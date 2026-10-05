# devbox

One EC2 dev box per ML project (Claude Code in Remote Control mode), GitHub repo settings via Terraform, a Copier project template, and a reusable `run-experiments` workflow that launches Modal GPU jobs only when you approve.

Projects are one JSON file each in `infra/projects/<name>.json` (`{"repo": "<owner>/<name>", "instance_type": "...", "data_gb": 50}`; the last two optional). The Makefile wraps adding and retiring them.

## One-time devbox setup

Prereqs: `terraform` >= 1.11 (write-only arguments), `aws` CLI + [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `gh` (logged in), `jq`, `uv`. GNU make 3.81 / bash 3.2 are fine.

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # region, VPC/subnet, bucket, GitHub owner, agent_github_username...
cat > infra/terraform/backend.hcl <<'EOF'
bucket = "<state-bucket>"
key    = "devbox/terraform.tfstate"
region = "ap-southeast-2"
EOF
terraform -chdir=infra/terraform init -backend-config=backend.hcl
export GITHUB_TOKEN=<admin-token>   # local only, never on a box
```

`terraform.tfvars` and `backend.hcl` are gitignored. Region defaults to `ap-southeast-2`; if you change `region` in `terraform.tfvars`, also pass `REGION=...` to make (or export it).

Manual, once:

- **GitHub admin token for Terraform** (`GITHUB_TOKEN`, your account): classic token with `repo`, or fine-grained with Administration + Environments + Secrets read/write on the project repos. Note: required reviewers on environments of private repos need GitHub Pro/Team for personal accounts.
- **Private devbox repo:** devbox Settings -> Actions -> General -> Access -> "Accessible from repositories owned by the user", so project repos can call the reusable workflow.
- **Agent machine user:** create a separate GitHub account for the agent (GitHub allows one free machine account per person) and set `agent_github_username` in `terraform.tfvars`. Terraform invites it as a push collaborator on each project repo; the agent's commits and PRs are its own, so it can't approve them.
- **Branch protection:** the default branch requires a PR with 1 approval, and the latest push must be approved by someone other than its pusher. That someone is you; the agent can open PRs but never merge. Admins aren't enforced, so you can still merge your own PRs (e.g. `copier update`) directly.
- **Modal:** create a dedicated workspace with a low spend limit. If you use W&B, store its key there (never in GitHub), with the Modal CLI logged in to that workspace: `modal secret create wandb WANDB_API_KEY=<key>`, and answer `use_wandb=true` in Copier.
- **Anthropic Console** (only if project code calls the API): dedicated workspace with a spend limit; its key goes only into Environment secrets.
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
make new-project NAME=my-proj REPO=<owner>/my-proj   # optional: TYPE=m7g.xlarge DATA_GB=50
make secrets NAME=my-proj   # agent token -> SSM, Modal token -> repo's `modal` Environment
```

**3. Manual, once per project, as the machine user:** accept the invite (`https://github.com/<owner>/my-proj/invitations`), then create a **classic** token (Settings -> Developer settings -> Tokens (classic)) with only the `repo` scope, with an expiry. Paste it at the "Agent machine-user token" prompt of `make secrets`.
Why classic: fine-grained tokens can't be used on repos where the user is only a collaborator ([docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)). Leaving out the `workflow` scope means pushes that add or change `.github/workflows/` files are rejected ([scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps#available-scopes)).

**4. First login on the box:**

```bash
make login NAME=my-proj   # session opens as ubuntu: claude auth login
```

Then, still as ubuntu, accept the workspace trust prompt once (Remote Control runs headless and exits with "Workspace not trusted" otherwise). `ubuntu` has no sudo, so `exit` back to `ssm-user` to restart the service:

```bash
cd /data/repo && claude   # accept "Trust this folder?", then /exit
exit                      # back to ssm-user (has sudo)
sudo systemctl restart claude-rc
```

Must be the claude.ai login, not `setup-token`. After this, Remote Control comes up on every boot and the session appears in the Claude app as `my-proj`.

## Daily usage

`make start NAME=my-proj` (or a phone shortcut), work via the Claude app or `make ssh NAME=my-proj`; the box stops itself when idle. Also: `make stop|status NAME=...`, `make list`. To run on GPU: review the pushed commit's whole diff (including `pyproject.toml`/`uv.lock`), then trigger the project's `run-experiments` workflow with the SHA and configs.

**Admin on the box:** `make ssh` lands as `ubuntu` (no sudo); `exit` drops you to `ssm-user`, which has sudo. Never run repo code (`make check`, `uv run`, git hooks) as `ssm-user`: it would run agent-written code with sudo.

**Sandbox and egress allowlist:** Claude Code's sandbox and network allowlist are enforced by the root-owned `/etc/claude-code/managed-settings.json` (from `infra/scripts/managed-settings.json`); the project's `.claude/settings.json` can't loosen them. To allow a domain: edit `infra/scripts/managed-settings.json`, `terraform -chdir=infra/terraform apply`, then reboot the box (`sudo reboot` as ssm-user, or `make stop` + `make start`).

## Updates

- Template: `uvx copier update` in the project repo (review and commit the merge).
- Workflow logic: changes centrally via the reusable workflow at `@main`; no project change needed.

## Retiring a project

```bash
make retire NAME=my-proj
```

Asks you to type the name, stops the box, removes the JSON, plans, aborts if the plan touches anything but this project's resources (or anything other than deletes), asks y/N, applies, prints the final data-volume snapshot ID and the `aws ec2 delete-snapshot` command, and commits the removal. The GitHub repo is never touched (only its `modal` Environment and branch protection go). Terraform also removes the machine user's collaborator access; revoke the token you made for this project.

## Security model

The agent on each box is treated as potentially hostile (prompt injection via code, issues, web pages).

- **It has:** its project repo checkout, a machine-user token that can push branches and open PRs on the repos that user collaborates on, CPU, and network egress only to the managed-settings allowlist (incl. github.com).
- **It can't:** read the Modal token or W&B key (they live in GitHub Environment / Modal secrets, never on the box), start a GPU run without your Environment approval, see run output, merge to the default branch or approve its own PRs, push workflow files, use sudo, reach IMDS from the sandbox, or loosen the managed settings.
- **Residual risks:**
  - The agent can read its own repo token and push anything to non-default branches of every repo the machine user collaborates on (use one machine user per project if that matters).
  - github.com egress means it can exfiltrate code it can read to GitHub.
  - A GPU run executes the commit's code on the Actions runner with the Modal token in env (`modal run` imports it; `uv sync` in the image build runs its dependencies). Review the whole diff, including `pyproject.toml` and `uv.lock`, before you trigger a run. The Modal workspace spend limit is the budget backstop.

## Dev

`make fmt`, `make validate`, `make help`.

## Manual acceptance checklist (needs a real AWS box)

- [ ] `terraform plan` is clean with two example projects against an existing VPC.
- [ ] `make new-project` creates only that project's resources; `make retire` destroys only that project's, leaves a final data-volume snapshot and the GitHub repo intact.
- [ ] `make secrets` sets values without them appearing in Terraform state, shell history or files.
- [ ] A reboot brings up Remote Control automatically, named after the project.
- [ ] The box stops itself after the idle window.
- [ ] On the box: the secrets file is unreadable from inside the sandbox, IMDS is unreachable from containers, `modal` has no credentials, `ubuntu` can't sudo, a non-allowlisted domain is blocked.
- [ ] The machine user can push a branch and open a PR but can't merge it, and its push of a `.github/workflows/` change is rejected.
- [ ] `copier copy` into an empty dir and into an existing repo both work; `copier update` applies a template change.
- [ ] In a freshly templated project, `make check` passes on the box in a few minutes, and the pre-push hook blocks a push when it fails.
- [ ] Triggering the caller workflow with a SHA and configs runs the GPU smoke stage first; a failing smoke stops the full runs; on success detached Modal runs launch and their links appear in the job summary.
