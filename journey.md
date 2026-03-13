🛠️ Lab Hardening Roadmap
1. DNS & DHCP Integration
- ✅ Ensure Sophos DHCP hands out:
- 10.0.0.201 as DNS server.
- lab.lan as domain suffix (option domain-name "lab.lan";).
- 🔧 Verify with ipconfig /all on Windows → suffix should show as lab.lan.

2. Bind9 Health & Recovery
- ✅ Health check script overwrites log every 30 minutes.
- 🔧 Extend script to:
- Exit with non‑zero code if bind9 is inactive.
- Optionally auto‑restart bind9 (systemctl restart bind9) if failure detected.
- 📖 Document the script in your GitHub repo with usage + cron setup.

3. Monitoring & Alerts
- 🪶 Lightweight options:
- Monit → auto‑restart bind9, send alerts (email, webhook, push).
- Netdata → one container, real‑time dashboard + alerts to Slack/Discord/Teams.
- Gotify/Pushover/Telegram bot → push notifications to your phone.
- 🔧 Start with Monit for simplicity, then expand to Netdata if you want dashboards.

4. Backup & Recovery
- 🔧 Add cron jobs to back up:
- Bind9 zone files.
- Config files (/etc/bind/).
- ✅ Store backups in your GitHub repo or a local archive.
- 📖 Document restore steps (copy back configs, rndc reload).

5. Documentation & Portfolio
- 📖 Expand your GitHub README:
- Architecture diagram (Sophos DHCP → bind9 → forwarders).
- Step‑by‑step setup (forward zone, reverse zone, suffix config).
- Health check script + verification routine.
- Troubleshooting section (common errors like NXDOMAIN, network unreachable).
- 🎯 This makes your repo recruiter‑friendly and shows architect‑level thinking.

6. Future Enhancements
- 🔧 Add logging/metrics for DNS queries (bind9 statistics channel).
- 🔧 Explore Prometheus blackbox exporter for DNS probes.
- 🔧 Consider containerizing bind9 for reproducibility.

✅ Outcome
By following this roadmap, you’ll have:
- A resilient DNS setup (forward + reverse resolution always consistent).
- Automated health checks with recovery.
- Lightweight monitoring with alerts beyond email.
- Backups + documentation for disaster recovery.
- A portfolio‑ready GitHub repo that demonstrates enterprise‑grade practices.
