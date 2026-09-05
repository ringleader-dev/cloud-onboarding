#!/usr/bin/env python3
"""The route-parity guard's own teeth, proved against the REAL shipped artifacts.

Every case below takes the artifacts as they stand on this branch, applies one edit of the shape
a real change makes -- a permission added to one route and not the other -- and asserts the guard
rejects it. That is what makes "a PR that grants something on the Terraform path and forgets the
script fails CI" a fact rather than a belief.

The class this file exists for is the one that LOOKS fine. Both routes still apply. `terraform
validate`, `cfn-lint` and `bash -n` all stay green. The two landing pads differ, and the customer
who took the other one finds out when a feature 403s in an account we cannot re-apply.

There is a second class the tests cover deliberately: a guard that has quietly stopped READING
one of its artifacts. Renaming the anchor a reader is written against must fail loudly here, not
turn the comparison into a vacuous pass -- which is the failure mode every guard in this
directory is most likely to die of.

`mutate` asserts its anchor appears EXACTLY ONCE. A mutation that no longer applies is a test
that asserts nothing, and it fails here loudly instead of passing silently.

Run:  python3 -m unittest discover -s .github/scripts -t .github/scripts
"""

from __future__ import annotations

import contextlib
import io
import json
import unittest

from check_route_parity import (
    AWS_CFN,
    AWS_TF,
    AZURE_ARM,
    AZURE_TF,
    GCP_SH,
    GCP_TF,
    PATHS,
    REPO_ROOT,
    aws_cloudformation_statements,
    aws_terraform_statements,
    check_all,
    gcloud_role_permission_vars,
    gcp_terraform_roles,
    main,
    read_sources,
)


TRUST_SID = "RingleaderOrgFederation"


@contextlib.contextmanager
def quiet():
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        yield


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
    srcs = read_sources(REPO_ROOT)
    for path, old, new in edits:
        srcs[path] = mutate(srcs[path], old, new)
    return srcs


class Rejects(unittest.TestCase):
    def assertRejected(self, srcs, needle=""):
        problems = check_all(srcs)
        self.assertTrue(problems, "the guard accepted two routes that grant different things")
        if needle:
            self.assertTrue(
                any(needle in p for p in problems), f"no failure mentioned {needle!r}: {problems}"
            )
        return problems


class TheShippedArtifactsPass(unittest.TestCase):
    def test_main_is_green_on_this_branch(self):
        with quiet():
            self.assertEqual(main(), 0, "the artifacts on this branch must satisfy the guard")

    def test_every_path_is_read(self):
        srcs = read_sources(REPO_ROOT)
        self.assertEqual(set(srcs), set(PATHS))
        for path, text in srcs.items():
            self.assertTrue(text.strip(), f"{path} is empty")

    def test_the_readers_actually_find_something(self):
        # A reader that returns nothing turns every comparison below into a vacuous pass, so the
        # counts are asserted rather than assumed. They are lower bounds, not exact: adding a
        # grant is normal and must not break this test.
        srcs = read_sources(REPO_ROOT)
        roles = gcp_terraform_roles(srcs[GCP_TF], GCP_TF)
        self.assertGreaterEqual(len(roles), 3, f"only found {sorted(roles)}")
        for name in ("egress", "identity", "artifact_storage", "artifact_storage_provision"):
            self.assertIn(name, roles)
        self.assertGreaterEqual(len(aws_terraform_statements(srcs[AWS_TF], AWS_TF)), 8)
        self.assertGreaterEqual(len(aws_cloudformation_statements(srcs[AWS_CFN], AWS_CFN)), 8)
        # Every role the script creates must be reachable through its `gcloud iam roles` command,
        # or the call-site half of the comparison is reading nothing.
        sites = gcloud_role_permission_vars(srcs[GCP_SH], GCP_SH)
        for role_arg, var in (
            ("$EGRESS_ROLE", "EGRESS_PERMS"),
            ("$IDENTITY_ROLE", "IDENTITY_PERMS"),
            ("$ARTIFACT_STORAGE_ROLE", "STORAGE_ROLE_PERMS"),
            ("${ARTIFACT_STORAGE_ROLE}Provision", "STORAGE_PROVISION_PERMS"),
        ):
            self.assertEqual(sites.get(role_arg), {var}, f"{role_arg} is not built from {var}")

    def test_both_aws_routes_name_the_same_statements(self):
        # The headline, asserted directly as well as through check_all: the two AWS routes are
        # compared BY SID, so a sid on one and not the other is a grant one route does not have.
        #
        # The trust statement is excluded exactly as the guard excludes it: on the Terraform side
        # it lives in a second policy document, and check_trust_pins.py reads it far more
        # carefully than a set comparison could.
        srcs = read_sources(REPO_ROOT)
        tf = set(aws_terraform_statements(srcs[AWS_TF], AWS_TF)) - {TRUST_SID}
        cfn = set(aws_cloudformation_statements(srcs[AWS_CFN], AWS_CFN)) - {TRUST_SID}
        self.assertEqual(tf, cfn)


class AGcpPermissionCannotBeAddedToOneRouteOnly(Rejects):
    def test_added_to_the_terraform_only(self):
        self.assertRejected(
            edited((GCP_TF, '"compute.routes.list",', '"compute.routes.list",\n    "compute.routes.update",')),
            "egress-control role",
        )

    def test_added_to_the_gcloud_script_only(self):
        self.assertRejected(
            edited((GCP_SH, "compute.networks.updatePolicy,", "compute.networks.updatePolicy,compute.routes.update,")),
            "egress-control role",
        )

    def test_the_managed_identities_role_drifts(self):
        self.assertRejected(
            edited((GCP_SH, "iam.serviceAccounts.update", "iam.serviceAccounts.getIamPolicy")),
            "managed-identities role",
        )

    def test_an_artifact_storage_permission_drifts(self):
        self.assertRejected(
            edited((GCP_SH, "storage.objects.update", "storage.objects.setIamPolicy")),
            "artifact-storage role",
        )

    def test_the_managed_width_extras_drift(self):
        self.assertRejected(
            edited((GCP_SH, 'STORAGE_MANAGED_PERMS="storage.buckets.delete,storage.buckets.update"',
                    'STORAGE_MANAGED_PERMS="storage.buckets.update"')),
            "managed width only",
        )


class AGcpRoleCannotDisappearFromOneRoute(Rejects):
    def test_the_role_is_renamed_in_the_terraform_only(self):
        self.assertRejected(
            edited((GCP_TF, 'resource "google_project_iam_custom_role" "identity"',
                    'resource "google_project_iam_custom_role" "appliance_identity"')),
            "google_project_iam_custom_role.identity",
        )

    def test_the_shell_variable_is_renamed(self):
        # The reader must say so rather than compare an empty list against a real one.
        self.assertRejected(
            edited((GCP_SH, 'IDENTITY_PERMS="iam.serviceAccounts.create', 'APPLIANCE_PERMS="iam.serviceAccounts.create')),
            "found no assignment",
        )

    def test_the_artifact_storage_role_stops_using_the_compared_locals(self):
        # The locals are what the gcloud path is compared against. Swapping one for a literal is a
        # role granting something else, and the resolved comparison says so.
        self.assertRejected(
            edited((GCP_TF, "    local.artifact_storage_permissions,\n",
                    '    ["storage.buckets.get"],\n')),
            "the artifact-storage role differs",
        )


class APermissionCannotBeSmuggledPastTheComparison(Rejects):
    """The shapes a substring or assignment-only reader would have missed.

    Both were live bypasses: the guard once checked the artifact-storage role by looking for its
    two `local.` names anywhere in the raw expression, and once read only a shell variable's
    assignment and never the command the variable is interpolated into.
    """

    def test_a_third_element_inside_the_same_concat(self):
        self.assertRejected(
            edited((GCP_TF,
                    "    local.artifact_storage_managed ? local.artifact_storage_manage_permissions : [],\n",
                    "    local.artifact_storage_managed ? local.artifact_storage_manage_permissions : [],\n"
                    '    ["storage.buckets.setIamPolicy"],\n')),
            "storage.buckets.setIamPolicy",
        )

    def test_a_permission_spliced_in_at_the_gcloud_call_site(self):
        # The assignment stays byte-identical to Terraform's list; the command grants more.
        self.assertRejected(
            edited((GCP_SH, '--permissions "$EGRESS_PERMS" --quiet',
                    '--permissions "$EGRESS_PERMS,compute.instances.setMetadata" --quiet')),
            "not a single variable",
        )

    def test_a_role_built_from_a_variable_nobody_compares(self):
        self.assertRejected(
            edited((GCP_SH, '--permissions "$IDENTITY_PERMS" --quiet',
                    '--permissions "$STORAGE_PERMS" --quiet')),
            "not\n  `IDENTITY_PERMS` alone",
        )

    def test_a_permission_list_assembled_from_an_unguarded_variable(self):
        self.assertRejected(
            edited((GCP_SH, 'STORAGE_ROLE_PERMS="${STORAGE_PERMS},${STORAGE_MANAGED_PERMS}"',
                    'STORAGE_ROLE_PERMS="${STORAGE_PERMS},${EXTRA_PERMS}"')),
            "not a guarded",
        )

    def test_the_permissions_flag_written_twice(self):
        # gcloud honours the LAST occurrence, so a reader that judged the first would be reading a
        # flag that decides nothing while the effective grant went unexamined.
        self.assertRejected(
            edited((GCP_SH, '--permissions "$EGRESS_PERMS" --quiet',
                    '--permissions "$EGRESS_PERMS" --permissions "$EGRESS_PERMS,compute.instances.setMetadata" --quiet')),
            "2 times",
        )

    def test_a_cycle_between_two_permission_variables(self):
        # Must be the guard's own diagnostic, not a RecursionError traceback: an uncaught crash is
        # a guard nobody can act on, even though it fails closed.
        self.assertRejected(
            edited((GCP_SH, 'STORAGE_PERMS="storage.buckets.get,',
                    'STORAGE_PERMS="${STORAGE_ROLE_PERMS},storage.buckets.get,')),
            "leads back to it",
        )

    def test_the_union_of_both_widths_is_what_is_compared(self):
        # A permission moved from the managed list into the always-granted one keeps the UNION
        # identical. The per-width comparison is what catches it.
        self.assertRejected(
            edited(
                (GCP_TF, '    "storage.buckets.delete",\n    "storage.buckets.update",\n', ""),
                (GCP_TF, '    "storage.buckets.get",\n',
                 '    "storage.buckets.get",\n    "storage.buckets.delete",\n    "storage.buckets.update",\n'),
            ),
            "managed width only",
        )


class AnAwsStatementCannotBeAddedToOneRouteOnly(Rejects):
    def test_an_action_is_added_to_the_terraform_only(self):
        self.assertRejected(
            edited((AWS_TF, '"s3:DeleteObject",', '"s3:DeleteObject",\n    "s3:PutObjectAcl",')),
            "ArtifactStorageObjects",
        )

    def test_an_action_is_added_to_the_cloudformation_only(self):
        self.assertRejected(
            edited((AWS_CFN, '                    - "s3:DeleteObject"',
                    '                    - "s3:DeleteObject"\n                    - "s3:PutObjectAcl"')),
            "ArtifactStorageObjects",
        )

    def test_a_whole_statement_is_missing_from_cloudformation(self):
        self.assertRejected(
            edited((AWS_CFN, "Sid: PassWorkstationInstanceProfileRole", "Sid: PassWorkstationRoleDisabled")),
            "PassWorkstationInstanceProfileRole",
        )

    def test_a_whole_statement_is_missing_from_terraform(self):
        self.assertRejected(
            edited((AWS_TF, 'sid       = "ArtifactStorageBucketProvisioning"',
                    'sid       = "ArtifactStorageBucketProvisioningV2"')),
            "ArtifactStorageBucketProvisioning",
        )


class AnAzureRouteCannotStopSharingTheOneActionList(Rejects):
    def test_the_module_stops_deploying_the_shared_template(self):
        self.assertRejected(
            edited((AZURE_TF, 'file("${path.module}/../arm/azuredeploy.json")',
                    'file("${path.module}/role.json")')),
            "verbatim",
        )

    def test_a_template_parameter_is_not_passed_by_terraform(self):
        self.assertRejected(
            edited((AZURE_TF, "    enableArtifactStorage       = { value = var.enable_artifact_storage }\n", "")),
            "enableArtifactStorage",
        )

    def test_terraform_passes_a_parameter_the_template_does_not_declare(self):
        srcs = read_sources(REPO_ROOT)
        doc = json.loads(srcs[AZURE_ARM])
        del doc["parameters"]["enableArtifactStorage"]
        srcs[AZURE_ARM] = json.dumps(doc, indent=2)
        self.assertRejected(srcs, "does not declare")


class TheGuardRefusesToReadNothing(Rejects):
    def test_the_aws_policy_document_is_renamed(self):
        self.assertRejected(
            edited((AWS_TF, 'data "aws_iam_policy_document" "permissions"',
                    'data "aws_iam_policy_document" "role_permissions"')),
            "aws_iam_policy_document",
        )

    def test_a_cloudformation_statement_loses_its_action_key(self):
        self.assertRejected(
            edited((AWS_CFN, '                  Action:\n                    - "s3:CreateBucket"',
                    '                  NotAction:\n                    - "s3:CreateBucket"')),
            "ArtifactStorageBucketProvisioning",
        )


if __name__ == "__main__":
    unittest.main()
