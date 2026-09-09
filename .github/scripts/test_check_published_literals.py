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
    GCP_ONBOARD_SH,
    AZURE_ARM,
    AZURE_TF,
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
            "ringleader-allow-gateway",
        )

    def test_the_shell_rule_is_renamed(self):
        self.assertRejected(
            edited((GCP_SH, "gcloud compute firewall-rules create ringleader-allow-gateway --project",
                    "gcloud compute firewall-rules create ringleader-allow-egress-gateway --project")),
            "firewall-rules create ringleader-allow-gateway",
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

    def test_the_arm_variable_is_renamed(self):
        self.assertRejected(
            edited((AZURE_ARM, '"secondarySshRules": [', '"altSshRules": [')),
            "secondarySshRules",
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
            edited((GCP_SH, "gcloud compute firewall-rules create ringleader-allow-gateway-management --project",
                    "gcloud compute firewall-rules create ringleader-allow-mgmt --project")),
            "ringleader-allow-gateway-management",
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
            "does not follow",
        )

    def test_the_mirror_local_is_renamed(self):
        self.assertRejected(
            edited((GCP_TF, "  gateway_management_ranges = var.gateway_management_source_ranges",
                    "  gw_management_ranges = var.gateway_management_source_ranges")),
            "no `gateway_management_ranges`",
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


class ARuleNameThatPrefixesAnotherIsNotThatRule(unittest.TestCase):
    """`ringleader-allow-gateway` and `ringleader-allow-gateway-management` are two rules.

    Matched with a trailing `\\b`, the first name is found inside the second -- a hyphen is a
    non-word character -- and the shell wiring check then reports two invocations of a rule that
    has one. It fails on a correct artifact, and the cheapest way out is renaming the new rule
    rather than reading the file properly, so it is pinned here instead.
    """

    def test_the_shipped_script_is_not_miscounted(self):
        self.assertEqual(check_shell_wiring(sources()[GCP_SH]), [])

    def test_a_genuinely_duplicated_rule_is_still_caught(self):
        # The lookahead narrows the match; it must not stop the check seeing a real second
        # invocation, whose flags are what the customer would actually get.
        one = (
            'gcloud compute firewall-rules create ringleader-allow-gateway --project "$PROJECT" \\\n'
            "  --network ringleader-vpc --direction INGRESS --action allow \\\n"
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
            edited((AWS_CFN, 'arn:${AWS::Partition}:s3:::ringleader-*/*',
                    'arn:${AWS::Partition}:s3:::rl-*/*')),
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
            edited((GCP_TF, 'resource.name.startsWith(\\"projects/_/buckets/${local.managed_bucket_prefix}\\")',
                    'resource.name.startsWith(\\"projects/_/buckets/\\")')),
            "does not interpolate the declared prefix",
        )

    def test_the_aws_arn_stops_referencing_the_local(self):
        self.assertRejected(
            edited((AWS_TF, '"arn:${data.aws_partition.current.partition}:s3:::${local.managed_bucket_prefix}*",',
                    '"arn:${data.aws_partition.current.partition}:s3:::ringleader-*",')),
            "does not interpolate the declared prefix",
        )


class AMissingFileIsLoud(unittest.TestCase):
    def test_a_vanished_artifact_fails_rather_than_passing(self):
        with quiet():
            self.assertEqual(main(root=Path("/nonexistent")), 1)


if __name__ == "__main__":
    unittest.main()
