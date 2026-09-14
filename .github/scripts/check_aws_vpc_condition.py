#!/usr/bin/env python3
"""Fail the build if an AWS statement bounds an action by an `ec2:Vpc` key it never carries.

An IAM condition on a key the request does not carry is FALSE, not skipped. AWS's condition-operator
reference says so in as many words: "If the key that you specify in a policy condition is not
present in the request context, the values do not match and the condition is false." So a statement
bounding its writes with `ec2:Vpc` refuses every action in it for which the service reference lists
no such key. It lints clean, deploys clean, reads as "bounded to your VPC" in review, and denies at
runtime -- in a customer's account, where we cannot see it and cannot re-apply the fix.

Which actions never carry `ec2:Vpc` is not a judgement call. AWS publishes, per action, the resource
types it is authorized against and the condition keys each of those supports:

    https://servicereference.us-east-1.amazonaws.com/v1/ec2/ec2.json

An action is in NO_VPC_KEY below when its own listing gives `ec2:Vpc` for NONE of its resource
types: every Describe read, the Elastic IP allocation, the instance lifecycle, and every create,
whose listing gives the key on neither the new object nor the VPC. It is in VPC_KEY when at least
one of its resource types carries the key in that listing. Two rules, on both AWS routes:

  * a statement that names `ec2:Vpc` grants no action from NO_VPC_KEY;
  * every EC2 action either route grants is in exactly one of the two sets. A new action fails the
    build until someone looks it up in that file and places it, which is the moment the trap is
    cheap to avoid.

What this does NOT prove is that an action in VPC_KEY is satisfied: an action authorized against
several resource types may carry the key on some and not on others. Those are the reviewer's, with
the same file in hand.

Run it:   python3 .github/scripts/check_aws_vpc_condition.py
Test it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from check_route_parity import (
    AWS_CFN,
    AWS_TF,
    SID_RE,
    aws_cloudformation_statements,
    aws_terraform_statements,
)
from check_trust_pins import GuardError, brace_block, strip_hcl_comments, strip_yaml_comments

REPO_ROOT = Path(__file__).resolve().parents[2]
PATHS = (AWS_TF, AWS_CFN)
KEY = "ec2:Vpc"

# Each action's own listing in the service reference gives `ec2:Vpc` for none of its resource types,
# so a condition on it can never match them. Read from that file, not inferred.
NO_VPC_KEY = frozenset({
    "AllocateAddress", "CreateRouteTable", "CreateSecurityGroup", "CreateSubnet", "DeleteTags",
    "DescribeAddresses", "DescribeAvailabilityZones", "DescribeImages", "DescribeInstanceAttribute",
    "DescribeInstanceStatus", "DescribeInstanceTypes", "DescribeInstances",
    "DescribeNetworkInterfaces", "DescribeRouteTables", "DescribeSecurityGroupRules",
    "DescribeSecurityGroups", "DescribeSubnets", "DescribeTags", "DescribeVolumes",
    "DescribeVolumesModifications", "DescribeVpcs", "ModifyVolume", "ReleaseAddress", "StartInstances",
    "StopInstances", "TerminateInstances",
})

# Each action's own listing gives `ec2:Vpc` for at least one of its resource types.
VPC_KEY = frozenset({
    "AssociateAddress", "AssociateRouteTable", "AuthorizeSecurityGroupEgress",
    "AuthorizeSecurityGroupIngress", "CreateRoute", "CreateTags", "DeleteRoute", "DeleteRouteTable",
    "DeleteSecurityGroup", "DeleteSubnet", "DisassociateAddress", "DisassociateRouteTable",
    "ModifyInstanceAttribute", "ModifyNetworkInterfaceAttribute", "ReplaceRoute",
    "RevokeSecurityGroupEgress", "RevokeSecurityGroupIngress", "RunInstances",
    "UpdateSecurityGroupRuleDescriptionsIngress",
})

assert not NO_VPC_KEY & VPC_KEY, f"classified both ways: {sorted(NO_VPC_KEY & VPC_KEY)}"


def terraform_statement_bodies(source: str, path: str) -> dict[str, str]:
    """Every statement in the permissions document, as sid -> the text from its sid to the next."""
    src = strip_hcl_comments(source)
    m = re.search(r'data\s+"aws_iam_policy_document"\s+"permissions"\s*\{', src)
    if m is None:
        raise GuardError(
            f"{path}: no `data \"aws_iam_policy_document\" \"permissions\"` block.\n\n"
            "  That document IS the role's permissions policy. If it was renamed or split, move this\n"
            "  guard with it rather than leaving it reading nothing."
        )
    body = brace_block(src[m.end() - 1 :], "the permissions policy document")
    starts = list(re.finditer(r'^[ \t]*sid[ \t]*=[ \t]*"([^"]+)"', body, re.M))
    if not starts:
        raise GuardError(f"{path}: the permissions document declares no `sid`s.")
    # A statement's conditions follow its sid and precede the next statement's, so the span between
    # two sids holds exactly one statement's conditions.
    return {
        sm.group(1): body[sm.end() : starts[i + 1].start() if i + 1 < len(starts) else len(body)]
        for i, sm in enumerate(starts)
    }


def cloudformation_statement_bodies(source: str, path: str) -> dict[str, str]:
    """Every IAM statement in the template, as sid -> its mapping's text.

    The same indent walk `check_route_parity.aws_cloudformation_statements` uses, for the same reason:
    the template's short tags do not load without a constructor for each.
    """
    lines = [line for line in strip_yaml_comments(source).split("\n") if line.strip()]
    out: dict[str, str] = {}
    for i, line in enumerate(lines):
        m = SID_RE.match(line)
        if m is None:
            continue
        col = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
        chunk = []
        for cur in lines[i + 1 :]:
            indent = len(cur) - len(cur.lstrip(" "))
            if indent < col or (indent == col and cur.lstrip().startswith("-")):
                break
            chunk.append(cur)
        out[m.group(3)] = "\n".join(chunk)
    if not out:
        raise GuardError(f"{path}: no `Sid:` lines at all, so this guard is reading nothing.")
    return out


def check_route(path: str, actions: dict[str, list[str]], bodies: dict[str, str]) -> list[str]:
    if set(actions) != set(bodies):
        raise GuardError(
            f"{path}: the statement readers disagree on which statements exist "
            f"({sorted(set(actions) ^ set(bodies))}). One of them no longer matches the file."
        )
    # Quoted, so a longer key that merely starts with this one (`ec2:VpcID`) is not mistaken for it.
    bound = sorted(sid for sid, body in bodies.items() if f'"{KEY}"' in body)
    if not bound:
        raise GuardError(
            f"{path}: no statement names `{KEY}`.\n\n"
            "  Either the VPC bound was removed on purpose -- then delete this guard deliberately -- or\n"
            "  the statements were restructured and this guard now reads nothing."
        )

    failures = []
    for sid in sorted(actions):
        for action in actions[sid]:
            if not action.startswith("ec2:"):
                continue
            name = action[len("ec2:") :]
            if name not in NO_VPC_KEY and name not in VPC_KEY:
                failures.append(
                    f"{path}: statement `{sid}` grants `{action}`, which this guard has not classified.\n\n"
                    "  Look it up in https://servicereference.us-east-1.amazonaws.com/v1/ec2/ec2.json. If\n"
                    f"  none of the resource types under its `Resources` lists `{KEY}`, add it to\n"
                    "  NO_VPC_KEY and keep it out of every statement conditioned on that key; otherwise add\n"
                    "  it to VPC_KEY."
                )
    for sid in bound:
        never = sorted(a for a in actions[sid] if a.startswith("ec2:") and a[len("ec2:") :] in NO_VPC_KEY)
        if never:
            failures.append(
                f"{path}: statement `{sid}` is conditioned on `{KEY}` and grants {never}, which the service reference never\n"
                f"  lists that key for, on any resource it is authorized against.\n\n"
                "  A condition on a key missing from the request is false, so these actions are refused\n"
                "  on every call while the policy reads as bounded to the VPC. Move them to a statement\n"
                "  without the condition, and bound them another way: a create by naming the VPC in\n"
                "  `Resource`, a read or an Elastic IP action by region."
            )
    return failures


def check_all(srcs: dict[str, str]) -> list[str]:
    failures: list[str] = []
    for path, read_actions, read_bodies in (
        (AWS_TF, aws_terraform_statements, terraform_statement_bodies),
        (AWS_CFN, aws_cloudformation_statements, cloudformation_statement_bodies),
    ):
        try:
            failures += check_route(path, read_actions(srcs[path], path), read_bodies(srcs[path], path))
        except GuardError as err:
            failures.append(str(err))
    return failures


def main(root: Path = REPO_ROOT) -> int:
    srcs = {path: (root / path).read_text(encoding="utf-8") for path in PATHS}
    failures = check_all(srcs)
    if failures:
        print("An AWS statement bounds an action by a key that action never carries:\n", file=sys.stderr)
        for f in failures:
            print(f"  * {f}\n", file=sys.stderr)
        return 1
    print(f"No `{KEY}` condition bounds an action that never carries it, on {len(PATHS)} AWS routes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
