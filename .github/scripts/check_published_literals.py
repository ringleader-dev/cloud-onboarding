#!/usr/bin/env python3
"""Fail the build if a landing pad stops naming a literal Ringleader actually sets.

Some strings in this repository are not settings. They are one half of a contract whose other
half is compiled into Ringleader, and the two halves are written in DIFFERENT REPOSITORIES that
are released independently. A landing pad names the value; Ringleader sets it on the machine.

The failure mode when they drift is the worst kind: **everything reports healthy and nothing
works.** A firewall rule admitting `ringleader-egress-gatway` is a valid rule. `terraform
validate` passes, `bash -n` passes, the rule appears in the console, Ringleader creates the
gateway VM, writes the steering route, and reports the gateway healthy -- because every object
it checks is exactly as it wrote it. Every packet a governed workstation sends is then dropped
at the gateway's own NIC. Nothing anywhere reports it.

And the drift CANNOT BE REPAIRED BY US. A landing pad is applied once, in the customer's own
cloud account, by the customer. We do not hold credentials there and cannot re-apply it. So a
value that has shipped is permanent in a way an internal constant never is: renaming it here
does not fix the customers who already applied the old one, it breaks them.

Two classes of literal, judged differently:

  * **Ringleader-set** -- Ringleader puts this value on the machine or dials this port, and the
    landing pad must admit exactly it. There is a second guard at the other end, in the
    ringleader repository, pinning the same string (`TestTheGatewayTagIsThePublishedLiteral`);
    together they mean a rename fails a test in whichever repo does the renaming, with the other
    end named in the message. Neither side may READ the other's file: agreeing by construction
    would prove nothing about the landing pads customers have ALREADY applied.
  * **Cross-path default** -- a tag the CUSTOMER puts on their own workstations, so the value is
    theirs to choose and Ringleader never sets it. What must not differ is the DEFAULT the two
    supported GCP paths ship, because a customer who follows the Terraform README and a customer
    who runs the shell script would otherwise get landing pads that are not the same landing pad.
    Renaming one of these is legitimate: rename it in every site below AND in this table, in one
    change.

Read as TEXT rather than executed, and every reader fails LOUDLY when its anchor is gone --
the same standing rules as `check_trust_pins.py`, whose HCL, YAML and shell readers this reuses
rather than growing a second copy of. The shell reader is that file's CLOSED GRAMMAR, so a
`GATEWAY_TAG` rebound by a `read`, a `printf -v` or an `eval` is refused here too.

Pinning a value nothing applies proves nothing, so each Ringleader-set literal is also checked
for its WIRING: the firewall rule that admits the tag must be the rule that names it.

Run it:   python3 .github/scripts/check_published_literals.py
Test it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from check_trust_pins import (
    GuardError,
    brace_block,
    gcloud_flag_values,
    hcl_attr,
    hcl_locals,
    hcl_resources,
    shell_assignments,
    shell_commands,
    strip_hcl_comments,
    strip_shell_comments,
    strip_yaml_comments,
)

REPO_ROOT = Path(__file__).resolve().parents[2]

GCP_TF = "gcp/terraform/main.tf"
GCP_VARS = "gcp/terraform/variables.tf"
GCP_SH = "gcp/gcloud/network-landing-pad.sh"
GCP_ONBOARD_SH = "gcp/gcloud/onboard.sh"
AWS_TF = "aws/terraform/main.tf"
AWS_CFN = "aws/cloudformation/ringleader-onboarding.yaml"
AZURE_TF = "azure/terraform/main.tf"
AZURE_ARM = "azure/arm/azuredeploy-network.json"


# --------------------------------------------------------------------------------------
# Readers -- one per shape, each loud when its anchor is gone
# --------------------------------------------------------------------------------------


def _unquote(value: str) -> str:
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def hcl_local(name: str):
    """The value of `<name> = ...` in a `locals` block, unquoted."""

    def read(source: str, path: str) -> str:
        locals_ = hcl_locals(strip_hcl_comments(source))
        if name not in locals_:
            raise GuardError(
                f"{path}: no `{name}` in any `locals` block.\n\n"
                "  It was renamed, moved out of `locals`, or spread over several lines. Any of the\n"
                "  three leaves this guard reading nothing, and a landing pad's literal unchecked."
            )
        return _unquote(locals_[name])

    return read


def hcl_variable_default(name: str):
    """The `default` of `variable "<name>" { ... }`, unquoted."""

    def read(source: str, path: str) -> str:
        src = strip_hcl_comments(source)
        m = re.search(r'variable\s+"' + re.escape(name) + r'"\s*\{', src)
        if m is None:
            raise GuardError(
                f"{path}: no `variable \"{name}\"` block.\n\n"
                "  If the variable was renamed, rename it in the shell path too and update this guard --\n"
                "  do not leave the guard reading nothing while the two GCP paths drift apart."
            )
        body = brace_block(src[m.end() - 1 :], f"variable {name}")
        default = hcl_attr(body, "default")
        if default is None:
            raise GuardError(
                f"{path}: `variable \"{name}\"` has no `default`.\n\n"
                "  The default is the whole point of the comparison: it is what a customer who sets\n"
                "  nothing gets, and it is what has to match the shell path's default."
            )
        return _unquote(default)

    return read


SH_DEFAULT_RE = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.*)\}$")


def shell_literal(name: str):
    """A shell variable bound to a BARE literal -- no `${NAME:-...}` override.

    A Ringleader-set value must not be a knob. `GATEWAY_TAG="${GATEWAY_TAG:-...}"` reads as
    helpful flexibility and is the outage in one line: an operator who exports the variable gets a
    firewall rule admitting a tag no gateway wears, and every check either side of it still passes.
    """

    def read(source: str, path: str) -> str:
        value = _one_shell_assignment(source, path, name)
        if SH_DEFAULT_RE.match(value):
            raise GuardError(
                f"{path}: `{name}` is `{value}`, an environment override.\n\n"
                "  This value is not the operator's to choose -- Ringleader sets it on the machine, and\n"
                "  the rule below has to admit exactly it. An override turns a silent, total outage into\n"
                "  something an exported variable can cause. Bind it to the literal."
            )
        return value

    return read


def shell_default(name: str):
    """The default of `NAME="${NAME:-default}"` -- a value the customer may override."""

    def read(source: str, path: str) -> str:
        value = _one_shell_assignment(source, path, name)
        m = SH_DEFAULT_RE.match(value)
        if m is None:
            raise GuardError(
                f"{path}: `{name}` is `{value}`, not the `${{{name}:-<default>}}` shape this guard reads.\n\n"
                "  The default is what has to match the Terraform variable's. Written another way it is\n"
                "  still a default, but this guard can no longer tell what it is -- and will not assume."
            )
        if m.group(1) != name:
            raise GuardError(
                f"{path}: `{name}` defaults through `${{{m.group(1)}:-...}}`, a different variable."
            )
        return m.group(2)

    return read


# The names this guard reads out of a shell script, handed to `check_trust_pins`' closed grammar
# so a statement binding one of them any other way -- `read`, `printf -v`, `eval`, a `for`
# variable -- is refused. That reader protects the names it is GIVEN; passing the trust guard's
# set would leave `printf -v GATEWAY_TAG ...` classified as an ordinary command, and this guard
# would then report the assignment it can see while the script runs with another value.
GUARDED_SHELL_VARS = frozenset({
    "GATEWAY_TAG", "SSH_TAG", "SECONDARY_SSH_TAG", "SECONDARY_SSH_PORT",
    "MANAGED_BUCKET_PREFIX",
})


def _one_shell_assignment(source: str, path: str, name: str) -> str:
    """The single assignment to `name`, having held every other statement to the closed grammar."""
    src = strip_shell_comments(source)
    found = [v for n, v in shell_assignments(src, path, GUARDED_SHELL_VARS) if n == name]
    if len(found) != 1:
        raise GuardError(
            f"{path}: found {len(found)} assignments to `{name}`, expected exactly 1.\n\n"
            "  None means it was renamed and this guard is reading nothing. Two means the second one\n"
            "  wins at runtime while a reader sees the first -- which is how a landing pad ships\n"
            "  admitting a value nobody intended."
        )
    return _unquote(found[0])


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def yaml_siblings(source: str, path: str, anchor: str, key: str) -> list[str]:
    """Every `<key>:` value sharing a mapping with a line reading exactly `<anchor>`.

    Walks by indent rather than parsing: the template carries CloudFormation's `!Ref` / `!If`
    short tags, which PyYAML will not load without constructors registered for each.
    """
    lines = [line for line in strip_yaml_comments(source).split("\n") if line.strip()]
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if not hits:
        raise GuardError(
            f"{path}: no line reading `{anchor}`.\n\n"
            "  That is how this guard finds the rule to judge. If the rule moved or was rewritten,\n"
            "  move this guard with it -- do not leave it scanning nothing."
        )
    out = []
    for hit in hits:
        depth = _indent(lines[hit])
        # The mapping's own keys are the contiguous run at this exact indent, in both directions.
        # A shallower line, or one opening a new sequence entry, ends the run.
        rows = [lines[hit]]
        for step in (-1, 1):
            i = hit + step
            while 0 <= i < len(lines) and _indent(lines[i]) >= depth:
                if _indent(lines[i]) == depth:
                    if lines[i].lstrip().startswith("-"):
                        break
                    rows.append(lines[i])
                i += step
        for row in rows:
            if row.strip().startswith(f"{key}:"):
                out.append(row.strip()[len(key) + 1 :].strip())
    if not out:
        raise GuardError(
            f"{path}: the rule at `{anchor}` carries no `{key}`.\n\n"
            "  Either the rule was restructured or the key was renamed. Both leave the port this\n"
            "  landing pad opens unchecked against the port Ringleader dials."
        )
    return out


def cfn_secondary_ssh_ports(source: str, path: str) -> str:
    """Every FromPort/ToPort on an ingress rule scoped to `SecondarySshSourceCidr`.

    Anchored on the parameter reference rather than on the port number: a guard that looked for
    `2222` would find the number it was hoping for and prove nothing about which rule carries it.
    """
    values = []
    for key in ("FromPort", "ToPort"):
        values += yaml_siblings(source, path, "CidrIp: !Ref SecondarySshSourceCidr", key)
    distinct = sorted(set(values))
    if len(distinct) != 1:
        raise GuardError(
            f"{path}: the secondary-SSH ingress rules open {distinct}, which is not one port.\n\n"
            "  The template has two security groups carrying the same pair of rules. They must open\n"
            "  the same port as each other and as Ringleader dials, or a workstation is reachable\n"
            "  through one group and not the other depending on which it was given."
        )
    return distinct[0]


def cfn_managed_bucket_prefix(source: str, path: str) -> str:
    """The bucket-name prefix every artifact-storage ARN in the template is bounded to.

    Anchored on the ARN shape rather than on a statement name, because the prefix is the whole
    bound: an ARN pattern is all that stops the grant from reaching a bucket the customer already
    has. Every occurrence must agree -- a bucket-level statement bounded to one prefix and an
    object-level statement bounded to another is a policy that lints clean and grants a shape
    nobody intended.
    """
    found = re.findall(r"arn:\$\{AWS::Partition\}:s3:::([A-Za-z0-9.\-]*)\*", strip_yaml_comments(source))
    if not found:
        raise GuardError(
            f"{path}: no `arn:${{AWS::Partition}}:s3:::<prefix>*` resource anywhere.\n\n"
            "  That pattern is the artifact-storage grant's only bound. If the statements were\n"
            "  restructured, move this guard with them -- an unread bound is an unchecked one."
        )
    distinct = sorted(set(found))
    if len(distinct) != 1:
        raise GuardError(
            f"{path}: the artifact-storage statements are bounded to {distinct}, which is not one\n"
            "  prefix. The bucket-level and object-level statements must name the same one, or the\n"
            "  grant reaches objects in buckets it cannot see and vice versa."
        )
    return distinct[0]


def arm_secondary_ssh_port(source: str, path: str) -> str:
    """The `destinationPortRange` of the ARM template's secondary-SSH security rules."""
    doc = json.loads(source)
    rules = doc.get("variables", {}).get("secondarySshRules")
    if not rules:
        raise GuardError(
            f"{path}: no `variables.secondarySshRules`.\n\n"
            "  That array is the secondary-SSH rule this template deploys. If it was renamed or\n"
            "  folded into another variable, move this guard with it."
        )
    ports = sorted({r.get("properties", {}).get("destinationPortRange") for r in rules})
    if len(ports) != 1 or ports[0] is None:
        raise GuardError(
            f"{path}: `secondarySshRules` opens {ports}, which is not one port."
        )
    return str(ports[0])


# --------------------------------------------------------------------------------------
# The literals
# --------------------------------------------------------------------------------------


@dataclass
class Site:
    path: str
    what: str
    read: object


@dataclass
class Literal:
    name: str
    value: str
    # Where the OTHER half of the contract lives, named in the failure message. Empty for a
    # cross-path default, which has no other half -- the sites below are all of it.
    other_half: str
    why: str
    sites: list[Site]


LITERALS = [
    Literal(
        name="the egress gateway's network tag",
        value="ringleader-egress-gateway",
        other_half="`gcegateway.NetworkTag` in the ringleader repository",
        why=(
            "Ringleader tags the egress gateway VM it builds in the customer's project with this\n"
            "  string, and `<prefix>-allow-gateway` is the rule that admits governed workstations to\n"
            "  it. A tag no gateway wears is a rule that admits nobody: the VM runs, the steering\n"
            "  route exists, every object check Ringleader makes passes, and every forwarded packet is\n"
            "  dropped at the gateway's own NIC. It cannot reuse the workstation tag -- the steering\n"
            "  route is scoped by tag, so a gateway wearing one would route its traffic into itself."
        ),
        sites=[
            Site(GCP_TF, "local.gateway_network_tag", hcl_local("gateway_network_tag")),
            Site(GCP_SH, "GATEWAY_TAG", shell_literal("GATEWAY_TAG")),
        ],
    ),
    Literal(
        name="the secondary SSH port",
        value="2222",
        other_half="`capsuleboot.SSHPort` in the ringleader repository",
        why=(
            "A workstation booted from an OCI image runs its own sshd on this port inside the VM,\n"
            "  beside the host's on 22, and `rl shell` dials it for those boxes. A landing pad opening\n"
            "  another port leaves them unreachable -- they boot, they converge, and no session ever\n"
            "  connects. It is deliberately not a parameter on any path: nobody has to know the number."
        ),
        sites=[
            Site(AWS_TF, "local.secondary_ssh_port", hcl_local("secondary_ssh_port")),
            Site(AWS_CFN, "the SecondarySshSourceCidr ingress rules", cfn_secondary_ssh_ports),
            Site(AZURE_TF, "local.secondary_ssh_port", hcl_local("secondary_ssh_port")),
            Site(AZURE_ARM, "variables.secondarySshRules", arm_secondary_ssh_port),
            Site(GCP_TF, "local.secondary_ssh_port", hcl_local("secondary_ssh_port")),
            Site(GCP_SH, "SECONDARY_SSH_PORT", shell_literal("SECONDARY_SSH_PORT")),
        ],
    ),
    Literal(
        name="the managed artifact-bucket prefix",
        value="ringleader-",
        other_half="`storagekind.ManagedBucketPrefix` in the ringleader repository",
        why=(
            "Under the MANAGED artifact-storage width Ringleader creates its own buckets, and each\n"
            "  landing pad confines that grant to buckets whose NAME starts with this string -- an IAM\n"
            "  condition on gcp, an ARN pattern on aws. It is the only bound there is, so the two ends\n"
            "  have to agree exactly: a pad admitting a different prefix grants an authority that\n"
            "  matches no bucket Ringleader will ever create, and every bucket create fails with a 403\n"
            "  that looks like a Ringleader bug rather than like a landing pad that needs re-applying.\n"
            "  Azure has no equivalent: its custom role is scoped to the resource group and Azure\n"
            "  offers no name-prefix condition on these control-plane actions."
        ),
        sites=[
            Site(GCP_TF, "local.managed_bucket_prefix", hcl_local("managed_bucket_prefix")),
            Site(GCP_ONBOARD_SH, "MANAGED_BUCKET_PREFIX", shell_literal("MANAGED_BUCKET_PREFIX")),
            Site(AWS_TF, "local.managed_bucket_prefix", hcl_local("managed_bucket_prefix")),
            Site(AWS_CFN, "the artifact-storage statements' bucket ARNs", cfn_managed_bucket_prefix),
        ],
    ),
    Literal(
        name="the workstation network tag's default",
        value="ringleader-workstation",
        other_half="",
        why=(
            "The customer puts this tag on their own workstations\n"
            "  (`providerConfig.gcp.networkTags`), so the value is theirs and Ringleader never sets it.\n"
            "  What must not differ is the DEFAULT the two supported GCP paths ship: the inbound-SSH\n"
            "  rule targets it, so a customer who followed the Terraform README and a customer who ran\n"
            "  the script would otherwise need different tags on their boxes to be reachable at all."
        ),
        sites=[
            Site(GCP_VARS, 'variable "workstation_network_tag"', hcl_variable_default("workstation_network_tag")),
            Site(GCP_SH, "SSH_TAG", shell_default("SSH_TAG")),
        ],
    ),
    Literal(
        name="the secondary-SSH network tag's default",
        value="ringleader-secondary-ssh",
        other_half="",
        why=(
            "The same shape as the workstation tag: the customer's to choose, but the two GCP paths\n"
            "  must ship the same default or the rule opening the secondary port reaches different\n"
            "  boxes depending on which path was followed."
        ),
        sites=[
            Site(GCP_VARS, 'variable "secondary_ssh_network_tag"', hcl_variable_default("secondary_ssh_network_tag")),
            Site(GCP_SH, "SECONDARY_SSH_TAG", shell_default("SECONDARY_SSH_TAG")),
        ],
    ),
]


# --------------------------------------------------------------------------------------
# Wiring -- the rule that admits the tag must be the rule that names it
# --------------------------------------------------------------------------------------

# Terraform: the firewall resource, the reference its `target_tags` must carry, and why.
TF_TAG_WIRING = [
    ("gateway", "local.gateway_network_tag"),
    ("ssh", "var.workstation_network_tag"),
    ("internal", "var.workstation_network_tag"),
    ("secondary_ssh", "var.secondary_ssh_network_tag"),
]

# The shell script: the rule created by name, and the variable its `--target-tags` must be.
SH_TAG_WIRING = [
    ("ringleader-allow-gateway", "GATEWAY_TAG"),
    ("ringleader-allow-ssh", "SSH_TAG"),
    ("ringleader-allow-internal", "SSH_TAG"),
    ("ringleader-allow-secondary-ssh", "SECONDARY_SSH_TAG"),
]


def check_terraform_wiring(source: str) -> list[str]:
    src = strip_hcl_comments(source)
    by_name = dict(hcl_resources(src, "google_compute_firewall"))
    fails = []
    for name, want in TF_TAG_WIRING:
        if name not in by_name:
            raise GuardError(
                f"{GCP_TF}: no `google_compute_firewall` named `{name}`.\n\n"
                "  A renamed or deleted rule leaves this guard checking a rule customers do not apply.\n"
                "  If the rule really is gone, delete its row from TF_TAG_WIRING deliberately."
            )
        tags = hcl_attr(by_name[name], "target_tags")
        if tags is None or want not in tags:
            fails.append(
                f"{GCP_TF}: `google_compute_firewall.{name}` targets {tags}, not `{want}`.\n\n"
                "  The value checked above is then a value nothing applies. A rule pointed at some other\n"
                "  tag is still a valid rule -- it simply admits nobody, silently, forever."
            )
    return fails


def check_shell_wiring(source: str) -> list[str]:
    """Judge each `gcloud` invocation on ITS OWN flags.

    Never on a tally across the file: `--target-tags "$GATEWAY_TAG"` left behind in a second,
    non-executing fragment would restore a count while the rule that actually runs admits
    something else. A flag has to sit in the invocation to reach gcloud at all.
    """
    src = strip_shell_comments(source)
    fails = []
    for rule, want in SH_TAG_WIRING:
        creates = [
            c for c in shell_commands(src)
            if re.search(r"\bfirewall-rules\s+create\s+" + re.escape(rule) + r"\b", c)
        ]
        if len(creates) != 1:
            raise GuardError(
                f"{GCP_SH}: found {len(creates)} `firewall-rules create {rule}` invocations, expected 1.\n\n"
                "  None means the rule was renamed and this guard reads nothing. Two means the second\n"
                "  one's flags are what the customer actually gets."
            )
        values = gcloud_flag_values(creates[0], "target-tags")
        if values != [f"${{{want}}}"] and values != [f"${want}"]:
            fails.append(
                f"{GCP_SH}: `{rule}` targets {values or 'nothing'}, not `${want}`.\n\n"
                "  Writing the tag out again here is not equivalent: it is a second definition of the\n"
                "  value, free to drift from the one checked above while both look right in isolation."
            )
    return fails


# --------------------------------------------------------------------------------------


def check_literal(literal: Literal, sources: dict[str, str]) -> list[str]:
    fails = []
    for site in literal.sites:
        got = site.read(sources[site.path], site.path)
        if got != literal.value:
            other = (
                f"\n\n  The other half of this contract is {literal.other_half}, which cannot see this\n"
                "  file and is pinned separately. A landing pad a customer has already applied does not\n"
                "  change when this repository does."
                if literal.other_half
                else ""
            )
            fails.append(
                f"{site.path}: {site.what} is `{got}`, want `{literal.value}`"
                f" -- {literal.name}.\n\n  {literal.why}{other}"
            )
    return fails


def check_bucket_prefix_wiring(sources: dict[str, str]) -> list[str]:
    """The prefix must be what the artifact-storage BOUND is written against.

    The same rule as the tag wiring above: pinning a value nothing applies proves nothing. Here it
    matters more than usual, because the bound is the only thing between "Ringleader may manage
    the buckets it creates" and "Ringleader may read every bucket in this project". A landing pad
    that declares the prefix and then bounds the grant with a literal of its own would satisfy
    every check above while granting something else entirely.
    """
    failures = []
    checks = (
        (AWS_TF, "s3:::${local.managed_bucket_prefix}", "the artifact-storage ARN patterns"),
        (GCP_TF, 'projects/_/buckets/${local.managed_bucket_prefix}', "the artifact-storage IAM condition"),
        (GCP_ONBOARD_SH, 'projects/_/buckets/${MANAGED_BUCKET_PREFIX}', "the artifact-storage IAM condition"),
    )
    for path, needle, what in checks:
        if needle not in sources[path]:
            failures.append(
                f"{path}: {what} does not interpolate the declared prefix (`{needle}`).\n\n"
                "  The prefix is pinned above, but the bound is written against something else -- so\n"
                "  the pin proves nothing about what this landing pad actually grants. Bound and\n"
                "  prefix have to be the same value, by reference and not by coincidence."
            )
    return failures


PATHS = sorted({s.path for lit in LITERALS for s in lit.sites} | {GCP_TF, GCP_SH})


def check_all(sources: dict[str, str]) -> list[str]:
    """Every literal and every wiring rule, against sources already read.

    A `GuardError` from any one check is COLLECTED rather than raised on, so a renamed anchor in
    one artifact does not hide a real weakening in the next -- the whole report is printed once.
    """
    failures: list[str] = []
    for literal in LITERALS:
        try:
            failures += check_literal(literal, sources)
        except GuardError as err:
            failures.append(str(err))
    for check, src in ((check_terraform_wiring, sources[GCP_TF]), (check_shell_wiring, sources[GCP_SH])):
        try:
            failures += check(src)
        except GuardError as err:
            failures.append(str(err))
    try:
        failures += check_bucket_prefix_wiring(sources)
    except GuardError as err:
        failures.append(str(err))
    return failures


def main(root: Path = REPO_ROOT) -> int:
    sources: dict[str, str] = {}
    failures: list[str] = []
    for path in PATHS:
        try:
            sources[path] = (root / path).read_text(encoding="utf-8")
        except OSError as err:
            failures.append(
                f"{path}: cannot read it ({err}).\n\n"
                "  It names a literal Ringleader sets on a machine in a customer's account. If it\n"
                "  moved, move this guard with it."
            )
    if failures:
        return _report(failures)

    failures = check_all(sources)
    if failures:
        return _report(failures)

    print(f"Published literals intact across {len(LITERALS)} contracts:")
    for literal in LITERALS:
        print(f"  ok  {literal.value}  ({literal.name}, {len(literal.sites)} sites)")
    return 0


def _report(failures: list[str]) -> int:
    print("A landing pad no longer names what Ringleader sets:\n", file=sys.stderr)
    for f in failures:
        print(f"  * {f}\n", file=sys.stderr)
    print(
        "A landing pad is applied once, by the customer, in their own account -- we hold no\n"
        "credentials there and cannot re-apply it. A value that has shipped is permanent: renaming\n"
        "it here does not fix the customers who applied the old one, it breaks them.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
