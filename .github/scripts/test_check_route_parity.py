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
    AZURE_ARM_FLOW_LOGS,
    AZURE_TF,
    GCP_SH,
    GCP_TF,
    PATHS,
    REPO_ROOT,
    aws_cloudformation_conditions,
    aws_cloudformation_statements,
    aws_terraform_conditions,
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


REGION = ("StringEquals", "aws:RequestedRegion")
VPC = ("StringLike", "ec2:Vpc")

# The interface statement on each route, from its action into its conditions. Both egress write
# statements carry the same bounds, so an anchor that did not start at the action would match twice.
CFN_VPC_BOUND = """\
                          "ec2:Vpc": !If
                            - HasEgressVpc
                            - !Sub "arn:${AWS::Partition}:ec2:*:${AWS::AccountId}:vpc/${EgressVpcId}"
                            - !Sub "arn:${AWS::Partition}:ec2:*:${AWS::AccountId}:vpc/${Vpc}"
"""
CFN_BOTH_BOUNDS = """\
                    - !If
                      - HasRegionCondition
                      - StringLike:
""" + CFN_VPC_BOUND + """\
                        StringEquals:
                          "aws:RequestedRegion": !Ref AllowedRegion
                      - StringLike:
""" + CFN_VPC_BOUND
CFN_REGION_ONLY = """\
                    - !If
                      - HasRegionCondition
                      - StringEquals:
                          "aws:RequestedRegion": !Ref AllowedRegion
                      - !Ref AWS::NoValue
"""
CFN_ATTACH_BOUNDS = """\
                  Action: "ec2:ModifyNetworkInterfaceAttribute"
                  Resource: "*"
                  Condition: !If
                    - HasAnyEgressVpc
""" + CFN_BOTH_BOUNDS + CFN_REGION_ONLY
TF_ATTACH_BOUNDS = """\
      actions   = ["ec2:ModifyNetworkInterfaceAttribute"]
      resources = ["*"]

      dynamic "condition" {
        for_each = local.region_condition ? [1] : []
        content {
          test     = "StringEquals"
          variable = "aws:RequestedRegion"
          values   = var.allowed_regions
        }
      }

      dynamic "condition" {
        for_each = length(local.egress_vpc_arns) > 0 ? [1] : []
"""


class AnAwsStatementIsBoundedAlikeOnBothRoutes(Rejects):
    def test_the_readers_see_both_bounds_together(self):
        # Each route's reader must find both bounds together, in one combination. A reader that found
        # nothing would pass every rule below.
        srcs = read_sources(REPO_ROOT)
        for conditions in (
            aws_terraform_conditions(srcs[AWS_TF], AWS_TF),
            aws_cloudformation_conditions(srcs[AWS_CFN], AWS_CFN),
        ):
            pairs = {sid: [p for _, p in combos] for sid, combos in conditions.items()}
            for sid in ("EgressSecurityGroups", "EgressAttachToInstances"):
                self.assertIn(frozenset({REGION, VPC}), pairs[sid], sid)
            self.assertIn(frozenset({REGION}), pairs["Ec2Lifecycle"])
            self.assertEqual(
                pairs["PassWorkstationInstanceProfileRole"],
                [frozenset({("StringEquals", "iam:PassedToService")})],
            )

    def test_cloudformation_emits_the_region_bound_only_in_place_of_the_vpc_bound(self):
        # The shape this rule exists for. Both keys are still named, so a comparison of keys alone
        # passes, and a stack with a VPC never gets the region bound its AllowedRegion asked for.
        problems = self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace(
                CFN_BOTH_BOUNDS, "                    - StringLike:\n" + CFN_VPC_BOUND.replace("    ", "  ", 1),
            ))),
            "`EgressAttachToInstances` in aws/cloudformation/ringleader-onboarding.yaml never carries all",
        )
        self.assertTrue(any("more than one switch" in p for p in problems), problems)

    def test_cloudformation_edits_one_copy_of_the_vpc_bound(self):
        # The VPC bound is written once per branch of HasRegionCondition. An edit to one copy ships a
        # VPC bound that depends on whether AllowedRegion is set, with every key still in place.
        drifted = CFN_VPC_BOUND.replace("vpc/${EgressVpcId}", "vpc/${EgressVpcId}*")
        region_set, region_unset = CFN_BOTH_BOUNDS.rsplit(CFN_VPC_BOUND, 1)[0], drifted
        self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace(
                CFN_BOTH_BOUNDS, region_set + region_unset,
            ))),
            "`EgressAttachToInstances` in aws/cloudformation/ringleader-onboarding.yaml writes `StringLike` on `ec2:Vpc` with a different value",
        )

    def test_cloudformation_drops_the_region_bound_when_no_vpc_is_known(self):
        # Every bound is still emitted together in SOME combination, so only the rule that each
        # bound follows one switch sees that a stack without a VPC loses its region bound.
        self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace(
                CFN_REGION_ONLY, "                    - !Ref AWS::NoValue\n",
            ))),
            "`EgressAttachToInstances` in aws/cloudformation/ringleader-onboarding.yaml emits a condition under more than one switch",
        )

    def test_cloudformation_gates_both_bounds_on_whether_a_vpc_is_known(self):
        # Each bound still follows exactly one switch, the same one. With a VPC and no AllowedRegion
        # the statement would name an empty region and refuse every write.
        self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace(
                CFN_BOTH_BOUNDS + CFN_REGION_ONLY,
                """\
                    - StringLike:
""" + CFN_VPC_BOUND + """\
                      StringEquals:
                        "aws:RequestedRegion": !Ref AllowedRegion
                    - !Ref AWS::NoValue
""",
            ))),
            "emits StringEquals aws:RequestedRegion under different inputs",
        )

    def test_terraform_gates_the_region_bound_on_the_wrong_input(self):
        self.assertRejected(
            edited((AWS_TF, TF_ATTACH_BOUNDS, TF_ATTACH_BOUNDS.replace(
                "for_each = local.region_condition ? [1] : []",
                "for_each = length(local.egress_vpc_arns) > 0 ? [1] : []",
            ))),
            "emits StringEquals aws:RequestedRegion under different inputs",
        )

    def test_a_switch_the_table_does_not_pair(self):
        self.assertRejected(
            edited((AWS_TF, TF_ATTACH_BOUNDS, TF_ATTACH_BOUNDS.replace(
                "for_each = local.region_condition ? [1] : []",
                "for_each = length(var.allowed_regions) > 0 ? [1] : []",
            ))),
            "under a switch that `SWITCHES` does not name",
        )

    def test_terraform_makes_its_two_bounds_exclusive(self):
        self.assertRejected(
            edited((AWS_TF, TF_ATTACH_BOUNDS, TF_ATTACH_BOUNDS.replace(
                "for_each = length(local.egress_vpc_arns) > 0 ? [1] : []",
                "for_each = local.region_condition ? [] : [1]",
            ))),
            "`EgressAttachToInstances` in aws/terraform/main.tf never carries all",
        )

    def test_terraform_drops_a_bound(self):
        self.assertRejected(
            edited((AWS_TF, TF_ATTACH_BOUNDS, TF_ATTACH_BOUNDS.replace(
                """      dynamic "condition" {
        for_each = local.region_condition ? [1] : []
        content {
          test     = "StringEquals"
          variable = "aws:RequestedRegion"
          values   = var.allowed_regions
        }
      }

""", ""))),
            "`EgressAttachToInstances` is bounded by different conditions",
        )

    def test_cloudformation_changes_a_bound_operator(self):
        self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace("StringLike:", "ArnLike:"))),
            "`EgressAttachToInstances` is bounded by different conditions",
        )

    def test_cloudformation_adds_a_bound_terraform_lacks(self):
        self.assertRejected(
            edited((AWS_CFN, """\
                  Action: "iam:PassRole"
                  Resource: !Sub "arn:${AWS::Partition}:iam::*:role${WorkstationIdentityPath}*"
                  Condition:
                    StringEquals:
""", """\
                  Action: "iam:PassRole"
                  Resource: !Sub "arn:${AWS::Partition}:iam::*:role${WorkstationIdentityPath}*"
                  Condition:
                    StringEquals:
                      "aws:RequestedRegion": !Ref AllowedRegion
""")),
            "`PassWorkstationInstanceProfileRole` is bounded by different conditions",
        )


class TheConditionReadersRefuseWhatTheyCannotRead(Rejects):
    def test_a_flow_if_in_cloudformation(self):
        self.assertRejected(
            edited((AWS_CFN, CFN_ATTACH_BOUNDS, CFN_ATTACH_BOUNDS.replace(
                CFN_REGION_ONLY,
                '                    - !If [HasRegionCondition, {StringEquals: {"aws:RequestedRegion": !Ref AllowedRegion}}, !Ref AWS::NoValue]\n',
            ))),
            "flow form",
        )

    def test_a_terraform_gate_that_is_not_a_ternary(self):
        self.assertRejected(
            edited((AWS_TF, TF_ATTACH_BOUNDS, TF_ATTACH_BOUNDS.replace(
                "for_each = local.region_condition ? [1] : []",
                "for_each = toset(var.allowed_regions)",
            ))),
            "is not `<gate> ? [1] : []`",
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


class TheFlowLogTemplateIsSharedTheSameWay(Rejects):
    def test_the_module_stops_deploying_the_flow_log_template(self):
        self.assertRejected(
            edited((AZURE_TF, 'file("${path.module}/../arm/azuredeploy-flowlogs.json")',
                    'file("${path.module}/flowlogs.json")')),
            "azuredeploy-flowlogs.json",
        )

    def test_a_flow_log_parameter_is_not_passed_by_terraform(self):
        self.assertRejected(
            edited((AZURE_TF, "    retentionDays      = { value = var.flow_log_retention_days }\n", "")),
            "retentionDays",
        )

    def test_terraform_passes_a_flow_log_parameter_the_template_does_not_declare(self):
        srcs = read_sources(REPO_ROOT)
        doc = json.loads(srcs[AZURE_ARM_FLOW_LOGS])
        del doc["parameters"]["retentionDays"]
        srcs[AZURE_ARM_FLOW_LOGS] = json.dumps(doc, indent=2)
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
