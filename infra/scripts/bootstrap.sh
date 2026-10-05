#!/usr/bin/env bash
# Idempotent boot setup; runs as root from setup-boot.service on every boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
U=ubuntu
H=/home/$U
SRC=$(dirname "$(readlink -f "$0")")
as_u() { sudo -u "$U" -H "$@"; }

# shellcheck disable=SC1091
. /etc/devbox/boot.conf
export AWS_DEFAULT_REGION=$AWS_REGION

# --- 1. data volume -> /data
dev=$(blkid -L devbox-data || true)
if [[ -z $dev ]]; then
  for _ in $(seq 24); do   # wait up to ~2 min for the attach
    # non-root whole disk with no partitions/children and no mountpoint
    for d in $(lsblk -dpno NAME,TYPE | awk '$1 ~ /nvme|xvd|sd/ && $2=="disk"{print $1}'); do
      [[ $(lsblk -nr "$d" | wc -l) -eq 1 ]] && ! findmnt -rn -S "$d" >/dev/null && dev=$d && break
    done
    [[ -n $dev ]] && break
    sleep 5
  done
  [[ -n $dev ]] || { echo "data volume not found" >&2; exit 1; }
  # format only if no filesystem
  blkid "$dev" >/dev/null || mkfs.ext4 -L devbox-data "$dev"
  e2label "$dev" devbox-data
fi
mkdir -p /data
grep -q 'LABEL=devbox-data' /etc/fstab || echo 'LABEL=devbox-data /data ext4 defaults,nofail 0 2' >> /etc/fstab
mountpoint -q /data || mount /data
chown "$U:$U" /data
mkdir -p /data/cache /data/claude
chown "$U:$U" /data/cache /data/claude

# --- 2. packages (bwrap+socat: Claude Code sandbox; Node for project tooling)
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential python3 nodejs bubblewrap socat

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

# --- 3. secrets: SSM -> /etc/devbox/env (0600 root), rc.env (public bits only)
NAME=$(TOKEN=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token) &&
  curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Project)
declare -A P
while IFS=$'\t' read -r k v; do P[${k##*/}]=$v; done < <(
  aws ssm get-parameters-by-path --path "/devbox/$NAME/" --with-decryption \
    --query 'Parameters[].[Name,Value]' --output text)
umask 077
cat > /etc/devbox/env <<EOV
DEVBOX_PROJECT=$NAME
REPO_URL=${P[repo_url]:-}
IDLE_MINUTES=${P[idle_minutes]:-30}
GITHUB_TOKEN=${P[github_token]:-}
EOV
chown root:root /etc/devbox/env; chmod 0600 /etc/devbox/env
umask 022
cat > /etc/devbox/rc.env <<EOV
DEVBOX_PROJECT=$NAME
PATH=$H/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
XDG_CACHE_HOME=/data/cache
UV_CACHE_DIR=/data/cache/uv
EOV
cat > /etc/profile.d/devbox.sh <<'EOV'
export XDG_CACHE_HOME=/data/cache
export UV_CACHE_DIR=/data/cache/uv
export PATH="$HOME/.local/bin:$PATH"
EOV

# --- 4. ~/.claude and ~/.claude.json live on /data
if [[ -d $H/.claude && ! -L $H/.claude ]]; then
  cp -an "$H/.claude/." /data/claude/ && rm -rf "$H/.claude"
fi
[[ -e /data/claude.json || ! -f $H/.claude.json || -L $H/.claude.json ]] || mv "$H/.claude.json" /data/claude.json
[[ -e /data/claude.json ]] || echo '{}' > /data/claude.json
ln -sfn /data/claude "$H/.claude"
ln -sfn /data/claude.json "$H/.claude.json"
chown -R "$U:$U" /data/claude /data/claude.json
chown -h "$U:$U" "$H/.claude" "$H/.claude.json"

# --- 5. git auth (credential store; token reachable by the dev user, see report)
if [[ -n ${P[github_token]:-} ]]; then
  ( umask 077; echo "https://x-access-token:${P[github_token]}@github.com" > /data/git-credentials )
  chown "$U:$U" /data/git-credentials
  as_u git config --global credential.helper "store --file /data/git-credentials"
fi

# --- 6. user tools (skipped if present; claude self-updates)
[[ -x $H/.local/bin/uv ]] || as_u bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
[[ -x $H/.local/bin/claude ]] || as_u bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

# --- 7. repo
if [[ ! -d /data/repo/.git && -n ${P[repo_url]:-} ]]; then
  as_u git clone "${P[repo_url]}" /data/repo || echo "clone failed (token set yet?)" >&2
fi
if [[ -f /data/repo/pyproject.toml ]]; then
  as_u bash -c 'cd /data/repo && UV_CACHE_DIR=/data/cache/uv ~/.local/bin/uv sync' || echo "uv sync failed" >&2
fi

# --- 8. services
for f in claude-rc.service idle-stop.service idle-stop.timer; do
  install -m 0644 "$SRC/$f" /etc/systemd/system/$f
done
systemctl daemon-reload
systemctl enable idle-stop.timer claude-rc.service
systemctl restart claude-rc.service
systemctl start idle-stop.timer
