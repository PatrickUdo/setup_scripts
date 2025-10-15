#!/usr/bin/env bash
set -euo pipefail

USERNAME="patrickudo"
HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/setup-backups-$(date +%Y%m%d%H%M%S)"

# GitHub file URL you provided (html view). We'll try this and a derived raw URL.
GITHUB_KEY_URL="https://github.com/PatrickUdo/setup_scripts/blob/main/sshkey.pub"

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root (or with sudo)."
  exit 1
fi

mkdir -p "$BACKUP_DIR"
echo "Backups will be stored in $BACKUP_DIR"

# 1) Create user if needed
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "User $USERNAME already exists."
else
  echo "Creating user $USERNAME ..."
  useradd -m -s /bin/bash -G sudo "$USERNAME"
  echo "Set a password for $USERNAME:"
  passwd "$USERNAME"
  echo "User $USERNAME created and added to sudo group."
fi

# 2) Ensure sudo group membership
if id -nG "$USERNAME" | grep -qw sudo; then
  echo "$USERNAME already in sudo."
else
  usermod -aG sudo "$USERNAME"
  echo "Added $USERNAME to sudo group."
fi

# 3) Prepare .ssh and authorized_keys
mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# 4) Fetch key(s) from GitHub (try raw first, then fallback to ?raw=1)
TMP_KEYS="$(mktemp)"
cleanup() { rm -f "$TMP_KEYS" || true; }
trap cleanup EXIT

derive_raw_url() {
  echo "$1" | sed -E 's#https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*)#https://raw.githubusercontent.com/\1/\2/\3/\4#'
}

RAW_URL="$(derive_raw_url "$GITHUB_KEY_URL")"

fetch_ok=false
for URL in "$RAW_URL" "${GITHUB_KEY_URL}?raw=1" "$GITHUB_KEY_URL"; do
  echo "Trying to fetch keys from: $URL"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$URL" -o "$TMP_KEYS"; then fetch_ok=true; break; fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "$TMP_KEYS" "$URL"; then fetch_ok=true; break; fi
  else
    echo "Neither curl nor wget found. Install one (e.g., apt-get update && apt-get install -y curl)."
    exit 1
  fi
done

if [ "$fetch_ok" != true ]; then
  echo "Failed to fetch key file from GitHub."
  exit 1
fi

# 5) Add any missing keys
added_any=false
while IFS= read -r line; do
  key="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$key" ] && continue
  echo "$key" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ' || continue
  if grep -Fqx "$key" "$AUTH_KEYS"; then
    echo "Key already present; skipping."
  else
    echo "$key" >> "$AUTH_KEYS"
    added_any=true
  fi
done < "$TMP_KEYS"

chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if [ "$added_any" = true ]; then
  echo "Added new key(s) for $USERNAME."
else
  echo "No new keys to add; authorized_keys unchanged."
fi

# 6) Backup and harden sshd_config
echo "Backing up $SSHD_CONFIG to $BACKUP_DIR"
cp -p "$SSHD_CONFIG" "$BACKUP_DIR/sshd_config.bak"

set_sshd_option() {
  local option="$1"
  local value="$2"
  local file="$3"
  if grep -Ei "^\s*#?\s*${option}\s+" "$file" >/dev/null 2>&1; then
    sed -ri "s|^\s*#?\s*(${option})\s+.*$|${option} ${value}|I" "$file"
  else
    echo "${option} ${value}" >> "$file"
  fi
}

set_sshd_option "PermitRootLogin" "no" "$SSHD_CONFIG"
set_sshd_option "PasswordAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "ChallengeResponseAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "UsePAM" "yes" "$SSHD_CONFIG"

# 7) Lock root password
passwd -l root || true

# 8) Restart SSH
echo "Restarting SSH service..."
if systemctl list-units --type=service --all | grep -q 'ssh.service'; then
  systemctl restart ssh
elif systemctl list-units --type=service --all | grep -q 'sshd.service'; then
  systemctl restart sshd
else
  service ssh reload || service ssh restart || true
fi

echo
echo "All set. Test from a new terminal:"
echo "  ssh ${USERNAME}@<server-ip>"
