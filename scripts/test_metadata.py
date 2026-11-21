"""Tests for the metadata rules and their compiler.

Run from the repo root (mise run test):
    uv run --locked pytest scripts

The site tests need crd-schema-publisher and kubeconform on PATH. The evidence
test needs vendir and network access.
"""

import difflib
import json
import re
import subprocess
from pathlib import Path

import pytest
import yaml

from metadata import (
    MARKER,
    RULES_DIR,
    Rule,
    RulesError,
    collect_evidence,
    compile_rules,
    fetch_evidence,
    is_resource,
    load_rule_sets,
    patch,
    patch_site,
    rule_schema,
)

TESTDATA = Path(__file__).parent / "testdata"
RULE_SETS = load_rule_sets(RULES_DIR)
RULES = [rule for rule_set in RULE_SETS.values() for rule in rule_set.rules]

# One CRD kind and one built-in kind, as the converter writes them.
KINDS = [("example.com/v1", "Widget"), ("scheduling.k8s.io/v1", "PriorityClass")]


def write_rule_set(tmp_path: Path, name: str, *rules: dict, evidence: tuple[str, ...] = ("mode",)) -> None:
    (tmp_path / name).mkdir()
    (tmp_path / name / "rules.yaml").write_text(yaml.safe_dump({"evidence": list(evidence), "rules": list(rules)}))


def rule(**overrides: object) -> dict:
    return {"key": "example.com/mode", "fields": ["annotations"], "values": ["on"], "description": "A mode."} | overrides


def test_schema_file_matches_the_model():
    assert json.loads((RULES_DIR / "schema.json").read_text()) == rule_schema(), "run `mise run metadata-schema`"


@pytest.mark.parametrize(
    ("override", "error"),
    [
        ({"key": "mode"}, "key"),
        ({"fields": ["finalizers"]}, "fields"),
        ({"fields": []}, "fields"),
        ({"values": []}, "values"),
        ({"description": ""}, "description"),
        ({"extra": True}, "extra"),
        ({"ignoreCase": True, "values": ["a|b"]}, "values must match"),
    ],
)
def test_invalid_rule_is_rejected(tmp_path: Path, override: dict, error: str):
    write_rule_set(tmp_path, "bad", rule(**override))
    with pytest.raises(RulesError, match=rf"bad: (.|\n)*{error}"):
        load_rule_sets(tmp_path)


@pytest.mark.parametrize("evidence", [(), ("(",)])
def test_invalid_evidence_is_rejected(tmp_path: Path, evidence: tuple[str, ...]):
    write_rule_set(tmp_path, "bad", rule(), evidence=evidence)
    with pytest.raises(RulesError, match=r"bad: (.|\n)*evidence"):
        load_rule_sets(tmp_path)


def test_second_rule_for_a_key_is_rejected(tmp_path: Path):
    write_rule_set(tmp_path, "a", rule(fields=["annotations", "labels"]))
    write_rule_set(tmp_path, "b", rule(fields=["labels"]))
    with pytest.raises(RulesError, match=r"b: a already has a rule for example\.com/mode in labels"):
        load_rule_sets(tmp_path)


def test_directory_without_rule_sets_is_rejected(tmp_path: Path):
    with pytest.raises(RulesError, match="no rule sets"):
        load_rule_sets(tmp_path)


def test_collect_evidence(tmp_path: Path):
    (tmp_path / "b").mkdir()
    (tmp_path / "b/types.go").write_text('const (\n\tMode    = "on"\n\tOther = 1\n)\n')
    (tmp_path / "a.md").write_text("Set `example.com/mode` to on.\n")
    (tmp_path / "unrelated.md").write_text("Nothing here.\n")
    # Each pattern stands alone: a flag or a group in one does not reach the next.
    patterns = ["(?i)MODE +=", r"(example)\.com/mode", r"(o)n\1?\."]
    assert collect_evidence(patterns, tmp_path) == (
        'a.md\n  Set `example.com/mode` to on.\nb/types.go\n  Mode = "on"\n'
    )


@pytest.mark.parametrize("vendor", ["", "missing"])
def test_pattern_without_a_match_is_rejected(tmp_path: Path, vendor: str):
    (tmp_path / "a.md").write_text("Set `example.com/mode` to on.\n")
    with pytest.raises(ValueError, match="no line in .* matches: gone"):
        collect_evidence(["mode", "gone"], tmp_path / vendor)


@pytest.mark.parametrize("name", RULE_SETS)
def test_evidence_matches_the_pinned_upstream(name: str):
    recorded = (RULES_DIR / name / "evidence.txt").read_text().splitlines()
    fetched = fetch_evidence(RULES_DIR / name, RULE_SETS[name]).splitlines()
    diff = "\n".join(difflib.unified_diff(recorded, fetched, "evidence.txt", "upstream", lineterm=""))
    assert not diff, (
        f"The upstream lines behind metadata/{name}/rules.yaml changed. "
        f"Check the rules against the new lines, then run `mise run metadata-evidence`.\n{diff}"
    )


def test_value_schema():
    exact = Rule.model_validate(rule(values=["on", "off"]))
    assert exact.value_schema() == {"description": "A mode.", "type": "string", "enum": ["on", "off"]}

    folded = Rule.model_validate(rule(values=["On", "v1.2-b_c"], ignoreCase=True))
    pattern = folded.value_schema()["pattern"]
    assert pattern == "^([Oo][Nn]|[Vv]1[.]2-[Bb]_[Cc])$"
    for value in ["on", "ON", "oN", "V1.2-B_c"]:
        assert re.search(pattern, value) and folded.accepts(value)
    for value in ["", "o", "onn", "on v1.2-b_c", "v1x2-b_c", "true"]:
        assert not re.search(pattern, value) and not folded.accepts(value)


def test_compile_groups_rules_by_field():
    rules = [
        Rule.model_validate(rule(fields=["annotations", "labels"])),
        Rule.model_validate(rule(key="example.com/other", fields=["labels"])),
    ]
    fields = compile_rules(rules)["properties"]["metadata"]["properties"]
    assert list(fields["annotations"]["properties"]) == ["example.com/mode"]
    assert list(fields["labels"]["properties"]) == ["example.com/mode", "example.com/other"]


def test_patch_replaces_its_own_branch_only():
    other = {"required": ["spec"]}
    old, new = {"$comment": MARKER, "old": True}, {"$comment": MARKER, "new": True}
    assert patch({"type": "object", "allOf": [other, old]}, new) == {"type": "object", "allOf": [other, new]}


@pytest.fixture(scope="module")
def site(tmp_path_factory: pytest.TempPathFactory) -> Path:
    site = tmp_path_factory.mktemp("site")
    crd, swagger = TESTDATA / "crd.yaml", TESTDATA / "swagger.json"
    convert = ["crd-schema-publisher", "convert", "-f", crd, "--openapi", swagger, "--kustomize", "-o", site]
    subprocess.run(convert, check=True, capture_output=True)
    patch_site(site, compile_rules(RULES))
    return site


def test_only_resources_are_patched(site: Path):
    patched = {
        path
        for path in json.loads((site / "_meta/schema-metadata.json").read_text())
        if any(b.get("$comment") == MARKER for b in json.loads((site / path).read_text()).get("allOf", []))
    }
    assert patched == {"example.com/widget_v1.json", "scheduling.k8s.io/priorityclass_v1.json"}


def test_kubeval_copy_matches(site: Path):
    grouped = (site / "example.com/widget_v1.json").read_text()
    assert grouped == (site / "master-standalone/example.com-widget-stable-v1.json").read_text()


def test_second_run_changes_nothing(site: Path):
    before = (site / "example.com/widget_v1.json").read_text()
    patch_site(site, compile_rules(RULES))
    assert (site / "example.com/widget_v1.json").read_text() == before


def test_missing_kubeval_copy_fails(site: Path, tmp_path: Path):
    for path in ["_meta/schema-metadata.json", "example.com/widget_v1.json"]:
        (tmp_path / path).parent.mkdir(exist_ok=True)
        (tmp_path / path).write_text((site / path).read_text())
    with pytest.raises(FileNotFoundError, match="no kubeval copy of example.com/widget_v1.json"):
        patch_site(tmp_path, compile_rules(RULES))


def test_is_resource(site: Path):
    def check(path: str, source: str) -> bool:
        return is_resource(json.loads((site / path).read_text()), source)

    assert check("example.com/widget_v1.json", "crd")
    assert check("scheduling.k8s.io/priorityclass_v1.json", "builtin")
    assert not check("scheduling.k8s.io/priorityclasslist_v1.json", "builtin")
    assert not check("kustomize.config.k8s.io/kustomization_v1beta1.json", "kustomize")


def cases() -> list[tuple[str, str, object, bool]]:
    """Values to try for every rule, with the answer that the rule gives."""
    out: list[tuple[str, str, object, bool]] = [("annotations", "example.com/unclaimed", "anything", True)]
    for r in RULES:
        candidates = {c for v in r.values for c in (v, v.swapcase(), f"{v}x")} | {"true", ""}
        for field in r.fields:
            out += [(field, r.key, value, r.accepts(value)) for value in sorted(candidates)]
            # YAML reads an unquoted true as a boolean.
            out.append((field, r.key, True, False))
    return out


def test_kubeconform_enforces_every_rule(site: Path, tmp_path: Path):
    expected: dict[str, tuple[str, str, bool]] = {}
    documents = []
    for api_version, kind in KINDS:
        for field, key, value, accepted in cases():
            name = f"case-{len(documents)}"
            expected[name] = (f"{kind} {field} {key}={value!r}", key, accepted)
            body = {"spec": {"size": 1}} if kind == "Widget" else {"value": 1}
            documents.append({"apiVersion": api_version, "kind": kind, "metadata": {"name": name, field: {key: value}}} | body)
    manifests = tmp_path / "manifests.yaml"
    manifests.write_text(yaml.safe_dump_all(documents))

    location = f"{site}/{{{{ .Group }}}}/{{{{ .ResourceKind }}}}_{{{{ .ResourceAPIVersion }}}}.json"
    run = subprocess.run(
        ["kubeconform", "-strict", "-verbose", "-output", "json", "-schema-location", location, manifests],
        capture_output=True,
        text=True,
        check=False,  # an invalid manifest is an expected result
    )
    results = {r["name"]: r for r in json.loads(run.stdout)["resources"]}

    assert results.keys() == expected.keys(), run.stderr
    wrong = []
    for name, (case, key, accepted) in expected.items():
        status, message = results[name]["status"], results[name]["msg"]
        # A rejection must come from the rule, not from another part of the schema.
        # The message holds the key as a JSON pointer, which writes "/" as "~1".
        if (status == "statusValid") != accepted or (not accepted and key.replace("/", "~1") not in message):
            wrong.append(f"{case}: expected {'valid' if accepted else 'invalid'}, got {status} {message}")
    assert not wrong, "\n".join(wrong)
    # The cases must exercise both answers, or the test proves nothing.
    assert {accepted for _, _, accepted in expected.values()} == {True, False}
