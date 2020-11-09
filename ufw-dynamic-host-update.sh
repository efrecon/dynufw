#!/usr/bin/env sh

set -eu

VERBOSE=0
QUIET=0
SERVER=${SERVER:-}
HOSTS_ALLOW=${HOSTS_ALLOW:-/etc/ufw-dynamic-hosts.allow}
IPS_ALLOW=${IPS_ALLOW:-}
RESPIT=${RESPIT:-1}
UFW=ufw
FORCE=0;

# Dynamic vars
cmdname=$(basename "$(readlink -f "$0")")
appname=${cmdname%.*}

# Print usage on stderr and exit
usage() {
  exitcode="$1"
  cat << USAGE >&2

Description:

  $cmdname will update ufw rules based for dynamically allocated addresses.

Usage:
  $cmdname [-option arg --long-option(=)arg] [--] command

  where all dash-led options are as follows (long options can be followed by
  an equal sign):
    -c | --config        Config file with : separated lines
    --cache              Where to store the IP cache
    -s | --server        Server to use for DNS resolutions, whenever possible
    --ufw                Location of the ufw binary, defaults to ufw
    --respit             Time to wait between rule changes, defaults to 1
    --quiet              Be almost silent, only warnings.
    -v | --verbose       Be more verbose
    -h | --help          Print this help and exit.
USAGE
  exit "$exitcode"
}


while [ $# -gt 0 ]; do
    case "$1" in
        -s | --server)
            SERVER=$2; shift 2;;
        --server=*)
            SERVER="${1#*=}"; shift 1;;

        -c | --config)
            HOSTS_ALLOW=$2; shift 2;;
        --config=*)
            HOSTS_ALLOW="${1#*=}"; shift 1;;

        --cache)
            IPS_ALLOW=$2; shift 2;;
        --cache=*)
            IPS_ALLOW="${1#*=}"; shift 1;;

        --ufw)
            UFW=$2; shift 2;;
        --ufw=*)
            UFW="${1#*=}"; shift 1;;

        --respit)
            RESPIT=$2; shift 2;;
        --respit=*)
            RESPIT="${1#*=}"; shift 1;;

        --force)
            FORCE=1; shift;;

        -q | --quiet)
            QUIET=1; shift;;

        -v | --verbose)
            VERBOSE=1; shift;;

        -h | --help)
            usage 0;;
        --)
            shift; break;;
        -*)
            echo "Unknown option: $1 !" >&2 ; usage 1;;
        *)
            break;;
    esac
done

log() {
    if [ "$QUIET" = 0 ] && [ "$VERBOSE" = "1" ]; then
        echo "[$appname] [log] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
    fi
}

info() {
    if [ "$QUIET" = 0 ]; then
        echo "[$appname] [info] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
    fi
}

warn() {
    echo "[$appname] [WARN] [$(date +'%Y%m%d-%H%M%S')] $1" >&2
}

if [ -z "$(command -v "$UFW")" ]; then
    warn "An installation of ufw is required!"
    usage 1
fi


has_rule() {
    _proto=$1
    _port=$2
    _ip=$3
    _regex="${_port}\/${_proto}\\s+ALLOW\\s+IN\\s+${_ip}"
    $UFW status numbered | grep -qE "$_regex"
}

add_rule() {
    _proto=$1
    _port=$2
    _ip=$3
    _host=${4:-}
    if [ "$FORCE" = "1" ] || ! has_rule "$_proto" "$_port" "$ip"; then
        log "Allow access from ${_ip} to port ${_port} on ${_proto}"
        info "${_ip}:${_port}/$proto: $($UFW allow proto "${_proto}" from "${_ip}" to any port "${_port}" comment "$_host")"
    else
        log "rule already exists. nothing to do."
    fi
}

delete_rule() {
    _proto=$1
    _port=$2
    _ip=$3
    if [ "$FORCE" = "1" ] || has_rule "$_proto" "$_port" "$ip"; then
        log "Forbid access from ${_ip} to port ${_port} on ${_proto}"
        info "${_ip}:${_port}/$proto: $($UFW delete allow proto "${_proto}" from "${_ip}" to any port "${_port}")"
    else
        log "rule already exists. nothing to do."
    fi
}

resolv_v4() {
    _host=
    _rx_ip='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    if [ -z "$_host" ] && command -v dig >/dev/null 2>&1; then
        if [ -n "$SERVER" ]; then
            _host=$(dig +short @"$SERVER" "$1" | grep -Eo -e "$_rx_ip" | tail -n 1)
        else
            _host=$(dig +short "$1" | grep -Eo -e "$_rx_ip" | tail -n 1)
        fi
    fi
    if [ -z "$_host" ] && command -v getent >/dev/null 2>&1; then
        _host=$({ getent ahostsv4 "$1" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
    fi
    if [ -z "$_host" ] && command -v nslookup >/dev/null 2>&1; then
        if [ -n "$SERVER" ]; then
            _host=$({ nslookup "$1" "$SERVER" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
        else
            _host=$({ nslookup "$1" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
        fi
    fi
    if [ -z "$_host" ] && command -v host >/dev/null 2>&1; then
        _host=$(host "$1" | grep -Eo -e "$_rx_ip" | head -n 1)
    fi
    log "$1 is at: $_host"
    printf %s\\n "$_host"
}

# Read configuration file and perform relevant ufw allow/delete allow rules.
sed -E '/^[[:space:]]*$/d' "${HOSTS_ALLOW}" | sed -E '/^[[:space:]]*#/d' | while IFS= read -r line
do
    # Extract protocol (tcp/udp), port (range) and host from line
    proto=$(printf %s\\n "${line}" | cut -d: -f1)
    port=$(printf %s\\n "${line}" | cut -d: -f2 | sed 's/-/:/g')
    host=$(printf %s\\n "${line}" | cut -d: -f3)

    # extract old IP address from cache, if any
    old_ip=
    if [ -z "$IPS_ALLOW" ]; then
        old_ip=$($UFW status | grep "$host" | grep "${port}/${proto}" | awk '{print $3}')
    elif [ -f "${IPS_ALLOW}" ]; then
        old_ip=$(grep "${host}" "${IPS_ALLOW}" | cut -d: -f2)
    fi

    # Resolve hostname to its current IP address
    ip=$(resolv_v4 "$host")

    # When the IP is lost, delete the rule. When the IP has changed, delete the
    # old rule and create a new one.
    if [ -z "$ip" ]; then
        if [ -n "$old_ip" ]; then
            delete_rule "$proto" "$port" "$old_ip"
        fi
        warn "Failed to resolve the ip address of $host."
    else
        if [ -n "$old_ip" ]; then
            if [ "$ip" != "$old_ip" ] || [ "$FORCE" = "1" ]; then
                delete_rule "$proto" "$port" "$old_ip"
            fi
        fi
        add_rule "$proto" "$port" "$ip" "$host"
    fi

    # When the IP has changed, including been removed, update the cache for next
    # time.
    if [ -n "$IPS_ALLOW" ] && [ "${ip}" != "${old_ip}" ]; then
        if [ -f "${IPS_ALLOW}" ]; then
            sed -i.bak "/^${host}:.*/d" "${IPS_ALLOW}"
        fi

        if [ -n "$ip" ]; then
            printf "%s:%s\n" "${host}" "${ip}" >> "${IPS_ALLOW}"
        fi
    fi
    sleep "$RESPIT"
done
