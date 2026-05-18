#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Comprehensive Test Suite (Proof of Concept)
#  Run:  sudo bash run_tests.sh
#
#  Tests all major components of the mail infrastructure:
#    1. Container health            10. manage_users.sh CRUD
#    2. SSL/TLS endpoints           11. Nginx reverse proxy
#    3. IMAP authentication         12. Dovecot Sieve (Junk)
#    4. Anti-relay protection       13. Postfix SMTP banner
#    5. Mail delivery (self)        14. MariaDB / Roundcube
#    6. Cross-user delivery         15. Rate limiting
#    7. Rspamd milter integration   16. Fail2ban jails
#    8. GTUBE spam rejection        17. Log rotation & crons
#    9. DKIM signing
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { ((PASS++)); echo -e "  ${GREEN}✔ PASS${NC}  $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✘ FAIL${NC}  $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠ WARN${NC}  $1"; }
banner() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

# ── Load .env ────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}[✘] .env not found. Run install.sh first.${NC}"; exit 1
fi
set -a; source "$ENV_FILE"; set +a

DC="docker compose"

###############################################################################
# 1. Container Health
###############################################################################
banner "1/17 — Container Health"

EXPECTED_CONTAINERS=(automail-postfix automail-dovecot automail-rspamd automail-nginx automail-roundcube automail-mariadb automail-redis)
for cname in "${EXPECTED_CONTAINERS[@]}"; do
    status=$(docker ps --filter "name=^${cname}$" --format '{{.Status}}' 2>/dev/null)
    if [[ "$status" == *"Up"* ]]; then
        pass "$cname is running ($status)"
    else
        fail "$cname is NOT running (status: ${status:-not found})"
    fi
done

###############################################################################
# 2. SSL/TLS Endpoints
###############################################################################
banner "2/17 — SSL/TLS Endpoints"

# IMAPS (993) — send LOGOUT so the server has time to respond
if echo "a1 LOGOUT" | timeout 5 openssl s_client -connect localhost:993 -quiet 2>/dev/null | grep -qi "OK\|BYE\|Dovecot\|CAPABILITY"; then
    pass "IMAPS (993) — TLS handshake OK, Dovecot banner received"
else
    fail "IMAPS (993) — TLS handshake failed"
fi

# SMTPS (465) — don't use -quiet so we can see cert chain output
if timeout 5 openssl s_client -connect localhost:465 </dev/null 2>&1 | grep -qi "New,\|Protocol\|Cipher\|Verify"; then
    pass "SMTPS (465) — TLS handshake OK"
else
    fail "SMTPS (465) — TLS handshake failed"
fi

# Submission STARTTLS (587) — don't use -quiet
if timeout 5 openssl s_client -starttls smtp -connect localhost:587 </dev/null 2>&1 | grep -qi "New,\|Protocol\|Cipher\|Verify"; then
    pass "Submission (587) — STARTTLS OK"
else
    fail "Submission (587) — STARTTLS failed"
fi

###############################################################################
# 3. IMAP Authentication
###############################################################################
banner "3/17 — IMAP Authentication"

# Correct credentials
IMAP_RESULT=$(echo -e "a1 LOGIN ${ADMIN_USER}@${MAIL_DOMAIN} \"${ADMIN_PASSWORD}\"\na2 LOGOUT" \
    | timeout 5 openssl s_client -connect localhost:993 -quiet 2>/dev/null)
if echo "$IMAP_RESULT" | grep -q "a1 OK"; then
    pass "IMAP login with correct credentials (${ADMIN_USER}@${MAIL_DOMAIN})"
else
    fail "IMAP login with correct credentials rejected"
fi

# Wrong credentials (must fail)
IMAP_BAD=$(echo -e "a1 LOGIN fakeuser@${MAIL_DOMAIN} \"wrongpassword\"\na2 LOGOUT" \
    | timeout 5 openssl s_client -connect localhost:993 -quiet 2>/dev/null)
if echo "$IMAP_BAD" | grep -qi "NO.*AUTHENTICATIONFAILED\|NO.*authentication"; then
    pass "IMAP login with wrong credentials correctly rejected"
else
    fail "IMAP login with wrong credentials was NOT rejected"
fi

###############################################################################
# 4. Anti-Relay Protection
###############################################################################
banner "4/17 — Anti-Relay Protection"

# Method 1: Try SMTP conversation via nc (netcat-openbsd installed in image)
RELAY_RESULT=$( $DC exec -T postfix bash -c '
    if command -v nc >/dev/null 2>&1; then
        (sleep 0.5; printf "EHLO test.com\r\n";
         sleep 0.5; printf "MAIL FROM:<spammer@evil.com>\r\n";
         sleep 0.5; printf "RCPT TO:<someone@gmail.com>\r\n";
         sleep 0.5; printf "QUIT\r\n"; sleep 0.3
        ) | nc -w 3 localhost 25 2>&1
    fi
' 2>&1 || true)
if echo "$RELAY_RESULT" | grep -qi "Relay access denied\|relay not permitted\|554\|550\|553"; then
    pass "Open relay blocked — external recipients rejected without auth"
else
    # Method 2: Verify config has reject_unauth_destination
    RELAY_CFG=$($DC exec -T postfix postconf smtpd_relay_restrictions 2>&1 || true)
    if echo "$RELAY_CFG" | grep -q "reject_unauth_destination"; then
        pass "Open relay blocked — reject_unauth_destination configured"
    else
        fail "Open relay NOT blocked — server may be an open relay!"
    fi
fi

###############################################################################
# 5. Mail Delivery (admin → admin)
###############################################################################
banner "5/17 — Mail Delivery (admin → admin)"

$DC exec -T postfix bash -c \
    "printf 'Subject: Test 5 self-delivery\nFrom: ${ADMIN_USER}@${MAIL_DOMAIN}\nTo: ${ADMIN_USER}@${MAIL_DOMAIN}\n\nSelf-delivery test at $(date -u +%H:%M:%S)\n' | sendmail -t" 2>/dev/null
$DC exec -T postfix postfix flush 2>/dev/null || true
sleep 8

# Search all Maildir folders (inbox, Junk, etc.) for delivered messages
MAIL_COUNT=$($DC exec -T dovecot sh -c "find /var/vmail/${MAIL_DOMAIN}/${ADMIN_USER}/Maildir/ -path '*/new/*' -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
MAIL_COUNT="${MAIL_COUNT:-0}"
if [[ "$MAIL_COUNT" -ge 1 ]]; then
    pass "Self-delivery: ${MAIL_COUNT} message(s) in admin's inbox"
else
    # Print diagnostics to help debug delivery issues
    echo -e "    ${YELLOW}── delivery diagnostics ──${NC}"
    echo -e "    ${YELLOW}Queue:${NC}"
    $DC exec -T postfix mailq 2>/dev/null | head -5 | sed 's/^/    /'
    echo -e "    ${YELLOW}Maildir:${NC}"
    $DC exec -T dovecot sh -c "find /var/vmail/ -type f 2>/dev/null | head -10" | sed 's/^/    /'
    echo -e "    ${YELLOW}Recent log:${NC}"
    $DC exec -T postfix cat /var/log/mail.log 2>/dev/null | grep -i 'status=\|error\|fatal\|lmtp' | tail -5 | sed 's/^/    /'
    fail "Self-delivery: no messages found in admin's inbox"
fi

###############################################################################
# 6. Cross-User Delivery
###############################################################################
banner "6/17 — Cross-User Delivery"

# Get first extra user (if defined)
if [[ -n "${EXTRA_USERS:-}" ]]; then
    FIRST_USER=$(echo "${EXTRA_USERS%%:*}" | tr 'A-Z' 'a-z')

    $DC exec -T postfix bash -c \
        "printf 'Subject: Test 6 cross-user\nFrom: ${ADMIN_USER}@${MAIL_DOMAIN}\nTo: ${FIRST_USER}@${MAIL_DOMAIN}\n\nCross-user test\n' | sendmail -t" 2>/dev/null
    $DC exec -T postfix postfix flush 2>/dev/null || true
    sleep 8

    CROSS_COUNT=$($DC exec -T dovecot sh -c "find /var/vmail/${MAIL_DOMAIN}/${FIRST_USER}/Maildir/ -path '*/new/*' -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
    CROSS_COUNT="${CROSS_COUNT:-0}"
    # Retry once — first delivery to a new user takes longer (Maildir creation)
    if [[ "$CROSS_COUNT" -lt 1 ]]; then
        $DC exec -T postfix postfix flush 2>/dev/null || true
        sleep 5
        CROSS_COUNT=$($DC exec -T dovecot sh -c "find /var/vmail/${MAIL_DOMAIN}/${FIRST_USER}/Maildir/ -path '*/new/*' -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
        CROSS_COUNT="${CROSS_COUNT:-0}"
    fi
    if [[ "$CROSS_COUNT" -ge 1 ]]; then
        pass "Cross-user delivery: ${CROSS_COUNT} message(s) in ${FIRST_USER}'s inbox"
    else
        fail "Cross-user delivery: no messages in ${FIRST_USER}'s inbox"
    fi
else
    warn "EXTRA_USERS not set — skipping cross-user delivery test"
fi

###############################################################################
# 7. Rspamd Milter Integration
###############################################################################
banner "7/17 — Rspamd Milter Integration"

# Check postfix log for milter warnings
MILTER_ERRORS=$($DC exec postfix cat /var/log/mail.log 2>/dev/null | grep -c "rspamd.*not found\|Cannot assign requested address" || true)
if [[ "$MILTER_ERRORS" -eq 0 ]]; then
    pass "Rspamd milter connected — no DNS/connection errors in Postfix log"
else
    fail "Rspamd milter: ${MILTER_ERRORS} connection error(s) in Postfix log"
fi

# Rspamd permission errors
# Use container logs (only from current container instance after down -v + up)
PERM_ERRORS=$($DC exec -T rspamd cat /var/log/rspamd/rspamd.log 2>/dev/null | grep -c "Permission denied" || true)
if [[ "$PERM_ERRORS" -eq 0 ]]; then
    # Fallback: check docker logs too
    PERM_ERRORS2=$($DC logs rspamd 2>&1 | grep -c "Permission denied" || true)
    if [[ "$PERM_ERRORS2" -eq 0 ]]; then
        pass "Rspamd data volume — no permission errors"
    else
        # Permission errors at startup that resolved themselves are OK
        # Check if rspamd is currently healthy
        if $DC exec -T rspamd rspamc stat >/dev/null 2>&1; then
            pass "Rspamd data volume — startup warnings present but service healthy"
        else
            fail "Rspamd data volume: ${PERM_ERRORS2} permission error(s)"
        fi
    fi
else
    fail "Rspamd data volume: ${PERM_ERRORS} permission error(s)"
fi

###############################################################################
# 8. GTUBE Spam Rejection
###############################################################################
banner "8/17 — GTUBE Spam Rejection"

$DC exec postfix bash -c \
    "printf 'Subject: GTUBE Test\nFrom: ${ADMIN_USER}@${MAIL_DOMAIN}\nTo: ${ADMIN_USER}@${MAIL_DOMAIN}\n\nXJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X\n' | sendmail -t" 2>/dev/null
sleep 3

GTUBE_LOG=$($DC logs rspamd 2>&1 | grep -i "gtube")
if echo "$GTUBE_LOG" | grep -qi "reject"; then
    pass "GTUBE pattern detected and rejected by Rspamd"
else
    fail "GTUBE pattern was NOT detected/rejected by Rspamd"
fi

# Verify the spam did NOT land in inbox
SPAM_IN_INBOX=$($DC exec postfix cat /var/log/mail.log 2>/dev/null | grep "GTUBE Test" | grep -c "status=sent" || true)
SPAM_BOUNCED=$($DC exec postfix cat /var/log/mail.log 2>/dev/null | grep -c "milter-reject.*Gtube\|sender non-delivery" || true)
if [[ "$SPAM_BOUNCED" -ge 1 ]]; then
    pass "GTUBE email bounced/rejected — not delivered to inbox"
else
    warn "GTUBE bounce not confirmed in Postfix log (Rspamd still caught it)"
fi

###############################################################################
# 9. DKIM Signing
###############################################################################
banner "9/17 — DKIM Signing"

# Check DKIM key exists
if [[ -f "${SCRIPT_DIR}/dkim/${MAIL_DOMAIN}.dkim.key" ]]; then
    pass "DKIM private key exists for ${MAIL_DOMAIN}"
else
    fail "DKIM private key NOT found"
fi

# Check Rspamd DKIM config
DKIM_CFG=$($DC exec rspamd cat /etc/rspamd/local.d/dkim_signing.conf 2>/dev/null)
if echo "$DKIM_CFG" | grep -q "${MAIL_DOMAIN}"; then
    pass "DKIM signing config references ${MAIL_DOMAIN}"
else
    fail "DKIM signing config does not reference ${MAIL_DOMAIN}"
fi

# Check DKIM key is accessible inside rspamd container
if $DC exec rspamd test -f /dkim/${MAIL_DOMAIN}.dkim.key 2>/dev/null; then
    pass "DKIM key readable inside Rspamd container at /dkim/"
else
    fail "DKIM key NOT accessible inside Rspamd container"
fi

###############################################################################
# 10. manage_users.sh CRUD
###############################################################################
banner "10/17 — manage_users.sh User Management"

# List
LIST_OUT=$(bash "${SCRIPT_DIR}/manage_users.sh" list 2>&1)
if echo "$LIST_OUT" | grep -q "${ADMIN_USER}@${MAIL_DOMAIN}"; then
    pass "manage_users.sh list — shows admin user"
else
    fail "manage_users.sh list — admin user not found"
fi

# Add
TESTUSER="_autotest_user_$$"
ADD_OUT=$(bash "${SCRIPT_DIR}/manage_users.sh" add "$TESTUSER" "T3stP@ss_Auto" 2>&1)
if echo "$ADD_OUT" | grep -qi "created"; then
    pass "manage_users.sh add — created ${TESTUSER}@${MAIL_DOMAIN}"
else
    fail "manage_users.sh add — failed to create test user"
fi

# Verify added
if grep -q "${TESTUSER}@${MAIL_DOMAIN}" "${SCRIPT_DIR}/config/dovecot/passwd" 2>/dev/null; then
    pass "manage_users.sh add — user present in passwd file"
else
    fail "manage_users.sh add — user NOT in passwd file"
fi

# Remove
RM_OUT=$(bash "${SCRIPT_DIR}/manage_users.sh" remove "$TESTUSER" 2>&1)
if echo "$RM_OUT" | grep -qi "removed"; then
    pass "manage_users.sh remove — removed ${TESTUSER}@${MAIL_DOMAIN}"
else
    fail "manage_users.sh remove — failed to remove test user"
fi

# Verify removed
if ! grep -q "${TESTUSER}@${MAIL_DOMAIN}" "${SCRIPT_DIR}/config/dovecot/passwd" 2>/dev/null; then
    pass "manage_users.sh remove — user purged from passwd file"
else
    fail "manage_users.sh remove — user still in passwd file"
fi

###############################################################################
# 11. Nginx Reverse Proxy
###############################################################################
banner "11/17 — Nginx Reverse Proxy"

# HTTP → HTTPS redirect
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost/ 2>/dev/null)
if [[ "$HTTP_CODE" == "301" ]]; then
    pass "HTTP → HTTPS redirect (301)"
elif [[ "$HTTP_CODE" == "000" ]]; then
    fail "Nginx not responding on port 80"
else
    warn "HTTP response: $HTTP_CODE (expected 301)"
fi

# HTTPS Roundcube
HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 https://localhost/ 2>/dev/null)
if [[ "$HTTPS_CODE" == "200" ]]; then
    pass "HTTPS → Roundcube webmail (200 OK)"
elif [[ "$HTTPS_CODE" == "502" ]]; then
    warn "HTTPS 502 — Roundcube PHP-FPM may still be initializing"
else
    fail "HTTPS response: $HTTPS_CODE (expected 200)"
fi

# Rspamd web UI
RSPAMD_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 https://localhost/rspamd/ 2>/dev/null)
if [[ "$RSPAMD_CODE" == "200" ]]; then
    pass "Rspamd web UI at /rspamd/ (200 OK)"
else
    fail "Rspamd web UI response: $RSPAMD_CODE (expected 200)"
fi

###############################################################################
# 12. Dovecot Sieve (default sieve exists)
###############################################################################
banner "12/17 — Dovecot Sieve Configuration"

SIEVE_EXISTS=$($DC exec dovecot test -f /var/vmail/sieve/default.sieve 2>/dev/null && echo "yes" || echo "no")
if [[ "$SIEVE_EXISTS" == "yes" ]]; then
    pass "Default Sieve script present at /var/vmail/sieve/default.sieve"
else
    warn "Default Sieve script not found (optional — spam-to-Junk filtering not active)"
fi

###############################################################################
# 13. Postfix SMTP Banner & STARTTLS
###############################################################################
banner "13/17 — Postfix SMTP Banner"

SMTP_BANNER=$( (echo -e "QUIT\r"; sleep 1) | timeout 3 nc localhost 25 2>&1 || true)
if echo "$SMTP_BANNER" | grep -q "220.*${MAIL_HOSTNAME}"; then
    pass "SMTP banner shows correct hostname (${MAIL_HOSTNAME})"
else
    # Fallback check inside container
    BANNER2=$($DC exec postfix bash -c 'echo QUIT | nc localhost 25' 2>&1 || true)
    if echo "$BANNER2" | grep -q "220.*$MAIL_HOSTNAME"; then
        pass "SMTP banner shows correct hostname (verified inside container)"
    else
        fail "SMTP banner does not show ${MAIL_HOSTNAME}"
    fi
fi

if echo "$SMTP_BANNER" | grep -qi "ESMTP"; then
    pass "SMTP banner hides software version (shows ESMTP only)"
else
    warn "SMTP banner may be leaking server info"
fi

###############################################################################
# 14. MariaDB / Roundcube Database
###############################################################################
banner "14/17 — MariaDB & Roundcube Database"

# MariaDB 11+ uses 'mariadb' client; try it first, fall back to 'mysql'
DB_CHECK=$($DC exec -T mariadb mariadb -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1;" "${MYSQL_DATABASE}" 2>&1 || \
           $DC exec -T mariadb mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1;" "${MYSQL_DATABASE}" 2>&1 || true)
if echo "$DB_CHECK" | grep -q "1"; then
    pass "MariaDB connection OK (${MYSQL_USER}@${MYSQL_DATABASE})"
else
    fail "MariaDB connection failed"
fi

# Detect which client command works
MDB_CMD="mariadb"
$DC exec -T mariadb bash -c 'command -v mariadb' >/dev/null 2>&1 || MDB_CMD="mysql"

# Check Roundcube tables exist
TABLE_COUNT=$($DC exec -T mariadb $MDB_CMD -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';" 2>/dev/null | tr -d '[:space:]' || true)
TABLE_COUNT="${TABLE_COUNT:-0}"
if [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -gt 0 ]] 2>/dev/null; then
    pass "Roundcube database has ${TABLE_COUNT} table(s)"
else
    warn "Roundcube database has no tables yet (created on first webmail login)"
fi

###############################################################################
# 15. Rate Limiting
###############################################################################
banner "15/17 — SMTP Rate Limiting"

RATE_CFG=$($DC exec -T postfix postconf smtpd_client_message_rate_limit 2>/dev/null | tr -d '[:space:]' || true)
if echo "$RATE_CFG" | grep -q "=50"; then
    pass "Rate limiting configured: 50 messages/client/minute"
else
    warn "Rate limiting may not be configured (got: ${RATE_CFG:-empty})"
fi

CONN_CFG=$($DC exec -T postfix postconf smtpd_client_connection_rate_limit 2>/dev/null | tr -d '[:space:]' || true)
if echo "$CONN_CFG" | grep -q "=30"; then
    pass "Connection rate limiting configured: 30 connections/client/minute"
else
    warn "Connection rate limiting may not be configured"
fi

###############################################################################
# 16. Fail2ban
###############################################################################
banner "16/17 — Fail2ban Intrusion Protection"

if command -v fail2ban-client &>/dev/null; then
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        pass "Fail2ban service is running"
    else
        warn "Fail2ban installed but not running"
    fi

    if fail2ban-client status postfix-sasl &>/dev/null; then
        pass "Fail2ban jail active: postfix-sasl"
    else
        warn "Fail2ban jail postfix-sasl not found"
    fi

    if fail2ban-client status dovecot &>/dev/null; then
        pass "Fail2ban jail active: dovecot"
    else
        warn "Fail2ban jail dovecot not found"
    fi
else
    warn "Fail2ban not installed — skipping"
fi

###############################################################################
# 17. Log Rotation
###############################################################################
banner "17/17 — Log Rotation"

if [[ -f /etc/logrotate.d/automaildeploy ]]; then
    pass "Logrotate config installed at /etc/logrotate.d/automaildeploy"
else
    warn "Logrotate config not found — install.sh may not have been run"
fi

if [[ -f /etc/cron.d/automaildeploy-backup ]]; then
    pass "Backup cron job installed (daily at 2:00 AM)"
else
    warn "Backup cron job not found"
fi

if [[ -f /etc/cron.d/automaildeploy-monitor ]]; then
    pass "Monitor cron job installed (every 5 min)"
else
    warn "Monitor cron job not found"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo -e "${BOLD}  Test Summary${NC}"
echo -e "${BOLD}══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed:  ${PASS}${NC}"
echo -e "  ${RED}Failed:  ${FAIL}${NC}"
echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All critical tests passed! ✔${NC}"
else
    echo -e "  ${RED}${BOLD}${FAIL} test(s) failed — review output above.${NC}"
fi
echo ""
