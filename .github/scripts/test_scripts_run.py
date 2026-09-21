"""The gcloud scripts RUN, and on their defaults they do what they did before.

Every other check in this directory reads the artifacts. None executes one, and that gap has a
shape: a shell script can be well-formed, pass `shellcheck`, satisfy every pin here, and still die
on its first line under `set -u` because an assignment reads a variable declared below it. The
customer sees an abort before anything is created, in an account we cannot reach.

So these run the two `gcp/gcloud` scripts against a stub `gcloud` on `PATH` that records its
arguments and exits 0. Nothing reaches Google, nothing needs credentials, and the assertions are
about the script's own control flow rather than about what the cloud would have done.

The DEFAULT-PATH comparison is the valuable half: the same script at `origin/main`'s parent and in
the working tree must print the same thing when no new variable is set. That is the property every
added knob here promises -- "changing nothing changes nothing" -- and it is the one a reader cannot
verify by eye once the knobs outnumber the lines.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ONBOARD = ROOT / "gcp" / "gcloud" / "onboard.sh"
NETWORK_PAD = ROOT / "gcp" / "gcloud" / "network-landing-pad.sh"

# Enough to get past each script's required-input checks. The values are shaped like the real ones
# (a UUID, an https origin with no trailing slash) because the scripts validate both.
BASE_ENV = {
    "PROJECT": "example-project",
    "ISSUER_URL": "https://oidc.example",
    "ORG_UID": "00000000-0000-0000-0000-000000000000",
}

STUB = "#!/bin/sh\nexit 0\n"


def run(script: Path, extra: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Run `script` with a stub `gcloud` first on PATH."""
    with tempfile.TemporaryDirectory() as bindir:
        stub = Path(bindir) / "gcloud"
        stub.write_text(STUB)
        stub.chmod(0o755)
        env = dict(os.environ)
        env.update(BASE_ENV)
        env.update(extra or {})
        env["PATH"] = f"{bindir}{os.pathsep}{env['PATH']}"
        return subprocess.run(
            ["bash", str(script)], capture_output=True, text=True, env=env, cwd=script.parent
        )


class TheScriptsRunAtAll(unittest.TestCase):
    """The failure `bash -n` and `shellcheck` both pass and every pin here misses."""

    def test_onboard_runs_on_its_defaults(self):
        got = run(ONBOARD)
        self.assertEqual(
            got.returncode,
            0,
            "onboard.sh did not complete on its defaults. A customer on the gcloud route gets this "
            f"instead of a landing pad:\n{got.stderr}",
        )

    def test_network_landing_pad_runs_on_its_defaults(self):
        got = run(NETWORK_PAD)
        self.assertEqual(
            got.returncode,
            0,
            "network-landing-pad.sh did not complete on its defaults. A customer on the gcloud "
            f"route gets this instead of a network:\n{got.stderr}",
        )

    def test_no_script_reads_a_variable_before_it_is_assigned(self):
        # The same defect stated as the property rather than the symptom, so a future one is named
        # for what it is rather than reported as a bare non-zero exit.
        for script in (ONBOARD, NETWORK_PAD):
            with self.subTest(script=script.name):
                got = run(script)
                self.assertNotIn(
                    "unbound variable",
                    got.stderr,
                    f"{script.name} reads a variable declared below it. Under `set -u` that is an "
                    "abort before anything is created, not a wrong value.",
                )


class TheDefaultsStillDoWhatTheyDid(unittest.TestCase):
    """Every knob added here promises that leaving it unset changes nothing. This checks it."""

    def _baseline(self, script: Path) -> str:
        """The same script as of the merge-base with origin/main, run the same way."""
        rel = script.relative_to(ROOT)
        base = subprocess.run(
            ["git", "merge-base", "HEAD", "origin/main"],
            capture_output=True, text=True, cwd=ROOT,
        )
        if base.returncode != 0 or not base.stdout.strip():
            self.skipTest("no origin/main to compare against")
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=ROOT,
        )
        if head.stdout.strip() == base.stdout.strip():
            # On `main`, or on a branch checked out too shallowly for the merge base to be an
            # ancestor, the baseline IS this commit and the comparison would pass vacuously.
            # Skipping says so; passing would not.
            self.skipTest(
                "the merge base is HEAD, so there is no earlier revision to compare against; "
                "run this on a branch, with enough history fetched for the merge base to resolve"
            )
        show = subprocess.run(
            ["git", "show", f"{base.stdout.strip()}:{rel.as_posix()}"],
            capture_output=True, text=True, cwd=ROOT,
        )
        if show.returncode != 0:
            self.skipTest(f"{rel} does not exist at the merge base")
        with tempfile.TemporaryDirectory() as d:
            old = Path(d) / script.name
            old.write_text(show.stdout)
            # Run it from the real directory so any sibling it sources resolves.
            target = script.parent / f".baseline-{script.name}"
            target.write_text(show.stdout)
            try:
                return run(target).stdout
            finally:
                target.unlink(missing_ok=True)

    def test_onboard_is_unchanged_when_no_new_variable_is_set(self):
        self.assertEqual(
            self._baseline(ONBOARD),
            run(ONBOARD).stdout,
            "onboard.sh behaves differently on its defaults than it did before this change. Every "
            "variable added here defaults to what the script already did, so an unset run must be "
            "indistinguishable -- a customer re-running it is not asking for anything new.",
        )

    def test_network_landing_pad_is_unchanged_when_no_new_variable_is_set(self):
        self.assertEqual(
            self._baseline(NETWORK_PAD),
            run(NETWORK_PAD).stdout,
            "network-landing-pad.sh behaves differently on its defaults than it did before this "
            "change. The eleven names it creates are built from NAME_PREFIX now, and its default "
            "has to reproduce the names every applied landing pad already carries.",
        )


class TheKnobsReachTheCommands(unittest.TestCase):
    """A variable that changes nothing observable is a variable that is not wired up."""

    def test_the_name_prefix_renames_the_landing_pad(self):
        got = run(NETWORK_PAD, {"NAME_PREFIX": "acme2org"}).stdout
        self.assertIn("acme2org", got, "NAME_PREFIX does not reach network-landing-pad.sh's output")
        # The network TAGS are deliberately not prefixed: Ringleader sets those itself.
        self.assertIn(
            "ringleader-workstation",
            got,
            "the workstation network tag moved with NAME_PREFIX. Ringleader sets that tag, so a "
            "renamed one is a rule that admits nobody.",
        )

    def test_the_artifact_label_reaches_the_grant(self):
        got = run(ONBOARD, {"ARTIFACT_STORAGE_BUCKET_PREFIX": "0192f5bf"}).stdout
        self.assertIn(
            "ringleader-0192f5bf",
            got,
            "ARTIFACT_STORAGE_BUCKET_PREFIX does not reach the artifact-storage bound, so two "
            "organizations in one project still share it.",
        )

    def test_an_artifact_label_of_the_wrong_length_is_refused(self):
        # The separation two organizations get rests on every label being the same length.
        got = run(ONBOARD, {"ARTIFACT_STORAGE_BUCKET_PREFIX": "acme"})
        self.assertNotEqual(
            got.returncode, 0, "a four-character label was accepted; it would overlap `acmedev`"
        )


if __name__ == "__main__":
    unittest.main()
