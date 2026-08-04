# 🏠 Home-Lab — Franco Ameri Sbraccia

A running record of my home infrastructure builds, documented the way I'd document production systems: real configs, real topology, real bugs.

This repo now spans two generations:

| Version | Status | Summary |
|---|---|---|
| [**v1 — Sophos-on-Proxmox, Site-to-Site VPN**](v1/README.md) | 📦 Decommissioned (Nov 2025 – Apr 2026) | Virtualized Sophos Home firewall on a Dell/Proxmox host, StrongSwan site-to-site IPsec to Oracle Cloud, self-built dynamic DNS (BIND9 + nsupdate), Samba file share. |
| [**v2 — Segmented OPNsense Build**](v2/README.md) | 🚧 Active, in progress | Dedicated bare-metal OPNsense firewall, multi-VLAN segmentation (trusted/servers/guest), dual-instance OpenVPN with content-safety hardening, migrating from a single flat network toward a Proxmox + NAS backend. |

Each version's folder is self-contained — its own README, its own component docs, its own `configs/` (secrets redacted). v1 is preserved as-is, a historical record of what worked, what didn't, and what I'd do differently. v2 is a living document, updated as the build progresses.

## Why keep both

The architectures are genuinely different, not just a hardware refresh — v1 ran the firewall as a VM behind a hypervisor; v2 runs it as the dedicated bare-metal edge device, with virtualization (Proxmox) arriving *behind* the firewall instead of hosting it. Keeping both visible shows the actual progression in reasoning, not just a finished result.

## License

All content in this repository is shared under the [Creative Commons Attribution 4.0 International License (CC BY 4.0)](LICENSE.md).

## Contact

💼 [LinkedIn](https://linkedin.com/in/fameri) · ✉️ famerisbraccia@gmail.com
