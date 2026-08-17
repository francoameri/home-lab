# 🖥️ Proxmox — Hypervisor, Storage, and VLAN-Aware Networking

Hardware, storage strategy, the networking design that lets one bridge serve both host-level and guest-level VLAN membership, and the reasoning behind where Proxmox itself sits in the network. Cross-references to the main [`README.md`](README.md) use `§N` notation for its numbered sections.

---

## Table of Contents

1. [Hardware](#hardware)
2. [Storage](#storage)
3. [Networking: one bridge, two VLAN mechanisms](#networking-one-bridge-two-vlan-mechanisms)
4. [Where Proxmox lives on the network — and why](#where-proxmox-lives-on-the-network--and-why)
5. [Guests](#guests)
6. [Known issues & lessons](#known-issues--lessons)

---

## Hardware

HP EliteDesk Mini 600 G6 (i5-10500T). ZFS root.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Storage

`local-zfs` — ZFS-backed, inherently thin-provisioned by default, unlike VM zvols which need it configured explicitly. All container rootfs volumes live here. A dedicated bay is reserved for a future local Proxmox Backup Server datastore once the NAS build frees it up (see main [`README.md` §Planned](README.md#-planned--not-yet-built)) — Tier-1, fast local restore, with the NAS becoming Tier-2 off-box backup afterward.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Networking: one bridge, two VLAN mechanisms

`vmbr0` runs with `bridge-vlan-aware yes` and an explicit `bridge-vids` range, which unlocks two different ways of putting something onto a specific VLAN through the same physical trunk port:

- **Per-guest tagging.** An LXC container's own `net0` line can specify `tag=N` directly (e.g., `tag=30` for SERVERS) — the vlan-aware bridge handles tagging/untagging traffic to and from that specific guest's virtual NIC, with no separate interface needed per VLAN per guest.
- **A dedicated host-level VLAN sub-interface.** For the Proxmox *host's own* management IP, a classic 802.1Q sub-interface (`vmbr0.30`) rides on top of the same bridge, giving the hypervisor itself a tagged presence on SERVERS without needing its own physical port.

```
auto vmbr0
iface vmbr0 inet manual
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094

auto vmbr0.30
iface vmbr0.30 inet static
        address 192.168.130.253/24
        gateway 192.168.130.254
        vlan-raw-device vmbr0
```

Both mechanisms coexist cleanly on the same bridge and the same physical trunk port (the switch's `Proxmox-Trunk` profile, tagged for SERVERS — see [`unifi.md`](unifi.md)) — there's no conflict between "the host has a tagged IP" and "guests get their own tags," since they're handled by different layers of the same bridge.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Where Proxmox lives on the network — and why

Proxmox's management IP initially sat on the untagged native (MGMT) segment, alongside OPNsense's own base interface, the switch, and the AP — simply because that's where it happened to land during initial provisioning, before VLAN segmentation existed yet. Once VLANs were live, this became a real architectural question worth resolving deliberately rather than leaving as an accident of history: MGMT's entire design purpose is staying the one segment never touched during VLAN work, so a mistake anywhere else can't strand access to the core network gear needed to fix it. A hypervisor running actual production-ish workloads doesn't fit that "core network gear, nothing else" description — it's a workload, not infrastructure you'd use to rescue a broken VLAN.

The alternative considered was dual-homing — giving Proxmox a secondary address on MGMT as an out-of-band fallback, in addition to its primary SERVERS VLAN address, for resilience if SERVERS-side routing or firewall rules ever broke. That idea didn't survive scrutiny: since normal day-to-day access to Proxmox comes from TRUSTED (routed through OPNsense, which already has a full bidirectional Pass rule between TRUSTED and SERVERS), a working fallback IP would need to be reachable from TRUSTED too — and if it's reachable from TRUSTED, the isolation benefit MGMT was supposed to preserve is already gone. A fallback that only works when physically local isn't a fallback for a remotely-managed hypervisor; it's just a second address that adds attack surface without adding real resilience.

Proxmox's management IP now lives entirely on SERVERS (VLAN 30), with no presence on MGMT at all. The tradeoff accepted deliberately: if SERVERS VLAN routing or firewall config ever breaks, the hypervisor becomes unreachable over the network, full stop — local console access becomes the only way in. Clean isolation, at the cost of losing a network-based break-glass path for the hypervisor specifically (core network gear — the firewall, switch, and AP — keep theirs on MGMT, unaffected).

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Guests

| VMID | Hostname     | Role                                   | Network                  | Status         |
| ----- | ------------ | ---------------------------------------- | -------------------------- | --------------- |
| 200   | —            | UniFi Network Application (Docker-based) | SERVERS `.200`            | Destroyed (superseded by 201) |
| 201   | `unifi-os`   | UniFi OS Server (Podman, privileged LXC) | SERVERS `.201`, tag 30    | Live           |

`CT 201` runs as a **privileged** LXC — a deliberate, documented exception to running everything unprivileged by default, required because UniFi OS Server's installer needs to write a specific sysctl that the kernel refuses from a non-initial user namespace (i.e., any unprivileged container). Full reasoning and the debugging path that led to this conclusion are in [`unifi.md`](unifi.md).

Container-to-IP convention: where practical, a container's last-two-IP-digits match its Proxmox VMID (`CT 201` → `.201`), making the relationship between "which container is this" and "what's its address" readable at a glance without needing to look anything up.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Known issues & lessons

- **`/etc/hosts` doesn't follow interface IP changes automatically.** Changing a host's network config updates routing and reachability, but any hostname-to-IP mapping baked into `/etc/hosts` stays stale until manually updated — worth checking any time a host's own IP moves, not just the interface config itself.
- **`ifreload -a` applies interface changes without a full reboot, but still drops the current session** if the interface you're connected through is the one being changed — functionally identical to a reboot from the perspective of "will this session survive," even though the rest of the system stays running throughout.
- **A container's IP and its VMID drift apart over time if not enforced.** The convention only holds if it's actively maintained during provisioning and renumbering — it's not something Proxmox tracks or enforces on its own.
- **Flipping `unprivileged: 0`/`1` on an existing container changes UID mapping going forward, but not retroactively** — see [`unifi.md`](unifi.md) for what happens when that assumption is wrong.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>
