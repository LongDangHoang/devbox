# Spec: `devbox` — one repo for per-project Claude Code dev boxes + approved Modal runs

## Goal
A single repo (`devbox`) that:
1. **Provisions one EC2 dev box per ML project** (Terraform, `for_each` over one JSON file per project in `infra/projects/`; a Makefile wraps adding and retiring projects). On each box, Claude Code runs in **Remote Control server mode**, so I can drive it from the Claude mobile app or claude.ai/code, and SSH in via SSM from my desk.
2. **Configures each project's GitHub repo** (Environment, secrets, branch protection) via the Terraform `github` provider.
3. **Templates new or existing project repos** via **Copier** (`copier copy` / `copier update`).
4. **Hosts a reusable `run-experiments` workflow** that project repos call, so workflow logic lives in one place.

Each agent can write and run code locally (CPU PyTorch) but **cannot submit GPU jobs or read results**. GPU jobs run on **Modal**, triggered **only by me** via `workflow_dispatch` on a commit I reviewed.

Budget: ~US$0.10–0.25/hr per box while running, EBS-only cost while stopped.

## Architecture (per project)
```
Phone (Claude app) ──Remote Control──┐
Desk (SSH via SSM) ──────────────────┤
                                     ▼
EC2 box for <project>: Claude Code (sandboxed) — writes/runs code, pushes branches
   no Modal token, no W&B / results read access
                                     │ push branch + "run configs X,Y @ <sha>"
                                     ▼
<project> repo: I review diff → trigger caller workflow (inputs: sha, configs)
   → uses devbox/.github/workflows/run-experiments.yml (workflow_call)
   → Modal token + W&B key in <project>'s protected GitHub Environment
                                     │ modal run --detach
                                     ▼
Modal (dedicated workspace with hard budget) → results to W&B / S3 (only I can read)
```

## Repo layout
```
devbox/
  copier.yml                      # _subdirectory: template ; questions: project_name, python_version, default_gpu, ...
  template/                       # what gets copied into a project repo
    .github/workflows/run-experiments.yml.jinja   # thin caller of devbox reusable workflow
    .claude/settings.json         # sandbox on, push notifications, deny-read on secrets file
    CLAUDE.md.jinja               # agent conventions (see below)
    experiments/example.yml
    src/{{project_name}}/{train,config,modal_app,cli}.py.jinja   # see "Template contents"
    tests/                        # minimal: config loads, smoke run completes
    Makefile                      # setup, check
    pyproject.toml.jinja          # uv-managed; uv.lock committed
  .github/workflows/
    run-experiments.yml           # reusable workflow (on: workflow_call)
  infra/
    projects/                     # one <name>.json per active project (the source of truth)
    terraform/
      main.tf / variables.tf / outputs.tf / versions.tf
      modules/devbox/             # one EC2 box + IAM + SSM params + data volume
      modules/github_project/     # Environment, secrets placeholders, branch protection
      terraform.tfvars.example    # shared settings only (region, VPC, bucket, ...)
    scripts/                      # bootstrap.sh, idle-stop.sh, claude-rc.service, setup-boot.service
  Makefile                        # project lifecycle + daily-use commands (see below)
  README.md                       # setup, onboarding a project, daily usage, retiring
```

## Terraform (`infra/terraform`)
Projects are defined as **one JSON file per project** in `infra/projects/<name>.json`, so adding or retiring a project means creating or deleting a file, not editing HCL:
```json
{ "repo": "you/my-proj", "instance_type": "m7g.xlarge", "data_gb": 50 }
```
(`instance_type` and `data_gb` are optional overrides.) Root config builds the map with `fileset("${path.module}/../projects", "*.json")` + `jsondecode`, and does `for_each` over both modules. Shared variables: region (`ap-southeast-2`), existing VPC/subnet IDs, scripts S3 bucket/prefix, default instance type, idle minutes, GitHub owner. One state file; remote backend placeholder.

### `modules/devbox` (per project)
- **Existing VPC/subnet** via data sources; do not create a VPC.
- Security group with **no ingress**; egress 443 (plus 80 if package mirrors need it).
- Launch template:
  - IMDSv2 required, **hop limit 1**
  - instance-initiated shutdown behaviour = `stop`
  - Ubuntu 24.04 arm64 AMI (data source); default `m7g.xlarge`
- Root volume: gp3 ~30 GB.
- Separate **data volume** (gp3, `data_gb`) at `/data`. Holds the repo checkout, `~/.claude`, and caches.
  - Do **not** use `prevent_destroy` (it would block retiring a project). Instead set `final_snapshot = true` on `aws_ebs_volume` (verify the argument exists in the current AWS provider), so retiring leaves a cheap snapshot as a safety net.
  - Instance changes (AMI, type, replacement) must never replace the data volume.
- Tags: `Project=<name>`, `Name=devbox-<name>`.
- IAM instance profile:
  - `AmazonSSMManagedInstanceCore`
  - read only `/devbox/<name>/*` SSM params (+ KMS decrypt)
  - read only the scripts S3 prefix
- SSM SecureStrings under `/devbox/<name>/`:
  - `github_token`
  - `repo_url` (plain String, from the map)
  - Placeholders for secret values with `ignore_changes = [value]`; I set real values in the console.
- **Do not** manage running state (no `aws_ec2_instance_state`).
- Optional: AWS Budgets alert per `Project` tag.

### `modules/github_project` (per project)
- Uses the `integrations/github` provider. The admin token comes from my local env and is **never** placed on a box.
- Creates Environment `modal`:
  - required reviewer = me
  - deployment branches restricted to the default branch
- Environment secrets `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`, `WANDB_API_KEY` with placeholder values + `ignore_changes`.
- Branch protection on the default branch: no direct pushes by the agent (require PR), no force push.

## Boot behaviour (scripts in S3, pulled every boot)
- User data stays minimal: install `setup-boot.service`, which on **every boot** pulls the latest scripts from S3 and runs `bootstrap.sh`. Script changes then need only `terraform apply` + reboot, never replacement.
- `bootstrap.sh` (idempotent):
  - mount `/data`, formatting only if it has no filesystem
  - install/update: git, uv, Python, CPU PyTorch (aarch64), Node, Claude Code
  - fetch `/devbox/<name>/*` into an env file with mode 0600
  - symlink `~/.claude` → `/data/claude`
  - clone `repo_url` into `/data/repo` if absent, using `github_token`
  - configure git to push with that token
- `claude-rc.service`: `claude remote-control --spawn worktree --name <project>` in `/data/repo`, running as the dev user with `Restart=always`.
  - The environment must **not** set `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, or `DISABLE_GROWTHBOOK`.
  - Verify flags against https://code.claude.com/docs/en/remote-control.
- `idle-stop.sh` (timer, every 10 min): if there are no active SSM/SSH sessions, `/data/claude` has been unmodified for N minutes (default 30), and load is low, then `shutdown -h now`.
- Verify current Claude Code sandbox/settings key names in the docs before writing `.claude/settings.json`.

## Reusable workflow (`devbox/.github/workflows/run-experiments.yml`)
- `on: workflow_call` with inputs:
  - `sha` (required)
  - `configs` (comma-separated, under `experiments/`)
  - `entrypoint` (default from template)
- Job declares `environment: modal`, which resolves to the **caller** repo's Environment, and reads its secrets.
- Two jobs, both after my single approval:
  1. **`smoke`**: check out the caller repo at exactly `inputs.sha` (fail if unreachable), install the Modal client, and for each config run `modal run <entrypoint> --config <path> --smoke` (**not** detached) on the smallest GPU type in the allowlist, with a ~5 min timeout. Fails the workflow if any smoke run fails. Purpose: catch GPU-only failures (device mismatches, OOM at small scale, bf16/flash-attention/`torch.compile` paths) and Modal image/volume/secret wiring, for cents.
  2. **`run`** (`needs: smoke`): same checkout, then for each config `modal run --detach <entrypoint> --config <path>`, and write the Modal run URLs to the job summary.
- Input `skip_smoke` (boolean, default false) for reruns of a SHA that already passed.
- Smoke output stays in the Actions log and Modal dashboard, visible to me only. The agent sees nothing from either stage; I relay errors if needed.
- Template caller (`template/.github/workflows/run-experiments.yml.jinja`):
  - `on: workflow_dispatch` with the same inputs
  - one job: `uses: <owner>/devbox/.github/workflows/run-experiments.yml@main`, `secrets: inherit`
- README note: if `devbox` is private, enable Settings → Actions → Access → accessible from repositories owned by me.

## Template contents
Keep it small; this is a side-project template, not a framework.

- **Code structure: the local run is the real code path.**
  - `src/<project>/train.py`: a plain `run(config, device)` function containing all the work. No Modal imports.
  - `src/<project>/config.py`: config schema (pydantic or dataclasses). Loading a YAML validates it; a `smoke()` method returns a shrunk copy (tiny width/depth, a few batches, small data slice, 1–2 eval steps).
  - `src/<project>/modal_app.py`: thin wrapper only. Defines the image, GPU (from an allowlist in the config), `timeout`, `max_containers`, volumes and secrets, then calls `run(config, "cuda")`. A `--smoke` flag applies `config.smoke()`.
  - The Modal image installs from the same `uv.lock` the box uses, so local and remote dependencies match.
  - `cli.py` (or `python -m <project> --config X --smoke`) runs `run()` locally on CPU.
- **`make check`** (project Makefile): lint (ruff) + type check (pyright, basic mode) + unit tests (pytest) + config validation for every `experiments/*.yml` + CPU smoke run of each config named in `CONFIGS=` (default: all). Target runtime: a few minutes on the box.
  - A git `pre-push` hook (installed by `make setup`) runs `make check`.
- **`CLAUDE.md` conventions for the agent:**
  - You cannot run Modal jobs or view their outputs.
  - Only propose a run when `make check CONFIGS=...` passes on the exact commit. Then push the branch and reply with: `run <configs> @ <sha>`, what changed, and what to look for in the results.
  - Device hygiene, since CPU tests can't catch device bugs: pass `device` explicitly; create tensors with `device=`; no bare `.cuda()`; GPU-only features (bf16 autocast, flash attention, `torch.compile`) go behind config flags, which the local CPU smoke turns off and the GPU smoke stage leaves on.
  - Keep `modal_app.py` a thin wrapper; all logic in `run()`.
- `.claude/settings.json`: sandboxing on, deny-read on the secrets env file, push notifications for "actions required".

## Security rules (must hold)
1. Boxes have **no** Modal token and **no** W&B or results-bucket read credentials.
2. The agent's GitHub token is a fine-grained PAT ("selected repositories") with **Contents: read/write** (+ Pull requests) only. It must have **no** Actions or Workflows permission, so it can't edit workflows or trigger runs.
3. The default branch is protected; Modal secrets live only in the `modal` Environment, restricted to the default branch with a required reviewer.
4. Each box's IAM role reads only its own `/devbox/<name>/*` params.
5. No inbound ports; access only through SSM and Remote Control (outbound HTTPS).

## Makefile (in `devbox` root)
All targets take `NAME=<project>`; they wrap Terraform, the AWS CLI and `gh`. Each prints what it will do and relies on Terraform's own interactive approval (no `-auto-approve`).

| Target | Does |
|---|---|
| `make new-project NAME=x REPO=owner/x [TYPE=m7g.xlarge] [DATA_GB=50]` | Writes `infra/projects/x.json`, runs `terraform apply` (creates only x's box + GitHub settings), commits the JSON file. Fails if the file already exists or the GitHub repo doesn't. |
| `make secrets NAME=x` | Prompts (hidden input) for the agent GitHub token, Modal token ID/secret and W&B key. Writes the first to SSM (`aws ssm put-parameter --overwrite`) and the rest to the repo's `modal` Environment (`gh secret set --env modal --repo ...`). Values never touch disk or Terraform state. Empty input skips that secret. |
| `make login NAME=x` | Starts the box if stopped, waits for SSM, opens a session as the dev user so I can run `claude auth login`. |
| `make start / stop / status NAME=x` | Start, stop, or show state of x's box (by `Project` tag). |
| `make ssh NAME=x` | SSM session to x's box. |
| `make retire NAME=x` | See "Retiring a project" below. |
| `make list` | List projects (from `infra/projects/`) with each box's state. |

## Retiring a project
`make retire NAME=x`:
1. Confirms by asking me to type the project name.
2. Stops the box if running.
3. Deletes `infra/projects/x.json` and runs `terraform apply`. Terraform's plan should show **only** x's resources being destroyed; the target aborts if the plan touches any other project (check the plan output or use `terraform plan -out` + `terraform show -json` and grep resource addresses).
4. The data volume leaves a final snapshot (`final_snapshot = true`). Print its snapshot ID and the command to delete it later.
5. Commits the removal of the JSON file.

It must **not** delete or archive the GitHub repo itself; it only removes the `modal` Environment (with its secrets) and branch protection. README reminds me to remove the repo from the agent PAT's selected repositories.

## README: onboarding a project
The README must give copy-pasteable commands in this order, clearly split by where they run.

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
make new-project NAME=my-proj REPO=<owner>/my-proj
make secrets NAME=my-proj
```

**3. Manual, once per project:**
- GitHub → Settings → Fine-grained tokens → the agent PAT → add `my-proj` to selected repositories.

**4. First login on the box:**
```bash
make login NAME=my-proj   # then inside the session: claude auth login
```
Must be the claude.ai login, not `setup-token`. After this, Remote Control comes up on every boot and the session appears in the Claude app as `my-proj`.

**Later:**
- Template updates: `uvx copier update` in the project repo (review and commit the merge).
- Workflow logic updates centrally via the reusable workflow at `@main`; no project change needed.
- Daily use: `make start NAME=my-proj` (or the phone shortcut), work, and the box idles itself off.

The README also covers the one-time devbox setup: `terraform.tfvars` from the example, backend config, the GitHub admin token env var for Terraform, the private-repo Actions access setting, and the manual setup below.

## One-time manual setup
- A dedicated Modal workspace with a low budget / spend limit.
- If project code uses the Anthropic API: a dedicated Console workspace with a spend limit; its key goes only into Environment secrets.
- Turn off or cap extra usage on claude.ai.

## Acceptance criteria
- `terraform plan` is clean with two example projects against an existing VPC.
- `make new-project` creates only that project's resources; `make retire` destroys only that project's resources, leaves a final data-volume snapshot, and leaves the GitHub repo intact.
- `make secrets` sets values without them appearing in Terraform state, shell history or files.
- A reboot brings up Remote Control automatically, named after the project.
- The box stops itself after the idle window.
- On the box: the secrets file is unreadable from inside the sandbox, IMDS is unreachable from containers, and `modal` has no credentials.
- `copier copy` into an empty dir and into an existing repo both work; `copier update` applies a template change.
- In a freshly templated project, `make check` passes on the box in a few minutes, and the pre-push hook blocks a push when it fails.
- Triggering the caller workflow with a SHA and configs runs a GPU smoke stage first; a failing smoke stops the full runs. On success, detached Modal runs launch and their links appear in the job summary.
