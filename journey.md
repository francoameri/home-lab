# 🚀 Journey — Building (and Learning From) This Lab

**One skill at a time: how this lab grew from a single virtualized host into a complete piece of infrastructure — a firewall, self-built DNS automation, cross-platform file sharing, a site-to-site cloud VPN, and remote access — and what I found looking back.**

---

## 📑 Table of Contents
1. [Why I built this](#-why-i-built-this)
2. [Step 1 — Virtualization first](#-step-1--virtualization-first)
3. [Step 2 — My own firewall](#-step-2--my-own-firewall)
4. [Step 3 — Building my own dynamic DNS](#-step-3--building-my-own-dynamic-dns)
5. [Step 4 — Sharing files across machines](#-step-4--sharing-files-across-machines)
6. [Step 5 — Reaching the cloud: the provider hunt](#-step-5--reaching-the-cloud-the-provider-hunt)
7. [Step 6 — Getting back in: remote access](#-step-6--getting-back-in-remote-access)
8. [What I found looking back](#-what-i-found-looking-back)
9. [Where this led](#-where-this-led)
10. [Related documentation](#-related-documentation)
11. [Keywords](#️-keywords)
12. [License](#-license)

---

## 🎯 Why I built this

I wanted a small, realistic environment to actually *do* the things that show up in enterprise IT — not just read about them.  
This is the story of how it grew, one skill at a time, from a single virtualized host into a full lab with its own firewall, its own DNS automation, cross-platform file sharing, and a real site-to-site VPN into the cloud.

Built between November 2025 and April 2026, then kept running a few more months before I decommissioned it in mid-2026 — this repo is what's left: how it worked, what broke, and what I'd do differently.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🖥️ Step 1 — Virtualization first

It started simple: **Proxmox VE**, installed bare-metal on a repurposed Dell laptop, purely to build real hands-on virtualization skills — creating VMs and containers, understanding storage layout, getting comfortable with a Type 1 hypervisor instead of running VirtualBox on top of a desktop OS.  
Everything else in this lab exists because this first step gave me a platform to build on.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🛡️ Step 2 — My own firewall

Once Proxmox was solid, I wanted a real firewall — not a home router's built-in NAT, but something with actual policy, logging, and security features I could learn from.  
Rather than buy dedicated hardware, I **virtualized Sophos Home Firewall** as a VM with its own bridged LAN and WAN interfaces. That gave me a genuine edge device to configure — firewall rules, IPS, web filtering, VPN endpoints — and a far better hands-on grip on infrastructure security than reading about it ever would have. Full config in [`firewall.md`](./firewall.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🌐 Step 3 — Building my own dynamic DNS

This is the part I'm proudest of technically. I wanted the kind of DHCP-to-DNS integration you get "for free" with something like **Active Directory** — a device joins the network, gets a lease, and is immediately reachable by hostname — but without standing up anything as resource-heavy as a domain controller for a home lab.

So I built the bridge myself: a **cron job** pulls Sophos's live DHCP lease data (via its lease file and API), a script parses it, and **`nsupdate`** — secured with a **TSIG key** — pushes forward and reverse records into a **BIND9** zone. It's not how you'd do this if the tooling supported it natively, but building it by hand meant actually understanding every piece of what "dynamic DNS" really involves under the hood, rather than trusting a checkbox in a GUI.

Static infrastructure never went through this pipeline — those got fixed entries in Sophos's own DNS host table, since they never change. Full build in [`BIND9.md`](./BIND9.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📁 Step 4 — Sharing files across machines

Between a couple of different operating systems and two physical machines, I needed a simple, reliable way to move files around without emailing things to myself or juggling a USB drive.  
**Samba** solved that cleanly — one authenticated share, one user, working the same way on Windows or Linux. Small in scope, but it got real, regular use — including, at one point, moving files securely between my personal PC and a new work laptop during a job transition, simply because the infrastructure was already there and already trustworthy. See [`Samba.md`](./Samba.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## ☁️ Step 5 — Reaching the cloud: the provider hunt

Once the LAN felt solid, I wanted a real **site-to-site VPN** to an actual cloud environment, not a simulated peer.  
I tried **AWS, GCP, and Azure** first — but their free-tier constraints kept getting in the way of what I actually wanted to build, and I didn't want to compromise the design just to fit a trial limit. **Oracle Cloud Infrastructure** turned out to be the one that let me build it properly on their Always Free tier: an Ubuntu VM running **StrongSwan**, tunneling back to Sophos over **IKEv2** with a pre-shared key.

The trickiest part wasn't the VPN config itself — it was realizing that Sophos's own WAN address was never a real public IP; my ISP's own NAT sat in front of it. The fix was dynamic DNS, tracking my actual public-facing address from a script running inside the network (since Sophos itself couldn't reliably tell what its own public IP was), with the OCI side of the tunnel pointed at that hostname instead of an IP. The whole tunnel, both ends, is written up in [`vpn.md`](./vpn.md).

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔐 Step 6 — Getting back in: remote access

The last piece was making sure I could reach my own network from outside it.  
I built a **VPN client profile** so my laptop could connect back home securely from anywhere — the same firewall now serving both site-to-site and remote-access roles.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔍 What I found looking back

Writing this documentation months after decommissioning turned up a few things I never caught while the lab was live:

- **The Proxmox host itself had a real, unfirewalled path to the internet over IPv6** — a global address picked up automatically via router advertisement on the same bridge Sophos used for WAN, but never filtered by Sophos or by anything on the host itself. Sophos only ever protected its own VM; the bare-metal host underneath was never in scope.
- **A small quoting bug in the DHCP sync script** occasionally left hostnames in DNS with inconsistent casing — surfaced once, then stopped happening on its own once client behavior changed, not because I fixed it.
- **A health-check script that "worked" but never told the full story** — it overwrote its own log every run instead of keeping history, and a cron scheduling mistake meant it ran half as often as intended.

None of these caused real problems in practice. But they're exactly the kind of thing that's easy to miss while a lab is running, and easy to spot once you're forced to verify every claim against the live system — which is exactly what building this documentation forced me to do.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏁 Where this led

Every piece of this — virtualization, firewalling, DNS automation, file sharing, site-to-site VPN, remote access — built on the one before it.  
By the time I retired this lab, I'd gone from "installing a hypervisor" to running a small but genuinely complete piece of infrastructure end to end.

With everything I learned here, I've since started building a new lab.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🔗 Related documentation

- [`README.md`](./README.md) — full lab overview, topology, and inventory.
- [`firewall.md`](./firewall.md) — the Sophos firewall config in full.
- [`vpn.md`](./vpn.md) — the site-to-site VPN, end to end.
- [`BIND9.md`](./BIND9.md) — the self-built dynamic DNS service.
- [`Samba.md`](./Samba.md) — the authenticated file share.

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 🏷️ Keywords

`homelab` · `Proxmox VE` · `virtualization` · `Sophos` · `firewall` · `BIND9` · `dynamic DNS` · `Samba` · `StrongSwan` · `IPsec` · `site-to-site VPN` · `Oracle Cloud` · `OCI` · `remote access VPN` · `continuous learning`

<div align="right"><a href="#-table-of-contents">↑ Back to top</a></div>

---

## 📝 License

This repository is shared for educational purposes. Please respect usage guidelines and credit appropriately when reusing content.
