# 🛡️ Sophos Firewall Configuration

**The virtualized edge of the lab — a Sophos Home Firewall running as a Proxmox VM, handling routing, NAT, DHCP, DNS host records, three VPN roles, and a full stack of layered security services for the entire network.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Technical reference](#-technical-reference)
   - [Platform & edition](#platform--edition)
   - [Interfaces & zones](#interfaces--zones)
   - [DHCP](#dhcp)
   - [DNS host records](#dns-host-records)
   - [Firewall rules](#firewall-rules)
   - [NAT](#nat)
   - [Security services](#security-services)
   - [Local service ACL & admin access](#local-service-acl--admin-access)
   - [Backups](#backups)
3. [VPN roles](#-vpn-roles)
4. [Engineering notes & lessons](#️-engineering-notes--lessons)
5. [Config files](#-config-files)
6. [Related documentation](#-related-documentation)
7. [Keywords](#️-keywords)
8. [License](#-license)

---

## 📖 Overview

Sophos ran as a VM inside Proxmox (`10.0.0.1`), acting as the gateway for the entire `10.0.0.0/24` LAN — routing, NAT, DHCP, DNS for static hosts, VPN termination, and layered security all in one guest. Virtualizing it rather than buying an appliance was the whole point: the goal was to *learn* an enterprise-class firewall hands-on, and running it as a VM meant the whole edge lived on the same laptop as everything it protected while still behaving like a real standalone appliance.

The technical reference below is the full configuration as it actually ran. The VPN spans both this firewall and the cloud, so it gets its own document — [`vpn.md`](./vpn.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔧 Technical reference

### Platform & edition

Free/registered **Sophos Home Firewall**, model `SFVH` — worth stating plainly rather than implying a paid enterprise license. It's genuinely capable regardless: full firewall policy engine, IPS, web filtering, application control, NDR threat intelligence, and both IPsec and SSL VPN. Ran as VM guest 100 (2 vCPU, 8 GB RAM) — see [`proxmox.md`](./proxmox.md) and [`configs/proxmox/100.conf`](./configs/proxmox/100.conf).

### Interfaces & zones

| Port | Zone | Address | Assignment | Role |
|------|------|---------|-----------|------|
| Port1 | LAN | `10.0.0.1/24` | Static | Gateway for the lab |
| Port2 | WAN | `192.168.1.6/24` | DHCP from ISP | Uplink — **behind ISP NAT** |
| GuestAP | WiFi | `10.255.0.1/24` | Static | Guest net — configured, never activated |

The WAN interface holding a **private** `192.168.1.6` is the defining fact of this network: Sophos had no public IP of its own, it sat behind the ISP's NAT (a Claro-Telmex router). Every design decision in [`vpn.md`](./vpn.md) flows from that constraint. WAN link tracked as `Claro-Telmex Link`, gateway `192.168.1.1`.

### DHCP

Two DHCP servers defined:

- **`Default_DHCP_Server`** (Port1) — range `10.0.0.100–10.0.0.199`, handing out `10.0.0.201` (BIND9) as DNS via Option 6. These leases are the input to the [dynamic DNS pipeline](./BIND9.md).
- **`GuestAccess_DHCP`** (GuestAP) — range `10.255.0.2–10.255.0.254`. Configured but never in service (the guest AP interface stayed unplugged).

### DNS host records

Static infrastructure got fixed hostname records directly in Sophos's own DNS host table — the counterpart to BIND9's dynamic side:

| Host | Address |
|------|---------|
| `sophos.lab.lan` | `10.0.0.1` |
| `amerinfra.lab.lan` | `10.0.0.200` |
| `bind9.lab.lan` | `10.0.0.201` |
| `samba.lab.lan` | `10.0.0.202` |

The reasoning for splitting static (here) from dynamic (BIND9) is in [`BIND9.md`](./BIND9.md#-two-dns-layers-by-design). Sophos's DNS/API access was restricted to accept calls only from BIND9's IP (`10.0.0.201`), since BIND9 was the sole consumer of the DHCP lease data.

### Firewall rules

IPv4 rules, evaluated top-down (first match wins), with an implicit drop at the bottom:

| # | Name | Source zones | Dest zones | Services | Action |
|---|------|-------------|-----------|----------|--------|
| 1 | `fameri-sfw default` | LAN, VPN | LAN, WAN, VPN | DNS, HTTP/S, IKE, NTP, ping, SSH, TCP, UDP | Accept |
| 2 | `Outgoing OCI_Tunnel` | Any, Homelab | VPN, OCI Subnet | Any | Accept |
| 3 | `Incoming OCI_Tunnel` | VPN, OCI Subnet | Any, Homelab | Any | Accept |
| 4 | `Drop all` | Any | Any | Any | **Drop** |

Rule 1 is a permissive default-accept for the trusted LAN/VPN zones on a defined service set — appropriate for a lab, less so for production. Rules 2–3 explicitly carve out bidirectional traffic for the site-to-site tunnel. Rule 1 also carried the security services (IPS `lantowan_general`, web filtering, NDR) — logging enabled, so matched traffic was recorded.

### NAT

- **`Default SNAT IPv4`** — masquerade for all LAN-originated traffic egressing Port2. The workhorse rule (10K+ hits observed).
- **`#NAT_Default_Network_Policy`** — the auto-created default, linked to firewall rule 2, effectively unused.

### Security services

Layered onto rule 1 — more than a home LAN strictly needs, which was the point since learning them was a goal:

| Service | Configuration |
|---------|--------------|
| **IPS** | Enabled; `lantowan_general` policy on the LAN→WAN rule |
| **Web filtering** | Default policy; explicit blocks for malicious/explicit content + risky/suspicious downloads; most category blocks left off (lab, not a filtered household) |
| **Malware scanning** | HTTP + decrypted-HTTPS scanning, zero-day protection on |
| **Application control** | Custom `fameri-sfw` filter |
| **NDR / threat intel** | Active threat intelligence on; MDR threat feeds set to **log-and-drop** |

### Local service ACL & admin access

The zone-based local service ACL followed least-exposure on WAN: from the **WAN** zone, only IPsec, SSL VPN, and ping were permitted inbound — admin HTTPS/SSH were **not** reachable from WAN, only from LAN/VPN. Admin SSH used **public-key auth** (two RSA keys authorized: one for BIND9's lease-sync automation, `root@bind9`; a second retained from early setup). This matters: it means the management plane was never exposed to the internet, only reachable from inside the trusted zones or over VPN.

### Backups

Automated **encrypted configuration backup, emailed weekly** (Fridays 15:00), config encrypted under a password before leaving the box, prefix `fameri-sfw`. Even in a lab, an automatic restore point beats remembering to make one.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔑 VPN roles

Sophos served three VPN roles at once — full detail in [`vpn.md`](./vpn.md):

1. **Site-to-site IPsec** (`OCI_Tunnel`) to the Oracle Cloud VM — the main event. IKEv2, PSK, using Sophos's stock `Clone_Branch office (IKEv2)` profile.
2. **Remote-access SSL VPN** (`fameri_mb`) — the profile actually used day to day to reach the lab from outside.
3. **Remote-access IPsec** (`LaptopRemoteAccess`) — a fully tuned IKEv1 road-warrior profile, built and compared but never put into real use.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛠️ Engineering notes & lessons

- **A virtualized firewall protects its traffic path, not the hypervisor.** The Proxmox host underneath Sophos picked up a globally-routable IPv6 address via router advertisement on the shared WAN bridge — a path Sophos never saw or filtered (confirmed: the host's own `iptables`/`ip6tables` were empty). This is architectural, not a config typo: on a dedicated appliance it doesn't arise; on a virtualized one sharing a host NIC, the host itself needs hardening too. Full detail in [`proxmox.md`](./proxmox.md#️-engineering-notes--lessons).
- **The remote-access VPN pool overlapped the DHCP scope** — both `10.0.0.100–10.0.0.199`. A latent address-collision risk that never fired but should have been a separate range from the start.
- **Two remote-access profiles, one used.** Building both IPsec and SSL remote-access profiles was a deliberate way to compare them hands-on; only the SSL one (`fameri_mb`) earned daily use. Documented honestly rather than implying both were load-bearing.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📂 Config files

- [`configs/proxmox/100.conf`](./configs/proxmox/100.conf) — the Sophos VM definition (2 vCPU / 8 GB / dual NICs on vmbr0+vmbr1).
- Sophos's own configuration lived inside the appliance (managed via its web UI, backed up via the encrypted email backup described above) rather than as flat files on the host — so the reference above is drawn from the live config, not a committable text file.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`vpn.md`](./vpn.md) — the site-to-site VPN, spanning this firewall and Oracle Cloud.
- [`proxmox.md`](./proxmox.md) — the hypervisor and the VM this runs as.
- [`BIND9.md`](./BIND9.md) — the dynamic DNS fed by this firewall's DHCP leases.
- [`journey.md`](./journey.md) — how the firewall fit into the overall build.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`Sophos` · `firewall` · `SFVH` · `zones` · `NAT` · `SNAT` · `DHCP` · `IPS` · `web filtering` · `application control` · `NDR` · `local service ACL` · `IPsec` · `SSL VPN` · `public-key auth` · `Proxmox VM` · `double NAT` · `network security` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
