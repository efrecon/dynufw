#!/usr/bin/env sh

set -eu

VERBOSE=0
QUIET=0
SERVER=${SERVER:-}
HOSTS_ALLOW=${HOSTS_ALLOW:-/etc/ufw-dynamic-hosts.allow}
IPS_ALLOW=${IPS_ALLOW:-/var/run/ufw-dynamic-ips.allow}
RESPIT=${RESPIT:-1}
UFW=ufw

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
    if ! has_rule "$_proto" "$_port" "$ip"; then
        log "Allow access from ${_ip} to port ${_port} on ${_proto}"
        info "${_ip}:${_port} ($proto) $($UFW allow proto "${_proto}" from "${_ip}" to any port "${_port}")"
    else
        log "rule already exists. nothing to do."
    fi
}

delete_rule() {
    _proto=$1
    _port=$2
    _ip=$3
    if has_rule "$_proto" "$_port" "$ip"; then
        log "Forbid access from ${_ip} to port ${_port} on ${_proto}"
        info "${_ip}:${_port} ($proto) $($UFW delete allow proto "${_proto}" from "${_ip}" to any port "${_port}")"
    else
        log "rule already exists. nothing to do."
    fi
}

resolv_v4() {
    _host=
    _rx_ip='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    if [ -z "$_host" ] && command -v dig 2>1 >/dev/null; then
        if [ -n "$SERVER" ]; then
            _host=$(dig +short "$1" | grep -Eo -e "$_rx_ip" | tail -n 1)
        else
            _host=$(dig +short @"$SERVER" "$1" | grep -Eo -e "$_rx_ip" | tail -n 1)
        fi
    fi
    if [ -z "$_host" ] && command -v getent 2>1 >/dev/null; then
        _host=$({ getent ahostsv4 "$1" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
    fi
    if [ -z "$_host" ] && command -v nslookup 2>1 >/dev/null; then
        if [ -n "$SERVER" ]; then
            _host=$({ nslookup "$1" "$SERVER" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
        else
            _host=$({ nslookup "$1" 2>/dev/null || true; } | grep -Eo -e "$_rx_ip" | head -n 1)
        fi
    fi
    if [ -z "$_host" ] && command -v host 2>1 >/dev/null; then
        _host=$(host "$1" | grep -Eo -e "$_rx_ip" | head -n 1)
    fi
    log "$1 is at: $_host"
    printf %s\\n "$_host"
}

sed -E '/^[[:space:]]*$/d' "${HOSTS_ALLOW}" | sed -E '/^[[:space:]]*#/d' | while IFS= read -r line
do
    proto=$(printf %s\\n "${line}" | cut -d: -f1)
    port=$(printf %s\\n "${line}" | cut -d: -f2 | sed 's/-/:/g')
    host=$(printf %s\\n "${line}" | cut -d: -f3)

    old_ip=
    if [ -f "${IPS_ALLOW}" ]; then
      old_ip=$(grep "${host}" "${IPS_ALLOW}" | cut -d: -f2)
    fi

    ip=$(resolv_v4 "$host")
    if [ -z "${ip}" ]; then
        if [ -n "${old_ip}" ]; then
            delete_rule "$proto" "$port" "$old_ip"
        fi
        warn "Failed to resolve the ip address of ${host}."
    else
        if [ -n "${old_ip}" ] && [ "${ip}" != "${old_ip}" ]; then
            delete_rule "$proto" "$port" "$old_ip"
        fi
        add_rule "$proto" "$port" "$ip"
    fi

    if [ -f "${IPS_ALLOW}" ]; then
        sed -i.bak "/^${host}:.*/d" "${IPS_ALLOW}"
    fi

    if [ -n "$ip" ]; then
        printf "%s:%s\n" "${host}" "${ip}" >> "${IPS_ALLOW}"
    fi
    sleep "$RESPIT"
done
