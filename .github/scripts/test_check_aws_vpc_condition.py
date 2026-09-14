#!/usr/bin/env python3
"""The ec2:Vpc guard's own teeth, proved against the REAL shipped artifacts.

Each case takes the artifacts as they stand, applies one edit that puts an action under a condition
it can never satisfy, and asserts the guard rejects it. The class it exists for is the one that
LOOKS bounded: the policy lints, deploys and reads as "confined to your VPC", and refuses the action
on every call.

Run:  python3 -m unittest discover -s .github/scripts -t .github/scripts
"""

from __future__ import annotations

import contextlib
import io
import unittest

from check_aws_vpc_condition import AWS_CFN, AWS_TF, PATHS, REPO_ROOT, check_all, main


def sources() -> dict[str, str]:
    return {p: (REPO_ROOT / p).read_text(encoding="utf-8") for p in PATHS}


def edited(path: str, old: str, new: str) -> dict[str, str]:
    srcs = sources()
    count = srcs[path].count(old)
    if count != 1:
        raise AssertionError(f"the mutation anchor appears {count} times in {path}, expected 1:\n{old}")
    srcs[path] = srcs[path].replace(old, new)
    return srcs


class TheShippedArtifactsPass(unittest.TestCase):
    def test_main_is_green_on_this_branch(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(), 0)


class Rejects(unittest.TestCase):
    def assertRejected(self, srcs, *needles):
        failures = check_all(srcs)
        self.assertTrue(failures, "the guard accepted an action under a condition it cannot satisfy")
        for needle in needles:
            self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")


class ACreateUnderTheVpcConditionIsRefused(Rejects):
    def test_terraform_puts_create_security_group_back_under_the_condition(self):
        # The shape this guard exists for: one line, and every egress policy fails to enforce.
        self.assertRejected(
            edited(AWS_TF, '  egress_group_actions = [\n',
                   '  egress_group_actions = [\n    "ec2:CreateSecurityGroup",\n'),
            "EgressSecurityGroups", "ec2:CreateSecurityGroup",
        )

    def test_cloudformation_puts_create_subnet_back_under_the_condition(self):
        self.assertRejected(
            edited(AWS_CFN, '                    - "ec2:DeleteSubnet"\n',
                   '                    - "ec2:DeleteSubnet"\n                    - "ec2:CreateSubnet"\n'),
            "EgressSecurityGroups", "ec2:CreateSubnet",
        )

    def test_a_read_joins_the_interface_statement(self):
        # Not only creates: a Describe under the same condition is refused just as surely.
        self.assertRejected(
            edited(AWS_TF, '      actions   = ["ec2:ModifyNetworkInterfaceAttribute"]',
                   '      actions   = ["ec2:ModifyNetworkInterfaceAttribute", "ec2:DescribeNetworkInterfaces"]'),
            "EgressAttachToInstances",
        )


class AnUnclassifiedActionIsRefused(Rejects):
    def test_a_new_action_must_be_looked_up(self):
        self.assertRejected(
            edited(AWS_TF, '    "ec2:DeleteTags",\n', '    "ec2:DeleteTags",\n    "ec2:CreateVolume",\n'),
            "ec2:CreateVolume", "not classified",
        )


class TheReaderFailsLoudly(Rejects):
    def test_no_statement_names_the_key(self):
        srcs = sources()
        srcs[AWS_CFN] = srcs[AWS_CFN].replace('"ec2:Vpc"', '"ec2:VpcID"')
        self.assertRejected(srcs, "no statement names")


if __name__ == "__main__":
    unittest.main()
