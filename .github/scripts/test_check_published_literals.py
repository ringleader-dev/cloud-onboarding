#!/usr/bin/env python3
"""The published-literal guard's own teeth, proved against the REAL shipped artifacts.

Every case below takes the artifacts as they stand on this branch, applies one edit that would
make a landing pad name something other than what Ringleader sets, and asserts the guard rejects
it. That is what makes "a PR that renames the gateway tag in the Terraform but not the shell
script fails CI" a fact rather than a belief.

The class this file exists for is the one that LOOKS fine: a renamed tag is a valid firewall
rule, `terraform validate` and `bash -n` both stay green, and the symptom is an outage nothing
reports. So the tests come in pairs -- rename one site (the two paths disagree), and rename both
(they agree with each other and no longer with Ringleader).

`mutate` asserts its anchor appears EXACTLY ONCE. A mutation that no longer applies is a test
that asserts nothing, and it fails here loudly instead of passing silently.

Run:  python3 -m unittest discover -s .github/scripts -t .github/scripts
"""

from __future__ import annotations

import contextlib
import io
import unittest
from pathlib import Path

from check_published_literals import (
    AWS_CFN,
    AWS_TF,
    AWS_VARS,
    GCP_ONBOARD_SH,
    AZURE_ARM,
    AZURE_SH,
    AZURE_TF,
    AZURE_VARS,
    GCP_SH,
    GCP_TF,
    GCP_VARS,
    LITERALS,
    PATHS,
    REPO_ROOT,
    GuardError,
    check_all,
    check_shell_wiring,
    main,
)

GATEWAY_TAG = "ringleader-egress-gateway"


@contextlib.contextmanager
def quiet():
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        yield


def sources() -> dict[str, str]:
    return {p: (REPO_ROOT / p).read_text(encoding="utf-8") for p in PATHS}


def mutate(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise AssertionError(
            f"the mutation anchor appears {count} times, expected exactly 1. The artifact has "
            f"drifted and this test is no longer testing what it claims:\n{old}"
        )
    return text.replace(old, new)


def edited(*edits: tuple[str, str, str]) -> dict[str, str]:
    """The real artifacts with one edit applied per (path, old, new)."""
    srcs = sources()
    for path, old, new in edits:
        srcs[path] = mutate(srcs[path], old, new)
    return srcs


def renamed_everywhere(old: str, new: str) -> dict[str, str]:
    """`old` -> `new` in EVERY artifact and at every occurrence, asserting it appeared somewhere.

    For the case a per-site edit cannot express: a value renamed consistently across all of its
    sites. The pads then agree with each other and no longer with what Ringleader compiles, which
    is the drift no amount of internal consistency can catch.
    """
    srcs = sources()
    hits = sum(text.count(old) for text in srcs.values())
    if hits == 0:
        raise AssertionError(f"the anchor {old!r} appears in no artifact; this test asserts nothing")
    return {path: text.replace(old, new) for path, text in srcs.items()}


class Rejects(unittest.TestCase):
    def assertRejected(self, srcs, needle=""):
        failures = check_all(srcs)
        self.assertTrue(failures, "the guard accepted a landing pad that names the wrong literal")
        if needle:
            self.assertTrue(
                any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}"
            )
        return failures


class TheShippedArtifactsPass(unittest.TestCase):
    def test_main_is_green_on_this_branch(self):
        with quiet():
            self.assertEqual(main(), 0, "the artifacts on this branch must satisfy the guard")

    def test_no_literal_has_lost_its_sites(self):
        # A literal whose table lost a site passes vacuously for that path forever.
        for literal in LITERALS:
            with self.subTest(literal.name):
                self.assertGreaterEqual(len(literal.sites), 2, "a contract has at least two ends")


class GatewayTagCannotDrift(Rejects):
    """The headline: the tag Ringleader sets, named in two places in this repo."""

    def test_renamed_in_the_terraform_only(self):
        self.assertRejected(
            edited((GCP_TF, f'gateway_network_tag = "{GATEWAY_TAG}"',
                    'gateway_network_tag = "ringleader-egress-gw"')),
            "gateway_network_tag",
        )

    def test_renamed_in_the_shell_script_only(self):
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"', 'GATEWAY_TAG="ringleader-egress-gw"')),
            "GATEWAY_TAG",
        )

    def test_renamed_in_both_still_fails_and_names_the_other_half(self):
        # The two agree with each other and no longer with Ringleader. This is the case a
        # cross-file consistency check alone would pass, and it is the outage.
        failures = self.assertRejected(
            edited(
                (GCP_TF, f'gateway_network_tag = "{GATEWAY_TAG}"',
                 'gateway_network_tag = "ringleader-egress-gw"'),
                (GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"', 'GATEWAY_TAG="ringleader-egress-gw"'),
            )
        )
        joined = "\n".join(failures)
        self.assertIn("gcegateway.NetworkTag", joined)
        self.assertIn("already applied", joined)

    def test_a_typo_of_one_character(self):
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"', 'GATEWAY_TAG="ringleader-egress-gatway"'))
        )

    def test_the_tag_becomes_an_environment_override(self):
        # Reads as helpful flexibility; is the outage in one line.
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                    f'GATEWAY_TAG="${{GATEWAY_TAG:-{GATEWAY_TAG}}}"')),
            "override",
        )

    def test_the_local_is_renamed(self):
        # Loud, not silent: a guard reading nothing is worse than no guard.
        self.assertRejected(
            edited((GCP_TF, f'gateway_network_tag = "{GATEWAY_TAG}"',
                    f'egress_gateway_tag = "{GATEWAY_TAG}"')),
            "no `gateway_network_tag`",
        )


class GatewayTagWiring(Rejects):
    """A pinned value the rule does not name is a value nothing applies."""

    def test_the_terraform_rule_targets_something_else(self):
        self.assertRejected(
            edited((GCP_TF,
                    "  source_ranges = local.workstation_ranges\n"
                    "  target_tags   = [local.gateway_network_tag]",
                    "  source_ranges = local.workstation_ranges\n"
                    "  target_tags   = [var.workstation_network_tag]")),
            "google_compute_firewall.gateway",
        )

    def test_the_terraform_rule_is_renamed(self):
        self.assertRejected(
            edited((GCP_TF, 'resource "google_compute_firewall" "gateway" {',
                    'resource "google_compute_firewall" "egress_gateway" {')),
            "no `google_compute_firewall` named `gateway`",
        )

    def test_the_shell_rule_writes_the_tag_out_again(self):
        # A second definition of the value: both sites read correctly in isolation and are free
        # to drift from each other on the next edit.
        self.assertRejected(
            edited((GCP_SH, '--rules tcp,udp,icmp --source-ranges "$WORKSTATION_RANGES" --target-tags "$GATEWAY_TAG"',
                    f'--rules tcp,udp,icmp --source-ranges "$WORKSTATION_RANGES" --target-tags "{GATEWAY_TAG}"')),
            "${NAME_PREFIX}-allow-gateway",
        )

    def test_the_shell_rule_is_renamed(self):
        self.assertRejected(
            edited((GCP_SH, 'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-gateway" --project',
                    'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-egress-gateway" --project')),
            'firewall-rules create "${NAME_PREFIX}-allow-gateway"',
        )

    def test_the_shell_rule_hardcodes_its_name(self):
        # A name written out instead of built from NAME_PREFIX. The rule still deploys, and it
        # still admits the right tag, so nothing here is visibly wrong -- but a second Ringleader
        # organization can no longer apply this script into the same project, which is the whole
        # reason these names carry the prefix.
        self.assertRejected(
            edited((GCP_SH, 'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-gateway" --project',
                    "gcloud compute firewall-rules create ringleader-allow-gateway --project")),
            'firewall-rules create "${NAME_PREFIX}-allow-gateway"',
        )


class ARebindingIsRefused(Rejects):
    """The shell reader is `check_trust_pins`' closed grammar, so this file inherits its teeth."""

    def test_a_read_rebinds_the_tag(self):
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                    f'GATEWAY_TAG="{GATEWAY_TAG}"\nread -r GATEWAY_TAG <<< "ringleader-egress-gw"'))
        )

    def test_a_printf_v_rebinds_the_tag(self):
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                    f'GATEWAY_TAG="{GATEWAY_TAG}"\nprintf -v GATEWAY_TAG %s ringleader-egress-gw'))
        )

    def test_a_bare_bracket_cannot_hide_a_rebinding(self):
        # The desync twin of the above, on THIS script: a bare `(` or `[` is an ordinary word to
        # bash, so it must not join the next line into the `echo` before it. It once did, and the
        # rebinding below then reached the customer's landing pad unseen -- the silent outage this
        # file exists to prevent, arriving through the guard rather than around it.
        for label, br in (("bare [", "["), ("bare (", "(")):
            with self.subTest(shape=label):
                self.assertRejected(
                    edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                            f'GATEWAY_TAG="{GATEWAY_TAG}"\necho ok {br}\n'
                            'GATEWAY_TAG="ringleader-egress-gatway"')),
                    "expected exactly 1",
                )

    def test_an_escaped_quote_cannot_hide_a_rebinding(self):
        # `echo \'` prints one apostrophe and ends. Read as an OPENING quote it swallowed the next
        # line, and a second one re-closed it -- so exactly the rebinding below vanished while the
        # rest of the script parsed normally and this guard reported the tag intact.
        for label, opener in {
            "escaped single quote": "echo \\'",
            "escaped double quote": 'echo \\"',
            "escaped backtick": "echo \\`",
        }.items():
            with self.subTest(shape=label):
                self.assertRejected(
                    edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                            f'GATEWAY_TAG="{GATEWAY_TAG}"\n{opener}\n'
                            f'GATEWAY_TAG="ringleader-egress-gatway"\n{opener}')),
                    "expected exactly 1",
                )

    def test_a_second_plain_assignment_is_reported(self):
        self.assertRejected(
            edited((GCP_SH, f'GATEWAY_TAG="{GATEWAY_TAG}"',
                    f'GATEWAY_TAG="{GATEWAY_TAG}"\nGATEWAY_TAG="ringleader-egress-gw"')),
            "expected exactly 1",
        )


class SecondarySSHPortCannotDrift(Rejects):
    """Six sites in one repository, all of them the port `rl shell` dials."""

    def test_the_aws_module(self):
        self.assertRejected(edited((AWS_TF, "secondary_ssh_port = 2222", "secondary_ssh_port = 2200")))

    def test_the_cloudformation_template(self):
        # Both security groups carry the pair, so one edit leaves them inconsistent AND wrong.
        srcs = sources()
        srcs[AWS_CFN] = srcs[AWS_CFN].replace("FromPort: 2222", "FromPort: 2200")
        self.assertRejected(srcs)

    def test_the_azure_module(self):
        self.assertRejected(edited((AZURE_TF, "secondary_ssh_port = 2222", "secondary_ssh_port = 2200")))

    def test_the_azure_arm_template(self):
        self.assertRejected(
            edited((AZURE_ARM, '"destinationPortRange": "2222"', '"destinationPortRange": "2200"'))
        )

    def test_the_gcp_module(self):
        self.assertRejected(edited((GCP_TF, "secondary_ssh_port = 2222", "secondary_ssh_port = 2200")))

    def test_the_gcp_script(self):
        self.assertRejected(edited((GCP_SH, "SECONDARY_SSH_PORT=2222", "SECONDARY_SSH_PORT=2200")))

    def test_every_site_moved_together_still_fails(self):
        srcs = sources()
        for path in (AWS_TF, AZURE_TF, GCP_TF):
            srcs[path] = mutate(srcs[path], "secondary_ssh_port = 2222", "secondary_ssh_port = 2200")
        srcs[AWS_CFN] = srcs[AWS_CFN].replace("Port: 2222", "Port: 2200")
        srcs[AZURE_ARM] = mutate(
            srcs[AZURE_ARM], '"destinationPortRange": "2222"', '"destinationPortRange": "2200"'
        )
        srcs[GCP_SH] = mutate(srcs[GCP_SH], "SECONDARY_SSH_PORT=2222", "SECONDARY_SSH_PORT=2200")
        failures = self.assertRejected(srcs)
        self.assertIn("capsuleboot.SSHPort", "\n".join(failures))

    def test_the_cloudformation_anchor_is_gone(self):
        srcs = sources()
        srcs[AWS_CFN] = srcs[AWS_CFN].replace(
            "CidrIp: !Ref SecondarySshSourceCidr", "CidrIp: !Ref SshSourceCidr"
        )
        self.assertRejected(srcs, "no line reading")

    def test_the_arm_rule_is_renamed(self):
        self.assertRejected(
            edited((AZURE_ARM, "'/AllowRingleaderSecondarySSHInbound')]", "'/AllowRingleaderAltSSHInbound')]")),
            "expected 1",
        )


class CrossPathDefaultsMustAgree(Rejects):
    """The customer's own tags: the value is theirs, the DEFAULTS are ours to keep in step."""

    def test_the_workstation_tag_drifts_in_the_module(self):
        self.assertRejected(
            edited((GCP_VARS, 'default     = "ringleader-workstation"',
                    'default     = "ringleader-box"')),
            "workstation_network_tag",
        )

    def test_the_workstation_tag_drifts_in_the_script(self):
        self.assertRejected(
            edited((GCP_SH, 'SSH_TAG="${SSH_TAG:-ringleader-workstation}"',
                    'SSH_TAG="${SSH_TAG:-ringleader-box}"')),
            "SSH_TAG",
        )

    def test_the_secondary_ssh_tag_drifts_in_the_module(self):
        self.assertRejected(
            edited((GCP_VARS, 'default     = "ringleader-secondary-ssh"',
                    'default     = "ringleader-alt-ssh"')),
            "secondary_ssh_network_tag",
        )

    def test_the_secondary_ssh_tag_drifts_in_the_script(self):
        self.assertRejected(
            edited((GCP_SH, 'SECONDARY_SSH_TAG="${SECONDARY_SSH_TAG:-ringleader-secondary-ssh}"',
                    'SECONDARY_SSH_TAG="${SECONDARY_SSH_TAG:-ringleader-alt-ssh}"')),
            "SECONDARY_SSH_TAG",
        )

    def test_a_customer_knob_that_stops_being_overridable(self):
        # The opposite drift: a default hardcoded is a tag the customer can no longer choose,
        # while the module still says they can.
        self.assertRejected(
            edited((GCP_SH, 'SSH_TAG="${SSH_TAG:-ringleader-workstation}"',
                    'SSH_TAG="ringleader-workstation"')),
            "not the `${SSH_TAG:-<default>}` shape",
        )

    def test_the_module_variable_is_renamed(self):
        self.assertRejected(
            edited((GCP_VARS, 'variable "secondary_ssh_network_tag" {',
                    'variable "alt_ssh_network_tag" {')),
            'no `variable "secondary_ssh_network_tag"`',
        )


class TheManagementPortSetCannotDrift(Rejects):
    """The ports the GCP landing pad opens on the egress gateway, in two languages.

    Unlike the tag, this set has no compiled counterpart to disagree with yet -- the mechanism that
    listens behind it is still being chosen. What it has instead is the property that outlives that
    choice: a pad is applied ONCE, in an account we cannot re-enter, so the two GCP paths must open
    the same envelope, and it must be the envelope the pinned value names.
    """

    def test_the_module_narrows_the_set(self):
        self.assertRejected(
            edited((GCP_TF, '  gateway_management_ports = ["22", "30000-32767"]',
                    '  gateway_management_ports = ["22"]')),
            "inbound management port set",
        )

    def test_the_script_narrows_the_set(self):
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:30000-32767"',
                    'GATEWAY_MANAGEMENT_RULES="tcp:22"')),
            "inbound management port set",
        )

    def test_both_paths_move_together_and_still_fail(self):
        # The case a cross-file consistency check alone would pass: the pads agree with each other
        # and no longer with the envelope every already-applied pad carries.
        failures = self.assertRejected(
            edited(
                (GCP_TF, '  gateway_management_ports = ["22", "30000-32767"]',
                 '  gateway_management_ports = ["22", "40000-49999"]'),
                (GCP_SH, 'GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:30000-32767"',
                 'GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:40000-49999"'),
            )
        )
        self.assertIn("applied ONCE", "\n".join(failures))

    def test_the_local_is_renamed(self):
        self.assertRejected(
            edited((GCP_TF, '  gateway_management_ports = ["22", "30000-32767"]',
                    '  management_ports = ["22", "30000-32767"]')),
            "no `gateway_management_ports`",
        )

    def test_the_port_set_becomes_an_environment_override(self):
        # Reads as flexibility; is a rule that admits nothing, on a pad we cannot re-apply.
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:30000-32767"',
                    'GATEWAY_MANAGEMENT_RULES="${GATEWAY_MANAGEMENT_RULES:-tcp:22,tcp:30000-32767}"')),
            "override",
        )

    def test_a_protocol_other_than_tcp_is_refused_rather_than_normalised(self):
        # `udp:30000-32767` would compare equal to the TCP entry if the protocol were stripped
        # without being read, and the shell path would then grant something the Terraform path
        # cannot express at all.
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RULES="tcp:22,tcp:30000-32767"',
                    'GATEWAY_MANAGEMENT_RULES="tcp:22,udp:30000-32767"')),
            "not a `tcp:<ports>` rule",
        )

    def test_a_computed_port_set_is_refused_rather_than_guessed(self):
        self.assertRejected(
            edited((GCP_TF, '  gateway_management_ports = ["22", "30000-32767"]',
                    '  gateway_management_ports = concat(["22"], var.extra_ports)')),
            "not a `[...]` list",
        )


class TheManagementRuleWiring(Rejects):
    """A pinned port set the rule does not name is a port set nothing applies."""

    def test_the_terraform_rule_writes_the_ports_out_again(self):
        self.assertRejected(
            edited((GCP_TF, "    ports    = local.gateway_management_ports",
                    '    ports    = ["22", "30000-32767"]')),
            "local.gateway_management_ports",
        )

    def test_the_terraform_rule_targets_the_workstation_tag(self):
        self.assertRejected(
            edited((GCP_TF,
                    "  source_ranges = local.gateway_management_ranges\n"
                    "  target_tags   = [local.gateway_network_tag]",
                    "  source_ranges = local.gateway_management_ranges\n"
                    "  target_tags   = [var.workstation_network_tag]")),
            "google_compute_firewall.gateway_management",
        )

    def test_the_terraform_rule_is_renamed(self):
        self.assertRejected(
            edited((GCP_TF, 'resource "google_compute_firewall" "gateway_management" {',
                    'resource "google_compute_firewall" "gateway_inbound" {')),
            "gateway_management",
        )

    def test_a_second_allow_block_widens_the_rule_unseen(self):
        # The shape every "read the block and check it" guard misses: the pinned block still reads
        # exactly right, and the one appended after it hands the operator's CIDRs unrestricted UDP
        # to the appliance.
        self.assertRejected(
            edited((GCP_TF, """  allow {
    protocol = "tcp"
    ports    = local.gateway_management_ports
  }""", """  allow {
    protocol = "tcp"
    ports    = local.gateway_management_ports
  }

  allow { protocol = "udp" }""")),
            "`allow` blocks",
        )

    def test_the_rule_changes_protocol(self):
        # The ports are still the pinned ones; the protocol is not one the shell path can express.
        self.assertRejected(
            edited((GCP_TF, """  allow {
    protocol = "tcp"
    ports    = local.gateway_management_ports
  }""", """  allow {
    protocol = "udp"
    ports    = local.gateway_management_ports
  }""")),
            "admits protocol `udp`",
        )

    def test_a_dynamic_block_hides_a_second_grant(self):
        # Valid, `terraform validate`-clean HCL that expands at plan time into an allow block no
        # text scan can count. The pinned block beside it still reads exactly right.
        self.assertRejected(
            edited((GCP_TF,
                    '  allow {\n'
                    '    protocol = "tcp"\n'
                    "    ports    = local.gateway_management_ports\n"
                    "  }",
                    '  allow {\n'
                    '    protocol = "tcp"\n'
                    "    ports    = local.gateway_management_ports\n"
                    "  }\n\n"
                    '  dynamic "allow" {\n'
                    "    for_each = var.extra_protocols\n"
                    "    content {\n"
                    "      protocol = allow.value\n"
                    "    }\n"
                    "  }")),
            "`dynamic` block",
        )

    def test_the_shell_rule_writes_the_ports_out_again(self):
        self.assertRejected(
            edited((GCP_SH, '    --rules "$GATEWAY_MANAGEMENT_RULES" \\',
                    '    --rules tcp:22,tcp:30000-32767 \\')),
            "GATEWAY_MANAGEMENT_RULES",
        )

    def test_the_shell_rule_is_renamed(self):
        self.assertRejected(
            edited((GCP_SH, 'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-gateway-management" --project',
                    'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-mgmt" --project')),
            "${NAME_PREFIX}-allow-gateway-management",
        )


class TheFollowedRangesCannotBeRebound(Rejects):
    """`GATEWAY_MANAGEMENT_RANGES` carries no pinned VALUE, only the closed grammar's protection.

    Who is admitted to the appliance is the whole of this rule, so a statement that binds the name
    by any means an assignment reader cannot see -- a `for` variable outlives its loop in bash --
    must be refused even though the value itself is legitimately the operator's to choose.
    """

    ANCHOR = 'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"'

    def test_a_for_loop_variable_rebinds_the_ranges(self):
        self.assertRejected(
            edited((GCP_SH, self.ANCHOR,
                    self.ANCHOR + '\nfor GATEWAY_MANAGEMENT_RANGES in "0.0.0.0/0"; do true; done'))
        )

    def test_a_printf_v_rebinds_the_ranges(self):
        self.assertRejected(
            edited((GCP_SH, self.ANCHOR,
                    self.ANCHOR + "\nprintf -v GATEWAY_MANAGEMENT_RANGES %s 0.0.0.0/0"))
        )

    def test_a_read_rebinds_the_ranges(self):
        self.assertRejected(
            edited((GCP_SH, self.ANCHOR,
                    self.ANCHOR + '\nread -r GATEWAY_MANAGEMENT_RANGES <<< "0.0.0.0/0"'))
        )


class TheAdmissionFollowsTheInboundSSHRanges(Rejects):
    """The default that makes this rule land without a second decision, on BOTH gcp paths.

    Losing it is one line either way and both read as caution -- an empty default, or a list
    written out here instead of followed -- and either leaves one of the two routes unable to reach
    a steered box while the other can.
    """

    def test_the_script_stops_following(self):
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"',
                    'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-}"')),
            "not `$SSH_RANGES`",
        )

    def test_the_script_invents_its_own_ranges(self):
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"',
                    'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-0.0.0.0/0}"')),
            "not `$SSH_RANGES`",
        )

    def test_the_module_stops_following(self):
        self.assertRejected(
            edited((GCP_VARS,
                    'variable "gateway_management_source_ranges" {\n'
                    "  type        = list(string)\n"
                    "  default     = null",
                    'variable "gateway_management_source_ranges" {\n'
                    "  type        = list(string)\n"
                    "  default     = []")),
            "not `null`",
        )

    def test_the_module_variable_is_renamed(self):
        self.assertRejected(
            edited((GCP_VARS, 'variable "gateway_management_source_ranges" {',
                    'variable "gateway_mgmt_source_ranges" {')),
            'no `variable "gateway_management_source_ranges"`',
        )

    def test_the_mirror_local_resolves_somewhere_else(self):
        # The shape a default-only check misses: the variable still defaults to `null`, and the
        # line that gives `null` its meaning now names something the description never promised.
        self.assertRejected(
            edited((GCP_TF, "var.gateway_management_source_ranges == null ? var.ssh_source_ranges :",
                    "var.gateway_management_source_ranges == null ? var.secondary_ssh_source_ranges :")),
            "mirrors `var.secondary_ssh_source_ranges`",
        )

    def test_the_mirror_local_is_renamed(self):
        self.assertRejected(
            edited((GCP_TF, "  gateway_management_ranges = var.gateway_management_source_ranges",
                    "  gw_management_ranges = var.gateway_management_source_ranges")),
            "no `gateway_management_ranges`",
        )

    def test_the_override_branch_is_dropped(self):
        # Still "follows ssh_source_ranges" by every substring test, and an operator's explicit []
        # no longer closes the rule: the variable, its default and its description all go on
        # promising an override the module stopped reading.
        self.assertRejected(
            edited((GCP_TF,
                    "var.gateway_management_source_ranges == null ? var.ssh_source_ranges : var.gateway_management_source_ranges",
                    "var.gateway_management_source_ranges == null ? var.ssh_source_ranges : var.ssh_source_ranges")),
            "resolves a SET value",
        )

    def test_a_second_assignment_carrying_a_value_is_refused(self):
        # The `none` normalisation is legitimate; a second assignment carrying a VALUE is the one
        # that leaves a reader judging something the script does not use.
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"',
                    'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"\n'
                    'GATEWAY_MANAGEMENT_RANGES="0.0.0.0/0"')),
            "not the `none` normalisation",
        )

    def test_a_second_default_assignment_is_refused(self):
        self.assertRejected(
            edited((GCP_SH, 'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"',
                    'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-$SSH_RANGES}"\n'
                    'GATEWAY_MANAGEMENT_RANGES="${GATEWAY_MANAGEMENT_RANGES:-0.0.0.0/0}"')),
            "expected exactly 1",
        )


class TheAzureManagementRuleCannotDrift(Rejects):
    """The same envelope on azure, where the landing pad owns the gateway SUBNET's NSG.

    Azure evaluates that NSG before the one Ringleader writes on the gateway VM's NIC, so both routes
    must open the pinned ports, to the ranges the operator already named, on that group.
    """

    TF_PORTS = '  gateway_management_ports = ["22", "30000-32767"]'
    ARM_PORTS = '"destinationPortRanges": [\n          "22",\n          "30000-32767"\n        ]'
    ARM_PROTOCOL = '"protocol": "Tcp",\n        "direction": "Inbound",\n        "access": "Allow",\n        "priority": 4010,'
    SH_DEFAULT = 'GATEWAY_MANAGEMENT_SOURCE_CIDR="${GATEWAY_MANAGEMENT_SOURCE_CIDR:-$SSH_SOURCE_CIDR}"'

    def test_the_module_narrows_the_set(self):
        self.assertRejected(
            edited((AZURE_TF, self.TF_PORTS, '  gateway_management_ports = ["30000-32767"]')),
            "inbound management port set",
        )

    def test_the_template_narrows_the_set(self):
        self.assertRejected(
            edited((AZURE_ARM, self.ARM_PORTS, '"destinationPortRanges": [\n            "30000-32767"\n          ]')),
            "inbound management port set",
        )

    def test_the_template_admits_udp(self):
        self.assertRejected(
            edited((AZURE_ARM, self.ARM_PROTOCOL, self.ARM_PROTOCOL.replace('"Tcp"', '"Udp"'))),
            "not `Tcp`",
        )

    def test_the_template_spells_a_port_a_second_way(self):
        self.assertRejected(
            edited((AZURE_ARM, self.ARM_PORTS, '"destinationPortRange": "22",\n          ' + self.ARM_PORTS)),
            "destinationPortRange",
        )

    def test_the_module_rule_writes_the_ports_out_again(self):
        self.assertRejected(
            edited((AZURE_TF, "  destination_port_ranges     = local.gateway_management_ports",
                    '  destination_port_ranges     = ["22", "30000-32767"]')),
            "local.gateway_management_ports",
        )

    def test_the_module_rule_moves_to_the_workstations_nsg(self):
        self.assertRejected(
            edited((AZURE_TF,
                    "  network_security_group_name = azurerm_network_security_group.gateway[0].name\n"
                    "  priority                    = 4010",
                    "  network_security_group_name = azurerm_network_security_group.workstations[0].name\n"
                    "  priority                    = 4010")),
            "network_security_group_name",
        )

    def test_the_template_stops_deploying_the_rule(self):
        self.assertRejected(
            edited((AZURE_ARM,
                    "\"name\": \"[concat(variables('gatewayNsgName'), '/allow-management-inbound')]\"",
                    "\"name\": \"[concat(variables('gatewayNsgName'), '/allow-mgmt-inbound')]\"")),
            "expected 1",
        )

    def test_the_script_stops_following(self):
        self.assertRejected(
            edited((AZURE_SH, self.SH_DEFAULT,
                    'GATEWAY_MANAGEMENT_SOURCE_CIDR="${GATEWAY_MANAGEMENT_SOURCE_CIDR:-}"')),
            "not `$SSH_SOURCE_CIDR`",
        )

    def test_the_script_stops_passing_the_parameter(self):
        self.assertRejected(
            edited((AZURE_SH, '                 gatewayManagementSourceCidr="$GATEWAY_MANAGEMENT_SOURCE_CIDR" \\\n', "")),
            "gatewayManagementSourceCidr",
        )

    def test_a_for_loop_variable_rebinds_the_script_default(self):
        self.assertRejected(
            edited((AZURE_SH, self.SH_DEFAULT,
                    self.SH_DEFAULT + '\nfor GATEWAY_MANAGEMENT_SOURCE_CIDR in "0.0.0.0/0"; do true; done'))
        )

    def test_the_module_stops_following(self):
        self.assertRejected(
            edited((AZURE_VARS,
                    'variable "gateway_management_source_ranges" {\n'
                    "  type        = list(string)\n"
                    "  default     = null",
                    'variable "gateway_management_source_ranges" {\n'
                    "  type        = list(string)\n"
                    "  default     = []")),
            "not `null`",
        )

    def test_the_mirror_local_resolves_somewhere_else(self):
        self.assertRejected(
            edited((AZURE_TF, "var.gateway_management_source_ranges == null ? var.ssh_source_ranges :",
                    "var.gateway_management_source_ranges == null ? var.secondary_ssh_source_ranges :")),
            "mirrors `var.secondary_ssh_source_ranges`",
        )


class TheArmGroupsKeepARuleTheyDidNotDeclare(Rejects):
    """Ringleader writes inbound rules of its own inside the two groups the ARM pad creates.

    Two shapes take them away again, and both deploy cleanly: a `securityRules` list on the group,
    which a deployment sets as a whole, and redeploying a group that is already there, which resets
    the rules to the ones the template declares. Each case below is one of those shapes coming back.
    """

    NSG_BODY = ('"name": "[variables(\'gatewayNsgName\')]",\n'
                '      "location": "[parameters(\'location\')]"')

    def test_the_group_declares_a_rule_list_again(self):
        self.assertRejected(
            edited((AZURE_ARM, self.NSG_BODY,
                    self.NSG_BODY + ',\n      "properties": {\n        "securityRules": []\n      }')),
            "securityRules",
        )

    def test_the_group_is_redeployed_over_one_that_exists(self):
        self.assertRejected(
            edited((AZURE_ARM,
                    '"condition": "[and(parameters(\'createGatewaySubnet\'), not(parameters(\'gatewayNsgExists\')))]"',
                    '"condition": "[parameters(\'createGatewaySubnet\')]"')),
            "without asking",
        )

    def test_the_script_stops_passing_the_switch(self):
        self.assertRejected(
            edited((AZURE_SH, '                 workstationsNsgExists="$WORKSTATIONS_NSG_EXISTS" \\\n', "")),
            "does not pass `workstationsNsgExists`",
        )

    def test_the_script_looks_the_group_up_under_another_name(self):
        self.assertRejected(
            edited((AZURE_SH, 'WORKSTATIONS_NSG="${NAME_PREFIX}-workstations-nsg"',
                    'WORKSTATIONS_NSG="${NAME_PREFIX}-workstations"')),
            "does not name",
        )


class ARuleNameThatPrefixesAnotherIsNotThatRule(unittest.TestCase):
    """`allow-gateway` and `allow-gateway-management` are two rules, and one name prefixes the other.

    Matched with a trailing `\\b`, the first is found inside the second -- a hyphen is a non-word
    character -- and the shell wiring check then reports two invocations of a rule that has one. It
    fails on a correct artifact, and the cheapest way out is renaming the new rule rather than
    reading the file properly, so it is pinned here instead. The closing quote in `sh_rule_create`
    now separates them as well, which makes this two independent defences rather than one.
    """

    def test_the_shipped_script_is_not_miscounted(self):
        self.assertEqual(check_shell_wiring(sources()[GCP_SH]), [])

    def test_a_genuinely_duplicated_rule_is_still_caught(self):
        # The lookahead narrows the match; it must not stop the check seeing a real second
        # invocation, whose flags are what the customer would actually get.
        one = (
            'gcloud compute firewall-rules create "${NAME_PREFIX}-allow-gateway" --project "$PROJECT" \\\n'
            '  --network "$VPC" --direction INGRESS --action allow \\\n'
            '  --rules tcp,udp,icmp --source-ranges "$WORKSTATION_RANGES" --target-tags "$GATEWAY_TAG"'
        )
        src = mutate(sources()[GCP_SH], one, one + "\n" + one)
        with self.assertRaises(GuardError):
            check_shell_wiring(src)


class TheManagedBucketPrefixCannotDrift(Rejects):
    """The one bound between "the buckets Ringleader made" and "every bucket in the project"."""

    def test_renamed_in_the_gcp_terraform_only(self):
        self.assertRejected(
            edited((GCP_TF, 'managed_bucket_prefix = "ringleader-"',
                    'managed_bucket_prefix = "rl-"')),
            "managed artifact-bucket prefix",
        )

    def test_renamed_in_the_gcloud_script_only(self):
        self.assertRejected(
            edited((GCP_ONBOARD_SH, 'MANAGED_BUCKET_PREFIX="ringleader-"',
                    'MANAGED_BUCKET_PREFIX="rl-"')),
            "managed artifact-bucket prefix",
        )

    def test_renamed_in_the_aws_terraform_only(self):
        self.assertRejected(
            edited((AWS_TF, 'managed_bucket_prefix = "ringleader-"',
                    'managed_bucket_prefix = "rl-"')),
            "managed artifact-bucket prefix",
        )

    def test_renamed_in_the_cloudformation_only(self):
        self.assertRejected(
            edited((AWS_CFN, 'arn:${AWS::Partition}:s3:::ringleader-${ArtifactStorageBucketPrefix}*/*',
                    'arn:${AWS::Partition}:s3:::rl-${ArtifactStorageBucketPrefix}*/*')),
            "not one",
        )


    def test_renamed_everywhere_still_fails(self):
        # The pair that matters most: every site agrees with the others and no longer with the
        # string Ringleader compiles, which no amount of internal consistency can catch.
        self.assertRejected(
            renamed_everywhere("ringleader-", "rl-"),
            "storagekind.ManagedBucketPrefix",
        )

    def test_the_prefix_is_declared_but_not_what_bounds_the_grant(self):
        # The shape every value-only guard misses: the pin still reads "ringleader-", and the
        # condition it is supposed to bound now names something else.
        self.assertRejected(
            edited((GCP_TF, 'resource.name.startsWith(\\"projects/_/buckets/${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}\\")',
                    'resource.name.startsWith(\\"projects/_/buckets/\\")')),
            "by reference and not by coincidence",
        )

    def test_the_aws_arn_stops_referencing_the_local(self):
        self.assertRejected(
            edited((AWS_TF, '"arn:${data.aws_partition.current.partition}:s3:::${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}*",',
                    '"arn:${data.aws_partition.current.partition}:s3:::ringleader-*",')),
            "by reference and not by coincidence",
        )


class TheLandingPadNamePrefixDefaultCannotDrift(Rejects):
    """A variable's DEFAULT is what both GCP routes ship, so moving one splits the two routes.

    The names it builds were literals until the script took NAME_PREFIX, and a literal was pinned by
    being matched. A variable is not, so the default needs its own pin: move it on either route and
    every other check here stays green, because each route remains internally consistent while the
    two no longer build the same landing pad.
    """

    def test_moved_in_the_script_only(self):
        self.assertRejected(
            edited((GCP_SH, 'NAME_PREFIX="${NAME_PREFIX:-ringleader}"', 'NAME_PREFIX="${NAME_PREFIX:-rl}"')),
            "name prefix default",
        )

    def test_moved_in_the_terraform_only(self):
        self.assertRejected(
            edited((GCP_VARS, 'variable "name_prefix" {\n  type        = string\n  default     = "ringleader"',
                    'variable "name_prefix" {\n  type        = string\n  default     = "rl"')),
            "name prefix default",
        )


class ARebindOfANamePinIsRefused(Rejects):
    """The closed grammar protects only the names it is given, and bash has more than one binder.

    A rebind after the pinned assignment wins at runtime while every reader -- this guard included
    -- sees the value it was declared with. `printf -v` and a loop variable are the two spellings
    that look like ordinary commands.
    """

    def test_name_prefix_rebound_by_printf(self):
        self.assertRejected(
            edited((GCP_SH, 'NAME_PREFIX="${NAME_PREFIX:-ringleader}"',
                    'NAME_PREFIX="${NAME_PREFIX:-ringleader}"\nprintf -v NAME_PREFIX %s rl')),
            "NAME_PREFIX",
        )

    def test_the_artifact_bound_rebound_by_a_loop_variable(self):
        self.assertRejected(
            edited((GCP_ONBOARD_SH, 'ARTIFACT_STORAGE_BUCKET_PREFIX="${ARTIFACT_STORAGE_BUCKET_PREFIX:-}"',
                    'ARTIFACT_STORAGE_BUCKET_PREFIX="${ARTIFACT_STORAGE_BUCKET_PREFIX:-}"\n'
                    'for ARTIFACT_STORAGE_BUCKET_PREFIX in ""; do true; done')),
            "ARTIFACT_STORAGE_BUCKET_PREFIX",
        )


class ALandingPadNameHardcodedBackIsRefused(Rejects):
    """The eleven names were literals until the script took NAME_PREFIX; a literal was pinned by
    being matched, and a variable reference is not. Writing one back out leaves every other check
    green while a second organization collides on that one resource at its own apply."""

    def test_the_vpc_name_written_out(self):
        self.assertRejected(
            edited((GCP_SH, 'VPC="${NAME_PREFIX}-vpc"', 'VPC="ringleader-vpc"')),
            "does not build `VPC`",
        )

    def test_the_router_name_written_out(self):
        self.assertRejected(
            edited((GCP_SH, 'ROUTER="${NAME_PREFIX}-router"', 'ROUTER="ringleader-router"')),
            "does not build `ROUTER`",
        )


class ALandingPadNameWrittenOutAnywhereIsRefused(Rejects):
    """A name pinned at its declaration and written out at its USE is not pinned.

    The six names are read at `gcloud` calls far from where they are declared, so these are the
    mutations that read correctly at both ends and attach a second organization's apply to the
    first organization's resources.
    """

    def test_the_router_named_at_the_nat_create(self):
        self.assertRejected(
            edited((GCP_SH, '--router "$ROUTER"', "--router ringleader-router")),
            "`ringleader-router` is written out",
        )

    def test_the_vpc_named_at_a_rule_create(self):
        self.assertRejected(
            edited((GCP_SH, '--network "$VPC" --direction INGRESS --action allow --rules tcp:22',
                    "--network ringleader-vpc --direction INGRESS --action allow --rules tcp:22")),
            "`ringleader-vpc` is written out",
        )

    def test_the_subnet_named_at_the_final_describe(self):
        self.assertRejected(
            edited((GCP_SH, 'subnets describe "$SUBNET"', "subnets describe ringleader-workstations")),
            "`ringleader-workstations` is written out",
        )

    def test_a_name_reassigned_after_its_pinned_declaration(self):
        self.assertRejected(
            edited((GCP_SH, 'SUBNET="${NAME_PREFIX}-workstations"',
                    'SUBNET="${NAME_PREFIX}-workstations"\nVPC="ringleader-vpc"')),
            "`ringleader-vpc` is written out",
        )


class TheArtifactLabelLengthRuleCannotBeRelaxed(Rejects):
    """The label separates two organizations only because every label is the same length.

    The rule lives at four sites and a relaxation at any one reintroduces the overlap for the
    customers who took that route, while every other check here stays green.
    """

    def test_relaxed_in_the_aws_terraform(self):
        self.assertRejected(
            edited((AWS_VARS, '"^([a-z0-9]{8})?$"', '"^[a-z0-9]*$"')),
            "the artifact label validation",
        )

    def test_relaxed_in_the_gcp_terraform(self):
        self.assertRejected(
            edited((GCP_VARS, '"^([a-z0-9]{8})?$"', '"^[a-z0-9]*$"')),
            "the artifact label validation",
        )

    def test_relaxed_in_the_cloudformation_allowed_pattern(self):
        self.assertRejected(
            edited((AWS_CFN, '"^([a-z0-9]{8})?$"', '"^[a-z0-9]*$"')),
            "AllowedPattern",
        )

    def test_relaxed_in_the_gcloud_script(self):
        self.assertRejected(
            edited((GCP_ONBOARD_SH, "'^[a-z0-9]{8}$'", "'^[a-z0-9]*$'")),
            "the artifact label check",
        )


class AWiderBoundBesideTheNarrowedOneIsRefused(Rejects):
    """A grant is the UNION of its statements, so the widest bound is what the customer applied.

    Checking that the narrowed bound is PRESENT cannot see a second, wider one added beside it: the
    pad then reads as narrowed in review and grants the wide thing. Both routes that express the
    bound in their own language are held to one bound, the way the CloudFormation reader already is.
    """

    def test_an_extra_unnarrowed_arn_in_the_aws_terraform(self):
        one = '"arn:${data.aws_partition.current.partition}:s3:::${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}*",'
        wide = '"arn:${data.aws_partition.current.partition}:s3:::${local.managed_bucket_prefix}*",'
        self.assertRejected(
            edited((AWS_TF, one, one + "\n    " + wide)),
            "the artifact-storage ARN patterns",
        )

    def test_a_widening_or_clause_in_the_gcp_condition(self):
        one = 'resource.name.startsWith(\\"projects/_/buckets/${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}\\")'
        wide = ' || resource.name.startsWith(\\"projects/_/buckets/${local.managed_bucket_prefix}\\")'
        self.assertRejected(
            edited((GCP_TF, one, one + wide)),
            "the artifact-storage IAM condition",
        )


class ThePerOrganizationNarrowingCannotDrift(Rejects):
    """A narrowing applied to some of the grant's statements and not others is not a narrowing.

    The managed width is bounded by a bucket-NAME pattern and nothing else, so one account serving
    two Ringleader organizations has each grant reaching the other's buckets until the pattern
    carries something per-organization. That makes the narrowing load-bearing wherever it is set,
    and half-applied is the shape that reads as narrowed while granting the wider thing -- which is
    what a customer has already applied by the time anyone notices.
    """

    def test_dropped_from_the_cloudformation_object_statement(self):
        self.assertRejected(
            edited((AWS_CFN, 'arn:${AWS::Partition}:s3:::ringleader-${ArtifactStorageBucketPrefix}*/*',
                    'arn:${AWS::Partition}:s3:::ringleader-*/*')),
            "not one narrowing",
        )

    def test_dropped_from_the_cloudformation_provisioning_statement(self):
        self.assertRejected(
            edited((AWS_CFN, 'Resource: !Sub "arn:${AWS::Partition}:s3:::ringleader-${ArtifactStorageBucketPrefix}*"',
                    'Resource: !Sub "arn:${AWS::Partition}:s3:::ringleader-*"')),
            "not one narrowing",
        )

    def test_dropped_from_the_aws_terraform_arn(self):
        self.assertRejected(
            edited((AWS_TF, 's3:::${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}*',
                    's3:::${local.managed_bucket_prefix}*')),
            "the artifact-storage ARN patterns",
        )

    def test_dropped_from_the_gcp_terraform_condition(self):
        self.assertRejected(
            edited((GCP_TF, 'projects/_/buckets/${local.managed_bucket_prefix}${var.artifact_storage_bucket_prefix}',
                    'projects/_/buckets/${local.managed_bucket_prefix}')),
            "the artifact-storage IAM condition",
        )

    def test_dropped_from_the_gcloud_script_condition(self):
        self.assertRejected(
            edited((GCP_ONBOARD_SH, 'projects/_/buckets/${MANAGED_BUCKET_PREFIX}${ARTIFACT_STORAGE_BUCKET_PREFIX}',
                    'projects/_/buckets/${MANAGED_BUCKET_PREFIX}')),
            "the artifact-storage IAM condition",
        )



class AMissingFileIsLoud(unittest.TestCase):
    def test_a_vanished_artifact_fails_rather_than_passing(self):
        with quiet():
            self.assertEqual(main(root=Path("/nonexistent")), 1)


if __name__ == "__main__":
    unittest.main()
