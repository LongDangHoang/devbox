# devbox

One EC2 dev box per ML project (Claude Code in Remote Control mode), GitHub repo settings via Terraform, a Copier project template, and a reusable `run-experiments` workflow that launches Modal GPU jobs only when you approve.

Projects are one JSON file each in `infra/projects/<name>.json` (`{"repo": "<owner>/<name>", "instance_type": "...", "data_gb": 50}`; the last two optional). The `devbox` CLI wraps adding and retiring them.

## One-time devbox setup

Prereqs: `terraform` >= 1.11, AWS CLI v2 (`aws ec2-instance-connect` is built in; no session-manager-plugin), OpenSSH (`ssh`, `ssh-keygen`), `gh` (logged in), `uv`.

Install the CLI once from this repo (editable, so it finds `infra/`):

```bash
uv tool install -e .   # puts `devbox` on PATH; `devbox --help` lists commands
```

Setup happens in this order: **(1) local config, (2) AWS identity in the IAM console, (3) `devbox auth`, (4) Terraform.** The `devbox-deployer` role can't create IAM resources, so step 2 is manual and has to come before anything that touches Terraform.

### 1. Local config

Pick these values. Nothing has a default:

- `<account>`: your AWS account ID.
- `<region>`: where the boxes run (e.g. `ap-southeast-2`).
- `<state-bucket>`: an existing S3 bucket for Terraform state.
- `<state-key>`: the state file's path in that bucket (e.g. `devbox/terraform.tfstate`).

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # set region = "<region>", VPC/subnet, GitHub owner, ...
cat > infra/terraform/backend.hcl <<'EOF'
bucket       = "<state-bucket>"
key          = "<state-key>"
region       = "<region>"
use_lockfile = true
EOF
gh auth login   # once; devbox hands this login to Terraform (never exported, never on a box)
```

Both files are gitignored. `devbox` reads `region` from `terraform.tfvars` (override with `devbox --region ...`), and errors if it's missing.

### 2. AWS identity (IAM console, as admin, once)

`devbox` never uses your admin credentials. It runs as the role `devbox-deployer`, which a dedicated user `devbox-operator` assumes with MFA. The role gets `PowerUserAccess`, capped by the permissions boundary `devbox-deployer-boundary`. The three policies are in `infra/iam/`; replace the `<...>` placeholders with your values from step 1 before pasting.

1. **User:** create `devbox-operator` (no console access). Assign it an MFA device and create an access key. Give it one inline policy, `assume-devbox-deployer`, from `infra/iam/operator-policy.json`. It must have no other policies or groups. In particular, don't add an `aws:MultiFactorAuthPresent` condition there, or AWS's "force MFA" example policy: `AssumeRole` is signed with the long-term key, so that condition never matches and the call is denied. The role's trust policy enforces MFA instead.
2. **Boundary:** create the customer-managed policy `devbox-deployer-boundary` from `infra/iam/deployer-boundary.json`. `<state-bucket>`/`<state-key>` must match `backend.hcl` exactly: the boundary exempts the state file and its `.tflock` lock file from the delete guard.
3. **Role:** create `devbox-deployer` with a custom trust policy from `infra/iam/deployer-trust.json` (it requires MFA). Attach `PowerUserAccess`, set its permissions boundary to `devbox-deployer-boundary`, and leave the maximum session duration at 1 hour.

   Create the user before the role, since the trust policy names the user. If you ever delete and recreate the user, re-save the role's trust policy: AWS stores the old user's internal ID (`AIDA...`) in it, which silently stops matching.

### 3. Profiles and `devbox auth`

Put the access key in `~/.aws/credentials` as `[devbox-operator]`, and add this to `~/.aws/config`:

```ini
[profile devbox-operator]
region = <region>

[profile devbox]
role_arn = arn:aws:iam::<account>:role/devbox-deployer
source_profile = devbox-operator
mfa_serial = arn:aws:iam::<account>:mfa/<device-name>
duration_seconds = 3600
```

`devbox auth` prompts for the MFA code and shows who you are (`assumed-role/devbox-deployer/...`).
- **How credentials flow:** the AWS CLI caches the 1h session in `~/.aws/cli/cache`. Each `devbox` run takes the keys from `aws configure export-credentials --profile devbox` and hands them only to its own `aws`/`terraform`/`ssh` child processes.
- **Other profile name:** set `DEVBOX_AWS_PROFILE`. By hand: `aws --profile devbox ...`.

`AccessDenied` here, with the caller shown as `user/devbox-operator`:
- **The user's policy:** it's missing, it has an MFA condition, or its `Resource` isn't exactly the role ARN.
- **Another policy on the user:** a group or policy denies the call, e.g. a force-MFA policy.
- **The trust policy:** it doesn't name `user/devbox-operator` (or shows a stale `AIDA...` ID), or `mfa_serial` isn't the device assigned to this user.
- **The session duration:** `duration_seconds` is larger than the role's maximum session duration. This shows up as a `ValidationError`.

`aws sts get-caller-identity --profile devbox-operator` checks the key alone; `aws sts get-caller-identity --profile devbox` checks the whole chain.

### 4. Terraform

```bash
devbox tf init -backend-config=backend.hcl
devbox tf plan
```

`devbox tf <args>` runs `terraform -chdir=infra/terraform` as the deployer, with `GITHUB_TOKEN` taken from your `gh` login and set only for that process. Terraform itself can't prompt for MFA, so plain `terraform plan` won't get credentials. Use `devbox tf` for any manual Terraform command.

**The guard** is accident prevention, not attacker containment: a compromised laptop is game over anyway.
- **Without the `ManagedBy=devbox` tag, the deployer can't** terminate, stop, modify or delete EC2 resources, delete S3/RDS/DynamoDB/Lambda/... resources, or change budgets. It can still create things. Terraform tags everything here via `default_tags`, and budgets match by the `devbox-` name prefix.
- **The boundary also:**
  - blocks all IAM except creating the Instance Connect service-linked role,
  - blocks `sts` role hopping,
  - keeps everything in `<region>` (budgets excepted).

  It caps the role even if you attach a broader policy later.
- **If a devbox operation hits `AccessDenied`:** add a narrowly scoped exception to `infra/iam/deployer-boundary.json` and update the policy in the console.
- **Later:** IAM Access Analyzer can generate a least-privilege policy from CloudTrail to replace `PowerUserAccess`.

**Access to the boxes:** one EC2 Instance Connect Endpoint (EICE) in `subnet_id`, created by the first `devbox add` (AWS allows one per VPC). Boxes have no internet-reachable ports: their SG accepts tcp 22 only from the endpoint's SG (this replaces spec rule 5's "no inbound ports; access only through SSM"). `devbox` pushes a throwaway SSH key (valid 60s) with `ec2-instance-connect send-ssh-public-key` and connects through `ec2-instance-connect open-tunnel`, both IAM-gated.

**Upgrading from the SSM version:** run one `terraform apply` with admin credentials (the deployer can't delete the old IAM roles, S3 script objects or not-yet-tagged resources), adding `-replace='module.devbox["<name>"].aws_launch_template.this' -replace='module.devbox["<name>"].aws_instance.this'` per project so boxes boot with the new user data (data volumes survive). Then run `devbox secrets <name>` again (the token moved from SSM to the box). Remove `scripts_bucket`, `scripts_prefix` and `egress_cidrs` from `terraform.tfvars`.

Manual, once:

- **GitHub admin access for Terraform:** no separate token. `devbox` runs Terraform with `GITHUB_TOKEN=$(gh auth token)` (your `gh` login, default `repo` scope) set only for that process. Running Terraform by hand? Use `devbox tf ...`. Note: required reviewers on environments of private repos need GitHub Pro/Team for personal accounts.
- **Private devbox repo:** devbox Settings -> Actions -> General -> Access -> "Accessible from repositories owned by the user", so project repos can call the reusable workflow.
- **Agent machine user:** create a separate GitHub account for the agent (GitHub allows one free machine account per person) and set `agent_github_username` in `terraform.tfvars`. Terraform invites it as a push collaborator on each project repo; the agent's commits and PRs are its own, so it can't approve them.
- **Branch protection:** the default branch requires a PR with 1 approval, and the latest push must be approved by someone other than its pusher. That someone is you; the agent can open PRs but never merge. Admins aren't enforced, so you can still merge your own PRs (e.g. `copier update`) directly.
- **Modal:** create a dedicated workspace with a low spend limit. If you use W&B, store its key there (never in GitHub), with the Modal CLI logged in to that workspace: `modal secret create wandb WANDB_API_KEY=<key>`, and answer `use_wandb=true` in Copier.
- **Anthropic Console** (only if project code calls the API): dedicated workspace with a spend limit; its key goes only into Environment secrets.
- **AWS cost alerts:** each project gets an AWS Budget (`monthly_budget_usd`, emails `budget_email` at 80% actual / 100% forecast). Activate `Project` once under Billing → Cost allocation tags (it appears after the first tagged resource exists; data can lag ~24h).
- **claude.ai:** turn off or cap extra usage, and turn on trusted devices (the box's OAuth token is the one secret that reaches beyond the box: it can drive Remote Control on all your boxes).

## Onboarding a project

**1. In the project repo** (new or existing):

```bash
# New project
uvx copier copy gh:<owner>/devbox my-proj
cd my-proj && git init && git add -A && git commit -m "Init from devbox template"
gh repo create <owner>/my-proj --private --source . --push

# Existing project (run inside the repo; review the diff before committing)
uvx copier copy gh:<owner>/devbox .
git add -A && git commit -m "Add devbox template" && git push
```

**2. In the `devbox` repo:**

```bash
devbox add my-proj <owner>/my-proj   # optional: --type m7g.xlarge --data-gb 50
devbox secrets my-proj   # agent token -> the box (root-only file), Modal token -> repo's `modal` Environment
```

`devbox add` and `devbox retire` both plan first and abort if the plan touches anything beyond that project's creates/deletes (creating the shared EICE with the first project is allowed), then ask y/N before applying.

**3. Manual, once per project, as the machine user:** accept the invite (`https://github.com/<owner>/my-proj/invitations`), then create a **classic** token (Settings -> Developer settings -> Tokens (classic)) with only the `repo` scope, with an expiry. Paste it at the "Agent machine-user token" prompt of `devbox secrets`.
Why classic: fine-grained tokens can't be used on repos where the user is only a collaborator ([docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)). Leaving out the `workflow` scope means pushes that add or change `.github/workflows/` files are rejected ([scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps#available-scopes)).

**4. First login on the box:**

```bash
devbox open my-proj   # starts the box if needed; session opens as ubuntu: claude auth login
```

Then, still as ubuntu, accept the workspace trust prompt once (Remote Control runs headless and exits with "Workspace not trusted" otherwise). `ubuntu` has no sudo, so `exit` back to `admin` to restart the service:

```bash
cd /data/repo && claude   # accept "Trust this folder?", then /exit
exit                      # back to admin (has sudo)
sudo systemctl restart claude-rc
```

Must be the claude.ai login, not `setup-token`. After this, Remote Control comes up on every boot and the session appears in the Claude app as `my-proj`.

## Daily usage

`devbox start my-proj` (or a phone shortcut), work via the Claude app or `devbox open my-proj`; the box stops itself when idle. Also: `devbox stop|status my-proj`, `devbox ls`. To run on GPU: review the pushed commit's whole diff (including `pyproject.toml`/`uv.lock`), then trigger the project's `run-experiments` workflow with the SHA and configs.

**Admin on the box:** `devbox open` logs in as `admin` (passwordless sudo, created by bootstrap) and switches to `ubuntu` (no sudo); `exit` drops you back to `admin`. Never run repo code (`make check`, `uv run`, git hooks) as `admin`: it would run agent-written code with sudo.

**Sandbox and egress allowlist:** Claude Code's sandbox and network allowlist are enforced by the root-owned `/etc/claude-code/managed-settings.json` (from `infra/scripts/managed-settings.json`); the project's `.claude/settings.json` can't loosen them. To allow a domain: edit `infra/scripts/managed-settings.json`, then `devbox sync my-proj`.

**Box scripts:** `infra/scripts/*` are embedded in the launch template's user data (installed to `/opt/devbox/scripts` on first boot only; `bootstrap.sh` runs every boot). The launch template ignores later user-data changes so `devbox add`/`retire` plans stay scoped; push script edits to existing boxes with `devbox sync <name>` (copies them over SSH, re-runs bootstrap). Box settings (repo, idle minutes, data volume) come from instance tags via IMDS.

## Updates

- Template: `uvx copier update` in the project repo (review and commit the merge).
- Workflow logic: changes centrally via the reusable workflow at `@main`; no project change needed.

## Retiring a project

```bash
devbox retire my-proj
```

Asks you to type the name, stops the box, removes the JSON, plans, aborts if the plan touches anything but this project's resources (or anything other than deletes), asks y/N, applies, prints the final data-volume snapshot ID and the `aws ec2 delete-snapshot` command (the snapshot inherits `ManagedBy=devbox`, so the deployer may delete it), and commits the removal. The GitHub repo is never touched (only its `modal` Environment and branch protection go). Terraform also removes the machine user's collaborator access; revoke the token you made for this project.

## Security model

The agent on each box is treated as potentially hostile (prompt injection via code, issues, web pages).

- **It has:** its project repo checkout, a machine-user token that can push branches and open PRs on the repos that user collaborates on, CPU, and network egress only to the managed-settings allowlist (incl. github.com).
- **It can't:** read the Modal token or W&B key (they live in GitHub Environment / Modal secrets, never on the box), start a GPU run without your Environment approval, see run output, merge to the default branch or approve its own PRs, push workflow files, use sudo, use any AWS identity (no instance role; IMDS holds only tags and user data, no credentials), receive connections from anywhere but the EICE (tcp 22, IAM-gated), or loosen the managed settings.
- **Your AWS credentials** never reach a box: `devbox` uses them only in local child processes; a box receives only the agent token (over SSH stdin) and the scripts.
- **Residual risks:**
  - The agent can read its own repo token and push anything to non-default branches of every repo the machine user collaborates on (to scope tokens per repo, move project repos into a free GitHub org: a single machine user can then hold one fine-grained token per repo, without Actions/Workflows permissions; GitHub allows only one free machine account per person).
  - github.com egress means it can exfiltrate code it can read to GitHub.
  - A GPU run executes the commit's code on the Actions runner with the Modal token in env (`modal run` imports it; `uv sync` in the image build runs its dependencies). Review the whole diff, including `pyproject.toml` and `uv.lock`, before you trigger a run. The Modal workspace spend limit is the budget backstop.

## Dev

```bash
uv run pytest                       # CLI plan-scope check
terraform fmt -recursive infra
terraform -chdir=infra/terraform init -backend=false && terraform -chdir=infra/terraform validate
for f in infra/iam/*.json; do python3 -m json.tool "$f" >/dev/null; done
uvx --from shellcheck-py shellcheck infra/scripts/*.sh
```

## Manual acceptance checklist (needs a real AWS box)

- [ ] `terraform plan` is clean with two example projects against an existing VPC.
- [ ] `devbox add` creates only that project's resources; `devbox retire` destroys only that project's, leaves a final data-volume snapshot and the GitHub repo intact.
- [ ] `devbox secrets` sets values without them appearing in Terraform state, shell history or local files.
- [ ] A reboot brings up Remote Control automatically, named after the project.
- [ ] The box stops itself after the idle window.
- [ ] On the box: `/etc/devbox/github_token` is unreadable by `ubuntu`, IMDS returns no IAM credentials, `modal` has no credentials, `ubuntu` can't sudo, a non-allowlisted domain is blocked.
- [ ] `devbox open`/`secrets`/`sync` work through the EICE; the box SG has no ingress except tcp 22 from the EICE SG.
- [ ] With the `devbox` profile, changing or deleting an untagged resource (e.g. a non-devbox security group) is denied.
- [ ] The machine user can push a branch and open a PR but can't merge it, and its push of a `.github/workflows/` change is rejected.
- [ ] `copier copy` into an empty dir and into an existing repo both work; `copier update` applies a template change.
- [ ] In a freshly templated project, `make check` passes on the box in a few minutes, and the pre-push hook blocks a push when it fails.
- [ ] Triggering the caller workflow with a SHA and configs runs the GPU smoke stage first; a failing smoke stops the full runs; on success detached Modal runs launch and their links appear in the job summary.
