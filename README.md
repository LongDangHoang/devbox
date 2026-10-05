# devbox

One EC2 dev box per ML project (Claude Code in Remote Control mode), GitHub repo settings via Terraform, a Copier project template, and a reusable `run-experiments` workflow that launches Modal GPU jobs only when you approve.

Projects are one JSON file each in `infra/projects/<name>.json` (`{"repo": "<owner>/<name>", "instance_type": "...", "data_gb": 50}`; the last two optional). The Makefile wraps adding and retiring them.

## One-time devbox setup

Prereqs: `terraform`, `aws` CLI + [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `gh` (logged in), `jq`, `uv`. GNU make 3.81 / bash 3.2 are fine.

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # region, VPC/subnet, scripts bucket, GitHub owner...
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

- **GitHub admin token for Terraform** (`GITHUB_TOKEN`): classic token with `repo`, or fine-grained with Administration + Environments + Secrets read/write on the project repos. Note: required reviewers on environments of private repos need GitHub Pro/Team for personal accounts.
- **Private devbox repo:** devbox Settings -> Actions -> General -> Access -> "Accessible from repositories owned by the user", so project repos can call the reusable workflow.
- **Agent PAT** (fine-grained, "selected repositories", added per project): Contents read/write + Pull requests read/write. **No** Actions or Workflows permission. Its token is what `make secrets` stores on the box.
- **Branch protection** uses `enforce_admins=true` because the agent PAT acts as you; you go through PRs too.
- **Modal:** create a dedicated workspace with a low spend limit.
- **Anthropic Console** (only if project code calls the API): dedicated workspace with a spend limit; its key goes only into Environment secrets.
- **claude.ai:** turn off or cap extra usage.

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
make secrets NAME=my-proj
```

**3. Manual, once per project:** GitHub -> Settings -> Fine-grained tokens -> the agent PAT -> add `my-proj` to selected repositories.

**4. First login on the box:**

```bash
make login NAME=my-proj   # then inside the session: claude auth login
```

Then, still in the session, accept the workspace trust prompt once (Remote Control runs headless and exits with "Workspace not trusted" otherwise):

```bash
cd /data/repo && claude   # accept "Trust this folder?", then /exit
sudo systemctl restart claude-rc
```

Must be the claude.ai login, not `setup-token`. After this, Remote Control comes up on every boot and the session appears in the Claude app as `my-proj`.

## Daily usage

`make start NAME=my-proj` (or a phone shortcut), work via the Claude app or `make ssh NAME=my-proj`; the box stops itself when idle. Also: `make stop|status NAME=...`, `make list`. To run on GPU: review the pushed commit, then trigger the project's `run-experiments` workflow with the SHA and configs.

## Updates

- Template: `uvx copier update` in the project repo (review and commit the merge).
- Workflow logic: changes centrally via the reusable workflow at `@main`; no project change needed.

## Retiring a project

```bash
make retire NAME=my-proj
```

Asks you to type the name, stops the box, removes the JSON, plans, aborts if the plan touches anything but this project's resources (or anything other than deletes), asks y/N, applies, prints the final data-volume snapshot ID and the `aws ec2 delete-snapshot` command, and commits the removal. The GitHub repo is never touched (only its `modal` Environment and branch protection go). Afterwards remove the repo from the agent PAT's selected repositories.

## Dev

`make fmt`, `make validate`, `make help`.

## Manual acceptance checklist (needs a real AWS box)

- [ ] `terraform plan` is clean with two example projects against an existing VPC.
- [ ] `make new-project` creates only that project's resources; `make retire` destroys only that project's, leaves a final data-volume snapshot and the GitHub repo intact.
- [ ] `make secrets` sets values without them appearing in Terraform state, shell history or files.
- [ ] A reboot brings up Remote Control automatically, named after the project.
- [ ] The box stops itself after the idle window.
- [ ] On the box: the secrets file is unreadable from inside the sandbox, IMDS is unreachable from containers, `modal` has no credentials.
- [ ] `copier copy` into an empty dir and into an existing repo both work; `copier update` applies a template change.
- [ ] In a freshly templated project, `make check` passes on the box in a few minutes, and the pre-push hook blocks a push when it fails.
- [ ] Triggering the caller workflow with a SHA and configs runs the GPU smoke stage first; a failing smoke stops the full runs; on success detached Modal runs launch and their links appear in the job summary.
