# 📊 Monitoring — Prometheus, Grafana, and Exporters

A self-contained observability stack for the whole lab: host resources, container metrics, service-specific metrics (Pi-hole, OPNsense), and uptime/availability checks — built in four deliberate phases. Cross-references to [`opnsense.md`](opnsense.md), [`pihole.md`](pihole.md), [`proxmox.md`](proxmox.md), and [`unifi.md`](unifi.md) use direct-link notation.

---

## Table of Contents

1. [Overview](#overview)
2. [Deployment](#deployment)
3. [Architecture](#architecture)
4. [Phase 1 — core stack and host metrics](#phase-1--core-stack-and-host-metrics)
5. [Phase 2 — container metrics](#phase-2--container-metrics)
6. [Phase 3 — service-specific exporters](#phase-3--service-specific-exporters)
7. [Phase 4 — uptime and availability checks](#phase-4--uptime-and-availability-checks)
8. [Targets reference](#targets-reference)
9. [Known issues & lessons](#known-issues--lessons)

---

## Overview

Prometheus pulls metrics from exporters on a schedule; Grafana queries Prometheus as its only data source and stores nothing of its own. Everything in this stack lives on one dedicated CT, deployed in four phases — core stack + host metrics, container metrics, service-specific exporters, then uptime/availability checks — rather than all at once, specifically to understand how each layer works before adding the next.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Deployment

Runs as `CT 202` on Proxmox (SERVERS `192.168.130.202`, tag 30) — Debian 13, unprivileged LXC, `--features nesting=1` set at creation for Docker support (see [`proxmox.md` §Known issues](proxmox.md#known-issues--lessons)). All services live under `/opt/monitoring-stack/` as a single Docker Compose project.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Architecture

- **Pull-based scraping.** Every exporter exposes a `/metrics` endpoint; Prometheus polls each one on a 15-second `scrape_interval` and stores the time series itself. Grafana never talks to exporters directly — only to Prometheus.
- **`network_mode: host` on every container**, the same pattern used throughout this build, for reliable reachability across VLANs rather than being boxed in behind Docker's bridge NAT.
- **Explicit IPs in every Prometheus target, not `localhost`.** Prometheus derives its `instance` label directly from the configured target address — `localhost:PORT` is ambiguous and non-self-documenting once there's more than one host in the fleet, so every target in `prometheus.yml` uses the real IP of the thing it's scraping.
- **`node_exporter` must run on the actual physical or logical host it reports on.** A containerized instance can only ever see the container's own view of resources — it can't see the true hypervisor's CPU/RAM/disk. This is why there are two separate `node_exporter` instances: one running as a native systemd service directly on the Proxmox host itself, and one running inside `CT 202` for the monitoring stack's own self-monitoring.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Phase 1 — core stack and host metrics

Prometheus + Grafana + two `node_exporter` instances (Proxmox host, monitoring CT itself). Grafana's official "Node Exporter Full" community dashboard covers both out of the box, filterable by host.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Phase 2 — container metrics

cAdvisor deployed on all three existing CTs (Pi-hole, UniFi OS, and the monitoring CT itself), reading container-level metrics via each host's container runtime socket:

- **Docker CTs** (Pi-hole, monitoring): standard cAdvisor deployment against the Docker socket.
- **The Podman CT (UniFi OS, `CT 201`):** deployed via plain `podman run` rather than Compose, since Ubiquiti's own installer owns that container runtime. Podman doesn't expose its API socket by default, so cAdvisor initially fell back to a degraded generic "Raw" cgroup-based factory — real metrics, but no container names or labels. Fixed by enabling `podman.socket` explicitly and remounting it into a recreated cAdvisor container. Also needed a port change (`--port=8081`) since cAdvisor's default 8080 collides with UniFi OS Server's own device-inform channel.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Phase 3 — service-specific exporters

**Pi-hole** — a custom-built exporter wrapping `bazmonk/pihole6_exporter` (no official image exists), since Pi-hole v6's session-based App Password auth broke compatibility with older exporters. Full detail in [`pihole.md` §Monitoring integration](pihole.md#monitoring-integration).

**OPNsense** — `ghcr.io/athennamind/opnsense-exporter`, calling OPNsense's own REST API over HTTPS with a dedicated least-privilege `monitoring-api` user and API key/secret (see [`opnsense.md` §Monitoring API access](opnsense.md#monitoring-api-access)). Every endpoint returned `context deadline exceeded` on first deploy — a plain `curl` from the Proxmox host to the firewall's SERVERS IP timed out identically, which isolated the problem to the firewall itself rather than the exporter or a routing/firewall-rule issue. Root cause: System → Settings → Administration → **Listen Interfaces** was scoped to `LAN` only, so the API/GUI daemon never bound a listening socket on SERVERS at all — indistinguishable from a firewall block until traced this specifically. Fixed by adding SERVERS to that list.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Phase 4 — uptime and availability checks

`prom/blackbox-exporter`, scraped indirectly: Prometheus targets blackbox's own `/probe` endpoint with `params.module` and `target`, then uses `relabel_configs` to rewrite `__address__`/`instance` to reflect the real target rather than blackbox itself. Two modules in use:

- `http_2xx` — the four admin UIs: Pi-hole, OPNsense, UniFi OS Server (port `11443`), and Grafana itself.
- `icmp` — external connectivity, probing `1.1.1.1` (requires `cap_add: [NET_RAW]` on the container).

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Targets reference

| Job | Target(s) |
| --- | --- |
| `prometheus` | `192.168.130.202:9090` |
| `node-monitoring-ct` | `192.168.130.202:9100` |
| `node-proxmox-host` | `192.168.130.253:9100` |
| `cadvisor-monitoring-ct` | `192.168.130.202:8080` |
| `cadvisor-pihole-ct` | `192.168.130.200:8080` |
| `cadvisor-unifi-ct` | `192.168.130.201:8081` |
| `pihole-exporter` | `192.168.130.200:9666` |
| `opnsense-exporter` | `192.168.130.202:8082` |
| `blackbox_http` | `https://192.168.130.200/admin/`, `https://192.168.130.254/`, `https://192.168.130.201:11443/`, `http://192.168.130.202:3000/` (via `192.168.130.202:9115`) |
| `blackbox_icmp` | `1.1.1.1` (via `192.168.130.202:9115`) |

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>

---

## Known issues & lessons

- **Bind-mounted data directories must be pre-chowned to the exporter's actual runtime UID.** `prom/prometheus` runs as UID `65534` (nobody), `grafana/grafana` as UID `472` — root-owned bind mounts crash-loop both containers with permission-denied errors on first start.
- **`GF_SECURITY_ADMIN_PASSWORD` only applies on first database initialization.** Resetting Grafana's admin password afterward requires `docker exec grafana grafana cli admin reset-admin-password '<value>'` — note the current image invokes this as the `grafana cli` subcommand, not the old standalone `grafana-cli` binary, which doesn't exist in this image version.
- **Don't guess exporter version numbers.** A guessed `node_exporter` version 404'd on download; querying the project's GitHub releases API for the real current tag is one extra step that avoids it entirely.
- **Podman doesn't expose its API socket by default**, so cAdvisor falls back to a degraded "Raw" cgroup factory (works, but no real container names/labels) until `podman.socket` is enabled explicitly.
- **Port collisions are a real risk under `network_mode: host`.** cAdvisor's default port (8080) collided with UniFi OS Server's own device-inform channel on `CT 201`; solved by moving cAdvisor to 8081 there rather than touching UniFi's port.
- **OPNsense's Listen Interfaces setting scopes more than the web GUI** — an interface left out of that list produces a full connection timeout indistinguishable from "nothing is listening," not a firewall rejection. Full detail in [`opnsense.md` §Known issues](opnsense.md#known-issues--lessons).
- **Blackbox exporter is scraped indirectly**, via its own `/probe` endpoint with relabeling — a fundamentally different pattern from every direct exporter in this stack. Worth remembering before debugging a "target down": it could be blackbox itself unreachable, not the real target.
- **`podman logs` requires flags before the container name** (`podman logs --tail 20 cadvisor`), unlike Docker's more flexible argument ordering.

<div align="right"><sub><a href="#table-of-contents">↑ Back to Table of Contents</a></sub></div>
