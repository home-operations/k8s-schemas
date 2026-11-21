"""Check each rule set against the upstream that it pins.

Run from the repo root (mise run test-evidence):
    uv run --locked pytest scripts/test_evidence.py

Needs vendir on PATH and network access, so it is apart from the other tests.
"""

import difflib

import pytest

from metadata import RULES_DIR, fetch_evidence, load_rule_sets

RULE_SETS = load_rule_sets(RULES_DIR)


@pytest.mark.parametrize("name", RULE_SETS)
def test_evidence_matches_the_pinned_upstream(name: str):
    recorded = (RULES_DIR / name / "evidence.txt").read_text().splitlines()
    fetched = fetch_evidence(RULES_DIR / name, RULE_SETS[name]).splitlines()
    diff = "\n".join(difflib.unified_diff(recorded, fetched, "evidence.txt", "upstream", lineterm=""))
    assert not diff, (
        f"The upstream lines behind metadata/{name}/rules.yaml changed. "
        f"Check the rules against the new lines, then run `mise run metadata-evidence`.\n{diff}"
    )
