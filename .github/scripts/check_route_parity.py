#!/usr/bin/env python3
"""Fail the build if the two supported paths for one cloud grant different things.

Every cloud here has TWO paths a customer may follow -- Terraform or a template/script -- and a
customer is on one or the other, never both. Nothing about that is visible in a diff: a change
that adds a permission to `gcp/terraform/main.tf` and forgets `gcp/gcloud/onboard.sh` reviews
cleanly, deploys cleanly on both, and ships **two different landing pads under one name**.

The failure it causes is the expensive kind. It is not found at apply time, because both paths
apply. It is found later, by the customer who happened to take the other route, when the feature
the grant was for fails with a `403` -- and by then the pad is applied in an account we hold no
credentials for, so the fix is asking that customer to re-apply. That is the cost this whole
repository exists to avoid, and forgetting one route is the cheapest possible way to pay it.

So parity is a TEST rather than a habit. Three checks, one per cloud, each shaped by how that
cloud's two paths are actually kept in step:

  * **gcp** -- two INDEPENDENT implementations (Terraform and `gcloud`), so every custom role's
    permission set is compared, name by name. This is the one that has actually drifted.
  * **aws** -- two independent implementations (Terraform and CloudFormation), so every IAM
    statement's action set is compared, keyed by its `Sid`. A statement present on one path and
    absent on the other is the failure, and it is reported as such rather than as a difference in
    some list.
  * **azure** -- ONE implementation: the Terraform module deploys `../arm/azuredeploy.json`
    verbatim, so the action list cannot drift. That property is what is checked -- that the
    module still deploys that file, and still passes every parameter the template declares. An
    unpassed parameter with a default is its own quiet failure: Azure materializes the default
    into the stored deployment while the file leaves it unset, and `terraform plan` then reports
    a change forever.

What this guard does NOT compare is resource bounds -- an ARN pattern, an IAM condition, a
`--condition` flag. Those are written in three different languages that cannot be compared as
text, and a guard that pretended otherwise would be reporting on its own parser. What it
guarantees is that the two paths grant THE SAME ACTIONS; the bounds are the reviewer's job and
the module tests'.

Every reader fails LOUDLY when its anchor is gone, the standing rule for the guards here: a
guard that has quietly stopped reading anything passes every build until the day it matters.

Run it:   python3 .github/scripts/check_route_parity.py
Test it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from check_trust_pins import (
    GuardError,
    brace_block,
    hcl_resources,
    shell_assignments,
    shell_commands,
    strip_hcl_comments,
    strip_shell_comments,
    strip_yaml_comments,
)

REPO_ROOT = Path(__file__).resolve().parents[2]

GCP_TF = "gcp/terraform/main.tf"
GCP_SH = "gcp/gcloud/onboard.sh"
AWS_TF = "aws/terraform/main.tf"
AWS_CFN = "aws/cloudformation/ringleader-onboarding.yaml"
AZURE_TF = "azure/terraform/main.tf"
AZURE_ARM = "azure/arm/azuredeploy.json"

# Every artifact this guard reads, so a test can hand it edited sources rather than editing the
# repository -- the same shape check_published_literals.py uses, and for the same reason: a guard
# whose teeth can only be proved by breaking the working tree does not get its teeth proved.
PATHS = (GCP_TF, GCP_SH, AWS_TF, AWS_CFN, AZURE_TF, AZURE_ARM)

# The shell names this guard reads. Handed to `check_trust_pins`' closed grammar so a statement
# that binds one of them by any means other than a plain assignment -- `read`, `printf -v`,
# `eval`, a `for` variable -- is refused rather than silently unseen. Without this a
# `printf -v EGRESS_PERMS ...` would leave the guard comparing an assignment that never runs.
GUARDED_SHELL_VARS = frozenset({
    "EGRESS_PERMS",
    "IDENTITY_PERMS",
    "STORAGE_PERMS",
    "STORAGE_MANAGED_PERMS",
    "STORAGE_PROVISION_PERMS",
    "STORAGE_ROLE_PERMS",
})


# --------------------------------------------------------------------------------------
# Readers
# --------------------------------------------------------------------------------------


def _unquote(value: str) -> str:
    v = value.strip().rstrip(",").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def hcl_string_list(expr: str, path: str, what: str) -> list[str]:
    """Every string in a `[ ... ]` literal, one line per entry or all on one.

    `check_trust_pins.hcl_list_items` deliberately refuses a multi-line list, because the pins it
    reads are single-line by rule. A permission list is not: these are twenty entries with a
    paragraph of reasoning between them, and reflowing one to satisfy a guard would be the guard
    deciding how the artifact is written.
    """
    e = expr.strip()
    if not e.startswith("["):
        raise GuardError(
            f"{path}: {what} is `{e.splitlines()[0]}`, which this guard cannot read as a list.\n\n"
            "  It reads a `[...]` literal, a bare `local.<name>`, or a `concat(...)` of those. A\n"
            "  fourth shape means the two routes are no longer comparable, and an uncompared route\n"
            "  is how one of them silently loses a grant."
        )
    depth, end = 0, -1
    for i, ch in enumerate(e):
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end < 0:
        raise GuardError(f"{path}: {what} opens a list that never closes.")
    inner = e[1:end]
    return [_unquote(item) for item in inner.split(",") if item.strip()]


def split_ternary(expr: str) -> tuple[str, str] | None:
    """The two branches of a top-level `cond ? a : b`, or None if there is no top-level `?`.

    Both branches are resolved and UNIONED by the caller, never chosen between. A guard that
    picked one would report on the width the customer may not have taken; the union is "everything
    this role can ever grant", which is exactly what the shell path's own two-branch assembly
    produces, so the two sides stay comparable without either guessing.
    """
    depth, quoted = 0, False
    q = -1
    for i, ch in enumerate(expr):
        if ch == '"' and (i == 0 or expr[i - 1] != "\\"):
            quoted = not quoted
        elif quoted:
            continue
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "?" and depth == 0 and q < 0:
            q = i
        elif ch == ":" and depth == 0 and q >= 0:
            return expr[q + 1 : i], expr[i + 1 :]
    return None


def hcl_actions(expr: str, locals_: dict[str, str], path: str, what: str) -> list[str]:
    """Resolve an action/permission expression to the strings it names.

    Handles the shapes these modules use and refuses everything else: a `[...]` literal, a
    `local.<name>` reference, a `concat(...)` of those, and a `cond ? a : b` -- which resolves to
    the UNION of its branches, never to one of them.
    """
    e = expr.strip()
    branches = split_ternary(e)
    if branches is not None:
        out: list[str] = []
        for branch in branches:
            out += hcl_actions(branch, locals_, path, what)
        return out
    if e.startswith("concat("):
        depth, parts, start = 0, [], len("concat(")
        for i in range(start - 1, len(e)):
            ch = e[i]
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
                if depth == 0:
                    parts.append(e[start:i])
                    break
            elif ch == "," and depth == 1:
                parts.append(e[start:i])
                start = i + 1
        else:
            raise GuardError(f"{path}: {what} opens a concat( that never closes.")
        out: list[str] = []
        for part in parts:
            if part.strip():
                out += hcl_actions(part, locals_, path, what)
        return out
    if e.startswith("local."):
        name = re.match(r"local\.([A-Za-z0-9_]+)", e).group(1)
        if name not in locals_:
            raise GuardError(
                f"{path}: {what} names `local.{name}`, which is in no `locals` block.\n\n"
                "  It was renamed or moved. Either way this guard is now comparing nothing, while\n"
                "  the two routes are free to drift."
            )
        return hcl_actions(locals_[name], locals_, path, what)
    return hcl_string_list(e, path, what)


def balanced_expr(text: str) -> str:
    """The expression starting at text[0]: to the end of its outermost bracket, or its line.

    Quote-aware and bracket-generic, because these expressions mix both: a permission list is
    `[...]`, an assembled one is `concat(local.a, [...])`, and a plain reference is neither. A
    scanner that counted only one kind of bracket would stop inside the other, and one that
    stopped at the first newline would read `concat(` and report a list that never closes -- both
    are a reader returning half an expression and then reporting the difference as the file's.
    """
    depth, quoted = 0, False
    for i, ch in enumerate(text):
        if ch == '"' and (i == 0 or text[i - 1] != "\\"):
            quoted = not quoted
        elif quoted:
            continue
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return text[: i + 1]
        elif ch == "\n" and depth == 0:
            return text[:i].strip()
    return text


def hcl_attr_multiline(body: str, name: str) -> str | None:
    """`name = <value>` where the value may span lines -- a list, a concat, a reference."""
    m = re.search(r"^[ \t]*" + re.escape(name) + r"[ \t]*=[ \t]*(?=\S)", body, re.M)
    if m is None:
        return None
    return balanced_expr(body[m.end() :])


LOCAL_NAME_RE = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=[ \t]*(?=\S)", re.M)


def hcl_locals_multiline(src: str) -> dict[str, str]:
    """Every assignment in every `locals` block, values allowed to span lines.

    `check_trust_pins.hcl_locals` is deliberately single-line -- a pin it cannot parse must become
    an unresolvable reference rather than a guess. The lists here are multi-line by nature, so
    this reads them properly instead; the same loud-on-missing rule still applies, one level up in
    `hcl_actions`.
    """
    out: dict[str, str] = {}
    rest = src
    while (m := re.search(r"^locals\s*\{", rest, re.M)) is not None:
        body = brace_block(rest[m.end() - 1 :], "a locals block")
        for am in LOCAL_NAME_RE.finditer(body):
            out.setdefault(am.group(1), balanced_expr(body[am.end() :]))
        rest = rest[m.end() - 1 + len(body) :]
    return out


def gcp_terraform_roles(source: str, path: str) -> dict[str, tuple[list[str] | None, str]]:
    """Every `google_project_iam_custom_role`, as name -> (permissions or None, raw expression).

    A role whose `permissions` this guard cannot resolve to a flat set yields None rather than a
    failure, and the raw expression beside it. That is not leniency: one role here assembles its
    permissions with a CONDITIONAL, because the two artifact-storage widths grant different
    things, and resolving a ternary would mean the guard picking a branch and comparing a grant
    the customer may not be getting. Such a role is compared through its `locals` instead, plus a
    check that it is still BUILT from them -- and a caller that asks for a role it cannot read
    still fails, in `check_gcp`.
    """
    src = strip_hcl_comments(source)
    locals_ = hcl_locals_multiline(src)
    found = hcl_resources(src, "google_project_iam_custom_role")
    if not found:
        raise GuardError(
            f"{path}: no `google_project_iam_custom_role` resources at all.\n\n"
            "  Every optional GCP grant is a custom role. None means they were renamed or replaced\n"
            "  with predefined roles, and this guard is reading nothing."
        )
    out: dict[str, tuple[list[str] | None, str]] = {}
    for name, body in found:
        expr = hcl_attr_multiline(body, "permissions")
        if expr is None:
            raise GuardError(f"{path}: `google_project_iam_custom_role.{name}` has no `permissions`.")
        try:
            out[name] = (hcl_actions(expr, locals_, path, f"{name}.permissions"), expr)
        except GuardError:
            out[name] = (None, expr)
    return out


def gcp_terraform_locals(source: str, path: str, name: str) -> list[str]:
    src = strip_hcl_comments(source)
    locals_ = hcl_locals_multiline(src)
    return hcl_actions(f"local.{name}", locals_, path, f"local.{name}")


SH_REF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")


def shell_comma_list(source: str, path: str, name: str, seen: frozenset[str] = frozenset()) -> list[str]:
    """Every permission a `NAME="a,b,c"` variable can hold, across ALL of its assignments.

    A variable assigned more than once is the shell's way of writing the ternary the Terraform side
    writes -- `STORAGE_ROLE_PERMS` is the base list, and the managed branch reassigns it to the base
    plus the extras. Taking the UNION mirrors how `hcl_actions` resolves that ternary, so the two
    sides are compared on "everything this role can ever grant" and neither guesses a width.

    References to other guarded variables are expanded; a reference to anything else is refused,
    because a value assembled out of something this guard cannot see is a value it is not checking.
    """
    src = strip_shell_comments(source)
    assigned = [v for n, v in shell_assignments(src, path, GUARDED_SHELL_VARS) if n == name]
    if not assigned:
        raise GuardError(
            f"{path}: found no assignment to `{name}`.\n\n"
            "  It was renamed, and this guard is now reading nothing -- which is exactly when the two\n"
            "  GCP routes are free to drift apart unnoticed."
        )
    out: list[str] = []
    for raw in assigned:
        for part in _unquote(raw).split(","):
            part = part.strip()
            if not part:
                continue
            ref = SH_REF_RE.fullmatch(part)
            if ref is None:
                if "$" in part:
                    raise GuardError(
                        f"{path}: `{name}` is assembled from `{part}`, which this guard cannot read.\n\n"
                        "  Every element must be a literal permission or a whole reference to another\n"
                        "  guarded variable. Anything else is a grant assembled out of something no\n"
                        "  reader here can see, which is the same as not comparing it at all."
                    )
                out.append(part)
                continue
            if ref.group(1) in seen | {name}:
                raise GuardError(
                    f"{path}: `{name}` is assembled from `${ref.group(1)}`, which leads back to it.\n\n"
                    "  A cycle among these variables has no value this guard can read, and at runtime\n"
                    "  the script would grant whatever the assignment order happens to leave behind.\n"
                    "  Write the permissions out rather than referring in a circle."
                )
            if ref.group(1) not in GUARDED_SHELL_VARS:
                raise GuardError(
                    f"{path}: `{name}` is assembled from `${ref.group(1)}`, which is not a guarded\n"
                    "  variable -- so nothing holds it to the closed grammar and nothing compares it.\n"
                    "  Add it to GUARDED_SHELL_VARS, or write the permissions out here."
                )
            out += shell_comma_list(source, path, ref.group(1), seen | {name})
    return out


GCLOUD_ROLE_RE = re.compile(r"\bgcloud\s+iam\s+roles\s+(?:create|update)\s+(\S+)")
GCLOUD_PERMS_RE = re.compile(r"--permissions[=\s]+(\S+)")


def gcloud_role_permission_vars(source: str, path: str) -> dict[str, set[str]]:
    """Each `gcloud iam roles create|update` command, as its role argument -> `--permissions` vars.

    Reading the ASSIGNMENT is not enough, and this is the hole that closes it. `EGRESS_PERMS="..."`
    can be perfectly in step with Terraform while the command that runs is
    `--permissions "$EGRESS_PERMS,compute.instances.setMetadata"` -- an extra grant on one route
    that no comparison of assignments can see. So the flag's argument must be exactly one whole
    variable reference and nothing else, and it must be the variable this guard compares.
    """
    out: dict[str, set[str]] = {}
    for cmd in shell_commands(strip_shell_comments(source)):
        role = GCLOUD_ROLE_RE.search(cmd)
        if role is None:
            continue
        perms = GCLOUD_PERMS_RE.findall(cmd)
        if not perms:
            raise GuardError(
                f"{path}: `gcloud iam roles ...  {role.group(1)}` carries no `--permissions`.\n\n"
                "  Either the command was restructured or the permissions now arrive some other way.\n"
                "  Both leave this route's grant uncompared."
            )
        if len(perms) > 1:
            raise GuardError(
                f"{path}: `{role.group(1)}` is given `--permissions` {len(perms)} times.\n\n"
                "  gcloud honours the LAST one, so a reader that judged the first would be reading a\n"
                "  flag that does not decide anything -- which is how an extra grant reaches one route\n"
                "  with every comparison still agreeing. Pass the flag once."
            )
        value = _unquote(perms[0])
        ref = SH_REF_RE.fullmatch(value)
        if ref is None:
            raise GuardError(
                f"{path}: `{role.group(1)}`'s `--permissions` is `{value}`, not a single variable.\n\n"
                "  It must be exactly one whole `\"$VAR\"` and nothing else. A literal spliced in beside\n"
                "  the variable -- `\"$EGRESS_PERMS,compute.instances.setMetadata\"` -- grants something\n"
                "  on this route that the Terraform module does not, while every comparison of the\n"
                "  ASSIGNMENTS still agrees."
            )
        out.setdefault(_unquote(role.group(1)), set()).add(ref.group(1))
    if not out:
        raise GuardError(
            f"{path}: no `gcloud iam roles create|update` commands at all.\n\n"
            "  Every optional GCP grant is a custom role this script writes. None means the script was\n"
            "  restructured and this guard is reading nothing."
        )
    return out


# --- AWS ------------------------------------------------------------------------------


def aws_terraform_statements(source: str, path: str) -> dict[str, list[str]]:
    """Every statement in `data "aws_iam_policy_document" "permissions"`, as sid -> actions."""
    src = strip_hcl_comments(source)
    locals_ = hcl_locals_multiline(src)
    m = re.search(r'data\s+"aws_iam_policy_document"\s+"permissions"\s*\{', src)
    if m is None:
        raise GuardError(
            f"{path}: no `data \"aws_iam_policy_document\" \"permissions\"` block.\n\n"
            "  That document IS the role's permissions policy. If it was renamed or split, move this\n"
            "  guard with it rather than leaving it comparing nothing against CloudFormation."
        )
    body = brace_block(src[m.end() - 1 :], "the permissions policy document")
    out: dict[str, list[str]] = {}
    for sm in re.finditer(r'^[ \t]*sid[ \t]*=[ \t]*"([^"]+)"', body, re.M):
        sid = sm.group(1)
        # The statement's own body: from the sid to the end of the enclosing `content`/`statement`
        # block. Reading forward to the next `sid` is enough, and is robust to either wrapper.
        nxt = re.search(r'^[ \t]*sid[ \t]*=[ \t]*"', body[sm.end() :], re.M)
        chunk = body[sm.end() : sm.end() + (nxt.start() if nxt else len(body))]
        expr = hcl_attr_multiline(chunk, "actions")
        if expr is None:
            raise GuardError(f"{path}: statement `{sid}` carries no `actions`.")
        out[sid] = hcl_actions(expr, locals_, path, f"statement {sid}")
    if not out:
        raise GuardError(f"{path}: the permissions document declares no `sid`s.")
    return out


SID_RE = re.compile(r"^(\s*)(- )?Sid: (\S+)\s*$")


def aws_cloudformation_statements(source: str, path: str) -> dict[str, list[str]]:
    """Every IAM statement in the template, as sid -> actions.

    Walks by indent rather than parsing: the template carries CloudFormation's `!Ref` / `!If`
    short tags, which PyYAML will not load without a constructor registered for each. Both
    statement shapes are read -- a plain `- Sid: x` entry and one wrapped in `!If`, where the
    keys sit one level deeper but still share a column with each other.
    """
    lines = [line for line in strip_yaml_comments(source).split("\n") if line.strip()]
    out: dict[str, list[str]] = {}
    for i, line in enumerate(lines):
        m = SID_RE.match(line)
        if m is None:
            continue
        sid = m.group(3)
        # The column the mapping's KEYS start at: past the `- ` when the sid opens the entry.
        col = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
        actions: list[str] | None = None
        for j in range(i + 1, len(lines)):
            cur = lines[j]
            indent = len(cur) - len(cur.lstrip(" "))
            if indent < col:
                break
            if indent == col and cur.lstrip().startswith("-"):
                break
            if indent != col:
                continue
            key = cur.strip()
            if key == "Action:":
                actions = []
                for k in range(j + 1, len(lines)):
                    item = lines[k]
                    if len(item) - len(item.lstrip(" ")) <= col:
                        break
                    if not item.lstrip().startswith("- "):
                        break
                    actions.append(_unquote(item.lstrip()[2:]))
                break
            if key.startswith("Action: "):
                actions = [_unquote(key[len("Action: ") :])]
                break
        if actions is None:
            raise GuardError(
                f"{path}: statement `{sid}` carries no `Action`.\n\n"
                "  Either the statement was restructured or this guard's indent walk no longer\n"
                "  matches the template. Both leave an AWS route's grants uncompared."
            )
        out[sid] = actions
    if not out:
        raise GuardError(
            f"{path}: no `Sid:` lines at all.\n\n"
            "  Every statement in this template names one, and they are what the two AWS routes are\n"
            "  compared by. None means the guard is reading nothing."
        )
    return out


# --------------------------------------------------------------------------------------
# The comparisons
# --------------------------------------------------------------------------------------


@dataclass
class Grant:
    """One set of actions that both of a cloud's routes must state identically."""

    cloud: str
    what: str
    why: str
    left: tuple[str, str]  # (path, human name of the site)
    right: tuple[str, str]
    read_left: object = field(repr=False, default=None)
    read_right: object = field(repr=False, default=None)


def _diff(name: str, grant: Grant, left: list[str], right: list[str]) -> list[str]:
    ls, rs = set(left), set(right)
    if ls == rs:
        return []
    problems = []
    missing_right = sorted(ls - rs)
    missing_left = sorted(rs - ls)
    detail = []
    if missing_right:
        detail.append(f"    only in {grant.left[0]}: {', '.join(missing_right)}")
    if missing_left:
        detail.append(f"    only in {grant.right[0]}: {', '.join(missing_left)}")
    problems.append(
        f"{grant.cloud}: {name} differs between the two supported paths.\n\n"
        + "\n".join(detail)
        + f"\n\n  {grant.why}\n"
        "  A customer is on ONE of these paths and never both, so this ships two different landing\n"
        "  pads under one name. Add the missing entries to the path that lacks them -- do not\n"
        "  remove them from the path that has them, unless removing them is the actual intent."
    )
    return problems


# The GCP custom roles, and how each one is written on the two routes:
#   (Terraform resource name, the shell variable holding its permissions, the role-id argument the
#    script passes to `gcloud iam roles`, a human label)
#
# The role-id argument is here so the shell variable can be tied to the command that actually uses
# it. Comparing the assignment alone leaves `--permissions "$VAR,extra.permission"` invisible.
GCP_ROLES = (
    ("egress", "EGRESS_PERMS", "$EGRESS_ROLE", "the egress-control role"),
    ("identity", "IDENTITY_PERMS", "$IDENTITY_ROLE", "the managed-identities role"),
    ("artifact_storage", "STORAGE_ROLE_PERMS", "$ARTIFACT_STORAGE_ROLE", "the artifact-storage role"),
    (
        "artifact_storage_provision",
        "STORAGE_PROVISION_PERMS",
        "${ARTIFACT_STORAGE_ROLE}Provision",
        "the artifact-storage provisioning role",
    ),
)

# The two widths, compared separately as well as through the role above. The role comparison is the
# UNION of both widths and would pass if a permission moved from one list to the other; these pin
# which width each permission belongs to, which is the difference between "Ringleader may reshape
# the buckets it made" and "Ringleader may reshape yours".
GCP_WIDTH_LISTS = (
    ("artifact_storage_permissions", "STORAGE_PERMS", "the artifact-storage role (both widths)"),
    (
        "artifact_storage_manage_permissions",
        "STORAGE_MANAGED_PERMS",
        "the artifact-storage role (managed width only)",
    ),
)


def check_gcp(srcs: dict[str, str]) -> list[str]:
    tf_src = srcs[GCP_TF]
    sh_src = srcs[GCP_SH]
    roles = gcp_terraform_roles(tf_src, GCP_TF)
    call_sites = gcloud_role_permission_vars(sh_src, GCP_SH)

    why = (
        "GCP's two paths are two independent implementations: the Terraform module writes a\n"
        "  google_project_iam_custom_role and the script runs `gcloud iam roles create`. Nothing but\n"
        "  this guard connects them."
    )
    grant = Grant("gcp", "", why, (GCP_TF, "terraform"), (GCP_SH, "gcloud"))

    problems: list[str] = []
    for resource, shell_var, role_arg, label in GCP_ROLES:
        if resource not in roles:
            problems.append(
                f"gcp: no `google_project_iam_custom_role.{resource}` in {GCP_TF}.\n\n"
                f"  {label} is granted by the gcloud path as `{shell_var}`. A role that exists on one\n"
                "  path and not the other is the drift this guard is for -- if it was renamed, rename\n"
                "  it here too."
            )
            continue
        perms, expr = roles[resource]
        if perms is None:
            problems.append(
                f"gcp: `google_project_iam_custom_role.{resource}`'s permissions are now\n"
                f"  `{expr.splitlines()[0]}`, which this guard cannot resolve to a flat set.\n\n"
                f"  It is compared against the gcloud path's `{shell_var}`, so an unreadable expression\n"
                "  is an uncompared route. Build it from `[...]` literals, `local` lists, `concat(...)`\n"
                "  and ternaries -- the shapes every other role here uses."
            )
            continue
        problems += _diff(label, grant, perms, shell_comma_list(sh_src, GCP_SH, shell_var))

        # And the role the script actually creates must be built from the variable just compared.
        # Without this the two lists can agree perfectly while the command uses a third one.
        used = call_sites.get(role_arg)
        if used is None:
            problems.append(
                f"gcp: no `gcloud iam roles create|update {role_arg}` in {GCP_SH}.\n\n"
                f"  {label} is compared against `{shell_var}`, but nothing here proves that variable\n"
                "  reaches a role. A permission list nothing applies proves nothing."
            )
        elif used != {shell_var}:
            problems.append(
                f"gcp: `{role_arg}` is created with `--permissions` from {sorted(used)}, not\n"
                f"  `{shell_var}` alone.\n\n"
                f"  {shell_var} is what this guard compares against Terraform. A role built from a\n"
                "  different variable is a role nothing is comparing."
            )

    for local_name, shell_var, label in GCP_WIDTH_LISTS:
        problems += _diff(
            label,
            grant,
            gcp_terraform_locals(tf_src, GCP_TF, local_name),
            shell_comma_list(sh_src, GCP_SH, shell_var),
        )
    return problems


def check_aws(srcs: dict[str, str]) -> list[str]:
    tf = aws_terraform_statements(srcs[AWS_TF], AWS_TF)
    cfn = aws_cloudformation_statements(srcs[AWS_CFN], AWS_CFN)
    # The trust policy's statement lives in a different document on the Terraform side and in the
    # same file on the CloudFormation side. It is pinned by check_trust_pins.py, which reads it
    # far more carefully than a set comparison would; exclude it rather than half-check it here.
    trust = "RingleaderOrgFederation"
    tf.pop(trust, None)
    cfn.pop(trust, None)

    why = (
        "AWS's two paths are two independent implementations: an aws_iam_policy_document and a\n"
        "  CloudFormation inline policy. Nothing but this guard connects them."
    )
    grant = Grant("aws", "", why, (AWS_TF, "terraform"), (AWS_CFN, "cloudformation"))

    problems: list[str] = []
    for sid in sorted(set(tf) - set(cfn)):
        problems.append(
            f"aws: statement `{sid}` is in {AWS_TF} and in no statement of {AWS_CFN}.\n\n"
            f"  {why}\n"
            "  A customer who deployed the CloudFormation stack does not have this grant at all, and\n"
            "  will find out when the feature it is for fails with a 403 in an account we cannot reach."
        )
    for sid in sorted(set(cfn) - set(tf)):
        problems.append(
            f"aws: statement `{sid}` is in {AWS_CFN} and in no statement of {AWS_TF}.\n\n"
            f"  {why}\n"
            "  A customer who applied the Terraform module does not have this grant at all."
        )
    for sid in sorted(set(tf) & set(cfn)):
        problems += _diff(f"statement `{sid}`", grant, tf[sid], cfn[sid])
    return problems


def check_azure(srcs: dict[str, str]) -> list[str]:
    """Azure has ONE action list; what is checked is that it still has one."""
    tf_src = strip_hcl_comments(srcs[AZURE_TF])
    problems: list[str] = []

    if 'file("${path.module}/../arm/azuredeploy.json")' not in tf_src:
        problems.append(
            f"azure: {AZURE_TF} no longer deploys `../arm/azuredeploy.json` verbatim.\n\n"
            "  That single source is the ONLY reason Azure's two paths cannot drift, and it is why\n"
            "  there is no action-by-action comparison here. A Terraform module that builds its own\n"
            "  role definition needs one -- write it before making that change, not after."
        )
        return problems

    doc = json.loads(srcs[AZURE_ARM])
    declared = set(doc.get("parameters", {}))
    if not declared:
        raise GuardError(f"{AZURE_ARM}: no `parameters` block; this guard is reading nothing.")

    m = re.search(r"parameters_content\s*=\s*jsonencode\(\{", tf_src)
    if m is None:
        raise GuardError(
            f"{AZURE_TF}: no `parameters_content = jsonencode({{`.\n\n"
            "  That block is where the module passes the template's parameters. If it was rewritten,\n"
            "  move this guard with it."
        )
    passed = set(re.findall(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*\{", brace_block(tf_src[m.end() - 1 :], "parameters_content"), re.M))

    for name in sorted(declared - passed):
        problems.append(
            f"azure: `{AZURE_ARM}` declares parameter `{name}` and {AZURE_TF} does not pass it.\n\n"
            "  Two failures at once. A customer on the Terraform route silently gets the template's\n"
            "  DEFAULT rather than the module's variable -- so a switch they set does nothing -- and\n"
            "  Azure materializes that default into the stored deployment while the file leaves it\n"
            "  unset, which is a `terraform plan` reporting a change on this resource forever."
        )
    for name in sorted(passed - declared):
        problems.append(
            f"azure: {AZURE_TF} passes parameter `{name}`, which `{AZURE_ARM}` does not declare.\n\n"
            "  ARM refuses an unknown parameter, so this is an apply that fails for every customer on\n"
            "  the Terraform route."
        )
    return problems


CHECKS = (("gcp", check_gcp), ("aws", check_aws), ("azure", check_azure))


def read_sources(root: Path) -> dict[str, str]:
    return {path: (root / path).read_text(encoding="utf-8") for path in PATHS}


def check_all(srcs: dict[str, str]) -> list[str]:
    problems: list[str] = []
    for name, check in CHECKS:
        try:
            problems += check(srcs)
        except GuardError as exc:
            problems.append(str(exc))
        except (KeyError, ValueError, AttributeError) as exc:
            # A reader that hit a shape it does not understand. Reported rather than raised, so
            # one cloud's unreadable artifact does not hide the other two clouds' results.
            problems.append(
                f"{name}: this guard could not read one of its artifacts ({exc!r}).\n\n"
                "  It was restructured into a shape no reader here handles. Fix the reader; leaving\n"
                "  it broken leaves that cloud's two routes uncompared."
            )
    return problems


def main(root: Path = REPO_ROOT) -> int:
    try:
        srcs = read_sources(root)
    except FileNotFoundError as exc:
        print(
            f"Route parity FAILED: {exc.filename} is gone.\n\n"
            "  A path this guard reads was moved or deleted. Point it at the new one; a guard that\n"
            "  cannot find its artifact is a guard that has stopped guarding.",
            file=sys.stderr,
        )
        return 1
    problems = check_all(srcs)
    if problems:
        print("Route parity FAILED:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}\n", file=sys.stderr)
        return 1
    print("Route parity intact:")
    print("  ok  gcp     terraform custom roles == gcloud custom roles")
    print("  ok  aws     terraform statements == cloudformation statements")
    print("  ok  azure   one action list, deployed by both paths, every parameter passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
