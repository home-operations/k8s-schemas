"""Compile the metadata rules into the converted schemas.

A rule in metadata/*.yaml lists the values that a controller accepts for one
annotation or label key. Compiling adds the rules to every resource schema, so
that validators and editors check those values. Run it after
`crd-schema-publisher convert`.

Compile (mise run site): uv run --locked --no-dev scripts/metadata.py <site-dir>
Schema export (mise run metadata-schema): uv run --locked --no-dev scripts/metadata.py --schema

Exits non-zero with one error per line on stderr when a rule file is invalid.
"""

import json
import re
import sys
from pathlib import Path
from typing import Any, Literal, Self

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from pydantic.alias_generators import to_camel

RULES_DIR = Path(__file__).parents[1] / "metadata"

# Marks the branch that this script owns, so that a second run replaces it.
MARKER = "k8s-schemas metadata rules"

# A key must carry a DNS prefix, so that a rule never claims a key that any
# tool could use.
KEY_PATTERN = r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?/[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"

type Schema = dict[str, Any]


class RulesError(Exception):
    """A rule file is invalid."""


class _Model(BaseModel):
    model_config = ConfigDict(extra="forbid", alias_generator=to_camel)


class Rule(_Model):
    key: str = Field(pattern=KEY_PATTERN, description="The annotation or label key, with its DNS prefix.")
    fields: list[Literal["annotations", "labels"]] = Field(
        min_length=1, description="The metadata fields where the controller reads the key."
    )
    values: list[str] = Field(
        min_length=1, description="Every value that the controller documents for the key, defaults included."
    )
    ignore_case: bool = Field(
        default=False, description="Set to true when the controller compares the value without regard to case."
    )
    description: str = Field(min_length=1, description="The text that editors show on hover.")

    @model_validator(mode="after")
    def _values_fit_a_pattern(self) -> Self:
        # ignore_case turns the values into a regular expression. These are the
        # characters of a label value, and only "." needs escaping.
        if self.ignore_case and not all(re.fullmatch(r"[A-Za-z0-9._-]+", v) for v in self.values):
            raise ValueError("values must match [A-Za-z0-9._-]+ when ignoreCase is true")
        return self

    def accepts(self, value: str) -> bool:
        if self.ignore_case:
            return value.lower() in (v.lower() for v in self.values)
        return value in self.values

    def value_schema(self) -> Schema:
        # CRD schemas do not type their metadata, so the type is stated here.
        schema = {"description": self.description, "type": "string"}
        if not self.ignore_case:
            return schema | {"enum": self.values}
        # A character class per letter is the only portable way to ignore case:
        # JSON Schema has no keyword for it, and not every validator accepts an
        # inline (?i) flag.
        alternatives = (
            "".join(f"[{c.upper()}{c.lower()}]" if c.isalpha() else "[.]" if c == "." else c for c in v)
            for v in self.values
        )
        return schema | {"pattern": f"^({'|'.join(alternatives)})$"}


class RuleFile(_Model):
    """Value rules for well-known annotation and label keys."""

    rules: list[Rule] = Field(min_length=1)


def rule_schema() -> Schema:
    return RuleFile.model_json_schema()


def load_rules(rules_dir: Path) -> list[Rule]:
    rules: list[Rule] = []
    owners: dict[tuple[str, str], str] = {}
    for file in sorted(rules_dir.glob("*.yaml")):
        try:
            parsed = RuleFile.model_validate(yaml.safe_load(file.read_text()))
        except (yaml.YAMLError, ValidationError) as e:
            raise RulesError(f"{file.name}: {e}") from e
        for rule in parsed.rules:
            for field in rule.fields:
                if owner := owners.get((field, rule.key)):
                    raise RulesError(f"{file.name}: {owner} already has a rule for {rule.key} in {field}")
                owners[field, rule.key] = file.name
        rules += parsed.rules
    if not rules:
        raise RulesError(f"no rule files in {rules_dir}")
    return rules


def compile_rules(rules: list[Rule]) -> Schema:
    """Build one schema branch for all rules.

    The branch only constrains the listed keys, so every other annotation and
    label still passes.
    """
    fields: dict[str, Schema] = {}
    for rule in rules:
        for field in rule.fields:
            fields.setdefault(field, {"properties": {}})["properties"][rule.key] = rule.value_schema()
    return {"$comment": MARKER, "properties": {"metadata": {"properties": fields}}}


def is_resource(schema: Schema, source: str) -> bool:
    """Tell if the schema is for a kind that carries annotations and labels.

    That is every CRD kind, and each built-in kind with ObjectMeta. The other
    built-in kinds (lists, DeleteOptions, ...) have none, and neither do the
    kustomize configuration kinds.
    """
    if source == "crd":
        return True
    metadata = schema.get("properties", {}).get("metadata", {})
    refs = [s.get("$ref", "") for s in (metadata, *metadata.get("anyOf", []))]
    return source == "builtin" and any(ref.endswith(".ObjectMeta") for ref in refs)


def patch(schema: Schema, branch: Schema) -> Schema:
    """Add the branch at the root, where it works for every schema shape."""
    kept = [b for b in schema.get("allOf", []) if b.get("$comment") != MARKER]
    return {**schema, "allOf": [*kept, branch]}


def patch_site(site_dir: Path, branch: Schema) -> int:
    """Patch every resource schema in a converted site. Return how many."""
    sources = json.loads((site_dir / "_meta/schema-metadata.json").read_text())
    patched = 0
    for path, entry in sources.items():
        file = site_dir / path
        schema = json.loads(file.read_text())
        if not is_resource(schema, entry["source"]):
            continue
        # convert writes each schema a second time, in the layout that kubeval reads.
        kind, version = file.stem.rsplit("_", 1)
        copy = site_dir / "master-standalone" / f"{file.parent.name}-{kind}-stable-{version}.json"
        if not copy.is_file():
            raise FileNotFoundError(f"no kubeval copy of {path} at {copy}")
        text = json.dumps(patch(schema, branch), indent=2, sort_keys=True, ensure_ascii=False)
        file.write_text(text)
        copy.write_text(text)
        patched += 1
    if not patched:
        raise ValueError(f"no resource schemas in {site_dir}")
    return patched


def main(argv: list[str]) -> int:
    if argv == ["--schema"]:
        print(json.dumps(rule_schema(), indent=2))
        return 0
    if len(argv) != 1:
        print("usage: metadata.py <site-dir> | --schema", file=sys.stderr)
        return 2
    try:
        rules = load_rules(RULES_DIR)
    except RulesError as e:
        print(e, file=sys.stderr)
        return 1
    patched = patch_site(Path(argv[0]), compile_rules(rules))
    print(f"compiled {len(rules)} metadata rules into {patched} schemas", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
