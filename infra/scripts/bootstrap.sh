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

install -d -m 0755 /etc/devbox

# --- 1. lock down ubuntu: no sudo/lxd/adm. The human logs in (EC2 Instance Connect) as `admin`,
# which has passwordless sudo. The box has no AWS identity, so IMDS holds no credentials.
rm -f /etc/sudoers.d/90-cloud-init-users
for g in sudo lxd adm; do gpasswd -d "$U" "$g" >/dev/null 2>&1 || true; done
# -N: Ubuntu already has a system group `admin`, so a same-name user group would fail (exit 9).
id admin >/dev/null 2>&1 || useradd -m -N -s /bin/bash -G sudo admin   # no password (key-only login)
t=$(mktemp)
echo 'admin ALL=(ALL) NOPASSWD:ALL' > "$t"
visudo -cqf "$t" && install -o root -g root -m 0440 "$t" /etc/sudoers.d/devbox-admin
rm -f "$t"

# --- 2. settings from instance tags (set by Terraform; nothing secret)
IMDS=http://169.254.169.254/latest
T=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' "$IMDS/api/token")
tag() { curl -fsS -H "X-aws-ec2-metadata-token: $T" "$IMDS/meta-data/tags/instance/$1"; }
NAME=$(tag Project)
REPO=$(tag Repo)
IDLE=$(tag IdleMinutes)
vol=$(tag DataVolumeId)

# --- 3. data volume -> /data: exactly our EBS volume, found by its NVMe serial
dev=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol//-/}
for _ in $(seq 24); do [[ -b $dev ]] && break; sleep 5; done   # wait up to ~2 min for the attach
[[ -b $dev ]] || { echo "data volume $vol not attached" >&2; exit 1; }
blkid "$dev" >/dev/null || mkfs.ext4 -L devbox-data "$dev"   # format only if no filesystem
mkdir -p /data
mountpoint -q /data || mount "$dev" /data
chown "$U:$U" /data   # fs root of our volume; everything below is created by ubuntu
as_u mkdir -p /data/cache /data/claude /data/shared

# --- 4. packages (bwrap+socat: Claude Code sandbox; Node for project tooling; gh root-owned like claude)
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential python3 nodejs bubblewrap socat ec2-instance-connect gh

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
IDLE_MINUTES=$IDLE
EOV
cat > /etc/devbox/rc.env <<EOV
DEVBOX_PROJECT=$NAME
DEVBOX_SHARED=/data/shared
PATH=$H/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
XDG_CACHE_HOME=/data/cache
UV_CACHE_DIR=/data/cache/uv
UV_PYTHON_INSTALL_DIR=/data/cache/uv-python
EOV
cat > /etc/profile.d/devbox.sh <<'EOV'
export DEVBOX_SHARED=/data/shared
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
# Source: /etc/devbox/github_token (root 0600, pushed by `devbox secrets`). Token goes via stdin, not argv.
TOKEN_FILE=/etc/devbox/github_token
if [[ -s $TOKEN_FILE ]]; then
  printf 'https://x-access-token:%s@github.com\n' "$(< "$TOKEN_FILE")" |
    as_u bash -euc 'umask 077; rm -f /data/git-credentials; cat > /data/git-credentials'
  as_u git config --global credential.helper "store --file /data/git-credentials"
  # gh for PRs/CI logs, so the agent never handles the token itself (no keyring: plain hosts.yml).
  # Needs the read:org scope; non-fatal so a GitHub hiccup doesn't block Remote Control.
  as_u gh auth login --hostname github.com --with-token < "$TOKEN_FILE" || echo "gh login failed (token lacks read:org?)" >&2
else
  echo "no $TOKEN_FILE yet (run: devbox secrets $NAME); skipping git credentials and clone" >&2
fi

# --- 8. tools. Claude Code is installed by root and copied root-owned to /usr/local/bin,
# so nothing running as ubuntu can swap the binary claude-rc executes. Updated each boot
# (the in-app autoupdater is off via managed settings).
[[ -x $H/.local/bin/uv ]] || as_u bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
if [[ -x /root/.local/bin/claude ]]; then
  /root/.local/bin/claude update || echo "claude update failed; keeping current version" >&2
else
  curl -fsSL https://claude.ai/install.sh | bash
fi
install -o root -g root -m 0755 "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude
rm -f "$H/.local/bin/claude" # older ubuntu-owned install would shadow it on PATH

# --- 9. repo (no dependency install here: that would run agent-controlled code unsandboxed)
if [[ ! -d /data/repo/.git && -s $TOKEN_FILE ]]; then
  as_u git clone "https://github.com/$REPO.git" /data/repo || echo "clone failed (token set / invite accepted?)" >&2
fi
# Prune session worktrees untouched for 7 days (sandboxed sessions can't delete siblings). Runs before
# claude-rc starts, so no live session. Branches stay; only uncommitted work in stale worktrees is lost
# (keepers belong in /data/shared). mtime only: never run git inside a worktree, since its .git file
# is agent-controlled and could point at a gitdir whose config executes code outside the sandbox.
# ponytail: fixed 7 days, make it a project setting if a project needs longer.
if [[ -d /data/repo/.git ]]; then
  as_u bash -c '
    for wt in /data/repo/.claude/worktrees/*/; do
      [[ -d $wt && -z $(find "$wt" -mtime -7 -print -quit) ]] && rm -rf --one-file-system "$wt"
    done
    git -C /data/repo worktree prune' || echo "worktree prune failed" >&2
fi

# --- 10. services
for f in setup-boot.service claude-rc.service idle-stop.service idle-stop.timer; do
  install -m 0644 "$SRC/$f" "/etc/systemd/system/$f"
done
systemctl daemon-reload
systemctl enable idle-stop.timer claude-rc.service
# --no-block: claude-rc is ordered after this (still running) unit; a blocking restart would deadlock.
systemctl restart --no-block claude-rc.service
systemctl start idle-stop.timer
