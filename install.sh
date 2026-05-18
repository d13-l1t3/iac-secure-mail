#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Automated Mail Server Installation Script
#  Usage:  sudo bash install.sh
#  Requires: .env file in the same directory (copy from .env.example)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_DIR="${SCRIPT_DIR}/config"
DKIM_DIR="${SCRIPT_DIR}/dkim"
DATA_DIR="${SCRIPT_DIR}/data"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }
banner() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $*${NC}"; echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then err "This script must be run as root (sudo)."; exit 1; fi
if [[ ! -f "$ENV_FILE" ]]; then err ".env file not found. Copy .env.example to .env and configure it."; exit 1; fi

banner "AutoMailDeploy — Enterprise Mail Server Installer"

# ── Load configuration ───────────────────────────────────────────────────────
log "Loading configuration from .env …"
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

# Validate required variables
for var in MAIL_DOMAIN MAIL_HOSTNAME SERVER_IP LETSENCRYPT_EMAIL \
           ADMIN_USER ADMIN_PASSWORD MYSQL_ROOT_PASSWORD MYSQL_DATABASE \
           MYSQL_USER MYSQL_PASSWORD RSPAMD_PASSWORD ROUNDCUBE_DES_KEY; do
    if [[ -z "${!var:-}" ]]; then
        err "Required variable $var is empty in .env"; exit 1
    fi
done
log "Configuration validated."

###############################################################################
# 1. Install host dependencies
###############################################################################
banner "1/9 — Installing Host Dependencies"

apt-get update -qq

# Docker
if ! command -v docker &>/dev/null; then
    log "Installing Docker …"
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed."
else
    log "Docker already installed — $(docker --version)"
fi

# Certbot
if ! command -v certbot &>/dev/null; then
    log "Installing Certbot …"
    apt-get install -y -qq certbot
    log "Certbot installed."
else
    log "Certbot already installed — $(certbot --version 2>&1)"
fi

# Utilities needed for password hashing, DKIM, DNS checks, backups, and security
apt-get install -y -qq openssl dnsutils gettext-base logrotate rsync ufw fail2ban 2>/dev/null || \
    apt-get install -y -qq openssl dnsutils gettext-base logrotate rsync 2>/dev/null

###############################################################################
# 2. Obtain SSL/TLS Certificates
###############################################################################
banner "2/9 — Obtaining SSL/TLS Certificates"

SSL_DIR="${CONFIG_DIR}/ssl"
mkdir -p "$SSL_DIR"

# ── Detect whether this is a local/non-public domain ─────────────────────────
# Certbot cannot issue certs for .local, .test, .lan, .internal, RFC-1918 IPs,
# or when the LETSENCRYPT_EMAIL is not a real routable address.
USE_SELFSIGNED=false

# Check domain TLD
case "${MAIL_HOSTNAME}" in
    *.local|*.test|*.lan|*.internal|*.localhost|*.example|*.invalid)
        USE_SELFSIGNED=true
        warn "Non-public domain detected (${MAIL_HOSTNAME}). Will generate self-signed certificate."
        ;;
esac

# Check for private/reserved IP
if [[ "$USE_SELFSIGNED" == "false" ]]; then
    case "${SERVER_IP}" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|127.*|169.254.*)
            USE_SELFSIGNED=true
            warn "Private IP detected (${SERVER_IP}). Will generate self-signed certificate."
            ;;
    esac
fi

# Check if certs already exist in project dir (manual or previous run)
if [[ -f "${SSL_DIR}/fullchain.pem" && -f "${SSL_DIR}/privkey.pem" ]]; then
    log "Certificates already present in ${SSL_DIR}, skipping generation."

elif [[ "$USE_SELFSIGNED" == "true" ]]; then
    # ── Generate self-signed certificate ──────────────────────────────────────
    log "Generating self-signed certificate (valid 365 days) …"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${SSL_DIR}/privkey.pem" \
        -out    "${SSL_DIR}/fullchain.pem" \
        -subj   "/CN=${MAIL_HOSTNAME}/O=AutoMailDeploy/C=US" \
        -addext "subjectAltName=DNS:${MAIL_HOSTNAME},DNS:${MAIL_DOMAIN}" \
        2>/dev/null
    chmod 600 "${SSL_DIR}/privkey.pem"
    log "Self-signed certificate created."
    warn "Browsers and external mail servers will NOT trust this certificate."
    warn "For production, use a real domain and set USE_SELFSIGNED to false."

else
    # ── Let's Encrypt (public domain) ─────────────────────────────────────────
    CERTBOT_FLAGS=()
    if [[ "${LETSENCRYPT_STAGING:-false}" == "true" ]]; then
        CERTBOT_FLAGS+=(--staging)
        warn "Using Let's Encrypt STAGING environment (certs will NOT be trusted)."
    fi

    CERT_LIVE="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
    if [[ -f "${CERT_LIVE}/fullchain.pem" ]]; then
        log "Let's Encrypt certificate already exists for ${MAIL_HOSTNAME}."
    else
        # Stop anything on port 80 temporarily
        if ss -tlnp | grep -q ':80 '; then
            warn "Port 80 is in use. Attempting to free it …"
            fuser -k 80/tcp 2>/dev/null || true
            sleep 2
        fi

        log "Requesting certificate via standalone mode …"
        if certbot certonly --standalone --non-interactive --agree-tos \
            --email "${LETSENCRYPT_EMAIL}" \
            -d "${MAIL_HOSTNAME}" \
            "${CERTBOT_FLAGS[@]+"${CERTBOT_FLAGS[@]}"}"; then
            log "Certificate obtained successfully."
        else
            warn "Standalone failed. Retrying with --preferred-challenges http …"
            if certbot certonly --standalone --non-interactive --agree-tos \
                --email "${LETSENCRYPT_EMAIL}" \
                -d "${MAIL_HOSTNAME}" \
                --preferred-challenges http \
                "${CERTBOT_FLAGS[@]+"${CERTBOT_FLAGS[@]}"}"; then
                log "Certificate obtained on retry."
            else
                warn "Certbot failed. Falling back to self-signed certificate."
                openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                    -keyout "${SSL_DIR}/privkey.pem" \
                    -out    "${SSL_DIR}/fullchain.pem" \
                    -subj   "/CN=${MAIL_HOSTNAME}/O=AutoMailDeploy/C=US" \
                    -addext "subjectAltName=DNS:${MAIL_HOSTNAME},DNS:${MAIL_DOMAIN}" \
                    2>/dev/null
                chmod 600 "${SSL_DIR}/privkey.pem"
                log "Self-signed certificate created as fallback."
            fi
        fi
    fi

    # Copy certs into project SSL dir (if obtained via certbot)
    CERT_LIVE="/etc/letsencrypt/live/${MAIL_HOSTNAME}"
    if [[ -f "${CERT_LIVE}/fullchain.pem" && ! -f "${SSL_DIR}/fullchain.pem" ]]; then
        cp -L "${CERT_LIVE}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
        cp -L "${CERT_LIVE}/privkey.pem"   "${SSL_DIR}/privkey.pem"
        chmod 600 "${SSL_DIR}/privkey.pem"
        log "Certificates copied to ${SSL_DIR}."
    fi

    # Certbot auto-renewal hook (only if certbot succeeded)
    if [[ -f "${CERT_LIVE}/fullchain.pem" ]]; then
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh <<HOOK
#!/usr/bin/env bash
cp -L "${CERT_LIVE}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
cp -L "${CERT_LIVE}/privkey.pem"   "${SSL_DIR}/privkey.pem"
chmod 600 "${SSL_DIR}/privkey.pem"
cd "${SCRIPT_DIR}" && docker compose restart postfix dovecot nginx
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh
        log "Certbot auto-renewal hook installed."
    fi
fi

# Final check — certs must exist at this point
if [[ ! -f "${SSL_DIR}/fullchain.pem" || ! -f "${SSL_DIR}/privkey.pem" ]]; then
    err "SSL certificates not found in ${SSL_DIR}. Cannot continue."
    exit 1
fi
log "SSL/TLS certificates ready."

###############################################################################
# 3. Generate DKIM keys
###############################################################################
banner "3/9 — Generating DKIM Keys"

mkdir -p "$DKIM_DIR"
DKIM_PRIVATE="${DKIM_DIR}/${MAIL_DOMAIN}.dkim.key"
DKIM_PUBLIC="${DKIM_DIR}/${MAIL_DOMAIN}.dkim.pub"
DKIM_SELECTOR="dkim"

if [[ -f "$DKIM_PRIVATE" ]]; then
    log "DKIM key already exists for ${MAIL_DOMAIN}, skipping."
else
    openssl genrsa -out "$DKIM_PRIVATE" 2048 2>/dev/null
    openssl rsa -in "$DKIM_PRIVATE" -pubout -out "$DKIM_PUBLIC" 2>/dev/null
    chmod 600 "$DKIM_PRIVATE"
    log "DKIM key pair generated (selector: ${DKIM_SELECTOR})."
fi

# Extract the public key for DNS (strip header/footer, join lines)
DKIM_DNS_VALUE=$(grep -v '^-' "$DKIM_PUBLIC" | tr -d '\n')

###############################################################################
# 4. Generate configuration files from templates
###############################################################################
banner "4/9 — Generating Service Configurations"

mkdir -p "${DATA_DIR}"/{postfix/spool,postfix/log,dovecot,redis,mariadb,roundcube,rspamd,nginx/log}

# Rspamd runs as _rspamd user (UID varies by image version).
# Clean leftover data from previous runs (wrong ownership causes Permission denied).
if [[ -d "${DATA_DIR}/rspamd" ]]; then
    rm -rf "${DATA_DIR}/rspamd"/*  2>/dev/null || true
fi
chmod 777 "${DATA_DIR}/rspamd"

# Export all variables for envsubst
export MAIL_DOMAIN MAIL_HOSTNAME SERVER_IP ROUNDCUBE_DES_KEY

# Docker creates directories when bind-mount targets don't exist yet.
# Remove any such bogus directories so envsubst can create proper files.
for f in \
    "${CONFIG_DIR}/nginx/mail.conf" \
    "${CONFIG_DIR}/roundcube/config.inc.php" \
    "${CONFIG_DIR}/rspamd/local.d/dkim_signing.conf" \
    "${CONFIG_DIR}/rspamd/local.d/worker-controller.inc"; do
    [[ -d "$f" ]] && rm -rf "$f"
done

# ── Postfix ──────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/postfix/main.cf.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/postfix/main.cf"

sed 's/\r$//' "${CONFIG_DIR}/postfix/master.cf.template" > "${CONFIG_DIR}/postfix/master.cf"

# Virtual domains and mailboxes
# Lowercase usernames — email local parts are case-insensitive (RFC 5321)
ADMIN_LC=$(echo "${ADMIN_USER}" | tr 'A-Z' 'a-z')
echo "${MAIL_DOMAIN}  OK" > "${CONFIG_DIR}/postfix/virtual_mailbox_domains"
echo "${ADMIN_LC}@${MAIL_DOMAIN}  ${MAIL_DOMAIN}/${ADMIN_LC}/Maildir/" \
    > "${CONFIG_DIR}/postfix/virtual_mailbox_maps"

if [[ -n "${EXTRA_USERS:-}" ]]; then
    IFS=',' read -ra PAIRS <<< "$EXTRA_USERS"
    for pair in "${PAIRS[@]}"; do
        uname=$(echo "${pair%%:*}" | tr 'A-Z' 'a-z')
        echo "${uname}@${MAIL_DOMAIN}  ${MAIL_DOMAIN}/${uname}/Maildir/" \
            >> "${CONFIG_DIR}/postfix/virtual_mailbox_maps"
    done
fi
log "Postfix configs generated."

# ── Dovecot ──────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/dovecot/dovecot.conf.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/dovecot/dovecot.conf"

# Generate passwd entries
# openssl passwd -6 produces $6$salt$hash (SHA-512 crypt), Dovecot's {CRYPT} scheme handles this.
ADMIN_HASH=$(openssl passwd -6 "$ADMIN_PASSWORD")
echo "${ADMIN_LC}@${MAIL_DOMAIN}:{CRYPT}${ADMIN_HASH}:::::" \
    > "${CONFIG_DIR}/dovecot/passwd"

if [[ -n "${EXTRA_USERS:-}" ]]; then
    IFS=',' read -ra PAIRS <<< "$EXTRA_USERS"
    for pair in "${PAIRS[@]}"; do
        uname=$(echo "${pair%%:*}" | tr 'A-Z' 'a-z')
        upass="${pair#*:}"
        uhash=$(openssl passwd -6 "$upass")
        echo "${uname}@${MAIL_DOMAIN}:{CRYPT}${uhash}:::::" \
            >> "${CONFIG_DIR}/dovecot/passwd"
    done
fi
chmod 644 "${CONFIG_DIR}/dovecot/passwd"
log "Dovecot configs generated."

# ── Rspamd ───────────────────────────────────────────────────────────────────
# Hash the Rspamd web password (pbkdf2 via controller)
# Fallback: store as plain until first rspamd container start
# Store password as-is; Rspamd accepts plaintext and hashes internally on first use
export RSPAMD_HASHED_PASSWORD="${RSPAMD_PASSWORD}"
envsubst '${RSPAMD_HASHED_PASSWORD}' \
    < "${CONFIG_DIR}/rspamd/local.d/worker-controller.inc.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/rspamd/local.d/worker-controller.inc"

envsubst '${MAIL_DOMAIN}' \
    < "${CONFIG_DIR}/rspamd/local.d/dkim_signing.conf.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/rspamd/local.d/dkim_signing.conf"
log "Rspamd configs generated."

# ── Nginx ────────────────────────────────────────────────────────────────────
envsubst '${MAIL_HOSTNAME}' \
    < "${CONFIG_DIR}/nginx/mail.conf.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/nginx/mail.conf"
log "Nginx configs generated."

# ── Roundcube ────────────────────────────────────────────────────────────────
envsubst '${MAIL_DOMAIN} ${ROUNDCUBE_DES_KEY}' \
    < "${CONFIG_DIR}/roundcube/config.inc.php.template" \
    | sed 's/\r$//' > "${CONFIG_DIR}/roundcube/config.inc.php"
log "Roundcube configs generated."

###############################################################################
# 5. Start Docker infrastructure
###############################################################################
banner "5/9 — Starting Docker Infrastructure"

cd "$SCRIPT_DIR"

# Fix line endings & permissions (in case repo was cloned on Windows)
if command -v dos2unix &>/dev/null; then
    dos2unix manage_users.sh docker/postfix/entrypoint.sh docker/dovecot/entrypoint.sh 2>/dev/null || true
else
    sed -i 's/\r$//' manage_users.sh docker/postfix/entrypoint.sh docker/dovecot/entrypoint.sh 2>/dev/null || true
fi
chmod +x manage_users.sh install.sh
chmod +x docker/postfix/entrypoint.sh docker/dovecot/entrypoint.sh

# Clear stale Postfix spool data from previous runs.
# Bind-mounted spool survives `docker compose down -v`, and stale PID/queue
# files from a dead container can block mail delivery in the new one.
if [[ -d "${DATA_DIR}/postfix/spool" ]]; then
    log "Cleaning stale Postfix spool data …"
    rm -rf "${DATA_DIR}/postfix/spool"/*
fi

docker compose build --quiet
docker compose up -d
log "All containers started."

# Wait for services
log "Waiting for services to become healthy …"
sleep 10

for svc in automail-postfix automail-dovecot automail-rspamd automail-nginx automail-roundcube automail-mariadb automail-redis; do
    if docker ps --format '{{.Names}}' | grep -q "$svc"; then
        echo -e "  ${GREEN}●${NC} ${svc} — running"
    else
        echo -e "  ${RED}●${NC} ${svc} — NOT running"
    fi
done

###############################################################################
# 6. Firewall (UFW)
###############################################################################
banner "6/9 — Configuring Firewall"

if command -v ufw &>/dev/null; then
    ufw default deny incoming  2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    for rule in "22/tcp:SSH" "25/tcp:SMTP" "80/tcp:HTTP" "443/tcp:HTTPS" \
                "465/tcp:SMTPS" "587/tcp:Submission" "993/tcp:IMAPS" "4190/tcp:Sieve"; do
        port="${rule%%:*}"; label="${rule#*:}"
        ufw allow "$port" comment "$label" 2>/dev/null || true
    done
    echo "y" | ufw enable 2>/dev/null || true
    log "UFW firewall configured and enabled."
else
    warn "UFW not available — skipping firewall setup."
fi

###############################################################################
# 7. Fail2ban & Log Rotation
###############################################################################
banner "7/9 — Security & Log Management"

MAIL_LOG_PATH="${DATA_DIR}/postfix/log/mail.log"
touch "$MAIL_LOG_PATH" 2>/dev/null || true

if command -v fail2ban-client &>/dev/null; then
    cat > /etc/fail2ban/jail.d/automaildeploy.conf <<F2BEOF
[DEFAULT]
automail_logpath = ${MAIL_LOG_PATH}

[postfix-sasl]
enabled  = true
port     = smtp,465,submission
filter   = postfix[mode=auth]
logpath  = %(automail_logpath)s
maxretry = 5
findtime = 600
bantime  = 3600

[dovecot]
enabled  = true
port     = imap,imaps
filter   = dovecot[mode=aggressive]
logpath  = %(automail_logpath)s
maxretry = 5
findtime = 600
bantime  = 3600
F2BEOF
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    log "Fail2ban configured — bans IP after 5 failed auth attempts (1h ban)."
else
    warn "Fail2ban not available — skipping."
fi

cat > /etc/logrotate.d/automaildeploy <<LOGEOF
${DATA_DIR}/postfix/log/mail.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGEOF
log "Log rotation configured — 30 days retention, daily rotation."

###############################################################################
# 8. Automated Tasks (Cron)
###############################################################################
banner "8/9 — Setting Up Automated Tasks"

chmod +x "${SCRIPT_DIR}/backup.sh" "${SCRIPT_DIR}/monitor.sh" \
         "${SCRIPT_DIR}/verify_dns.sh" 2>/dev/null || true

CRON_DIR="/etc/cron.d"

cat > "${CRON_DIR}/automaildeploy-backup" <<CRONEOF
0 2 * * * root cd ${SCRIPT_DIR} && bash backup.sh >> ${DATA_DIR}/backup.log 2>&1
CRONEOF
chmod 644 "${CRON_DIR}/automaildeploy-backup"
log "Daily backup cron installed (2:00 AM)."

cat > "${CRON_DIR}/automaildeploy-monitor" <<CRONEOF
*/5 * * * * root cd ${SCRIPT_DIR} && bash monitor.sh --quiet >> ${DATA_DIR}/monitor.log 2>&1
CRONEOF
chmod 644 "${CRON_DIR}/automaildeploy-monitor"
log "Health monitor cron installed (every 5 min)."

if [[ "$USE_SELFSIGNED" == "false" ]]; then
    cat > "${CRON_DIR}/automaildeploy-certrenew" <<CRONEOF
0 3,15 * * * root certbot renew --quiet --deploy-hook "cd ${SCRIPT_DIR} && docker compose restart nginx dovecot postfix"
CRONEOF
    chmod 644 "${CRON_DIR}/automaildeploy-certrenew"
    log "Certificate renewal cron installed (3:00 AM & 3:00 PM)."
else
    log "Self-signed certificate — no renewal cron needed."
fi

###############################################################################
# 9. Print DNS Records
###############################################################################
banner "9/9 — Required DNS Records"

echo -e "${BOLD}Add the following DNS records at your DNS provider:${NC}\n"

echo -e "${CYAN}┌─────────┬──────────────────────────────────────────────────────────────────┐${NC}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "Type" "Value"
echo -e "${CYAN}├─────────┼──────────────────────────────────────────────────────────────────┤${NC}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "A"     "${MAIL_HOSTNAME}.  →  ${SERVER_IP}"
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "MX"    "${MAIL_DOMAIN}.  →  10 ${MAIL_HOSTNAME}."
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "${MAIL_DOMAIN}.  →  \"v=spf1 mx a ip4:${SERVER_IP} -all\""
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "_dmarc.${MAIL_DOMAIN}.  →  \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}\""
printf  "${CYAN}│${NC} %-7s ${CYAN}│${NC} %-64s ${CYAN}│${NC}\n" "TXT"   "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}."
echo -e "${CYAN}└─────────┴──────────────────────────────────────────────────────────────────┘${NC}"

echo -e "\n${BOLD}DKIM TXT Record Value (paste as a single TXT record):${NC}"
echo -e "\"v=DKIM1; k=rsa; p=${DKIM_DNS_VALUE}\"\n"

echo -e "${BOLD}PTR (Reverse DNS):${NC}"
echo -e "Ask your hosting provider to set the PTR record for ${SERVER_IP} → ${MAIL_HOSTNAME}\n"

cat > "${SCRIPT_DIR}/DNS_RECORDS.txt" <<DNSEOF
# AutoMailDeploy — DNS Records for ${MAIL_DOMAIN}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

A Record:
  ${MAIL_HOSTNAME}.  →  ${SERVER_IP}

MX Record:
  ${MAIL_DOMAIN}.  →  10 ${MAIL_HOSTNAME}.

SPF (TXT Record):
  ${MAIL_DOMAIN}.  →  "v=spf1 mx a ip4:${SERVER_IP} -all"

DMARC (TXT Record):
  _dmarc.${MAIL_DOMAIN}.  →  "v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"

DKIM (TXT Record):
  ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}.  →  "v=DKIM1; k=rsa; p=${DKIM_DNS_VALUE}"

PTR (Reverse DNS):
  ${SERVER_IP}  →  ${MAIL_HOSTNAME}
DNSEOF
log "DNS records also saved to ${SCRIPT_DIR}/DNS_RECORDS.txt"
log "Run ${BOLD}./verify_dns.sh${NC} after adding records to verify them."

banner "Installation Complete!"
echo -e "${GREEN}Webmail:${NC}   https://${MAIL_HOSTNAME}"
echo -e "${GREEN}Rspamd:${NC}   https://${MAIL_HOSTNAME}/rspamd/"
echo -e "${GREEN}IMAP:${NC}     ${MAIL_HOSTNAME}:993 (SSL)"
echo -e "${GREEN}SMTP:${NC}     ${MAIL_HOSTNAME}:587 (STARTTLS)"
echo -e "${GREEN}Admin:${NC}    ${ADMIN_USER}@${MAIL_DOMAIN}\n"

echo -e "${BOLD}Management tools:${NC}"
echo -e "  ${CYAN}./manage_users.sh${NC}  — Add/remove mailboxes"
echo -e "  ${CYAN}./backup.sh${NC}        — Run a manual backup"
echo -e "  ${CYAN}./monitor.sh${NC}       — Check system health"
echo -e "  ${CYAN}./verify_dns.sh${NC}    — Verify DNS records"
echo -e "  ${CYAN}./run_tests.sh${NC}     — Run the full test suite\n"

echo -e "${BOLD}Automated tasks:${NC}"
echo -e "  ${GREEN}●${NC} Backups      — daily at 2:00 AM (./backups/)"
echo -e "  ${GREEN}●${NC} Monitoring   — every 5 minutes (email alerts)"
echo -e "  ${GREEN}●${NC} Log rotation — daily, 30 days retention"
echo -e "  ${GREEN}●${NC} Fail2ban     — bans after 5 failed auth attempts"
[[ "${USE_SELFSIGNED:-false}" == "false" ]] && \
    echo -e "  ${GREEN}●${NC} Cert renewal — twice daily via certbot"
echo ""
