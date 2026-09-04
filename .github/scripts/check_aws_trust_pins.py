#!/usr/bin/env python3
"""Fail the build if an AWS onboarding artifact stops pinning the assertion to ONE org.

The AWS trust policy this repository ships is the artifact whose correctness IS the security
property of Ringleader's cloud federation.

`sts:AssumeRoleWithWebIdentity` names neither an audience nor an identity provider in the
request: AWS resolves the IdP from the assertion's own `iss` and checks `aud` against that
provider's client-id-list. Both pins therefore live entirely here, in the customer's IaC.
And every Ringleader customer's assertion is signed by the SAME issuer service, so the only
thing that distinguishes org A's assertion from org B's is the `sub` claim -- and the only
thing that makes AWS check it is a `StringEquals` condition on a literal subject in the
role's trust policy.

Weaken that one condition (drop it, or match it with `StringLike` and a `*`) and the role
accepts ANY Ringleader tenant's assertion and hands them credentials in that customer's AWS
account. That is a cross-tenant hole reintroduced by an edit that reads as hardening
boilerplate -- the wildcard form is the industry copy-paste for web-identity trust policies,
which is exactly why review is not enough and this guard exists.

Two artifacts carry the property independently, and BOTH are checked. They share no text, so
a guard that read only one would be blind to the same edit made in the other:

  * `aws/terraform/main.tf`                        -- the Terraform module
  * `aws/cloudformation/ringleader-onboarding.yaml` -- the CloudFormation template

**They express the same pin differently, so they are judged differently -- do not assume
symmetry.** The module BUILDS the pin from `var.org_uid` through its `locals` block, so a
condition can be textually perfect while one line in `locals` points the whole module at a
hardcoded org; the value is therefore resolved before it is judged. The template TAKES the pin
as a deploy-time `Parameter`, so what is judged there is the parameter it references and that
parameter's own constraints -- no `Default` (or a by-hand deploy silently gets one) and an
`AllowedPattern` (the only thing in the template that constrains what an operator types).

Read as TEXT rather than parsed (no HCL library, no YAML library, no AWS credentials): the
files are ours, the shapes are narrow, and a guard with no dependencies is one that still
runs in five years. Every extraction step below fails LOUDLY when it finds nothing, because
a guard that silently scans a renamed block is worse than no guard at all.

Run it:   python3 .github/scripts/check_aws_trust_pins.py
Test it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


class GuardError(Exception):
    """An artifact could not be scanned at all -- the loud failure, never a silent pass."""


@dataclass
class Condition:
    """One IAM condition: an operator, the condition key it tests, and the value(s)."""

    test: str = ""
    variable: str = ""
    values: str = ""


# --------------------------------------------------------------------------------------
# Terraform (HCL)
# --------------------------------------------------------------------------------------

TRUST_BLOCK_RE = re.compile(r'data\s+"aws_iam_policy_document"\s+"trust"\s*\{')
DYNAMIC_RE = re.compile(r'dynamic\s+"(statement|condition)"\s*\{')
LOCALS_BLOCK_RE = re.compile(r"\blocals\s*\{")
LOCAL_ASSIGN_RE = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=[ \t]*(.+?)[ \t]*$", re.M)
LOCAL_REF_RE = re.compile(r"\blocal\.([A-Za-z_][A-Za-z0-9_-]*)")
# What every pin must ultimately be built from. `var.org_uid` is the customer's own org, so an
# expression that no longer mentions it is no longer per-org, however it is spelled.
ORG_UID = "var.org_uid"
# Any function call. Refused outright in a pin, because "mentions var.org_uid" is not the same
# as "evaluates to this org" and a text scan cannot tell the two apart:
# `element(["org:HARDCODED", "decoy var.org_uid"], 0)` returns the hardcoded literal for every
# customer while carrying the substring that would satisfy a membership test. Rather than chase
# each function, the pin is held to a closed grammar -- a literal, an interpolation, a
# reference -- the same "refuse rather than half-support" stance taken for `dynamic` blocks.
CALL_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*\s*\(")
ROLE_BLOCK_RE = re.compile(r'resource\s+"aws_iam_role"\s+"[^"]+"\s*\{')
ASSUME_ROLE_POLICY_RE = re.compile(r"assume_role_policy\s*=\s*(\S+)")
TRUST_DOCUMENT = "data.aws_iam_policy_document.trust.json"
STATEMENT_RE = re.compile(r"statement\s*\{")
CONDITION_RE = re.compile(r"condition\s*\{")
HCL_TEST_RE = re.compile(r'test\s*=\s*"([^"]*)"')
HCL_VARIABLE_RE = re.compile(r'variable\s*=\s*"([^"]*)"')
HCL_VALUES_RE = re.compile(r"values\s*=\s*\[([^\]]*)\]")


def strip_hcl_comments(src: str) -> str:
    """Drop `#` and `//` line comments, leaving string literals intact.

    Not cosmetic. Both modules DOCUMENT the pin they must not lose -- and the Terraform one
    documents in prose that it grants `iam:PassRole`. A naive substring scan matches the
    documentation instead of the code and fails on a correct file.
    """
    out = []
    for line in src.split("\n"):
        in_quote = False
        cut = -1
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                in_quote = not in_quote
            elif in_quote:
                pass
            elif ch == "#":
                cut = i
            elif ch == "/" and i + 1 < len(line) and line[i + 1] == "/":
                cut = i
            if cut >= 0:
                break
            i += 1
        out.append(line if cut < 0 else line[:cut])
    return "\n".join(out)


def brace_block(src: str, what: str) -> str:
    """Return src -- which must start at a `{` -- through its matching `}`, counting depth.

    Brace-MATCHED rather than regexped to the first `}`: a condition's `variable` is
    "${local.oidc_condition_prefix}:sub", whose interpolation contains a `}`. A non-greedy
    `.*?}` stops inside it, truncating the body so `variable` never parses -- and the guard
    then reports a MISSING subject condition on a file that has one.

    QUOTE-AWARE, and that is load-bearing rather than tidy. A brace inside a string literal is an
    ordinary character to HCL, so a blind counter reading `sid = "Federation}"` closes the
    document one brace early and stops scanning there -- and a second, unconditioned statement
    written below it is never seen, while `terraform fmt` and `terraform validate` both pass.
    Interpolation braces outside a string are still counted, so `${...}` stays balanced.
    """
    depth, quoted = 0, False
    for i, ch in enumerate(src):
        if ch == '"' and (i == 0 or src[i - 1] != "\\"):
            quoted = not quoted
        elif quoted:
            continue
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[: i + 1]
    raise GuardError(f"unbalanced braces: could not find the end of {what}")


def terraform_wiring(src: str, path: str) -> None:
    """Assert the role Ringleader assumes is governed by the document this guard reads.

    Scanning a policy document BY NAME proves nothing on its own: the conditions below can be
    perfectly pinned while the role's `assume_role_policy` points at a second, unpinned
    `aws_iam_policy_document` added alongside it. The named block is then dead code, every
    check passes, `terraform validate` is happy (an unused data source is not an error), and
    every customer applying the module gets a role that trusts the whole fleet. So the guard
    checks the WIRING first, and there must be exactly one role to wire.
    """
    roles = [m for m in ROLE_BLOCK_RE.finditer(src)]
    if len(roles) != 1:
        raise GuardError(
            f"{path}: found {len(roles)} `aws_iam_role` resources, expected exactly 1.\n\n"
            "Each role carries its own trust policy, and this guard checks the one document named\n"
            "`trust`. A second role is a second way into the account that nothing here reads."
        )
    body = brace_block(src[roles[0].end() - 1 :], f"{path}'s aws_iam_role")
    m = ASSUME_ROLE_POLICY_RE.search(body)
    if m is None:
        raise GuardError(
            f"{path}: the `aws_iam_role` sets no `assume_role_policy`.\n\n"
            "Either it moved somewhere this guard cannot see it, or the role has no trust policy at\n"
            "all. Both leave the exact-subject pin unchecked."
        )
    if m.group(1) != TRUST_DOCUMENT:
        raise GuardError(
            f"{path}: the role's `assume_role_policy` is {m.group(1)}, want {TRUST_DOCUMENT}.\n\n"
            "This guard reads the policy document named `trust`. Pointing the role at a different\n"
            "one leaves `trust` as dead code that still passes every check below, while the document\n"
            "customers actually apply goes unread -- which is how an unpinned trust policy ships\n"
            "through a green build."
        )


def split_top_level(expr: str) -> list[str]:
    """Split a `values = [...]` body on its top-level commas.

    IAM ORs a condition's values, so a second entry WIDENS the pin: `["org:HARDCODED", <this
    org>]` trusts both. One value, always.
    """
    items, depth, quoted, start = [], 0, False, 0
    for i, ch in enumerate(expr):
        if ch == '"' and (i == 0 or expr[i - 1] != "\\"):
            quoted = not quoted
        elif quoted:
            continue
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            items.append(expr[start:i].strip())
            start = i + 1
    items.append(expr[start:].strip())
    return [i for i in items if i]


def hcl_locals(src: str) -> dict[str, str]:
    """Every single-line assignment in every `locals` block, by name.

    Deliberately only single-line: an assignment this cannot parse is not silently skipped, it
    becomes an unresolvable reference and `resolve_hcl` fails loudly. Guessing at a multi-line
    expression is how a resolver quietly concludes the wrong thing.
    """
    out: dict[str, str] = {}
    rest = src
    while (m := LOCALS_BLOCK_RE.search(rest)) is not None:
        body = brace_block(rest[m.end() - 1 :], "a locals block")
        for name, value in LOCAL_ASSIGN_RE.findall(body):
            if value.count("(") == value.count(")") and value.count("[") == value.count("]"):
                out[name] = value
        rest = rest[m.end() - 1 + len(body) :]
    return out


def resolve_hcl(expr: str, locals_: dict[str, str], path: str, what: str) -> str:
    """Expand `local.*` references until none remain, so a pin is judged by what it MEANS.

    Checking that a condition references `local.subject` proves only that a symbol is spelled
    correctly. The line that gives the symbol its meaning lives in the `locals` block, and an
    edit there -- `subject = "org:<some other customer's uid>"` -- leaves every condition byte
    identical while pointing the whole module at one hardcoded org.
    """
    for _ in range(10):
        refs = LOCAL_REF_RE.findall(expr)
        if not refs:
            return expr
        for name in refs:
            if name not in locals_:
                raise GuardError(
                    f"{path}: {what} resolves through `local.{name}`, which this guard cannot read.\n\n"
                    "It is defined outside a `locals` block, or spread over several lines. Either way the\n"
                    "guard can no longer tell what the pin means, and it will not assume. Keep the pin's\n"
                    "definition a single-line assignment in a `locals` block."
                )
            expr = expr.replace(f"local.{name}", f"({locals_[name]})")
    raise GuardError(
        f"{path}: {what} is a cycle of `local.*` references that never bottoms out."
    )


def terraform_conditions(src: str, path: str) -> tuple[list[Condition], int]:
    """Extract the `trust` policy document's conditions, and how many statements it has."""
    src = strip_hcl_comments(src)
    terraform_wiring(src, path)

    m = TRUST_BLOCK_RE.search(src)
    if m is None:
        raise GuardError(
            f'{path}: could not find the assume-role policy document (data "aws_iam_policy_document" "trust").\n\n'
            "If it was renamed, RENAME IT BACK or update this guard -- but do not leave the guard scanning\n"
            "nothing: the trust policy's exact-subject condition is the entire security property of AWS\n"
            "federation, and a guard that scans a block that no longer exists reports success forever."
        )
    block = brace_block(src[m.end() - 1 :], f"{path}'s trust policy document")

    # A `dynamic` block is a CONDITIONAL statement or condition: `for_each = []` emits nothing,
    # and no text scan can tell that from one that emits the pin. Refused outright rather than
    # supported, because a trust policy whose subject condition depends on a variable is the
    # thing this guard exists to prevent -- and it must be readable without evaluating HCL.
    if d := DYNAMIC_RE.search(block):
        raise GuardError(
            f'{path}: the trust policy uses `dynamic "{d.group(1)}"`.\n\n'
            "The trust document must be statically readable: a `dynamic` block emits nothing when its\n"
            "`for_each` is empty, so a trust policy built that way can ship with no subject pin at all\n"
            "while every check here reads one. Write the statement and its conditions out literally.\n"
            "(The permissions policy in this file may use `dynamic` freely; only `trust` may not.)"
        )

    statements = len(STATEMENT_RE.findall(block))
    conditions = []
    rest = block
    while True:
        c = CONDITION_RE.search(rest)
        if c is None:
            break
        body = brace_block(rest[c.end() - 1 :], f"{path}'s condition block")
        cond = Condition()
        if v := HCL_TEST_RE.search(body):
            cond.test = v.group(1)
        if v := HCL_VARIABLE_RE.search(body):
            cond.variable = v.group(1)
        if v := HCL_VALUES_RE.search(body):
            cond.values = v.group(1).strip()
        conditions.append(cond)
        rest = rest[c.end() - 1 + len(body) :]
    return conditions, statements


# --------------------------------------------------------------------------------------
# CloudFormation (YAML)
# --------------------------------------------------------------------------------------

# A condition KEY contains a colon of its own ("<issuer-host+path>:sub"), so a quoted key is
# matched first and WHOLE -- splitting on the first colon would yield "__OIDC_PROVIDER__" and a
# variable ending in nothing, i.e. a guard reporting a missing pin on a file that has one. Both
# quote styles are accepted: YAML treats them alike here, and a contributor reformatting one to
# the other must not turn a correct file red -- a guard that cries wolf is a guard that gets
# deleted rather than fixed.
YAML_QUOTED_PAIR_RE = re.compile(r"""^\s*(?:"([^"]+)"|'([^']+)')\s*:\s*(.+?)\s*$""")
YAML_PLAIN_PAIR_RE = re.compile(r"^\s*([^:\s][^:]*?)\s*:\s*(.+?)\s*$")


def strip_yaml_comments(src: str) -> str:
    """Drop `#` comments outside quotes. The trust policy carries one, inside the condition."""
    out = []
    for line in src.split("\n"):
        in_quote = False
        cut = -1
        for i, ch in enumerate(line):
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                in_quote = not in_quote
            elif ch == "#" and not in_quote:
                cut = i
                break
        out.append(line if cut < 0 else line[:cut])
    return "\n".join(out)


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _child_block(lines: list[str], start: int) -> list[str]:
    """The lines strictly more indented than lines[start] -- a YAML mapping's own body."""
    base = _indent(lines[start])
    body = []
    for line in lines[start + 1 :]:
        if not line.strip():
            continue
        if _indent(line) <= base:
            break
        body.append(line)
    return body


def _find_key(lines: list[str], key: str) -> list[int]:
    return [i for i, line in enumerate(lines) if line.strip() == f"{key}:"]


def _list_entries(lines: list[str], start: int) -> list[list[str]]:
    """Split the YAML block sequence under lines[start] into one line-list per entry.

    An entry begins at a line at the sequence's own indent that starts with `-`. Both spellings
    count: `- Sid: x` with the first key inline, and a bare `-` with every key on the following
    lines. Matching only the first is how a second statement becomes invisible while remaining
    perfectly valid YAML that AWS honours.
    """
    body = _child_block(lines, start)
    if not body:
        return []
    base = min(_indent(line) for line in body)
    entries: list[list[str]] = []
    for line in body:
        if _indent(line) == base and line.lstrip().startswith("-"):
            entries.append([line])
        elif entries:
            entries[-1].append(line)
    return entries


def cloudformation_conditions(src: str, path: str) -> tuple[list[Condition], int]:
    """Extract the role's AssumeRolePolicyDocument conditions, and its statement count.

    YAML block structure IS indentation, so the nesting is walked by indent rather than parsed.
    That keeps the guard free of PyYAML -- which cannot load this file anyway without
    registering constructors for CloudFormation's `!Ref` / `!Sub` short tags.

    Conditions are collected PER STATEMENT, never globally across the document. A global scan
    finds the conditions belonging to a correctly pinned statement and reports them however many
    other statements sit beside it -- so a second, unconditioned statement grants every Ringleader
    tenant the role while the guard reads the first one's pins and reports success.
    """
    lines = [line for line in strip_yaml_comments(src).split("\n") if line.strip()]

    anchors = _find_key(lines, "AssumeRolePolicyDocument")
    if not anchors:
        raise GuardError(
            f"{path}: could not find the role's AssumeRolePolicyDocument.\n\n"
            "If the key moved or the role was restructured, update this guard -- but do not leave it\n"
            "scanning nothing: this template is the second, independent place the exact-subject pin\n"
            "is written, and a customer who deploys the CloudFormation stack gets whatever it says."
        )
    if len(anchors) > 1:
        raise GuardError(
            f"{path}: found {len(anchors)} AssumeRolePolicyDocument keys, expected exactly one.\n\n"
            "A second federated role is a second trust policy, and this guard checks one. Either fold\n"
            "them together or teach the guard about both -- do not leave one of them unchecked."
        )
    doc = _child_block(lines, anchors[0])

    statement_keys = _find_key(doc, "Statement")
    if not statement_keys:
        raise GuardError(
            f"{path}: the trust policy has no `Statement:` list this guard can read.\n\n"
            "It may have been written as a single inline mapping or in flow style. Write it as a block\n"
            "sequence: the pin is the one thing here that has to stay mechanically checkable."
        )
    statements = _list_entries(doc, statement_keys[0])

    conditions = []
    for entry in statements:
        for i, line in enumerate(entry):
            if line.strip() != "Condition:":
                continue
            operators = _child_block(entry, i)
            if not operators:
                continue
            for j, op_line in enumerate(operators):
                if _indent(op_line) != _indent(operators[0]):
                    continue
                # Block style only. A flow map (`StringEquals: {"...:sub": !Ref Subject}`) has no
                # child lines to walk, and reporting that as "no conditions" would read as "the
                # pin is missing" when it is really "this guard cannot read that shape".
                if not op_line.strip().endswith(":"):
                    raise GuardError(
                        f"{path}: the trust policy's `{op_line.strip().split(':')[0]}` condition is written\n"
                        "in YAML flow style, which this guard does not read.\n\n"
                        "Write the condition as an indented block mapping. The pin is the one thing here that\n"
                        "has to stay mechanically checkable, and that is worth more than the formatting."
                    )
                test = op_line.strip().rstrip(":")
                for pair in _child_block(operators, j):
                    if m := YAML_QUOTED_PAIR_RE.match(pair):
                        variable, values = m.group(1) or m.group(2), m.group(3)
                    elif m := YAML_PLAIN_PAIR_RE.match(pair):
                        variable, values = m.group(1), m.group(2)
                    else:
                        continue
                    conditions.append(
                        Condition(test=test, variable=variable, values=values)
                    )
    return conditions, len(statements)


def cloudformation_parameter(src: str, name: str) -> list[str] | None:
    """The lines of one `Parameters:` entry, or None if there is no such parameter."""
    lines = [line for line in strip_yaml_comments(src).split("\n") if line.strip()]
    anchors = _find_key(lines, "Parameters")
    if not anchors:
        return None
    params = _child_block(lines, anchors[0])
    for i, line in enumerate(params):
        if line.strip() == f"{name}:":
            return _child_block(params, i)
    return None


# --------------------------------------------------------------------------------------
# The artifacts and the checks
# --------------------------------------------------------------------------------------


def judge_terraform(artifact: "Artifact", source: str, path: str, cond: Condition, kind: str) -> list[str]:
    """Judge a condition's value by what it RESOLVES to, not by the symbol it is spelled with."""
    what = f"the `:{kind}` condition's value"
    locals_ = hcl_locals(strip_hcl_comments(source))

    items = split_top_level(cond.values)
    if len(items) != 1:
        return [
            f"{path}: the `:{kind}` condition carries {len(items)} values ({cond.values}).\n\n"
            "  IAM ORs them, so every extra value is another subject the role accepts. Pin exactly one."
        ]
    resolved = resolve_hcl(items[0], locals_, path, what)

    fails = []
    if call := CALL_RE.search(resolved):
        return [
            f"{path}: {what} resolves to {resolved}, which calls `{call.group(0).rstrip('(').strip()}`.\n\n"
            "  A pin must be a literal, an interpolation or a reference -- something whose value can be\n"
            "  read here. A function call cannot: `element([\"org:HARDCODED\", \"mentions var.org_uid\"], 0)`\n"
            "  returns the same hardcoded subject for every customer while carrying the text that makes\n"
            "  it look per-org. This guard will not guess which branch ships."
        ]
    if any(ch in resolved for ch in "*?"):
        fails.append(
            f"{path}: {what} contains a wildcard once resolved ({resolved}).\n\n"
            "  Even under StringEquals (which does not expand it) this is one operator change away\n"
            "  from admitting every org in the fleet. The pin is a literal, built from this customer's\n"
            "  own org uid."
        )
    if ORG_UID not in resolved:
        fails.append(
            f"{path}: {what} resolves to {resolved}, which is not built from `{ORG_UID}`.\n\n"
            "  Whatever it is spelled as, the pin has to derive from THIS customer's org uid. A value\n"
            "  that no longer mentions it is either a hardcoded subject -- every customer applying the\n"
            "  module trusting one org that is not theirs -- or a pin that can never match, and the\n"
            "  customer cannot boot a box."
        )
    if kind == "aud" and "/aws" not in resolved:
        fails.append(
            f"{path}: the `:aud` condition's value resolves to {resolved}, which is not the AWS\n"
            "  audience.\n\n"
            "  The issuer stamps a per-CLOUD audience (`<iss>/aws`). Pinning another cloud's here is what\n"
            "  lets an assertion minted for GCP or Azure -- same org, same issuer -- be replayed at AWS."
        )
    return fails


def judge_cloudformation(artifact: "Artifact", source: str, path: str, cond: Condition, kind: str) -> list[str]:
    """The template takes its pins as deploy-time Parameters, so judge the PARAMETER."""
    what = f"the `:{kind}` condition's value"
    pin = artifact.subject_pin if kind == "sub" else artifact.audience_pin

    fails = []
    if any(ch in cond.values for ch in "*?"):
        fails.append(
            f"{path}: {what} contains a wildcard ({cond.values}) -- pin the exact per-org value."
        )
    # An EXACT match, never a substring. `!Select [0, ["org:HARDCODED", !Ref Subject]]` contains
    # the pin and always resolves to the literal -- the same hardcoded subject for every customer
    # who deploys the template, with `!Ref Subject` present only as decoy text.
    if cond.values.strip() != pin:
        return fails + [
            f"{path}: {what} is {cond.values}, want exactly `{pin}`.\n\n"
            "  The template's pins are supplied at deploy time, and this parameter is the one whose\n"
            "  description and AllowedPattern say what it must be. Any other expression -- an intrinsic\n"
            "  wrapping it included -- is a second definition of the value, free to resolve to something\n"
            "  other than the org deploying the stack."
        ]

    name = pin.split()[-1]
    body = cloudformation_parameter(source, name)
    if body is None:
        # cfn-lint catches a !Ref to a parameter that does not exist, but this guard must not
        # depend on another job having run to be sound.
        return fails + [f"{path}: `{pin}` names a parameter `{name}` that does not exist."]
    if any(line.strip().startswith("Default:") for line in body):
        fails.append(
            f"{path}: the `{name}` parameter has a `Default`.\n\n"
            "  A default is what a by-hand deploy gets when the operator supplies nothing -- so a default\n"
            "  here is a trust policy pinned to whatever value happens to be baked into the template,\n"
            "  rather than to the org deploying it. This parameter must always be supplied."
        )
    if not any(line.strip().startswith("AllowedPattern:") for line in body):
        fails.append(
            f"{path}: the `{name}` parameter has no `AllowedPattern`.\n\n"
            "  It is supplied at deploy time, so the pattern is the only thing in this template that\n"
            "  constrains it to the per-org shape. Without one the pin is only as good as what somebody\n"
            "  typed into the console."
        )
    return fails

@dataclass
class Artifact:
    """One shipped file that carries the trust pin, and how this file spells it."""

    path: str
    extract: object
    # How a condition's VALUE is judged. The two artifacts express the same pin differently:
    # the Terraform module builds it from `var.org_uid` through the `locals` block, so it is
    # judged on what it resolves to; the template takes it as a deploy-time Parameter, so it is
    # judged on the parameter it references and that parameter's own constraints.
    judge: object
    # The correct condition, for the message printed when it has gone missing.
    restore: str
    # CloudFormation only: the `!Ref` each condition must carry.
    subject_pin: str = ""
    audience_pin: str = ""


ARTIFACTS = [
    Artifact(
        path="aws/terraform/main.tf",
        extract=terraform_conditions,
        judge=judge_terraform,
        restore=(
            "  condition {\n"
            '    test     = "StringEquals"\n'
            '    variable = "${local.oidc_condition_prefix}:sub"\n'
            "    values   = [local.subject]\n"
            "  }"
        ),
    ),
    Artifact(
        path="aws/cloudformation/ringleader-onboarding.yaml",
        extract=cloudformation_conditions,
        judge=judge_cloudformation,
        subject_pin="!Ref Subject",
        audience_pin="!Ref Audience",
        restore=(
            "  Condition:\n"
            "    StringEquals:\n"
            '      "__OIDC_PROVIDER__:aud": !Ref Audience\n'
            '      "__OIDC_PROVIDER__:sub": !Ref Subject'
        ),
    ),
]



@dataclass
class Report:
    failures: list[str] = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.failures.append(msg)


def _one(conditions: list[Condition], suffix: str) -> Condition | None:
    found = [c for c in conditions if c.variable.endswith(suffix)]
    if len(found) > 1:
        raise GuardError(
            f"the trust policy carries {len(found)} `{suffix}` conditions "
            f"({', '.join(repr(c.variable) for c in found)}).\n\n"
            "IAM ANDs them, so this is not itself a hole -- but it is ambiguous enough that the next\n"
            "edit will delete the wrong one. Keep exactly one."
        )
    return found[0] if found else None


def check_artifact(artifact: Artifact, source: str) -> list[str]:
    """Check one artifact's text. Raises GuardError when it cannot be scanned at all."""
    path = artifact.path
    conditions, statements = artifact.extract(source, path)

    if not conditions:
        raise GuardError(
            f"{path}: the trust policy carries NO conditions at all -- the role trusts every subject the\n"
            "Ringleader issuer will ever sign, i.e. every other customer's org."
        )
    if statements != 1:
        raise GuardError(
            f"{path}: the trust policy has {statements} statements, expected exactly 1.\n\n"
            "Each statement carries its own conditions, so a second one is a second, separately-pinned\n"
            "(or entirely unpinned) way into the role -- and the checks below describe only the first.\n"
            "Write the trust policy as exactly one statement."
        )

    r = Report()
    sub = _one(conditions, ":sub")
    aud = _one(conditions, ":aud")

    # 1. The subject condition exists at all. Without it the role trusts EVERY subject the
    #    issuer will ever sign -- i.e. every other Ringleader customer's org.
    if sub is None:
        r.fail(
            f"{path}: the trust policy has NO condition on `:sub`.\n\n"
            "  That role now accepts an assertion from ANY Ringleader org, not just this customer's --\n"
            "  every other tenant can assume it and act in this customer's AWS account. The subject\n"
            "  condition is not hardening; it is the only thing that makes the federation per-org.\n\n"
            f"  Restore:\n{artifact.restore}"
        )
    else:
        # 2. It is an EXACT match. A pattern operator admits a wildcard, and the industry
        #    copy-paste for web-identity trust is exactly that.
        if sub.test != "StringEquals":
            r.fail(
                f"{path}: the `:sub` condition uses {sub.test!r}, want \"StringEquals\".\n\n"
                "  A pattern operator lets a wildcard subject through, which is the whole risk: `org:*`\n"
                "  matches every Ringleader customer. The subject must be matched literally."
            )
        # 3. The VALUE means what it should -- no wildcard, and built from this org's uid. Judged
        #    per artifact, because a symbol that reads correctly is not a value that is correct:
        #    the Terraform value is resolved through the `locals` block first.
        for f in artifact.judge(artifact, source, path, sub, "sub"):
            r.fail(f)

    # The second, independent pin. Losing it is not the cross-tenant hole the subject is (the
    # subject still confines the org), but the audience is what stops an assertion minted for a
    # DIFFERENT CLOUD (same org, same issuer, `aud` = <iss>/gcp) from being replayed at AWS.
    if aud is None:
        r.fail(
            f"{path}: the trust policy has NO condition on `:aud`.\n\n"
            "  It is the pin that stops an assertion minted for another CLOUD (same org, same issuer,\n"
            "  aud = <iss>/gcp) being replayed here."
        )
    else:
        if aud.test != "StringEquals":
            r.fail(
                f"{path}: the `:aud` condition uses {aud.test!r}, want \"StringEquals\" "
                "(an exact match, like the subject)."
            )
        for f in artifact.judge(artifact, source, path, aud, "aud"):
            r.fail(f)

    # Ringleader's own instances hold no IAM identity, so the onboarding role needs no
    # `iam:PassRole` at all -- except under the opt-in workstation-identities feature, where it
    # is granted narrowly. Unpinned, PassRole would let a workstation act as ANY passable
    # identity in the customer's account, which is the standing-credential property the whole
    # product avoids. Comments are stripped above, so the module's own prose about the grant
    # does not match here.
    body = strip_hcl_comments(source) if path.endswith(".tf") else strip_yaml_comments(source)
    if "iam:PassRole" in body and "iam:PassedToService" not in body:
        r.fail(
            f"{path} grants iam:PassRole with no `iam:PassedToService` condition.\n\n"
            "  PassRole hands the account's identities to whatever service asks for them. The\n"
            "  PassedToService pin (`ec2.amazonaws.com`) is what confines it to the instance profiles\n"
            "  the workstation-identities feature actually needs; without it the grant reaches every\n"
            "  service in the account."
        )

    return r.failures


def main(root: Path = REPO_ROOT) -> int:
    failures: list[str] = []
    for artifact in ARTIFACTS:
        file = root / artifact.path
        try:
            source = file.read_text(encoding="utf-8")
        except OSError as err:
            failures.append(
                f"{artifact.path}: cannot read it ({err}).\n\n"
                "  It carries the security property of AWS cloud federation; it must not simply\n"
                "  disappear. If it moved, move this guard with it."
            )
            continue
        try:
            failures.extend(check_artifact(artifact, source))
        except GuardError as err:
            failures.append(str(err))

    if failures:
        print("The AWS trust pins are not intact:\n", file=sys.stderr)
        for f in failures:
            print(f"  * {f}\n", file=sys.stderr)
        print(
            "Every Ringleader customer's assertion is signed by the same issuer. The `sub` pin is the\n"
            "only thing separating one customer's AWS account from the whole fleet.",
            file=sys.stderr,
        )
        return 1

    print(f"AWS trust pins intact in {len(ARTIFACTS)} artifacts:")
    for artifact in ARTIFACTS:
        print(f"  ok  {artifact.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
