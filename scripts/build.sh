#!/usr/bin/env bash
# Extract CRDs from a single source into a YAML file.
# Usage: build.sh <source-dir> <output-file>
#
# Reads <source-dir>/vendir.yml, runs `vendir sync`, walks the vendored tree
# and writes a single multi-doc YAML containing only the
# CustomResourceDefinition documents. The result is then ingested by
# crd-schema-publisher in the publish step.

set -euo pipefail

SOURCE_DIR="${1:?usage: build.sh <source-dir> <output-file>}"
OUTPUT_FILE="${2:?usage: build.sh <source-dir> <output-file>}"

SOURCE_DIR="${SOURCE_DIR%/}"
mkdir -p "$(dirname "$OUTPUT_FILE")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SOURCE_DIR/vendir.yaml" "$WORK/"
pushd "$WORK" >/dev/null
vendir sync -f vendir.yaml >&2
popd >/dev/null

CRDS="$WORK/crds.yaml"
: > "$CRDS"

while IFS= read -r -d '' f; do
  yq 'select(.kind == "CustomResourceDefinition")' "$f" >> "$CRDS"
  printf -- '---\n' >> "$CRDS"
done < <(find "$WORK/vendor" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

[[ -s "$CRDS" ]] || { echo "no CRDs extracted from $SOURCE_DIR" >&2; exit 1; }

mv "$CRDS" "$OUTPUT_FILE"
