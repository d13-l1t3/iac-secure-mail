#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Uninstall / Cleanup Script
#  Usage:  sudo bash uninstall.sh [--keep-data] [--keep-packages] [--yes]
#
#  Reverses everything install.sh did:
#    - Stops and removes Docker containers, volumes, networks, images
#    - Removes UFW firewall rules
#    - Removes Fail2ban jail config
#    - Removes logrotate config
#    - Removes cron jobs (backup, monitor, cert renewal)
#    - Removes generated config files, SSL certs, DKIM keys
#    - Optionally removes mail data and backups
#
#  Flags:
#    --keep-data      Keep mail data (data/ and backups/ directories)
#    --keep-packages  Don't remove fail2ban/ufw (they may be used elsewhere)
#    --yes            Skip confirmation prompt
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then err "This script must be run as root (sudo)."; exit 1; fi

KEEP_DATA=false
KEEP_PACKAGES=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-data)     KEEP_DATA=true; shift ;;
        --keep-packages) KEEP_PACKAGES=true; shift ;;
        --yes|-y)        AUTO_YES=true; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  AutoMailDeploy — Uninstaller${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"

echo -e "${BOLD}This will remove:${NC}"
echo -e "  ${RED}●${NC} All Docker containers, volumes, networks, and images"
echo -e "  ${RED}●${NC} UFW firewall rules for mail ports"
echo -e "  ${RED}●${NC} Fail2ban jail configuration"
echo -e "  ${RED}●${NC} Logrotate configuration"
echo -e "  ${RED}●${NC} Cron jobs (backup, monitor, cert renewal)"
echo -e "  ${RED}●${NC} Generated config files (main.cf, passwd, etc.)"
echo -e "  ${RED}●${NC} SSL certificates and DKIM keys"
if [[ "$KEEP_DATA" == "true" ]]; then
    echo -e "  ${GREEN}●${NC} Mail data and backups — ${GREEN}KEPT${NC} (--keep-data)"
else
    echo -e "  ${RED}●${NC} Mail data (data/) and backups (backups/)"
fi
echo ""

if [[ "$AUTO_YES" == "false" ]]; then
    echo -e "${YELLOW}${BOLD}Are you sure? This cannot be undone.${NC}"
    read -rp "Type 'yes' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo -e "\n${GREEN}Cancelled. Nothing was changed.${NC}\n"
        exit 0
    fi
fi

echo ""

###############################################################################
# 1. Stop and remove Docker infrastructure
###############################################################################
echo -e "${BOLD}▸ Removing Docker infrastructure …${NC}"

cd "$SCRIPT_DIR"

if command -v docker &>/dev/null && [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
    # Stop containers and remove volumes + networks
    docker compose down -v --remove-orphans 2>/dev/null && \
        log "Containers, volumes, and networks removed." || \
        warn "docker compose down failed (containers may not exist)"

    # Remove built images
    for img in automaildeploy-postfix automaildeploy-dovecot; do
        if docker image inspect "$img" &>/dev/null; then
            docker image rm "$img" 2>/dev/null && \
                log "Removed image: $img"
        fi
    done
else
    warn "Docker not found or docker-compose.yml missing — skipping"
fi

###############################################################################
# 2. Remove UFW firewall rules
###############################################################################
echo -e "\n${BOLD}▸ Removing firewall rules …${NC}"

if command -v ufw &>/dev/null; then
    for port in 25 80 443 465 587 993 4190; do
        ufw delete allow "${port}/tcp" 2>/dev/null || true
    done
    log "Mail-related UFW rules removed."
    warn "UFW is still enabled. SSH (port 22) rule was NOT removed."
    warn "Run 'sudo ufw status' to verify."
else
    warn "UFW not installed — skipping"
fi

###############################################################################
# 3. Remove Fail2ban configuration
###############################################################################
echo -e "\n${BOLD}▸ Removing Fail2ban configuration …${NC}"

if [[ -f /etc/fail2ban/jail.d/automaildeploy.conf ]]; then
    rm -f /etc/fail2ban/jail.d/automaildeploy.conf
    systemctl restart fail2ban 2>/dev/null || true
    log "Fail2ban jail config removed and service restarted."
else
    log "No Fail2ban config to remove."
fi

###############################################################################
# 4. Remove logrotate configuration
###############################################################################
echo -e "\n${BOLD}▸ Removing logrotate configuration …${NC}"

if [[ -f /etc/logrotate.d/automaildeploy ]]; then
    rm -f /etc/logrotate.d/automaildeploy
    log "Logrotate config removed."
else
    log "No logrotate config to remove."
fi

###############################################################################
# 5. Remove cron jobs
###############################################################################
echo -e "\n${BOLD}▸ Removing cron jobs …${NC}"

REMOVED_CRONS=0
for cron_file in /etc/cron.d/automaildeploy-backup \
                 /etc/cron.d/automaildeploy-monitor \
                 /etc/cron.d/automaildeploy-certrenew; do
    if [[ -f "$cron_file" ]]; then
        rm -f "$cron_file"
        ((REMOVED_CRONS++))
    fi
done
log "Removed ${REMOVED_CRONS} cron job(s)."

###############################################################################
# 6. Remove Let's Encrypt renewal hook
###############################################################################
echo -e "\n${BOLD}▸ Removing certbot renewal hook …${NC}"

if [[ -f /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh ]]; then
    rm -f /etc/letsencrypt/renewal-hooks/deploy/automaildeploy.sh
    log "Certbot deploy hook removed."
else
    log "No certbot hook to remove."
fi

###############################################################################
# 7. Remove generated config files
###############################################################################
echo -e "\n${BOLD}▸ Removing generated config files …${NC}"

GENERATED_FILES=(
    "${SCRIPT_DIR}/config/ssl/fullchain.pem"
    "${SCRIPT_DIR}/config/ssl/privkey.pem"
    "${SCRIPT_DIR}/config/postfix/main.cf"
    "${SCRIPT_DIR}/config/postfix/master.cf"
    "${SCRIPT_DIR}/config/postfix/virtual_mailbox_domains"
    "${SCRIPT_DIR}/config/postfix/virtual_mailbox_maps"
    "${SCRIPT_DIR}/config/postfix/virtual_mailbox_maps.db"
    "${SCRIPT_DIR}/config/postfix/virtual_mailbox_domains.db"
    "${SCRIPT_DIR}/config/dovecot/dovecot.conf"
    "${SCRIPT_DIR}/config/dovecot/passwd"
    "${SCRIPT_DIR}/config/nginx/mail.conf"
    "${SCRIPT_DIR}/config/rspamd/local.d/dkim_signing.conf"
    "${SCRIPT_DIR}/config/rspamd/local.d/worker-controller.inc"
    "${SCRIPT_DIR}/config/roundcube/config.inc.php"
    "${SCRIPT_DIR}/DNS_RECORDS.txt"
)

REMOVED_FILES=0
for f in "${GENERATED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        ((REMOVED_FILES++))
    fi
done
log "Removed ${REMOVED_FILES} generated file(s)."

###############################################################################
# 8. Remove DKIM keys
###############################################################################
echo -e "\n${BOLD}▸ Removing DKIM keys …${NC}"

if [[ -d "${SCRIPT_DIR}/dkim" ]] && ls "${SCRIPT_DIR}/dkim/"*.key &>/dev/null 2>&1; then
    rm -f "${SCRIPT_DIR}/dkim/"*.key "${SCRIPT_DIR}/dkim/"*.pub
    log "DKIM keys removed."
else
    log "No DKIM keys to remove."
fi

###############################################################################
# 9. Remove data and backups (unless --keep-data)
###############################################################################
echo -e "\n${BOLD}▸ Removing data …${NC}"

if [[ "$KEEP_DATA" == "true" ]]; then
    log "Mail data preserved (--keep-data flag)."
    log "  data/    → $(du -sh "${SCRIPT_DIR}/data" 2>/dev/null | cut -f1 || echo 'N/A')"
    log "  backups/ → $(du -sh "${SCRIPT_DIR}/backups" 2>/dev/null | cut -f1 || echo 'N/A')"
else
    if [[ -d "${SCRIPT_DIR}/data" ]]; then
        rm -rf "${SCRIPT_DIR}/data"
        log "Removed data/ directory (mail data, logs, databases)."
    fi
    if [[ -d "${SCRIPT_DIR}/backups" ]]; then
        rm -rf "${SCRIPT_DIR}/backups"
        log "Removed backups/ directory."
    fi
fi

###############################################################################
# 10. Optionally remove packages
###############################################################################
echo -e "\n${BOLD}▸ Installed packages …${NC}"

if [[ "$KEEP_PACKAGES" == "true" ]]; then
    log "Packages preserved (--keep-packages flag)."
else
    warn "Docker, Certbot, Fail2ban, and UFW were NOT removed."
    warn "They may be used by other services on this system."
    warn "To remove them manually:"
    echo -e "    ${CYAN}sudo apt remove --purge fail2ban ufw${NC}"
    echo -e "    ${CYAN}sudo apt remove --purge docker-ce docker-ce-cli containerd.io${NC}"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  Uninstall Complete${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}●${NC} Docker containers, volumes, images — removed"
echo -e "  ${GREEN}●${NC} UFW mail port rules — removed"
echo -e "  ${GREEN}●${NC} Fail2ban jails — removed"
echo -e "  ${GREEN}●${NC} Cron jobs — removed"
echo -e "  ${GREEN}●${NC} Generated configs + SSL + DKIM — removed"
if [[ "$KEEP_DATA" == "true" ]]; then
    echo -e "  ${YELLOW}●${NC} Mail data + backups — preserved"
else
    echo -e "  ${GREEN}●${NC} Mail data + backups — removed"
fi
echo ""
echo -e "${BOLD}To reinstall:${NC} sudo bash install.sh"
echo ""
