🔧 Home-Lab v2 — Segmented OPNsense Build

A dedicated bare-metal firewall replacing v1's virtualized-Sophos-on-Proxmox design, with real VLAN segmentation, dual-purpose VPN egress, a Proxmox host behind it running core services, and a self-hosted monitoring stack watching all of it. This document is a living record, updated as the build progresses — not a retrospective like v1.

📑 Table of Contents

- [Status](#status)
- [Overview](#overview)
- [Goals](#goals)
- [Network topology](#network-topology)
- [Hardware and software inventory](#hardware-and-software-inventory)
- [Configuration highlights](#configuration-highlights)
- [Known issues & lessons](#known-issues--lessons)
- [Planned / not yet built](#planned--not-yet-built)
- [Related documentation](#related-documentation)
- [Keywords](#keywords)
- [Contributions](#contributions)
- [License](#license)

---

## Status

🚧 **Active, in progress.** Build started August 2026. Firewall, VLAN segmentation, switch, Proxmox host, DNS (Pi-hole + Unbound redundancy), and a Prometheus/Grafana monitoring stack are all live. NAS is planned, not yet deployed.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Overview

Where v1 ran its firewall as a VM inside a general-purpose hypervisor, v2 inverts that: a dedicated bare-metal appliance (OPNsense) sits at the edge, with virtualization (Proxmox) living *behind* it as just another segment on the network, not the thing hosting the firewall itself. Proxmox now hosts every core service in the lab — UniFi's self-hosted controller, Pi-hole for network-wide DNS, and a Prometheus/Grafana stack watching all of it — each in its own container, on its own address, rather than one box doing everything.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Goals

- **Dedicated edge hardware** — a purpose-built firewall appliance, not a VM competing for hypervisor resources.
- **Real network segmentation** — VLANs with distinct trust levels (management, trusted clients, servers, guest, IoT), not a flat LAN.
- **Defense in depth on egress** — GeoIP blocking, IDS/IPS, reputation-based blocklists, and DNS-bypass prevention, applied consistently across every segment.
- **Responsible shared VPN egress** — a friends-facing VPN exit hardened against the specific category of traffic that creates real legal exposure for the account holder, without being a blanket content filter.
- **Compute and storage as separate concerns** — Proxmox for services, a dedicated NAS for bulk/media storage, connected over the network rather than crammed into one box.
- **No single point of failure on core network services where avoidable** — e.g., DNS resolves through Pi-hole first and this firewall's own Unbound second, so a Proxmox or container failure degrades ad-blocking, not resolution itself.
- **Observability as a first-class citizen, not an afterthought** — host, container, and service-level metrics plus uptime checks, self-hosted alongside everything they monitor.
- **Operate like production, not like a hobby project** — config backups with rollback anchors before every change, verification against the live system rather than trusting exported config files, and a documented gotchas list so mistakes aren't repeated.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Network topology

**Hardware:** Topton mini PC (Intel J6412), 4× Intel i226-V NICs, running OPNsense.

| Interface | Role | Address | Notes |
|---|---|---|---|
| WAN | Internet | Static IPv4 behind double-NAT (ISP router) + public IPv6 GUA via DHCPv6 | The double-NAT doesn't shield IPv6 — WAN has a real routable IPv6 address. |
| MGMT (native/untagged) | Management | 192.168.100.0/24, gateway `.254` | Stays untagged on the trunk deliberately — the one segment that's never touched during VLAN work, so a mistake elsewhere can't strand admin access. |
| TRUSTED (VLAN 20) | Day-to-day devices, internal Wi-Fi | 192.168.120.0/24, gateway `.254` | |
| SERVERS (VLAN 30) | Proxmox host and VMs | 192.168.130.0/24, gateway `.254` | Live — hosts Pi-hole (`.200`), UniFi OS Server (`.201`), and the monitoring stack (`.202`). |
| GUEST (VLAN 50) | Guest devices, isolated | 192.168.150.0/24, gateway `.254` | Explicit isolation rule blocks all RFC1918 destinations; internet-only. |
| IOT (VLAN 40) | Wi-Fi casting devices | 192.168.140.0/24, gateway `.254` | Live — has its own full outbound ruleset (DNS/NTP/internet), not just inbound casting passes from TRUSTED/GUEST. |

**Switch:** Ubiquiti UniFi Switch Lite 16 PoE (layer 2 only — all inter-VLAN routing happens on OPNsense, router-on-a-stick over a single trunk), adopted into a self-hosted UniFi OS Server running on Proxmox.

**DNS/DHCP:** Pi-hole (`192.168.130.200`) is the primary DNS resolver advertised to every VLAN via DHCP, for network-wide ad/tracker blocking; this firewall's own Unbound is the secondary/fallback resolver per VLAN, so a Pi-hole or Proxmox outage degrades to "no ad-blocking" rather than "no DNS." Dnsmasq handles DHCP and authoritative local DNS (`lab.lan`) on a non-standard port. Each VLAN interface needs its own DHCP range and its own entry in both Dnsmasq's and Unbound's listener lists — a VLAN with an IP but no DNS resolution is the most common way a segmented network looks "broken" when it's actually just a missed checkbox. Full design in [`opnsense.md`](opnsense.md#dns-and-dhcp--a-split-design) and [`pihole.md`](pihole.md).

**VPN:** two OpenVPN instances sharing one CA and one tls-crypt key:
- Instance 1 (udp/1194) — personal remote access, split-tunnel, routes to TRUSTED and SERVERS (not GUEST).
- Instance 2 (udp/1195) — full-tunnel internet exit for friends/family, hardened (see Configuration highlights).

**Monitoring:** a Prometheus + Grafana stack on its own CT scrapes host, container, and service-level metrics across the whole lab, plus uptime/availability checks on every admin UI. Full detail in [`monitoring.md`](monitoring.md).

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Hardware and software inventory

**Deployed:**
- Topton mini PC (Intel N150, 4× i226-V) — OPNsense 26.7.1, FreeBSD 15.1, ZFS root.
- Ubiquiti Switch Lite 16 PoE (8 of 16 ports PoE+) — layer 2, adopted by the self-hosted UniFi OS Server.
- HP EliteDesk Mini 600 G6 (i5-10500T) — Proxmox VE host, ZFS root, on the SERVERS VLAN. Hosts three LXC guests: UniFi OS Server (`CT 201`), Pi-hole (`CT 200`), and the monitoring stack (`CT 202`). See [`proxmox.md`](proxmox.md#guests).
- Pi-hole (`CT 200`) — network-wide DNS resolution and ad-blocking for every VLAN. See [`pihole.md`](pihole.md).
- Prometheus + Grafana monitoring stack (`CT 202`) — host, container, and service-level metrics plus uptime checks. See [`monitoring.md`](monitoring.md).

**Planned:**
- 2–4 bay NAS, RAID10, starting with 4× 1TB HDDs.
- Local Proxmox Backup Server datastore (Tier-1, fast local restore) once a NAS-freed drive bay is available; the NAS becomes Tier-2 (off-box) backup afterward.

**Software services (planned):** media server (Jellyfin or similar, storage on NAS via NFS, app on Proxmox) — deliberately left open rather than over-planned.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Configuration highlights

- **Firewall rule consolidation via multi-interface + alias-based scoping.** Rather than duplicating identical rules across TRUSTED and SERVERS, rules are written once against both interfaces, using a purpose-built alias (`internal_vlans`) for inverted-destination matching where OPNsense's GUI won't allow inverting against multiple discrete targets directly. GUEST and IOT are each given their own fully separate, order-dependent rule sets — mixing them into shared rules would risk their isolation logic becoming unclear or bypassed.
- **GUEST and IOT isolation, in enforced order:** pass DNS/NTP to the gateway → block all further access to the firewall itself → block all RFC1918 destinations (`private_nets_VPN_ADD`, which conveniently already covers every other VLAN plus both VPN tunnel subnets) → pass-any (internet only) last.
- **DNS redundancy by design.** Every VLAN's DHCP option 6 advertises Pi-hole first and that VLAN's own OPNsense gateway (Unbound) second, so DNS survives a Pi-hole/Proxmox outage even though ad-blocking doesn't.
- **GeoIP blocking** of a defined hostile-country list, verified live to sit ahead of both OpenVPN port passes in the actual pf ruleset — not just assumed from the GUI.
- **Responsible VPN egress hardening (Instance 2 / friends' VPN):** DNS forced through CleanBrowsing's *Security Filter* (malware/phishing/CSAM blocking only — deliberately not a lifestyle/content filter, since general adult content and torrenting are explicitly permitted) plus a firewall block against an auto-updating alias of official Tor Project exit-node IPs (`https://check.torproject.org/torbulkexitlist`, refreshed daily). The goal is narrowly scoped: block the one category that creates real legal exposure for the account holder, without restricting anything else.
- **Least-privilege service accounts for integrations.** The monitoring stack's OPNsense exporter authenticates as a dedicated `monitoring-api` user scoped only to the read-only privileges it actually needs (no password login, no group membership); Pi-hole's exporter authenticates with an App Password generated after disabling destructive API actions. See [`opnsense.md`](opnsense.md#monitoring-api-access) and [`pihole.md`](pihole.md#monitoring-integration).
- **Standing operational discipline:** every live change gets a ZFS-boot-environment rollback anchor (`bectl create`) and a config backup *before* the change, and claims about firewall/DNS/service behavior are verified against the running system (`pfctl`, `sockstat`, `drill`) rather than trusted from an exported config file.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Known issues & lessons

Real gotchas discovered while building this, not sanitized after the fact:

- **Multi-interface + multi-network-source floating rules expand into a full cross-product.** Selecting three interfaces *and* three source networks on one rule doesn't generate "one rule per interface matching its own network" — OPNsense generates a rule for *every* interface/source-network combination, including nonsensical ones. Harmless in practice (anti-spoofing already drops wrong-subnet-on-wrong-interface packets), but inflates the ruleset for no functional benefit. Fix: use `any` for Source when Interface scoping already does the real work.
- **A pre-existing floating Block rule can silently break a brand-new service built long after the rule was written.** A floating "block DNS bypass" rule written before Pi-hole existed silently blocked every cross-VLAN query to it once deployed — same-subnet tests looked fine (they never traverse OPNsense's routing layer) while genuinely cross-VLAN tests failed identically-configured traffic. Full trail in [`pihole.md`](pihole.md#the-dns-bypass-floating-rule-bug).
- **A VLAN interface with no rules of its own has no outbound access, even if other VLANs have inbound passes pointed at it.** IOT initially had only the casting-related Pass rules that TRUSTED/GUEST pointed *at* it — no ruleset of its own meant no DNS, no NTP, no internet for IOT devices. Detail in [`opnsense.md`](opnsense.md#iots-own-ruleset).
- **"Invert Destination," left checked from a cloned rule, produces the exact opposite of the intended behavior.** Watch for a `!` prefixing the destination in the rules list.
- **OPNsense's Listen Interfaces setting scopes more than the web GUI.** An interface left out of System → Settings → Administration → Listen Interfaces produces a full connection timeout for anything hitting the API/GUI on that interface — indistinguishable from "nothing is listening," not a firewall rejection. Cost real debugging time on the OPNsense monitoring exporter; detail in [`monitoring.md`](monitoring.md#phase-3--service-specific-exporters).
- **dnsmasq and Unbound both self-follow interface IP changes** — moving an interface's address doesn't require manually updating each service's listen-address list, since both bind by interface, not a hardcoded address. What *does* need a manual nudge: an already-running service instance holding a stale socket on the old address until it's restarted/reloaded — `sockstat` will show the ghost binding until then.
- **A client machine's own DHCP lease doesn't self-heal** when the gateway address changes underneath it — the client keeps routing through the old (now-nonexistent) gateway/DNS server until its lease renews. Same-subnet SSH access to the new address still works immediately regardless (ARP, not routing), but broader connectivity needs a manual release/renew.
- **"Other Types" doesn't exist in this OPNsense version's menu** the way older documentation describes — VLAN interface creation lives under **Interfaces → Devices → VLAN**, not a dedicated top-level menu item.
- **UniFi switches have no standalone local management** — factory/unadopted state is a plain unmanaged L2 switch (everything on the native VLAN); VLAN-aware port profiles require a UniFi controller to exist and adopt the device first. This is architecture, not a missing feature.
- **PoE port layout isn't odd/even** on the UniFi Switch Lite 16 PoE — it's a straight split, ports 1–8 PoE+, 9–16 non-PoE. Moot in practice, since PoE only activates on negotiation — any port is safe to use for a non-PoE uplink.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Planned / not yet built

- NAS (2–4 bay, RAID10, ~2 months out at last check).
- Local Proxmox Backup Server datastore, once a drive bay frees up.
- Suricata IPS scope decision — currently `lan,opt1,wan` only; once inter-VLAN routing carries real traffic, all of it will hairpin through Suricata on modest hardware, so WAN-only vs. all-interfaces is an open tradeoff to make deliberately, not by default.
- OpenVPN tls-crypt key rotation — flagged as compromised after appearing unredacted in an exported config during a review pass; deferred since the VPN isn't currently in active use, revisit before either instance goes back into use.
- Tier-3 (off-Hetzner-equivalent / off-site) backup — no off-box backup target exists yet beyond the planned local PBS datastore and eventual NAS; acknowledged gap, not yet scheduled.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Related documentation

- [`opnsense.md`](opnsense.md) — firewall build in full: interfaces, VLANs, DNS/DHCP, firewall rules, monitoring API access.
- [`unifi.md`](unifi.md) — switch/AP adoption, port profiles, and the self-hosted controller migration.
- [`proxmox.md`](proxmox.md) — hypervisor storage, VM/LXC strategy, guest inventory, networking.
- [`pihole.md`](pihole.md) — network-wide DNS and ad-blocking, DNS redundancy design.
- [`monitoring.md`](monitoring.md) — Prometheus + Grafana stack: architecture, exporters, targets.
- `configs/` — real config excerpts, secrets redacted. *(to be added)*

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Keywords

OPNsense · VLAN segmentation · pfctl · UniFi · Proxmox · ZFS · Pi-hole · Prometheus · Grafana · cAdvisor · homelab · network security · GeoIP · CrowdSec · Suricata · OpenVPN · firewall · self-hosted · infrastructure engineering · observability

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Contributions

This repository is personal and experience-driven, but feedback and ideas are welcome. If you've faced similar challenges, feel free to share your approach or suggest improvements.

💼 [LinkedIn](https://linkedin.com/in/fameri) · 🌐 [GitHub](https://github.com/francoameri) · ✉️ famerisbraccia@gmail.com

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## License

All content in this repository is shared under the [Creative Commons Attribution 4.0 International License (CC BY 4.0)](../LICENSE.md).

You are free to **share** (copy and redistribute in any medium or format) and **adapt** (remix, transform, build upon) this material for any purpose, even commercially, under the term of **attribution** — credit Franco [francoameri] as the original author, link back to this repository, and indicate if changes were made.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>
