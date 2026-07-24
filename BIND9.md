# 🌐 Sophos DHCP + Bind9 Dynamic DNS Integration

**Turning Sophos DHCP leases into live DNS records — a self-built emulation of the DHCP-to-DNS integration you'd get from Active Directory, without the resource cost of a domain controller.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Architecture](#️-architecture)
3. [Setup](#️-setup)
4. [Known bugs & gotchas](#-known-bugs--gotchas)
5. [Related documentation](#-related-documentation)
6. [Keywords](#️-keywords)
7. [License](#-license)

---

## 📖 Overview

This document covers how DHCP leases from **Sophos** were turned into live DNS records in **Bind9** — so any device getting an address on the LAN could immediately be reached by hostname (forward *and* reverse), with no static configuration.

Static infrastructure (Sophos, Proxmox, BIND9, Samba) didn't go through this pipeline — those got fixed entries directly in **Sophos's own DNS host table**, since they never change. This doc covers the dynamic side only; see the [main README](./README.md) for how the two layers fit together.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏗️ Architecture

```
[ Sophos DHCP ]
      │
      │  scp lease file, every 5 min
      ▼
[ sync-leases.sh ]
      │
      │  nsupdate, TSIG-secured
      ▼
[ Bind9  (10.0.0.201) ]
      │
      ├── authoritative: lab.lan  (forward, A records)
      ├── authoritative: 0.0.10.in-addr.arpa  (reverse, PTR records)
      │
      └── clients receive Bind9 as their resolver via DHCP Option 6
```

Ran as an unprivileged Debian LXC (`10.0.0.201`, 128MB RAM) — no Proxmox per-container firewall here, unlike the Samba container.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## ⚙️ Setup

### 1. Bind9 installation
Standard `bind9` package on Debian. `systemctl status bind9` to confirm it's up.

### 2. Zone configuration
`/etc/bind/named.conf.local`:

```
key dhcp_updater {
    algorithm hmac-sha256;
    secret "<REDACTED-TSIG-KEY>";
};

zone "lab.lan" {
    type master;
    file "/var/lib/bind/db.lab.lan";
    allow-update { key dhcp_updater; };
};

zone "0.0.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/db.10.0.0";
    allow-update { key dhcp_updater; };
};
```

`/etc/bind/named.conf.options` — recursive resolver bound to loopback + LAN IP, forwarding to Sophos first and Cisco Umbrella beyond:

```
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { any; };
    listen-on { 127.0.0.1; 10.0.0.201; };

    forwarders {
        10.0.0.1;           // Sophos
        208.67.222.222;     // Cisco Umbrella
        208.67.220.220;     // Cisco Umbrella
    };
};
```

### 3. Zone files (as they actually ended up)
`/var/lib/bind/db.lab.lan` — static infra entries (1-week TTL) alongside the dynamic client record (5-minute TTL) the sync script kept overwriting:

```
$ORIGIN lab.lan.
bind9                   A       10.0.0.201
proxmox                 A       10.0.0.200
samba                   A       10.0.0.202
sophos                  A       10.0.0.1

$TTL 300        ; 5 minutes
fameri                  A       10.0.0.100
test                    A       10.0.0.250   ; leftover from manually testing nsupdate
```

`/var/lib/bind/db.10.0.0` — matching reverse (`PTR`) records.

### 4. Sync script
`/usr/local/bin/sync-leases.sh` — parses Sophos's live lease file, pushes forward + reverse records via `nsupdate`:

```bash
#!/bin/bash
set -x
NSUPDATE="/usr/bin/nsupdate -k /etc/bind/dhcp_updater.key"
LEASEFILE="/var/tmp/sophos-leases.live"
ZONE="lab.lan"
REVZONE="0.0.10.in-addr.arpa"

awk -F'###' '{print $1, $4, $5}' "$LEASEFILE" | while read ip mac hostname; do
    if [ -n "$hostname" ]; then
        hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower':])   # <- bug: malformed argument
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
```

### 5. Health check
`/usr/local/bin/check-bind9.sh`, run via cron:

```bash
#!/bin/bash
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
```

### 6. Automation
Cron, tying lease sync and health check together:

```
*/5 * * * * scp -i /root/.ssh/sophos_key admin@10.0.0.1:/tmp/dhcpd.leases.live /var/tmp/sophos-leases.live && /usr/local/bin/sync-leases.sh
*/120 * * * * /usr/local/bin/check-bind9.sh
```

A third cron entry on this box also kept the lab's DDNS hostname current via DynU — see the [main README](./README.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🐛 Known bugs & gotchas

These are documented as-found, not silently cleaned up — they're part of the lesson.

- **Lowercase bug** – `tr '[:upper:]' '[:lower':]` has the closing bracket and colon swapped, breaking the lowercase conversion. It showed up once: March DNS logs show a device registering as `FAmeri.lab.lan` (mixed case). Around the same time a Rocky Linux dual-boot partition briefly appeared as `fameri-rocky.lab.lan` at `10.0.0.102`, failing one update with `NOTZONE`. By April the casing settled to clean lowercase on its own — the DHCP client started sending a lowercase hostname — so the bug never got fixed; it just stopped mattering.
- **Log overwrite** – the health check uses `> "$LOGFILE"` (overwrite) instead of `>>` (append), so there's never any history, only the latest snapshot.
- **Cron schedule** – `*/120` in the minutes field doesn't mean "every 2 hours." The minutes field only runs 0–59, so this fired once an hour. The check worked fine; the schedule just quietly wasn't what it looked like.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`journey.md`](./journey.md) — why this DNS service was built, and the story around it.
- [`Samba.md`](./Samba.md) — the other LXC service on this lab.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`BIND9` · `dynamic DNS` · `DDNS` · `nsupdate` · `TSIG` · `DHCP` · `Sophos` · `forward zone` · `reverse zone` · `PTR` · `cron` · `Debian LXC` · `Cisco Umbrella` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
