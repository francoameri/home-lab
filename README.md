# 🔧 Home‑Lab — Hybrid Proxmox Lab with Site‑to‑Site VPN

Short summary  
A hands‑on home‑lab built on a Dell laptop running Proxmox VE. Demonstrates a hybrid network with a Sophos home firewall (virtualized), StrongSwan site‑to‑site IPsec to an OCI Ubuntu VM, local DNS/DDNS emulation, and lightweight file sharing. This repo documents design decisions, configuration snippets, deployment steps, automation, and lessons learned for engineers and hiring managers.

---

## 📚 Table of contents

🔧 Overview
🎯 Goals
🗺️ Network topology
🧾 Hardware and software inventory
🚀 Getting started
⚙️ Configuration highlights
🤖 Automation and self‑healing
📄 Documentation and diagrams
🤝 Contributing
🛣️ Roadmap
📜 License

---

## 🔧 Overview

>This project documents a compact, production‑inspired home‑lab used to learn and demonstrate virtualization, networking, VPNs, DNS automation, and container services.
>The lab is intentionally small and reproducible so others can replicate or adapt it.

---

## 🎯 Goals
- Build a reproducible Proxmox‑based home‑lab.
- Demonstrate secure site‑to‑site IPsec (StrongSwan ↔ Sophos).
- Show DNS/DDNS integration with DHCP leases for realistic name resolution.
- Provide clear, copy‑pasteable configuration snippets and diagrams.
- Make the repo useful for peers, technicians, managers, and recruiters.

---

## 🗺️ Network topology

### Local network (10.0.0.0/24)

10.0.0.1 — Sophos Home Firewall (virtualized VM in Proxmox) edge; handles VPN, NAT, DHCP.

    DHCP range: 10.0.0.100–10.0.0.199 (served by Sophos DHCP).

10.0.0.200 — Proxmox VE (bare‑metal host; Type 1 hypervisor).

10.0.0.201 — BIND9 container — Local DNS / DDNS emulation (authoritative for lab; integrated with Sophos DHCP leases).

10.0.0.202 — Samba container — small file sharing between devices.

### Remote / Cloud

    OCI Ubuntu VM 172.16.1.99 — StrongSwan peer for site‑to‑site IPsec (Ubuntu is listed as software below).

    DYNU used for DDNS to handle ISP public IP rotation.

### Internet DNS (recursive / filtering)

    Cisco Umbrella resolvers used for upstream DNS filtering: 208.67.222.222 and 208.67.220.220.

A simplified diagram is available in /docs/network-diagram.md and /docs/network-diagram.svg.

---

## 🧾 Hardware and software inventory

- Hardware

    Dell laptop — Core i7 (4C/8T), 16GB DDR3, 120GB NVMe (Proxmox + ISOs), 240GB SATA SSD (VMs/CTs)

- Software / Services

    Proxmox VE (bare‑metal Type 1 hypervisor; version noted in /docs/versions.md)
    Sophos Home Firewall (virtualized inside Proxmox as a VM)
    Ubuntu — guest OS in OCI for StrongSwan peer (and any other Linux VMs)
    StrongSwan (IPsec implementation on Ubuntu VM)
    BIND9 (container for local DNS + DDNS emulation)
    Samba (container for file sharing)
    DYNU (DDNS provider)
    Cisco Umbrella (upstream DNS filtering; resolvers listed above)

---

🚀 Getting started

- Why clone this repo?
  To obtain copy‑ready configuration snippets, automation playbooks, diagrams, and verification scripts so you can reproduce or adapt the lab quickly. The repo contains everything needed to provision VMs/CTs, configure VPNs and DNS, and run the verification/self‑healing checks described below.

- Clone and inspect:

```
git clone https://github.com/<you>/home-lab.git
cd home-lab
```

- Read /docs/quickstart.md for step‑by‑step provisioning of the Proxmox host, VM/CT creation, and initial configuration.

- Use the provided automation in /automation (Ansible playbooks, scripts) to provision and configure services.

- Review /configs for sample config files (StrongSwan, Sophos snippets, BIND9, Samba) and /scripts for verification and self‑healing helpers.

---

## ⚙️ Configuration highlights

- StrongSwan: sample ipsec.conf and ipsec.secrets with comments and secure parameter recommendations. Runs on Ubuntu VM in OCI.
- Sophos: exported policy snippets and DHCP integration notes; Sophos runs as a VM inside Proxmox.
- BIND9: dynamic update examples and a script that emulates DDNS updates from DHCP leases (local DNS at 10.0.0.201).
- Samba: minimal secure share configuration for cross‑platform testing.
- Proxmox: notes on storage layout (NVMe for host/ISOs, SATA for VMs/CTs), backup recommendations, and VM templates.

See /configs for full examples and /docs/security.md for hardening notes. Do not commit secrets — use *.example templates for secrets.

---

## 🤖 Automation and self‑healing

This repo includes automation and basic self‑healing capabilities designed to make the lab reproducible and resilient.

- What you’ll find in /automation and /scripts

  - Ansible playbooks to provision Proxmox VMs/CTs, deploy BIND9 and Samba containers, and apply baseline hardening.
  - Provisioning scripts for initial host setup (partitioning, Proxmox install notes, storage configuration).
  - Verification scripts (scripts/verify.sh) that run checks such as:
    - ipsec statusall and journalctl checks for StrongSwan health.
    - dig/nslookup against 10.0.0.201 and upstream Umbrella resolvers.
    - smbclient checks for Samba shares.

  - Self‑healing helpers:
    - Lightweight watchdog scripts that restart failed services (e.g., restart BIND9 if zone updates fail).
    - Ansible playbooks that can be re-run idempotently to restore desired state.
    - Health‑check cron jobs that report status to local logs and optionally trigger remediation playbooks.

  - Templates and examples:
    - ipsec.secrets.example, named.conf.local.example, smb.conf.example — safe to copy and fill.
    - automation/restore-playbook.yml — example playbook to restore a VM or reapply network config.

How to use

- Run automation/bootstrap.yml once to provision the baseline.
- Add the repo to your CI or a local cron job to run scripts/verify.sh periodically.
- Use the automation/repair.yml playbook to attempt automated remediation when checks fail.

---

## 📄 Documentation and diagrams

All documentation lives in /docs. Key files:

- quickstart.md — bootstrap steps and minimal commands.
- network-diagram.md — ASCII + Mermaid diagrams; network-diagram.svg for visual reference.
- automation.md — how to run playbooks and scripts; how self‑healing works.
- configs/ — copy‑ready config snippets.
- changelog.md — lab changes and lessons learned.
- versions.md — software versions used during testing.

## 🤝 Contributing

Contributions are welcome. Please:

 - Open an issue describing the change or improvement.
 - Create a branch feature/<short-desc>.
 - Submit a PR with tests or verification steps.

See CONTRIBUTING.md for templates and expectations.

## 🛣️ Roadmap

Planned items:

- Add automated backups for VMs/CTs.
- Integrate monitoring (Prometheus + Grafana) with alerting.
- Add CI checks for config syntax and playbook linting.
- Expand self‑healing to include snapshot rollback for critical VMs.
- Publish a short blog post series documenting the build process.
