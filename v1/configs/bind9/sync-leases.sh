#!/bin/bash
# /usr/local/bin/sync-leases.sh
# Parses the Sophos DHCP lease file and pushes A + PTR records into BIND9 via nsupdate.
# NOTE: the `tr` line below has a real bug (see BIND9.md) -- kept as-is for the record.
set -x
NSUPDATE="/usr/bin/nsupdate -k /etc/bind/dhcp_updater.key"
LEASEFILE="/var/tmp/sophos-leases.live"
ZONE="lab.lan"
REVZONE="0.0.10.in-addr.arpa"

awk -F'###' '{print $1, $4, $5}' "$LEASEFILE" | while read ip mac hostname; do
    echo "DEBUG: ip=$ip mac=$mac hostname=$hostname"

    if [ -n "$hostname" ]; then
        hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower':])
        # Forward A record
        echo "server 127.0.0.1
zone $ZONE
update delete ${hostname}.${ZONE}. A
update add ${hostname}.${ZONE}. 300 A $ip
send" | $NSUPDATE

        # Reverse PTR record
        REVNAME=$(echo $ip | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa."}')
        echo "server 127.0.0.1
zone $REVZONE
update delete ${REVNAME} PTR
update add ${REVNAME} 300 PTR ${hostname}.${ZONE}.
send" | $NSUPDATE
    fi
done
