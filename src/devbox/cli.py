"""devbox: manage per-project Claude Code dev boxes (wraps terraform, aws and gh)."""

import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # needs an editable install (`uv tool install -e .`)
PROJECTS = ROOT / "infra" / "projects"
TF_DIR = ROOT / "infra" / "terraform"
LIVE = "Name=instance-state-name,Values=pending,running,stopping,stopped"
# Shell as ubuntu (no sudo); `exit` drops to ssm-user (has sudo) for admin. SSM runs this via sh -c.
SESSION_CMD = 'sudo -iu ubuntu; echo "now ssm-user (sudo available); exit again to end"; exec bash -l'
# Shared, project-independent resources a scoped plan may also touch.
SHARED = ("aws_s3_object.scripts",)
REGION = "ap-southeast-2"  # overwritten in main()


def die(msg: str):
    sys.exit(f"error: {msg}")


def run(*cmd: str, capture=False, input=None, check=True, cwd=None, env=None):
    """Run cmd; stderr always goes to the terminal. Returns stdout (capture) or the exit code."""
    try:
        r = subprocess.run(
            cmd,
            text=True,
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


def aws(*args: str, **kw):
    return run("aws", "--region", REGION, *args, capture=True, **kw)


def tf(*args: str, **kw):
    # The GitHub provider authenticates as you via your `gh` login; the token lives only in
    # this child's environment (never your shell, state, or a box).
    env = os.environ.copy()
    env.setdefault("GITHUB_TOKEN", run("gh", "auth", "token", capture=True))
    return run("terraform", f"-chdir={TF_DIR}", *args, env=env, **kw)


def default_region() -> str:
    f = TF_DIR / "terraform.tfvars"
    m = f.exists() and re.search(r'^\s*region\s*=\s*"([^"]+)"', f.read_text(), re.MULTILINE)
    return m.group(1) if m else REGION


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
        if acts in (["no-op"], ["read"]) or addr.startswith(SHARED):
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


def session(iid: str) -> int:
    return run(
        "aws", "ssm", "start-session", "--region", REGION, "--target", iid,
        "--document-name", "AWS-StartInteractiveCommand",
        "--parameters", json.dumps({"command": [SESSION_CMD]}),
        check=False,
    )  # fmt: skip


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


def cmd_open(a):
    iid = instance_id(a.name)
    if state(iid) != "running":
        print(f"Starting {iid}...")
        aws("ec2", "start-instances", "--instance-ids", iid)
        aws("ec2", "wait", "instance-running", "--instance-ids", iid)
    print("Waiting for SSM agent...")
    for _ in range(60):
        s = aws(
            "ssm", "describe-instance-information",
            "--filters", f"Key=InstanceIds,Values={iid}",
            "--query", "InstanceInformationList[0].PingStatus", "--output", "text",
            check=False,
        )  # fmt: skip
        if s == "Online":
            break
        time.sleep(5)
    else:
        die(f"SSM agent on {iid} not online after 5 min")
    print("First time? Run `claude auth login` (claude.ai login, NOT setup-token).")
    sys.exit(session(iid))


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
    param = f"/devbox/{a.name}/github_token"
    print("Empty input skips a secret. Input is hidden.")
    if tok := getpass.getpass(f"Agent machine-user token (-> SSM {param}): "):
        payload = {"Name": param, "Value": tok, "Type": "SecureString", "Overwrite": True}
        aws("ssm", "put-parameter", "--cli-input-json", "file:///dev/stdin", input=json.dumps(payload))
        print(f"  set SSM {param} (reboot the box to pick it up)")
    for s in ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"):
        if val := getpass.getpass(f"{s} (-> {repo} env modal): "):
            run("gh", "secret", "set", s, "--env", "modal", "--repo", repo, input=val)
    print("W&B (if used) is a Modal secret, never a GitHub one. With the Modal CLI on the")
    print("dedicated workspace, run once:  modal secret create wandb WANDB_API_KEY=<key>")


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
        print(f"Delete later: aws ec2 delete-snapshot --region {REGION} --snapshot-id <id>")
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

    cmd("ls", cmd_ls, "list projects with repo and box state", with_name=False)
    add = cmd("add", cmd_add, "add a project: write its JSON, apply (scoped), commit")
    add.add_argument("repo", help="GitHub repo, owner/name (must exist)")
    add.add_argument("--type", help="instance type (default from tfvars)")
    add.add_argument("--data-gb", type=int, help="data volume size (default from tfvars)")
    cmd("open", cmd_open, "start the box if needed and open a shell as ubuntu")
    cmd("start", cmd_start, "start the box")
    cmd("stop", cmd_stop, "stop the box")
    cmd("status", cmd_status, "show the box state")
    cmd("secrets", cmd_secrets, "set agent token (SSM) and Modal token (GitHub env), hidden input")
    cmd("retire", cmd_retire, "destroy a project's resources (scoped), keep final snapshot and repo")

    a = p.parse_args()
    REGION = a.region
    try:
        a.fn(a)
    except KeyboardInterrupt:
        sys.exit(130)
