#!/usr/bin/env bash
# Stop the box only if: past boot grace, no SSH/login sessions, /data/claude quiet, load low.
set -euo pipefail

N=$(sed -n 's/^IDLE_MINUTES=//p' /etc/devbox/env 2>/dev/null | tail -n1)
N=${N:-30}
[[ $N =~ ^[0-9]+$ ]] || N=30
LOAD_MAX=0.5

stay() { echo "idle-stop: staying up: $1"; exit 0; }

up_min=$(awk '{print int($1/60)}' /proc/uptime)
((up_min >= N)) || stay "uptime ${up_min}m < ${N}m"
[[ -n $(who) ]] && stay "login session"
pgrep -f 'sshd: .*@' >/dev/null && stay "ssh session"
[[ -n $(find /data/claude -mmin "-$N" -print -quit 2>/dev/null) ]] && stay "/data/claude modified in last ${N}m"
load5=$(awk '{print $2}' /proc/loadavg)
awk -v l="$load5" -v m="$LOAD_MAX" 'BEGIN{exit !(l>=m)}' && stay "load5 $load5 >= $LOAD_MAX"

logger -t idle-stop "idle ${N}m, load5 $load5, no sessions: shutting down"
shutdown -h now
