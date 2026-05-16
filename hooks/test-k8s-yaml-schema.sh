#!/usr/bin/env bash
# Smoke tests for hooks/k8s-yaml-schema. Run from the repo root: `bash hooks/test-k8s-yaml-schema.sh`.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/k8s-yaml-schema"
PASS=0
FAIL=0

run() {
  local name=$1; shift
  if "$@"; then
    PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$name"
  else
    FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$name"
  fi
}

# --- fixtures ----------------------------------------------------------------
# Each test runs in its own tmp dir so we can rebuild fixtures cheaply.
new_workdir() {
  local d; d=$(mktemp -d)
  cat > "$d/.k8s-schema-hook.yaml" <<'YAML'
domain: schemas.example.com
overrides:
  - name: kustomize
    match:
      apiGroup: kustomize.config.k8s.io
    schema: https://json.schemastore.org/kustomization
  - name: helmrelease-app-template
    match:
      kind: HelmRelease
      chartRefOciUrl: oci://ghcr.io/bjw-s-labs/helm/app-template
    schema: https://{domain}/extras/bjw-s-labs/app-template/helmrelease-helm-v2.schema.json
YAML
  printf '%s' "$d"
}

# --- tests -------------------------------------------------------------------

test_inserts_directive_for_crd() {
  local d; d=$(new_workdir)
  cat > "$d/cert.yaml" <<'YAML'
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: foo
YAML
  ( cd "$d" && "$HOOK" cert.yaml ) >/dev/null 2>&1
  local rc=$?
  [[ $rc -eq 1 ]] || { echo "expected rc=1 (modified), got $rc"; return 1; }
  grep -qx '# yaml-language-server: $schema=https://schemas.example.com/cert-manager.io/certificate_v1.json' "$d/cert.yaml" \
    || { echo "directive missing or wrong:"; cat "$d/cert.yaml"; return 1; }
}

test_idempotent_on_second_run() {
  local d; d=$(new_workdir)
  cat > "$d/cert.yaml" <<'YAML'
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: foo
YAML
  ( cd "$d" && "$HOOK" cert.yaml ) >/dev/null 2>&1 || true
  set +e
  ( cd "$d" && "$HOOK" cert.yaml ) >/dev/null 2>&1
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || { echo "expected rc=0 on second run, got $rc"; return 1; }
}

test_applies_kustomize_override() {
  local d; d=$(new_workdir)
  cat > "$d/kustomization.yaml" <<'YAML'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML
  ( cd "$d" && "$HOOK" kustomization.yaml ) >/dev/null 2>&1 || true
  grep -qx '# yaml-language-server: $schema=https://json.schemastore.org/kustomization' "$d/kustomization.yaml" \
    || { echo "override not applied:"; cat "$d/kustomization.yaml"; return 1; }
}

test_skips_core_by_default() {
  local d; d=$(new_workdir)
  cat > "$d/cm.yaml" <<'YAML'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: foo
data: {}
YAML
  ( cd "$d" && "$HOOK" cm.yaml ) >/dev/null 2>&1
  local rc=$?
  [[ $rc -eq 0 ]] || { echo "expected rc=0 for core resource, got $rc"; return 1; }
  ! grep -q 'yaml-language-server' "$d/cm.yaml" || { echo "directive unexpectedly inserted:"; cat "$d/cm.yaml"; return 1; }
}

test_chart_ref_oci_url_override() {
  local d; d=$(new_workdir)
  cat > "$d/ocirepository.yaml" <<'YAML'
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: app-template
spec:
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
YAML
  cat > "$d/helmrelease.yaml" <<'YAML'
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: foo
spec:
  chartRef:
    kind: OCIRepository
    name: app-template
  interval: 1h
YAML
  ( cd "$d" && "$HOOK" helmrelease.yaml ) >/dev/null 2>&1 || true
  grep -qx '# yaml-language-server: $schema=https://schemas.example.com/extras/bjw-s-labs/app-template/helmrelease-helm-v2.schema.json' "$d/helmrelease.yaml" \
    || { echo "chartRefOciUrl override not applied:"; cat "$d/helmrelease.yaml"; return 1; }
}

test_missing_domain_returns_error() {
  local d; d=$(mktemp -d)
  echo "overrides: []" > "$d/.k8s-schema-hook.yaml"
  cat > "$d/cert.yaml" <<'YAML'
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: foo
YAML
  set +e
  ( cd "$d" && "$HOOK" cert.yaml ) >/dev/null 2>&1
  local rc=$?
  set -e
  [[ $rc -eq 2 ]] || { echo "expected rc=2 on missing domain, got $rc"; return 1; }
}

test_multi_doc_file() {
  local d; d=$(new_workdir)
  cat > "$d/mixed.yaml" <<'YAML'
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: a
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML
  ( cd "$d" && "$HOOK" mixed.yaml ) >/dev/null 2>&1 || true
  grep -qF '$schema=https://schemas.example.com/cert-manager.io/certificate_v1.json' "$d/mixed.yaml" \
    || { echo "first-doc directive missing"; cat "$d/mixed.yaml"; return 1; }
  grep -qF '$schema=https://json.schemastore.org/kustomization' "$d/mixed.yaml" \
    || { echo "second-doc directive missing"; cat "$d/mixed.yaml"; return 1; }
}

# --- run ---------------------------------------------------------------------
echo "hooks/k8s-yaml-schema smoke tests"
run "inserts directive for CRD resource"        test_inserts_directive_for_crd
run "idempotent on second run"                  test_idempotent_on_second_run
run "applies kustomize override"                test_applies_kustomize_override
run "skips core resources by default"           test_skips_core_by_default
run "chartRefOciUrl override looks up sidecar"  test_chart_ref_oci_url_override
run "missing domain returns error"              test_missing_domain_returns_error
run "multi-doc file processes each doc"         test_multi_doc_file
echo
echo "passed: $PASS  failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
