#!/usr/bin/env bash
###############################################################################
#  AutoMailDeploy — Backup Script
#  Usage:  sudo ./backup.sh [--remote user@host:/path/]
#
#  Backs up: MariaDB, Maildir, DKIM keys, configs, .env
#  Retention: configurable via BACKUP_RETENTION_DAYS in .env (default: 30)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✘]${NC} $*" >&2; }

# ── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then err ".env not found."; exit 1; fi
set -a; source "$ENV_FILE"; set +a

BACKUP_DIR="${SCRIPT_DIR}/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
BACKUP_NAME="automail-backup-${TIMESTAMP}"
WORK_DIR="${BACKUP_DIR}/${BACKUP_NAME}"
DC="docker compose -f ${SCRIPT_DIR}/docker-compose.yml"

# Parse CLI args
REMOTE_TARGET="${BACKUP_REMOTE:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) REMOTE_TARGET="$2"; shift 2 ;;
        --remote=*) REMOTE_TARGET="${1#*=}"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  AutoMailDeploy — Backup${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"

mkdir -p "$WORK_DIR"

# ── 1. MariaDB dump ──────────────────────────────────────────────────────────
log "Dumping MariaDB database …"
MDB_CMD="mariadb-dump"
$DC exec -T mariadb bash -c "command -v mariadb-dump" >/dev/null 2>&1 || MDB_CMD="mysqldump"
$DC exec -T mariadb $MDB_CMD \
    -uroot -p"${MYSQL_ROOT_PASSWORD}" \
    --all-databases --single-transaction \
    > "${WORK_DIR}/mariadb-all-databases.sql" 2>/dev/null
log "Database dump: $(du -sh "${WORK_DIR}/mariadb-all-databases.sql" | cut -f1)"

# ── 2. Maildir data ─────────────────────────────────────────────────────────
log "Backing up Maildir data …"
if [[ -d "${SCRIPT_DIR}/data" ]]; then
    tar czf "${WORK_DIR}/maildata.tar.gz" \
        -C "${SCRIPT_DIR}" data/ 2>/dev/null || warn "Some files could not be archived"
    log "Maildir archive: $(du -sh "${WORK_DIR}/maildata.tar.gz" | cut -f1)"
else
    warn "No data/ directory found, skipping Maildir backup"
fi

# ── 3. DKIM keys ────────────────────────────────────────────────────────────
log "Backing up DKIM keys …"
if [[ -d "${SCRIPT_DIR}/dkim" ]]; then
    cp -r "${SCRIPT_DIR}/dkim" "${WORK_DIR}/dkim"
    log "DKIM keys backed up"
else
    warn "No dkim/ directory found"
fi

# ── 4. Configuration ────────────────────────────────────────────────────────
log "Backing up configuration …"
cp -r "${SCRIPT_DIR}/config" "${WORK_DIR}/config"
cp "${SCRIPT_DIR}/.env" "${WORK_DIR}/dot-env"
log "Configs backed up"

# ── 5. Create final archive ─────────────────────────────────────────────────
log "Creating compressed archive …"
ARCHIVE="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
tar czf "$ARCHIVE" -C "$BACKUP_DIR" "$BACKUP_NAME"
rm -rf "$WORK_DIR"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
log "Backup complete: ${ARCHIVE} (${ARCHIVE_SIZE})"

# ── 6. Remote sync (optional) ───────────────────────────────────────────────
if [[ -n "$REMOTE_TARGET" ]]; then
    log "Syncing to remote: ${REMOTE_TARGET} …"
    if command -v rsync &>/dev/null; then
        if rsync -az --progress "$ARCHIVE" "${REMOTE_TARGET}"; then
            log "Remote sync complete"
        else
            err "Remote sync failed — backup is saved locally at ${ARCHIVE}"
        fi
    else
        err "rsync not installed. Install with: apt install rsync"
        err "Backup is saved locally at ${ARCHIVE}"
    fi
fi

# ── 7. Cleanup old backups ──────────────────────────────────────────────────
DELETED=$(find "$BACKUP_DIR" -name "automail-backup-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete -print | wc -l)
if [[ "$DELETED" -gt 0 ]]; then
    log "Cleaned up ${DELETED} backup(s) older than ${RETENTION_DAYS} days"
fi

echo -e "\n${GREEN}${BOLD}Backup saved to: ${ARCHIVE}${NC}"
[[ -n "$REMOTE_TARGET" ]] && echo -e "${GREEN}Also synced to: ${REMOTE_TARGET}${NC}"
echo ""
