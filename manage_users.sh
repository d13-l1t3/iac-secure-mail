#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — User Management Script
#  Usage:
#    sudo ./manage_users.sh add    <username> <password>
#    sudo ./manage_users.sh remove <username>
#    sudo ./manage_users.sh passwd <username> <new_password>
#    sudo ./manage_users.sh list
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PASSWD_FILE="${SCRIPT_DIR}/config/dovecot/passwd"
VMAP_FILE="${SCRIPT_DIR}/config/postfix/virtual_mailbox_maps"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }

# ── Load domain from .env ────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then err ".env not found."; exit 1; fi
set -a; source "$ENV_FILE"; set +a
DOMAIN="${MAIL_DOMAIN}"

usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 add    <username> <password>     — Create a mailbox"
    echo "  $0 remove <username>                — Remove a mailbox"
    echo "  $0 passwd <username> <new_password> — Change password"
    echo "  $0 list                             — List all mailboxes"
    exit 1
}

reload_services() {
    log "Reloading Postfix and Dovecot …"
    cd "$SCRIPT_DIR"
    # Copy updated passwd into Dovecot container and fix permissions.
    # Dovecot auth-worker runs as user 'dovecot', so the file MUST be readable.
    docker compose cp "${PASSWD_FILE}" dovecot:/etc/dovecot/passwd 2>/dev/null || true
    docker compose exec dovecot chmod 644 /etc/dovecot/passwd 2>/dev/null || true
    docker compose exec dovecot doveadm reload 2>/dev/null || true
    # Copy updated virtual maps into Postfix container, THEN postmap the new data
    docker compose cp "${VMAP_FILE}" postfix:/etc/postfix/virtual_mailbox_maps 2>/dev/null || true
    docker compose exec postfix postmap /etc/postfix/virtual_mailbox_maps 2>/dev/null || true
    docker compose exec postfix postfix reload 2>/dev/null || true
    log "Services reloaded."
}

cmd_add() {
    local user pass
    user=$(echo "$1" | tr 'A-Z' 'a-z')
    pass="$2"
    local email="${user}@${DOMAIN}"

    if grep -q "^${email}:" "$PASSWD_FILE" 2>/dev/null; then
        err "User ${email} already exists."; exit 1
    fi

    local hash
    hash=$(openssl passwd -6 "$pass")
    echo "${email}:{CRYPT}${hash}:::::" >> "$PASSWD_FILE"
    echo "${email}  ${DOMAIN}/${user}/Maildir/" >> "$VMAP_FILE"
    chmod 644 "$PASSWD_FILE"
    log "Mailbox ${email} created."
    reload_services
}

cmd_remove() {
    local user="$1"
    local email="${user}@${DOMAIN}"

    if ! grep -q "^${email}:" "$PASSWD_FILE" 2>/dev/null; then
        err "User ${email} does not exist."; exit 1
    fi

    sed -i "/^${email}:/d" "$PASSWD_FILE"
    sed -i "/^${email} /d" "$VMAP_FILE"
    log "Mailbox ${email} removed."
    echo -e "${YELLOW}[⚠]${NC} Mail data in /var/vmail/${DOMAIN}/${user}/ was NOT deleted. Remove manually if needed."
    reload_services
}

cmd_passwd() {
    local user="$1" pass="$2"
    local email="${user}@${DOMAIN}"

    if ! grep -q "^${email}:" "$PASSWD_FILE" 2>/dev/null; then
        err "User ${email} does not exist."; exit 1
    fi

    local hash
    hash=$(openssl passwd -6 "$pass")
    sed -i "s|^${email}:.*|${email}:{CRYPT}${hash}:::::|" "$PASSWD_FILE"
    chmod 644 "$PASSWD_FILE"
    log "Password changed for ${email}."
    reload_services
}

cmd_list() {
    echo -e "${BOLD}Mailboxes for ${DOMAIN}:${NC}"
    if [[ ! -s "$PASSWD_FILE" ]] || ! grep -q "@" "$PASSWD_FILE" 2>/dev/null; then
        echo "  (none)"
    else
        grep "@" "$PASSWD_FILE" | cut -d: -f1 | while read -r addr; do
            echo -e "  ${GREEN}●${NC} ${addr}"
        done
    fi
}

# ── Argument parsing ─────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage

case "$1" in
    add)
        [[ $# -lt 3 ]] && { err "Usage: $0 add <username> <password>"; exit 1; }
        cmd_add "$2" "$3"
        ;;
    remove|rm|del)
        [[ $# -lt 2 ]] && { err "Usage: $0 remove <username>"; exit 1; }
        cmd_remove "$2"
        ;;
    passwd|password)
        [[ $# -lt 3 ]] && { err "Usage: $0 passwd <username> <new_password>"; exit 1; }
        cmd_passwd "$2" "$3"
        ;;
    list|ls)
        cmd_list
        ;;
    *)
        err "Unknown command: $1"
        usage
        ;;
esac
