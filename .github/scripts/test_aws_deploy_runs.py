"""`aws/cloudformation/deploy.sh` empties the VPC's default security group only when asked.

cfn-lint reads the template and nothing else here executes `deploy.sh`, so the one change it makes
outside the stack has no other check. That change removes rules from a security group in a
customer's account, where a wrong call cuts the traffic of whatever carries the group and nobody at
Ringleader can put it back.

So these run `deploy.sh` against stub `aws` and `openssl` commands on `PATH`. The `aws` stub records
its arguments and answers the script's reads with fixed ids. Nothing reaches AWS and nothing needs
credentials. The assertions are about which commands the script runs, and with which arguments.

Run it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "aws" / "cloudformation" / "deploy.sh"

BASE_ENV = {
    "ISSUER_URL": "https://oidc.example",
    "ORG_UID": "00000000-0000-4000-8000-000000000000",
    "REGION_INDEX": "0",
}

VPC_ID = "vpc-0123456789abcdef0"
GROUP_ID = "sg-0fedcba9876543210"

# deploy.sh pipes `openssl s_client` into `openssl x509 -fingerprint`, and keeps what follows the
# `=`. Answering both calls with one fingerprint line gives it the 40 hex digits it checks for. The
# stub reads its input first, because the script runs under `pipefail` and a writer whose reader
# has gone fails the pipeline.
OPENSSL_STUB = "#!/bin/sh\ncat > /dev/null\necho 'sha1 Fingerprint=" + ":".join(["AB"] * 20) + "'\n"

# Records every call, then answers the four reads the new step makes. $INBOUND and $OUTBOUND are the
# rule ids the default group holds, as the tab-separated line `--output text` prints.
AWS_STUB = f"""#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
  *describe-stacks*VpcId*) echo "${{STACK_VPC-{VPC_ID}}}" ;;
  *describe-security-groups*) echo "{GROUP_ID}" ;;
  *describe-security-group-rules*false*) printf '%s\\n' "$INBOUND" ;;
  *describe-security-group-rules*true*) printf '%s\\n' "$OUTBOUND" ;;
esac
exit 0
"""


def run(extra: dict[str, str] | None = None) -> tuple[subprocess.CompletedProcess, list[str]]:
    """Run deploy.sh with the stubs first on PATH. Returns the result and its `aws` calls."""
    with tempfile.TemporaryDirectory() as bindir:
        for name, body in (("aws", AWS_STUB), ("openssl", OPENSSL_STUB)):
            stub = Path(bindir) / name
            stub.write_text(body)
            stub.chmod(0o755)
        calls = Path(bindir) / "calls"
        calls.write_text("")
        env = dict(os.environ)
        env.update(BASE_ENV)
        env.update({"INBOUND": "sgr-0aaa", "OUTBOUND": "sgr-0bbb\tsgr-0ccc"})
        env.update(extra or {})
        env["CALLS"] = str(calls)
        env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
        got = subprocess.run(
            ["bash", str(DEPLOY)], capture_output=True, text=True, env=env, cwd=DEPLOY.parent
        )
        return got, calls.read_text().splitlines()


def ec2_calls(calls: list[str]) -> list[str]:
    return [c for c in calls if c.startswith("ec2 ")]


class TheDefaultGroupIsLeftAloneUntilAskedFor(unittest.TestCase):
    """A customer who re-runs deploy.sh without the variable is not asking for anything new."""

    def test_a_run_on_the_defaults_makes_no_ec2_call(self):
        got, calls = run()
        self.assertEqual(got.returncode, 0, f"deploy.sh failed on its defaults:\n{got.stderr}")
        self.assertTrue(
            any(c.startswith("cloudformation deploy ") for c in calls),
            f"the stub recorded no stack deploy, so this test proves nothing: {calls}",
        )
        self.assertEqual(
            ec2_calls(calls),
            [],
            "deploy.sh called EC2 with RESTRICT_DEFAULT_SECURITY_GROUP unset. A workstation that "
            "names no security group gets its outbound traffic from the VPC's default group, so "
            "emptying it by default cuts that traffic on a customer's next run.",
        )

    def test_false_makes_no_ec2_call_either(self):
        got, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "false"})
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(ec2_calls(calls), [])


class TheDefaultGroupIsEmptiedWhenAskedFor(unittest.TestCase):
    """Switched on, every rule the group holds is removed, in both directions."""

    def test_both_directions_are_revoked_by_rule_id(self):
        got, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true"})
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn(
            f"ec2 revoke-security-group-ingress --region us-east-1 --group-id {GROUP_ID} "
            "--security-group-rule-ids sgr-0aaa",
            calls,
            "the inbound rule of the default group was not revoked",
        )
        self.assertIn(
            f"ec2 revoke-security-group-egress --region us-east-1 --group-id {GROUP_ID} "
            "--security-group-rule-ids sgr-0bbb sgr-0ccc",
            calls,
            "the outbound rules of the default group were not revoked, one argument per rule id",
        )

    def test_the_group_is_the_default_one_of_the_stacks_vpc(self):
        _, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true"})
        lookup = [c for c in calls if c.startswith("ec2 describe-security-groups ")]
        self.assertEqual(len(lookup), 1, f"expected one lookup of the group, got {lookup}")
        self.assertIn(f"Name=vpc-id,Values={VPC_ID}", lookup[0])
        self.assertIn(
            "Name=group-name,Values=default",
            lookup[0],
            "the lookup is not limited to the group named `default`, so it could return one of the "
            "two workstation groups and deploy.sh would empty that instead",
        )

    def test_the_rules_are_removed_after_the_stack_deploys(self):
        _, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true"})
        deploy = next(i for i, c in enumerate(calls) if c.startswith("cloudformation deploy "))
        first_ec2 = next(i for i, c in enumerate(calls) if c.startswith("ec2 "))
        self.assertLess(
            deploy,
            first_ec2,
            "EC2 was called before the stack deployed, when a new stack has no VPC yet",
        )

    def test_a_group_that_is_already_empty_is_not_revoked(self):
        # A revoke with no rule id asks EC2 for nothing, so a second run skips both.
        got, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true", "INBOUND": "", "OUTBOUND": ""})
        self.assertEqual(got.returncode, 0, f"a second run on an empty group failed:\n{got.stderr}")
        self.assertEqual([c for c in calls if "revoke-security-group" in c], [])

    def test_only_the_direction_that_holds_rules_is_revoked(self):
        got, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true", "INBOUND": ""})
        self.assertEqual(got.returncode, 0, got.stderr)
        revokes = [c.split()[1] for c in calls if "revoke-security-group" in c]
        self.assertEqual(revokes, ["revoke-security-group-egress"])


class TheSwitchIsRefusedWhereItCannotWork(unittest.TestCase):
    """A refusal comes before the stack deploys, so a bad value changes nothing."""

    def assert_refused_before_deploying(self, extra: dict[str, str], why: str):
        got, calls = run(extra)
        self.assertNotEqual(got.returncode, 0, why)
        self.assertEqual(calls, [], f"deploy.sh called aws before refusing: {calls}")

    def test_it_needs_the_network_this_stack_creates(self):
        self.assert_refused_before_deploying(
            {"RESTRICT_DEFAULT_SECURITY_GROUP": "true", "CREATE_NETWORK": "false"},
            "deploy.sh accepted the switch with CREATE_NETWORK=false. The stack then creates no "
            "VPC, and a customer who set it for a compliance scan would believe a group was empty.",
        )

    def test_a_value_that_is_not_true_or_false_is_refused(self):
        self.assert_refused_before_deploying(
            {"RESTRICT_DEFAULT_SECURITY_GROUP": "yes"},
            "deploy.sh accepted RESTRICT_DEFAULT_SECURITY_GROUP=yes and treated it as off",
        )

    def test_a_stack_with_no_vpc_output_stops_the_run(self):
        # `--output text` prints nothing when the stack has no VpcId output, and None when it has
        # no outputs at all.
        for answer in ("", "None"):
            with self.subTest(answer=answer):
                got, calls = run({"RESTRICT_DEFAULT_SECURITY_GROUP": "true", "STACK_VPC": answer})
                self.assertNotEqual(got.returncode, 0, "deploy.sh went on without a VPC id")
                self.assertEqual(
                    ec2_calls(calls), [], "EC2 was called with no VPC to limit the lookup to"
                )


if __name__ == "__main__":
    unittest.main()
