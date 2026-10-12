#!/usr/bin/env bash
#
# Servex — Option A: dedicated phone user + password-only-for-them SSH access,
# plus future-proof permissions on shared folders.
#
# Usage:
#   sudo ./scripts/setup-phone-sftp.sh --user phone \
#     --paths "/home/ubuntu/shared,/srv/files" [--password "…"]
#
# What it does:
#   1. Creates the user (if missing) and sets a password (generated if omitted — printed ONCE).
#   2. Adds the user to the owning group of each path (no ownership changes).
#   3. chmod -R g+rwX on each path (existing files).
#   4. Default ACLs (u:<user>:rwX) on each path (future files). Installs `acl` if apt exists.
#   5. Writes an sshd Match block enabling PasswordAuthentication ONLY for this user.
#   6. Validates config and reloads sshd (existing sessions survive).
#
set -euo pipefail

USER_PHONE=""
PATHS=""
PASSWORD=""
NEED_HELP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_PHONE="$2"; shift 2 ;;
    --paths) PATHS="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    -h|--help) NEED_HELP=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$NEED_HELP" = 1 ] || [ -z "$USER_PHONE" ] || [ -z "$PATHS" ]; then
  echo "Usage: sudo $0 --user <name> --paths \"<dir1,dir2>\" [--password <pw>]"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# 1. user ---------------------------------------------------------------
if ! id "$USER_PHONE" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USER_PHONE"
  echo "Created user: $USER_PHONE"
else
  echo "User exists: $USER_PHONE"
fi

GENERATED=0
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
  GENERATED=1
fi
echo "${USER_PHONE}:${PASSWORD}" | chpasswd
echo "Password set."

# 2–4. per-path access ---------------------------------------------------
IFS=',' read -ra DIRS <<< "$PATHS"
for RAW in "${DIRS[@]}"; do
  D=$(echo "$RAW" | xargs)   # trim
  [ -d "$D" ] || { echo "Skipping (not a dir): $D" >&2; continue; }
  GRP=$(stat -c '%G' "$D")
  usermod -aG "$GRP" "$USER_PHONE"
  echo "Added $USER_PHONE to group $GRP (owns $D)"
  chmod -R g+rwX "$D"
  echo "chmod g+rwX done: $D"
  if command -v setfacl >/dev/null 2>&1 || (command -v apt-get >/dev/null 2>&1 && apt-get install -y acl >/dev/null 2>&1); then
    setfacl -R -m "u:${USER_PHONE}:rwX" "$D"
    setfacl -R -d -m "u:${USER_PHONE}:rwX" "$D"
    echo "Default ACLs set: $D"
  else
    echo "WARNING: setfacl unavailable — future owner-only files may need manual chmod." >&2
  fi
done

# 5–6. sshd Match block ---------------------------------------------------
CONF="/etc/ssh/sshd_config.d/99-servex-${USER_PHONE}.conf"
cat > "$CONF" <<EOF
Match User ${USER_PHONE}
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
chmod 644 "$CONF"
sshd -t && echo "sshd config OK."
if systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null; then
  echo "sshd reloaded."
else
  echo "WARNING: could not reload sshd — run 'sudo systemctl reload ssh' manually." >&2
fi

echo
echo "Global password auth: $(sshd -T | grep -i '^passwordauthentication' | awk '{print $2}')"
echo "For ${USER_PHONE}:     $(sshd -T -C user=${USER_PHONE},host=localhost,addr=127.0.0.1 | grep -i '^passwordauthentication' | awk '{print $2}')"
echo
echo "=== Phone settings (MiXplorer → Add storage → SFTP) ==="
echo "URI:      sftp://<your-server>:22<first-path-from---paths>"
echo "Username: ${USER_PHONE}"
if [ "$GENERATED" = 1 ]; then
  echo "Password: ${PASSWORD}   ← generated, shown ONCE. Save it now."
else
  echo "Password: (the one you passed via --password)"
fi
