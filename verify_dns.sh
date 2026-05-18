#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — DNS Record Verification
#  Usage:  ./verify_dns.sh
#
#  Checks all required DNS records using dig and reports ✔/✘ for each.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

if [[ ! -f "$ENV_FILE" ]]; then echo "ERROR: .env not found" >&2; exit 1; fi
set -a; source "$ENV_FILE"; set +a

# Check for dig
if ! command -v dig &>/dev/null; then
    echo -e "${RED}[✘] 'dig' not found. Install with: sudo apt install dnsutils${NC}"
    exit 1
fi

PASS=0; FAIL=0; WARN=0
DKIM_SELECTOR="${DKIM_SELECTOR:-dkim}"

check() {
    local label="$1" status="$2" expected="$3" actual="$4"
    if [[ "$status" == "pass" ]]; then
        echo -e "  ${GREEN}✔${NC} ${label}"
        echo -e "       ${GREEN}→ ${actual}${NC}"
        ((PASS++))
    elif [[ "$status" == "warn" ]]; then
        echo -e "  ${YELLOW}⚠${NC} ${label}"
        echo -e "       ${YELLOW}Expected: ${expected}${NC}"
        echo -e "       ${YELLOW}Got:      ${actual}${NC}"
        ((WARN++))
    else
        echo -e "  ${RED}✘${NC} ${label}"
        echo -e "       ${RED}Expected: ${expected}${NC}"
        echo -e "       ${RED}Got:      ${actual:-<not found>}${NC}"
        ((FAIL++))
    fi
}

echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  AutoMailDeploy — DNS Verification${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"
echo -e "${BOLD}Domain: ${MAIL_DOMAIN} | Server: ${MAIL_HOSTNAME} (${SERVER_IP})${NC}\n"

# ── 1. A Record ─────────────────────────────────────────────────────────────
echo -e "${BOLD}▸ A Record${NC}"
A_RESULT=$(dig +short A "${MAIL_HOSTNAME}" 2>/dev/null | head -1)
if [[ "$A_RESULT" == "$SERVER_IP" ]]; then
    check "A record for ${MAIL_HOSTNAME}" "pass" "$SERVER_IP" "$A_RESULT"
elif [[ -n "$A_RESULT" ]]; then
    check "A record for ${MAIL_HOSTNAME}" "warn" "$SERVER_IP" "$A_RESULT"
else
    check "A record for ${MAIL_HOSTNAME}" "fail" "$SERVER_IP" ""
fi

# ── 2. MX Record ────────────────────────────────────────────────────────────
echo -e "\n${BOLD}▸ MX Record${NC}"
MX_RESULT=$(dig +short MX "${MAIL_DOMAIN}" 2>/dev/null | head -1)
EXPECTED_MX="10 ${MAIL_HOSTNAME}."
if echo "$MX_RESULT" | grep -qi "${MAIL_HOSTNAME}"; then
    check "MX record for ${MAIL_DOMAIN}" "pass" "$EXPECTED_MX" "$MX_RESULT"
elif [[ -n "$MX_RESULT" ]]; then
    check "MX record for ${MAIL_DOMAIN}" "warn" "$EXPECTED_MX" "$MX_RESULT"
else
    check "MX record for ${MAIL_DOMAIN}" "fail" "$EXPECTED_MX" ""
fi

# ── 3. SPF (TXT) Record ─────────────────────────────────────────────────────
echo -e "\n${BOLD}▸ SPF Record${NC}"
SPF_RESULT=$(dig +short TXT "${MAIL_DOMAIN}" 2>/dev/null | grep -i "v=spf1" | head -1 | tr -d '"')
EXPECTED_SPF="v=spf1 mx a ip4:${SERVER_IP} -all"
if [[ -n "$SPF_RESULT" ]] && echo "$SPF_RESULT" | grep -qi "v=spf1"; then
    if echo "$SPF_RESULT" | grep -q "$SERVER_IP"; then
        check "SPF record for ${MAIL_DOMAIN}" "pass" "$EXPECTED_SPF" "$SPF_RESULT"
    else
        check "SPF record for ${MAIL_DOMAIN}" "warn" "$EXPECTED_SPF" "$SPF_RESULT"
    fi
else
    check "SPF record for ${MAIL_DOMAIN}" "fail" "$EXPECTED_SPF" ""
fi

# ── 4. DKIM (TXT) Record ────────────────────────────────────────────────────
echo -e "\n${BOLD}▸ DKIM Record${NC}"
DKIM_RESULT=$(dig +short TXT "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' | tr -d ' ' | head -1)
if [[ -n "$DKIM_RESULT" ]] && echo "$DKIM_RESULT" | grep -qi "v=DKIM1"; then
    check "DKIM record (${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN})" "pass" "v=DKIM1; k=rsa; p=..." "$DKIM_RESULT"
else
    check "DKIM record (${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN})" "fail" "v=DKIM1; k=rsa; p=<your-public-key>" ""
    echo -e "       ${YELLOW}Copy the DKIM value from DNS_RECORDS.txt into your DNS provider${NC}"
fi

# ── 5. DMARC (TXT) Record ───────────────────────────────────────────────────
echo -e "\n${BOLD}▸ DMARC Record${NC}"
DMARC_RESULT=$(dig +short TXT "_dmarc.${MAIL_DOMAIN}" 2>/dev/null | grep -i "v=DMARC1" | head -1 | tr -d '"')
EXPECTED_DMARC="v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"
if [[ -n "$DMARC_RESULT" ]] && echo "$DMARC_RESULT" | grep -qi "v=DMARC1"; then
    check "DMARC record for _dmarc.${MAIL_DOMAIN}" "pass" "$EXPECTED_DMARC" "$DMARC_RESULT"
else
    check "DMARC record for _dmarc.${MAIL_DOMAIN}" "fail" "$EXPECTED_DMARC" ""
fi

# ── 6. PTR (Reverse DNS) ────────────────────────────────────────────────────
echo -e "\n${BOLD}▸ PTR (Reverse DNS)${NC}"
# Build the reverse lookup address
IFS='.' read -ra OCTETS <<< "$SERVER_IP"
REVERSE="${OCTETS[3]}.${OCTETS[2]}.${OCTETS[1]}.${OCTETS[0]}.in-addr.arpa"
PTR_RESULT=$(dig +short PTR "$REVERSE" 2>/dev/null | head -1 | sed 's/\.$//')
EXPECTED_PTR="${MAIL_HOSTNAME}"
if [[ "$PTR_RESULT" == "$EXPECTED_PTR" || "$PTR_RESULT" == "${EXPECTED_PTR}." ]]; then
    check "PTR record for ${SERVER_IP}" "pass" "$EXPECTED_PTR" "$PTR_RESULT"
elif [[ -n "$PTR_RESULT" ]]; then
    check "PTR record for ${SERVER_IP}" "warn" "$EXPECTED_PTR" "$PTR_RESULT"
else
    check "PTR record for ${SERVER_IP}" "fail" "$EXPECTED_PTR" ""
    echo -e "       ${YELLOW}Ask your hosting provider to set PTR for ${SERVER_IP} → ${MAIL_HOSTNAME}${NC}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed: ${PASS}${NC}  ${YELLOW}Warnings: ${WARN}${NC}  ${RED}Failed: ${FAIL}${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"

if [[ $FAIL -gt 0 ]]; then
    echo -e "${YELLOW}Missing records? Copy the values from DNS_RECORDS.txt into your DNS provider.${NC}"
    echo -e "${YELLOW}After adding records, wait 5-30 minutes for propagation, then re-run this script.${NC}\n"
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}Some records have unexpected values — mail may still work but verify carefully.${NC}\n"
    exit 0
else
    echo -e "${GREEN}All DNS records are correctly configured! ✔${NC}\n"
    exit 0
fi
