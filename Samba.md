# 📁 Samba File Share

**A single authenticated SMB share — a quick, secure way to move files across operating systems and machines on the LAN.**

---

## 📑 Table of Contents
1. [Overview](#-overview)
2. [Architecture](#️-architecture)
3. [Setup](#️-setup)
4. [Notes](#-notes)
5. [Related documentation](#-related-documentation)
6. [Keywords](#️-keywords)
7. [License](#-license)

---

## 📖 Overview

This document covers the Samba LXC container (`10.0.0.202`) — a single authenticated SMB share used as a quick, secure way to move files internally on the LAN, across different operating systems and between two physical machines.

It wasn't a general-purpose file server or media share. It existed so files could move between machines without a USB drive, over a connection already secured by being inside the lab's own LAN.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏗️ Architecture

```
[ LAN client (Windows / Linux) ]
              │
              │  SMB, authenticated (user: fameri)
              ▼
[ Samba LXC  (10.0.0.202) ]
              │
              └── [shared] → /amerinfra/storage   (read-write, single user)
```

Runs as an unprivileged Debian LXC (128MB RAM). Unlike the BIND9 container, this LXC had Proxmox's **per-container firewall flag enabled** — the higher-risk profile of exposing SMB made the extra isolation layer a sensible default.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## ⚙️ Setup

### 1. Base install
Standard `samba` package on Debian (`apt install samba`). Everything in `/etc/samba/smb.conf` outside the `[shared]` section is stock Debian default — untouched.

### 2. Share definition
The one meaningful customization, appended to the default config:

```ini
[shared]
   path = /amerinfra/storage
   browseable = yes
   read only = no
   valid users = fameri
```

- **User-authenticated, not guest.** `valid users = fameri` — only one local account could connect; no anonymous access exposed.
- **Read-write.** Explicitly writable, since its whole purpose was moving files onto and off of it.

### 3. User account
A single local Unix user, `fameri`, with `unix password sync = yes` keeping the SMB password in sync with the Unix account — one password to manage, not a separate Samba credential store.

### 4. Everything else
`[homes]`, `[printers]`, `[print$]` stayed as Debian's shipped defaults and were never used. If you're reading this as a "copy this" reference: the interesting part really is just the six lines above.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔩 Notes

- This share is **not** documented with an inventory of what was stored on it — by design. This doc describes the mechanism, not an archive of contents.
- No `smbd` crashes or stability issues came up in the lab's operational life — the service ran quietly in the background throughout.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview and topology.
- [`journey.md`](./journey.md) — where this share fit into the build story.
- [`firewall.md`](./firewall.md) — the Sophos firewall fronting this network.
- [`vpn.md`](./vpn.md) — the site-to-site VPN.
- [`BIND9.md`](./BIND9.md) — the other LXC service on this lab.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`Samba` · `SMB` · `file share` · `Debian LXC` · `Proxmox` · `unix password sync` · `cross-platform` · `homelab`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
