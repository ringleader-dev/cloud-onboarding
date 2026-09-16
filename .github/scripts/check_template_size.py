#!/usr/bin/env python3
"""Fail the build if deploy.sh would render a CloudFormation template over 51,200 bytes.

`aws cloudformation deploy --template-file` refuses a template larger than 51,200 bytes unless it is
also given `--s3-bucket`, and deploy.sh passes no bucket. The refusal happens on the customer's
machine, before any API call:

    Templates with a size greater than 51,200 bytes must be deployed via an S3 Bucket.

The same number is CloudFormation's quota on a template body passed inline:
https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cloudformation-limits.html

cfn-lint has no rule for this limit, so this guard measures the file deploy.sh actually deploys: the
template with the placeholder replaced. deploy.sh fills the placeholder with the issuer URL minus
`https://`, and IAM accepts an OIDC provider URL of at most 255 characters:
https://docs.aws.amazon.com/IAM/latest/APIReference/API_CreateOpenIDConnectProvider.html
So the guard fills it with 247 characters, and no template a customer can deploy successfully is
larger than the one measured here.

Run it:   python3 .github/scripts/check_template_size.py
Test it:  python3 -m unittest discover -s .github/scripts -t .github/scripts -v
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = "aws/cloudformation/ringleader-onboarding.yaml"
DEPLOY_SH = "aws/cloudformation/deploy.sh"
PATHS = (TEMPLATE, DEPLOY_SH)

LIMIT = 51_200
MAX_ISSUER_URL = 255
LONGEST_PLACEHOLDER_VALUE = "h" * (MAX_ISSUER_URL - len("https://") - len("/org/") - 36) + "/org/" + "0" * 36

# deploy.sh's one substitution: sed "s|<token>|${OIDC_PROVIDER}|g" <template> > "$RENDERED"
SED_RE = re.compile(r'sed\s+"s\|(__[A-Z_]+__)\|\$\{OIDC_PROVIDER\}\|g"\s+"\$\{SCRIPT_DIR\}/ringleader-onboarding\.yaml"')


class GuardError(Exception):
    """A file could not be read the way this guard expects: the loud failure, never a silent pass."""


def placeholder(deploy_src: str) -> str:
    tokens = SED_RE.findall(deploy_src)
    if len(tokens) != 1:
        raise GuardError(
            f"{DEPLOY_SH}: found {len(tokens)} `sed` substitutions of the template, expected 1.\n\n"
            "  This guard renders the template the way deploy.sh does. If deploy.sh now renders it\n"
            "  differently, change this guard to match, so it measures what deploy.sh deploys."
        )
    if "--s3-bucket" in deploy_src:
        raise GuardError(
            f"{DEPLOY_SH}: passes --s3-bucket, so the 51,200-byte limit no longer applies to it.\n\n"
            "  Remove this guard, or change it to the 1 MB limit on a template read from S3."
        )
    return tokens[0]


def rendered_size(template_src: str, deploy_src: str) -> int:
    token = placeholder(deploy_src)
    if token not in template_src:
        raise GuardError(f"{TEMPLATE}: deploy.sh substitutes {token}, and the template does not contain it.")
    return len(template_src.replace(token, LONGEST_PLACEHOLDER_VALUE).encode("utf-8"))


def check_all(srcs: dict[str, str]) -> tuple[list[str], int | None]:
    try:
        size = rendered_size(srcs[TEMPLATE], srcs[DEPLOY_SH])
    except GuardError as err:
        return [str(err)], None
    if size > LIMIT:
        return [
            f"{TEMPLATE}: deploy.sh renders it at up to {size:,} bytes, over the {LIMIT:,}-byte limit by "
            f"{size - LIMIT:,}.\n\n"
            "  `aws cloudformation deploy` refuses it without --s3-bucket, so every customer on this\n"
            "  route fails on the first command. Shorten comments and descriptions in the template,\n"
            "  and move the explanation to aws/cloudformation/README.md or aws/README.md."
        ], size
    return [], size


def main(root: Path = REPO_ROOT) -> int:
    srcs = {path: (root / path).read_text(encoding="utf-8") for path in PATHS}
    failures, size = check_all(srcs)
    if failures:
        print("The CloudFormation template does not fit deploy.sh:\n", file=sys.stderr)
        for f in failures:
            print(f"  * {f}\n", file=sys.stderr)
        return 1
    print(f"{TEMPLATE} renders at up to {size:,} bytes, {LIMIT - size:,} under the {LIMIT:,}-byte limit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
