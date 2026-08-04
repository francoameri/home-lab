# 📂 Configuration files

Real configuration from the lab, committed at their proper extensions so the write-ups in the parent docs have something concrete to point at. These are the actual files that ran — not idealized examples.

## Redaction policy

Everything here is verbatim **except** secrets: passwords, keys, and pre-shared keys are replaced with `<REDACTED-...>` markers. Nothing else is altered — real IPs, hostnames, and (deliberately preserved) bugs are all as they were.

## Contents

| Path | What it is | Documented in |
|------|-----------|---------------|
| `proxmox/interfaces` | Host network bridges (WAN/LAN) | [`../proxmox.md`](../proxmox.md) |
| `proxmox/storage.cfg` | Proxmox storage definitions | [`../proxmox.md`](../proxmox.md) |
| `proxmox/100.conf` | Sophos firewall VM config | [`../proxmox.md`](../proxmox.md) / [`../firewall.md`](../firewall.md) |
| `proxmox/101.conf` | BIND9 LXC config | [`../proxmox.md`](../proxmox.md) / [`../BIND9.md`](../BIND9.md) |
| `proxmox/103.conf` | Samba LXC config | [`../proxmox.md`](../proxmox.md) / [`../Samba.md`](../Samba.md) |
| `bind9/named.conf.local` | Zone + TSIG key declarations | [`../BIND9.md`](../BIND9.md) |
| `bind9/named.conf.options` | Resolver + forwarders | [`../BIND9.md`](../BIND9.md) |
| `bind9/db.lab.lan` | Forward zone file | [`../BIND9.md`](../BIND9.md) |
| `bind9/db.10.0.0` | Reverse zone file | [`../BIND9.md`](../BIND9.md) |
| `bind9/sync-leases.sh` | DHCP→DNS sync script (contains a documented bug) | [`../BIND9.md`](../BIND9.md) |
| `bind9/check-bind9.sh` | Health-check script | [`../BIND9.md`](../BIND9.md) |
| `bind9/crontab` | The three cron jobs (sync, health, DDNS) | [`../BIND9.md`](../BIND9.md) |
| `samba/smb.conf` | The customized share block | [`../Samba.md`](../Samba.md) |
| `oci/ipsec.conf` | StrongSwan tunnel definition | [`../vpn.md`](../vpn.md) |
| `oci/ipsec.secrets` | PSK declaration (redacted) | [`../vpn.md`](../vpn.md) |
