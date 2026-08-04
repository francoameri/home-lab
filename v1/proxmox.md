# 🖥️ Proxmox VE — The Hypervisor Foundation

**The bare-metal layer everything else runs on: a single Dell laptop turned into a Type 1 hypervisor host, carrying a firewall VM and two service containers across two purpose-split disks and two purpose-split network bridges.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Technical reference](#-technical-reference)
   - [Host hardware](#host-hardware)
   - [Storage layout](#storage-layout)
   - [Network bridges](#network-bridges)
   - [Guests](#guests)
   - [VM vs LXC — why each workload got what it got](#vm-vs-lxc--why-each-workload-got-what-it-got)
3. [Engineering notes & lessons](#️-engineering-notes--lessons)
4. [Config files](#-config-files)
5. [Related documentation](#-related-documentation)
6. [Keywords](#️-keywords)
7. [License](#-license)

---

## 📖 Overview

Everything in this lab rode on one repurposed Dell laptop running **Proxmox VE 9.2.3** bare-metal. Rather than a desktop OS with virtualization bolted on, this was a real Type 1 hypervisor: the firewall, the DNS service, and the file share were all guests on top of it, isolated from each other, each getting exactly the resources its job needed.

The two design decisions worth understanding up front — because everything else follows from them — are the **two-disk storage split** (a small system disk for Proxmox itself, a larger SSD dedicated to guest storage) and the **two-bridge network split** (one bridge carrying only WAN traffic to the firewall VM, one carrying the LAN shared by the host and containers). The rest of this doc is the detail behind those two choices.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔧 Technical reference

### Host hardware

| Component | Spec |
|-----------|------|
| Model | Dell laptop |
| CPU | Intel Core **i7-6700HQ** — 4 cores / 8 threads @ 2.60 GHz |
| RAM | 16 GB DDR3 (~15 GiB usable) |
| Disk 1 | ~120 GB — Proxmox host (root + swap) |
| Disk 2 | ~233 GB SSD — guest storage (LVM-thin) |
| Hypervisor | Proxmox VE 9.2.3, kernel 7.0.6-2-pve |

The i7-6700HQ's hardware virtualization (VT-x) is what makes running a full firewall appliance as a guest practical on a laptop — the Sophos VM gets `cpu: x86-64-v2-AES`, exposing AES-NI through to the guest so its crypto (VPN, HTTPS scanning) runs on native instructions rather than emulated.

### Storage layout

Two volume groups, one per physical disk — a deliberate split of host state from guest state:

```
pve      VG (118G)  ── root (110G, ext4, Proxmox host)
                    └─ swap (8G)

ssd-vg   VG (233G)  ── ssd-thin (200G LVM-thin pool)
                        ├─ vm-100-disk-0 (30G) → Sophos VM
                        ├─ vm-101-disk-0 (4G)  → BIND9 LXC
                        └─ vm-103-disk-0 (5G)  → Samba LXC
```

Guests live on an **LVM-thin pool** (`ssd-thin`), which is what enables thin provisioning — the three guests are *provisioned* at 39 GB total but only *consume* what they actually write (the pool sat at ~11% used). Thin provisioning on a lab with modest disk is the difference between comfortably running three guests and constantly juggling space.

Storage is defined in [`configs/proxmox/storage.cfg`](./configs/proxmox/storage.cfg): `local` (dir) holds ISOs, templates, and backups; `ssd-thin` (lvmthin) holds guest disks and container root filesystems.

### Network bridges

Two Linux bridges, split by purpose — this is the core of the network design:

| Bridge | Purpose | Backing NIC | Address |
|--------|---------|-------------|---------|
| `vmbr0` | **WAN — Sophos VM only** | `nic0` (onboard Ethernet) | none on host (manual) |
| `vmbr1` | **LAN — Sophos + host + LXCs** | `enx7cc2c6449e1b` (USB Ethernet) | `10.0.0.200/24` |

The reason there are two: the Sophos VM needs a WAN interface *and* a LAN interface, and those must be electrically separate — WAN traffic should never touch the LAN bridge directly. `vmbr0` exists purely to hand the firewall VM its uplink; nothing else is attached to it. `vmbr1` is the actual lab LAN, shared by the Proxmox host (so it's manageable at `10.0.0.200`) and the two containers.

Full config in [`configs/proxmox/interfaces`](./configs/proxmox/interfaces).

### Guests

| ID | Name | Type | vCPU | RAM | Disk | Role |
|----|------|------|------|-----|------|------|
| 100 | `fameri-sfw.lab.lan` | **VM** (KVM) | 2 | 8192 MB | 30G | Sophos firewall |
| 101 | `bind9.lab.lan` | **LXC** (unpriv.) | 1 | 128 MB | 4G | Dynamic DNS |
| 103 | `samba.lab.lan` | **LXC** (unpriv.) | 1 | 128 MB | 5G | File share |

Note the resource asymmetry: the firewall gets 8 GB and 2 cores because it's running a full appliance OS with crypto and DPI; the two containers get 128 MB each because a DNS resolver and an SMB daemon genuinely need almost nothing. That's the practical payoff of the VM-vs-LXC split below.

Interesting config details in the guest files:
- **VM 100** boots off SATA-emulated disks (`sata0`), not virtio-blk — Sophos's installer is happier with an emulated controller. Both NICs *are* virtio (`net0` on vmbr1/LAN, `net1` on vmbr0/WAN) for throughput. Full config: [`configs/proxmox/100.conf`](./configs/proxmox/100.conf).
- **LXC 103 (Samba)** has `firewall=1` on its NIC — Proxmox's per-container firewall enabled — while **LXC 101 (BIND9)** does not. The higher-risk SMB service got the extra isolation layer. Configs: [`101.conf`](./configs/proxmox/101.conf), [`103.conf`](./configs/proxmox/103.conf).
- Both LXCs are `unprivileged: 1` with `nesting=1`, and `onboot: 1` so the whole lab comes back up after a host reboot in dependency-friendly order.

### VM vs LXC — why each workload got what it got

This split is the single most important resource decision in the lab, so it's worth stating the reasoning explicitly (this is the kind of "non-default choice" worth explaining):

- **Sophos → full VM.** A firewall appliance ships its own kernel and OS; it can't run as a container. It needs hardware-level isolation, its own network stack, and direct-ish access to virtual NICs. KVM is the only option, and it's why this guest costs 8 GB.
- **BIND9 & Samba → LXC.** Both are ordinary Linux daemons that don't need their own kernel. Running them as unprivileged LXCs instead of VMs means near-zero overhead (128 MB each vs. what a full VM would demand), instant start, and they still get real isolation. On a 16 GB laptop already spending 8 GB on the firewall, this is what makes running everything simultaneously feasible.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛠️ Engineering notes & lessons

- **The host shares a NIC with the firewall's WAN — and that has consequences.** `vmbr0` bridges the onboard NIC for Sophos's WAN, but the Proxmox host itself, on `vmbr1`, still picked up a globally-routable IPv6 address via router advertisement on the underlying link. The host had no `ip6tables` rules of its own, so it sat on IPv6 unfiltered, entirely outside Sophos's view. The lesson: on a virtualized-firewall design, the hypervisor is a separate host on the wire, not something the firewall VM automatically protects. A dedicated appliance sidesteps this; a virtualized one needs the host itself hardened too.
- **Thin provisioning is a "watch it" feature, not a free lunch.** Provisioning 39 GB of guests on a 200 GB thin pool is fine — until guests actually fill their disks and the *pool* fills before the guests report full. It never bit this lab (11% used), but on a thin pool you monitor the pool, not just the guests.
- **`onboot: 1` everywhere means boot order matters.** Everything auto-starts, which is convenient, but there's no explicit start-order/delay configured — the containers depend on Sophos (their gateway and DHCP) being up first. It worked in practice, but a `startup:` order/delay would have made that dependency explicit rather than incidental.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📂 Config files

- [`configs/proxmox/interfaces`](./configs/proxmox/interfaces) — the two-bridge network config.
- [`configs/proxmox/storage.cfg`](./configs/proxmox/storage.cfg) — storage definitions.
- [`configs/proxmox/100.conf`](./configs/proxmox/100.conf) — Sophos VM.
- [`configs/proxmox/101.conf`](./configs/proxmox/101.conf) — BIND9 LXC.
- [`configs/proxmox/103.conf`](./configs/proxmox/103.conf) — Samba LXC.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`firewall.md`](./firewall.md) — the Sophos VM (guest 100) in full.
- [`BIND9.md`](./BIND9.md) — the BIND9 LXC (guest 101).
- [`Samba.md`](./Samba.md) — the Samba LXC (guest 103).
- [`journey.md`](./journey.md) — where Proxmox fit into the build story.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔑 Keywords

`Proxmox VE` · `virtualization` · `Type 1 hypervisor` · `KVM` · `LXC` · `LVM-thin` · `thin provisioning` · `Linux bridge` · `vmbr` · `unprivileged container` · `i7-6700HQ` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

✍️ Authored by **Franco [francoameri]**
📜 Licensed under [CC BY 4.0](https://github.com/francoameri/francoameri/blob/main/LICENSE.md)
Please credit the original author when sharing or adapting this work.
