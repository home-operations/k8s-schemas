#!/usr/bin/env bash
set -euo pipefail

# Fetch an external (non-CRD) source's upstream JSON schemas at the pinned
# version and copy them verbatim into the site. No conversion — upstream
# already publishes ready-to-use JSON schema files.

SOURCE_DIR="${1:?usage: external.sh <source-dir> <output-dir>}"
OUTPUT_DIR="${2:?usage: external.sh <source-dir> <output-dir>}"
SOURCE_DIR="$(cd "${SOURCE_DIR%/}" && pwd)"
mkdir -p "$OUTPUT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SOURCE_DIR/vendir.yml" "$WORK/"
vendir sync --chdir "$WORK" >&2

found=0
while IFS= read -r -d '' file; do
    cp "$file" "$OUTPUT_DIR/"
    found=1
done < <(find "$WORK/vendor" -name '*.json' -print0)

[[ "$found" -eq 1 ]] || { echo "no JSON schemas fetched for $SOURCE_DIR" >&2; exit 1; }
