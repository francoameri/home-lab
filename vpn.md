# 🔐 Site-to-Site VPN — Home ⇄ Oracle Cloud

**A working IKEv2 IPsec tunnel between the home lab and an Oracle Cloud VM — and the double-NAT problem, solved with a DDNS indirection, that made it more than a copy-paste config.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [The core problem: no public IP](#-the-core-problem-no-public-ip)
3. [Technical reference](#-technical-reference)
   - [The cloud side (Oracle Cloud)](#the-cloud-side-oracle-cloud)
   - [OCI security list](#oci-security-list)
   - [Host firewall (StrongSwan side)](#host-firewall-strongswan-side)
   - [The home side (Sophos)](#the-home-side-sophos)
   - [Negotiated parameters](#negotiated-parameters)
   - [The StrongSwan config](#the-strongswan-config)
4. [Choosing the cloud provider](#-choosing-the-cloud-provider)
5. [Remote access VPN](#-remote-access-vpn)
6. [Engineering notes & lessons](#️-engineering-notes--lessons)
7. [Config files](#-config-files)
8. [Related documentation](#-related-documentation)
9. [Keywords](#️-keywords)
10. [License](#-license)

---

## 📖 Overview

The goal was a real site-to-site VPN — the kind linking a branch office to a data center — but between my home lab and an actual cloud environment, not a simulated peer. The result: an **IKEv2 IPsec tunnel** joining the home LAN (`10.0.0.0/24`) and an Oracle Cloud VCN (`172.16.0.0/16`), terminated by **Sophos** at home and **StrongSwan** on an Ubuntu VM in the cloud. In its final stretch it held **43 days** of continuous uptime.

The interesting part isn't the tunnel config — it's that the home end had no public IP to point at. The next section is the actual engineering; the technical reference after it has every parameter.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🎯 The core problem: no public IP

Sophos's WAN interface sat behind the ISP's NAT with a private `192.168.1.6`. A site-to-site tunnel normally points each end at the other's public address — but the home end didn't own one, and the ISP-assigned upstream address could change. The solution is a chain of three decisions, each following from the last:

1. **The cloud side has a stable public IP** (`164.152.249.176`) → so the **home side initiates** and the cloud side waits (Sophos gateway type: "initiate the connection"; StrongSwan `auto=add`, waiting).
2. **The cloud still needs to identify the home peer** without a fixed home IP → identify it by a **DNS hostname** (`fameri-lab.ddnsfree.com`), not an address (StrongSwan `right=fameri-lab.ddnsfree.com`, `rightid=@fameri-lab.ddnsfree.com`).
3. **That hostname must track the real public IP**, which Sophos behind NAT couldn't self-detect → run the **DynU DDNS updater as a cron job on the BIND9 container**, reaching an external service to learn the true public IP and keep the hostname current (see [`BIND9.md`](./BIND9.md#cron-jobs)).

So the tunnel's home identity is a *name a container keeps honest*, not an *address the firewall owns*. That indirection is the real work here — and it's a reusable pattern for any site-to-site VPN where one end is behind CGNAT or ISP NAT.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔧 Technical reference

### The cloud side (Oracle Cloud)

**Instance** (`ubuntu-lab`):

| Attribute | Value |
|-----------|-------|
| Shape | `VM.Standard.E2.1.Micro` (1 OCPU, 1 GB RAM) — Always Free |
| OS | Ubuntu 24.04 (`Canonical-Ubuntu-24.04-2026.02.28-0`) |
| Region | `sa-vinhedo-1` (Brazil) |
| Boot volume | 47 GB, in-transit encryption enabled |
| Private IP | `172.16.1.99` (reserved) |
| Public IP | `164.152.249.176` |
| StrongSwan | 5.9.13 |

**Network** — VCN `lab-vcn` (`172.16.0.0/16`), subnet `lab-subnet` (`172.16.1.0/24`, public/regional), internet gateway `lab-igw`. The default route table has two rules:

| Destination | Target | Purpose |
|-------------|--------|---------|
| `0.0.0.0/0` | Internet Gateway `lab-igw` | Default internet egress |
| `10.0.0.0/24` | Private IP `172.16.1.99` | **Home LAN → routed to the StrongSwan VM** |

That second route is what makes return traffic for the tunnel work: anything in OCI destined for the home LAN is routed to the VPN instance's private IP, which then sends it down the tunnel.

### OCI security list

Least-privilege where it counts — ingress rules (`181.116.210.114` = the home public IP at capture time):

| Source | Protocol | Port | Purpose |
|--------|----------|------|---------|
| `181.116.210.114/32` | TCP | 22 | SSH from home only |
| `181.116.210.114/32` | UDP | 500 | IKE handshake |
| `181.116.210.114/32` | UDP | 4500 | NAT traversal (NAT-T) |
| `10.0.0.0/24` | ICMP / TCP / UDP | all | Home LAN over the tunnel |
| `172.16.0.0/16` | UDP | 53 | Intra-VCN DNS (a `to_bind9` forwarding experiment) |
| `0.0.0.0/0` | TCP | 80, 443 | HTTP/S (broader than the VPN needs) |

Pinning IKE/NAT-T/SSH to the single home IP rather than `0.0.0.0/0` is the right instinct — the tunnel's control plane is only reachable from where it should originate.

### Host firewall (StrongSwan side)

The instance also ran its own `iptables` — Oracle's cloud-init default chain (protecting the `169.254.x` metadata service) plus explicit accepts for IKE (UDP 500), NAT-T (UDP 4500), ESP, and the home LAN. IPv6 was never configured on the VCN (`IPv6 Prefix: —`), so the empty `ip6tables` is a genuine non-issue here — there's no v6 to filter, unlike the [Proxmox host at home](./proxmox.md#️-engineering-notes--lessons).

### The home side (Sophos)

Policy-based IPsec connection `OCI_Tunnel`, on Sophos's stock `Clone_Branch office (IKEv2)` profile:

| Setting | Value |
|---------|-------|
| Connection type | Policy-based |
| Gateway type | **Initiate the connection** |
| Local ID | `fameri-lab.ddnsfree.com` (DNS type) |
| Remote gateway | `164.152.249.176` |
| Remote ID | `164.152.249.176` (IP) |
| Local subnet | `Homelab` = `10.0.0.0/24` |
| Remote subnet | `OCI Subnet` = `172.16.0.0/16` |

Two firewall rules (`Outgoing`/`Incoming OCI_Tunnel`) pass the traffic — see [`firewall.md`](./firewall.md#firewall-rules).

### Negotiated parameters

Both ends had to agree exactly — confirmed live from the running tunnel on both sides:

| Phase | Parameter | Value |
|-------|-----------|-------|
| IKE (Phase 1) | Encryption | AES-256 |
| | Integrity / PRF | HMAC-SHA2-256 |
| | DH group | 14 (MODP2048) |
| ESP (Phase 2) | Encryption | AES-256 |
| | Integrity | HMAC-SHA2-256 |
| Both | Key exchange | IKEv2 |
| | Authentication | Pre-shared key |
| | DPD | every 30s, action = restart |

**On the parameter choices:** DH group 14 (MODP2048) was the strongest group Sophos's *stock* IKEv2 profile and StrongSwan both offered without hand-writing custom proposals — a pragmatic "strongest common default" rather than pushing to a higher group and fighting mismatches. AES-256/SHA2-256 is a solid, widely-interoperable suite; the point was a working, secure tunnel, not chasing the theoretical maximum at the cost of interoperability.

### The StrongSwan config

The Ubuntu side mirrored Sophos exactly ([`configs/oci/ipsec.conf`](./configs/oci/ipsec.conf)):

```
conn cloud-to-home
    authby=secret
    auto=add
    keyexchange=ikev2
    left=172.16.1.99          # Private IP of the Ubuntu NIC
    leftid=164.152.249.176    # Public IP of OCI
    leftsubnet=172.16.0.0/16
    right=fameri-lab.ddnsfree.com     # DDNS hostname of home
    rightid=@fameri-lab.ddnsfree.com
    rightsubnet=10.0.0.0/24
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
```

Two details worth noting: `left=172.16.1.99` is the **private** IP (StrongSwan binds to the NIC's actual address; OCI's NAT maps the public IP to it), while `leftid=164.152.249.176` is the **public** identity the peer sees — getting that distinction right is a common StrongSwan-behind-cloud-NAT stumble. And `dpdaction=restart` (with the trailing `!` on the proposals forcing *exactly* these algorithms, no downgrade) is a big part of why the tunnel self-healed across 43 days: any interruption triggers a rebuild rather than a dead session.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🧪 Choosing the cloud provider

The endpoint didn't have to be Oracle — it landed there after trying the alternatives. AWS, GCP, and Azure all have free tiers, but each imposed limits (time-boxed trials, or shapes that don't stay free) that got in the way of running a *persistent, always-on* VPN peer without either hitting a wall or compromising the design. **Oracle Cloud's Always Free tier** allows a small always-on VM to run indefinitely — exactly what a site-to-site endpoint needs. Picking the right provider was part of the engineering, not a footnote.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 💻 Remote access VPN

Separate from the site-to-site tunnel, Sophos also provided remote access into the lab:

- **`fameri_mb` (SSL VPN)** — the profile actually used day to day. Permitted resources: BIND9, the Homelab subnet, and the OCI subnet.
- **`LaptopRemoteAccess` (IPsec)** — a fully tuned IKEv1 / Main-mode / AES-256 / DH14 road-warrior profile (client pool `10.0.0.100–10.0.0.199`, DNS `10.0.0.201`), built and compared but never put into real use. Note that client pool overlaps the DHCP scope — a latent bug, see [`firewall.md`](./firewall.md#️-engineering-notes--lessons).

Building both was a deliberate hands-on comparison of SSL vs. IPsec remote access; only one earned daily use.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛠️ Engineering notes & lessons

- **The double-NAT + DDNS chain is the real lesson.** Anyone can follow a site-to-site tutorial when both ends have public IPs. The instructive version is when one end doesn't — and the fix (initiate from the NAT'd side, identify it by DNS name, keep that name current from inside the network) is a genuinely reusable pattern for home labs and CGNAT'd sites.
- **StrongSwan's `_updown` script stacks iptables rules on reconnect.** Every tunnel bring-up re-inserted the IKE/NAT-T/ESP accept rules without removing the old ones; 43 days of reconnects left four near-identical copies of each. Harmless functionally, but "it works" ≠ "it's clean" — a longer-lived deployment wants an idempotent updown script or a periodic flush.
- **`systemctl status strongswan` returning "not found" is a red herring.** Ubuntu packages the daemon under a different unit name; `ipsec statusall` is the real health check. Knowing where to actually look saved chasing a non-problem.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📂 Config files

- [`configs/oci/ipsec.conf`](./configs/oci/ipsec.conf) — the StrongSwan tunnel definition.
- [`configs/oci/ipsec.secrets`](./configs/oci/ipsec.secrets) — the PSK declaration (redacted).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology diagram.
- [`firewall.md`](./firewall.md) — the Sophos side in full (rules, NAT, profiles).
- [`BIND9.md`](./BIND9.md) — the container running the DDNS updater that keeps this tunnel reachable.
- [`proxmox.md`](./proxmox.md) — the hypervisor hosting the home end.
- [`journey.md`](./journey.md) — the provider hunt and how the VPN fit the build.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`IPsec` · `site-to-site VPN` · `IKEv2` · `StrongSwan` · `Sophos` · `Oracle Cloud` · `OCI` · `double NAT` · `NAT traversal` · `NAT-T` · `DDNS` · `DynU` · `pre-shared key` · `MODP2048` · `DH group 14` · `AES-256` · `Dead Peer Detection` · `VCN` · `security list` · `route table` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
