#!/usr/bin/env python3
"""The trust guard's own teeth, proved against the REAL shipped artifacts, on all three clouds.

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

from check_trust_pins import (
    ARTIFACTS,
    REPO_ROOT,
    GuardError,
    check_artifact,
    cloudformation_conditions,
    _heredoc_delims,
    main,
)

TERRAFORM, CLOUDFORMATION, GCP_TF, GCP_SH, AZURE_TF, AZURE_SH = ARTIFACTS

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
        #
        # Anchored on the line ABOVE as well, because `StringEquals:` alone is no longer unique in
        # this template -- the PassRole statement carries one too, at a deeper indent that contains
        # the shallower one as a substring.
        text = mutate(
            source(CLOUDFORMATION),
            '            Condition:\n              StringEquals:',
            '            Condition:\n'
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


# ======================================================================================
# GCP -- two independent places to lose the confinement, and neither alone confines the org
# ======================================================================================

GCP_CONDITION = """  attribute_condition = "assertion.sub == '${local.subject}'\""""
GCP_MEMBER = (
    '  member             = "principal://iam.googleapis.com/'
    '${google_iam_workload_identity_pool.ringleader.name}/subject/${local.subject}"'
)


class GcpAttributeConditionCannotBeWeakened(unittest.TestCase):
    """The condition decides whether a token is admitted to the POOL at all."""

    def assertRejected(self, text, needle="attribute_condition"):
        failures = check_artifact(GCP_TF, text)
        self.assertTrue(failures, "the guard accepted a weakened GCP pool condition")
        self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_condition_deleted(self):
        self.assertRejected(mutate(source(GCP_TF), GCP_CONDITION, ""))

    def test_condition_widened_to_a_wildcard(self):
        text = mutate(
            source(GCP_TF), GCP_CONDITION,
            '  attribute_condition = "assertion.sub.startsWith(\'org:\')"',
        )
        self.assertRejected(text)

    def test_condition_matched_loosely_rather_than_for_equality(self):
        # CEL has several operators that admit more than one org. Any of them is the hole.
        text = mutate(
            source(GCP_TF), GCP_CONDITION,
            '  attribute_condition = "assertion.sub.matches(\'${local.subject}\')"',
        )
        self.assertRejected(text)

    def test_condition_hardcoded_to_another_org(self):
        text = mutate(
            source(GCP_TF), GCP_CONDITION,
            '  attribute_condition = "assertion.sub == \'org:00000000-0000-0000-0000-000000000000\'"',
        )
        self.assertRejected(text)

    def test_the_local_the_condition_resolves_through_is_repointed(self):
        # The condition stays byte-identical while the whole module points at one hardcoded org.
        text = mutate(
            source(GCP_TF),
            '  subject    = "org:${var.org_uid}"',
            '  subject    = "org:00000000-0000-0000-0000-000000000000"',
        )
        failures = check_artifact(GCP_TF, text)
        self.assertTrue(failures, "a repointed local left the pin looking correct")


class GcpImpersonationBindingCannotBeWidened(unittest.TestCase):
    """The wildcard-shaped hole: `principalSet://.../<pool>/*` is every org in the pool."""

    def assertRejected(self, text, needle="member"):
        failures = check_artifact(GCP_TF, text)
        self.assertTrue(failures, "the guard accepted a widened impersonation binding")
        self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_the_industry_copy_paste_principal_set_wildcard(self):
        text = mutate(
            source(GCP_TF), GCP_MEMBER,
            '  member             = "principalSet://iam.googleapis.com/'
            '${google_iam_workload_identity_pool.ringleader.name}/*"',
        )
        self.assertRejected(text, "principalSet")

    def test_a_principal_set_on_an_attribute_is_still_a_set(self):
        text = mutate(
            source(GCP_TF), GCP_MEMBER,
            '  member             = "principalSet://iam.googleapis.com/'
            '${google_iam_workload_identity_pool.ringleader.name}/attribute.x/y"',
        )
        self.assertRejected(text, "principalSet")

    def test_the_subject_segment_is_dropped(self):
        text = mutate(
            source(GCP_TF), GCP_MEMBER,
            '  member             = "principal://iam.googleapis.com/'
            '${google_iam_workload_identity_pool.ringleader.name}"',
        )
        self.assertRejected(text)

    def test_the_binding_names_another_org(self):
        text = mutate(
            source(GCP_TF), GCP_MEMBER,
            '  member             = "principal://iam.googleapis.com/'
            '${google_iam_workload_identity_pool.ringleader.name}'
            '/subject/org:00000000-0000-0000-0000-000000000000"',
        )
        self.assertRejected(text)

    def test_the_binding_names_a_pool_the_guarded_provider_is_not_in(self):
        # The wiring half: a pinned condition on a provider in one pool proves nothing if the
        # binding admits a principal from another pool, which may carry no condition at all.
        text = mutate(
            source(GCP_TF), GCP_MEMBER,
            '  member             = "principal://iam.googleapis.com/'
            'projects/1/locations/global/workloadIdentityPools/other/subject/${local.subject}"',
        )
        self.assertRejected(text)


class GcpAudienceCannotBeWeakened(unittest.TestCase):
    def test_the_audience_is_another_clouds(self):
        text = mutate(
            source(GCP_TF),
            '  audience   = "${var.ringleader_issuer_url}/org/${var.org_uid}/gcp"',
            '  audience   = "${var.ringleader_issuer_url}/org/${var.org_uid}/aws"',
        )
        failures = check_artifact(GCP_TF, text)
        self.assertTrue(any("/gcp" in f for f in failures), failures)

    def test_allowed_audiences_deleted(self):
        text = mutate(source(GCP_TF), "    allowed_audiences = [local.audience]\n", "")
        failures = check_artifact(GCP_TF, text)
        self.assertTrue(any("allowed_audiences" in f for f in failures), failures)


class GcpScanningNothingIsLoud(unittest.TestCase):
    """A renamed or duplicated resource must fail, never pass while scanning nothing."""

    def test_the_provider_resource_renamed(self):
        text = source(GCP_TF).replace(
            'resource "google_iam_workload_identity_pool_provider"',
            'resource "google_iam_workload_identity_pool_provider_v2"',
        )
        with self.assertRaises(GuardError):
            check_artifact(GCP_TF, text)

    def test_a_second_binding_is_loud(self):
        # A second workloadIdentityUser binding is a second way in, and the checks describe one.
        text = source(GCP_TF) + '''
resource "google_service_account_iam_member" "second" {
  service_account_id = google_service_account.onboarding.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/x/*"
}
'''
        with self.assertRaises(GuardError):
            check_artifact(GCP_TF, text)


# ======================================================================================
# GCP -- the gcloud script, which AUTHORS the same two pins rather than applying the module
# ======================================================================================


class GcpScriptPinsCannotBeWeakened(unittest.TestCase):
    def assertRejected(self, text, needle=""):
        failures = check_artifact(GCP_SH, text)
        self.assertTrue(failures, "the guard accepted a weakened gcloud pin")
        if needle:
            self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_the_subject_is_hardcoded(self):
        self.assertRejected(
            mutate(source(GCP_SH), 'SUBJECT="org:${ORG_UID}"',
                   'SUBJECT="org:00000000-0000-0000-0000-000000000000"'),
            "ORG_UID",
        )

    def test_only_the_update_path_is_weakened(self):
        # This script writes the condition TWICE, and an operator re-running onboarding takes the
        # second one. Checking the first occurrence only would pass this.
        text = source(GCP_SH)
        want = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''
        self.assertEqual(text.count(want), 2, "the script no longer writes the condition twice")
        head, _, tail = text.rpartition(want)
        self.assertRejected(head + '''--attribute-condition "assertion.sub.startsWith(\'org:\')"''' + tail)

    def test_every_condition_removed_is_loud(self):
        # Each provider write is judged on its OWN flags, so this is a finding that NAMES the write
        # rather than a "cannot scan" GuardError -- the command is perfectly readable, it has simply
        # lost its pin. The GuardError is reserved for the provider write vanishing entirely, below.
        text = source(GCP_SH).replace("--attribute-condition", "--no-such-flag")
        failures = check_artifact(GCP_SH, text)
        self.assertEqual(len(failures), 2, failures)
        self.assertTrue(all("attribute-condition" in f for f in failures), failures)

    def test_the_provider_write_vanishing_is_loud(self):
        text = source(GCP_SH).replace("workload-identity-pools providers create-oidc", "true #") \
                             .replace("workload-identity-pools providers update-oidc", "true #")
        with self.assertRaises(GuardError):
            check_artifact(GCP_SH, text)

    def test_the_binding_takes_the_principal_set_wildcard(self):
        self.assertRejected(
            mutate(source(GCP_SH),
                   '--member "principal://iam.googleapis.com/${POOL_NAME}/subject/${SUBJECT}"',
                   '--member "principalSet://iam.googleapis.com/${POOL_NAME}/*"'),
            "principalSet",
        )

    def test_the_audience_is_another_clouds(self):
        self.assertRejected(mutate(source(GCP_SH), 'AUDIENCE="${ISSUER}/gcp"',
                                   'AUDIENCE="${ISSUER}/aws"'), "AUDIENCE")


# ======================================================================================
# Azure -- no operator to loosen, so the loss mode is a widened, dropped or repointed field
# ======================================================================================


class AzureTerraformPinCannotBeWeakened(unittest.TestCase):
    def assertRejected(self, text, needle=""):
        failures = check_artifact(AZURE_TF, text)
        self.assertTrue(failures, "the guard accepted a weakened Azure credential")
        if needle:
            self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_the_subject_is_dropped(self):
        self.assertRejected(mutate(source(AZURE_TF), "  subject        = local.subject\n", ""), "subject")

    def test_the_subject_is_hardcoded_to_another_org(self):
        self.assertRejected(
            mutate(source(AZURE_TF), '  subject  = "org:${var.org_uid}"',
                   '  subject  = "org:00000000-0000-0000-0000-000000000000"'),
        )

    def test_the_subject_is_widened(self):
        self.assertRejected(mutate(source(AZURE_TF), '  subject  = "org:${var.org_uid}"',
                                   '  subject  = "org:*"'))

    def test_a_second_audience_widens_the_credential(self):
        self.assertRejected(
            mutate(source(AZURE_TF), "  audiences      = [local.audience]",
                   '  audiences      = [local.audience, "api://Other"]'),
            "audiences",
        )

    def test_the_credential_is_attached_to_a_second_application(self):
        # The wiring half: a perfectly pinned credential on an application nobody uses.
        text = mutate(
            source(AZURE_TF), "  application_id = azuread_application.workstations[0].id",
            '  application_id = "/applications/00000000-0000-0000-0000-000000000000"',
        )
        self.assertRejected(text, "application_id")

    def test_the_credential_resource_renamed(self):
        text = source(AZURE_TF).replace(
            'resource "azuread_application_federated_identity_credential"',
            'resource "azuread_application_federated_identity_credential_v2"',
        )
        with self.assertRaises(GuardError):
            check_artifact(AZURE_TF, text)


class AzureScriptPinCannotBeWeakened(unittest.TestCase):
    def assertRejected(self, text, needle=""):
        failures = check_artifact(AZURE_SH, text)
        self.assertTrue(failures, "the guard accepted a weakened Azure credential body")
        if needle:
            self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_the_subject_is_hardcoded(self):
        self.assertRejected(
            mutate(source(AZURE_SH), 'SUBJECT="org:${ORG_UID}"',
                   'SUBJECT="org:00000000-0000-0000-0000-000000000000"'),
            "ORG_UID",
        )

    def test_the_credential_body_widens_the_subject(self):
        self.assertRejected(mutate(source(AZURE_SH), '"subject": "${SUBJECT}",',
                                   '"subject": "org:*",'), "subject")

    def test_the_credential_body_loses_the_subject(self):
        text = source(AZURE_SH).replace('"subject": "${SUBJECT}",', "")
        with self.assertRaises(GuardError):
            check_artifact(AZURE_SH, text)

    def test_the_issuer_is_repointed(self):
        self.assertRejected(mutate(source(AZURE_SH), '"issuer": "${ISSUER}",',
                                   '"issuer": "https://example.invalid",'), "issuer")

    def test_a_second_audience_widens_the_credential(self):
        self.assertRejected(
            mutate(source(AZURE_SH), '"audiences": ["api://AzureADTokenExchange"],',
                   '"audiences": ["api://AzureADTokenExchange", "api://Other"],'),
            "audiences",
        )


# ======================================================================================
# The four bypasses an adversarial review of this guard found and this guard now closes.
# Each is a weakening that SHIPS GREEN unless the check below holds.
# ======================================================================================


class ACelConditionCannotBeLoosenedWithoutAnOperator(unittest.TestCase):
    """CEL has no wildcard to spot, so the condition is held to a closed grammar."""

    def assertRejected(self, cel):
        text = mutate(source(GCP_TF), GCP_CONDITION, f'  attribute_condition = "{cel}"')
        self.assertTrue(check_artifact(GCP_TF, text), f"the guard accepted `{cel}`")

    def test_or_ed_with_something_always_true(self):
        # Names the right org, calls no function, carries no wildcard -- and admits the fleet.
        self.assertRejected("true || assertion.sub == '${local.subject}'")

    def test_or_ed_with_a_trailing_disjunct(self):
        # The greedy-capture case: the closing quote must not be swallowed.
        self.assertRejected("assertion.sub == '${local.subject}' || assertion.sub != ''")

    def test_and_ed_with_something_always_true(self):
        self.assertRejected("assertion.sub == '${local.subject}' && true")

    def test_matched_loosely(self):
        self.assertRejected("assertion.sub.startsWith('org:')")
        self.assertRejected("assertion.sub in ['a','b']")


class BothGcloudFlagSpellingsAreRead(unittest.TestCase):
    """`--flag=value` reaches gcloud identically to `--flag value`, and this script uses both."""

    def loosen_only_the_update_path(self, replacement):
        text = source(GCP_SH)
        want = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''
        self.assertEqual(text.count(want), 2, "the script no longer writes the condition twice")
        head, _, tail = text.rpartition(want)
        return head + replacement + tail

    def test_the_equals_spelling_is_seen(self):
        text = self.loosen_only_the_update_path(
            '''--attribute-condition="assertion.sub.startsWith(\'org:\')"''')
        self.assertTrue(check_artifact(GCP_SH, text), "a --flag= weakening was invisible")

    def test_the_single_quoted_spelling_is_seen(self):
        text = self.loosen_only_the_update_path(
            '''--attribute-condition=\'assertion.sub != ""\'''')
        self.assertTrue(check_artifact(GCP_SH, text), "a single-quoted weakening was invisible")

    def test_an_extra_principal_set_binding_is_seen(self):
        for spelling in (
            '--member="principalSet://iam.googleapis.com/${POOL_NAME}/*"',
            "--member='principalSet://iam.googleapis.com/${POOL_NAME}/*'",
        ):
            with self.subTest(spelling):
                text = source(GCP_SH) + (
                    '\ngcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" '
                    '--role=roles/iam.workloadIdentityUser ' + spelling + '\n'
                )
                failures = check_artifact(GCP_SH, text)
                self.assertTrue(any("principalSet" in f for f in failures), failures)

    def test_a_provider_written_with_no_condition_is_seen(self):
        # The count check: an added create-oidc without a condition leaves the existing two intact.
        text = source(GCP_SH) + (
            '\ngcloud iam workload-identity-pools providers create-oidc other '
            '--workload-identity-pool "$POOL" --issuer-uri "$ISSUER"\n'
        )
        failures = check_artifact(GCP_SH, text)
        self.assertTrue(any("attribute-condition" in f for f in failures), failures)


class TheIssuerIsPinnedOnTheScriptPathsToo(unittest.TestCase):
    """Repoint the issuer and the cloud trusts tokens this org never minted -- and whoever mints
    them chooses the subject too, so the subject pin is no defence."""

    def test_gcloud_issuer_repointed(self):
        text = mutate(source(GCP_SH), 'ISSUER="${ISSUER_URL}/org/${ORG_UID}"',
                      'ISSUER="https://attacker.example/org/${ORG_UID}"')
        failures = check_artifact(GCP_SH, text)
        self.assertTrue(any("ISSUER" in f for f in failures), failures)

    def test_azure_issuer_repointed(self):
        text = mutate(source(AZURE_SH), 'ISSUER="${ISSUER_URL}/org/${ORG_UID}"',
                      'ISSUER="https://attacker.example/shared"')
        failures = check_artifact(AZURE_SH, text)
        self.assertTrue(any("ISSUER" in f for f in failures), failures)


class AReassignedShellPinIsSeen(unittest.TestCase):
    """The LAST assignment is the one that ships; a column-0 anchor would judge the first."""

    def test_an_indented_reassignment_is_loud(self):
        text = mutate(
            source(GCP_SH), 'SUBJECT="org:${ORG_UID}"',
            'SUBJECT="org:${ORG_UID}"\nif true; then\n'
            '  SUBJECT="org:00000000-0000-0000-0000-000000000000"\nfi',
        )
        with self.assertRaises(GuardError):
            check_artifact(GCP_SH, text)


class TextThatNeverRunsCannotSatisfyTheGuard(unittest.TestCase):
    """A tally can be restored by text that never executes; a per-command check cannot be fooled."""

    def drop_the_create_path_condition(self, decoy=""):
        text = source(GCP_SH)
        cond = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''
        self.assertEqual(text.count(cond), 2, "the script no longer writes the condition twice")
        return text.replace(cond, decoy, 1)

    def test_a_hash_comment_does_not_restore_it(self):
        text = self.drop_the_create_path_condition("# " + '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"''')
        self.assertTrue(check_artifact(GCP_SH, text), "a commented-out flag satisfied the guard")

    def test_a_heredoc_does_not_restore_it(self):
        text = self.drop_the_create_path_condition() + (
            "\n: <<'DOC'\n"
            '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''
            "\nDOC\n"
        )
        self.assertTrue(check_artifact(GCP_SH, text), "a heredoc satisfied the guard")

    def test_a_doc_comment_naming_the_command_is_NOT_a_false_positive(self):
        # The other direction: a guard that cries wolf gets deleted rather than fixed.
        text = mutate(
            source(GCP_SH), "#!/usr/bin/env bash",
            "#!/usr/bin/env bash\n"
            "# Uses `gcloud iam workload-identity-pools providers create-oidc` under the hood.",
        )
        self.assertEqual(check_artifact(GCP_SH, text), [])


class TheIssuerIsHeldToTheExactString(unittest.TestCase):
    """"Mentions both variables" is not "is the right issuer"."""

    def test_a_suffix_onto_an_attacker_host(self):
        for art in (GCP_SH, AZURE_SH):
            with self.subTest(art.path):
                text = mutate(source(art), 'ISSUER="${ISSUER_URL}/org/${ORG_UID}"',
                              'ISSUER="${ISSUER_URL}.attacker.example/org/${ORG_UID}"')
                self.assertTrue(any("ISSUER" in f for f in check_artifact(art, text)))

    def test_a_path_that_climbs_out(self):
        text = mutate(source(GCP_SH), 'ISSUER="${ISSUER_URL}/org/${ORG_UID}"',
                      'ISSUER="${ISSUER_URL}/org/${ORG_UID}/../../fleet"')
        self.assertTrue(any("ISSUER" in f for f in check_artifact(GCP_SH, text)))


class AListThisGuardCannotReadSaysSo(unittest.TestCase):
    """Reporting "the pin is missing" on a correct file is how a guard gets deleted."""

    def test_a_reflowed_audiences_list_is_a_loud_cannot_read(self):
        text = mutate(source(AZURE_TF), "  audiences      = [local.audience]",
                      "  audiences = [\n    local.audience,\n  ]")
        with self.assertRaises(GuardError):
            check_artifact(AZURE_TF, text)

    def test_the_braced_audience_spelling_is_accepted(self):
        # Both provider writes carry the flag, so both are rewritten -- `${AUDIENCE}` and
        # `$AUDIENCE` are the same value to the shell and neither may turn a correct file red.
        original = source(GCP_SH)
        self.assertEqual(original.count('--allowed-audiences "$AUDIENCE"'), 2)
        text = original.replace('--allowed-audiences "$AUDIENCE"',
                                '--allowed-audiences "${AUDIENCE}"')
        self.assertEqual(check_artifact(GCP_SH, text), [])


class TheAzureAudienceValueIsJudged(unittest.TestCase):
    def test_the_script_credential_loses_its_audiences(self):
        text = mutate(source(AZURE_SH), '  "audiences": ["api://AzureADTokenExchange"],\n', "")
        self.assertTrue(any("audiences" in f for f in check_artifact(AZURE_SH, text)))

    def test_the_terraform_credential_is_repointed(self):
        text = mutate(source(AZURE_TF), '  audience = "api://AzureADTokenExchange"',
                      '  audience = "api://SomethingElse"')
        self.assertTrue(any("audience" in f for f in check_artifact(AZURE_TF, text)))


class AnAssignmentIsReadTheWayTheShellReadsOne(unittest.TestCase):
    """The LAST assignment is what the script runs with, in whatever spelling it is written."""

    SPELLINGS = [
        ("unquoted", "\nSUBJECT=org:00000000-0000-0000-0000-000000000000\n"),
        ("single-quoted", "\nSUBJECT='org:00000000-0000-0000-0000-000000000000'\n"),
        ("export", '\nexport ISSUER="https://attacker.example/org/${ORG_UID}"\n'),
        ("indented in an if", "\nif true; then\n  SUBJECT=org:00000000-0000-0000-0000-000000000000\nfi\n"),
        ("declare -r", '\ndeclare -r SUBJECT="org:00000000-0000-0000-0000-000000000000"\n'),
    ]

    def test_a_second_assignment_is_loud_in_every_spelling(self):
        for artifact in (GCP_SH, AZURE_SH):
            for label, extra in self.SPELLINGS:
                with self.subTest(f"{artifact.path} {label}"):
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, source(artifact) + extra)

    def test_readonly_on_the_one_correct_assignment_is_not_a_false_positive(self):
        # An ordinary hardening edit must not turn a correct file red -- a guard that cries wolf
        # gets deleted rather than fixed.
        text = mutate(source(GCP_SH), 'SUBJECT="org:${ORG_UID}"', 'readonly SUBJECT="org:${ORG_UID}"')
        self.assertEqual(check_artifact(GCP_SH, text), [])

    def test_export_on_the_one_correct_issuer_is_not_a_false_positive(self):
        text = mutate(source(AZURE_SH), 'ISSUER="${ISSUER_URL}/org/${ORG_UID}"',
                      'export ISSUER="${ISSUER_URL}/org/${ORG_UID}"')
        self.assertEqual(check_artifact(AZURE_SH, text), [])


class ACommandIsAFragmentNotALine(unittest.TestCase):
    """`gcloud ... ; : --attribute-condition "<right value>"` creates the provider without one."""

    MAP = '--attribute-mapping "google.subject=assertion.sub"'
    COND = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''

    def decoy(self, sep):
        text = source(GCP_SH)
        both = self.MAP + " \\\n    " + self.COND
        self.assertEqual(text.count(both), 2, "the create/update calls no longer share this shape")
        return text.replace(both, self.MAP + " " + sep + " : " + self.COND, 1)

    def test_a_semicolon_decoy_does_not_satisfy_the_count(self):
        failures = check_artifact(GCP_SH, self.decoy(";"))
        self.assertTrue(any("attribute-condition" in f for f in failures), failures)

    def test_an_and_decoy_does_not_satisfy_the_count(self):
        failures = check_artifact(GCP_SH, self.decoy("&&"))
        self.assertTrue(any("attribute-condition" in f for f in failures), failures)


class OneTokenizerReadsBothFlagsAndAssignments(unittest.TestCase):
    """Two readers with two notions of "a command" is how a bypass survives a fix."""

    SECOND_ASSIGNMENT = [
        ("after a semicolon", '\ntrue; SUBJECT="org:00000000-0000-0000-0000-000000000000"\n'),
        ("inside a one-line if", '\nif true; then SUBJECT="org:00000000-0000-0000-0000-000000000000"; fi\n'),
        ("after &&", '\ntrue && SUBJECT="org:00000000-0000-0000-0000-000000000000"\n'),
        ("typeset", '\ntypeset SUBJECT="org:00000000-0000-0000-0000-000000000000"\n'),
        ("declare with two flag groups", '\ndeclare -x -r SUBJECT="org:00000000-0000-0000-0000-000000000000"\n'),
        ("+= append", '\nSUBJECT+=".evil"\n'),
        ("a repointed issuer after a semicolon", '\ntrue; ISSUER="https://attacker.example/org/${ORG_UID}"\n'),
    ]

    def test_a_second_assignment_anywhere_is_loud(self):
        for artifact in (GCP_SH, AZURE_SH):
            for label, extra in self.SECOND_ASSIGNMENT:
                with self.subTest(f"{artifact.path} {label}"):
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, source(artifact) + extra)

    def test_declare_g_on_the_one_assignment_is_not_a_false_positive(self):
        text = mutate(source(GCP_SH), 'SUBJECT="org:${ORG_UID}"', 'declare -g SUBJECT="org:${ORG_UID}"')
        self.assertEqual(check_artifact(GCP_SH, text), [])


class ASubstitutionIsNotAnArgument(unittest.TestCase):
    """A flag inside `$( )` reads correctly here and never reaches gcloud."""

    COND = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''

    def test_a_dollar_paren_decoy_is_refused(self):
        text = source(GCP_SH).replace(self.COND, "$(: " + self.COND + ")", 1)
        failures = check_artifact(GCP_SH, text)
        self.assertTrue(any("substitution" in f for f in failures), failures)

    def test_a_backtick_decoy_is_refused(self):
        text = source(GCP_SH).replace(self.COND, "`: " + self.COND + "`", 1)
        failures = check_artifact(GCP_SH, text)
        self.assertTrue(any("substitution" in f for f in failures), failures)


class AShellPinIsTheValueNotASubstring(unittest.TestCase):
    """`org:VICTIM${zz:+${ORG_UID}}` carries the text and expands to somebody else."""

    DECOY = 'org:00000000-0000-0000-0000-000000000000${zz:+${ORG_UID}}'

    def test_a_nested_expansion_decoy_is_refused(self):
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact.path):
                text = mutate(source(artifact), 'SUBJECT="org:${ORG_UID}"', f'SUBJECT="{self.DECOY}"')
                failures = check_artifact(artifact, text)
                self.assertTrue(any("SUBJECT" in f for f in failures), failures)

    def test_an_adjacent_quote_concatenation_is_refused(self):
        text = mutate(source(GCP_SH), 'SUBJECT="org:${ORG_UID}"',
                      'SUBJECT="org:0000""0000${zz:+${ORG_UID}}"')
        self.assertTrue(any("SUBJECT" in f for f in check_artifact(GCP_SH, text)))

    def test_the_audience_is_held_to_the_exact_string(self):
        text = source(GCP_SH).replace('AUDIENCE="${ISSUER}/gcp"', 'AUDIENCE="${ISSUER}/gcp-x${zz:+}"')
        self.assertTrue(any("AUDIENCE" in f for f in check_artifact(GCP_SH, text)))


class EverySeparatorTheShellSplitsOn(unittest.TestCase):
    """A bare `&` backgrounds what precedes it and starts a new command, like `;` does."""

    MAP = '--attribute-mapping "google.subject=assertion.sub"'
    COND = '''--attribute-condition "assertion.sub == \'${SUBJECT}\'"'''

    def decoy(self, sep):
        text = source(GCP_SH)
        both = self.MAP + " \\\n    " + self.COND
        self.assertEqual(text.count(both), 2, "the create/update calls no longer share this shape")
        return text.replace(both, self.MAP + " \\\n    " + sep + " : " + self.COND, 1)

    def test_a_bare_ampersand_decoy_is_caught(self):
        self.assertTrue(any("attribute-condition" in f for f in check_artifact(GCP_SH, self.decoy("&"))))

    def test_a_pipe_decoy_is_caught(self):
        self.assertTrue(any("attribute-condition" in f for f in check_artifact(GCP_SH, self.decoy("|"))))

    def test_an_assignment_after_a_bare_ampersand_is_loud(self):
        with self.assertRaises(GuardError):
            check_artifact(GCP_SH, source(GCP_SH) + '\ntrue & SUBJECT="org:VICTIM"\n')


class ThePinsRootVariablesAreJudgedToo(unittest.TestCase):
    """SUBJECT and ISSUER are exact strings, so the attack moves to what they interpolate."""

    ORG = 'ORG_UID="${ORG_UID:?set ORG_UID to your Ringleader organization id, a UUID}"'
    URL = ('ISSUER_URL="${ISSUER_URL:?set ISSUER_URL to the Ringleader issuer origin, '
           'e.g. https://oidc-app.ringleader.dev}"')

    def test_a_hardcoded_org_uid_is_caught_on_both_scripts(self):
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact.path):
                text = mutate(source(artifact), self.ORG, 'ORG_UID="00000000-0000-0000-0000-000000000000"')
                self.assertTrue(any("ORG_UID" in f for f in check_artifact(artifact, text)))

    def test_a_repointed_issuer_url_is_caught_on_both_scripts(self):
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact.path):
                text = mutate(source(artifact), self.URL, 'ISSUER_URL="https://attacker.example"')
                self.assertTrue(any("ISSUER_URL" in f for f in check_artifact(artifact, text)))

    def test_a_second_org_uid_assignment_is_loud(self):
        with self.assertRaises(GuardError):
            check_artifact(GCP_SH, source(GCP_SH) + '\nORG_UID="VICTIM"\n')


if __name__ == "__main__":
    unittest.main()


# ======================================================================================
# The closed grammar: every way to bind a pin that is NOT an assignment
# ======================================================================================


class ARebindingSpelledAnyOtherWayIsRefused(unittest.TestCase):
    """The shapes a denylist of assignment spellings cannot see.

    Every case leaves the script's own correct `SUBJECT="org:${ORG_UID}"` untouched and appends a
    SECOND binding of the same name in a shape that is not an assignment. Under the old reader each
    one passed: it counted one assignment, judged it perfect, and never saw the rebinding that
    decides what the script actually runs with. They are held to a GuardError rather than a finding
    because the file is refused, not scanned -- that is what a closed grammar buys.

    None of these shapes is present in the shipped scripts; this is the surface a hostile PR would
    reach for, not a defect in what ships today.
    """

    ANCHOR = 'SUBJECT="org:${ORG_UID}"'
    EVIL = "org:00000000-0000-0000-0000-000000000000"

    def shapes(self):
        e = self.EVIL
        return {
            "read_from_a_herestring": f'read -r SUBJECT <<< "{e}"',
            "printf_v": f"printf -v SUBJECT %s \"{e}\"",
            "eval": f"eval 'SUBJECT=\"{e}\"'",
            "a_loop_variable": f'for SUBJECT in "{e}"; do :; done',
            "a_brace_group": f'{{ SUBJECT="{e}"; }}',
            "a_function_body": f'rebind() {{ SUBJECT="{e}"; }}\nrebind',
            "a_sourced_herestring": f"source /dev/stdin <<< 'SUBJECT=\"{e}\"'",
            "a_case_arm": f'case x in x) SUBJECT="{e}";; esac',
        }

    def test_every_shape_is_refused_on_both_scripts(self):
        for artifact in (GCP_SH, AZURE_SH):
            text = source(artifact)
            for label, injection in self.shapes().items():
                with self.subTest(artifact=artifact.path, shape=label):
                    mutated = mutate(text, self.ANCHOR, self.ANCHOR + "\n" + injection)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, mutated)

    def test_the_refusal_names_the_pin_and_the_statement(self):
        # A loud failure nobody can act on is only half a guard. The message has to say WHICH name
        # was rebound and by what, or the next contributor deletes the guard instead of the line.
        text = mutate(source(GCP_SH), self.ANCHOR,
                      self.ANCHOR + '\nread -r SUBJECT <<< "org:elsewhere"')
        with self.assertRaises(GuardError) as caught:
            check_artifact(GCP_SH, text)
        message = str(caught.exception)
        self.assertIn("SUBJECT", message)
        self.assertIn("read", message)

    def test_every_root_variable_is_covered_too(self):
        # ORG_UID and ISSUER_URL are what every pin RESOLVES THROUGH, so rebinding one of them is
        # the same attack a level down -- and they are the pair a previous round found unjudged.
        for name, anchor in (
            ("ORG_UID", 'ORG_UID="${ORG_UID:?'),
            ("ISSUER_URL", 'ISSUER_URL="${ISSUER_URL:?'),
        ):
            with self.subTest(name=name):
                text = source(GCP_SH)
                line = next(l for l in text.splitlines() if l.startswith(anchor))
                mutated = mutate(text, line, line + f'\nread -r {name} <<< "elsewhere"')
                with self.assertRaises(GuardError):
                    check_artifact(GCP_SH, mutated)


class TheGrammarRefusesWhatItCannotRead(unittest.TestCase):
    """A shape the guard cannot classify is a LOUD failure, never a silent pass.

    This is the rule the HCL and YAML readers already state, and the reason the shell side is now a
    closed grammar: an unrecognised statement is where a rebinding hides, so it is refused rather
    than skipped. Widening the grammar is a deliberate edit to SH_COMMANDS with a test beside it.
    """

    def test_an_unknown_command_is_refused(self):
        text = mutate(source(GCP_SH), 'SUBJECT="org:${ORG_UID}"',
                      'SUBJECT="org:${ORG_UID}"\nsome_helper --do-a-thing')
        with self.assertRaises(GuardError) as caught:
            check_artifact(GCP_SH, text)
        self.assertIn("some_helper", str(caught.exception))

    def test_both_shipped_scripts_are_fully_classified(self):
        # The other half: the grammar has to ACCEPT what ships, or it is a guard nobody can keep.
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact=artifact.path):
                self.assertEqual(check_artifact(artifact, source(artifact)), [])


class CorrectlySpelledAssignmentsStayGreen(unittest.TestCase):
    """The grammar must not turn a correct file red, which is how a guard gets deleted.

    Each of these is the SAME pin, spelled another legitimate way. Missing one fails in the
    direction nobody notices until an ordinary hardening edit is blamed on the guard.
    """

    ANCHOR = 'SUBJECT="org:${ORG_UID}"'

    def test_every_legitimate_spelling_is_accepted(self):
        for label, spelling in {
            "readonly": 'readonly SUBJECT="org:${ORG_UID}"',
            "declare -g": 'declare -g SUBJECT="org:${ORG_UID}"',
            "export": 'export SUBJECT="org:${ORG_UID}"',
            "typeset -r": 'typeset -r SUBJECT="org:${ORG_UID}"',
            "unquoted": "SUBJECT=org:${ORG_UID}",
            "behind a then": 'if true; then SUBJECT="org:${ORG_UID}"; fi',
        }.items():
            with self.subTest(spelling=label):
                mutated = mutate(source(GCP_SH), self.ANCHOR, spelling)
                self.assertEqual(check_artifact(GCP_SH, mutated), [])

    def test_a_heredoc_body_is_data_and_not_commands(self):
        # deploy.sh hands `az` a JSON document through `$(cat <<JSON ...)`. Its lines are not
        # statements, and a grammar that judged them would refuse the file it is meant to pass.
        self.assertEqual(check_artifact(AZURE_SH, source(AZURE_SH)), [])
        self.assertIn("<<JSON", source(AZURE_SH))


class TheGrammarClosesTheSecondRoundOfShapes(unittest.TestCase):
    """Shapes found by attacking the grammar itself, after it closed the eight the issue named.

    Each is a way to bind a pin that is not an assignment and is not one of the original eight.
    The first is the one that mattered most: a statement may carry a RUN of assignments before a
    command, so reading only its first `NAME=` classified `IFS= read -r SUBJECT` as an assignment
    to `IFS` and never looked at the `read`.
    """

    ANCHOR = 'SUBJECT="org:${ORG_UID}"'
    EVIL = "org:00000000-0000-0000-0000-000000000000"

    def assertRefused(self, injection):
        text = mutate(source(GCP_SH), self.ANCHOR, self.ANCHOR + "\n" + injection)
        with self.assertRaises(GuardError):
            check_artifact(GCP_SH, text)

    def test_an_assignment_prefix_cannot_hide_a_binder(self):
        # `IFS= read -r SUBJECT` assigns IFS *and* rebinds SUBJECT. Both halves have to be seen.
        self.assertRefused('IFS= read -r SUBJECT < /dev/null')

    def test_a_nameref_alias(self):
        # `declare -n ref=SUBJECT` makes an ordinary-looking `ref=` assignment rebind the pin, with
        # the pin's own name nowhere near the line that does it.
        self.assertRefused(f'declare -n ref=SUBJECT\nref="{self.EVIL}"')

    def test_an_assigning_expansion(self):
        # `${NAME:=value}` assigns, and it can ride inside an argument to an allowed command.
        self.assertRefused(f'echo "${{SUBJECT:={self.EVIL}}}"')

    def test_a_coprocess_names_a_variable(self):
        self.assertRefused('coproc SUBJECT { echo hi; }')

    def test_a_trap_body_is_not_read(self):
        self.assertRefused(f"trap 'SUBJECT=\"{self.EVIL}\"' EXIT")

    def test_process_substitution_is_refused(self):
        self.assertRefused(f'cat <(echo "{self.EVIL}")')

    def test_a_command_scoped_prefix_on_a_pin_is_refused(self):
        # `SUBJECT=x cmd` does NOT persist, so this cannot rebind -- but a reader that has to
        # reason about which assignments persist is the reader this grammar exists to stop being.
        self.assertRefused(f'SUBJECT="{self.EVIL}" gcloud version')

    def test_an_ordinary_assignment_holding_a_command_substitution_still_reads(self):
        # The other direction, and the one a nesting-blind value scanner breaks: the shipped script
        # assigns from `$(gcloud ... )`, whose value contains spaces and is still ONE word.
        self.assertIn("POOL_NAME=$(gcloud", source(GCP_SH))
        self.assertEqual(check_artifact(GCP_SH, source(GCP_SH)), [])


class ARunnerPrefixCannotLaunderABinder(unittest.TestCase):
    """`command`, `time`, `env` and friends RUN what follows them, so they cannot be a head.

    Left in the allow-list they were a free pass for every refusal above: `command eval
    SUBJECT=org:VICTIM` rebinds the pin for real -- `bash -c 'SUBJECT=a; command eval SUBJECT=b;
    echo $SUBJECT'` prints `b` -- while the grammar saw the allowed head `command` and stopped.
    They are peeled instead, so the thing they run is judged on its own terms.
    """

    ANCHOR = 'SUBJECT="org:${ORG_UID}"'

    def test_every_runner_prefixed_binder_is_refused_on_both_scripts(self):
        for artifact in (GCP_SH, AZURE_SH):
            for label, injection in {
                "command eval": "command eval SUBJECT=org:VICTIM",
                "command read": 'command read SUBJECT <<< "org:VICTIM"',
                "time eval": "time eval SUBJECT=org:VICTIM",
                "builtin read": 'builtin read SUBJECT <<< "org:VICTIM"',
                "env prefix": "env SUBJECT=org:VICTIM gcloud version",
                "nohup eval": "nohup eval SUBJECT=org:VICTIM",
                "doubled command": "command command eval SUBJECT=org:VICTIM",
                "command printf -v": "command printf -v SUBJECT %s org:VICTIM",
                "timeout then eval": "timeout 5 eval SUBJECT=org:VICTIM",
            }.items():
                with self.subTest(artifact=artifact.path, runner=label):
                    text = mutate(source(artifact), self.ANCHOR, self.ANCHOR + "\n" + injection)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, text)

    def test_an_arithmetic_context_cannot_rebind_a_pin(self):
        # `JUNK=$((SUBJECT=1337))` reads as one clean assignment to JUNK, and rebinds SUBJECT for
        # real: bash's arithmetic assignment is a shell side effect, not a subshell's.
        #   bash -c 'SUBJECT=org:orig; JUNK=$((SUBJECT="1337")); echo "$SUBJECT"'  ->  1337
        # A pin is a string -- an org id, a URL -- so it is never an arithmetic operand, and the
        # whole context is refused rather than the operators being enumerated.
        for artifact in (GCP_SH, AZURE_SH):
            for label, injection in {
                "command substitution": 'JUNK=$((SUBJECT="1337"))',
                "bare arithmetic": "(( SUBJECT = 1337 ))",
                "deprecated $[ ]": "JUNK=$[SUBJECT=1337]",
                "compound assign": "JUNK=$((SUBJECT+=1))",
                "increment": "JUNK=$((SUBJECT++))",
                "inside an argument": 'echo "$((ISSUER=1))"',
                "a root variable": "JUNK=$((ORG_UID=1))",
            }.items():
                with self.subTest(artifact=artifact.path, arithmetic=label):
                    text = mutate(source(artifact), self.ANCHOR, self.ANCHOR + "\n" + injection)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, text)

    def test_a_backslash_run_cannot_desync_the_splitter(self):
        """The escape check must count the backslash RUN, not look at one character.

        `\\"` is an escaped quote; `\\\\"` is an escaped BACKSLASH and then a real closing quote. A
        one-character lookback reads the second as "string still open" and swallows every following
        line into that statement -- so `echo "note\\\\"` on one line hid an ordinary
        `SUBJECT="org:VICTIM"` on the next from every check in this file, while bash ran both as
        two independent statements. That is a full confinement bypass, not a parsing nicety.
        """
        anchor = 'AUDIENCE="${ISSUER}/gcp"'
        for label, injection in {
            "even run closes the string": 'echo "note\\\\"\nSUBJECT="org:VICTIM"',
            "longer even run": 'echo "note\\\\\\\\"\nSUBJECT="org:VICTIM"',
            "odd run is a real escaped quote": 'echo "note\\""\nSUBJECT="org:VICTIM"',
            "single quotes escape nothing": "echo 'note\\'\nSUBJECT=\"org:VICTIM\"",
        }.items():
            with self.subTest(shape=label):
                text = mutate(source(GCP_SH), anchor, anchor + "\n" + injection)
                with self.assertRaises(GuardError):
                    check_artifact(GCP_SH, text)

    def test_a_bare_bracket_cannot_join_the_next_line_into_a_command(self):
        """A bare `(` or `[` is an ORDINARY WORD to bash, and must not continue a line here.

        The line-rejoiner and the statement splitter both counted one as an unclosed nesting, so
        `echo ok [` made the reader swallow the following line into that `echo` -- whose head is a
        known command, so the whole thing classified as `command` and the real
        `SUBJECT="org:VICTIM"` on the next line was never seen. Bash runs both:

            bash -c 'SUBJECT=a; echo ok [
            SUBJECT=org:VICTIM; echo "$SUBJECT"'   ->  ok [  /  org:VICTIM

        Only a quote, a backtick or a `$(`/`${`/`$[` substitution may carry a statement across a
        line break, which is what `_scan_shell` now enforces for both readers.
        """
        for artifact in (GCP_SH, AZURE_SH):
            for label, injection in {
                "bare [": 'echo ok [\nSUBJECT="org:VICTIM"',
                "bare (": 'echo ok (\nSUBJECT="org:VICTIM"',
                "bare { in a command": 'echo ok {\nSUBJECT="org:VICTIM"',
                "unmatched closer": 'echo ok )\nSUBJECT="org:VICTIM"',
                "bracket then a separator": 'echo ok [ ; SUBJECT="org:VICTIM"',
            }.items():
                with self.subTest(artifact=artifact.path, shape=label):
                    text = mutate(source(artifact), self.ANCHOR, self.ANCHOR + "\n" + injection)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, text)

    def test_an_escaped_quote_does_not_open_a_string(self):
        r"""`echo \'` is a complete statement printing one apostrophe, not an opening quote.

        The escape check ran only in the CLOSE direction, so nothing asked whether the quote that
        OPENS a string is itself escaped. `echo \'` left every scanner in single-quote state and
        swallowed the following line; a second `echo \'` re-closed it, so the swallow was SURGICAL
        -- exactly the injected `SUBJECT="org:VICTIM"` disappeared, the rest of the file parsed
        normally, and `bash -n`, `check_trust_pins.py` and `check_published_literals.py` were all
        green while bash bound the pin to the attacker's value.
        """
        for artifact in (GCP_SH, AZURE_SH):
            for label, opener in {
                "escaped single quote": "echo \\'",
                "escaped double quote": 'echo \\"',
                "escaped dollar-brace": "echo \\${",
                "escaped backtick": "echo \\`",
            }.items():
                with self.subTest(artifact=artifact.path, shape=label):
                    injected = f'{opener}\nSUBJECT="org:VICTIM"\n{opener}'
                    text = mutate(source(artifact), self.ANCHOR, self.ANCHOR + "\n" + injected)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, text)

    def test_a_real_substitution_still_carries_a_statement_across_lines(self):
        """...and the typing must not turn a CORRECT file red.

        `X="$(cat <<JSON` closes its `)"` on its own line once the heredoc body is gone, and
        `deploy.sh` really is written that way. A reader that stopped joining altogether would
        report that trailing `)"` as a statement it cannot classify -- a guard crying wolf on a
        file whose pins are perfect, which is how a guard gets deleted rather than fixed.
        """
        anchor = 'AUDIENCE="${ISSUER}/gcp"'
        for label, injection in {
            "$( ) over two lines": 'JUNK="$(echo\n  ok)"',
            "${ } over two lines": 'JUNK="${ISSUER:-\n  x}"',
            "an open quote": 'echo "two\nlines"',
            "an escaped quote is one statement": "echo \\'\necho ok",
            "an escaped quote in a value": "JUNK=a\\'b\necho ok",
            "a real quote after an escaped one": "echo \\' 'quoted'\necho ok",
        }.items():
            with self.subTest(shape=label):
                text = mutate(source(GCP_SH), anchor, anchor + "\n" + injection)
                self.assertEqual(check_artifact(GCP_SH, text), [], f"{label} turned a correct file red")

    def test_an_unmatched_bracket_cannot_swallow_the_next_assignment(self):
        """The value scanner must TYPE-MATCH its brackets and only nest on `$(`/`${`/`$[`.

        Pooling `(`, `[` and `{` into one untyped depth meant a bare `{` in a value raised it with
        nothing to lower it, so `JUNK={ SUBJECT="org:VICTIM"` swallowed the second assignment into
        JUNK's value. Bash reads that as two assignments -- `JUNK` gets the literal `{` and SUBJECT
        is rebound, persistently, for every later `--attribute-condition` and `--member`:
          bash -c 'SUBJECT=org:a; JUNK={ SUBJECT=org:VICTIM; echo "$SUBJECT"'  ->  org:VICTIM
        A value that never closes is refused too: bash would reject the script, and the scanner has
        by then swallowed the rest of the statement.
        """
        evil = "org:eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        for artifact in (GCP_SH, AZURE_SH):
            for label, injection in {
                "bare brace": f'JUNK={{ SUBJECT="{evil}"',
                "bare paren": f'JUNK=( SUBJECT="{evil}"',
                "bare bracket": f'JUNK=[ SUBJECT="{evil}"',
                "doubled brace": f'JUNK={{{{ SUBJECT="{evil}"',
                "mismatched closer": f'JUNK=$(echo x}} SUBJECT="{evil}"',
                "unterminated quote": f'JUNK="x SUBJECT={evil}',
                "unterminated expansion": f'JUNK=${{x SUBJECT="{evil}"',
            }.items():
                with self.subTest(artifact=artifact.path, shape=label):
                    text = mutate(source(artifact), self.ANCHOR, self.ANCHOR + "\n" + injection)
                    with self.assertRaises(GuardError):
                        check_artifact(artifact, text)

    def test_a_legitimately_nested_value_still_reads_as_one_word(self):
        # The other direction, and the reason the scanner nests at all: both shipped scripts assign
        # from `$( ... )` values whose spaces must NOT end the word.
        self.assertIn("POOL_NAME=$(gcloud", source(GCP_SH))
        self.assertIn('SCRIPT_DIR="$(cd', source(AZURE_SH))
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact=artifact.path):
                self.assertEqual(check_artifact(artifact, source(artifact)), [])

    def test_a_runner_in_front_of_an_allowed_command_still_reads(self):
        # The other direction: peeling must not turn a legitimate `time gcloud ...` red.
        text = mutate(source(GCP_SH), self.ANCHOR, self.ANCHOR + "\ntime gcloud version")
        self.assertEqual(check_artifact(GCP_SH, text), [])


class AHeredocDelimiterIsFormedTheWayBashFormsIt(unittest.TestCase):
    """A wrong delimiter makes `strip_heredocs` delete REAL, executing statements.

    Bash builds a heredoc delimiter by concatenating adjacent quoted, unquoted and
    backslash-escaped fragments and then removing the quotes, so `<<t"rue"` names `true`. Reading
    only the first fragment gives `t`, and the stripper then swallows every line until one reads
    `t` -- taking a real `SUBJECT="org:VICTIM"` with it, invisible to every check in this file.
    Making a statement disappear is worth exactly as much to an attacker as a hidden binder.
    """

    ANCHOR = 'SUBJECT="org:${ORG_UID}"'
    EVIL = "org:VICTIM-not-the-customer"

    def test_the_delimiter_matches_bash(self):
        for line, want in {
            'cat <<t"rue"': ["true"],
            "cat <<'A'\"B\"C": ["ABC"],
            "cat <<EOF": ["EOF"],
            "cat <<-'X'": ["X"],
            "cat <<A; cat <<B": ["A", "B"],
            # `<<<` is a herestring and opens nothing -- `read -r X <<< "y"` has to reach the
            # grammar to be refused, not be swallowed as a heredoc body.
            'read -r X <<< "y"': [],
            # A `<<` inside quotes is text...
            'echo "a << b"': [],
            "echo '$(cat <<NOPE'": [],
            # ...but `$(` re-enters command context even from inside a double quote, which is how
            # the shipped `az ... --parameters "$(cat <<JSON` opens its own.
            'az x --parameters "$(cat <<JSON': ["JSON"],
        }.items():
            with self.subTest(line=line):
                self.assertEqual(_heredoc_delims(line), want)

    def test_a_concatenated_delimiter_cannot_hide_a_rebind(self):
        for label, injection in {
            "quote-split delimiter": (
                'cat <<t"rue"\ndummy body\ntrue\nSUBJECT="%s"\n: <<\'do\'\nt\ndo' % "org:VICTIM-not-the-customer"),
            "three-way split": 'cat <<\'A\'"B"C\nbody\nABC\nSUBJECT="%s"' % "org:VICTIM-not-the-customer",
            "tab-stripped form": 'cat <<-t"rue"\nbody\ntrue\nSUBJECT="%s"' % "org:VICTIM-not-the-customer",
            "a quoted << is not a heredoc": 'echo "a << b"\nSUBJECT="%s"' % "org:VICTIM-not-the-customer",
        }.items():
            with self.subTest(shape=label):
                text = mutate(source(GCP_SH), self.ANCHOR, self.ANCHOR + "\n" + injection)
                with self.assertRaises(GuardError):
                    check_artifact(GCP_SH, text)

    def test_both_shipped_scripts_still_read(self):
        # The other direction: deploy.sh's own `"$(cat <<JSON ... JSON)"` must still be stripped as
        # data, or its JSON lines would be judged as commands and a correct file would turn red.
        self.assertIn('"$(cat <<JSON', source(AZURE_SH))
        for artifact in (GCP_SH, AZURE_SH):
            with self.subTest(artifact=artifact.path):
                self.assertEqual(check_artifact(artifact, source(artifact)), [])
