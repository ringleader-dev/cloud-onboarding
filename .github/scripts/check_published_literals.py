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
    hcl_sub_block,
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


def hcl_local_port_set(name: str):
    """A `locals` list of port specs, normalised to one comma-separated string.

    Compared as ONE value rather than as a list, because the two GCP paths spell the same set in
    two different languages -- an HCL list here, gcloud's `--rules` there -- and the property is
    that they OPEN THE SAME PORTS, not that they are written alike.
    """

    def read(source: str, path: str) -> str:
        locals_ = hcl_locals(strip_hcl_comments(source))
        if name not in locals_:
            raise GuardError(
                f"{path}: no `{name}` in any `locals` block.\n\n"
                "  It was renamed, moved out of `locals`, or spread over several lines. Any of the\n"
                "  three leaves this guard reading nothing while the port set it pins can drift."
            )
        expr = locals_[name].strip()
        if not (expr.startswith("[") and expr.endswith("]")):
            raise GuardError(
                f"{path}: `{name}` is `{expr}`, not a `[...]` list this guard can read.\n\n"
                "  A computed port set is one this guard cannot compare against the shell path's,\n"
                "  and an uncompared port set is how one route silently opens something the other\n"
                "  does not."
            )
        return ",".join(_unquote(part) for part in expr[1:-1].split(",") if part.strip())

    return read


def shell_gcloud_rules(name: str):
    """A shell variable bound to a bare `--rules` value, normalised to the same port string.

    Every entry must be `tcp:<ports>`. A `udp:` or bare-protocol entry admits something the
    Terraform path does not, and would compare equal if the protocol were simply stripped without
    being checked -- so it is refused rather than normalised away.
    """

    def read(source: str, path: str) -> str:
        value = _one_shell_assignment(source, path, name)
        if SH_DEFAULT_RE.match(value):
            raise GuardError(
                f"{path}: `{name}` is `{value}`, an environment override.\n\n"
                "  The port set is not the operator's to choose: Ringleader listens on these ports and\n"
                "  a rule opening others reads correctly in the console and admits nothing. Bind it to\n"
                "  the literal."
            )
        ports = []
        for entry in value.split(","):
            entry = entry.strip()
            if not entry.startswith("tcp:") or len(entry) == 4:
                raise GuardError(
                    f"{path}: `{name}` contains `{entry}`, which is not a `tcp:<ports>` rule.\n\n"
                    "  The management admission is TCP only, and the Terraform path can express nothing\n"
                    "  else. An entry of another shape means the two routes no longer grant the same\n"
                    "  thing -- and this guard will not guess which one is right."
                )
            ports.append(entry[4:])
        return ",".join(ports)

    return read


def shell_mirror_default(name: str):
    """The default of `NAME="${NAME:-...}"` in a file where a `none` sentinel may also close it.

    Two assignments to this name are legitimate and only two: the one that supplies the default,
    and the one that turns the documented `none` into emptiness. `shell_default` demands exactly
    one, which is right for a name nothing else touches and wrong for this idiom -- so the shape
    is read out rather than the count. What is refused is a second assignment carrying a VALUE: an
    operator who ran the script would then get a rule built from something this guard never saw.
    """

    def read(source: str, path: str) -> str:
        src = strip_shell_comments(source)
        values = [_unquote(v) for n, v in shell_assignments(src, path, GUARDED_SHELL_VARS) if n == name]
        defaults = [v for v in values if SH_DEFAULT_RE.match(v)]
        rest = [v for v in values if not SH_DEFAULT_RE.match(v)]
        if len(defaults) != 1:
            raise GuardError(
                f"{path}: found {len(defaults)} `${{{name}:-<default>}}` assignments to `{name}`,\n"
                "  expected exactly 1. None means it was renamed or rewritten and this guard is\n"
                "  reading nothing; two means the second one is what the customer actually gets."
            )
        if rest != [] and rest != [""]:
            raise GuardError(
                f"{path}: `{name}` is also assigned {rest}, which is not the `none` normalisation.\n\n"
                "  The only other statement this name may carry is the one emptying it when the\n"
                "  operator asked for `none`. An assignment carrying a VALUE means the rule is built\n"
                "  from something other than the default read here, and both read right in isolation."
            )
        m = SH_DEFAULT_RE.match(defaults[0])
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
    "MANAGED_BUCKET_PREFIX", "GATEWAY_MANAGEMENT_RULES",
    # Its VALUE is the operator's, so nothing below pins it -- but WHO it admits to the gateway
    # appliance is the whole of the opt-in, and the closed grammar protects only the names it is
    # given. Left out, `for GATEWAY_MANAGEMENT_RANGES in 0.0.0.0/0; do true; done` (a loop variable
    # outlives its loop in bash) would rebind it and every later reader would still see the empty
    # default it was declared with.
    "GATEWAY_MANAGEMENT_RANGES",
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
        name="the egress gateway's inbound management port set",
        value="22,30000-32767",
        other_half="",
        why=(
            "A workstation an egress policy steers stops answering on its own address from outside\n"
            "  its VPC -- the steering object is a 0.0.0.0/0 route, so it carries the reply to a\n"
            "  connection the box never opened. The only repair is to terminate the management\n"
            "  connection AT the gateway, and on gcp the gateway's inbound firewall is a VPC rule in\n"
            "  the customer's project rather than an object Ringleader owns. This is the port set that\n"
            "  rule opens, and the two gcp paths must open the SAME one: a customer who followed the\n"
            "  Terraform README and a customer who ran the script would otherwise get landing pads on\n"
            "  which different halves of the feature work.\n\n"
            "  It is an ENVELOPE rather than one port, deliberately. The two shapes that can carry\n"
            "  management through a gateway need different halves of it -- an SSH jump host on the\n"
            "  appliance answers on 22, a per-box DNAT bastion needs one high port per governed box --\n"
            "  and a landing pad is applied ONCE, by the customer, in an account we cannot re-enter.\n"
            "  Narrowing this later does not narrow the pads already applied; widening it is a\n"
            "  re-apply asked of every customer. Ringleader chooses WITHIN this envelope: the\n"
            "  mechanism that terminates a management session at the gateway (RIN-1999) has no\n"
            "  compiled counterpart to pin against yet, and when it lands it binds itself to these\n"
            "  ports rather than the other way round. Changing this value is a decision about every\n"
            "  pad already applied, not about the next one."
        ),
        sites=[
            Site(GCP_TF, "local.gateway_management_ports", hcl_local_port_set("gateway_management_ports")),
            Site(GCP_SH, "GATEWAY_MANAGEMENT_RULES", shell_gcloud_rules("GATEWAY_MANAGEMENT_RULES")),
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
    ("gateway_management", "local.gateway_network_tag"),
    ("ssh", "var.workstation_network_tag"),
    ("internal", "var.workstation_network_tag"),
    ("secondary_ssh", "var.secondary_ssh_network_tag"),
]

# The shell script: the rule created by name, and the variable its `--target-tags` must be.
SH_TAG_WIRING = [
    ("ringleader-allow-gateway", "GATEWAY_TAG"),
    ("ringleader-allow-gateway-management", "GATEWAY_TAG"),
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
            # `(?![\w-])` and not `\b`: a hyphen is a non-word character, so `\b` would find
            # `ringleader-allow-gateway` inside `ringleader-allow-gateway-management` and report two
            # invocations of a rule that has one. A name that PREFIXES another's is not that rule.
            if re.search(r"\bfirewall-rules\s+create\s+" + re.escape(rule) + r"(?![\w-])", c)
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


def check_management_port_wiring(sources: dict[str, str]) -> list[str]:
    """The inbound-management rule must open the port set pinned above, by REFERENCE.

    The same rule as the tag wiring: a pinned value the rule does not name is a value nothing
    applies. Written out again at the rule, the set is a second definition free to drift from the
    one checked above while both read correctly in isolation -- and the symptom of that drift is a
    steered workstation that stays unreachable while every object Ringleader checks is as it wrote
    it.
    """
    failures = []

    src = strip_hcl_comments(sources[GCP_TF])
    by_name = dict(hcl_resources(src, "google_compute_firewall"))
    if "gateway_management" not in by_name:
        raise GuardError(
            f"{GCP_TF}: no `google_compute_firewall` named `gateway_management`.\n\n"
            "  That is the rule admitting management traffic to the egress gateway, and the port set\n"
            "  pinned above is what it opens. If it really was removed, remove its row from\n"
            "  TF_TAG_WIRING and its Literal deliberately -- and know that no customer who has already\n"
            "  applied this pad loses the rule when you do."
        )
    body = by_name["gateway_management"]

    # ONE `allow` block, counted before anything is read out of it. `hcl_sub_block` returns the
    # FIRST match, so a second block is invisible to every check below -- and a second block is a
    # second grant: `allow { protocol = "udp" }` appended here hands the operator's CIDRs
    # unrestricted UDP to the appliance while the port set above still reads exactly right.
    # A `dynamic` block is a second grant this reader cannot count: `dynamic "allow" { content {
    # protocol = "udp" } }` is valid, `terraform validate`-clean HCL that expands at plan time into
    # an allow block no text scan sees. There is no legitimate use for one in a rule whose whole
    # content is pinned, so the shape is refused rather than parsed.
    for kind in re.findall(r'^[ \t]*dynamic[ \t]+"([A-Za-z_]+)"', body, re.M):
        failures.append(
            f"{GCP_TF}: `google_compute_firewall.gateway_management` builds its `{kind}` blocks with a\n"
            "  `dynamic` block. What it expands to is decided at plan time, so nothing here can say\n"
            "  what this rule admits -- and the pinned port set below would go on reading exactly\n"
            "  right beside a second grant nobody judged. Write the block out."
        )

    allows = re.findall(r"^[ \t]*allow[ \t]*\{", body, re.M)
    if len(allows) != 1:
        failures.append(
            f"{GCP_TF}: `google_compute_firewall.gateway_management` has {len(allows)} `allow` blocks,\n"
            "  expected exactly 1. The pin above reads the first one only, so a second grants a\n"
            "  protocol or a port range nothing here judges -- on a landing pad that cannot be\n"
            "  narrowed again once a customer has applied it. This rule admits TCP on the pinned\n"
            "  ports and nothing else."
        )

    allow = hcl_sub_block(body, "allow")
    protocol = None if allow is None else _unquote(hcl_attr(allow, "protocol") or "")
    if protocol != "tcp":
        failures.append(
            f"{GCP_TF}: `google_compute_firewall.gateway_management` admits protocol `{protocol}`,\n"
            "  not `tcp`. The shell path can express nothing else -- its `--rules` entries are pinned\n"
            "  to `tcp:` -- so the two gcp routes would grant different things, and the wider of the\n"
            "  two is the one already applied in a customer's project."
        )
    ports = None if allow is None else hcl_attr(allow, "ports")
    if ports != "local.gateway_management_ports":
        failures.append(
            f"{GCP_TF}: `google_compute_firewall.gateway_management` opens {ports}, not\n"
            "  `local.gateway_management_ports`. The value checked above is then a value nothing\n"
            "  applies, and the two gcp paths are free to open different ports while both look right."
        )

    sh = strip_shell_comments(sources[GCP_SH])
    creates = [
        c for c in shell_commands(sh)
        if re.search(r"\bfirewall-rules\s+create\s+ringleader-allow-gateway-management(?![\w-])", c)
    ]
    if len(creates) != 1:
        raise GuardError(
            f"{GCP_SH}: found {len(creates)} `firewall-rules create ringleader-allow-gateway-management`\n"
            "  invocations, expected 1. None means the rule was renamed and this guard reads nothing;\n"
            "  two means the second one's flags are what the customer actually gets."
        )
    rules = gcloud_flag_values(creates[0], "rules")
    if rules != ["${GATEWAY_MANAGEMENT_RULES}"] and rules != ["$GATEWAY_MANAGEMENT_RULES"]:
        failures.append(
            f"{GCP_SH}: `ringleader-allow-gateway-management` opens {rules or 'nothing'}, not\n"
            "  `$GATEWAY_MANAGEMENT_RULES`. Writing the ports out again here is a second definition of\n"
            "  the value, free to drift from the one checked above while both look right in isolation."
        )
    return failures


def check_management_default_follows_ssh(sources: dict[str, str]) -> list[str]:
    """The inbound-management admission must FOLLOW the inbound-SSH ranges, on both paths.

    This is the property that makes the rule land without a second decision: an operator who named
    the CIDRs their engineers connect from keeps reaching those boxes after a policy steers one.
    It is checked rather than assumed because the two ways of losing it are both one line and both
    read as caution -- an empty default here, or a hardcoded list there -- and either leaves ONE of
    the two gcp routes silently unable to reach a steered box while the other can.

    It does not check WHO is admitted: the ranges are the operator's. What it checks is that
    neither path invents an answer of its own, and that neither stops following.

    `shell_mirror_default` runs the closed grammar on the way and reads the script's two-statement
    idiom exactly -- one assignment carrying the default, one emptying it for `none`. A third, or a
    second carrying a value, is refused: the rule would then be built from something this guard
    never read.
    """
    failures = []

    sh_default = shell_mirror_default("GATEWAY_MANAGEMENT_RANGES")(sources[GCP_SH], GCP_SH)
    if sh_default != "$SSH_RANGES":
        failures.append(
            f"{GCP_SH}: `GATEWAY_MANAGEMENT_RANGES` defaults to `{sh_default}`, not `$SSH_RANGES`.\n\n"
            "  Empty, an operator who opened 22 to their engineers loses those boxes the moment a\n"
            "  policy steers one, and gets no rule from the path the Terraform module would have\n"
            "  given them. A hardcoded list is worse: it admits somebody to the egress gateway\n"
            "  appliance that the operator never named. Follow the ranges they already chose."
        )

    tf_default = hcl_variable_default("gateway_management_source_ranges")(sources[GCP_VARS], GCP_VARS)
    if tf_default != "null":
        failures.append(
            f"{GCP_VARS}: `gateway_management_source_ranges` defaults to `{tf_default}`, not `null`.\n\n"
            "  `null` is what MIRRORS ssh_source_ranges here -- the shape secondary_ssh_source_ranges\n"
            "  already uses. `[]` would be a module that silently stops following, and any other\n"
            "  default is the module choosing who may reach the appliance in the operator's account."
        )

    # ...and the mirror has to be spelled against the variable it claims to follow. A default of
    # `null` whose local resolves to something else is a promise the description makes and the
    # module does not keep.
    mirror = hcl_locals(strip_hcl_comments(sources[GCP_TF])).get("gateway_management_ranges")
    if mirror is None:
        raise GuardError(
            f"{GCP_TF}: no `gateway_management_ranges` in any `locals` block.\n\n"
            "  That local is where `null` becomes `var.ssh_source_ranges`. Without it the mirror is\n"
            "  unchecked, and a rule that quietly stopped following would read exactly right."
        )
    if "var.ssh_source_ranges" not in mirror:
        failures.append(
            f"{GCP_TF}: `local.gateway_management_ranges` is `{mirror}`, which does not follow\n"
            "  `var.ssh_source_ranges`. The variable's default says unset mirrors the inbound-SSH\n"
            "  ranges; this is the line that has to make that true, and a default of `null` resolving\n"
            "  to anything else is a rule nobody asked for or a rule that never appears."
        )
    return failures


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
    for cross in (check_management_port_wiring, check_management_default_follows_ssh, check_bucket_prefix_wiring):
        try:
            failures += cross(sources)
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
