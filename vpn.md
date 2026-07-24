# 🔐 Site-to-Site VPN — Home ⇄ Oracle Cloud

**A working IPsec site-to-site tunnel between the home lab and a cloud VM — and the double-NAT problem that made it more interesting than a copy-paste config.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [The core problem: no public IP](#-the-core-problem-no-public-ip)
3. [The cloud side (Oracle Cloud)](#️-the-cloud-side-oracle-cloud)
4. [The home side (Sophos)](#-the-home-side-sophos)
5. [Tunnel parameters](#-tunnel-parameters)
6. [Choosing the cloud provider](#-choosing-the-cloud-provider)
7. [Remote access VPN](#-remote-access-vpn)
8. [Engineering notes & lessons](#️-engineering-notes--lessons)
9. [Related documentation](#-related-documentation)
10. [Keywords](#️-keywords)
11. [License](#-license)

---

## 📖 Overview

The goal was a real site-to-site VPN — the kind that links a branch office to a data center — but between my home lab and an actual cloud environment, not a simulated peer. The result: an **IKEv2 IPsec tunnel** joining the home LAN (`10.0.0.0/24`) and an Oracle Cloud VCN (`172.16.0.0/16`), terminated by **Sophos** at home and **StrongSwan** on an Ubuntu VM in the cloud.

In its final stretch of life the tunnel stayed up continuously for **43 days** — a good sign the design was stable, not just barely working.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🎯 The core problem: no public IP

The whole design hinges on one constraint: **Sophos never had a public IP.** Its WAN interface sat behind the ISP's own NAT, getting a private `192.168.1.6`. A site-to-site tunnel normally points each end at the other's public address — but the home end didn't have one to point at, and worse, that address (whatever the ISP assigned upstream) could change.

The chain of reasoning that solved it:

1. **The cloud side has a stable public IP** (`164.152.249.176`) — so it makes sense for the home side to *initiate* the connection, and the cloud side to wait for it.
2. **But the cloud side still needs to identify the home peer** — and can't rely on a fixed home IP. Solution: identify the home end by a **DNS hostname** (`fameri-lab.ddnsfree.com`) instead of an IP.
3. **That hostname needs to track the real public IP** — which Sophos, sitting behind NAT, couldn't reliably detect about itself. Solution: run the **DynU DDNS updater as a cron job on the BIND9 container**, which reaches out to an external service to learn the true public-facing address and keeps the hostname current.

So the tunnel's home identity is a name that a container keeps honest, not an address the firewall owns. That indirection is the actual engineering in this build.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## ☁️ The cloud side (Oracle Cloud)

**Instance**
- `ubuntu-lab` — `VM.Standard.E2.1.Micro` (1 OCPU, 1GB RAM), Always Free tier.
- Ubuntu 24.04, region `sa-vinhedo-1` (Brazil), 47GB boot volume, in-transit encryption enabled.
- Private IP `172.16.1.99`, public IP `164.152.249.176`.

**Network (VCN `lab-vcn`)**
- CIDR `172.16.0.0/16`, subnet `lab-subnet` `172.16.1.0/24` (public/regional).
- Internet gateway `lab-igw`; default route table sends `0.0.0.0/0` to the IGW and `10.0.0.0/24` (the home LAN) to the instance's private IP — so return traffic for the tunnel routes correctly.

**Security list** — least-privilege where it counts:
- SSH (22), IKE (UDP 500), NAT-T (UDP 4500) allowed **only from the home public IP** (`181.116.210.114/32`).
- ICMP + full TCP/UDP allowed from the home LAN (`10.0.0.0/24`) over the tunnel.
- DNS (UDP 53) from within the VCN, for a DNS-forwarding experiment (`to_bind9`).
- HTTP/HTTPS/ICMP open publicly — broader than the VPN strictly needs.

**Host firewall** — the instance also ran its own `iptables` (Oracle's cloud-init default chain protecting the metadata service, plus explicit IKE/NAT-T/ESP accepts). IPv6 was never configured on the VCN, so the empty `ip6tables` is a non-issue here — there's simply no v6 to filter.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏠 The home side (Sophos)

Configured as a **policy-based IPsec connection** (`OCI_Tunnel`), using Sophos's stock `Clone_Branch office (IKEv2)` profile:

- Gateway type: **initiate the connection** (home dials out, per the reasoning above).
- Local ID: `fameri-lab.ddnsfree.com` (DNS type) — not an IP.
- Remote gateway: `164.152.249.176`, remote ID by IP address.
- Local subnet: `Homelab` (`10.0.0.0/24`); remote subnet: `OCI Subnet` (`172.16.0.0/16`).
- Two matching firewall rules (`Outgoing`/`Incoming OCI_Tunnel`) pass the traffic — see [`firewall.md`](./firewall.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📐 Tunnel parameters

Both ends had to agree exactly — confirmed live from both sides:

| Parameter | Value |
|-----------|-------|
| Key exchange | IKEv2 |
| Authentication | Pre-shared key |
| IKE (Phase 1) | AES-256 / SHA2-256 / DH group 14 (MODP2048) |
| ESP (Phase 2) | AES-256 / SHA2-256 |
| Tunnel | `172.16.0.0/16` ⇄ `10.0.0.0/24` |
| Dead Peer Detection | every 30s, restart on failure |

The StrongSwan config on the Ubuntu side (`/etc/ipsec.conf`) mirrored this exactly, with `dpdaction=restart` so the tunnel would re-establish itself after any interruption — which is a big part of how it held 43 days of uptime.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🧪 Choosing the cloud provider

The VPN endpoint didn't have to be Oracle — it ended up there after actually trying the alternatives. AWS, GCP, and Azure all have free tiers, but each imposed limits that got in the way of running a persistent VPN peer the way I wanted, without either hitting a time limit or compromising the design to fit inside a trial. **Oracle Cloud's Always Free tier** turned out to be the one that let a small always-on VM run indefinitely, which is exactly what a site-to-site tunnel endpoint needs. Picking the right provider *was* part of the work.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 💻 Remote access VPN

Separate from the site-to-site tunnel, Sophos also provided remote access back into the lab from outside:

- **`fameri_mb` (SSL VPN)** — the profile actually used day to day to reach the lab remotely.
- **`LaptopRemoteAccess` (IPsec)** — a fully tuned road-warrior profile (IKEv1, AES-256, DH14) that was built and compared but never put into real use.

Building both was a deliberate way to understand the difference between SSL and IPsec remote access hands-on; only one earned a place in daily use.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛠️ Engineering notes & lessons

- **The double-NAT + DDNS chain is the real lesson here.** Anyone can follow a site-to-site VPN tutorial when both ends have public IPs. The interesting version is when one end doesn't — and the fix (initiate from the NAT'd side, identify it by a DNS name, keep that name current from inside the network) is a genuinely reusable pattern.
- **StrongSwan's `_updown` script stacks iptables rules on reconnect.** Every time the tunnel came up, StrongSwan re-inserted its IKE/NAT-T/ESP accept rules without removing the old ones. Over 43 days of reconnects, the host's iptables ended up with four near-identical copies of each rule. Harmless functionally, but a good reminder that "it works" and "it's clean" aren't the same thing — worth a periodic flush or an idempotent updown script in a longer-lived deployment.
- **`systemctl status strongswan` returning "not found" is a red herring.** Ubuntu packages the daemon under a different unit name; `ipsec statusall` is the real health check. Knowing where to actually look saved chasing a non-problem.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology diagram.
- [`firewall.md`](./firewall.md) — the Sophos side in full (rules, NAT, profiles).
- [`journey.md`](./journey.md) — the provider hunt and how the VPN fit the overall build.
- [`BIND9.md`](./BIND9.md) — the container that also runs the DDNS updater keeping this tunnel reachable.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`IPsec` · `site-to-site VPN` · `IKEv2` · `StrongSwan` · `Sophos` · `Oracle Cloud` · `OCI` · `double NAT` · `NAT traversal` · `DDNS` · `DynU` · `pre-shared key` · `Dead Peer Detection` · `VCN` · `security list` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
