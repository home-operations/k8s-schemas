#!/usr/bin/env bash
# Extract CRDs from a single source into a YAML file.
# Usage: build.sh <source-dir> <output-file>
#
# Reads <source-dir>/vendir.yml, runs `vendir sync` in a scratch dir, and
# yq-filters the vendored tree into one multi-doc YAML containing only the
# CustomResourceDefinition documents. The result is then ingested by
# crd-schema-publisher in the publish step.

set -euo pipefail
shopt -s globstar nullglob

SOURCE_DIR="${1:?usage: build.sh <source-dir> <output-file>}"
OUTPUT_FILE="${2:?usage: build.sh <source-dir> <output-file>}"

# Resolve to absolute so vendir --chdir doesn't lose the path.
SOURCE_DIR="$(cd "${SOURCE_DIR%/}" && pwd)"

mkdir -p "$(dirname "$OUTPUT_FILE")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SOURCE_DIR/vendir.yml" "$WORK/"
vendir sync --chdir "$WORK" >&2

# Strip any inline helm template directives so files like longhorn-manager's
# k8s/crds.yaml parse as plain YAML. Safe for CRDs — neither openAPIV3Schema
# nor any standard CRD field contains literal `{{...}}`.
find "$WORK/vendor" -name '*.yaml' -exec sd '\{\{[^}]*\}\}' '' {} \;

files=("$WORK"/vendor/**/*.yaml "$WORK"/vendor/**/*.yml)
if (( ${#files[@]} == 0 )); then
  echo "vendir produced no YAML files for $SOURCE_DIR" >&2
  exit 1
fi

yq eval-all 'select(.kind == "CustomResourceDefinition")' "${files[@]}" > "$OUTPUT_FILE"

[[ -s "$OUTPUT_FILE" ]] || { echo "no CRDs extracted from $SOURCE_DIR" >&2; exit 1; }
