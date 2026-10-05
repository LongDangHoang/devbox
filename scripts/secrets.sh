#!/usr/bin/env bash
# Prompt (hidden) for secrets and store them. Values only ever flow through
# stdin pipes (printf is a builtin: no argv, no disk, no Terraform state).
set -euo pipefail
name=${1:?usage: secrets.sh NAME}
region=${REGION:-ap-southeast-2}
cd "$(dirname "$0")/.."
f=infra/projects/$name.json
[ -f "$f" ] || { echo "error: $f not found" >&2; exit 1; }
repo=$(jq -r .repo "$f")

echo "Empty input skips a secret. Input is hidden."
read -rs -p "Agent GitHub token (-> SSM /devbox/$name/github_token): " val; echo
if [ -n "$val" ]; then
  printf '%s' "$val" \
    | jq -Rs --arg n "/devbox/$name/github_token" '{Name:$n, Value:., Type:"SecureString", Overwrite:true}' \
    | aws ssm put-parameter --region "$region" --cli-input-json file:///dev/stdin >/dev/null
  echo "  set SSM /devbox/$name/github_token"
fi

for s in MODAL_TOKEN_ID MODAL_TOKEN_SECRET WANDB_API_KEY; do
  read -rs -p "$s (-> $repo env modal): " val; echo
  if [ -n "$val" ]; then
    printf '%s' "$val" | gh secret set "$s" --env modal --repo "$repo"
  fi
done
