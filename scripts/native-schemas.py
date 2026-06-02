#!/usr/bin/env python3
"""Split the Kubernetes OpenAPI spec into per-kind JSON schemas for native
(non-CRD) types: <group>/<kind>_<version>.json with $refs into a shared
_definitions.json. crd-schema-publisher is CRD-only, so these aren't indexed.

Usage: native-schemas.py <native-source-dir> <site-dir>
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA = "http://json-schema.org/draft-04/schema#"

src, site = Path(sys.argv[1]), Path(sys.argv[2])

match = re.search(r"ref:\s*(v\d[\d.]*)", (src / "vendir.yml").read_text())
if not match:
    sys.exit(f"no kubernetes ref found in {src / 'vendir.yml'}")
ref = match.group(1)

# A k8s clone is ~800MB, so skip the sync when vendor already holds this tag.
marker = src / "vendor" / ".ref"
if not marker.exists() or marker.read_text().strip() != ref:
    subprocess.run(["vendir", "sync", "--chdir", str(src)], check=True, stdout=sys.stderr)
    marker.write_text(ref + "\n")

definitions = json.loads((src / "vendor/api/openapi-spec/swagger.json").read_text())["definitions"]

# Publish under the minor so $schema URLs survive patch bumps.
out = site / "k8s" / ".".join(ref.split(".")[:2])
shutil.rmtree(out, ignore_errors=True)


def fix(node: Any) -> Any:
    """int-or-string has no real type -> string|int union."""
    if isinstance(node, dict):
        if node.get("format") == "int-or-string":
            union = {"oneOf": [{"type": "string"}, {"type": "integer"}]}
            return union | {"description": node["description"]} if "description" in node else union
        return {key: fix(value) for key, value in node.items()}
    if isinstance(node, list):
        return [fix(value) for value in node]
    return node


def deref(node: Any) -> Any:
    """repoint a kind's internal refs at the shared bundle."""
    if isinstance(node, dict):
        return {
            key: value.replace("#/definitions/", "../_definitions.json#/definitions/", 1)
            if key == "$ref"
            else deref(value)
            for key, value in node.items()
        }
    if isinstance(node, list):
        return [deref(value) for value in node]
    return node


def write(path: str, content: Any) -> None:
    dest = out / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(content, indent=2) + "\n")


write("_definitions.json", {"$schema": SCHEMA, "definitions": fix(definitions)})

count = 0
for schema in definitions.values():
    # Require apiVersion+kind properties; skips internal GVK types like WatchEvent.
    if {"apiVersion", "kind"} - schema.get("properties", {}).keys():
        continue
    for gvk in schema.get("x-kubernetes-group-version-kind", []):
        group, version, kind = gvk["group"], gvk["version"], gvk["kind"]
        content = deref(fix(schema))
        content["$schema"] = SCHEMA
        content["properties"]["apiVersion"]["enum"] = [f"{group}/{version}" if group else version]
        content["properties"]["kind"]["enum"] = [kind]
        write(f"{group or 'core'}/{kind.lower()}_{version}.json", content)
        count += 1

print(f"native: wrote {count} schemas to {out}", file=sys.stderr)
