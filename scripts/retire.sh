#!/usr/bin/env bash
# Retire a project: destroy only its resources, keep final EBS snapshot, keep GitHub repo.
set -euo pipefail
name=${1:?usage: retire.sh NAME}
region=${REGION:-ap-southeast-2}
cd "$(dirname "$0")/.."
tf="terraform -chdir=infra/terraform"
f=infra/projects/$name.json
plan=retire.tfplan # relative to infra/terraform
die() { echo "error: $*" >&2; exit 1; }
[ -f "$f" ] || die "$f not found"

echo "This will DESTROY the box, data volume and GitHub modal environment, branch protection + agent collaborator access for '$name'."
echo "The GitHub repo itself is not touched; a final data-volume snapshot is kept."
read -r -p "Type the project name to confirm: " ans
[ "$ans" = "$name" ] || die "confirmation mismatch"

content=$(cat "$f")
applied=0
cleanup() {
  rm -f "infra/terraform/$plan"
  if [ "$applied" != 1 ] && [ ! -f "$f" ]; then printf '%s\n' "$content" > "$f"; echo "restored $f"; fi
}
trap cleanup EXIT

# Stop the box so the data volume detaches cleanly.
id=$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:Project,Values=$name" Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
case "$id" in *[[:space:]]*) die "multiple instances for Project=$name: $(tr -s "[:space:]" " " <<<"$id")";; esac
if [ -n "$id" ] && [ "$id" != None ]; then
  echo "Stopping $id..."
  aws ec2 stop-instances --region "$region" --instance-ids "$id" >/dev/null || true
  aws ec2 wait instance-stopped --region "$region" --instance-ids "$id"
fi

# Record the volume id, remove the JSON and plan; abort unless the plan only deletes this project's resources.
volid=$($tf output -json projects | jq -r --arg n "$name" '.[$n].data_volume_id // empty')
rm "$f"
$tf plan -out="$plan"
changes=$($tf show -json "$plan" | jq -r --arg a "module.devbox[\"$name\"]" --arg b "module.github_project[\"$name\"]" '
  .resource_changes[]
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | select(((.address | startswith($a) or startswith($b)) | not) or .change.actions != ["delete"])
  | "\(.address) \(.change.actions | join(","))"')
[ -z "$changes" ] || die "plan touches more than $name's destroy; aborting:
$changes"
n=$($tf show -json "$plan" | jq '[.resource_changes[] | select(.change.actions == ["delete"])] | length')
[ "$n" -gt 0 ] || die "plan destroys nothing"
echo "Plan destroys $n resources, all under module.devbox[\"$name\"] / module.github_project[\"$name\"]."
read -r -p "Apply? [y/N] " ok
[ "$ok" = y ] || [ "$ok" = Y ] || die "declined"
$tf apply "$plan"
applied=1

# Terraform leaves a final snapshot (final_snapshot=true); it can take a moment to appear.
if [ -n "$volid" ]; then
  snap=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    snap=$(aws ec2 describe-snapshots --region "$region" --owner-ids self \
      --filters "Name=volume-id,Values=$volid" --query 'Snapshots[].SnapshotId' --output text)
    [ -n "$snap" ] && break
    sleep 10
  done
  if [ -n "$snap" ]; then
    echo "Final snapshot(s) of $volid: $snap"
    echo "Delete later: aws ec2 delete-snapshot --region $region --snapshot-id <id>"
  else
    echo "warning: no snapshot found yet for $volid; check: aws ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values=$volid" >&2
  fi
else
  echo "warning: data volume id not recorded; find snapshots manually" >&2
fi

git add -A -- "$f"
git commit -m "Retire project $name" -- "$f"
echo "Reminder: revoke the agent machine-user token you stored for $name (machine user -> Settings -> Developer settings -> Tokens (classic))."
