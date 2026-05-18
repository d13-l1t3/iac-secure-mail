#!/usr/bin/env bash
set -uo pipefail

# Copy generated configs from the read-only mount, stripping any Windows
# carriage-return characters that would make Postfix refuse to parse them.
for f in main.cf master.cf virtual_mailbox_domains virtual_mailbox_maps; do
    src="/etc/postfix/custom/${f}"
    if [[ -f "$src" ]]; then
        sed 's/\r$//' "$src" > "/etc/postfix/${f}"
    else
        echo "WARNING: ${src} not found — skipping" >&2
    fi
done

postmap /etc/postfix/virtual_mailbox_domains 2>/dev/null || true
postmap /etc/postfix/virtual_mailbox_maps    2>/dev/null || true

# Ensure vmail user exists
groupadd -g 5000 vmail 2>/dev/null || true
useradd -u 5000 -g vmail -d /var/vmail -s /usr/sbin/nologin vmail 2>/dev/null || true
mkdir -p /var/vmail
chown vmail:vmail /var/vmail

# ── Fix DNS resolution inside Postfix chroot ──────────────────────────────────
# Postfix on Debian runs smtp/lmtp/cleanup inside a chroot at /var/spool/postfix.
# The chroot does NOT inherit /etc/resolv.conf, so Docker's embedded DNS
# (127.0.0.11) is unreachable. This causes "Host not found" errors when
# Postfix tries to connect to 'dovecot' (LMTP) or 'rspamd' (milter).
CHROOT=/var/spool/postfix
mkdir -p "${CHROOT}/etc"
cp /etc/resolv.conf   "${CHROOT}/etc/resolv.conf"
cp /etc/nsswitch.conf "${CHROOT}/etc/nsswitch.conf"  2>/dev/null || true
cp /etc/hosts         "${CHROOT}/etc/hosts"
cp /etc/services      "${CHROOT}/etc/services"

# ── Fix spool directory ownership ──────────────────────────────────────────────
# Bind-mounted spool may have wrong ownership from previous runs or host OS.
postfix set-permissions 2>/dev/null || true

exec postfix start-fg
