# AutoMailDeploy

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests: 43/43](https://img.shields.io/badge/Tests-43%2F43%20Passing-brightgreen)](#proof-of-concept)

**Automated, production-ready enterprise email server deployed in a single command.**

Fully containerized mail infrastructure with automated security hardening, backups, monitoring, and a 43-test validation.

**Stack:** Postfix · Dovecot · Rspamd · Roundcube · Nginx · MariaDB · Redis · Let's Encrypt · Fail2ban · UFW

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Proof of Concept](#proof-of-concept)
- [Management Tools](#management-tools)
- [Security](#security)
- [DNS Records](#dns-records)
- [Backup & Recovery](#backup--recovery)
- [Monitoring & Alerts](#monitoring--alerts)
- [Uninstalling](#uninstalling)
- [Production vs Local Deployment](#production-vs-local-deployment)
- [Repository Structure](#repository-structure)
- [License](#license)

---

## Features

| Category | Details |
|----------|---------|
| **Mail Transport** | Postfix SMTP with TLS 1.2+, SASL auth via Dovecot, anti-relay protection |
| **Mail Delivery** | Dovecot IMAP/LMTP with Maildir storage, automatic folder structure |
| **Anti-Spam** | Rspamd with Bayes classifier, DKIM signing, SPF/DMARC enforcement |
| **Webmail** | Roundcube with Elastic skin, served via Nginx reverse proxy |
| **TLS Certificates** | Auto-detected: Let's Encrypt for public domains, self-signed for local/test |
| **Firewall** | UFW auto-configured — only SSH + mail ports open |
| **Intrusion Protection** | Fail2ban with jails for Postfix SASL and Dovecot (1h ban after 5 attempts) |
| **Rate Limiting** | 50 msgs/min, 30 connections/min per client |
| **Backups** | Daily automated backups with local + remote rsync support |
| **Monitoring** | Health checks every 5 min with email alerts to admin |
| **Log Management** | Daily rotation, 30-day compressed retention |
| **DNS Verification** | Script to validate A, MX, SPF, DKIM, DMARC, and PTR records |
| **Test Suite** | 43-test automated PoC covering all 17 infrastructure categories |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Internet / Client                     │
└──────┬──────────┬──────────┬──────────┬─────────────────┘
       │ :25/:465 │ :587     │ :993     │ :80/:443
       │          │          │          │
┌──────▼──────┐   │   ┌──────▼──────┐  ┌▼──────────────┐
│   Postfix   │◄──┘   │   Dovecot   │  │    Nginx      │
│   (SMTP)    │       │ (IMAP/LMTP) │  │(reverse proxy)│
└──────┬──────┘       └──────▲──────┘  └──┬─────────┬──┘
       │ milter              │ LMTP       │         │
┌──────▼──────┐       ┌─────┴──────┐  ┌──▼────┐ ┌──▼────┐
│   Rspamd    │       │  Maildir   │  │Round- │ │Rspamd │
│ (anti-spam) │       │  (Volume)  │  │ cube  │ │Web UI │
└──────┬──────┘       └────────────┘  └──┬────┘ └───────┘
       │                                  │
┌──────▼──────┐                    ┌──────▼──────┐
│    Redis    │                    │   MariaDB   │
│  (Bayes DB) │                    │ (Roundcube) │
└─────────────┘                    └─────────────┘
```

### Mail Flow

1. **Inbound:** Client → Postfix (:25/:465/:587) → Rspamd scan → Dovecot LMTP → Maildir
2. **Spam Handling:** Score ≥ 15 → rejected at SMTP; Score ≥ 6 → `X-Spam: Yes` → Sieve → Junk folder
3. **Webmail:** Browser → Nginx (HTTPS) → Roundcube (PHP-FPM) → Dovecot IMAP + Postfix SMTP
4. **Outbound:** Client → Postfix (submission/587, authenticated) → Rspamd (DKIM sign) → Internet

---

## Quick Start

### Prerequisites

- **OS:** Debian 12+ / Ubuntu 22.04+ (any systemd-based Linux)
- **Resources:** 2 CPU cores, 2 GB RAM minimum
- **Root access** (or sudo)
- **Ports available:** 22, 25, 80, 443, 465, 587, 993, 4190
- For production: a registered domain with DNS access

> Docker, Certbot, Fail2ban, UFW, and all dependencies are installed automatically.

### Installation

```bash
# 1. Clone
git clone https://github.com/d13-l1t3/automaildeploy.git
cd automaildeploy

# 2. Configure
cp .env.example .env
nano .env          # Fill in your domain, IP, passwords

# 3. Install (as root)
sudo bash install.sh

# 4. Wait for services to initialize
sleep 15

# 5. Verify everything works
sudo bash run_tests.sh
```

The installer runs 9 automated steps:

| Step | What It Does |
|------|-------------|
| 1/9 | Installs Docker, Certbot, Fail2ban, UFW, utilities |
| 2/9 | Obtains TLS certificates (Let's Encrypt or self-signed) |
| 3/9 | Generates 2048-bit DKIM key pair |
| 4/9 | Renders all service configs from templates |
| 5/9 | Builds and starts 7 Docker containers |
| 6/9 | Configures UFW firewall (only required ports) |
| 7/9 | Sets up Fail2ban jails and log rotation |
| 8/9 | Installs cron jobs (backup, monitoring, cert renewal) |
| 9/9 | Prints DNS records to configure at your provider |

---

## Configuration

All settings are in a single **`.env`** file. Copy from `.env.example` and edit:

### Required Variables

| Variable | Example | Description |
|----------|---------|-------------|
| `MAIL_DOMAIN` | `example.com` | Primary email domain (after the `@`) |
| `MAIL_HOSTNAME` | `mail.example.com` | FQDN of the mail server (MX target) |
| `SERVER_IP` | `203.0.113.10` | Server's public IPv4 address |
| `LETSENCRYPT_EMAIL` | `admin@example.com` | Email for Let's Encrypt notifications |
| `ADMIN_USER` | `admin` | Default admin mailbox username |
| `ADMIN_PASSWORD` | `StrongPass!123` | Admin mailbox password |
| `EXTRA_USERS` | `john:Pass1,jane:Pass2` | Additional mailboxes (comma-separated) |
| `MYSQL_ROOT_PASSWORD` | *(change)* | MariaDB root password |
| `MYSQL_DATABASE` | `roundcubemail` | Roundcube database name |
| `MYSQL_USER` | `roundcube` | Roundcube database user |
| `MYSQL_PASSWORD` | *(change)* | Roundcube database password |
| `RSPAMD_PASSWORD` | *(change)* | Rspamd web UI password |
| `ROUNDCUBE_DES_KEY` | *(24 chars)* | Roundcube encryption key |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LETSENCRYPT_STAGING` | `false` | Use Let's Encrypt staging (for testing) |
| `DOCKER_SUBNET` | `172.28.0.0/16` | Internal Docker network subnet |
| `TZ` | `UTC` | Timezone for all containers |
| `BACKUP_RETENTION_DAYS` | `30` | Days to keep local backups |
| `BACKUP_REMOTE` | *(empty)* | rsync target for remote backups |
| `MONITOR_ALERT_EMAIL` | *(admin)* | Email for health alerts |

> **Note:** Usernames are automatically normalized to lowercase. `Egor`, `EGOR`, and `egor` all create the same mailbox `egor@domain`.

---

## Proof of Concept

**Yes, `run_tests.sh` is a complete Proof of Concept.** It validates 17 categories with 43+ individual assertions:

```bash
sudo bash run_tests.sh
```

| # | Test Category | Assertions | What It Proves |
|---|--------------|------------|----------------|
| 1 | Container Health | 7 | All services start and stay running |
| 2 | SSL/TLS Endpoints | 3 | IMAPS, SMTPS, Submission all have valid TLS |
| 3 | IMAP Authentication | 2 | Correct credentials accepted, wrong rejected |
| 4 | Anti-Relay | 1 | Server refuses unauthorized relay attempts |
| 5 | Self-Delivery | 1 | Admin can send and receive email |
| 6 | Cross-User Delivery | 1 | Mail between different users works |
| 7 | Rspamd Milter | 2 | Anti-spam engine connected to Postfix |
| 8 | GTUBE Spam Rejection | 2 | Known spam pattern detected and blocked |
| 9 | DKIM Signing | 3 | Keys exist, config correct, accessible in container |
| 10 | User Management | 5 | Add, list, remove mailboxes via script |
| 11 | Nginx Proxy | 3 | HTTP→HTTPS redirect, Roundcube + Rspamd UI |
| 12 | Dovecot Sieve | 1 | Default spam filter script deployed |
| 13 | SMTP Banner | 2 | Correct hostname, software version hidden |
| 14 | MariaDB & Roundcube | 2 | Database connected, Roundcube tables created |
| 15 | Rate Limiting | 2 | SMTP rate limits enforced |
| 16 | Fail2ban | 3 | Service running, both jails active |
| 17 | Log Rotation | 3 | Logrotate + backup + monitor crons installed |

Expected output:
```
  Passed:  43
  Failed:  0
  Warnings: 0

  All critical tests passed! ✔
```

The test suite uses only the deployed infrastructure — no mocking, no stubs. Every test hits real running services.

---

## Management Tools

### User Management

```bash
sudo ./manage_users.sh add    john  'SecureP@ss123'   # Create mailbox
sudo ./manage_users.sh remove john                     # Remove mailbox
sudo ./manage_users.sh passwd john  'NewP@ss456'       # Change password
sudo ./manage_users.sh list                            # List all mailboxes
```

### Manual Backup

```bash
sudo ./backup.sh                                       # Local backup
sudo ./backup.sh --remote user@backup-server:/path/    # + remote sync
ls -lh backups/                                        # List backups
```

### Health Check

```bash
sudo ./monitor.sh                                      # Interactive health check
```

### DNS Verification

```bash
./verify_dns.sh                                        # Check all DNS records
```

---

## Security

| Layer | Protection |
|-------|-----------|
| **TLS** | TLSv1.2+ only on all services, strong cipher suites |
| **SASL** | SMTP submission/smtps require authentication |
| **Anti-Relay** | `reject_unauth_destination` blocks open relay |
| **Rate Limiting** | 50 msgs/min, 30 connections/min per client |
| **Fail2ban** | Bans IPs after 5 failed auth attempts (1h ban) |
| **Firewall** | UFW: only SSH + mail ports open, all else denied |
| **DKIM** | 2048-bit RSA signing via Rspamd |
| **SPF/DMARC** | Records auto-generated, ready to paste into DNS |
| **Rspamd** | Bayes classifier, greylisting, phishing detection |
| **Sieve** | Spam auto-filed to Junk folder |
| **HSTS** | HTTP Strict Transport Security on Nginx |
| **Network** | All containers on isolated Docker bridge |
| **Case-insensitive** | Usernames normalized to lowercase (RFC 5321 compliant) |

---

## DNS Records

After installation, `install.sh` prints and saves all required DNS records to `DNS_RECORDS.txt`:

| Type | Record |
|------|--------|
| **A** | `mail.example.com` → `your-server-IP` |
| **MX** | `example.com` → `10 mail.example.com` |
| **TXT (SPF)** | `example.com` → `"v=spf1 mx a ip4:your-IP -all"` |
| **TXT (DKIM)** | `dkim._domainkey.example.com` → `"v=DKIM1; k=rsa; p=..."` |
| **TXT (DMARC)** | `_dmarc.example.com` → `"v=DMARC1; p=quarantine; ..."` |
| **PTR** | `your-IP` → `mail.example.com` (set by hosting provider) |

After adding records, verify them:

```bash
./verify_dns.sh
```

> **Why can't DNS be automated?** DNS records live on your domain registrar's nameservers (Cloudflare, GoDaddy, Namecheap, etc.). Each provider has a different API and dashboard. The `verify_dns.sh` script checks if records are correctly set and tells you exactly what's missing.

---

## Backup & Recovery

### Automated Backups

Installed automatically during `install.sh`:
- **Schedule:** Daily at 2:00 AM (via cron)
- **Retention:** 30 days (configurable via `BACKUP_RETENTION_DAYS`)
- **Contents:** MariaDB dump, Maildir data, DKIM keys, all configs, `.env`

### Remote Backups

Set `BACKUP_REMOTE` in `.env`:

```env
BACKUP_REMOTE=user@backup-server:/backups/automaildeploy/
```

Or run manually:

```bash
sudo ./backup.sh --remote user@192.168.1.50:/backups/
```

### Restore

```bash
# Extract a backup
tar xzf backups/automail-backup-2026-05-17_020000.tar.gz

# Restore configs
cp -r automail-backup-*/config/* config/
cp automail-backup-*/dot-env .env

# Restore DKIM keys
cp -r automail-backup-*/dkim/* dkim/

# Restore database
docker compose exec -T mariadb mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" < automail-backup-*/mariadb-all-databases.sql

# Restore maildir
tar xzf automail-backup-*/maildata.tar.gz

# Reinstall
sudo bash install.sh
```

---

## Monitoring & Alerts

### How It Works

The `monitor.sh` script runs every 5 minutes (via cron) and checks:

| Check | Alert Threshold |
|-------|----------------|
| Container health | Any container down |
| Disk usage | ≥ 85% used |
| TLS certificate expiry | ≤ 14 days remaining |
| Mail queue | ≥ 50 messages pending |
| Log errors | ≥ 10 errors in the last hour |
| Service ports | 993, 465, 443 not responding |

When issues are detected, an **email alert** is sent to the admin mailbox (or `MONITOR_ALERT_EMAIL` if set to an external address).

### Manual Check

```bash
sudo ./monitor.sh
```

---

## Uninstalling

Full cleanup — reverses everything `install.sh` did:

```bash
sudo bash uninstall.sh
```

Options:

```bash
sudo bash uninstall.sh --keep-data       # Preserve mail data and backups
sudo bash uninstall.sh --keep-packages   # Don't touch system packages
sudo bash uninstall.sh --yes             # Skip confirmation prompt
```

What it removes:
- Docker containers, volumes, networks, images
- UFW firewall rules (keeps SSH)
- Fail2ban jail configuration
- Logrotate configuration
- Cron jobs (backup, monitor, cert renewal)
- Generated configs, SSL certificates, DKIM keys
- Mail data and backups (unless `--keep-data`)

---

## Production vs Local Deployment

| Aspect | Local (`.local`/`.test`) | Production |
|--------|--------------------------|------------|
| **TLS Certificate** | Self-signed (auto-generated) | Let's Encrypt (auto-obtained) |
| **DNS Records** | Not needed | Required (A, MX, SPF, DKIM, DMARC, PTR) |
| **PTR Record** | Not applicable | Must be set by hosting provider |
| **Cert Renewal** | No cron (self-signed) | Certbot twice daily |
| **External Mail** | Won't work (no DNS) | Full send/receive capability |
| **Test Suite** | All 43 tests pass ✔ | All 43 tests pass ✔ |

Both modes use the **same codebase** — the installer auto-detects the environment.

### Production Checklist

1. Set a real domain in `.env` (`MAIL_DOMAIN`, `MAIL_HOSTNAME`)
2. Set the server's public IP (`SERVER_IP`)
3. Set `LETSENCRYPT_STAGING=false`
4. Run `sudo bash install.sh`
5. Add all DNS records from `DNS_RECORDS.txt` to your DNS provider
6. Ask your hosting provider to set the PTR record
7. Verify: `./verify_dns.sh`
8. Test: `sudo bash run_tests.sh`

---

## Repository Structure

```
automaildeploy/
├── .env.example                              # Configuration template
├── install.sh                                # 9-step automated installer
├── uninstall.sh                              # Full cleanup / reversal
├── run_tests.sh                              # 43-test PoC suite
├── manage_users.sh                           # Mailbox CRUD operations
├── backup.sh                                 # Backup (local + remote)
├── monitor.sh                                # Health monitoring + email alerts
├── verify_dns.sh                             # DNS record verification
├── docker-compose.yml                        # 7-container orchestration
├── testing_guide.md                          # Demo walkthrough guide
│
├── docker/
│   ├── postfix/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   └── dovecot/
│       ├── Dockerfile
│       └── entrypoint.sh
│
├── config/
│   ├── postfix/
│   │   ├── main.cf.template                  # SMTP config
│   │   └── master.cf.template                # Postfix services
│   ├── dovecot/
│   │   └── dovecot.conf.template             # IMAP/LMTP/Sieve config
│   ├── nginx/
│   │   ├── nginx.conf                        # Global Nginx config
│   │   └── mail.conf.template                # HTTPS vhost
│   ├── rspamd/
│   │   ├── local.d/                          # Rspamd module configs
│   │   └── override.d/                       # Rspamd overrides
│   ├── roundcube/
│   │   └── config.inc.php.template           # Webmail config
│   ├── fail2ban/
│   │   └── automaildeploy.conf               # Jail definitions (reference)
│   └── ssl/                                  # (generated) TLS certificates
│
├── dkim/                                     # (generated) DKIM key pair
├── data/                                     # (generated) Runtime volumes
└── backups/                                  # (generated) Backup archives
```

---

## License

MIT — see [LICENSE](LICENSE)
