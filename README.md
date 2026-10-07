# devbox

One EC2 dev box per ML project (Claude Code in Remote Control mode), GitHub repo settings via Terraform, a Copier project template, and a reusable `run-experiments` workflow that launches Modal GPU jobs only when you trigger them.

Projects are one JSON file each in `infra/projects/<name>.json` (`{"repo": "<owner>/<name>", "instance_type": "...", "data_gb": 50}`; the last two optional). The `devbox` CLI writes and removes these files for you.

## What's manual and what's automated

**You do by hand, once:**

1. Install the local tools and the `devbox` CLI.
2. GitHub: push this repo, allow other repos to use its workflow, create a machine-user account for the agent.
3. AWS: choose a VPC and subnet with outbound internet, create the Terraform state bucket, and create the IAM user, boundary and role in the console (the deployer role can't create IAM).
4. Fill in the local config files (`terraform.tfvars`, `backend.hcl`, `~/.aws/config`), then run `devbox auth` and `devbox tf init`.
5. Modal: create a dedicated workspace with a spend limit and an API token. claude.ai: cap extra usage.
6. After the first project exists: activate the `Project` cost allocation tag.

**You do by hand, once per project:**

1. `devbox init-project` (creates the repo from the Copier template).
2. `devbox add` (you confirm the plan).
3. As the machine user: accept the repo invite, then create a classic token.
4. `devbox secrets` (paste the tokens).
5. `devbox open`: run `claude auth login` and accept workspace trust.

**Terraform and `devbox` handle from then on:**

- **Per project (Terraform):** the box (launch template, instance, security group, root volume), a persistent data volume that leaves a final snapshot on retire, an AWS Budget, and on GitHub: the `modal` Environment (default branch only), placeholder Modal secrets, the machine-user collaborator invite, and branch protection.
- **Shared (Terraform, created by the first `devbox add`):** the EC2 Instance Connect Endpoint and its security group.
- **On every boot (`bootstrap.sh`):** takes sudo away from `ubuntu`, creates `admin`, mounts `/data`, installs packages, writes the Claude Code managed settings (sandbox and egress allowlist), sets up git credentials from the token, installs or updates Claude Code, clones the repo, and starts Remote Control and the idle-stop timer.
- **`devbox` CLI:** scoped plan, confirm and apply on add/retire; commits the project JSON; carries secrets over stdin only; starts and stops boxes; pushes script changes (`devbox sync`); prints the final snapshot on retire.

## One-time setup

### 1. Tools and CLI

You need `terraform` >= 1.11, AWS CLI v2 (includes `aws ec2-instance-connect`), OpenSSH (`ssh`, `ssh-keygen`), `gh` and `uv`.

```bash
uv tool install -e .   # from this repo; editable so `devbox` finds infra/. `devbox --help` lists commands
gh auth login          # devbox hands this login to Terraform (never exported, never on a box)
```

### 2. GitHub

- **Plan:** project repos are private, so your account needs **GitHub Pro** (or higher) for Environments, Environment secrets and branch protection. On GitHub Free, make the project repos public instead.
- **This repo on GitHub** at `<owner>/devbox`. Copier templates from it and project repos call its workflow at `@main`, so push changes here before using them.
- **If this repo is private:** Settings -> Actions -> General -> Access -> "Accessible from repositories owned by the user".
- **Machine user:** create a second GitHub account for the agent (GitHub allows one free machine account per person). Its username goes into `agent_github_username`. The agent pushes and opens PRs as this account, so it can't approve its own PRs or trigger GPU runs.

### 3. AWS prerequisites

Pick these values. Nothing has a default:

- `<account>`: your AWS account ID.
- `<region>`: where the boxes run (e.g. `us-west-2`).
- `<state-bucket>`: an S3 bucket for Terraform state. It **must be in `<region>`** (the deployer is denied every other region). Turn on versioning and Block Public Access.
- `<state-key>`: the state file's path in that bucket (e.g. `devbox/terraform.tfstate`).
- A VPC and a subnet in `<region>` with **outbound internet** (a public subnet with "auto-assign public IPv4", or a private subnet with a NAT gateway). Boxes download packages on boot and need 443 out. They have no inbound ports either way.

Recommended: `aws ec2 enable-ebs-encryption-by-default --region <region>` (as admin). It makes new boxes' volumes encrypted.

### 4. IAM (console, as admin, once)

`devbox` never uses your admin credentials. It runs as the role `devbox-deployer`, which a dedicated user `devbox-operator` assumes with MFA. The role has `PowerUserAccess`, capped by the permissions boundary `devbox-deployer-boundary`. The three policies are in `infra/iam/`. Replace the `<...>` placeholders with your values from step 3 before pasting.

1. **User:** create `devbox-operator` (no console access). Assign it an MFA device and create an access key. Give it one inline policy, `assume-devbox-deployer`, from `infra/iam/operator-policy.json`. It must have no other policies or groups. In particular, don't add an `aws:MultiFactorAuthPresent` condition here or attach AWS's "force MFA" example policy: `AssumeRole` is signed with the long-term key, so that condition never matches and the call is denied. The role's trust policy enforces MFA instead.
2. **Boundary:** create the customer-managed policy `devbox-deployer-boundary` from `infra/iam/deployer-boundary.json`. `<state-bucket>` and `<state-key>` must match `backend.hcl` exactly: the boundary only allows S3 writes to the state file and its `.tflock` lock file.
3. **Role:** create `devbox-deployer` with a custom trust policy from `infra/iam/deployer-trust.json` (it requires MFA). Attach `PowerUserAccess`, set its permissions boundary to `devbox-deployer-boundary`, and leave the maximum session duration at 1 hour.

Create the user before the role, since the trust policy names the user. If you ever delete and recreate the user, re-save the role's trust policy. AWS stores the old user's internal ID (`AIDA...`) there, and it silently stops matching.

When you change `deployer-boundary.json` later, paste it into the console again (Policies -> `devbox-deployer-boundary` -> Edit). Nothing applies it automatically.

### 5. Local config

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # fill in every value
cat > infra/terraform/backend.hcl <<'EOF'
bucket       = "<state-bucket>"
key          = "<state-key>"
region       = "<region>"
use_lockfile = true
EOF
```

Both files are gitignored. `devbox` reads `region` from `terraform.tfvars` (`devbox --region ...` overrides it) and errors if it's missing.

Put the operator's access key in `~/.aws/credentials` as `[devbox-operator]`, and add this to `~/.aws/config`:

```ini
[profile devbox-operator]
region = <region>

[profile devbox]
role_arn = arn:aws:iam::<account>:role/devbox-deployer
source_profile = devbox-operator
mfa_serial = arn:aws:iam::<account>:mfa/<device-name>
duration_seconds = 3600
```

To use a different profile name, set `DEVBOX_AWS_PROFILE`.

### 6. Authenticate and initialise Terraform

```bash
devbox auth                                      # MFA prompt; shows assumed-role/devbox-deployer/...
devbox tf init -backend-config=backend.hcl
```

The AWS CLI caches the 1-hour session in `~/.aws/cli/cache`. Each `devbox` run gets the keys from `aws configure export-credentials --profile devbox` and passes them only to its own `aws`/`terraform`/`ssh` child processes. `devbox tf <args>` runs `terraform -chdir=infra/terraform` with those credentials and `GITHUB_TOKEN` from `gh auth token`. Terraform can't prompt for MFA, so plain `terraform` gets no credentials. Use `devbox tf` for any manual Terraform command.

There's nothing to apply yet. The first `devbox add` creates the shared endpoint together with the first box.

**`AccessDenied` from `devbox auth`, with the caller shown as `user/devbox-operator`:**
- **The user's policy:** it's missing, it has an MFA condition, or its `Resource` isn't exactly the role ARN.
- **Another policy on the user:** a group or policy denies the call, e.g. a force-MFA policy.
- **The trust policy:** it doesn't name `user/devbox-operator` (or shows a stale `AIDA...` ID), or `mfa_serial` isn't the device assigned to this user.
- **The session duration:** `duration_seconds` is larger than the role's maximum. This shows up as a `ValidationError`.

`aws sts get-caller-identity --profile devbox-operator` checks the key alone. `aws sts get-caller-identity --profile devbox` checks the whole chain.

### 7. Modal and claude.ai

- **Modal:** create a dedicated workspace with a low spend limit. Create an API token for it (Modal dashboard -> Settings -> API Tokens, or `modal token new` while logged in to that workspace). Keep the token ID and secret for `devbox secrets`. If you use W&B, store its key in Modal (never GitHub): `modal secret create wandb WANDB_API_KEY=<key>`, and answer `use_wandb=true` in Copier.
- **Anthropic Console** (only if project code calls the API): a dedicated workspace with a spend limit. Its key goes only into Environment secrets.
- **claude.ai:** you need a plan with Remote Control. Turn off or cap extra usage, and turn on trusted devices. The box's OAuth token is the one secret that reaches beyond the box: it can drive Remote Control on all your boxes.

## Adding a project

**1. Create the project repo from the template** (it must exist on GitHub before `devbox add`):

```bash
devbox init-project my-proj                        # new: ./my-proj, private repo <owner>/my-proj, pushed
devbox init-project my-proj --path ~/code/my-proj  # existing git repo: applies the template; review, commit, push yourself
```

It runs Copier against this repo's GitHub copy (`gh:<owner>/devbox`), so push template changes here first. The project name, owner and devbox repo are filled in; Copier asks for the rest (package name, Python version, GPU, W&B), with defaults.

**2. Create the box and the GitHub settings** (in this repo):

```bash
devbox add my-proj <owner>/my-proj   # optional: --type m7g.2xlarge --data-gb 100
git push                             # devbox add committed infra/projects/my-proj.json
```

`devbox add` writes the JSON, plans, and aborts if the plan touches anything other than this project's creates (plus the shared endpoint on the first add). It asks y/N before applying. The box starts booting right away.

**3. As the machine user** (log in to GitHub as that account):
- Accept the invite at `https://github.com/<owner>/my-proj/invitations`.
- Create a **classic** token (Settings -> Developer settings -> Tokens (classic)) with only the `repo` scope and an expiry.

Why classic: fine-grained tokens can't be used on repos where the user is only a collaborator ([docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)). Without the `workflow` scope, pushes that add or change `.github/workflows/` files are rejected ([scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps#available-scopes)).

**4. Store the secrets:**

```bash
devbox secrets my-proj
```

It prompts with hidden input. The machine-user token goes to the box (`/etc/devbox/github_token`, root-only), and the box then sets up git credentials and clones the repo. `MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET` go to the repo's `modal` Environment. Empty input skips a value, so you can rerun this any time (e.g. to rotate the token). If the clone fails, check that the invite was accepted, then run `devbox secrets my-proj` again with the token.

**5. Log in to Claude on the box:**

```bash
devbox open my-proj   # session opens as ubuntu
claude auth login     # the claude.ai login, not setup-token
cd /data/repo && claude   # accept "Trust this folder?", then /exit
exit                      # back to admin (has sudo)
sudo systemctl restart claude-rc
```

Remote Control runs headless and exits with "Workspace not trusted" until you accept the trust prompt. From now on it comes up on every boot, and the session appears in the Claude app as `my-proj`.

**6. First project only:** in Billing -> Cost allocation tags, activate `Project`. It appears about a day after the first tagged resource exists. Until then the per-project budgets see no costs.

## Daily usage

`devbox start my-proj` (or a phone shortcut), then work in the Claude app or with `devbox open my-proj`. The box stops itself when idle. Also: `devbox stop|status my-proj`, `devbox ls`.

**GPU runs:** the agent replies `run <configs> @ <sha>`. Review that commit's whole diff (including `pyproject.toml` and `uv.lock`), then in the project repo go to Actions -> run-experiments -> Run workflow with the SHA and configs. The job runs only when you (the repo owner) trigger it. If the machine user dispatches or re-runs it, the job is skipped.

**Admin on the box:** `devbox open` logs in as `admin` (passwordless sudo) and switches to `ubuntu` (no sudo). `exit` drops you back to `admin`. Never run repo code (`make check`, `uv run`, git hooks) as `admin`: that would run agent-written code with sudo.

**Egress allowlist:** Claude Code's sandbox and network allowlist are enforced by the root-owned `/etc/claude-code/managed-settings.json` (from `infra/scripts/managed-settings.json`), and the project's `.claude/settings.json` can't loosen them. To allow a domain, edit `infra/scripts/managed-settings.json`, then run `devbox sync my-proj`.

**Box scripts:** `infra/scripts/*` are baked into the launch template's user data on first boot only. After that, `devbox sync <name>` copies them over SSH and re-runs bootstrap. The launch template ignores user-data and AMI changes so add/retire plans stay scoped. To rebuild a box onto a new AMI, run `devbox tf apply -replace='module.devbox["<name>"].aws_launch_template.this' -replace='module.devbox["<name>"].aws_instance.this'`. The data volume survives.

**Access path:** one EC2 Instance Connect Endpoint in `subnet_id` (AWS allows one per VPC). Box security groups accept tcp 22 only from the endpoint's security group. `devbox` pushes a throwaway SSH key (valid 60s) with `ec2-instance-connect send-ssh-public-key` and connects through `ec2-instance-connect open-tunnel`. Both calls are IAM-gated.

## Updates

- Template: `uvx copier update` in the project repo (review and commit the merge). As admin you can merge it without a second reviewer.
- Workflow logic: push to this repo's `main`. Projects use `@main`, so no project change is needed.
- Boundary policy: edit `infra/iam/deployer-boundary.json`, then paste it into the console.

## Retiring a project

```bash
devbox retire my-proj
git push
```

It asks you to type the name, stops the box, removes the JSON, and plans. It aborts if the plan does anything other than delete this project's resources, then asks y/N and applies. It prints the final data-volume snapshot ID and the `aws ec2 delete-snapshot` command (the snapshot carries `ManagedBy=devbox`, so the deployer may delete it), then commits the removal. The GitHub repo is never touched; only its `modal` Environment, branch protection and the machine user's access are removed. Revoke the token you made for this project.

## The deployer guard

The guard is accident prevention, not attacker containment: a compromised laptop is game over anyway.

- **EC2 resources without the `ManagedBy=devbox` tag:** the deployer can't terminate, stop, modify or delete them, and it can't add `ManagedBy` to an existing resource to get around this. It can still create things. Terraform tags everything it creates via `default_tags`.
- **Other services:** the deployer can't delete anything in RDS, DynamoDB, Lambda, ... at all (devbox creates nothing there). EC2 actions that don't support `aws:ResourceTag` are denied outright, because the negated condition matches when the key is missing. That's why IAM Access Analyzer flags the EC2 statement; it fails closed.
- **S3:** the only S3 writes or deletes allowed are on the state file and its lock file.
- **Budgets:** only budgets named `devbox-*` can be changed.
- **Also blocked:** all IAM except creating the Instance Connect service-linked role, `sts` role hopping, and every region except `<region>` (budgets excepted).
- **The boundary caps the role** even if you attach a broader policy later.
- **If a devbox operation hits `AccessDenied`:** add a narrowly scoped exception to `infra/iam/deployer-boundary.json` and update the policy in the console. Changes the deployer can't make (e.g. adopting an untagged resource) need a one-off `terraform apply` with admin credentials.
- **Later:** IAM Access Analyzer can generate a least-privilege policy from CloudTrail to replace `PowerUserAccess`.

## Security model

The agent on each box is treated as potentially hostile (prompt injection via code, issues, web pages).

- **It has:** its project repo checkout, a machine-user token that can push branches and open PRs on the repos that user collaborates on, CPU, and network egress from its sandbox to the managed-settings allowlist only (including github.com).
- **It can't:** read the Modal token or W&B key (they live in the GitHub Environment and Modal secrets, never on the box), start a GPU run (the workflow job runs only when the repo owner triggers it), merge to the default branch or approve its own PRs, push workflow files, use sudo, use any AWS identity (no instance role; IMDS holds only tags and user data, no credentials), receive connections from anywhere but the endpoint (tcp 22, IAM-gated), or loosen the managed settings.
- **Your AWS credentials** never reach a box. `devbox` uses them only in local child processes. A box receives only the agent token (over SSH stdin) and the scripts.
- **Residual risks:**
  - The agent can read its own repo token and push anything to non-default branches of every repo the machine user collaborates on. To scope tokens per repo, move project repos into a free GitHub org: one machine user can then hold one fine-grained token per repo, without Actions/Workflows permissions.
  - github.com egress means it can exfiltrate any code it can read to GitHub.
  - It can read Actions logs and job summaries of its repos, including GPU smoke-run output and Modal run links. Don't print anything secret in runs.
  - The allowlist is enforced by Claude Code's sandbox, not the network: the box security group allows 80/443 out to anywhere. A sandbox escape gets the open internet.
  - A GPU run executes the commit's code on the Actions runner with the Modal token in its env (`modal run` imports it; `uv sync` in the image build runs its dependencies). Review the whole diff, including `pyproject.toml` and `uv.lock`, before you trigger a run. The Modal workspace spend limit is the budget backstop.
  - If you push to a PR branch the agent also committed to, your push counts as the last push and the agent can then approve and merge that PR. Open such fixes as your own PR instead.

## Dev

```bash
uv run pytest                       # CLI plan-scope check
terraform fmt -recursive infra
terraform -chdir=infra/terraform init -backend=false && terraform -chdir=infra/terraform validate
for f in infra/iam/*.json; do python3 -m json.tool "$f" >/dev/null; done
uvx --from shellcheck-py shellcheck infra/scripts/*.sh
```

## Manual acceptance checklist (needs a real AWS box)

- [ ] Following this README from scratch, the first `devbox add` applies cleanly against an existing VPC; a second project's add is scoped to it.
- [ ] `devbox retire` destroys only that project's resources and leaves a final data-volume snapshot and the GitHub repo intact.
- [ ] `devbox secrets` sets values without them appearing in Terraform state, shell history or local files.
- [ ] A reboot brings up Remote Control automatically, named after the project.
- [ ] The box stops itself after the idle window.
- [ ] On the box: `/etc/devbox/github_token` is unreadable by `ubuntu`, IMDS returns no IAM credentials, `modal` has no credentials, `ubuntu` can't sudo, a non-allowlisted domain is blocked.
- [ ] `devbox open`/`secrets`/`sync` work through the endpoint; the box SG has no ingress except tcp 22 from the endpoint SG.
- [ ] With the `devbox` profile: changing or deleting an untagged resource (e.g. a non-devbox security group) is denied, adding `ManagedBy=devbox` to it is denied, and writing to an S3 object other than the state file is denied.
- [ ] The machine user can push a branch and open a PR but can't merge it, and its push of a `.github/workflows/` change is rejected.
- [ ] A `run-experiments` dispatch by the machine user is skipped; one by you runs.
- [ ] `copier copy` into an empty dir and into an existing repo both work; `copier update` applies a template change.
- [ ] In a freshly templated project, `make check` passes on the box in a few minutes, and the pre-push hook blocks a push when it fails.
- [ ] Triggering the caller workflow with a SHA and configs runs the GPU smoke stage first; a failing smoke stops the full runs; on success detached Modal runs launch and their links appear in the job summary.
