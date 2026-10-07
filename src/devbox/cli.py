"""devbox: manage per-project Claude Code dev boxes (wraps terraform, aws, ssh and gh)."""

import argparse
import functools
import getpass
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # needs an editable install (`uv tool install -e .`)
PROJECTS = ROOT / "infra" / "projects"
TF_DIR = ROOT / "infra" / "terraform"
SCRIPTS = ROOT / "infra" / "scripts"
LIVE = "Name=instance-state-name,Values=pending,running,stopping,stopped"
# Shell as ubuntu (no sudo); `exit` drops to admin (has sudo).
SESSION_CMD = 'sudo -iu ubuntu; echo "now admin (sudo available); exit again to end"; exec bash -l'
# Shared, project-independent resources a scoped plan may create (the first `devbox add` makes them).
SHARED = ("aws_security_group.eice", "aws_ec2_instance_connect_endpoint.this")
PROFILE = os.environ.get("DEVBOX_AWS_PROFILE", "devbox")
REGION = ""  # set in main(): --region or `region` in terraform.tfvars


def die(msg: str):
    sys.exit(f"error: {msg}")


def run(*cmd: str, capture=False, input=None, check=True, cwd=None, env=None):
    """Run cmd; stderr always goes to the terminal. Returns stdout (capture) or the exit code."""
    try:
        r = subprocess.run(
            cmd,
            text=not isinstance(input, bytes),
            input=input,
            stdout=subprocess.PIPE if capture else None,
            cwd=cwd,
            env=env,
            check=False,
        )
    except FileNotFoundError:
        die(f"{cmd[0]} not found on PATH (see README prerequisites)")
    if check and r.returncode:
        die(f"`{' '.join(cmd[:3])} ...` failed (exit {r.returncode})")
    return r.stdout.strip() if capture else r.returncode


@functools.cache
def aws_env() -> dict:
    """Child env with the deployer role's temporary credentials, resolved once per invocation.
    The AWS CLI prompts for MFA on the tty (stdin inherited) and caches the session itself;
    devbox only puts the keys into child environments, never on disk."""
    out = run(
        "aws", "configure", "export-credentials", "--profile", PROFILE, "--format", "process", capture=True
    )
    c = json.loads(out)
    env = {k: v for k, v in os.environ.items() if k not in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE")}
    env.update(
        AWS_ACCESS_KEY_ID=c["AccessKeyId"],
        AWS_SECRET_ACCESS_KEY=c["SecretAccessKey"],
        AWS_SESSION_TOKEN=c["SessionToken"],
    )
    return env


def aws(*args: str, **kw):
    return run("aws", "--region", REGION, *args, capture=True, env=aws_env(), **kw)


def tf(*args: str, **kw):
    # The GitHub provider authenticates as you via your `gh` login; the token lives only in
    # this child's environment (never your shell, state, or a box).
    env = aws_env().copy()
    env["GITHUB_TOKEN"] = run("gh", "auth", "token", capture=True)
    return run("terraform", f"-chdir={TF_DIR}", *args, env=env, **kw)


def default_region() -> str | None:
    f = TF_DIR / "terraform.tfvars"
    m = f.exists() and re.search(r'^\s*region\s*=\s*"([^"]+)"', f.read_text(), re.MULTILINE)
    return m.group(1) if m else None


def project_file(name: str) -> Path:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        die(f"invalid project name {name!r} (lowercase letters, digits, hyphens)")
    return PROJECTS / f"{name}.json"


def load_project(name: str) -> dict:
    f = project_file(name)
    if not f.exists():
        die(f"{f.relative_to(ROOT)} not found")
    return json.loads(f.read_text())


def instance_ids(name: str) -> list[str]:
    load_project(name)
    out = aws(
        "ec2", "describe-instances",
        "--filters", f"Name=tag:Project,Values={name}", LIVE,
        "--query", "Reservations[].Instances[].InstanceId", "--output", "text",
    )  # fmt: skip
    return [i for i in out.split() if i != "None"]


def instance_id(name: str) -> str:
    ids = instance_ids(name)
    if not ids:
        die(f"no box found for project {name}")
    if len(ids) > 1:
        die(f"multiple instances for Project={name}: {' '.join(ids)}")
    return ids[0]


def state(iid: str) -> str:
    return aws(
        "ec2", "describe-instances", "--instance-ids", iid,
        "--query", "Reservations[0].Instances[0].State.Name", "--output", "text",
    )  # fmt: skip


def plan_violations(plan: dict, name: str, action: str) -> tuple[int, list[str]]:
    """Count this project's `action` changes; list every change outside it (or of another kind)."""
    mine = (f'module.devbox["{name}"]', f'module.github_project["{name}"]')
    n, bad = 0, []
    for rc in plan.get("resource_changes", []):
        addr, acts = rc["address"], rc["change"]["actions"]
        if acts in (["no-op"], ["read"]) or (addr.startswith(SHARED) and acts == ["create"]):
            continue
        if addr.startswith(mine) and acts == [action]:
            n += 1
        else:
            bad.append(f"{addr} {','.join(acts)}")
    return n, bad


def scoped_apply(name: str, action: str):
    """Plan, refuse anything beyond `action` on this project's resources, confirm, apply."""
    plan = "devbox.tfplan"
    try:
        tf("plan", f"-out={plan}")
        n, bad = plan_violations(json.loads(tf("show", "-json", plan, capture=True)), name, action)
        if bad:
            die(f"plan touches more than {name}'s {action}; aborting:\n  " + "\n  ".join(bad))
        if not n:
            die(f"plan has nothing to {action} for {name}")
        if input(f"Plan will {action} {n} resources for {name}. Apply? [y/N] ").lower() != "y":
            die("declined")
        tf("apply", plan)
    finally:
        (TF_DIR / plan).unlink(missing_ok=True)


def git_commit(path: Path, msg: str):
    rel = str(path.relative_to(ROOT))
    run("git", "add", "-A", "--", rel, cwd=ROOT)
    run("git", "commit", "-m", msg, "--", rel, cwd=ROOT)


def ssh(iid: str, remote_cmd: str | None = None, input=None, os_user: str = "admin") -> int:
    """SSH via the EC2 Instance Connect Endpoint with a throwaway key (valid 60s on the box).
    `aws ec2-instance-connect ssh` can't run a remote command, hence plain ssh + open-tunnel.
    Interactive (with a tty) when input is None; otherwise input is fed to remote_cmd's stdin."""
    with tempfile.TemporaryDirectory() as d:
        key = f"{d}/key"
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
        aws(
            "ec2-instance-connect", "send-ssh-public-key", "--instance-id", iid,
            "--instance-os-user", os_user, "--ssh-public-key", f"file://{key}.pub",
        )  # fmt: skip
        # ponytail: host key accepted per connection (tmp known_hosts); the IAM-authenticated
        # tunnel to the instance's private IP is the trust anchor. Pin keys if that ever matters.
        return run(
            "ssh", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=15",
            "-o", f"ProxyCommand=aws --region {REGION} ec2-instance-connect open-tunnel --instance-id %h",
            "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={d}/known_hosts",
            *(["-t"] if input is None else []), f"{os_user}@{iid}", *([remote_cmd] if remote_cmd else []),
            input=input, check=False, env=aws_env(),
        )  # fmt: skip


def connect(name: str) -> str:
    """Start the box if needed and wait until admin can SSH in (first boot creates admin)."""
    iid = instance_id(name)
    if state(iid) != "running":
        print(f"Starting {iid}...")
        aws("ec2", "start-instances", "--instance-ids", iid)
        aws("ec2", "wait", "instance-running", "--instance-ids", iid)
    print("Waiting for SSH...")
    for _ in range(18):
        if ssh(iid, "true", input="") == 0:
            return iid
        time.sleep(10)
    die(f"could not SSH to {iid} as admin after ~3 min (first boot still running bootstrap?)")


# --- commands


def cmd_ls(_):
    out = aws(
        "ec2", "describe-instances", "--filters", "Name=tag-key,Values=Project", LIVE,
        "--query", "Reservations[].Instances[].[Tags[?Key==`Project`]|[0].Value,State.Name]",
        "--output", "json",
    )  # fmt: skip
    states = dict(json.loads(out or "[]"))
    print(f"{'NAME':20} {'REPO':35} STATE")
    for f in sorted(PROJECTS.glob("*.json")):
        print(f"{f.stem:20} {json.loads(f.read_text())['repo']:35} {states.get(f.stem, 'none')}")


def cmd_add(a):
    f = project_file(a.name)
    if f.exists():
        die(f"{f.relative_to(ROOT)} already exists")
    if run("gh", "repo", "view", a.repo, "--json", "name", capture=True, check=False) == "":
        die(f"GitHub repo {a.repo} not found")
    data = {"repo": a.repo}
    if a.type:
        data["instance_type"] = a.type
    if a.data_gb:
        data["data_gb"] = a.data_gb
    f.write_text(json.dumps(data, indent=2) + "\n")
    done = False
    try:
        scoped_apply(a.name, "create")
        done = True
    finally:
        if not done:
            f.unlink()
            print(f"removed {f.relative_to(ROOT)}", file=sys.stderr)
    git_commit(f, f"Add project {a.name}")
    print(f"Next: devbox secrets {a.name}, then devbox open {a.name}")


def cmd_init_project(a):
    """New dir: render the template, commit, create the private GitHub repo and push.
    Existing git repo: render the template into it and leave the diff for you to review."""
    project_file(a.name)  # same name rules as the template and `devbox add`
    src = run("gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner", capture=True, cwd=ROOT)
    owner, devbox_repo = src.split("/")
    dest = Path(a.path or a.name).resolve()
    existing = (dest / ".git").exists()
    if dest.exists() and not existing and any(dest.iterdir()):
        die(f"{dest} is not empty and not a git repo")
    run(
        "uvx", "copier", "copy", f"gh:{src}", str(dest), "-d", f"project_name={a.name}",
        "-d", f"github_owner={owner}", "-d", f"devbox_repo={devbox_repo}",
    )  # fmt: skip
    if existing:
        repo = run("gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner",
                   capture=True, check=False, cwd=dest) or f"{owner}/<repo>"  # fmt: skip
        print(f"Template applied to {dest}. Review `git diff`, then commit and push.")
    else:
        repo = f"{owner}/{a.name}"
        run("git", "init", "-q", cwd=dest)
        run("git", "add", "-A", cwd=dest)
        run("git", "commit", "-qm", "Init from devbox template", cwd=dest)
        run("gh", "repo", "create", repo, "--private", "--source", ".", "--push", cwd=dest)
    print(f"Next: devbox add {a.name} {repo}")


def cmd_auth(_):
    aws_env()  # MFA prompt if the cached session expired
    print(aws("sts", "get-caller-identity", "--output", "table"))


def cmd_tf(a):
    """Terraform in infra/terraform with the deployer credentials and your gh login (Terraform can't prompt for MFA)."""
    sys.exit(tf(*a.args, check=False))


def cmd_open(a):
    iid = connect(a.name)
    print("First time? Run `claude auth login` (claude.ai login, NOT setup-token).")
    sys.exit(ssh(iid, SESSION_CMD))


def cmd_start(a):
    iid = instance_id(a.name)
    print(f"Starting {iid}")
    aws("ec2", "start-instances", "--instance-ids", iid)


def cmd_stop(a):
    iid = instance_id(a.name)
    print(f"Stopping {iid}")
    aws("ec2", "stop-instances", "--instance-ids", iid)


def cmd_status(a):
    iid = instance_id(a.name)
    print(iid, state(iid))


def cmd_secrets(a):
    """Values go only through subprocess stdin: never argv, disk, shell history or Terraform."""
    repo = load_project(a.name)["repo"]
    print("Empty input skips a secret. Input is hidden.")
    if tok := getpass.getpass("Agent machine-user token (-> box /etc/devbox/github_token): "):
        iid = connect(a.name)
        cmd = (
            "sudo install -D -o root -g root -m 0600 /dev/stdin /etc/devbox/github_token"
            " && sudo systemctl restart setup-boot.service"
        )
        if ssh(iid, cmd, input=tok):
            die("failed to store the token on the box")
        print("  stored on the box and re-ran setup (git credentials, clone)")
    for s in ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"):
        if val := getpass.getpass(f"{s} (-> {repo} env modal): "):
            run("gh", "secret", "set", s, "--env", "modal", "--repo", repo, input=val)
    print("W&B (if used) is a Modal secret, never a GitHub one. With the Modal CLI on the")
    print("dedicated workspace, run once:  modal secret create wandb WANDB_API_KEY=<key>")


def cmd_sync(a):
    """Push infra/scripts/* to /opt/devbox/scripts (root-owned) and re-run bootstrap."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for f in sorted(SCRIPTS.iterdir()):
            ti = t.gettarinfo(f, f.name)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mode = 0o755 if f.suffix == ".sh" else 0o644
            with f.open("rb") as fh:
                t.addfile(ti, fh)
    iid = connect(a.name)
    cmd = "sudo tar -x -C /opt/devbox/scripts && sudo systemctl restart setup-boot.service"
    if ssh(iid, cmd, input=buf.getvalue()):
        die("sync failed")
    print(f"Synced {SCRIPTS.relative_to(ROOT)} to {iid} and re-ran bootstrap")


def cmd_retire(a):
    f = project_file(a.name)
    load_project(a.name)
    content = f.read_text()
    print(
        f"This DESTROYS the box, data volume, GitHub modal environment, branch protection and agent\n"
        f"collaborator access for {a.name!r}. The GitHub repo is untouched; a final data-volume snapshot is kept."
    )
    if input("Type the project name to confirm: ") != a.name:
        die("confirmation mismatch")

    ids = instance_ids(a.name)  # stop first so the data volume detaches cleanly
    if len(ids) > 1:
        die(f"multiple instances for Project={a.name}: {' '.join(ids)}")
    if ids:
        print(f"Stopping {ids[0]}...")
        aws("ec2", "stop-instances", "--instance-ids", ids[0])
        aws("ec2", "wait", "instance-stopped", "--instance-ids", ids[0])

    outputs = tf("output", "-json", "projects", capture=True, check=False) or "{}"
    volid = json.loads(outputs).get(a.name, {}).get("data_volume_id")
    f.unlink()
    done = False
    try:
        scoped_apply(a.name, "delete")
        done = True
    finally:
        if not done:
            f.write_text(content)
            print(f"restored {f.relative_to(ROOT)}", file=sys.stderr)

    # final_snapshot=true leaves a snapshot; it can take a moment to appear.
    snaps = ""
    for _ in range(10 if volid else 0):
        snaps = aws(
            "ec2", "describe-snapshots", "--owner-ids", "self",
            "--filters", f"Name=volume-id,Values={volid}",
            "--query", "Snapshots[].SnapshotId", "--output", "text",
        )  # fmt: skip
        if snaps:
            break
        time.sleep(10)
    if snaps:
        print(f"Final snapshot(s) of {volid}: {snaps}")
        print(
            f"Delete later: aws ec2 delete-snapshot --profile {PROFILE} --snapshot-id <id> --region {REGION}"
        )
    else:
        print(f"warning: no final snapshot found yet for volume {volid or '(unknown)'}", file=sys.stderr)

    git_commit(f, f"Retire project {a.name}")
    print(f"Reminder: revoke the agent machine-user token you stored for {a.name}.")


def main():
    global REGION
    p = argparse.ArgumentParser(prog="devbox", description=__doc__)
    p.add_argument("--region", default=default_region(), help="default: region in terraform.tfvars")
    sub = p.add_subparsers(dest="cmd", required=True, metavar="COMMAND")

    def cmd(name, fn, help, with_name=True):
        sp = sub.add_parser(name, help=help, description=help)
        if with_name:
            sp.add_argument("name", help="project name")
        sp.set_defaults(fn=fn)
        return sp

    cmd(
        "auth", cmd_auth, f"get deployer credentials (profile {PROFILE}, MFA); show identity", with_name=False
    )
    tfp = cmd(
        "tf",
        cmd_tf,
        "run terraform in infra/terraform as the deployer, e.g. `devbox tf plan`",
        with_name=False,
    )
    tfp.add_argument("args", nargs=argparse.REMAINDER, help="terraform arguments")
    cmd("ls", cmd_ls, "list projects with repo and box state", with_name=False)
    init = cmd(
        "init-project",
        cmd_init_project,
        "create a project repo from the template (or apply it to an existing repo)",
    )
    init.add_argument(
        "--path", help="target dir (default: ./NAME); an existing git repo gets the template applied"
    )
    add = cmd("add", cmd_add, "add a project: write its JSON, apply (scoped), commit")
    add.add_argument("repo", help="GitHub repo, owner/name (must exist)")
    add.add_argument("--type", help="instance type (default from tfvars)")
    add.add_argument("--data-gb", type=int, help="data volume size (default from tfvars)")
    cmd("open", cmd_open, "start the box if needed and open a shell as ubuntu (exit -> admin)")
    cmd("start", cmd_start, "start the box")
    cmd("stop", cmd_stop, "stop the box")
    cmd("status", cmd_status, "show the box state")
    cmd("secrets", cmd_secrets, "set agent token (on the box) and Modal token (GitHub env), hidden input")
    cmd("sync", cmd_sync, "push infra/scripts to the box and re-run its bootstrap")
    cmd("retire", cmd_retire, "destroy a project's resources (scoped), keep final snapshot and repo")

    a = p.parse_args()
    if not a.region:
        die("no region: set `region` in infra/terraform/terraform.tfvars or pass --region")
    REGION = a.region
    try:
        a.fn(a)
    except KeyboardInterrupt:
        sys.exit(130)
