# 🛡️ OPNsense — Firewall Build in Full

Interfaces, VLANs, DNS/DHCP, firewall rules, and the filtering/reflection services layered on top. Cross-references to the main [`README.md`](README.md) use `§N` notation for its numbered sections.

---

## Table of Contents

1. [Interfaces and VLANs](#interfaces-and-vlans)
2. [DNS and DHCP — a split design](#dns-and-dhcp--a-split-design)
3. [Content filtering](#content-filtering)
4. [Firewall rule architecture](#firewall-rule-architecture)
5. [GeoIP blocking](#geoip-blocking)
6. [mDNS/SSDP reflection](#mdnsssdp-reflection)
7. [VPN](#vpn)
8. [Known issues & lessons](#known-issues--lessons)

---

## Interfaces and VLANs

One physical LAN NIC (`igc3`) carries four tagged VLANs plus the native/untagged segment, all router-on-a-stick through OPNsense to the switch's trunk port:

| VLAN device | Tag | Interface identifier | Description |
| ------------ | ---- | ---------------------- | ------------- |
| — (native)  | —   | `lan`                 | MGMT — firewall/switch/AP only |
| `vlan01`    | 20  | `opt2` (TRUSTED)      | Day-to-day devices |
| `vlan02`    | 30  | `opt3` (SERVERS)      | Proxmox + guests |
| `vlan03`    | 50  | `opt4` (GUEST)        | Isolated guest devices |
| `vlan04`    | 40  | `opt1` (IOT)          | Wi-Fi casting devices |

Each VLAN interface gets a static gateway address at `.254` on its own `/24`, `IPv4 gateway rules: Disabled` (OPNsense is the gateway for its own interfaces, not routing through another one).

VLAN device creation lives under **Interfaces → Devices → VLAN** in this OPNsense version — older documentation referencing an "Other Types" menu doesn't match the current UI. After creating the raw VLAN device, it still needs a separate step under **Interfaces → Assignments** to actually become a usable interface (`optN`) — creating the VLAN device alone isn't sufficient.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## DNS and DHCP — a split design

Unbound handles recursive resolution, DNSSEC, and DNSBL-based content filtering. Dnsmasq handles DHCP and authoritative local DNS (`lab.lan`) on a non-standard port, with an Unbound domain override tying the two together so both static infrastructure and dynamic DHCP clients resolve consistently by hostname.

The one rule that matters most operationally: **every VLAN interface needs its own DHCP range in Dnsmasq, and its own entry in both Dnsmasq's and Unbound's listener interface lists.** Neither service auto-discovers newly added interfaces — a VLAN can have a perfectly good IP scheme and gateway, and still hand out no DHCP leases and no DNS resolution at all, because one checkbox in a settings page was missed. This exact gap showed up twice during this build (once for the original TRUSTED/SERVERS/GUEST rollout, once for IOT), and is now a checked-first step any time a new VLAN is added rather than something discovered by debugging "why does this VLAN look broken."

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Content filtering

Unbound's built-in DNSBL plugin blocks against a combination of general ad/tracker/malware lists (OISD) and a Hagezi category list, intercepting matching domains before they're ever forwarded upstream — independent of whatever upstream resolver is configured. Two DNS-over-TLS forwarders (OpenDNS) sit behind the DNSBL for everything that isn't blocked, providing encrypted upstream resolution; the actual filtering enforcement is the DNSBL layer, not the upstream provider's own category filtering.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Firewall rule architecture

OPNsense's GUI-generated rules are evaluated **top-to-bottom with first-match-wins** (`quick` is implicit on every rule the GUI creates) — this is the single most important thing to internalize before writing any rule set here, since it means order is functionally part of the rule, not just presentation.

**Shared rules, alias-based.** Rules that apply identically to TRUSTED and SERVERS (which have full bidirectional access to each other, a deliberate home-lab convenience decision) are written once per interface using a purpose-built alias (`internal_vlans`) for destination matching, rather than duplicating near-identical rules across interfaces.

**GUEST, isolated and kept separate.** GUEST is deliberately excluded from the shared TRUSTED/SERVERS rule set and given its own fully separate, strictly ordered rules:

1. Pass DNS/NTP to the gateway.
2. Pass to IOT network (casting only).
3. Block all further access to the firewall itself.
4. Block all RFC1918 destinations (`private_nets_VPN_ADD` — an alias that conveniently already covers every other VLAN plus both VPN tunnel subnets).
5. Pass-any, last — internet access, and only internet access, once everything above has already had first crack at matching.

Mixing GUEST into the shared alias-based rule set was deliberately avoided — GUEST's isolation logic needs to stay unambiguous and independently auditable, not entangled with rules that intentionally grant broad access elsewhere.

**IOT access is intentionally one-directional.** TRUSTED→IOT and GUEST→IOT each get exactly one Pass rule; there's no IOT→TRUSTED or IOT→GUEST equivalent, and none is needed. OPNsense's firewall is stateful — once TRUSTED or GUEST initiates a connection to IOT, the reply traffic for that specific connection is automatically permitted back through the state table, without a separate rule. A return-path rule would only make sense if IOT devices needed to *initiate* new, unsolicited connections into TRUSTED/GUEST, which is deliberately not the design here.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## GeoIP blocking

A defined hostile-country IP list is blocked ahead of both OpenVPN port passes — verified directly against the live `pfctl -sr` ruleset rather than assumed from the GUI's rule listing, since a rule's on-screen "floating" appearance doesn't always match how it's actually stored or evaluated (see [Known issues](#known-issues--lessons)).

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## mDNS/SSDP reflection

The `os-mdns-repeater` plugin (**Services → mDNS Repeater**) reflects multicast mDNS/SSDP traffic between TRUSTED, GUEST, and IOT — required for cross-VLAN device discovery (e.g., a phone on TRUSTED finding a smart TV on IOT for casting) since multicast doesn't cross subnet boundaries on its own, regardless of how permissive the unicast firewall rules between those VLANs are. This is a simpler, more purpose-built alternative to a general Avahi setup when the only need is reflecting between a small, fixed set of interfaces.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## VPN

Two OpenVPN instances share one CA and one tls-crypt key:

- **Instance 1** (udp/1194) — personal remote access, split-tunnel, routes to TRUSTED and SERVERS only.
- **Instance 2** (udp/1195) — full-tunnel internet exit for friends/family, hardened: DNS forced through CleanBrowsing's Security Filter (malware/phishing/CSAM blocking only, deliberately not a general content filter), plus a firewall block against an auto-updating alias of official Tor Project exit-node IPs, refreshed daily. The intent is narrow — block the one traffic category that creates real legal exposure for the account holder, without restricting anything else a guest might legitimately want to do.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Known issues & lessons

- **Multi-interface + multi-source floating rules expand into a full cross-product**, not "one rule per matching pair." Selecting three interfaces and three source networks on one rule creates a rule for *every* interface/source combination, including nonsensical ones (e.g., a rule on TRUSTED matching GUEST's source subnet). Harmless — auto-generated anti-spoofing rules already drop packets claiming the wrong subnet on the wrong interface — but it inflates the ruleset for no functional benefit. Prefer `any` for Source when interface scoping already does the real work.
- **A rule can look "floating" by description and not be floating by schema.** Only the live ruleset (`pfctl -sr`) confirms actual evaluation order and behavior; the exported config alone can be misleading about a rule's real placement.
- **dnsmasq and Unbound both self-follow interface *address* changes, but not interface additions.** A new VLAN needs to be manually added to both services' interface lists — this doesn't happen automatically the way an address change on an existing interface does.
- **A client's own DHCP lease doesn't self-heal when the gateway changes underneath it.** It keeps routing through the old, now-nonexistent gateway/DNS until its lease renews. Same-subnet access to the new address still works immediately (ARP, not routing) regardless.
- **"Other Types" doesn't exist in this OPNsense version's menu** the way older documentation describes — VLAN interface creation lives under **Interfaces → Devices → VLAN**.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>
