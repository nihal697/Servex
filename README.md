# Servex

Access **any Ubuntu server's** files from your phone over **SFTP** — browse, upload, download, rename, just like a local folder. Works with any file manager that supports SFTP (MiXplorer, Material Files, Solid Explorer, …).

> Tested on: Oracle Cloud Ubuntu 22.04 + MiXplorer on Android. The server side is plain OpenSSH, so it works anywhere Ubuntu runs.

---

## Why SFTP instead of an HTTP file link?

| HTTP file browser link | SFTP in your file manager |
|---|---|
| View/download in a browser tab | Native folder: cut / copy / paste / rename / edit |
| Separate login, clunky uploads on mobile | Background transfers, offline queue |
| Needs the web app running | Needs only SSH (port 22), which you already have |

SFTP is just the file-transfer part of SSH. If you can `ssh user@server`, SFTP already works — you only need the right login for your phone.

## How it works

```
Phone (MiXplorer) ── SFTP, port 22 ──▶ Ubuntu server (/home/ubuntu, or any path)
                                          ├─ Option A: dedicated `phone` user + password
                                          │   (password login enabled ONLY for that user)
                                          └─ Option B (recommended): login AS the owner
                                              via a phone-only SSH key, restricted to
                                              files-only (no shell even if phone is stolen)
```

Both options can coexist. Option A is easiest to type; Option B never breaks on permissions, even for files created later with owner-only modes.

---

## Prerequisites

- Ubuntu server (20.04/22.04/24.04) with `sudo` access
- A hostname or IP that reaches it from your phone (public IP, DuckDNS, Tailscale, …)
- Port **22** reachable: cloud firewall (e.g. Oracle VCN ingress `0.0.0.0/0 TCP 22`) **and** host firewall (`sudo ufw allow 22/tcp`)
- Verify from anywhere: `ssh your-user@your-server` works

## Quick start (script)

```bash
git clone https://github.com/<you>/Servex.git
cd Servex
chmod +x scripts/*.sh

# 1. Password login for the phone (Option A) + future-proof permissions
sudo ./scripts/setup-phone-sftp.sh --user phone \
  --paths "/home/ubuntu/shared,/srv/files"

# 2. Owner key login (Option B, recommended)
./scripts/make-owner-key.sh --comment phone-sftp
```

The scripts print the exact values to enter on your phone. Details of what they do are in [MANUAL SETUP](#manual-setup) below.

---

## Manual setup

### Option A — dedicated phone user + password (no key files on phone)

Ubuntu servers typically have `PasswordAuthentication no` globally. Instead of weakening that, allow passwords **only for the phone user**:

```bash
# 1. Create the user (pick any name, e.g. `phone`)
sudo useradd -m -s /bin/bash phone
sudo passwd phone            # set a strong password

# 2. Give it access to your files WITHOUT changing owners:
#    add it to the group that owns your files (usually your own group)
sudo usermod -aG ubuntu phone

# 3. Open the permission bits on the folders it'll use
sudo chmod -R g+rwX /home/ubuntu/shared

# 4. Password login for THIS user only (everyone else stays key-only)
sudo tee /etc/ssh/sshd_config.d/99-servex-phone.conf > /dev/null <<'EOF'
Match User phone
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF

# 5. Validate + reload (reload, not restart — existing sessions survive)
sudo sshd -t && sudo systemctl reload ssh

# 6. Confirm the split: global stays "no", phone user is "yes"
sudo sshd -T | grep -i passwordauthentication
#   → passwordauthentication no
sudo sshd -T -C user=phone,host=localhost,addr=127.0.0.1 | grep -i passwordauthentication
#   → passwordauthentication yes
```

Phone settings for Option A:

```
URI:      sftp://your-server:22/home/ubuntu/shared
Username: phone
Password: <what you set>
```

> If you jailed the user (next section), the URI changes to the in-jail paths,
> e.g. `sftp://your-server:22/shared/...` — the jail root, not `/home/...`.

### SFTP-only jail (recommended hardening)

> **Field note:** we ran this jail for a day, then retired the `ChrootDirectory`
> half — allowlisting every folder the phone needs meant rebuilding the whole
> home view mount-by-mount. Kept: `nologin` shell + `ForceCommand internal-sftp`
> (no terminal ever) with the full view. Real secrets stay protected by their
> own file bits (`600`, `opc`-owned keys), which never depended on the chroot.
> Use the chroot below only if you truly want a scoped-down view.

A password user with a normal shell is the weakest part of Option A: a leaked
password means a terminal. Jail them to files-only with no shell:

```bash
# 1. Jail root must be root-owned (chroot requirement). Mount --bind only the
#    folders the phone needs (same filesystem → existing chmod/ACLs apply).
sudo mkdir -p /home/phone/shared
sudo mount --bind /home/ubuntu/shared /home/mixplorer/shared
#    persist across reboots (escape spaces as \040):
echo "/home/ubuntu/shared /home/phone/shared none bind,nofail 0 0" | sudo tee -a /etc/fstab

sudo chown root:root /home/phone && sudo chmod 755 /home/phone
sudo usermod -s /usr/sbin/nologin phone

# 2. So both sides can always edit each other's files:
#    setgid (new files inherit the shared group) + default ACLs for BOTH users
sudo find /home/ubuntu/shared -type d -exec chmod g+s {} +
sudo setfacl -R -d -m u:phone:rwX,u:ubuntu:rwX /home/ubuntu/shared

# 3. sshd Match block additions (keep the password/forwarder lines from Option A):
#      ChrootDirectory /home/phone
#      ForceCommand internal-sftp -u 0002
sudo sshd -t && sudo systemctl reload ssh
```

Two subtleties we learned the hard way:
- **Never `chown`/`chmod` a bind-mountpoint** expecting to affect only it — it changes the *source* dir (we once flipped a work folder to `root:root` this way; revert with `chown ubuntu:ubuntu` + `chmod 2775`).
- **The `-u 0002` umask can't widen modes the client doesn't request** (most clients propose `644`), so phone uploads may still arrive group-read-only. Fix with a normalizer cron that hands ownership to the main user while keeping the phone's ACL entry:
  ```
  */5 * * * * root find /home/ubuntu/shared -user phone -exec chown ubuntu:ubuntu {} + -exec setfacl -m u:phone:rw-,g::rw-,m::rw-,o::r-- {} +
  ```
  Verified both directions: owner edits, phone overwrites in place, phone deletes — all keep working after normalization.
### Future-proof permissions (so new files don't lock the phone out)

Some tools create files/folders owner-only (`700`/`600`). Your phone user then gets "Permission denied" on new stuff. Two fixes:

```bash
# one-time fix for existing files
sudo chmod -R g+rwX /path/to/shared

# permanent: new files inherit access automatically (needs the `acl` package)
sudo apt-get install -y acl
sudo setfacl -R -m u:phone:rwX /path/to/shared      # existing
sudo setfacl -R -d -m u:phone:rwX /path/to/shared   # all future files/folders
```

> ⚠️ Scope ACLs to your shared/work folders only — never blanket-apply them to `/home/user` (that would touch `.ssh/authorized_keys` and can break or weaken SSH).

Re-run the one-line `chmod` if some *other* folder outside your ACL'd trees ever denies access.

### Option B — log in AS the owner via a phone-only key (recommended)

The owner can always read/write its own files regardless of permission bits — so this option is immune to future permission problems by design.

```bash
# 1. Generate a key just for the phone (on the server, as the owner — NOT root)
ssh-keygen -t ed25519 -f ~/.ssh/phone_sftp -N "" -C "phone-sftp"

# 2. Install the public key, restricted to FILES ONLY (no shell, no forwarding —
#    a stolen phone gets file access and nothing else)
PUB=$(cat ~/.ssh/phone_sftp.pub)
grep -q "phone-sftp" ~/.ssh/authorized_keys && sed -i '/phone-sftp/d' ~/.ssh/authorized_keys
echo "restrict,command=\"/usr/lib/openssh/sftp-server\" $PUB" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 3. Test it (should list files; shell attempt should return nothing)
printf 'pwd\nls\nquit\n' | sftp -b - -i ~/.ssh/phone_sftp -o StrictHostKeyChecking=no $(whoami)@127.0.0.1
timeout 5 ssh -i ~/.ssh/phone_sftp -o StrictHostKeyChecking=no -o BatchMode=yes $(whoami)@127.0.0.1 "echo SHELL_WORKS"
#   → no SHELL_WORKS output = shell correctly blocked
```

**Getting the private key onto your phone:** copy `~/.ssh/phone_sftp` to somewhere downloadable (your HTTP file browser, `scp` to your PC then USB, QR tools, …), import it on the phone, then **delete the transfer copy from the server**. Keep the `~/.ssh/` original so you can re-issue.

Phone settings for Option B:

```
URI:      sftp://your-server:22/home/ubuntu
Username: <owner username, e.g. ubuntu>
Password: (empty)
Key:      the phone_sftp file (see MiXplorer notes below)
```

**Lost phone?** Revoke instantly — one line, no other login affected:

```bash
sed -i '/phone-sftp/d' ~/.ssh/authorized_keys
```

Then generate a fresh key for the replacement phone.

---

## Phone setup notes (MiXplorer + any SFTP client)

Every SFTP client needs the same 4 things: **host, port (22), username, and ONE credential (password OR key)** — never both.

### MiXplorer specifics

- Add storage → **SFTP**
- `URI address` format: `sftp://HOST:PORT/Linux-Path`
  - Start broad (`sftp://your-server:22/home/ubuntu`), navigate from there — or deep-link straight to your folder.
- `Username` / `Password` are separate fields; don't embed `user@` in the URI.
- First connect asks to trust the host key → accept.
- Advanced settings you may need: `port=22`. Leave the rest default.

### ⚠️ MiXplorer gotchas we hit

1. **"Search local >>" is NOT a file picker.** It's a *LAN scanner* — it lists SFTP servers on your WiFi (e.g. your own Samsung at `192.168.1.6`). Ignore it for key setup.
2. **To use a key file:** download the `.key` to Downloads, find its exact path (long-press → Properties, typically `/storage/emulated/0/Download/phone_sftp`), and type it into Advanced settings:
   ```
   key_path=/storage/emulated/0/Download/phone_sftp
   ```
   with `Password` left empty. (Alternative: paste the key's base64 into `key_base64=`.)
3. **If it keeps asking for a password** on a key-based entry, the key isn't attached (see 2) — the server will never accept a password for a key-only user, so the prompt can never succeed.
4. **"Permission denied" on one folder but not others** → owner-only bits on that folder (see [Future-proof permissions](#future-proof-permissions-future-proof-permissions-so-new-files-dont-lock-the-phone-out)). Option B logins are immune.

---

## Security checklist

- [ ] Global `PasswordAuthentication no` untouched (verify with `sshd -T`)
- [ ] Phone password user limited via `Match` + no forwarding/tunneling
- [ ] Phone user jailed (`ChrootDirectory` + `internal-sftp`, `nologin` shell) if passwords exist
- [ ] Owner key restricted with `restrict,command="…/sftp-server"` (files only)
- [ ] Transfer copies of private keys deleted from the server after import
- [ ] Private key never committed anywhere (this repo's `.gitignore` blocks `*.key`)
- [ ] fail2ban installed and the `sshd` jail active (see below)

### fail2ban (brute-force protection)

The moment port 22 is public, bots try thousands of logins (we saw 19 attempts and a ban within seconds of enabling it). fail2ban auto-bans IPs after repeated failures:

```bash
sudo apt-get install -y fail2ban
sudo systemctl enable --now fail2ban

# On modern Ubuntu there is no /var/log/auth.log (journal-only logging),
# so point the sshd jail at systemd or fail2ban won't start:
sudo tee /etc/fail2ban/jail.d/sshd-systemd.conf > /dev/null <<'EOF'
[sshd]
backend = systemd
EOF
sudo systemctl restart fail2ban

# Verify (expect: Jail list: sshd, with failed/banned counters climbing)
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Defaults (5 failures → 10-min ban) are fine for a phone setup. Useful commands:

```bash
sudo fail2ban-client status sshd          # currently failed / banned IPs
sudo fail2ban-client set sshd unbanip <IP>  # you typo'd your own password too often
sudo journalctl -u fail2ban -f            # watch bans happen live
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Timeout / unreachable | Port 22 blocked | Cloud ingress rule + `ufw allow 22/tcp`; test `ssh` from outside |
| Auth failed (password user) | `Match` block missing/typo, or forgot reload | `sshd -t`, `systemctl reload ssh`, re-check `sshd -T -C user=…` |
| Password prompt loop (key user) | Key not attached in app | Set `key_path=` / `key_base64=` correctly; password can't work here |
| Permission denied on some folders | Owner-only `700`/`600` bits | `chmod -R g+rwX` + default ACLs (Option A), or switch to Option B |
| Key rejected: invalid format | Old client vs ed25519 | Regenerate with `ssh-keygen -t rsa -b 3072` |
| Changed something, SSH broke | Bad sshd config | `sshd -t` before every reload; keep one SSH session open while testing |
| Locked out by fail2ban (own IP) | Too many failed logins | From another connection: `sudo fail2ban-client set sshd unbanip <your-IP>` |

## Repo contents

```
Servex/
├── README.md                  ← this guide
├── scripts/
│   ├── setup-phone-sftp.sh    ← Option A + permissions automation
│   └── make-owner-key.sh      ← Option B automation
└── LICENSE
```

MIT — do whatever you want with it. If it saved you an evening, star it.
