from devbox.cli import plan_violations


def rc(addr, *actions):
    return {"address": addr, "change": {"actions": list(actions)}}


def test_scoped_plan_check():
    plan = {
        "resource_changes": [
            rc('module.devbox["a"].aws_instance.this', "delete"),
            rc('module.github_project["a"].github_branch_protection.default', "delete"),
            rc('module.devbox["a"].data.aws_ami.ubuntu', "read"),
            rc('aws_s3_object.scripts["bootstrap.sh"]', "update"),
            rc('module.devbox["b"].aws_instance.this', "no-op"),
        ]
    }
    assert plan_violations(plan, "a", "delete") == (2, [])
    # Prefix lookalike, other projects, and replace/other actions are all violations.
    plan["resource_changes"] += [
        rc('module.devbox["ab"].aws_instance.this', "delete"),
        rc('module.devbox["b"].aws_instance.this', "update"),
        rc('module.devbox["a"].aws_ebs_volume.data', "delete", "create"),
    ]
    n, bad = plan_violations(plan, "a", "delete")
    assert n == 2 and len(bad) == 3
