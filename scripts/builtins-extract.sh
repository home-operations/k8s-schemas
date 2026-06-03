#!/usr/bin/env bash
# Boot a throwaway kind cluster at the pinned k8s version and dump its OpenAPI v2
# spec, for crd-schema-publisher's --openapi mode. Mirrors kind-extract.sh, but
# for built-in (non-CRD) types instead of an operator's CRDs.
#
# Usage: builtins-extract.sh <source-dir> <output-file>

set -euo pipefail

SOURCE_DIR="$(cd "${1:?usage: builtins-extract.sh <source-dir> <output-file>}" && pwd)"
OUTPUT_FILE="${2:?usage: builtins-extract.sh <source-dir> <output-file>}"

CLUSTER="k8s-schemas-builtins"
WORK="$(mktemp -d)"
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

kind create cluster \
    --name "$CLUSTER" \
    --config "$SOURCE_DIR/kind.yaml" \
    --kubeconfig "$WORK/kubeconfig" \
    --wait 120s >&2

mkdir -p "$(dirname "$OUTPUT_FILE")"
KUBECONFIG="$WORK/kubeconfig" kubectl get --raw /openapi/v2 > "$OUTPUT_FILE"
[[ -s "$OUTPUT_FILE" ]] || { echo "no OpenAPI spec dumped to $OUTPUT_FILE" >&2; exit 1; }
