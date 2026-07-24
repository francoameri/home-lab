#!/bin/bash
# /usr/local/bin/check-bind9.sh
# Simple bind9 health check. NOTE: uses > (overwrite) not >> -- no history kept. See BIND9.md.
LOGFILE="/var/log/bind9-health.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')
{
    echo "=== Bind9 Health Check @ $DATE ==="
    if systemctl is-active --quiet bind9; then
        echo "Service: bind9 is ACTIVE"
    else
        echo "Service: bind9 is INACTIVE"
    fi
    if ss -lnup | grep :53; then
        echo "Port 53: Listening OK"
    else
        echo "Port 53: NOT LISTENING"
    fi
    dig @127.0.0.1 lab.lan +short
    dig @127.0.0.1 microsoft.com +short
} > "$LOGFILE"
