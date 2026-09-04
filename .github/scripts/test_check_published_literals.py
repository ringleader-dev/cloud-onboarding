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
    AZURE_ARM,
    AZURE_TF,
    GCP_SH,
    GCP_TF,
    GCP_VARS,
    LITERALS,
    PATHS,
    REPO_ROOT,
    check_all,
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
            edited((GCP_TF, "  target_tags   = [local.gateway_network_tag]",
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


class AMissingFileIsLoud(unittest.TestCase):
    def test_a_vanished_artifact_fails_rather_than_passing(self):
        with quiet():
            self.assertEqual(main(root=Path("/nonexistent")), 1)


if __name__ == "__main__":
    unittest.main()
