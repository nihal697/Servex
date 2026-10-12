#!/usr/bin/env bash
#
# Servex — Option B: phone-only SSH key that logs in AS the owner,
# restricted to SFTP (files only, no shell).
#
# Usage (run AS THE OWNER, not root):
#   ./scripts/make-owner-key.sh [--comment phone-sftp] [--type ed25519] [--out ~/.ssh/phone_sftp]
#
# What it does:
#   1. Generates a keypair (no passphrase — the restriction below is the protection).
#   2. Appends the pubkey to ~/.ssh/authorized_keys with
#      restrict,command="<sftp-server>" (stolen phone ⇒ files only, never a shell).
#   3. Verifies: SFTP listing works, SSH shell attempt returns nothing.
#   4. Prints how to get the private key onto the phone + how to revoke it.
#
set -euo pipefail

COMMENT="phone-sftp"
TYPE="ed25519"
OUT="$HOME/.ssh/phone_sftp"

while [ $# -gt 0 ]; do
  case "$1" in
    --comment) COMMENT="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--comment C] [--type ed25519|rsa] [--out PATH]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as the OWNER user (not root/sudo) so key paths land in the right ~/.ssh." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
chmod 700 "$(dirname "$OUT")"

if [ "$TYPE" = "rsa" ]; then
  ssh-keygen -t rsa -b 3072 -f "$OUT" -N "" -C "$COMMENT"
else
  ssh-keygen -t ed25519 -f "$OUT" -N "" -C "$COMMENT"
fi
chmod 600 "$OUT"

SFTP_SERVER="$(command -v sftp-server || echo /usr/lib/openssh/sftp-server)"
[ -x "$SFTP_SERVER" ] || SFTP_SERVER="/usr/lib/openssh/sftp-server"

touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
cp "$HOME/.ssh/authorized_keys" "$HOME/.ssh/authorized_keys.bak.$(date +%F)" 2>/dev/null || true
grep -q "$COMMENT" "$HOME/.ssh/authorized_keys" && sed -i "/$COMMENT/d" "$HOME/.ssh/authorized_keys"
PUB=$(cat "${OUT}.pub")
echo "restrict,command=\"$SFTP_SERVER\" $PUB" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
echo "Public key installed (SFTP-only). Backup: ~/.ssh/authorized_keys.bak.$(date +%F)"

ME="$(whoami)"
echo
echo "--- verifying SFTP works ---"
printf 'pwd\nquit\n' | sftp -b - -i "$OUT" -o StrictHostKeyChecking=no "$ME"@127.0.0.1
echo "--- verifying shell is blocked (expect NO output below) ---"
timeout 5 ssh -i "$OUT" -o StrictHostKeyChecking=no -o BatchMode=yes "$ME"@127.0.0.1 "echo SHELL_WORKS" || true

echo
echo "=== Next steps ==="
echo "1. Copy the PRIVATE key to your phone (HTTP file browser / scp / USB):"
echo "     $OUT"
echo "2. Phone settings → SFTP: host=<server>, port=22, user=$ME, no password,"
echo "   key file = the copied private key (MiXplorer: Advanced → key_path=<path>)."
echo "3. Delete the transfer copy from the server after import."
echo "4. Lost phone? Revoke instantly:  sed -i '/$COMMENT/d' ~/.ssh/authorized_keys"
