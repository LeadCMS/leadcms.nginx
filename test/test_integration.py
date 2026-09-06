"""Test explorer front end for the bash integration suite.

Every case in test/run-integration-tests.sh shows up as its own node in the
VS Code test explorer and can be run on its own. This module only shells out to
that script — the suite itself stays in bash, so CI keeps running exactly the
same code path with no Python involved.

The docker stack is started once per session and deliberately left running
afterwards, which makes a re-run cost a couple of seconds instead of a full
rebuild. The runner rebuilds by itself whenever anything under nginx/ or
certbot/ changed since the last build, so a reused stack can never serve stale
container scripts. To stop it:

    bash test/run-integration-tests.sh --teardown
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "test" / "run-integration-tests.sh"
BOOTSTRAP_CASE = "bootstrap environment"


def _run(*args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(RUNNER), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=check,
    )


def _case_names() -> list[str]:
    """Reads the case list from the runner. Touches no docker, so collection is fast."""
    result = _run("--list")
    if result.returncode != 0:
        # Raised at import time, so it surfaces as a collection error with the
        # actual reason rather than an empty test tree.
        raise RuntimeError(
            f"could not list the integration test cases\n"
            f"command: bash {RUNNER} --list\n{result.stdout}{result.stderr}"
        )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


# The bootstrap is a fixture rather than a test: everything else depends on it.
CASES = [name for name in _case_names() if name != BOOTSTRAP_CASE]

# Case names contain spaces, which pytest's -k cannot express. Underscores keep
# the node ids both readable in the explorer and filterable from a terminal,
# e.g. `pytest -k hot_reload`. The case name itself is passed through unchanged.
CASE_IDS = [name.replace(" ", "_") for name in CASES]


@pytest.fixture(scope="session")
def stack() -> None:
    result = _run("--only", BOOTSTRAP_CASE, "--reuse", "--keep", "--no-report")
    if result.returncode != 0:
        pytest.fail(
            f"could not start the integration test stack\n\n{result.stdout}{result.stderr}",
            pytrace=False,
        )


@pytest.mark.parametrize("case", CASES, ids=CASE_IDS)
def test_integration_case(case: str, stack: None) -> None:
    result = _run("--reuse", "--keep", "--no-report", "--only", case)
    if result.returncode != 0:
        pytest.fail(f"{case}\n\n{result.stdout}{result.stderr}", pytrace=False)
