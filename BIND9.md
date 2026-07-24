# 🌐 BIND9 Dynamic DNS — Self-Built DHCP-to-DNS Integration

**A self-built emulation of the DHCP-to-DNS integration you'd get from Active Directory — DHCP leases from Sophos automatically becoming forward and reverse DNS records — implemented from scratch with a cron job, a shell script, and TSIG-secured dynamic updates, on a 128 MB container.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Technical reference](#-technical-reference)
   - [The pipeline, step by step](#the-pipeline-step-by-step)
   - [Zone configuration & TSIG](#zone-configuration--tsig)
   - [Resolver & forwarders](#resolver--forwarders)
   - [Zone files](#zone-files)
   - [The sync script](#the-sync-script)
   - [Health check](#health-check)
   - [Cron jobs](#cron-jobs)
3. [Two DNS layers, by design](#-two-dns-layers-by-design)
4. [Known bugs & gotchas](#-known-bugs--gotchas)
5. [Config files](#-config-files)
6. [Related documentation](#-related-documentation)
7. [Keywords](#️-keywords)
8. [License](#-license)

---

## 📖 Overview

Sophos hands out DHCP leases, but — unlike a Windows Server + AD DNS setup — it doesn't automatically publish those leases into a DNS zone. I wanted that behavior anyway: a device joins the network, gets an address, and is immediately reachable by hostname, forward and reverse, with no static configuration.

So I built the bridge myself on a tiny BIND9 container (`10.0.0.201`, 128 MB): every 5 minutes it pulls Sophos's live lease file, parses it, and pushes the results into its own authoritative zone using TSIG-secured dynamic updates. The technical reference below walks the whole pipeline; the short version is that this is "dynamic DNS" rebuilt from primitives, which is a far better way to actually understand it than trusting a checkbox.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔧 Technical reference

### The pipeline, step by step

```
[ Sophos DHCP server ]
        │  lease file: /tmp/dhcpd.leases.live
        │
        │  (1) cron on BIND9 LXC scp-pulls it every 5 min, using an
        │      SSH key (root@bind9) authorized on Sophos
        ▼
[ /var/tmp/sophos-leases.live ]  (local copy on the BIND9 container)
        │
        │  (2) sync-leases.sh parses it: awk splits on '###', extracting ip / mac / hostname
        ▼
[ nsupdate -k dhcp_updater.key ]
        │  (3) authenticated by TSIG (hmac-sha256) — BIND9 only accepts
        │      dynamic updates signed with this key
        ▼
[ BIND9 authoritative zones ]
        ├── lab.lan            → A record  (hostname → IP)
        └── 0.0.10.in-addr.arpa → PTR record (IP → hostname)
        │
        │  (4) clients receive 10.0.0.201 as their resolver via DHCP Option 6
        ▼
[ any LAN device can now resolve every other device by name ]
```

Four moving parts — a scheduled pull, a parser, an authenticated update mechanism, and an authoritative server — is exactly what a native DHCP-DNS integration hides behind one setting. Building it by hand meant owning each one.

### Zone configuration & TSIG

Dynamic updates are gated by a **TSIG key** (`hmac-sha256`) — BIND9 rejects any update not signed with it, which is what makes it safe to allow programmatic updates at all. From [`configs/bind9/named.conf.local`](./configs/bind9/named.conf.local):

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

`allow-update { key dhcp_updater; }` is the important line — updates are authorized **by key, not by IP**, so even something on the LAN can't inject records without the key. `hmac-sha256` over the older `hmac-md5` default is the one non-obvious choice here: MD5-based TSIG is deprecated, and there was no reason to use it for a key generated fresh.

### Resolver & forwarders

BIND9 was both authoritative (for `lab.lan`) and a recursive resolver (for everything else). From [`configs/bind9/named.conf.options`](./configs/bind9/named.conf.options):

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

The forwarder order matters: queries BIND9 can't answer locally go **to Sophos first** (which applies its own filtering and can answer for things it knows), then out to **Cisco Umbrella** for upstream recursive resolution with content/security filtering. So every external lookup on the LAN passed through two layers of filtering without any client needing to know.

### Zone files

The forward zone ([`db.lab.lan`](./configs/bind9/db.lab.lan)) mixes static infra (1-week TTL — they never change) with the dynamic client record (5-minute TTL — it gets overwritten constantly):

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

The TTL split is deliberate: infra records at 604800s (a week) because they're stable and you want them cached; the dynamic `fameri` record at 300s (5 min) because it could change on any lease renewal and you don't want stale caches. The reverse zone ([`db.10.0.0`](./configs/bind9/db.10.0.0)) mirrors this with `PTR` records. The serial numbers (16 forward, 10 reverse) show these zones were genuinely updated many times over the lab's life — not a config that was set once and left.

### The sync script

[`configs/bind9/sync-leases.sh`](./configs/bind9/sync-leases.sh) does the parse-and-update. Core logic:

```bash
awk -F'###' '{print $1, $4, $5}' "$LEASEFILE" | while read ip mac hostname; do
    if [ -n "$hostname" ]; then
        hostname=$(echo "$hostname" | tr '[:upper:]' '[:lower':])   # <- bug, see below
        echo "server 127.0.0.1
zone lab.lan
update delete ${hostname}.lab.lan. A
update add ${hostname}.lab.lan. 300 A $ip
send" | nsupdate -k /etc/bind/dhcp_updater.key
        # ...reverse PTR update follows the same pattern
    fi
done
```

The `delete` before every `add` is intentional — it makes each run **idempotent**, so re-running on an unchanged lease just re-writes the same record rather than erroring or duplicating.

### Health check

[`configs/bind9/check-bind9.sh`](./configs/bind9/check-bind9.sh) verifies service status, port 53 listening, and both internal + external resolution:

```bash
systemctl is-active --quiet bind9 && echo "ACTIVE" || echo "INACTIVE"
ss -lnup | grep :53
dig @127.0.0.1 lab.lan +short          # internal (authoritative)
dig @127.0.0.1 microsoft.com +short    # external (recursion + forwarders)
```

Testing both an internal *and* an external name in one check is the right instinct — it proves BIND9 is working as authoritative server *and* as recursive resolver, which are two separate failure modes.

### Cron jobs

Three jobs on the BIND9 LXC ([`configs/bind9/crontab`](./configs/bind9/crontab)):

```
*/5 * * * * scp ... admin@10.0.0.1:/tmp/dhcpd.leases.live ... && /usr/local/bin/sync-leases.sh
*/120 * * * * /usr/local/bin/check-bind9.sh
*/5 * * * * curl -s "https://api.dynu.com/nic/update?hostname=fameri-lab.ddnsfree.com&username=fameri&password=<REDACTED>"
```

Note the third job: this container didn't just do DNS — it also ran the **DynU DDNS updater** that kept the lab's public hostname current, which is what made the [site-to-site VPN](./vpn.md) reachable. One 128 MB container quietly did double duty.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🧭 Two DNS layers, by design

The dynamic pipeline above handled **DHCP clients**. Static infrastructure (Sophos, Proxmox, BIND9, Samba) did *not* go through it — those got fixed entries directly in [Sophos's own DNS host table](./firewall.md#-dns-host-records), since their addresses never change.

The split is deliberate and worth defending: dynamic infrastructure that changes on every lease belongs in an automated pipeline; static infrastructure that never changes belongs in a simple table where a typo can't be introduced by a script. Sophos's DNS API was locked to accept calls only from BIND9's IP, since BIND9 was the sole consumer of the lease data.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🐛 Known bugs & gotchas

Documented as-found — they're part of the lesson, and the config files keep them verbatim:

- **Lowercase bug** — `tr '[:upper:]' '[:lower':]` has the bracket and colon swapped, breaking the conversion. It surfaced once (March logs show `FAmeri.lab.lan` registered mixed-case; a Rocky Linux dual-boot partition briefly appeared as `fameri-rocky.lab.lan` at `10.0.0.102`, failing one update with `NOTZONE`). By April the casing settled to lowercase on its own once the DHCP client changed behavior — so it was never fixed, it just stopped mattering.
- **Log overwrite** — the health check uses `> "$LOGFILE"` not `>>`, so it only ever holds the latest snapshot, no history.
- **Cron schedule** — `*/120` in a minutes field doesn't mean "every 2 hours"; the field only runs 0–59, so it fired hourly. The check ran fine; the schedule just wasn't what it looked like.
- **DNSSEC vs. a wrong clock** — after the 2-month cold storage, BIND9's logs showed `RRSIG validity period has not begun` / broken-trust-chain errors on external lookups. Not a BIND bug — the host clock was reading ~April while real time was July, so DNSSEC signatures looked "not yet valid." A good reminder that DNSSEC failures are often a clock problem, not a DNS problem.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📂 Config files

All under [`configs/bind9/`](./configs/bind9/): `named.conf.local`, `named.conf.options`, `db.lab.lan`, `db.10.0.0`, `sync-leases.sh`, `check-bind9.sh`, `crontab`.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`proxmox.md`](./proxmox.md) — the LXC (guest 101) this runs in.
- [`firewall.md`](./firewall.md) — Sophos, whose DHCP leases feed this pipeline.
- [`vpn.md`](./vpn.md) — the VPN kept reachable by this container's DDNS updater.
- [`journey.md`](./journey.md) — why this DNS service was built.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔑 Keywords

`BIND9` · `dynamic DNS` · `DDNS` · `nsupdate` · `TSIG` · `hmac-sha256` · `DHCP` · `forward zone` · `reverse zone` · `PTR` · `SOA` · `TTL` · `recursion` · `forwarders` · `Cisco Umbrella` · `cron` · `Debian LXC` · `DNSSEC` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

✍️ Authored by **Franco [francoameri]**
📜 Licensed under [CC BY 4.0](https://github.com/francoameri/francoameri/blob/main/LICENSE.md)
Please credit the original author when sharing or adapting this work.
