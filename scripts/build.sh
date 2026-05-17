#!/usr/bin/env bash
set -euo pipefail
shopt -s globstar nullglob

SOURCE_DIR="${1:?usage: build.sh <source-dir> <output-file>}"
OUTPUT_FILE="${2:?usage: build.sh <source-dir> <output-file>}"
SOURCE_DIR="$(cd "${SOURCE_DIR%/}" && pwd)"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# $VENDOR_CACHE = persistent workdir (actions/cache); unset = tmp.
if [[ -n "${VENDOR_CACHE:-}" ]]; then
    WORK="$VENDOR_CACHE"
    mkdir -p "$WORK"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi

# Single cache decision: if every input is byte-identical to the last
# successful run, the stored output is reusable. Mirrors what the workflow's
# actions/cache key encodes, but also gives local persistent-$WORK users the
# same fast-path.
hash_inputs() {
    cat "$SOURCE_DIR/vendir.yml"
    [[ -f "$SOURCE_DIR/kind.yaml" ]] && cat "$SOURCE_DIR/kind.yaml"
    cat scripts/build.sh scripts/kind-extract.sh
}
HASH="$(hash_inputs | sha256sum | cut -d' ' -f1)"

if [[ -f "$WORK/output.yaml" && "$(cat "$WORK/.hash" 2>/dev/null)" == "$HASH" ]]; then
    echo "cached for $SOURCE_DIR — reusing previous output" >&2
    cp "$WORK/output.yaml" "$OUTPUT_FILE"
    exit
fi

# Clean slate. A partial leftover from a previous run's failure could otherwise
# mix with this run's vendor/.
rm -rf "$WORK"/{vendor,vendir.lock.yml,vendir.yml,output.yaml,.hash}
cp "$SOURCE_DIR/vendir.yml" "$WORK/"
vendir sync --chdir "$WORK" >&2

if [[ -f "$SOURCE_DIR/kind.yaml" ]]; then
    ./scripts/kind-extract.sh "$SOURCE_DIR" "$WORK" "$OUTPUT_FILE"
else
    # Strip inline helm directives — no standard CRD field contains `{{...}}`.
    find "$WORK/vendor" -name '*.yaml' -exec sd '\{\{[^}]*\}\}' '' {} \;

    files=("$WORK"/vendor/**/*.yaml "$WORK"/vendor/**/*.yml)
    [[ ${#files[@]} -gt 0 ]] || { echo "vendir produced no YAML files for $SOURCE_DIR" >&2; exit 1; }

    yq eval-all 'select(.kind == "CustomResourceDefinition")' "${files[@]}" > "$OUTPUT_FILE"
fi

[[ -s "$OUTPUT_FILE" ]] || { echo "no CRDs extracted from $SOURCE_DIR" >&2; exit 1; }

# Commit cache only on success. Output first, hash second — a crash between
# the two leaves a stale-looking hash that won't falsely match next run.
cp "$OUTPUT_FILE" "$WORK/output.yaml"
echo "$HASH" > "$WORK/.hash"
