#!/usr/bin/env python3
"""Fail the build if an onboarding artifact stops pinning the assertion to ONE org.

The trust configuration this repository ships is the artifact whose correctness IS the security
property of Ringleader's cloud federation, on every cloud.

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

SIX artifacts carry the property independently, and ALL are checked. They share no text, so a
guard that read only one would be blind to the same edit made in another -- and every cloud
ships two supported paths, a Terraform module and a script or template beside it:

  * `aws/terraform/main.tf`                         -- an IAM role's trust policy
  * `aws/cloudformation/ringleader-onboarding.yaml` -- the same policy, as a template
  * `gcp/terraform/main.tf`                         -- a WIF provider condition + an SA binding
  * `gcp/gcloud/onboard.sh`                         -- the same two, written with gcloud
  * `azure/terraform/main.tf`                       -- a federated identity credential
  * `azure/arm/deploy.sh`                           -- the same credential, written with az

(`azure/arm/azuredeploy.json` carries no subject pin -- it does the role assignment only -- so
there is nothing there to guard.)

**How the property is spelled differs per cloud, so each artifact is judged on its own terms --
do not assume symmetry.** AWS pins the assertion's `sub` and `aud` with `StringEquals` in a
trust policy. GCP has TWO independent sites, and neither alone confines the org: the pool
provider's `attribute_condition`, and the `workloadIdentityUser` binding whose member must be
the single `principal://.../subject/org:<uid>` rather than the industry copy-paste
`principalSet://.../<pool>/*`. Azure matches the subject byte for byte with no operator to
loosen, so its loss mode is the field being widened, dropped or repointed.

Every cloud is also checked for its WIRING, because pinning a block nothing applies proves
nothing: the AWS role's `assume_role_policy` must name the document read here; GCP's guarded
condition must belong to the pool the binding actually names; Azure's credential must be
attached to the application Ringleader authenticates as.

**Within AWS the two artifacts express the same pin differently, so they too are judged
differently.** The module BUILDS the pin from `var.org_uid` through its `locals` block, so a
condition can be textually perfect while one line in `locals` points the whole module at a
hardcoded org; the value is therefore resolved before it is judged. The template TAKES the pin
as a deploy-time `Parameter`, so what is judged there is the parameter it references and that
parameter's own constraints -- no `Default` (or a by-hand deploy silently gets one) and an
`AllowedPattern` (the only thing in the template that constrains what an operator types).

Read as TEXT rather than parsed (no HCL library, no YAML library, no AWS credentials): the
files are ours, the shapes are narrow, and a guard with no dependencies is one that still
runs in five years. Every extraction step below fails LOUDLY when it finds nothing, because
a guard that silently scans a renamed block is worse than no guard at all.

**The two SHELL artifacts are read against a CLOSED GRAMMAR.** `gcp/gcloud/onboard.sh` and
`azure/arm/deploy.sh` are still read statically rather than run, but not by looking for the shapes
that weaken a pin -- by requiring EVERY statement in the file to be one this guard recognises: an
assignment, a command from a named list, or a shell keyword. A statement matching none of them is a
hard failure and the file is refused unscanned.

That inversion is what closes the gap an assignment-hunting reader had. A pin may be bound only by a
plain `NAME=value` that PERSISTS; every other way of binding one is refused by name -- `read -r
SUBJECT <<<`, `printf -v`, `eval`, a `for` loop variable, a brace group, a function body, `source
/dev/stdin`, a `case` arm, a `declare -n` nameref, a `${NAME:=...}` assigning expansion, an
arithmetic `$(( NAME=... ))`, `coproc`, a `trap` body, process substitution -- and so is any command
the grammar does not know, and any word whose job is to RUN one (`command`, `time`, `env`). A statement
may carry a RUN of assignments before a command (`IFS= read -r SUBJECT ...`), so every one of them
is peeled and what follows is judged on its own; reading only the first `NAME=` is how that
particular one hid.

**The reader's own parsing is part of the guard.** The shapes that got furthest were not exotic
binders but ways to DESYNC the scanner, so that a perfectly ordinary `SUBJECT=...` became invisible:
a backslash run defeating the escape check and swallowing every following line into one `echo`
(`_quote_closes`), an unmatched bracket in a value swallowing the assignment after it
(`_peel_assignments`' typed stack), a BARE `(` or `[` -- an ordinary word to bash -- read as an
unclosed nesting, which joined the next line into the `echo` before it (`_scan_shell`, which lets
only a quote, a backtick or a `$(`/`${`/`$[` substitution carry a statement across a line break),
and an ESCAPED quote read as an opening one, which made the swallow surgical: `echo \'` on either
side of an injected line hid exactly that line while the rest of the file parsed normally
(`_escape_span`, applied wherever a scanner opens a string). All four are now refusals. When changing any of it, remember that
making a real statement invisible is worth exactly as much to an attacker as a hidden binder. A denylist of spellings never terminated,
because bash always has one more; an allowlist does, because widening it is a deliberate edit to
`SH_COMMANDS` with a test beside it. See `classify_shell_statement`.

Run it:   python3 .github/scripts/check_trust_pins.py
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

# --------------------------------------------------------------------------------------
# Shared judgement: what makes a resolved pin per-org
# --------------------------------------------------------------------------------------


def judge_resolved(path: str, what: str, resolved: str, must_contain: str = "") -> list[str]:
    """The three questions every pin on every cloud has to answer, asked once.

    A pin is a LITERAL, an interpolation or a reference -- something whose value can be read
    here. Anything else is refused rather than half-supported, because "mentions var.org_uid" is
    not the same as "evaluates to this org", and a text scan cannot tell the two apart.
    """
    if call := CALL_RE.search(resolved):
        return [
            f"{path}: {what} resolves to {resolved}, which calls "
            f"`{call.group(0).rstrip('(').strip()}`.\n\n"
            "  A pin must be a literal, an interpolation or a reference. A function call cannot be\n"
            "  read here: one branch can carry this customer's org uid while another, the one that\n"
            "  actually ships, carries somebody else's. This guard will not guess which."
        ]
    fails = []
    if any(ch in resolved for ch in "*?"):
        fails.append(
            f"{path}: {what} contains a wildcard once resolved ({resolved}).\n\n"
            "  Every Ringleader customer's assertion is signed by the same issuer, so a wildcard here\n"
            "  admits the whole fleet. The pin is a literal built from this customer's own org uid."
        )
    if ORG_UID not in resolved:
        fails.append(
            f"{path}: {what} resolves to {resolved}, which is not built from `{ORG_UID}`.\n\n"
            "  Whatever it is spelled as, the pin has to derive from THIS customer's org uid. A value\n"
            "  that no longer mentions it is either a hardcoded subject -- every customer applying the\n"
            "  module trusting one org that is not theirs -- or a pin that can never match."
        )
    if must_contain and must_contain not in resolved:
        fails.append(
            f"{path}: {what} resolves to {resolved}, which does not carry `{must_contain}`.\n\n"
            "  The issuer stamps a per-CLOUD audience. Pinning another cloud's is what lets an\n"
            "  assertion minted for a different cloud -- same org, same issuer -- be replayed here."
        )
    return fails


# --------------------------------------------------------------------------------------
# More HCL: whole resources, and the attributes inside them
# --------------------------------------------------------------------------------------


def hcl_resources(src: str, rtype: str) -> list[tuple[str, str]]:
    """Every `resource "<rtype>" "<name>" { ... }` in src, as (name, body-with-braces)."""
    pattern = re.compile(r'resource\s+"' + re.escape(rtype) + r'"\s+"([^"]+)"\s*\{')
    out = []
    for m in pattern.finditer(src):
        out.append((m.group(1), brace_block(src[m.end() - 1 :], f"{rtype}.{m.group(1)}")))
    return out


def hcl_list_items(value: str, path: str, what: str) -> list[str]:
    """Split a single-line `[...]` list, refusing LOUDLY when it is not one.

    A hand-reflowed `audiences = [\n  local.audience,\n]` gives `hcl_attr` just `[`, and splitting
    that yields nothing -- which would be reported as "carries 0 values", i.e. the pin is missing, on
    a file whose pin is perfect. A guard that cries wolf is a guard that gets deleted rather than
    fixed, so an unreadable shape says so instead.
    """
    v = value.strip()
    if not v.startswith("[") or not v.endswith("]"):
        raise GuardError(
            f"{path}: {what} is {value}, which this guard cannot read as a list.\n\n"
            "  It is probably spread over several lines. Write it on one -- the pin is the one thing\n"
            "  here that has to stay mechanically checkable, and that is worth more than the wrapping."
        )
    return split_top_level(v[1:-1])


def hcl_attr(body: str, name: str) -> str | None:
    """A single-line `name = value` inside body, or None.

    It matches the FIRST such line anywhere in `body`, nested blocks included -- so the caller picks
    the enclosing block first (`hcl_sub_block`) rather than relying on this to tell levels apart.
    Duplicating an attribute at two levels is an HCL error, so the ambiguity does not arise in a file
    that parses, but the narrowing is the caller's job and not this function's."""
    m = re.search(r"^[ \t]*" + re.escape(name) + r"[ \t]*=[ \t]*(.+?)[ \t]*$", body, re.M)
    return m.group(1) if m else None


def hcl_sub_block(body: str, name: str) -> str | None:
    """A nested `name { ... }` block inside body, braces included, or None."""
    m = re.search(r"^[ \t]*" + re.escape(name) + r"[ \t]*\{", body, re.M)
    return None if m is None else brace_block(body[m.end() - 1 :], f"a {name} block")


def one_resource(src: str, path: str, rtype: str, why: str) -> str:
    """The body of the single resource of this type, or a loud failure."""
    found = hcl_resources(src, rtype)
    if len(found) != 1:
        raise GuardError(
            f"{path}: found {len(found)} `{rtype}` resources, expected exactly 1.\n\n"
            f"  {why}\n"
            "  A renamed, deleted or duplicated resource leaves this guard scanning something other\n"
            "  than what customers apply, which is worse than no guard at all."
        )
    return found[0][1]


# --------------------------------------------------------------------------------------
# GCP -- Terraform
# --------------------------------------------------------------------------------------

# GCP has TWO independent places to lose the confinement, and neither alone confines the org:
# the provider's attribute_condition (which decides whether the token is admitted to the pool at
# all) and the service account's workloadIdentityUser binding (which decides which pool principal
# may impersonate it). The industry copy-paste for the second is
# `principalSet://.../workloadIdentityPools/<pool>/*` -- every subject in the pool -- so a
# customer who both drops the condition and takes the wildcard is impersonable by any org in the
# fleet. Both are checked, and so is the WIRING between them.
# The condition is held to a CLOSED GRAMMAR -- the whole value, not a substring anywhere in it.
# CEL has no wildcard to spot: `true || assertion.sub == '<this org>'` contains the right comparison,
# mentions the right org, calls no function, and admits every subject the issuer will ever sign. So
# the guard requires the condition to BE the comparison rather than to contain one, which also stops
# `startsWith`/`matches`/`in` without having to enumerate CEL's operators.
# `[^']*`, not `.+`: a greedy capture would swallow the closing quote and let
# `assertion.sub == '<this org>' || assertion.sub != ''` match, which is the whole fleet again.
GCP_CONDITION_RE = re.compile(r"^\"assertion\.sub == '([^']*)'\"$")
GCP_CONDITION_SHAPE = "assertion.sub == '<subject>'"
WORKLOAD_IDENTITY_ROLE = "roles/iam.workloadIdentityUser"


def check_gcp_terraform(artifact: "Artifact", source: str) -> list[str]:
    path = artifact.path
    src = strip_hcl_comments(source)
    locals_ = hcl_locals(src)
    fails: list[str] = []

    provider = one_resource(
        src, path, "google_iam_workload_identity_pool_provider",
        "This is the block that decides whether a token is admitted to the pool at all.",
    )
    pool = one_resource(
        src, path, "google_iam_workload_identity_pool",
        "The binding below names a principal inside one pool; two pools make that ambiguous.",
    )
    binding = one_resource(
        src, path, "google_service_account_iam_member",
        "This is the binding that decides which pool principal may impersonate the service account.",
    )

    # 1. The provider admits ONE subject.
    cond = hcl_attr(provider, "attribute_condition")
    if cond is None:
        fails.append(
            f"{path}: the workload identity pool provider sets no `attribute_condition`.\n\n"
            "  Without it the pool admits EVERY subject the Ringleader issuer will ever sign, i.e.\n"
            "  every other customer's org -- and the binding below is then the only thing between\n"
            "  them and this customer's service account.\n\n"
            f"  Restore:\n{artifact.restore}"
        )
    else:
        shape = GCP_CONDITION_RE.match(cond.strip())
        if shape is None:
            fails.append(
                f"{path}: the `attribute_condition` is {cond}, which is not exactly\n"
                f"  `{GCP_CONDITION_SHAPE}`.\n\n"
                "  It is held to that one form deliberately. CEL has no wildcard to spot: a condition can\n"
                "  match loosely (startsWith, endsWith, matches, in) or simply be OR-ed with something\n"
                "  always true -- `true || assertion.sub == '<this org>'` names the right org, calls no\n"
                "  function, and admits the entire fleet. Enumerating the ways to weaken CEL is a losing\n"
                "  game, so the guard checks the condition IS the equality rather than contains one."
            )
        else:
            fails += judge_resolved(
                path, "the `attribute_condition`'s subject",
                resolve_hcl(shape.group(1), locals_, path, "the attribute_condition's subject"),
            )

    # 2. The token was minted for GCP, not replayed from another cloud.
    oidc = hcl_sub_block(provider, "oidc")
    if oidc is None:
        fails.append(
            f"{path}: the workload identity pool provider has no `oidc` block, so nothing pins the\n"
            "  issuer or the audience."
        )
    else:
        auds = hcl_attr(oidc, "allowed_audiences")
        if auds is None:
            fails.append(
                f"{path}: the provider sets no `allowed_audiences`.\n\n"
                "  GCP then accepts the pool's DEFAULT audience as well, so an assertion minted for\n"
                "  another cloud -- same org, same issuer -- can be replayed here."
            )
        else:
            items = hcl_list_items(auds, path, "`allowed_audiences`")
            if len(items) != 1:
                fails.append(
                    f"{path}: `allowed_audiences` carries {len(items)} values ({auds}). Pin exactly one."
                )
            else:
                fails += judge_resolved(
                    path, "the audience",
                    resolve_hcl(items[0], locals_, path, "the audience"), "/gcp",
                )
        issuer = hcl_attr(oidc, "issuer_uri")
        if issuer is None:
            fails.append(f"{path}: the provider sets no `issuer_uri`.")
        else:
            fails += judge_resolved(
                path, "the issuer_uri", resolve_hcl(issuer, locals_, path, "the issuer_uri"),
            )

    # 3. Only this org's principal may impersonate the service account.
    role = hcl_attr(binding, "role")
    if role is None or WORKLOAD_IDENTITY_ROLE not in role:
        fails.append(
            f"{path}: the service account IAM member does not grant `{WORKLOAD_IDENTITY_ROLE}`\n"
            f"  (role = {role}).\n\n"
            "  That is the binding this guard exists to read. If impersonation moved to another\n"
            "  resource, move the guard with it rather than leaving this one scanning nothing."
        )
    member = hcl_attr(binding, "member")
    if member is None:
        fails.append(f"{path}: the service account IAM member sets no `member`.")
    else:
        resolved = resolve_hcl(member, locals_, path, "the binding's member")
        if "principalSet:" in resolved:
            fails.append(
                f"{path}: the workloadIdentityUser binding uses a `principalSet://` member\n"
                f"  ({resolved}).\n\n"
                "  A principalSet is a SET of subjects -- the copy-paste form is\n"
                "  `principalSet://.../workloadIdentityPools/<pool>/*`, which is every org in the pool.\n"
                "  Bind the single `principal://.../subject/org:<uid>` instead.\n\n"
                f"  Restore:\n{artifact.restore}"
            )
        elif "/subject/" not in resolved:
            fails.append(
                f"{path}: the workloadIdentityUser binding's member is {resolved}, which names no\n"
                "  `/subject/`.\n\n"
                "  Only a member that names ONE subject confines impersonation to this customer's org."
            )
        fails += judge_resolved(path, "the binding's member", resolved)

        # 4. The WIRING. A perfectly pinned condition on a provider in one pool proves nothing if
        #    the binding admits a principal from a DIFFERENT pool -- one that may carry no
        #    condition at all. Both must name the same pool resource.
        pool_names = [n for n, _ in hcl_resources(src, "google_iam_workload_identity_pool")]
        pool_ref = f"google_iam_workload_identity_pool.{pool_names[0]}"
        if pool_ref not in member:
            fails.append(
                f"{path}: the workloadIdentityUser member does not derive its pool from\n"
                f"  `{pool_ref}` (member = {member}).\n\n"
                "  The guarded `attribute_condition` belongs to a provider in THAT pool. A member\n"
                "  naming another pool -- or a hardcoded pool path -- is admitted by whatever\n"
                "  condition that pool's provider carries, which is not the one checked above."
            )
        provider_pool = hcl_attr(provider, "workload_identity_pool_id")
        if provider_pool is None or pool_ref not in provider_pool:
            fails.append(
                f"{path}: the guarded provider is not attached to `{pool_ref}`\n"
                f"  (workload_identity_pool_id = {provider_pool}).\n\n"
                "  Then the condition checked above governs a pool nothing here binds, and the pool the\n"
                "  binding does name is governed by a provider this guard never read."
            )
    _ = pool
    return fails


# --------------------------------------------------------------------------------------
# GCP -- the gcloud script
# --------------------------------------------------------------------------------------

# The second supported GCP path, and it AUTHORS the same two pins rather than applying the
# module -- so a guard that read only the Terraform would be half-blind, exactly as it would have
# been on AWS had it read only the module and not the CloudFormation template.
# Assignments are found over the SAME fragments the flag reader uses, not over raw lines. Two
# readers with two notions of "a command" is how a bypass survives: a line-oriented reader misses
# `true; SUBJECT="org:VICTIM"`, `if true; then SUBJECT=...; fi` and `x && SUBJECT=...`, all of which
# assign, while `shell_commands` already cuts exactly there. The exactly-one rule below is then
# meaningful -- a second assignment in ANY spelling is loud, and the LAST one is what the script
# would actually run with.
#

# What each pin must be, exactly. "Contains ${ORG_UID}" is not "is this org":
# `SUBJECT="org:VICTIM${zz:+${ORG_UID}}"` carries the text, carries no wildcard, and expands to
# `org:VICTIM` -- the shell twin of the `element([...])` decoy the HCL side refuses through CALL_RE.
SH_WANT_SUBJECT = "org:${ORG_UID}"
SH_WANT_AUDIENCE = "${ISSUER}/gcp"

# The two variables every pin above RESOLVES THROUGH. Holding SUBJECT to `org:${ORG_UID}` and ISSUER
# to `${ISSUER_URL}/org/${ORG_UID}` means the whole trust rests on these -- and a line reading
# `ORG_UID="VICTIM"` before the derivations leaves every pinned string byte-exact while confining the
# customer's account to another org, or trusting an issuer somebody else signs for. Both scripts take
# them from the environment with `:?`, which is also what makes the script refuse to run unset.
SH_ROOT_VARS = {
    "ORG_UID": "${ORG_UID:?",
    "ISSUER_URL": "${ISSUER_URL:?",
}
SH_ORG_UID = "${ORG_UID}"
SH_ISSUER_URL = "${ISSUER_URL}"
SH_WANT_ISSUER = "${ISSUER_URL}/org/${ORG_UID}"
# Every gcloud provider write. The condition count is held equal to this, so a provider created
# without one is loud rather than invisible.
GCLOUD_PROVIDER_WRITE_RE = re.compile(r"workload-identity-pools[ \t]+providers[ \t]+(?:create|update)-oidc")


# --------------------------------------------------------------------------------------
# The two SHELL artifacts: a CLOSED GRAMMAR
# --------------------------------------------------------------------------------------

# Why a grammar and not a longer list of spellings. The pins below are read out of a shell
# script, and the previous reader looked for the ONE assignment to each name. That is a
# denylist: every shape it did not recognise -- `read -r SUBJECT <<<`, `printf -v SUBJECT`,
# `eval`, a `for` loop variable, a brace group, a function body, `source /dev/stdin`, a `case`
# arm -- rebound the name for real while the reader still counted one assignment and passed.
# Enumerating them does not terminate; bash has more ways to bind a name than anyone will list.
#
# So the direction is inverted. Every statement in the file must match one of the shapes below,
# and a statement that matches NONE is a hard GuardError -- the file is refused rather than
# scanned. That is the rule this module already applies to HCL and YAML, and it terminates:
# adding a shape is a deliberate edit to this list, and until someone makes it the guard says
# so out loud instead of reading past it.
#
# The alternative considered and rejected was to stop reading and EXECUTE the script, taking the
# values back out with `declare -p`. It cannot be out-spelled, which is genuinely attractive --
# but the `trust-pins` job runs on `pull_request`, so the script it would execute is the one the
# pull request just wrote. Running it turns a guard against a hostile contributor into arbitrary
# code execution BY that contributor, on the runner, and every external command (`gcloud`, `az`)
# would have to be stubbed convincingly enough that the prologue still reached the pins -- which
# needs the script parsed anyway. The grammar keeps the guard static.

# The names the grammar PROTECTS: a statement that binds one of these by any means other than a
# plain assignment is refused. It is a PARAMETER rather than a fixed set, because the same reader
# guards a different script for a different contract -- `check_published_literals.py` reads
# `network-landing-pad.sh` for the gateway network tag -- and a grammar whose protected names were
# baked in would classify `printf -v GATEWAY_TAG` as an ordinary command and hand that guard a
# value the script does not run with. Every entry point below takes `guarded` and passes it down.
PIN_VARS = frozenset({"SUBJECT", "ISSUER", "AUDIENCE", "ORG_UID", "ISSUER_URL"})

# Shell keywords and punctuation a statement may BE, or may begin with. `in` appears as the tail
# of a `case` head; `;;` and `esac`/`fi`/`done` close blocks.
SH_KEYWORDS = frozenset({
    "if", "then", "else", "elif", "fi", "while", "until", "do", "done",
    "case", "esac", "in", "!", "{", "}", ";;",
})

# Every command head these two scripts use, and nothing else. A new one is a deliberate addition
# here -- which is the point: the guard cannot be widened by accident, and until it is widened it
# refuses rather than reading past a command it does not know.
SH_COMMANDS = frozenset({
    ":", "true", "false", "exit", "return", "set", "shift", "cd", "umask",
    "echo", "printf", "cat", "grep", "sed", "awk", "tr", "cut", "head", "tail", "sort", "wc",
    "test", "[", "[[", "sleep", "date", "basename", "dirname",
    "mkdir", "rm", "mv", "cp", "chmod", "touch", "tee", "python3", "jq", "envsubst",
    "gcloud", "az", "aws",
})

# Words that bind a NAME without looking like an assignment. Each is refused outright when it
# names a pin; `printf` and `declare`-family words are in SH_COMMANDS / the assignment prefix for
# their ordinary uses, so they are caught by the shape check below rather than by the head alone.
SH_BINDERS = frozenset({"read", "eval", "source", ".", "mapfile", "readarray", "getopts",
                        "let", "unset", "coproc", "exec", "trap"})


# `for NAME in ...`, and the `select` that binds the same way.
SH_FOR_RE = re.compile(r"^(?:for|select)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
# A function definition in either spelling.
SH_FUNC_RE = re.compile(r"^(?:function\s+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\))")
# `printf -v NAME`, in any flag order.
# Arithmetic: `$(( ))`, the deprecated `$[ ]`, and a bare `(( ))` statement. Matched non-greedily;
# over-matching only ever makes the guard REFUSE more, which is the safe direction.
SH_ARITH_RE = re.compile(r"\$\(\(.*?\)\)|\$\[.*?\]|\(\(.*?\)\)", re.S)
SH_PRINTF_V_RE = re.compile(r"^printf\b(?=(?:\s+-\w+)*\s+-\w*v)")
SH_ASSIGN_STMT_RE = re.compile(
    r"^(?:(?:then|do|else|elif)[ \t]+)*"
    r"(?:(?:export|readonly|local|typeset|declare)(?:[ \t]+-[A-Za-z]+)*[ \t]+)*"
    r"([A-Za-z_][A-Za-z0-9_]*)(\+?=)(.*)$"
)
# A bare `NAME` given to declare/typeset/local/export WITHOUT `=` still binds it (to empty, or
# from the environment), and `unset` unbinds it. Both leave the pin's value not what was read.
SH_DECLARE_BARE_RE = re.compile(
    r"^(?:export|readonly|local|typeset|declare)(?:[ \t]+-[A-Za-z]+)*[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*$"
)


def _heredoc_delims(line: str) -> list[str]:
    """Every heredoc delimiter opened on this line, spelled the way BASH forms it.

    A delimiter is ONE word, and bash builds it by concatenating adjacent quoted, unquoted and
    backslash-escaped fragments, then removing the quotes: `<<t"rue"` names `true`. Reading only the
    first fragment gives `t`, and strip_heredocs then swallows every line until one reads `t` --
    silently deleting REAL, executing statements, which hides a pin rebinding from every check in
    this file just as effectively as a hidden binder would.

    `<<<` is a HERESTRING and opens nothing. A `<<` inside quotes is text, not a redirection.

    """
    out: list[str] = []
    i, quote, subst = 0, "", []
    while i < len(line):
        ch = line[i]
        # `$(` re-enters COMMAND context even from inside a double quote, which is exactly how the
        # shipped `az ... --parameters "$(cat <<JSON` opens its heredoc. Missing that reads the
        # opener as text and leaves a real body to be judged as statements. Inside SINGLE quotes
        # nothing expands, so `$(` there is literal.
        if n := _escape_span(line, i, quote):
            i += n
            continue
        if quote != "'" and ch == "$" and line[i + 1:i + 2] == "(":
            subst.append(quote)
            quote = ""
            i += 2
            continue
        if quote:
            if ch == quote and _quote_closes(line, i, quote):
                quote = ""
            i += 1
            continue
        if ch == ")" and subst:
            quote = subst.pop()
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            i += 1
            continue
        if line[i:i + 2] != "<<":
            i += 1
            continue
        j = i + 2
        if j < len(line) and line[j] == "<":  # `<<<`, a herestring
            i = j + 1
            continue
        if j < len(line) and line[j] == "-":
            j += 1
        while j < len(line) and line[j] in " \t":
            j += 1
        word: list[str] = []
        while j < len(line):
            c = line[j]
            if c in " \t;&|<>()":
                break
            if c in "\"'":
                k = line.find(c, j + 1)
                if k < 0:
                    j = len(line)
                    break
                word.append(line[j + 1:k])
                j = k + 1
                continue
            if c == "\\" and j + 1 < len(line):
                word.append(line[j + 1])
                j += 2
                continue
            word.append(c)
            j += 1
        if word:
            out.append("".join(word))
        i = max(j, i + 2)
    return out


def strip_heredocs(src: str) -> str:
    """Remove heredoc BODIES, which are data and not commands.

    Without this the grammar below would judge `"subject": "${SUBJECT}",` -- a line inside the
    JSON `az` is handed -- as a command, and refuse a correct file. `<<<` is a HERESTRING and is
    deliberately not matched: it is an ordinary redirection whose word stays on the line, and
    `read -r SUBJECT <<< "..."` must reach the grammar to be refused.
    """
    lines = src.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = _heredoc_delims(line)
        i += 1
        for delim in delims:
            while i < len(lines) and lines[i].strip() != delim:
                i += 1
            i += 1  # step over the terminator itself
    return "\n".join(out)


def _quote_closes(text: str, i: int, quote: str) -> bool:
    """Does the quote at `text[i]` CLOSE the open string, or is it escaped?

    Only a DOUBLE quote can be escaped, and only by an ODD run of backslashes: `\\"` is an escaped
    quote, `\\\\"` is an escaped BACKSLASH followed by a real closing quote. A one-character lookback
    cannot tell those apart, and reading `\\\\"` as "still open" makes the splitter swallow every
    following line into one statement -- so `echo "note\\\\"` on one line hides an ordinary
    `SUBJECT="org:VICTIM"` on the next from every check in this file. Inside SINGLE quotes bash
    escapes nothing at all, so the first `'` always closes.
    """
    if quote == "'":
        return True
    n, j = 0, i - 1
    while j >= 0 and text[j] == "\\":
        n += 1
        j -= 1
    return n % 2 == 0


# The only constructs that can carry a statement across a line break or hold a `;` that does not
# separate statements. TYPED, and the type is load-bearing: bash treats a BARE `(` or `[` as an
# ordinary word character, so a scanner that counted one as "unclosed" would keep swallowing lines
# after `echo ok [` -- and an ordinary `SUBJECT="org:VICTIM"` on the next line then becomes part of
# an `echo`, invisible to every check in this file while bash runs it. Making a real statement
# invisible is worth exactly as much to an attacker as a hidden binder.
SH_SUBSTITUTIONS = (("$((", "))"), ("$(", ")"), ("${", "}"), ("$[", "]"))


def _scan_shell(text: str, i: int, quote: str, stack: list[str]) -> tuple[int, str, list[str]]:
    """Advance one token from `text[i]`, maintaining the quote state and the substitution stack.

    Returns the next index and the updated state. The caller decides what to do at a position where
    `quote` is empty and `stack` is empty -- that, and only that, is shell TOP LEVEL.
    """
    ch = text[i]
    if n := _escape_span(text, i, quote):
        return i + n, quote, stack
    if quote:
        if ch == quote and _quote_closes(text, i, quote):
            quote = ""
        return i + 1, quote, stack
    if stack and text.startswith(stack[-1], i):
        closer = stack.pop()
        return i + len(closer), quote, stack
    for opener, closer in SH_SUBSTITUTIONS:
        if text.startswith(opener, i):
            stack.append(closer)
            return i + len(opener), quote, stack
    if ch == "`":
        # A backtick substitution is its own terminator, so it behaves like a quote here.
        return i + 1, "`", stack
    if ch in "\"'":
        return i + 1, ch, stack
    return i + 1, quote, stack


def _escape_span(text: str, i: int, quote: str) -> int:
    """How many characters the backslash at `text[i]` consumes -- 0 if it is not an escape here.

    The OPEN direction, and `_quote_closes` is only the close one. Nothing checked whether the quote
    that OPENS a string is itself escaped, so `echo \\'` -- a complete bash statement printing one
    apostrophe -- left every scanner in single-quote state and swallowed the following line into that
    `echo`. A second `echo \\'` re-closed it, so the swallow was SURGICAL: exactly the injected
    `SUBJECT="org:VICTIM"` disappeared and the rest of the file parsed normally, with `bash -n` and
    both guards green. Making a real statement invisible is worth exactly as much to an attacker as a
    hidden binder.

    Inside SINGLE quotes bash escapes nothing, so a backslash there is an ordinary character.
    Everywhere else -- top level, inside a double quote, inside a backtick -- `\\x` is a literal x.

    """
    if text[i] != "\\" or quote == "'":
        return 0
    return 2 if i + 1 < len(text) else 1


def _balanced(text: str) -> bool:
    """Is every quote closed and every `$(`/`${`/`$[` matched? Used to rejoin a wrapped statement."""
    quote: str = ""
    stack: list[str] = []
    i = 0
    while i < len(text):
        i, quote, stack = _scan_shell(text, i, quote, stack)
    return not quote and not stack


def shell_statements(src: str) -> list[str]:
    """Every statement in the file, heredoc bodies removed and wrapped lines rejoined.

    This is the population the grammar accounts for. `shell_commands` splits the same way and is
    what each `gcloud`/`az` invocation's flags are read from; the difference is only that this one
    refuses to lose a fragment -- a statement that reaches no shape is a GuardError.
    """
    joined: list[str] = []
    buf = ""
    for line in strip_heredocs(src).split("\n"):
        line = line.rstrip()
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        candidate = buf + line
        buf = ""
        # A statement carried over a line break inside `$( )` or a quote -- the `$(cat <<JSON`
        # shape, whose closing `)"` sits on its own line once the body is gone.
        if joined and not _balanced(joined[-1]):
            joined[-1] += " " + candidate
        else:
            joined.append(candidate)
    if buf:
        joined.append(buf)

    out: list[str] = []
    for line in joined:
        quote, stack, start, i = "", [], 0, 0
        while i < len(line):
            ch = line[i]
            if not quote and not stack and ch in ";&|" and not (ch == "&" and i and line[i - 1] in "<>"):
                # ...but `2>&1` and `>&2` are REDIRECTIONS: the `&` there belongs to the
                # redirection, and cutting on it leaves a bare `1`/`2` that is not a statement.
                out.append(line[start:i])
                i += 2 if line[i: i + 2] in ("&&", "||", ";;") else 1
                start = i
                continue
            i, quote, stack = _scan_shell(line, i, quote, stack)
        out.append(line[start:])
    return [c for c in out if c.strip()]


SH_REDIRECT_RE = re.compile(r"(?:\d?>>?&?\d*|\d?<<<|\d?<&?\d*)\s*[^\s|;&]*\s*$")


def _strip_redirections(s: str) -> str:
    """Drop trailing redirections. `echo x >&2` and `cmd >/dev/null 2>&1` are the command they
    decorate; a redirection never binds a name, so it is noise to the grammar. `<<<` is NOT
    stripped -- a herestring is how `read -r SUBJECT <<< "..."` feeds a rebinding, and that
    statement has to reach the refusal below intact."""
    prev = None
    while prev != s:
        prev = s
        if "<<<" in s:
            break
        s = SH_REDIRECT_RE.sub("", s).rstrip()
    return s


SH_CASE_HEAD_RE = re.compile(r"^case\s+\S+\s+in\b\s*")
SH_CASE_ARM_RE = re.compile(r"^[^()\s]+\)\s*")
SH_WRAPPER_RE = re.compile(r"^(?:if|then|else|elif|while|until|do|!|\{|\()\s+")
# Words whose whole job is to RUN the command after them. Peeled, never accepted as the head:
# `command eval SUBJECT=org:VICTIM` and `time eval ...` rebind the pin exactly as the bare
# `eval` does, and a grammar that stopped at the prefix classified them as an allowed command.
SH_RUNNER_RE = re.compile(r"^(?:command|builtin|time|env|nice|nohup|stdbuf|timeout|xargs|sudo|doas)(?:\s+-\S+)*\s+")


def _peel(stmt: str) -> str:
    """Strip everything that WRAPS a command, leaving the command itself.

    Four wrappers, peeled until none is left: a keyword prefix (`then cmd`, `{ cmd`), a RUNNER
    (`command cmd`, `time cmd`, `env cmd`), a `case X in` head, and a `case` arm's `<pattern>)`. Peeling matters because each of them can carry an
    assignment -- `case x in x) SUBJECT=...` binds the pin for real, and judging the statement on
    its first word alone would classify it as the keyword `case` and never look inside.
    """
    s = _strip_redirections(stmt.strip())
    while True:
        for pattern in (SH_WRAPPER_RE, SH_RUNNER_RE, SH_CASE_HEAD_RE, SH_CASE_ARM_RE):
            m = pattern.match(s)
            if m and not (pattern is SH_CASE_ARM_RE and s.startswith("(")):
                s = s[m.end():]
                break
        else:
            return s


def _head_words(stmt: str) -> list[str]:
    """The statement's leading words, with every wrapper removed."""
    return _peel(stmt).split()


SH_CLOSERS = {"(": ")", "[": "]", "{": "}"}
SH_DECLARE_KW_RE = re.compile(r"^(?:export|readonly|local|typeset|declare)(?:[ \t]+-[A-Za-z]+)*[ \t]+")
SH_ONE_ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=")


def _peel_assignments(s: str, path: str, stmt: str) -> tuple[list[tuple[str, str]], str]:
    """Peel every leading `NAME=VALUE`, returning the pairs and whatever COMMAND follows them.

    Shell allows a run of assignments before a command, and the two mean different things: with no
    command they persist, with one they are scoped to it. Reading only the first `NAME=` and calling
    the whole statement an assignment is what let `IFS= read -r SUBJECT <<< "..."` through -- an
    assignment to IFS, and then a binder the reader never reached.
    """
    s = SH_DECLARE_KW_RE.sub("", s.strip(), count=1)
    pairs: list[tuple[str, str]] = []
    while True:
        m = SH_ONE_ASSIGN_RE.match(s)
        if not m:
            return pairs, s.strip()
        # The value runs to the first UNQUOTED, UNNESTED space. `$( )`, `${ }` and `$[ ]` nest, so
        # `$(gcloud iam ... )` is ONE word however many spaces it contains.
        #
        # Only a `$`-introduced bracket nests, and the closers are TYPE-MATCHED through a stack.
        # Pooling `(`, `[` and `{` into one untyped counter meant a bare `{` in a value raised the
        # depth with nothing to lower it, so `JUNK={ SUBJECT="org:VICTIM"` swallowed the second
        # assignment into JUNK's value -- while bash reads it as two assignments and rebinds the
        # pin for real. At top level a bare bracket is an ordinary character and does NOT nest;
        # inside a substitution it does, which is what makes `$(( ))` balance.
        i, quote, stack = m.end(), "", []
        while i < len(s):
            ch = s[i]
            if n := _escape_span(s, i, quote):
                i += n
                continue
            if quote:
                if ch == quote and _quote_closes(s, i, quote):
                    quote = ""
            elif ch in "\"'":
                quote = ch
            elif ch == "$" and i + 1 < len(s) and s[i + 1] in "([{":
                stack.append(SH_CLOSERS[s[i + 1]])
                i += 2
                continue
            elif stack and ch in "([{":
                stack.append(SH_CLOSERS[ch])
            elif stack and ch == stack[-1]:
                stack.pop()
            elif not stack and ch in " \t":
                break
            i += 1
        if stack or quote:
            # The value never closed. Bash would refuse the script outright, and the scanner has
            # just swallowed the rest of the statement into this value -- which is exactly how a
            # second assignment hides. Refuse rather than judge what is left.
            raise GuardError(_shape_refusal(
                path, stmt, "an assignment whose value has an unterminated quote or `$(`/`${`"))
        pairs.append((m.group(1), s[m.end():i].strip()))
        s = s[i:].lstrip()
        if not s:
            return pairs, ""


def classify_shell_statement(
    stmt: str, path: str, guarded: frozenset[str] = PIN_VARS
) -> tuple[str, list[tuple[str, str]]]:
    """Match ONE shape, or raise. Returns (kind, name, value); name/value only for an assignment.

    Kinds: `assign` (with its (name, value) pairs), `command`, `keyword`. Anything else is
    refused -- loudly, by construction.
    """
    if not stmt.strip():
        return ("keyword", [])

    # Judge what the statement RUNS, not what wraps it: `then SUBJECT=...`, `{ SUBJECT=...` and
    # `case x in x) SUBJECT=...` all bind the pin, and all three hide it behind a wrapper.
    s = _peel(stmt)
    if s.strip() in ("", "}", ")", "fi", "done", "esac", ";;") or s.strip() in SH_KEYWORDS:
        return ("keyword", [])

    named = sorted(guarded.intersection(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", s)))

    # A `${NAME:=value}` expansion ASSIGNS -- it is an assignment wearing an expansion's clothes,
    # and it can sit inside an argument to a command this grammar happily allows (`echo`).
    for pin in named:
        if re.search(r"\$\{" + pin + r"[ \t]*:?=", s):
            raise GuardError(
                _binding_refusal(path, stmt, "a `${NAME:=...}` assigning expansion", pin, guarded)
            )

    # An ARITHMETIC context assigns too, and it hides inside the VALUE of an ordinary assignment
    # where nothing was looking: `JUNK=$((SUBJECT=1337))` rebinds SUBJECT for real and persistently
    # (bash's arithmetic assignment is a shell side effect, not a subshell's), while the statement
    # reads as one clean assignment to JUNK. Every pin here is a STRING -- an org id, a URL -- so a
    # pin inside `(( ))` is never legitimate whatever operator follows it, and the whole context is
    # refused rather than the operators being enumerated.
    for m_arith in SH_ARITH_RE.finditer(s):
        inside = sorted(guarded.intersection(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m_arith.group(0))))
        if inside:
            raise GuardError(
                _binding_refusal(path, stmt, "an arithmetic context", ", ".join(inside), guarded)
            )

    # A NAMEREF makes one name an alias for another, so a later ordinary assignment to the alias
    # rebinds the pin with the pin's own name nowhere in sight.
    if re.match(r"^(?:declare|local|typeset)(?:[ \t]+-[A-Za-z]*n[A-Za-z]*)+\b", s):
        raise GuardError(
            _binding_refusal(path, stmt, "a `declare -n` nameref", ", ".join(named) or "a name", guarded)
        )

    # Process substitution runs a command list this reader is not parsing.
    if "<(" in s or ">(" in s:
        raise GuardError(_shape_refusal(path, stmt, "process substitution, whose body is not read"))

    # 1. ASSIGNMENTS -- the only shape allowed to bind a pin. A statement may carry SEVERAL, and
    #    may then run a COMMAND: `IFS= read -r SUBJECT <<< "..."` is an assignment to IFS followed
    #    by a binder, and matching only the first `NAME=` classified the whole statement as an
    #    assignment and never looked at the `read`. So peel every leading assignment and judge what
    #    is left.
    pairs, rest = _peel_assignments(s, path, stmt)
    if pairs and not rest:
        # A real, persisting assignment. More than one in a statement is fine (`A=1; B=2` splits
        # anyway); the caller counts them per name.
        return ("assign", pairs)
    if pairs and rest:
        # A PREFIX assignment: `FOO=1 cmd` scopes FOO to cmd alone and does not persist. Refused
        # outright when it names a pin -- it cannot rebind one, but a reader that has to reason
        # about which assignments persist is the reader this grammar exists to stop being.
        for name, _ in pairs:
            if name in guarded:
                raise GuardError(
                    _binding_refusal(path, stmt, "a command-scoped prefix assignment", name, guarded)
                )
        s = rest

    words = s.split()
    if not words:
        return ("keyword", [])
    head = words[0]

    # 2. Every other way of binding a name. Refused when it names a pin, and refused as an
    #    unreadable construct when it does not -- `eval` and `source` are not analysable at all.
    for pattern, why in (
        (SH_FOR_RE, "a loop variable"),
        (SH_FUNC_RE, "a function body"),
        (SH_PRINTF_V_RE, "`printf -v`"),
        (SH_DECLARE_BARE_RE, "a bare `declare`/`export` with no value"),
    ):
        m2 = pattern.match(s)
        if m2:
            bound = m2.group(1) if pattern in (SH_FOR_RE, SH_DECLARE_BARE_RE) else None
            if (bound in guarded) or (bound is None and named):
                raise GuardError(_binding_refusal(path, stmt, why, bound or ", ".join(named), guarded))
            if pattern is SH_FUNC_RE:
                raise GuardError(_shape_refusal(path, stmt, "a function definition"))
            return ("command", [])

    if head in SH_BINDERS:
        raise GuardError(
            _binding_refusal(path, stmt, f"`{head}`", ", ".join(named) or "a name", guarded)
        )

    # 3. A plain command this grammar knows.
    if head in SH_COMMANDS or head in SH_KEYWORDS:
        return ("command", [])

    raise GuardError(_shape_refusal(path, stmt, f"a command this guard does not know (`{head}`)"))


def _binding_refusal(
    path: str, stmt: str, why: str, names: str, guarded: frozenset[str] = PIN_VARS
) -> str:
    return (
        f"{path}: {names} is bound by {why}, not by an assignment:\n\n"
        f"    {stmt.strip()}\n\n"
        "  Every pin in this script is read from the ONE assignment to each name. A rebinding\n"
        "  spelled any other way changes the value the script actually runs with while leaving\n"
        "  that assignment textually perfect -- which is the whole shape of this attack. Only a\n"
        "  plain `NAME=value` may bind one of: " + ", ".join(sorted(guarded)) + "."
    )


def _shape_refusal(path: str, stmt: str, what: str) -> str:
    return (
        f"{path}: this statement is {what}:\n\n"
        f"    {stmt.strip()}\n\n"
        "  This guard reads the file against a CLOSED grammar: every statement must be an\n"
        "  assignment, a known command, or a shell keyword. A statement it cannot classify is\n"
        "  refused rather than skipped, because skipping is how a rebinding of the trust pins\n"
        "  hides. If the statement is legitimate, add its shape to SH_COMMANDS in this file --\n"
        "  deliberately, and with a test."
    )


def shell_assignments(
    src: str, path: str, guarded: frozenset[str] = PIN_VARS
) -> list[tuple[str, str]]:
    """Every assignment in the file, having first held every OTHER statement to the grammar."""
    out = []
    for stmt in shell_statements(src):
        kind, pairs = classify_shell_statement(stmt, path, guarded)
        if kind == "assign":
            out.extend(pairs)
    return out


def shell_commands(src: str) -> list[str]:
    """Join backslash-continued lines, so one `gcloud ...` invocation is one string.

    This is what lets each provider write be judged on ITS OWN flags rather than against a global
    tally. A tally can be restored by text that never executes -- a comment, a `: <<'DOC'` heredoc --
    while the command that actually runs has lost its pin; asking each command what IT carries cannot
    be fooled that way, because the flag has to sit in the invocation to have any effect.
    """
    joined, buf = [], ""
    for line in src.split("\n"):
        line = line.rstrip()
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        joined.append(buf + line)
        buf = ""
    if buf:
        joined.append(buf)

    # ...and a LINE is not a command. `gcloud ... ; : --attribute-condition "<the right value>"`
    # creates the provider with no condition while leaving the flag text on the same line for a
    # line-oriented reader to find. Split on the separators the shell splits on, quote- and
    # paren-aware so a `;` inside a string or a `$( )` does not cut a real command in half.
    out = []
    for line in joined:
        quote, stack, start = "", [], 0
        i = 0
        while i < len(line):
            ch = line[i]
            if not quote and not stack and ch in ";&|":
                # `;`, `&&`, `||` AND the bare `&` and `|`. A bare `&` backgrounds what precedes it
                # and starts a new command, so `gcloud ... & : --attribute-condition "<right value>"`
                # leaves the flag on the same LINE while gcloud never receives it -- the same decoy
                # the two-character separators already close, in the spelling they left out.
                out.append(line[start:i])
                i += 2 if line[i : i + 2] in ("&&", "||") else 1
                start = i
                continue
            i, quote, stack = _scan_shell(line, i, quote, stack)
        out.append(line[start:])
    return [c for c in out if c.strip()]


def strip_shell_comments(src: str) -> str:
    """Drop `#` comments outside quotes, the way the HCL and YAML readers already do.

    Not cosmetic, and it cuts BOTH ways. A weakening can be hidden by leaving the correct flag
    behind as a comment -- the count check below then sees the right number of conditions while the
    provider ships with none, which is the pool admitting every org the issuer will ever sign. And a
    perfectly ordinary doc comment mentioning `providers create-oidc` would otherwise turn a CORRECT
    file red, which is how a guard gets deleted rather than fixed.

    `#` opens a comment only at a word boundary in shell, so `10.0.0.0/8#x` and a `#` inside quotes
    are left alone.
    """
    out = []
    for line in src.split("\n"):
        quote = ""
        cut = -1
        i, skip = 0, 0
        while i < len(line):
            ch = line[i]
            if skip := _escape_span(line, i, quote):
                i += skip
                continue
            if quote:
                if ch == quote and _quote_closes(line, i, quote):
                    quote = ""
            elif ch in "\"'":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
            i += 1
        out.append(line if cut < 0 else line[:cut])
    return "\n".join(out)


def gcloud_flag_values(src: str, flag: str) -> list[str]:
    """Every value given to `--flag`, in EITHER spelling and EITHER quoting.

    `--flag value`, `--flag=value`, single-quoted and unquoted all reach gcloud identically -- and
    this very script already uses the `=` form elsewhere (`--condition=None`). A guard that read
    only `--flag "value"` would be blind to a weakening written the other way, which is a weakening
    that ships green.
    """
    pattern = re.compile(
        r"--" + re.escape(flag) + r"(?:=|[ \t]+)(\"[^\"]*\"|'[^']*'|[^\s\\]+)"
    )
    out = []
    for m in pattern.finditer(src):
        v = m.group(1)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out.append(v)
    return out


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def _shell_var(src: str, name: str, path: str) -> str:
    """The one value this name ends up bound to, read from a file held to the closed grammar.

    `shell_assignments` classifies EVERY statement first, so reaching this point already means no
    statement rebound the name by a shape an assignment regex cannot see. What is left to check is
    the ordinary one: exactly one assignment, because a second means the value that ships is not
    the one that was judged.
    """
    found = [_unquote(v) for n, v in shell_assignments(src, path) if n == name]
    if len(found) != 1:
        raise GuardError(
            f"{path}: found {len(found)} `{name}=` assignments, expected exactly 1.\n\n"
            "  Every pin below is spelled in terms of it, so the guard resolves it before judging --\n"
            "  a second assignment means the value that ships is not the one that was read."
        )
    return found[0]


def judge_shell_roots(path: str, source: str) -> list[str]:
    """`SUBJECT` and `ISSUER` are exact -- so the attack moves to what they interpolate."""
    fails = []
    for name, prefix in SH_ROOT_VARS.items():
        value = _shell_var(source, name, path)
        if not value.startswith(prefix):
            fails.append(
                f"{path}: {name} is \"{value}\", which does not take the operator's own\n"
                f"  `{prefix}...}}` value.\n\n"
                "  Every pin in this script interpolates it, so a literal here leaves SUBJECT, ISSUER\n"
                "  and AUDIENCE byte-exact while confining the customer to another org -- or trusting\n"
                "  an issuer somebody else signs for. The `:?` form is also what makes the script\n"
                "  refuse to run when the operator has not supplied it."
            )
    return fails


def judge_shell_subject(path: str, subject: str) -> list[str]:
    """The subject pin, held to the exact string rather than to "mentions ORG_UID".

    `SUBJECT="org:VICTIM${zz:+${ORG_UID}}"` contains the text, carries no wildcard, and expands to
    `org:VICTIM` for every customer -- the shell twin of the function-call decoy CALL_RE refuses on
    the HCL side. Every pin below interpolates this one line, so it decides which org the whole
    script confines to.
    """
    if subject != SH_WANT_SUBJECT:
        return [
            f"{path}: SUBJECT is \"{subject}\", want exactly \"{SH_WANT_SUBJECT}\".\n\n"
            "  Anything else -- a hardcoded org, an expansion that merely mentions ${ORG_UID}, a\n"
            "  concatenation -- leaves every condition and binding below textually perfect while\n"
            "  pointing the whole script at one org that is not the customer's."
        ]
    return []


def judge_shell_issuer(path: str, issuer: str) -> list[str]:
    """The issuer is a pin too, and on the script paths it is the one nobody was reading.

    Both Terraform modules put `issuer`/`issuer_uri` through `judge_resolved`, so a repointed issuer
    is a guard failure there. Repointed HERE it is the same hole and worse: the cloud would then
    trust tokens minted by whoever controls that issuer, for this customer's account, and the
    subject pin below is no defence because the attacker chooses the subject too.
    """
    # Held to the exact string, not to "mentions both variables". A substring test accepts
    # `${ISSUER_URL}.attacker.example/org/${ORG_UID}` -- which contains both, carries no wildcard,
    # and resolves to a host somebody else controls. Same reason GCP_CONDITION_RE matches the whole
    # condition: on a pin, "contains the right thing" is not "is the right thing".
    if issuer != SH_WANT_ISSUER:
        return [
            f"{path}: ISSUER is \"{issuer}\", want exactly \"{SH_WANT_ISSUER}\".\n\n"
            "  The per-ORG issuer is what makes the trust per-org at all. Anything else -- a fleet-wide\n"
            "  issuer, a suffix onto a host somebody else controls, a path that climbs out -- has the\n"
            "  cloud trust tokens this customer's org did not mint, and the subject pin is no defence\n"
            "  because whoever mints them picks the subject as well."
        ]
    return []


def check_gcp_gcloud(artifact: "Artifact", source: str) -> list[str]:
    path = artifact.path
    source = strip_shell_comments(source)
    fails = judge_shell_roots(path, source)

    subject = _shell_var(source, "SUBJECT", path)
    audience = _shell_var(source, "AUDIENCE", path)
    issuer = _shell_var(source, "ISSUER", path)

    # The pins are written as "${SUBJECT}", so what they MEAN is decided here, one line above.
    fails += judge_shell_subject(path, subject)
    if audience != SH_WANT_AUDIENCE:
        fails.append(
            f"{path}: AUDIENCE is \"{audience}\", want exactly \"{SH_WANT_AUDIENCE}\".\n\n"
            "  The issuer stamps a per-cloud audience; another cloud's here lets an assertion minted\n"
            "  for AWS or Azure -- same org, same issuer -- be replayed at GCP. Held to the exact\n"
            "  string for the same reason SUBJECT is: an expansion that merely mentions ${ISSUER} can\n"
            "  still evaluate to something else."
        )
    fails += judge_shell_issuer(path, issuer)

    # EVERY provider write, judged on its OWN flags. This script writes the pool provider twice --
    # the create path and the update path -- and an operator re-running onboarding takes the second,
    # so a weakening on either is a weakened pin for whoever hits it.
    writes = [c for c in shell_commands(source) if GCLOUD_PROVIDER_WRITE_RE.search(c)]
    if not writes:
        raise GuardError(
            f"{path}: no `workload-identity-pools providers create-oidc`/`update-oidc` call at all.\n\n"
            "  Either the pool provider stopped being created here, or the command was renamed. Both\n"
            "  leave this guard reading nothing about a pool that admits every subject the Ringleader\n"
            "  issuer will ever sign."
        )
    want = f"assertion.sub == '${{SUBJECT}}'"
    for i, cmd in enumerate(writes):
        # `$( : --attribute-condition "<the right value>" )` -- or the backtick spelling -- puts the
        # flag text inside a SUBSTITUTION, which gcloud never receives, while a reader scanning the
        # fragment's text finds it and counts it. Paren depth is tracked by the splitter, so no cut
        # happens either. Refused outright rather than half-supported: a provider write has no need
        # of one, and a guard that cannot tell an argument from a substitution is not reading
        # arguments at all.
        if "$(" in cmd or "`" in cmd:
            fails.append(
                f"{path}: provider write #{i + 1} contains a command substitution.\n\n"
                "  Its text is not necessarily its arguments -- a flag written inside `$( )` or\n"
                "  backticks reads correctly here and never reaches gcloud, which is a pool provider\n"
                "  created with no condition at all. Write the flags out literally."
            )
            continue
        conds = gcloud_flag_values(cmd, "attribute-condition")
        if len(conds) != 1:
            fails.append(
                f"{path}: provider write #{i + 1} carries {len(conds)} `--attribute-condition` flags,\n"
                "  expected exactly 1.\n\n"
                "  A provider written without one admits every subject the Ringleader issuer will ever\n"
                f"  sign.\n\n  Restore:\n{artifact.restore}"
            )
            continue
        if conds[0] != want:
            fails.append(
                f"{path}: provider write #{i + 1}'s `--attribute-condition` is \"{conds[0]}\", want\n"
                f"  exactly \"{want}\".\n\n"
                "  Anything but that equality admits more than this org -- CEL can match loosely\n"
                "  (startsWith, matches, in) or simply be OR-ed with something always true."
            )
        auds = gcloud_flag_values(cmd, "allowed-audiences")
        if len(auds) != 1:
            fails.append(
                f"{path}: provider write #{i + 1} carries {len(auds)} `--allowed-audiences` flags.\n\n"
                "  Without exactly one the pool accepts its default audience too, so an assertion minted\n"
                "  for another cloud -- same org, same issuer -- can be replayed here."
            )

    audiences = gcloud_flag_values(source, "allowed-audiences")
    for aud in audiences:
        if aud not in ("$AUDIENCE", "${AUDIENCE}"):
            fails.append(
                f"{path}: `--allowed-audiences` is \"{aud}\", want \"$AUDIENCE\" -- the value derived\n"
                "  once at the top of the script and judged above."
            )

    members = [m for m in gcloud_flag_values(source, "member") if m.startswith("principal")]
    if not members:
        raise GuardError(
            f"{path}: no `--member \"principal...\"` binding.\n\n"
            "  The workloadIdentityUser grant is what decides who may impersonate the service\n"
            "  account. If it moved, move this guard with it."
        )
    for member in members:
        if member.startswith("principalSet:") or any(ch in member for ch in "*?"):
            fails.append(
                f"{path}: the impersonation binding is \"{member}\".\n\n"
                "  `principalSet://.../workloadIdentityPools/<pool>/*` is every org in the pool -- the\n"
                "  industry copy-paste, and the cross-tenant hole.\n\n"
                f"  Restore:\n{artifact.restore}"
            )
        elif not member.endswith("/subject/${SUBJECT}"):
            fails.append(
                f"{path}: the impersonation binding is \"{member}\", which does not end\n"
                "  `/subject/${SUBJECT}` -- so it does not name this customer's org."
            )
    return fails


# --------------------------------------------------------------------------------------
# Azure
# --------------------------------------------------------------------------------------

# Azure matches the subject EXACTLY and offers no operator to weaken, so the loss mode is not a
# StringLike -- it is the field being widened, dropped, or repointed at another org. The
# federated credential is also useless unless it is attached to the application Ringleader is
# actually told to authenticate as, which is the wiring half.


def check_azure_terraform(artifact: "Artifact", source: str) -> list[str]:
    path = artifact.path
    src = strip_hcl_comments(source)
    locals_ = hcl_locals(src)
    fails: list[str] = []

    fic = one_resource(
        src, path, "azuread_application_federated_identity_credential",
        "This is the whole of Azure's federation trust: issuer, subject and audience in one block.",
    )
    app = one_resource(
        src, path, "azuread_application",
        "The credential below has to be attached to the one application Ringleader authenticates as.",
    )

    subject = hcl_attr(fic, "subject")
    if subject is None:
        fails.append(
            f"{path}: the federated identity credential sets no `subject`.\n\n"
            "  Azure then trusts any token from the issuer, and every Ringleader customer's token is\n"
            "  signed by that same issuer -- so every other tenant can authenticate as this app.\n\n"
            f"  Restore:\n{artifact.restore}"
        )
    else:
        fails += judge_resolved(
            path, "the credential's `subject`",
            resolve_hcl(subject, locals_, path, "the credential's subject"),
        )

    issuer = hcl_attr(fic, "issuer")
    if issuer is None:
        fails.append(f"{path}: the federated identity credential sets no `issuer`.")
    else:
        fails += judge_resolved(
            path, "the credential's `issuer`",
            resolve_hcl(issuer, locals_, path, "the credential's issuer"),
        )

    auds = hcl_attr(fic, "audiences")
    if auds is None:
        fails.append(f"{path}: the federated identity credential sets no `audiences`.")
    else:
        items = hcl_list_items(auds, path, "`audiences`")
        if len(items) != 1:
            fails.append(
                f"{path}: `audiences` carries {len(items)} values ({auds}).\n\n"
                "  Azure ORs them, so every extra entry is another audience the credential accepts."
            )
        else:
            resolved = resolve_hcl(items[0], locals_, path, "the credential's audience")
            if AZURE_AUDIENCE not in resolved:
                fails.append(
                    f"{path}: the credential's audience resolves to {resolved}, not `{AZURE_AUDIENCE}`.\n\n"
                    "  That is the value Entra requires for a workload-identity exchange. Another one\n"
                    "  either never matches -- the customer cannot boot a box -- or points the trust at a\n"
                    "  token minted for something else."
                )

    # The wiring. A perfectly pinned credential on a SECOND application is dead weight: the
    # application Ringleader is handed still carries whatever credentials it was given.
    app_names = [n for n, _ in hcl_resources(src, "azuread_application")]
    app_ref = f"azuread_application.{app_names[0]}"
    app_id = hcl_attr(fic, "application_id")
    if app_id is None or app_ref not in app_id:
        fails.append(
            f"{path}: the federated credential is not attached to `{app_ref}`\n"
            f"  (application_id = {app_id}).\n\n"
            "  Then the pin checked above governs an application nobody uses, while the one Ringleader\n"
            "  authenticates as carries credentials this guard never read."
        )
    _ = app
    return fails


# The ARM path creates the app + service principal + federated credential with `az` (they are
# Microsoft Graph directory objects, which an ARM template cannot create), so this SCRIPT carries
# the pin and azuredeploy.json -- which does the role assignment only -- carries none.
# The value Entra requires for a workload-identity exchange. Not per-org -- Azure's per-org
# confinement is the subject alone -- but a credential pinned to anything else either never matches
# or trusts a token minted for something other than this exchange.
AZURE_AUDIENCE = "api://AzureADTokenExchange"
AZ_FIC_SUBJECT_RE = re.compile(r'"subject"\s*:\s*"([^"]*)"')
AZ_FIC_ISSUER_RE = re.compile(r'"issuer"\s*:\s*"([^"]*)"')
AZ_FIC_AUDIENCES_RE = re.compile(r'"audiences"\s*:\s*\[([^\]]*)\]')


def check_azure_arm_script(artifact: "Artifact", source: str) -> list[str]:
    path = artifact.path
    source = strip_shell_comments(source)
    fails = judge_shell_roots(path, source)

    fails += judge_shell_issuer(path, _shell_var(source, "ISSUER", path))
    fails += judge_shell_subject(path, _shell_var(source, "SUBJECT", path))

    subs = AZ_FIC_SUBJECT_RE.findall(source)
    if not subs:
        raise GuardError(
            f"{path}: the federated credential body carries no `\"subject\"` field.\n\n"
            "  Azure's federation trust is that one field. If the credential moved or was renamed,\n"
            "  move this guard with it -- do not leave it scanning nothing.\n\n"
            f"  Restore:\n{artifact.restore}"
        )
    for sub in subs:
        if sub != "${SUBJECT}":
            fails.append(
                f"{path}: the federated credential's subject is \"{sub}\", want \"${{SUBJECT}}\".\n\n"
                "  Azure compares the subject byte for byte and offers no operator to loosen, so the\n"
                "  only ways to lose the confinement are to widen this field, drop it, or point it at\n"
                "  another org. Any of the three hands every Ringleader tenant this app."
            )

    issuers = AZ_FIC_ISSUER_RE.findall(source)
    if not issuers:
        fails.append(f"{path}: the federated credential body carries no `\"issuer\"` field.")
    for iss in issuers:
        if iss != "${ISSUER}":
            fails.append(
                f"{path}: the federated credential's issuer is \"{iss}\", want \"${{ISSUER}}\" -- the\n"
                "  per-org issuer derived at the top of the script."
            )

    audiences = AZ_FIC_AUDIENCES_RE.findall(source)
    if not audiences:
        fails.append(
            f"{path}: the federated credential body carries no `\"audiences\"` field.\n\n"
            "  Entra requires one for a workload-identity exchange, so a credential without it does\n"
            f"  not work -- and a guard that passed it would be reporting on a field it never read."
        )
    for auds in audiences:
        items = [i.strip() for i in auds.split(",") if i.strip()]
        if len(items) != 1:
            fails.append(
                f"{path}: the federated credential carries {len(items)} audiences ([{auds}]).\n\n"
                "  Azure ORs them; pin exactly one."
            )
        elif items[0].strip('"') != AZURE_AUDIENCE:
            fails.append(
                f"{path}: the federated credential's audience is {items[0]}, want\n"
                f"  \"{AZURE_AUDIENCE}\" -- the value Entra requires for this exchange."
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
    # How this artifact is checked. The AWS pair share one shape -- an IAM trust policy with
    # `:sub`/`:aud` conditions -- and default to it. GCP and Azure express the same property in
    # entirely different objects (a pool provider's CEL condition plus an impersonation binding; a
    # federated identity credential), so each brings its own, rather than the AWS checker growing
    # branches for shapes it has no business knowing about.
    check: object = None


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
    Artifact(
        path="gcp/terraform/main.tf",
        extract=None,
        judge=None,
        check=check_gcp_terraform,
        restore=(
            "  attribute_condition = \"assertion.sub == '${local.subject}'\"\n"
            "  ...\n"
            "  member = \"principal://iam.googleapis.com/"
            "${google_iam_workload_identity_pool.ringleader.name}/subject/${local.subject}\""
        ),
    ),
    Artifact(
        path="gcp/gcloud/onboard.sh",
        extract=None,
        judge=None,
        check=check_gcp_gcloud,
        restore=(
            "  --attribute-condition \"assertion.sub == '${SUBJECT}'\"\n"
            "  ...\n"
            "  --member \"principal://iam.googleapis.com/${POOL_NAME}/subject/${SUBJECT}\""
        ),
    ),
    Artifact(
        path="azure/terraform/main.tf",
        extract=None,
        judge=None,
        check=check_azure_terraform,
        restore=(
            "  issuer    = local.issuer\n"
            "  subject   = local.subject\n"
            "  audiences = [local.audience]"
        ),
    ),
    Artifact(
        path="azure/arm/deploy.sh",
        extract=None,
        judge=None,
        check=check_azure_arm_script,
        restore=(
            '  "issuer": "${ISSUER}",\n'
            '  "subject": "${SUBJECT}",\n'
            '  "audiences": ["api://AzureADTokenExchange"]'
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
    """Check one artifact's text with whatever checker it declares.

    Raises GuardError when the artifact cannot be scanned at all -- which is a failure, never a
    pass. A guard that silently scans a renamed block is worse than no guard.
    """
    return (artifact.check or check_aws_trust)(artifact, source)


def check_aws_trust(artifact: Artifact, source: str) -> list[str]:
    """The AWS pair: an IAM trust policy pinning the assertion's `:sub` and `:aud`."""
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
        print("The trust pins are not intact:\n", file=sys.stderr)
        for f in failures:
            print(f"  * {f}\n", file=sys.stderr)
        print(
            "Every Ringleader customer's assertion is signed by the same issuer. On every cloud the\n"
            "subject pin is the only thing separating one customer's account from the whole fleet.",
            file=sys.stderr,
        )
        return 1

    print(f"Trust pins intact in {len(ARTIFACTS)} artifacts:")
    for artifact in ARTIFACTS:
        print(f"  ok  {artifact.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
