#!/usr/bin/env bash
# Vendor non-CRD JSON Schema assets from a single source into an output dir.
# Usage: extras.sh <source-dir> <output-dir>
#
# Reads <source-dir>/vendir.yml and runs `vendir sync` in a scratch dir. If a
# `compose.sh` sits next to the vendir.yml, the script is handed the vendor
# tree, the output dir, and the site dir, and is expected to produce the
# published files itself; otherwise every regular file vendir selected is
# copied flat into <output-dir>. The output is what gets served at
# /extras/<owner>/<name>/.

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

if [[ -x "$SOURCE_DIR/compose.sh" ]]; then
  "$SOURCE_DIR/compose.sh" "$WORK/vendor" "$OUTPUT_DIR" "${OUT_DIR:-out}/site"
  exit 0
fi

# vendir auto-includes top-level LICENSE/README from git sources; skip them.
mapfile -t files < <(find "$WORK/vendor" -mindepth 2 -type f)
if (( ${#files[@]} == 0 )); then
  echo "vendir produced no files for $SOURCE_DIR" >&2
  exit 1
fi

cp -t "$OUTPUT_DIR" "${files[@]}"
