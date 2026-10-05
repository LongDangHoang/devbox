#!/usr/bin/env bash
# Idempotent boot setup; runs as root from setup-boot.service on every boot.
# The agent (ubuntu) is untrusted: root never writes into ubuntu-owned paths (/data, $H);
# those writes go through as_u. No ubuntu-controlled code runs outside the Claude sandbox here.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
U=ubuntu
H=/home/$U
SRC=$(dirname "$(readlink -f "$0")")
as_u() { runuser -u "$U" -- env HOME="$H" "$@"; }
umask 022

# shellcheck disable=SC1091
. /etc/devbox/boot.conf
export AWS_DEFAULT_REGION=$AWS_REGION

# --- 1. lock down ubuntu: IMDS root-only, no sudo/lxd/adm (human uses ssm-user + sudo)
iptables -C OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j REJECT 2>/dev/null ||
  iptables -I OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j REJECT
rm -f /etc/sudoers.d/90-cloud-init-users
for g in sudo lxd adm; do gpasswd -d "$U" "$g" >/dev/null 2>&1 || true; done

# --- 2. params from SSM (root only; never written to disk except where noted)
NAME=$(TOKEN=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token) &&
  curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Project)
declare -A P
while IFS=$'\t' read -r k v; do P[${k##*/}]=$v; done < <(
  aws ssm get-parameters-by-path --path "/devbox/$NAME/" --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text)

# --- 3. data volume -> /data: exactly our EBS volume, found by its NVMe serial
vol=${P[data_volume_id]:?missing /devbox/$NAME/data_volume_id}
dev=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol//-/}
for _ in $(seq 24); do [[ -b $dev ]] && break; sleep 5; done   # wait up to ~2 min for the attach
[[ -b $dev ]] || { echo "data volume $vol not attached" >&2; exit 1; }
blkid "$dev" >/dev/null || mkfs.ext4 -L devbox-data "$dev"   # format only if no filesystem
mkdir -p /data
mountpoint -q /data || mount "$dev" /data
chown "$U:$U" /data   # fs root of our volume; everything below is created by ubuntu
as_u mkdir -p /data/cache /data/claude

# --- 4. packages (bwrap+socat: Claude Code sandbox; Node for project tooling)
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential python3 nodejs bubblewrap socat iptables

# Ubuntu 24.04 blocks bwrap userns by default; allow it (per sandboxing docs).
if [[ $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0) == 1 && ! -f /etc/apparmor.d/bwrap ]]; then
  cat > /etc/apparmor.d/bwrap <<'EOP'
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOP
  systemctl reload apparmor || true
fi

# Org-level Claude Code policy (sandbox, network allowlist, credential deny-reads). Root-owned.
install -D -o root -g root -m 0644 "$SRC/managed-settings.json" /etc/claude-code/managed-settings.json

# --- 5. config files (no secrets): env for idle-stop, rc.env for claude-rc
cat > /etc/devbox/env <<EOV
DEVBOX_PROJECT=$NAME
IDLE_MINUTES=${P[idle_minutes]:-30}
EOV
cat > /etc/devbox/rc.env <<EOV
DEVBOX_PROJECT=$NAME
PATH=$H/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
XDG_CACHE_HOME=/data/cache
UV_CACHE_DIR=/data/cache/uv
UV_PYTHON_INSTALL_DIR=/data/cache/uv-python
EOV
cat > /etc/profile.d/devbox.sh <<'EOV'
export XDG_CACHE_HOME=/data/cache
export UV_CACHE_DIR=/data/cache/uv
export UV_PYTHON_INSTALL_DIR=/data/cache/uv-python
export PATH="$HOME/.local/bin:$PATH"
EOV

# --- 6. ~/.claude and ~/.claude.json live on /data (all as ubuntu)
as_u bash -euc '
  if [[ -d ~/.claude && ! -L ~/.claude ]]; then cp -an ~/.claude/. /data/claude/ && rm -rf ~/.claude; fi
  [[ -e /data/claude.json || ! -f ~/.claude.json || -L ~/.claude.json ]] || mv ~/.claude.json /data/claude.json
  [[ -e /data/claude.json ]] || echo "{}" > /data/claude.json
  ln -sfn /data/claude ~/.claude
  ln -sfn /data/claude.json ~/.claude.json
'

# --- 7. git auth: the agent's own scoped token, readable by ubuntu (git push needs it).
# Token goes via stdin, not argv.
if [[ -n ${P[github_token]:-} ]]; then
  printf 'https://x-access-token:%s@github.com\n' "${P[github_token]}" |
    as_u bash -euc 'umask 077; rm -f /data/git-credentials; cat > /data/git-credentials'
  as_u git config --global credential.helper "store --file /data/git-credentials"
fi

# --- 8. user tools (skipped if present; claude self-updates)
[[ -x $H/.local/bin/uv ]] || as_u bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
[[ -x $H/.local/bin/claude ]] || as_u bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# --- 9. repo (no dependency install here: that would run agent-controlled code unsandboxed)
if [[ ! -d /data/repo/.git && -n ${P[repo_url]:-} ]]; then
  as_u git clone "${P[repo_url]}" /data/repo || echo "clone failed (token set / invite accepted?)" >&2
fi

# --- 10. services
for f in claude-rc.service idle-stop.service idle-stop.timer; do
  install -m 0644 "$SRC/$f" "/etc/systemd/system/$f"
done
systemctl daemon-reload
systemctl enable idle-stop.timer claude-rc.service
# --no-block: claude-rc is ordered after this (still running) unit; a blocking restart would deadlock.
systemctl restart --no-block claude-rc.service
systemctl start idle-stop.timer
