# 📡 UniFi — Switch, AP, and the Self-Hosted Controller Migration

Adoption, port profiles, SSIDs, and the full story of moving from a self-hosted UniFi Network Application to Ubiquiti's newer self-hosted UniFi OS Server — including the kernel-level troubleshooting it took to get there. Cross-references to the main [`README.md`](README.md) use `§N` notation for its numbered sections.

---

## Table of Contents

1. [Overview](#overview)
2. [Switch and AP adoption](#switch-and-ap-adoption)
3. [Port profiles](#port-profiles)
4. [SSIDs](#ssids)
5. [The controller migration](#the-controller-migration)
6. [IP renumbering](#ip-renumbering)
7. [mDNS/SSDP reflection for cross-VLAN casting](#mdnsssdp-reflection-for-cross-vlan-casting)
8. [Known issues & lessons](#known-issues--lessons)

---

## Overview

The switch and AP are both Ubiquiti UniFi gear, which means neither one has any useful standalone local management — out of the box, a UniFi switch is a plain unmanaged L2 device with everything on the native VLAN, and VLAN-aware port profiles only exist once a UniFi controller adopts it. That controller needed to be self-hosted (no cloud gateway/key in this build), which is what makes this component more involved than "plug in switch, configure ports."

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Switch and AP adoption

Both devices were adopted via `set-inform` pointed at the self-hosted controller's inform endpoint (`http://<controller-ip>:8080/inform`), run directly over SSH on each device rather than relying purely on L2 discovery — more reliable when the controller sits behind Docker's network stack rather than bound directly to a host interface. The controller's **Inform Host Override** setting (Settings → System → search "inform") had to be set explicitly to the controller's real reachable IP; without it, devices see the controller's internal container IP instead and adoption never sticks.

Both devices needed to be re-pointed with a fresh `set-inform` every time the controller's IP changed — which happened three times over the course of this build (initial deployment, migration to UniFi OS Server, and the later SERVERS VLAN renumbering, see [`proxmox.md`](proxmox.md)). Each time, both devices reconnected automatically without needing to go through the full adopt-from-pending flow again, since they were already associated with that controller's identity — only the endpoint address needed updating.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Port profiles

| Profile          | Port(s) | Mode           | Native VLAN | Tagged VLANs           |
| ----------------- | -------- | --------------- | ------------ | ------------------------ |
| `Uplink-Trunk`    | 16       | Infrastructure | Default      | Allow All (to OPNsense) |
| `AP-Trunk`        | 1        | Infrastructure | Default      | TRUSTED, GUEST, IOT     |
| `Proxmox-Trunk`   | 15       | Infrastructure | Default      | SERVERS                |
| `Trusted-Access`  | 9–12     | Edge, Block All tagged | TRUSTED      | —                       |

`Uplink-Trunk` is deliberately `Allow All` rather than a custom tagged list — it's the port facing OPNsense itself, which needs to see every VLAN regardless of what gets added later, so there's nothing to maintain here as new VLANs appear. Every other trunk profile is `Custom`, carrying only the specific VLANs that device actually needs — `Proxmox-Trunk` doesn't carry IOT, TRUSTED, or GUEST, since nothing on the Proxmox host consumes any of those.

`Trusted-Access` is an Edge port profile (not Infrastructure) with tagged VLAN management set to Block All — appropriate for ports facing end-user client devices rather than other network infrastructure, and it native-VLANs those ports directly onto TRUSTED.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## SSIDs

Three SSIDs, one per client-facing VLAN:

- **Primary trusted network** → TRUSTED (VLAN 20).
- **Guest network** → GUEST (VLAN 50), with guest isolation enabled at the SSID level in addition to the firewall-level isolation on the VLAN itself — belt and suspenders.
- **`IoT`** → IOT (VLAN 40), broadcast (not hidden — SSID hiding is trivially bypassed by anyone scanning, so it buys no real security in exchange for the connection hassle), 2.4GHz + 5GHz only (no 6GHz — moot for a casting-target device like a smart TV, and reduces the SSID's radio footprint slightly).

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## The controller migration

The self-hosted UniFi controller went through two full generations in this build.

**Generation 1 — UniFi Network Application, by hand.** A `docker compose` stack: the `linuxserver/unifi-network-application` image alongside a separate `mongo:7.0` container, initially wired with Docker's default bridge networking and published ports. This worked for basic adoption, but the adopted switch intermittently dropped to "Offline" — unmanageable, no Port Manager, no live stats, no way to push config — for a few seconds at a time, with no obvious cause in the switch's own logs or via basic connectivity tests (conntrack table wasn't near its limit; direct pings between switch and host were clean). The actual cause was Docker's bridge network's NAT/userland-proxy path being unreliable specifically for the device *inform* channel — switching both containers to `network_mode: host` resolved it immediately and completely.

That fix had its own follow-on: switching networking modes on an *already-deployed* controller left `system.properties` still pointing at the old Docker-internal Mongo hostname (`unifi-mongo`), which isn't re-read from environment variables after first-run initialization — it's a persisted config file. The controller crash-looped with `MongoTimeoutException` until that file (and its `.bk` backup) got a manual `sed` to point at `127.0.0.1` instead.

**Generation 2 — migrating to UniFi OS Server.** Ubiquiti's classic self-hosted Network Application is being sunset in favor of a newer, officially self-hosted **UniFi OS Server** product — Ubiquiti documents an official migration path (backup export from the classic app → install UniFi OS Server → restore), so this build followed it rather than staying on a product with a known end date. The new server was deployed into a fresh LXC (`CT 201`, kept separate from the Docker-based `CT 200` deliberately, to avoid mixing container runtimes), and this is where the real troubleshooting started.

UniFi OS Server is Podman-only — not Docker — and Ubiquiti's own installer is explicit that this isn't optional (no Docker/Podman-agnostic build exists). The installer manages its own Podman containers and a `uosserver` systemd service internally; it isn't something you `docker compose up` yourself.

The first real blocker: the installer's own `sysctl -p` step failed setting `net.ipv4.ping_group_range` with `Invalid argument`. Three layers of investigation, each more revealing than the last:

1. Setting the sysctl at the Proxmox *host* level, under the theory that the container's network namespace would inherit it — didn't fix anything, since that's not actually how per-netns sysctls work.
2. Adding `lxc.sysctl.net.ipv4.ping_group_range` directly to the container's Proxmox config file — rejected outright by Proxmox's own config parser, regardless of quoting. Not a syntax problem; Proxmox's parser simply doesn't accept certain raw `lxc.*` keys directly.
3. Routing the same line through an `lxc.include` snippet file instead (which *does* pass through Proxmox's parser unvalidated) — this got further, but the container then failed to start at all. Foreground debug logging (`lxc-start -F -l DEBUG`) finally showed the real error, one layer deeper than any of the above: `conf.c:setup_sysctl_parameters:3020 - Invalid argument`. This is liblxc itself failing to apply that specific sysctl during container setup — a genuine kernel-level restriction on writing certain namespace-adjacent sysctls from a non-initial user namespace, which is exactly what an *unprivileged* LXC container's process tree is.

The fix was converting the container to **privileged** — trading some isolation (a privileged LXC's root is effectively host root) for compatibility with what the installer needs. That surfaced a second, unrelated problem: flipping an *existing* unprivileged container to privileged doesn't retroactively fix on-disk file ownership. Every file that container's "root" had ever written was actually stored on disk under the real UID/GID *offset* by the unprivileged subuid mapping (100000+) — and privileged containers use real host UIDs directly, with no such mapping. The result: `/usr/bin/su` and other setuid binaries now appeared owned by UID 100000 instead of 0, silently breaking their setuid semantics (`su: cannot set groups: Operation not permitted` — the exact, misleadingly generic error the installer surfaced). The fix here wasn't another config tweak; it was destroying the container and recreating it privileged *from creation*, so every file gets written with the correct ownership from the start.

Two smaller things came up on the freshly-rebuilt privileged container: default AppArmor confinement (ruled out once `dmesg` showed no matching denial for the failing operation), and Podman's rootless-style `pasta` network backend needing `/dev/net/tun`, which isn't exposed inside an LXC by default — fixed with an explicit `lxc.cgroup2.devices.allow` entry plus a bind-mount `lxc.mount.entry` for the device node.

With all of that resolved, the install completed cleanly, and the actual data migration — export a backup from the classic UniFi Network Application, restore it into the new UniFi OS Server's setup wizard — carried over the full site configuration (networks, port profiles, SSIDs, adopted devices) without any manual re-entry. Both devices needed one more `set-inform` pointed at the new server's IP, and came back online immediately.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## IP renumbering

Once the controller migration settled, IPs were normalized to a simple convention: a container's last-two-IP-digits match its Proxmox VMID where practical. This meant the old Docker-based controller (`CT 200`, later destroyed once the migration was confirmed stable) and the new UniFi OS Server (`CT 201`) both got renumbered, along with the Proxmox host itself moving off the address it happened to be squatting on (see [`proxmox.md`](proxmox.md) for the full SERVERS VLAN migration this was bundled with). Each renumbering required the same pattern: update the container's network config, confirm reachability, update the controller's Inform Host Override, then `set-inform` both devices at the new address.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## mDNS/SSDP reflection for cross-VLAN casting

Getting a casting-capable device (a smart TV, joined to the `IoT` SSID) discoverable from TRUSTED required more than the firewall Pass rule allowing TRUSTED→IOT traffic — mDNS/SSDP discovery is multicast, and multicast doesn't cross subnet/VLAN boundaries on its own no matter how permissive the unicast firewall rules are. OPNsense's `os-mdns-repeater` plugin (a purpose-built multicast-DNS proxy, simpler to configure than a general Avahi setup for this single reflection task) bridges that gap, reflecting mDNS traffic between TRUSTED, GUEST, and IOT.

With that in place, a client-initiated cast (phone or PC sending to the TV) needs only the one-directional Pass rule — the TV never needs to initiate anything back, since most casting flows are either stateful replies (already covered automatically) or the receiving device independently fetching content from the internet rather than from the sender.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Known issues & lessons

- **Docker's default bridge networking is unreliable for a self-hosted UniFi controller's device-inform channel**, specifically — not a general Docker problem, but specific enough to this one channel that `network_mode: host` was the actual fix, not a networking misconfiguration elsewhere.
- **`system.properties` doesn't re-read environment variables after first run.** Any change to how the controller reaches its database after initial deployment needs a manual edit to this persisted file, not just an environment variable change.
- **EINVAL on a sysctl write doesn't always mean a syntax problem.** It can mean the kernel is refusing the write entirely for namespace reasons — the only way to tell the difference is a debug-level trace at the point of failure, not just re-trying different formatting.
- **Privileged ≠ "was privileged from the start."** Converting an existing unprivileged LXC to privileged does not fix historical file ownership; a fresh container is the only clean path once this kind of corruption has happened.
- **UniFi devices remember their controller identity, not just its address.** Re-pointing `set-inform` at a new IP after a controller move reconnects instantly — no need to re-adopt from scratch, as long as the device was already adopted by that same controller before.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>
