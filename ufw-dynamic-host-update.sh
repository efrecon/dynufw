#!/bin/bash

VERBOSE=0
QUIET=0
SERVER=
while getopts "vqs:" opt; do
    case $opt in
        v)
            VERBOSE=1
            ;;
        q)
            QUIET=1
            ;;
        s)
            SERVER="$OPTARG"
            ;;
    esac
done

HOSTS_ALLOW=/etc/ufw-dynamic-hosts.allow
IPS_ALLOW=/var/tmp/ufw-dynamic-ips.allow

UFW=/usr/sbin/ufw
DIG=/usr/bin/dig

log() {
    local txt=$1

    if [ "$QUIET" == 0 -a "$VERBOSE" == "1" ]; then
        echo "$txt"
    fi
}

warn() {
    local txt=$1

    if [ "$QUIET" == 0 ]; then
        echo "$txt" 1>&2
    fi
}

add_rule() {
  local proto=$1
  local port=$2
  local ip=$3
  local regex="${port}\/${proto}.*ALLOW.*IN.*${ip}"
  local rule=$($UFW status numbered | grep $regex)
  if [ -z "$rule" ]; then
      log "Allow access from ${ip} to port ${port} on ${proto}"
      warn $($UFW allow proto ${proto} from ${ip} to any port ${port})
  else
      log "rule already exists. nothing to do."
  fi
}

delete_rule() {
  local proto=$1
  local port=$2
  local ip=$3
  local regex="${port}\/${proto}.*ALLOW.*IN.*${ip}"
  local rule=$($UFW status numbered | grep $regex)
  if [ -n "$rule" ]; then
      log "Forbid access from ${ip} to port ${port} on ${proto}"
      warn $($UFW delete allow proto ${proto} from ${ip} to any port ${port})
  else
      log "rule does not exist. nothing to do."
  fi
}


sed '/^[[:space:]]*$/d' ${HOSTS_ALLOW} | sed '/^[[:space:]]*#/d' | while read line
do
    proto=$(echo ${line} | cut -d: -f1)
    port=$(echo ${line} | cut -d: -f2 | sed 's/-/:/g')
    host=$(echo ${line} | cut -d: -f3)

    if [ -f ${IPS_ALLOW} ]; then
      old_ip=$(cat ${IPS_ALLOW} | grep ${host} | cut -d: -f2)
    fi

    if [ -z ${SERVER} ]; then
        ip=$($DIG +short $host | tail -n 1)
    else
        ip=$($DIG +short @${SERVER} $host | tail -n 1)
    fi
    if [ -z "${ip}" ]; then
        if [ -n "${old_ip}" ]; then
            delete_rule $proto $port $old_ip
        fi
        warn "Failed to resolve the ip address of ${host}."
    fi

    if [ -n "${old_ip}" ]; then
        if [ "${ip}" != "${old_ip}" ]; then
            delete_rule $proto $port $old_ip
        fi
    fi
    add_rule $proto $port $ip
    if [ -f ${IPS_ALLOW} ]; then
      sed -i.bak /^${host}*/d ${IPS_ALLOW}
    fi
    echo "${host}:${ip}" >> ${IPS_ALLOW}
    sleep 1
done
