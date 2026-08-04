# 📁 Samba File Share

**A single authenticated SMB share on a 128 MB container — a quick, secure way to move files across operating systems and between machines on the LAN, with the SMB credential kept in sync with the underlying Unix account.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Technical reference](#-technical-reference)
   - [The share definition](#the-share-definition)
   - [Authentication model](#authentication-model)
   - [Container-level isolation](#container-level-isolation)
3. [Notes](#-notes)
4. [Config files](#-config-files)
5. [Related documentation](#-related-documentation)
6. [Keywords](#️-keywords)
7. [License](#-license)

---

## 📖 Overview

The Samba container (`10.0.0.202`) existed for one practical job: moving files between different operating systems and two physical machines without a USB drive, over a connection already trusted by living inside the lab's LAN. It was a single authenticated share, one user — deliberately minimal. It wasn't a media server or a general file store, and it's documented here as a mechanism, not as an archive of what it held.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔧 Technical reference

### The share definition

Everything in `/etc/samba/smb.conf` outside the one block below was stock Debian default. The customization ([`configs/samba/smb.conf`](./configs/samba/smb.conf)):

```ini
[shared]
   path = /amerinfra/storage
   browseable = yes
   read only = no
   valid users = fameri
```

- `read only = no` — explicitly writable. The Debian `[homes]` template defaults to read-only; this share's whole purpose was moving files *onto* it, so that had to be flipped.
- `valid users = fameri` — restricts the share to a single account. Anyone browsing the network sees it (`browseable = yes`) but only `fameri` can connect.

### Authentication model

Three global settings (kept from Debian's defaults, but load-bearing here) define the auth behavior:

| Setting | Value | Effect |
|---------|-------|--------|
| `server role` | `standalone server` | No domain/AD — local accounts only |
| `unix password sync` | `yes` | Changing the SMB password also changes the Unix password |
| `map to guest` | `bad user` | Unknown users are refused, not silently mapped to guest |

`unix password sync = yes` is the choice worth calling out: it means there's exactly **one** credential for the `fameri` account, not a separate Samba password database drifting out of sync with the Unix login. On a single-user share, that's the difference between one password to reason about and two.

### Container-level isolation

The Samba LXC (guest 103) had **Proxmox's per-container firewall enabled** (`firewall=1` on its NIC in [`configs/proxmox/103.conf`](./configs/proxmox/103.conf)) — the BIND9 container did not. SMB is a higher-risk, historically more-exploited protocol than DNS, so the file-sharing container got the extra network-isolation layer. It's a small asymmetry, but a deliberate one: match the isolation to the exposure of the service.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔩 Notes

- This share is **not** documented with a contents inventory — by design. The doc describes the mechanism, not what was stored.
- `smbd` ran without crashes or stability issues across the lab's operational life — a quiet, low-resource service (128 MB LXC, see [`proxmox.md`](./proxmox.md)).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📂 Config files

- [`configs/samba/smb.conf`](./configs/samba/smb.conf) — the customized share block and the relevant globals.
- [`configs/proxmox/103.conf`](./configs/proxmox/103.conf) — the container definition (note `firewall=1`).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`proxmox.md`](./proxmox.md) — the LXC (guest 103) this runs in.
- [`firewall.md`](./firewall.md) — the Sophos firewall fronting this network.
- [`BIND9.md`](./BIND9.md) — the other LXC service on this lab.
- [`journey.md`](./journey.md) — where this share fit into the build story.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔑 Keywords

`Samba` · `SMB` · `file share` · `standalone server` · `unix password sync` · `valid users` · `Debian LXC` · `Proxmox firewall` · `cross-platform` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

✍️ Authored by **Franco [francoameri]**
📜 Licensed under [CC BY 4.0](https://github.com/francoameri/francoameri/blob/main/LICENSE.md)
Please credit the original author when sharing or adapting this work.
