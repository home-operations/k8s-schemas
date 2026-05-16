#!/usr/bin/env bash
# Vendor non-CRD JSON Schema assets from a single source into a flat output dir.
# Usage: extras.sh <source-dir> <output-dir>
#
# Reads <source-dir>/vendir.yml, runs `vendir sync` in a scratch dir, and
# copies every regular file the upstream config selected (via includePaths or
# asset names) into <output-dir> with its basename. The output is the path
# served at /extras/<owner>/<name>/ on the published site.

set -euo pipefail
shopt -s globstar nullglob

SOURCE_DIR="${1:?usage: extras.sh <source-dir> <output-dir>}"
OUTPUT_DIR="${2:?usage: extras.sh <source-dir> <output-dir>}"

SOURCE_DIR="$(cd "${SOURCE_DIR%/}" && pwd)"

mkdir -p "$OUTPUT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SOURCE_DIR/vendir.yml" "$WORK/"
vendir sync --chdir "$WORK" >&2

# vendir auto-includes top-level LICENSE/README from git sources; skip them.
mapfile -t files < <(find "$WORK/vendor" -mindepth 2 -type f)
if (( ${#files[@]} == 0 )); then
  echo "vendir produced no files for $SOURCE_DIR" >&2
  exit 1
fi

cp -t "$OUTPUT_DIR" "${files[@]}"
