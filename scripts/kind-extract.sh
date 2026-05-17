#!/usr/bin/env bash
# Extract CRDs from an operator that registers them at runtime. $WORK/vendor/
# is pre-synced by build.sh — operator/ holds the install manifest, cr/ holds
# the trigger CR. Output is a kubectl List that crd-schema-publisher's
# `convert` ingests as-is.
#
# Usage: kind-extract.sh <source-dir> <work-dir> <output-file>

set -euo pipefail

SOURCE_DIR="${1:?usage: kind-extract.sh <source-dir> <work-dir> <output-file>}"
WORK="${2:?usage: kind-extract.sh <source-dir> <work-dir> <output-file>}"
OUTPUT_FILE="${3:?usage: kind-extract.sh <source-dir> <work-dir> <output-file>}"

# Default Available matches the KubeVirt/CDI contract; sources whose CR
# reports something else (e.g. Ready) override it in extract.yaml.
READY_CONDITION="Available"
if [[ -f "$SOURCE_DIR/extract.yaml" ]]; then
    READY_CONDITION="$(yq '.readyCondition // "Available"' "$SOURCE_DIR/extract.yaml")"
fi

# k8s label rules: alphanumeric + dash, capped at 60 chars.
CLUSTER="k8s-schemas-$(printf %s "${SOURCE_DIR#*/sources/}" | sd '[^a-z0-9]' '-')"
CLUSTER="${CLUSTER:0:60}"
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT

kind create cluster \
    --name "$CLUSTER" \
    --config "$SOURCE_DIR/kind.yaml" \
    --kubeconfig "$WORK/kubeconfig" \
    --wait 120s >&2
export KUBECONFIG="$WORK/kubeconfig"

kubectl apply -f "$WORK/vendor/operator" >&2
kubectl wait --for=condition=Established --all crd --timeout=120s >&2
kubectl wait --for=condition=Available --all deployments --all-namespaces --timeout=120s >&2

# Readiness on the CR is the operator's contract for "every managed CRD is
# now registered" — strict superset of CRD-by-CRD polling.
kubectl apply -f "$WORK/vendor/cr" >&2
kubectl wait --for=condition="$READY_CONDITION" -f "$WORK/vendor/cr" --timeout=300s >&2

kubectl get crd -o yaml > "$OUTPUT_FILE"
[[ -s "$OUTPUT_FILE" ]] || { echo "no CRDs extracted from $SOURCE_DIR" >&2; exit 1; }
