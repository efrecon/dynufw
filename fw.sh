#! /usr/bin/env bash

# This script will be run on all machines. It opens up a few ports in the
# firewall. In addition it takes a number of port opening rules as parameters.
# The most complex rule would be: xx.xx.xx.xx:yyy/proto/d Where xx.xx.xx.xx is a
# hostname or IP address and yyy is a port number. The proto can be tcp or udp.
# When a hostname is specified it is resolved to its IP address at the time the
# script is run (unless /d is specified). Proto defaults to tcp. When no
# host/ip is specified, the port will be opened for all incoming traffic. When
# /d (verbatim) is specified, a rule is added to the dynamic port opener script
# that is run every minute on the host, if the file exists.

# Install ufw, be quiet and answer yes to all questions, the following is aware
# of both debian-derivatives or Alpine.
if [ -e "/sbin/apk" ]; then
    # On Alpine, we check if the binaries are already there to quicken the
    # initialisation process.
    
    # Add ufw from the testing repository
    if [ -z "$(which ufw)" ]; then
        installed=$(sudo apk add --no-cache ufw 2>&1)
        if [ -n "$(echo "$installed" | grep "ERROR")" ]; then
            sudo apk add ufw --allow-untrusted --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing/ --no-cache
        else
            echo "$installed"
        fi
    fi
    # Add statically compiled dig. This is an ugly trick and we should install
    # dig from the package repository as soon as it has move into testing or
    # similar.
    if [ -z "$(which dig)" ]; then
        installed=$(sudo apk add --no-cache dig 2>&1)
        if [ -n "$(echo "$installed" | grep "ERROR")" ]; then
            wget -q -O- https://github.com/sequenceiq/docker-alpine-dig/releases/download/v9.10.2/dig.tgz| sudo tar -xzv -C /usr/bin/
        else
            echo "$installed"
        fi
    fi
fi
if [ -e "/usr/bin/apt-get" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -yq ufw dnsutils
fi

exit
# Detect if we have ufw on the machine
UFW=$(which ufw)

# Allow OpenVPN port for traffic
DYNEXE=/usr/local/sbin/ufw-dynamic-host-update.sh
DYNPATH=/etc/ufw-dynamic-hosts.allow
if [ -n "$UFW" ]; then
    # Open specific ports (from specific hosts)
    for opening in "$@"; do
        # Opening are in the form host.tld:80/tcp (where host.tld and tcp can be
        # omitted)
        if [[ "$opening" =~ ^(([0-9a-zA-Z\.\-]+):)?([0-9]+(-[0-9]+)?)(/(udp|tcp)(/d)?)?$ ]]; then
            host=${BASH_REMATCH[2]};
            port=${BASH_REMATCH[3]};
            proto=${BASH_REMATCH[6]};
            dyn=${BASH_REMATCH[7]};
            if [ -z "$proto" ]; then
                proto="tcp";
            fi
            if [ -z "$host" ]; then
                # Convert dash separated port range to colon separated (which is
                # the format supported by UFW)
                port=$(echo ${port}|sed s/-/:/g)
                echo "Opening firewall for all incoming traffic on port ${port}/${proto}"
                ufw allow ${port}/${proto}
            else
                if [ -n "$dyn" ]; then
                    if [ -f "$DYNEXE" ]; then
                        ADDED=$(grep "${proto}:${port}:${host}" "$DYNPATH")
                        echo "Opening firewall for incoming traffic on port ${port}/${proto} from ${host} (dynamic)"
                        if [ -z "$ADDED" ]; then
                            echo "" >> $DYNPATH
                            echo "# Rule automatically added by ${0##*/}" >> $DYNPATH
                            echo "${proto}:${port}:${host}" >> $DYNPATH
                        else
                            echo "Skipping adding existing rule!"
                        fi
                    fi
                else
                    # Convert dash separated port range to colon separated (which is
                    # the format supported by UFW)
                    port=$(echo ${port}|sed s/-/:/g)
                    if [[ "$host" =~ ^[0-9\.]+$ ]]; then
                        ip=${host}
                    else
                        ip=$(dig +short $host | tail -n 1)
                    fi
                    echo "Opening firewall for incoming traffic on port ${port}/${proto} from ${ip}"
                    ufw allow proto $proto from $ip to any port $port
                fi
            fi
        else
            echo "$opening is not a valid port opening specification!"
        fi
    done
    
    # Open firewall (supposes /usr/local/sbin/ufw-dynamic-host-update.sh)
    if [ -f "$DYNEXE" ]; then
        echo "Running $DYNEXE once to open dynamic ports"
        chmod a+x $DYNEXE
        eval "$DYNEXE"
        
        if [ -e "/etc/os-release" ]; then
            . /etc/os-release
        else
            ID=""
        fi
        
        if [ "$ID" == "rancheros" ]; then
            SCHEDULED=$(system-docker ps -q --filter "name=fw-updater")
            if [ -z "$SCHEDULED" ]; then
                echo "Arranging for $DYNEXE to keep port openings at regular intervals from a container"
                system-docker run -d \
                    --name="fw-updater" \
                    -v /var/run/system-docker.sock:/var/run/docker.sock \
                    --net=host \
                    efrecon/dockron \
                    -verbose INFO \
                    -docker "unix:///var/run/docker.sock" \
                    -rules "* * * * * console exec \"$DYNEXE -q -s 8.8.8.8\""
            else
                echo "$DYNEXE already scheduled within container $SCHEDULED"
            fi
        else
            # Schedule to run this often via crontab.
            SCHEDULED=$(crontab -l|grep "$DYNEXE")
            if [ -z "$SCHEDULED" ]; then
                echo "Arranging for $DYNEXE to keep port openings at regular intervals"
                line="* * * * * $DYNEXE -q -s 8.8.8.8"
                (crontab -l; echo "$line") | crontab -
            fi
        fi
    fi
    
    echo "Enabling firewall forcefully"
    ufw --force enable
fi