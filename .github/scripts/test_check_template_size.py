#!/usr/bin/env python3
"""The template-size guard's own teeth, proved against the REAL shipped template and deploy.sh.

Run:  python3 -m unittest discover -s .github/scripts -t .github/scripts
"""

from __future__ import annotations

import contextlib
import io
import unittest

from check_template_size import (
    DEPLOY_SH,
    LIMIT,
    LONGEST_PLACEHOLDER_VALUE,
    PATHS,
    REPO_ROOT,
    TEMPLATE,
    check_all,
    main,
)

TOKEN = "__OIDC_PROVIDER__"


def sources() -> dict[str, str]:
    return {p: (REPO_ROOT / p).read_text(encoding="utf-8") for p in PATHS}


def padded_to(srcs: dict[str, str], rendered_bytes: int) -> dict[str, str]:
    """The real template plus a trailing comment, sized so the RENDERED file is exactly that long."""
    growth = srcs[TEMPLATE].count(TOKEN) * (len(LONGEST_PLACEHOLDER_VALUE) - len(TOKEN))
    pad = rendered_bytes - growth - len(srcs[TEMPLATE].encode("utf-8"))
    assert pad > 2, "the shipped template is already too large to pad"
    srcs[TEMPLATE] += "#" + "x" * (pad - 2) + "\n"
    return srcs


class TheShippedTemplatePasses(unittest.TestCase):
    def test_main_is_green_on_this_branch(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(), 0)

    def test_it_measures_the_rendered_file(self):
        srcs = sources()
        _, size = check_all(srcs)
        self.assertGreater(size, len(srcs[TEMPLATE].encode("utf-8")))


class TheLimit(unittest.TestCase):
    def test_exactly_the_limit_passes(self):
        # The CLI refuses a size GREATER than 51,200 bytes, so 51,200 itself deploys.
        failures, size = check_all(padded_to(sources(), LIMIT))
        self.assertEqual(size, LIMIT)
        self.assertEqual(failures, [])

    def test_one_byte_over_fails(self):
        failures, size = check_all(padded_to(sources(), LIMIT + 1))
        self.assertEqual(size, LIMIT + 1)
        self.assertTrue(any("over the 51,200-byte limit by 1" in f for f in failures), failures)

    def test_a_template_under_the_limit_only_before_rendering_fails(self):
        srcs = padded_to(sources(), LIMIT + 1)
        self.assertLessEqual(len(srcs[TEMPLATE].encode("utf-8")), LIMIT)
        failures, _ = check_all(srcs)
        self.assertTrue(failures)


class TheReaderFailsLoudly(unittest.TestCase):
    def assertRejected(self, srcs, needle):
        failures, _ = check_all(srcs)
        self.assertTrue(any(needle in f for f in failures), f"no failure mentioned {needle!r}: {failures}")

    def test_deploy_sh_stops_rendering_the_template(self):
        srcs = sources()
        srcs[DEPLOY_SH] = srcs[DEPLOY_SH].replace('sed "s|', 'sed -e "s|')
        self.assertRejected(srcs, "expected 1")

    def test_deploy_sh_uploads_through_s3(self):
        srcs = sources()
        srcs[DEPLOY_SH] = srcs[DEPLOY_SH].replace("--template-file", '--s3-bucket "$BUCKET" --template-file')
        self.assertRejected(srcs, "--s3-bucket")

    def test_the_template_loses_the_placeholder(self):
        srcs = sources()
        srcs[TEMPLATE] = srcs[TEMPLATE].replace(TOKEN, "oidc.example.com/org/x")
        self.assertRejected(srcs, "does not contain it")


if __name__ == "__main__":
    unittest.main()
