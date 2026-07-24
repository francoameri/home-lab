# 🛡️ Sophos Firewall Configuration

**The virtualized edge of the lab — a Sophos Home Firewall running as a Proxmox VM, handling routing, NAT, DHCP, DNS host records, VPN termination, and layered security services for the whole network.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Why virtualize the firewall](#-why-virtualize-the-firewall)
3. [Interfaces & zones](#-interfaces--zones)
4. [DHCP](#-dhcp)
5. [DNS host records](#-dns-host-records)
6. [Firewall rules](#-firewall-rules)
7. [NAT](#-nat)
8. [Security services](#-security-services)
9. [VPN roles](#-vpn-roles)
10. [Backups](#-backups)
11. [Engineering notes & lessons](#-engineering-notes--lessons)
12. [Related documentation](#-related-documentation)
13. [Keywords](#️-keywords)
14. [License](#-license)

---

## 📖 Overview

Sophos ran as a VM inside Proxmox (`10.0.0.1`), acting as the gateway for the entire `10.0.0.0/24` LAN. It's the free/registered Sophos Home edition (model `SFVH`) — which is worth stating plainly, because it's a legitimately capable platform even without a paid license: real firewall policy, IPS, web filtering, threat intelligence, and full IPsec/SSL VPN, all in a home lab.

This document covers the firewall's actual configuration as it ran. The VPN gets its own dedicated write-up in [`vpn.md`](./vpn.md) since it spans both this firewall and the cloud side.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🤔 Why virtualize the firewall

The lab ran on a single Dell laptop. Buying a dedicated firewall appliance wasn't the point — the point was to *learn* one. Running Sophos as a VM with two bridged interfaces (LAN + WAN) meant the whole edge could live on the same host as everything it protected, while still behaving like a real standalone appliance: separate zones, its own policy engine, its own management plane.

The tradeoff, which I only fully appreciated later: virtualizing the firewall protects only what routes *through* the VM. The Proxmox host underneath it is a separate machine on the same wire — see [Engineering notes](#-engineering-notes--lessons).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔌 Interfaces & zones

| Interface | Zone | Address | Role |
|-----------|------|---------|------|
| Port1 | LAN | `10.0.0.1/24` (static) | Gateway for the lab network |
| Port2 | WAN | `192.168.1.6/24` (DHCP from ISP) | Uplink — **behind ISP NAT** |
| GuestAP | WiFi | `10.255.0.1/24` (static) | Guest network — configured, never activated |

The WAN interface getting a *private* `192.168.1.x` address is the single most important fact about this network's shape: Sophos never had a real public IP of its own. Everything about the VPN design flows from that (see [`vpn.md`](./vpn.md)).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📶 DHCP

Two DHCP servers were defined:

- **`Default_DHCP_Server`** on Port1 — range `10.0.0.100–10.0.0.199`. This is the one that mattered: every dynamic client on the LAN got its lease here, and those leases were the input to the [self-built dynamic DNS pipeline](./BIND9.md).
- **`GuestAccess_DHCP`** on the GuestAP interface — range `10.255.0.2–10.255.0.254`. Configured but never put into service (the guest AP interface stayed unplugged).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🧭 DNS host records

Sophos kept its own small DNS host table for **static infrastructure** — the devices whose addresses never change:

| Host | Address |
|------|---------|
| `sophos.lab.lan` | `10.0.0.1` |
| `amerinfra.lab.lan` (Proxmox host) | `10.0.0.200` |
| `bind9.lab.lan` | `10.0.0.201` |
| `samba.lab.lan` | `10.0.0.202` |

This is deliberately *not* the same mechanism as the dynamic DNS. Static infra lived here (simple, never changes); dynamic clients were handled by BIND9 pulling DHCP leases. Two layers, split by device type — the reasoning is in [`BIND9.md`](./BIND9.md). Sophos's DNS API was locked down to accept calls only from BIND9's IP, since BIND9 was the only consumer.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔥 Firewall rules

The IPv4 rule set, top to bottom:

| # | Name | Source | Destination | Action |
|---|------|--------|-------------|--------|
| 1 | `fameri-sfw default` | LAN, VPN | LAN, WAN, VPN | Accept (DNS, HTTP/S, IKE, NTP, ping, SSH, TCP/UDP) |
| 2 | `Outgoing OCI_Tunnel` | Any, Homelab | VPN, OCI Subnet | Accept |
| 3 | `Incoming OCI_Tunnel` | VPN, OCI Subnet | Any, Homelab | Accept |
| 4 | `Drop all` | Any | Any | Drop (implicit default) |

A permissive default-accept posture for the trusted LAN and VPN zones on the common service set, two explicit bidirectional rules carving out the OCI tunnel traffic, and a final drop-all backstop. Rule #1 also had the security services (IPS, web filtering, NDR) bound to it — see below.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔀 NAT

- **`Default SNAT IPv4`** — masquerade for all LAN-originated traffic egressing Port2 (standard outbound NAT). This is the rule doing real work day to day.
- A linked NAT rule tied to the default firewall policy (`#NAT_Default_Network_Policy`), unused in practice.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔐 Security services

Layered onto the default firewall rule, more than a home network strictly needs — which was the point, since learning them was a goal:

- **IPS** — enabled, `lantowan_general` policy bound to the LAN→WAN rule.
- **Web filtering** — default policy with explicit blocks (malicious/explicit content, risky downloads); most category blocks left off, since this was a lab, not a filtered household.
- **Malware scanning** — HTTP + decrypted HTTPS scanning, zero-day protection on.
- **NDR / Active threat intelligence** — enabled, MDR threat feeds set to log-and-drop.
- **Application control** — a custom `fameri-sfw` application filter.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔑 VPN roles

Sophos served three VPN roles simultaneously — full detail in [`vpn.md`](./vpn.md):

1. **Site-to-site IPsec** to the OCI Ubuntu VM (`OCI_Tunnel`) — the main event.
2. **Remote-access SSL VPN** (`fameri_mb`) — the profile actually used day to day to reach the lab from outside.
3. **Remote-access IPsec** (`LaptopRemoteAccess`) — configured, tuned, but never put into real use.

Admin SSH into Sophos used public-key auth: two RSA keys were authorized — one for the BIND9 container's lease-sync automation, and a second key retained from early setup.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 💾 Backups

Sophos was set to email an **encrypted configuration backup weekly** (Fridays, 15:00), with the config encrypted under a password before leaving the box. A small thing, but a real one — even a home lab benefits from a config you can restore from, and doing it automatically beats remembering to.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛠️ Engineering notes & lessons

- **The firewall only protects what routes through it.** The Proxmox host underneath Sophos picked up its own globally-routable IPv6 address via router advertisement, on the same physical WAN bridge — a path Sophos never saw and therefore never filtered. Confirmed after the fact: the host's own `iptables`/`ip6tables` were completely empty. The lesson is architectural, not a config typo: a virtualized appliance secures its own traffic path, not the hypervisor it rides on. On a purpose-built firewall this doesn't arise; on a virtualized one sharing a host NIC, it's a real gap to design around.
- **The remote-access VPN pool overlapped the DHCP scope.** Both were `10.0.0.100–10.0.0.199` — a latent address-collision risk that never actually fired, but should have been a non-overlapping range from the start.
- **Two VPN profiles, one used.** Building both an IPsec and an SSL remote-access profile was useful for comparing them hands-on; in practice only the SSL profile (`fameri_mb`) got real use. Worth documenting honestly rather than implying both were load-bearing.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`vpn.md`](./vpn.md) — the site-to-site VPN, spanning this firewall and the OCI cloud side.
- [`BIND9.md`](./BIND9.md) — the dynamic DNS service fed by this firewall's DHCP leases.
- [`journey.md`](./journey.md) — how the firewall fit into the overall build.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`Sophos` · `firewall` · `SFVH` · `NAT` · `DHCP` · `IPS` · `web filtering` · `zones` · `IPsec` · `SSL VPN` · `Proxmox VM` · `double NAT` · `network security` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
