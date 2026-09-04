#!/usr/bin/env python3
"""The trust guard's own teeth, proved against the REAL shipped artifacts.

Every case below takes the artifact as it stands on this branch, applies one edit that would
weaken or erase the per-org pin, and asserts the guard rejects it. That is what makes
"a PR changing StringEquals to StringLike fails CI" a fact rather than a belief: a guard is
only worth its failure modes, and a guard that has quietly stopped matching the file it reads
passes every green build until the day it matters.

`mutate` therefore asserts its anchor appears EXACTLY ONCE. A mutation that no longer applies
is a test that asserts nothing, and it fails here loudly instead of passing silently.

Run:  python3 -m unittest discover -s .github/scripts -t .github/scripts
"""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from check_aws_trust_pins import (
    ARTIFACTS,
    REPO_ROOT,
    GuardError,
    check_artifact,
    cloudformation_conditions,
    main,
)

TERRAFORM, CLOUDFORMATION = ARTIFACTS

TF_SUB = """    condition {
      test     = "StringEquals"
      variable = "${local.oidc_condition_prefix}:sub"
      values   = [local.subject]
    }"""

TF_AUD = """    condition {
      test     = "StringEquals"
      variable = "${local.oidc_condition_prefix}:aud"
      values   = [local.audience]
    }"""

CFN_SUB = '                "__OIDC_PROVIDER__:sub": !Ref Subject'
CFN_AUD = '                "__OIDC_PROVIDER__:aud": !Ref Audience'


@contextlib.contextmanager
def quiet():
    """Swallow the guard's own report. A green run must not print "pins are not intact"."""
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        yield


def source(artifact) -> str:
    return (REPO_ROOT / artifact.path).read_text(encoding="utf-8")


def mutate(text: str, old: str, new: str) -> str:
    """Replace `old` with `new`, insisting `old` occurs exactly once."""
    count = text.count(old)
    if count != 1:
        raise AssertionError(
            f"the mutation anchor appears {count} times, expected exactly 1. The artifact has "
            f"drifted and this test is no longer testing what it claims:\n{old}"
        )
    return text.replace(old, new)


class TrustPinsHoldOnThisBranch(unittest.TestCase):
    def test_the_shipped_artifacts_pass(self):
        with quiet():
            self.assertEqual(main(), 0, "the artifacts on this branch must satisfy the guard")

    def test_every_artifact_is_actually_scanned(self):
        for artifact in ARTIFACTS:
            with self.subTest(artifact.path):
                self.assertEqual(check_artifact(artifact, source(artifact)), [])


class SubjectPinCannotBeWeakened(unittest.TestCase):
    """The cross-tenant hole: every way the `:sub` pin can stop confining one org."""

    def assertRejected(self, artifact, text, needle=":sub"):
        failures = check_artifact(artifact, text)
        self.assertTrue(failures, "the guard accepted a weakened subject pin")
        self.assertTrue(
            any(needle in f for f in failures),
            f"no failure mentioned {needle!r}: {failures}",
        )

    def test_terraform_string_like(self):
        text = mutate(
            source(TERRAFORM), TF_SUB, TF_SUB.replace("StringEquals", "StringLike")
        )
        self.assertRejected(TERRAFORM, text)

    def test_cloudformation_string_like(self):
        # In YAML the operator is the parent key, so loosening it moves the subject under a
        # StringLike sibling -- the same one-word edit, spelled the way this file spells it.
        text = mutate(
            source(CLOUDFORMATION),
            CFN_SUB,
            "              StringLike:\n" + CFN_SUB,
        )
        self.assertRejected(CLOUDFORMATION, text)

    def test_terraform_condition_deleted(self):
        self.assertRejected(TERRAFORM, mutate(source(TERRAFORM), TF_SUB, ""))

    def test_cloudformation_condition_deleted(self):
        self.assertRejected(CLOUDFORMATION, mutate(source(CLOUDFORMATION), CFN_SUB, ""))

    def test_terraform_wildcard_value(self):
        text = mutate(
            source(TERRAFORM), TF_SUB, TF_SUB.replace("[local.subject]", '["org:*"]')
        )
        self.assertRejected(TERRAFORM, text)

    def test_cloudformation_wildcard_value(self):
        text = mutate(
            source(CLOUDFORMATION), CFN_SUB, '                "__OIDC_PROVIDER__:sub": "org:*"'
        )
        self.assertRejected(CLOUDFORMATION, text)

    def test_terraform_pins_some_other_literal(self):
        text = mutate(
            source(TERRAFORM),
            TF_SUB,
            TF_SUB.replace("[local.subject]", '["org:00000000-0000-0000-0000-000000000000"]'),
        )
        self.assertRejected(TERRAFORM, text)

    def test_cloudformation_pins_some_other_literal(self):
        text = mutate(
            source(CLOUDFORMATION),
            CFN_SUB,
            '                "__OIDC_PROVIDER__:sub": !Ref RoleName',
        )
        self.assertRejected(CLOUDFORMATION, text)

    def test_terraform_two_subject_conditions_is_loud(self):
        text = mutate(source(TERRAFORM), TF_SUB, TF_SUB + "\n\n" + TF_SUB)
        with self.assertRaises(GuardError):
            check_artifact(TERRAFORM, text)

    def test_cloudformation_two_subject_conditions_is_loud(self):
        text = mutate(
            source(CLOUDFORMATION),
            CFN_SUB,
            CFN_SUB + "\n              StringLike:\n" + CFN_SUB,
        )
        with self.assertRaises(GuardError):
            check_artifact(CLOUDFORMATION, text)


class AudiencePinCannotBeWeakened(unittest.TestCase):
    """The second pin: what stops an assertion minted for another cloud being replayed here."""

    def assertRejected(self, artifact, text):
        failures = check_artifact(artifact, text)
        self.assertTrue(any(":aud" in f for f in failures), f"guard accepted: {failures}")

    def test_terraform_condition_deleted(self):
        self.assertRejected(TERRAFORM, mutate(source(TERRAFORM), TF_AUD, ""))

    def test_cloudformation_condition_deleted(self):
        self.assertRejected(CLOUDFORMATION, mutate(source(CLOUDFORMATION), CFN_AUD, ""))

    def test_terraform_string_like(self):
        text = mutate(
            source(TERRAFORM), TF_AUD, TF_AUD.replace("StringEquals", "StringLike")
        )
        self.assertRejected(TERRAFORM, text)

    def test_terraform_second_spelling_of_the_audience(self):
        text = mutate(
            source(TERRAFORM),
            TF_AUD,
            TF_AUD.replace("[local.audience]", '["${var.ringleader_issuer_url}/aws"]'),
        )
        self.assertRejected(TERRAFORM, text)


class ScanningNothingIsLoud(unittest.TestCase):
    """A guard that quietly reads a block that no longer exists is worse than no guard."""

    def test_terraform_policy_document_renamed(self):
        text = mutate(
            source(TERRAFORM),
            'data "aws_iam_policy_document" "trust" {',
            'data "aws_iam_policy_document" "assume_role" {',
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("aws_iam_policy_document", str(raised.exception))

    def test_cloudformation_key_renamed(self):
        text = mutate(
            source(CLOUDFORMATION),
            "      AssumeRolePolicyDocument:",
            "      AssumeRolePolicy:",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(CLOUDFORMATION, text)
        self.assertIn("AssumeRolePolicyDocument", str(raised.exception))

    def test_a_missing_artifact_fails(self):
        with tempfile.TemporaryDirectory() as empty, quiet():
            self.assertEqual(main(Path(empty)), 1)

    def test_terraform_second_statement_is_loud(self):
        # A second statement carries its own conditions, so an unpinned one is a second way
        # into the role that every per-condition check above would sail past.
        text = mutate(
            source(TERRAFORM),
            "data \"aws_iam_policy_document\" \"trust\" {\n",
            "data \"aws_iam_policy_document\" \"trust\" {\n"
            "  statement {\n"
            "    effect  = \"Allow\"\n"
            "    actions = [\"sts:AssumeRoleWithWebIdentity\"]\n"
            "  }\n",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("statements", str(raised.exception))

    def test_cloudformation_second_statement_is_loud(self):
        text = mutate(
            source(CLOUDFORMATION),
            "          - Sid: RingleaderOrgFederation\n",
            "          - Sid: AnythingGoes\n"
            "            Effect: Allow\n"
            "            Action: \"sts:AssumeRoleWithWebIdentity\"\n"
            "          - Sid: RingleaderOrgFederation\n",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(CLOUDFORMATION, text)
        self.assertIn("statements", str(raised.exception))


class TheGuardReadsTheDocumentTheRoleUses(unittest.TestCase):
    """Scanning a policy document by NAME proves nothing unless the role points at it."""

    def test_role_repointed_at_an_unpinned_document_is_loud(self):
        # The pinned `trust` document is left untouched and still passes every condition check;
        # it is simply no longer what the role applies. Nothing else in the toolchain objects --
        # an unused data source is not a `terraform validate` error.
        text = mutate(
            source(TERRAFORM),
            "assume_role_policy   = data.aws_iam_policy_document.trust.json",
            "assume_role_policy   = data.aws_iam_policy_document.trust_v2.json",
        )
        text = mutate(
            text,
            'resource "aws_iam_role" "ringleader" {',
            'data "aws_iam_policy_document" "trust_v2" {\n'
            "  statement {\n"
            '    effect  = "Allow"\n'
            '    actions = ["sts:AssumeRoleWithWebIdentity"]\n'
            "  }\n"
            "}\n\n"
            'resource "aws_iam_role" "ringleader" {',
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("assume_role_policy", str(raised.exception))

    def test_a_second_role_is_loud(self):
        text = mutate(
            source(TERRAFORM),
            'resource "aws_iam_role" "ringleader" {',
            'resource "aws_iam_role" "other" {\n'
            "  assume_role_policy = data.aws_iam_policy_document.trust.json\n"
            "}\n\n"
            'resource "aws_iam_role" "ringleader" {',
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("aws_iam_role", str(raised.exception))

    def test_a_role_with_no_trust_policy_is_loud(self):
        text = mutate(
            source(TERRAFORM),
            "  assume_role_policy   = data.aws_iam_policy_document.trust.json\n",
            "",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("assume_role_policy", str(raised.exception))


class CorrectFilesAreNotRejected(unittest.TestCase):
    """A guard that cries wolf is a guard that gets deleted rather than fixed."""

    def test_single_quoted_condition_keys_are_accepted(self):
        # Both quote styles are the same YAML. Reformatting one to the other is not a security
        # change and must not turn the build red with a cross-tenant-hole message.
        text = source(CLOUDFORMATION)
        for key in ("__OIDC_PROVIDER__:aud", "__OIDC_PROVIDER__:sub"):
            text = mutate(text, f'"{key}":', f"'{key}':")
        self.assertEqual(check_artifact(CLOUDFORMATION, text), [])


class PinsAreJudgedByWhatTheyResolveTo(unittest.TestCase):
    """A symbol that reads correctly is not a value that is correct.

    `values = [local.subject]` is byte-identical whatever the `locals` block says it means, so a
    guard that checks the condition text alone can be defeated one line away from the condition.
    """

    def assertRejected(self, text):
        failures = check_artifact(TERRAFORM, text)
        self.assertTrue(failures, "the guard accepted a pin that no longer means this org")

    def test_subject_hardcoded_to_another_org(self):
        self.assertRejected(
            mutate(
                source(TERRAFORM),
                'subject  = "org:${var.org_uid}"',
                'subject  = "org:some-other-customers-real-org-uid"',
            )
        )

    def test_subject_widened_to_a_wildcard(self):
        self.assertRejected(
            mutate(source(TERRAFORM), 'subject  = "org:${var.org_uid}"', 'subject  = "org:*"')
        )

    def test_audience_repointed_at_another_cloud(self):
        # Same org, same issuer, `aud` = <iss>/gcp: an assertion minted for another cloud,
        # replayed here. The subject still confines the org, so only the audience pin catches it.
        self.assertRejected(
            mutate(
                source(TERRAFORM), 'audience = "${local.issuer}/aws"', 'audience = "${local.issuer}/gcp"'
            )
        )

    def test_issuer_loses_the_org_segment(self):
        # Two hops away from the condition: audience resolves through issuer.
        self.assertRejected(
            mutate(
                source(TERRAFORM),
                'issuer = "${var.ringleader_issuer_url}/org/${var.org_uid}"',
                'issuer = "${var.ringleader_issuer_url}/org/shared"',
            )
        )

    def test_an_inlined_literal_pin_is_accepted(self):
        # The deleted Go guard required this exact spelling, and it is still correct: what matters
        # is that the value is built from the org uid, not which of the two ways it is written.
        text = mutate(
            source(TERRAFORM), "values   = [local.subject]", 'values   = ["org:${var.org_uid}"]'
        )
        self.assertEqual(check_artifact(TERRAFORM, text), [])

    def test_an_unreadable_local_is_loud(self):
        text = mutate(source(TERRAFORM), '  subject  = "org:${var.org_uid}"\n', "")
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("local.subject", str(raised.exception))

    def test_a_dynamic_condition_is_refused(self):
        # `for_each = []` emits no condition at all, and no text scan can tell that apart from one
        # that emits the pin -- so the trust document may not be built that way.
        text = mutate(
            source(TERRAFORM),
            TF_SUB,
            '    dynamic "condition" {\n      for_each = [1]\n      content {\n'
            '        test     = "StringEquals"\n'
            '        variable = "${local.oidc_condition_prefix}:sub"\n'
            "        values   = [local.subject]\n      }\n    }",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("dynamic", str(raised.exception))


class TheTemplatesPinsAreSuppliedSafely(unittest.TestCase):
    """CloudFormation takes its pins as deploy-time Parameters, so the parameter is the pin."""

    def assertRejected(self, text, needle):
        failures = check_artifact(CLOUDFORMATION, text)
        self.assertTrue(any(needle in f for f in failures), f"guard accepted: {failures}")

    def test_a_default_on_the_subject_parameter_is_rejected(self):
        # A default is what a by-hand console deploy gets when nothing is supplied.
        text = mutate(
            source(CLOUDFORMATION),
            "  Subject:\n    Type: String",
            '  Subject:\n    Type: String\n    Default: "org:00000000-0000-0000-0000-000000000000"',
        )
        self.assertRejected(text, "Default")

    def test_a_subject_parameter_with_no_allowed_pattern_is_rejected(self):
        text = mutate(
            source(CLOUDFORMATION),
            '    AllowedPattern: "^org:[0-9a-f-]{36}$"',
            '    MinLength: 1',
        )
        self.assertRejected(text, "AllowedPattern")

    def test_a_ref_to_a_parameter_that_does_not_exist_is_rejected(self):
        text = mutate(source(CLOUDFORMATION), "  Subject:\n", "  SubjectClaim:\n")
        self.assertRejected(text, "does not exist")


class APinMustEvaluateToThisOrg(unittest.TestCase):
    """"Mentions the org uid" is not "evaluates to the org uid", and a text scan cannot tell.

    Each case below carries the text a membership test would accept while shipping one hardcoded
    subject to every customer -- which is the cross-tenant hole, dressed as a refactor.
    """

    def assertRejected(self, artifact, text):
        try:
            failures = check_artifact(artifact, text)
        except GuardError:
            return
        self.assertTrue(failures, "the guard accepted a pin that does not evaluate to this org")

    def test_terraform_function_call_with_a_decoy_argument(self):
        # element(list, 0) always returns the FIRST item; the second exists only to carry the
        # characters `var.org_uid`.
        self.assertRejected(
            TERRAFORM,
            mutate(
                source(TERRAFORM),
                'subject  = "org:${var.org_uid}"',
                'subject  = element(["org:HARDCODED", "decoy-mentions-var.org_uid-here"], 0)',
            ),
        )

    def test_terraform_function_call_in_the_audience(self):
        self.assertRejected(
            TERRAFORM,
            mutate(
                source(TERRAFORM),
                'audience = "${local.issuer}/aws"',
                'audience = coalesce("https://x/org/HARD/aws", "${local.issuer}/aws")',
            ),
        )

    def test_terraform_a_second_value_widens_the_pin(self):
        # IAM ORs a condition's values, so a second entry is another subject the role accepts.
        self.assertRejected(
            TERRAFORM,
            mutate(
                source(TERRAFORM),
                "values   = [local.subject]",
                'values   = ["org:HARDCODED", local.subject]',
            ),
        )

    def test_cloudformation_intrinsic_wrapping_the_ref(self):
        # !Select [0, [...]] always resolves to the literal; !Ref Subject is decoy text.
        self.assertRejected(
            CLOUDFORMATION,
            mutate(
                source(CLOUDFORMATION),
                CFN_SUB,
                '                "__OIDC_PROVIDER__:sub": !Select [0, ["org:HARDCODED", !Ref Subject]]',
            ),
        )

    def test_cloudformation_conditional_wrapping_the_ref(self):
        self.assertRejected(
            CLOUDFORMATION,
            mutate(
                source(CLOUDFORMATION),
                CFN_SUB,
                '                "__OIDC_PROVIDER__:sub": !If [WantNetwork, "org:HARDCODED", !Ref Subject]',
            ),
        )

    def test_flow_style_says_what_is_actually_wrong(self):
        # A shape the guard cannot read must not be reported as a missing pin.
        text = mutate(
            source(CLOUDFORMATION),
            "              StringEquals:",
            '              StringEquals: {"__OIDC_PROVIDER__:aud": !Ref Audience}\n'
            "              _unused:",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(CLOUDFORMATION, text)
        self.assertIn("flow style", str(raised.exception))


class EverySpellingOfASecondStatementIsSeen(unittest.TestCase):
    """A statement the counter cannot see is a second, unpinned way into the role.

    YAML writes a block-sequence entry two ways -- `- Sid: x` with the first key inline, and a
    bare `-` with every key on the following lines. AWS honours both; a guard that matches only
    the first reads the pinned statement, reports success, and never sees the one beside it.
    """

    EVIL = (
        "          -\n"
        "            Sid: RingleaderOrgFederationEvil\n"
        "            Effect: Allow\n"
        "            Principal:\n"
        "              Federated: !Ref RingleaderOidcProvider\n"
        '            Action: "sts:AssumeRoleWithWebIdentity"\n'
    )

    def test_a_bare_dash_second_statement_is_loud(self):
        text = mutate(source(CLOUDFORMATION), "      Policies:", self.EVIL + "      Policies:")
        with self.assertRaises(GuardError) as raised:
            check_artifact(CLOUDFORMATION, text)
        self.assertIn("statements", str(raised.exception))

    def test_a_dash_space_second_statement_is_loud(self):
        text = mutate(
            source(CLOUDFORMATION),
            "      Policies:",
            self.EVIL.replace("          -\n            Sid:", "          - Sid:") + "      Policies:",
        )
        with self.assertRaises(GuardError) as raised:
            check_artifact(CLOUDFORMATION, text)
        self.assertIn("statements", str(raised.exception))

    def test_the_correct_policy_in_bare_dash_style_is_accepted(self):
        # The inverse failure: a legitimate formatting choice must not read as a missing pin.
        text = mutate(
            source(CLOUDFORMATION),
            "          - Sid: RingleaderOrgFederation\n",
            "          -\n            Sid: RingleaderOrgFederation\n",
        )
        self.assertEqual(check_artifact(CLOUDFORMATION, text), [])

    def test_both_spellings_are_counted(self):
        # Straight at the extractor: the count is what the `statements != 1` check rests on, and
        # a spelling it cannot see reports 1 for a document that has 2.
        conditions, statements = cloudformation_conditions(source(CLOUDFORMATION), "cfn")
        self.assertEqual(statements, 1)
        self.assertEqual(len(conditions), 2)  # :aud and :sub, from the one statement

        for label, entry in (("bare dash", self.EVIL), ("dash space", self.EVIL.replace(
            "          -\n            Sid:", "          - Sid:"))):
            with self.subTest(label):
                _, statements = cloudformation_conditions(
                    mutate(source(CLOUDFORMATION), "      Policies:", entry + "      Policies:"),
                    "cfn",
                )
                self.assertEqual(statements, 2, f"a {label} entry was not counted")


class BracesInsideStringsDoNotDesyncTheScanner(unittest.TestCase):
    """A brace in a string literal is an ordinary character to HCL, and must be to the guard.

    A blind brace counter reading `sid = "Federation}"` closes the trust document one brace
    early and simply stops scanning -- so anything written below it, including a second
    statement with no condition at all, is never seen. `terraform fmt` and `terraform validate`
    both accept that file, so nothing else in CI would catch it either.
    """

    EVIL = """
  statement {
    sid     = "AnyOrgWelcome"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.ringleader.arn]
    }
  }
"""

    def test_a_stray_brace_cannot_hide_a_second_statement(self):
        text = mutate(
            source(TERRAFORM),
            'sid     = "RingleaderOrgFederation"',
            'sid     = "RingleaderOrgFederation}"',
        )
        text = mutate(text, TF_SUB + "\n  }\n}", TF_SUB + "\n  }\n" + self.EVIL + "}")
        with self.assertRaises(GuardError) as raised:
            check_artifact(TERRAFORM, text)
        self.assertIn("statements", str(raised.exception))

    def test_a_brace_in_a_string_alone_does_not_break_a_correct_file(self):
        # The inverse: the counter must not mistake a quoted brace for structure either.
        text = mutate(
            source(TERRAFORM),
            'sid     = "RingleaderOrgFederation"',
            'sid     = "RingleaderOrgFederation}"',
        )
        self.assertEqual(check_artifact(TERRAFORM, text), [])


class PassRoleStaysPinnedToEC2(unittest.TestCase):
    """The relaxed form of the old "grants no iam:PassRole at all" check.

    The module now grants it, narrowly, under the opt-in workstation-identities feature. What
    must not be lost is the service pin that confines it.
    """

    def test_terraform_unpinned_pass_role_is_rejected(self):
        text = mutate(
            source(TERRAFORM),
            '        variable = "iam:PassedToService"',
            '        variable = "aws:RequestedRegion"',
        )
        failures = check_artifact(TERRAFORM, text)
        self.assertTrue(any("PassRole" in f for f in failures), f"guard accepted: {failures}")

    def test_documentation_prose_does_not_trip_it(self):
        # Comments are stripped first. The module documents the grant in prose; a naive
        # substring scan would match the documentation and fail on a correct file.
        text = mutate(
            source(TERRAFORM),
            '  subject  = "org:${var.org_uid}"',
            '  # This module grants iam:PassRole under an opt-in flag.\n'
            '  subject  = "org:${var.org_uid}"',
        ).replace('        variable = "iam:PassedToService"', "")
        # With the real condition removed, only the comment mentions PassedToService...
        self.assertTrue(any("PassRole" in f for f in check_artifact(TERRAFORM, text)))


if __name__ == "__main__":
    unittest.main()
