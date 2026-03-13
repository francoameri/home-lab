# Sophos DHCP + Bind9 Dynamic DNS Integration

## 📖 Overview
This project documents how to integrate **Sophos DHCP leases** with **Bind9 DNS** to achieve dynamic hostname resolution in a lab environment.  
Goal: when a host gets a DHCP lease, its hostname and IP are automatically available in DNS (forward + reverse lookups).

---

## 🏗️ Architecture

```
[ Sophos DHCP ] ---> [ Sync Script ] ---> [ Bind9 DNS ]
|                                   |
|                                   +--> Authoritative for lab.lan + reverse zone
|
+--> Clients receive DNS = Bind9 via DHCP Option 6
```

---

## ⚙️ Setup Steps

### 1. Bind9 Installation
- Install bind9 on Debian/Ubuntu.
- Confirm service is running: `systemctl status bind9`.

### 2. Zone Configuration
- Edit `/etc/bind/named.conf.local`:
  ```bash
  key dhcp_updater {
      algorithm hmac-sha256;
      secret "YOUR_TSIG_SECRET";
  };

  zone "lab.lan" {
      type master;
      file "/var/lib/bind/db.lab.lan";
      allow-update { key dhcp_updater; };
  };

  zone "0.0.10.in-addr.arpa" {
      type master;
      file "/var/lib/bind/db.10.0.0";
      allow-update { key dhcp_updater; };
  };


3. Zone Files

    Minimal SOA + NS records in /var/lib/bind/db.lab.lan and /var/lib/bind/db.10.0.0.

4. Forwarders

> /etc/bind/named.conf.options:

```
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { any; };
    forwarders {
        10.0.0.1;           // Sophos
        208.67.222.222;     // Cisco Umbrella
        208.67.220.220;     // Cisco Umbrella
    };
};
```

5. Sync Script

    /usr/local/bin/sync-leases.sh:

        Pulls leases from Sophos (scp).

        Parses IP + hostname.

        Uses nsupdate with TSIG key to insert A + PTR records.

        Logs updates to /var/log/ddns-sync.log.

6. Automation
Cron job every 5 minutes:

```
*/5 * * * * scp -i /root/.ssh/sophos_key admin@10.0.0.1:/tmp/dhcpd.leases.live /var/tmp/sophos-leases.live && /usr/local/bin/sync-leases.sh
```
