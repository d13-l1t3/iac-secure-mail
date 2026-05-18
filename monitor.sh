#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Monitoring & Alerting Script
#  Usage:  sudo ./monitor.sh [--quiet]
#
#  Checks: containers, disk, certs, mail queue, recent errors
#  Alerts: sends email to admin (or MONITOR_ALERT_EMAIL) when issues found
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors (disabled in --quiet mode)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

say()  { $QUIET || echo -e "$*"; }
log()  { say "${GREEN}[✔]${NC} $*"; }
warn() { say "${YELLOW}[⚠]${NC} $*"; }
err()  { say "${RED}[✘]${NC} $*"; }

# ── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then echo "ERROR: .env not found" >&2; exit 1; fi
set -a; source "$ENV_FILE"; set +a

DC="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"
ALERT_EMAIL="${MONITOR_ALERT_EMAIL:-${ADMIN_USER}@${MAIL_DOMAIN}}"
ADMIN_LC=$(echo "${ADMIN_USER}" | tr 'A-Z' 'a-z')
ISSUES=()

say "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
say "${CYAN}${BOLD}  AutoMailDeploy — Health Monitor${NC}"
say "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"

# ── Check 1: Container Health ────────────────────────────────────────────────
say "${BOLD}▸ Container Health${NC}"
EXPECTED_CONTAINERS="automail-postfix automail-dovecot automail-rspamd automail-nginx automail-roundcube automail-mariadb automail-redis"
for ctr in $EXPECTED_CONTAINERS; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ctr}$"; then
        log "$ctr — running"
    else
        err "$ctr — DOWN"
        ISSUES+=("Container $ctr is not running")
    fi
done

# ── Check 2: Disk Usage ─────────────────────────────────────────────────────
say "\n${BOLD}▸ Disk Usage${NC}"
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
if [[ "$DISK_USAGE" -ge 90 ]]; then
    err "Disk usage CRITICAL: ${DISK_USAGE}% (${DISK_AVAIL} free)"
    ISSUES+=("Disk usage critical: ${DISK_USAGE}% used, ${DISK_AVAIL} free")
elif [[ "$DISK_USAGE" -ge 85 ]]; then
    warn "Disk usage HIGH: ${DISK_USAGE}% (${DISK_AVAIL} free)"
    ISSUES+=("Disk usage high: ${DISK_USAGE}% used, ${DISK_AVAIL} free")
else
    log "Disk usage OK: ${DISK_USAGE}% (${DISK_AVAIL} free)"
fi

# ── Check 3: TLS Certificate Expiry ─────────────────────────────────────────
say "\n${BOLD}▸ TLS Certificate${NC}"
CERT_FILE="${SCRIPT_DIR}/config/ssl/fullchain.pem"
if [[ -f "$CERT_FILE" ]]; then
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

    if [[ "$DAYS_LEFT" -le 0 ]]; then
        err "Certificate EXPIRED on ${EXPIRY_DATE}"
        ISSUES+=("TLS certificate EXPIRED on ${EXPIRY_DATE}")
    elif [[ "$DAYS_LEFT" -le 14 ]]; then
        warn "Certificate expires in ${DAYS_LEFT} days (${EXPIRY_DATE})"
        ISSUES+=("TLS certificate expires in ${DAYS_LEFT} days")
    else
        log "Certificate valid for ${DAYS_LEFT} more days (expires ${EXPIRY_DATE})"
    fi
else
    err "Certificate file not found at ${CERT_FILE}"
    ISSUES+=("Certificate file missing")
fi

# ── Check 4: Mail Queue ─────────────────────────────────────────────────────
say "\n${BOLD}▸ Mail Queue${NC}"
QUEUE_COUNT=$($DC exec -T postfix mailq 2>/dev/null | grep -c "^[A-F0-9]" || echo 0)
if [[ "$QUEUE_COUNT" -ge 100 ]]; then
    err "Mail queue LARGE: ${QUEUE_COUNT} messages"
    ISSUES+=("Mail queue has ${QUEUE_COUNT} messages (possible delivery problem)")
elif [[ "$QUEUE_COUNT" -ge 50 ]]; then
    warn "Mail queue elevated: ${QUEUE_COUNT} messages"
    ISSUES+=("Mail queue elevated: ${QUEUE_COUNT} messages")
else
    log "Mail queue OK: ${QUEUE_COUNT} message(s)"
fi

# ── Check 5: Recent Errors in Logs ──────────────────────────────────────────
say "\n${BOLD}▸ Recent Errors (last hour)${NC}"
ERROR_COUNT=0

# Postfix errors
PF_ERRORS=$($DC exec -T postfix bash -c 'cat /var/log/mail.log 2>/dev/null | grep -c "fatal\|panic\|error" || echo 0' 2>/dev/null | tr -d '[:space:]')
PF_ERRORS="${PF_ERRORS:-0}"

# Dovecot errors
DV_ERRORS=$($DC logs --since 1h dovecot 2>&1 | grep -ci "fatal\|panic\|error" || true)

ERROR_COUNT=$((PF_ERRORS + DV_ERRORS))
if [[ "$ERROR_COUNT" -ge 10 ]]; then
    err "${ERROR_COUNT} error(s) in the last hour (Postfix: ${PF_ERRORS}, Dovecot: ${DV_ERRORS})"
    ISSUES+=("${ERROR_COUNT} log errors in the last hour")
elif [[ "$ERROR_COUNT" -ge 1 ]]; then
    warn "${ERROR_COUNT} error(s) in the last hour"
else
    log "No errors in the last hour"
fi

# ── Check 6: Service Connectivity ───────────────────────────────────────────
say "\n${BOLD}▸ Service Ports${NC}"
for port_name in "993:IMAPS" "465:SMTPS" "443:HTTPS"; do
    port="${port_name%%:*}"
    name="${port_name#*:}"
    if timeout 3 bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null; then
        log "${name} (port ${port}) — responding"
    else
        err "${name} (port ${port}) — NOT responding"
        ISSUES+=("${name} on port ${port} is not responding")
    fi
done

# ── Summary & Alert ──────────────────────────────────────────────────────────
say ""
if [[ ${#ISSUES[@]} -eq 0 ]]; then
    say "${GREEN}${BOLD}All checks passed — system healthy ✔${NC}\n"
    exit 0
fi

say "${RED}${BOLD}${#ISSUES[@]} issue(s) detected:${NC}"
for issue in "${ISSUES[@]}"; do
    say "  ${RED}•${NC} ${issue}"
done
say ""

# ── Send email alert ─────────────────────────────────────────────────────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "automail-postfix"; then
    ALERT_BODY="AutoMailDeploy Health Alert — $(date)\n"
    ALERT_BODY+="Server: ${MAIL_HOSTNAME}\n"
    ALERT_BODY+="\nIssues detected:\n"
    for issue in "${ISSUES[@]}"; do
        ALERT_BODY+="  • ${issue}\n"
    done
    ALERT_BODY+="\nRun 'sudo ./monitor.sh' on the server for details.\n"

    $DC exec -T postfix bash -c \
        "printf 'Subject: [ALERT] AutoMailDeploy — ${#ISSUES[@]} issue(s) detected\nFrom: postmaster@${MAIL_DOMAIN}\nTo: ${ALERT_EMAIL}\nX-Priority: 1\n\n${ALERT_BODY}\n' | sendmail -t" \
        2>/dev/null && log "Alert email sent to ${ALERT_EMAIL}" \
        || warn "Could not send alert email (Postfix may be down)"
else
    warn "Postfix container down — cannot send alert email"
fi

exit 1
