# ADR-0001 — Well-Known Metadata Catalog

- **Status:** Proposed
- **Date:** 2026-07-21
- **Deciders:** k8s-schemas maintainers
- **Scope:** a curated, machine-readable catalog of well-known metadata keys
  (annotations, labels, taints) with value rules, compiled into this repo's
  published JSON schemas

> **Open-world principle.** Rules only ever tighten keys inside explicitly
> claimed prefixes; arbitrary user keys always pass. Sites never require keys
> to be known. Every tightening mechanism ships per-prefix, behind a fixture
> gate, never globally.

## Context

Kubernetes controllers define behavior through magic annotations, labels, and
taints whose keys and values have no machine-readable schema anywhere — they
exist only as Go constants and prose docs. Schema validators treat
`metadata.annotations` as an unconstrained `map[string]string`, so typos pass
every check and fail silently at runtime. Motivating incident:
`kustomize.toolkit.fluxcd.io/force: "true"` on a Job — Flux only recognizes
`enabled`/`disabled`. Schema-valid, silently broken.

No existing tool or catalog covers this class. The July 2026 Flux Schema /
Ecosystem Schema Catalog launch (the closest neighbor, ~100 projects) does
strict field validation and spec-level CEL with API-server semantics, but its
only metadata checking is syntactic (DNS-1123, qualified names) — verified
against `fluxcd/flux-schema` source and docs. The kubernetes.io "Well-Known
Labels, Annotations and Taints" page is prose.

This repo owns the delivery channel:

- **yayamlls** — home-operations' language server — defaults its Kubernetes
  schema URL to this site (`internal/schema/k8s.go`). Patching the published
  schemas upgrades every yayamlls user with zero configuration.
- **flux-schema**'s default schema-location template
  (`{{.Group}}/{{.Kind}}_{{.Version}}.json`, core → `core/`) matches this
  site's layout byte-for-byte; `--schema-location
https://k8s-schemas.home-operations.com` works today with no glue.
- **kubeconform** consumes the same layout via `-schema-location`.

The ecosystem catalog commoditizes plain schema hosting; metadata strictness
is what this site can have that nobody else does.

## Decision

### 1. Catalog format

One `annotations.yaml` per source, colocated with that source's `vendir.yml`
under `sources/<owner>/<repo>/` (upstream version bumps and rule review share
a PR); `native/annotations.yaml` for kubernetes.io keys and core-kind sites.
All files validate against a root-level `annotations.schema.json` meta-schema.

Each file declares:

- `prefixes` — DNS-suffix ownership claims, each independently
  `closed: true|false`. Claims may nest; **longest match wins**, so a broad
  closed claim can carry open carve-outs. Claim breadth reflects the author's
  confidence in having enumerated everything; when unsure, narrow the claim.
- `rules` — `keys` + `on: annotations|labels|taints`, then only what's
  needed: `match` (Role-style apiGroups/resources scoping, resolved at
  compile time), `values` (enum), `pattern`, `format`, `requires` (cross-key
  presence dependency), `description` (hover/docs text), `warn`.
- `sites` — explicit entries for places where specs embed metadata keys:
  `resources`/`path`/`shape: labelMap|labelKey|requirements|taint`/`target`
  (which kind's rule set applies). No auto-detection; each embed spot is a
  catalog entry.

```yaml
# sources/controlplaneio-fluxcd/flux-operator/annotations.yaml
owner: fluxcd
docs: https://fluxcd.io/flux/
prefixes:
  - { domain: fluxcd.io, closed: true }
  - { domain: event.toolkit.fluxcd.io, closed: false } # user-defined event metadata
rules:
  - keys: [kustomize.toolkit.fluxcd.io/force, kustomize.toolkit.fluxcd.io/prune]
    on: annotations
    values: [enabled, disabled]
    description: Per-resource override for the Kustomization's force/prune behavior.
  - keys: [kustomize.toolkit.fluxcd.io/name, kustomize.toolkit.fluxcd.io/namespace]
    on: labels
    warn: written by kustomize-controller; hand-set values are overwritten
```

Not in v1: `validations` (CEL) — see §4. Parsing structured values beyond
"it parses", cross-resource referential integrity, and anything requiring
object context remain out of scope.

### 2. Compilation: the merge tool

A small Go tool in this repo (mise-managed), inserted between
`crd-schema-publisher convert` and `render` (render-as-a-standalone-command is
[sholdee/crd-schema-publisher#211], the only upstream dependency). Rendering
after merging means docs/search/hover reflect the rules.

**Uniform merge mechanism.** At every attachment point the tool appends one
self-contained `allOf` branch carrying a `$comment: k8s-schemas
metadata-catalog` marker. It never mutates existing subtrees — no
keyword-collision logic, no dependence on upstream schema shape, and the patch
is identifiable and strippable. Use-site overlay is mandatory, not stylistic:
native files share one inlined `ObjectMeta` definition between the resource's
own `metadata` and its pod template's, so patching the definition would bleed
scoped rules across contexts (verified in `apps/deployment_v1.json`).

**Placement rules:**

- Known keys compile to plain `properties` entries (with `description`) —
  this drives completion and hover. Conditionals are confined to
  validation-only positions: yayamlls' completion walker merges
  `$ref`/`allOf`/`anyOf`/`oneOf` but not `if/then` branches (verified in
  `internal/schema/walk.go`), and no LS completes from `propertyNames`.
- Closed prefixes compile to `propertyNames` + `if/then` with RE2-safe
  pattern alternation (no negative lookahead; nested open claims become
  explicit alternation carve-outs). Verified end-to-end in kubeconform:
  the check names the offending key in its error.
- `match` scoping is resolved at compile time by stamping different content
  into different kinds' schemas — no runtime conditionals.
- Pod-scoped rules and Pod-targeted sites are stamped into a fixed built-in
  list of native workload template paths (Deployment, StatefulSet, DaemonSet,
  ReplicaSet, Job, CronJob's `jobTemplate`). CRDs embedding pod templates get
  coverage via explicit `sites` entries, not detection.
- `warn` rules contribute **zero standard constraints**. The payload lives
  under a single `x-warn` extension (values + message) that only yayamlls
  evaluates (at Warning severity — requires a small yayamlls feature);
  every other validator sees a permissive string with hover text. Warnings
  that cannot break anyone's CI.

**Site shapes, all four in v1:**

- `labelMap` — reuses the metadata-labels generator verbatim.
- `labelKey` — known keys go in `examples` (editor suggestions with zero
  constraint; open world by construction).
- `requirements` — two layers: fixed generic operator conditionals
  (`Exists`/`DoesNotExist` → empty `values`, `In`/`NotIn` → non-empty,
  `Gt`/`Lt` → single numeric), written once; plus generated per-key value
  conditionals, only for rules that carry `values`/`pattern` (bounds schema
  bloat — most node labels are unenumerable and contribute nothing here).
- `taint` — same generator plus the `effect` enum, which the upstream
  swagger only describes in prose.

**Dialect re-declaration.** Published native files explicitly declare
draft-04 (`extractor/openapi.go` in crd-schema-publisher), under which
`propertyNames`/`if/then` do not exist — a conforming validator is required
to ignore them (verified: kubeconform silently passes a typo'd key until the
file declares 2020-12). CRD-derived files declare nothing. The merge tool
therefore re-declares `$schema: 2020-12` on every file it patches. That
re-declaration is made honest by construction: upstream's declaration is
truthful for the content upstream produces; whoever transforms the content
owns the new declaration. Concretely, per patched file:

- normalize draft-04-only forms (boolean `exclusiveMinimum`/`Maximum` →
  numeric; probed across representative published schemas: zero occurrences
  in practice);
- compile under strict 2020-12 (santhosh-tekuri) in CI — validity failures
  are loud, not silent semantic shifts;
- audit the two known same-bytes-different-meaning deltas: `$ref` siblings
  must be annotation-only (2020-12 activates constraint siblings draft-04
  ignored), and `format` becomes annotation-only (note the potential
  relaxation; kubernetes formats are largely nonstandard anyway).

**Gate:** stamping CRD-derived files waits for a flux-schema release
containing [fluxcd/flux-schema#78]. Verified: `$schema` on a CRD-derived file
currently breaks flux-schema's structural conversion, killing that kind's
(working!) upstream CEL evaluation and failing valid manifests. Native files
are safe to stamp immediately — they carry no CEL, so structural conversion
never runs on them.

### 3. Rollout and maintenance policy

- **Value rules ship first; closed prefixes second.** The motivating
  incident is caught by a plain enum. Closed-prefix enforcement flips on
  per-prefix, each behind passing fixtures, because a wrong closed claim
  reaches every yayamlls user's editor and every kubeconform consumer's CI.
- **Conservative claims.** `kubernetes.io` apex stays open; confidently
  enumerable subdomains (`pod-security.kubernetes.io`,
  `topology.kubernetes.io`, `node-restriction.kubernetes.io`) may close.
  `fluxcd.io` closes with the `event.toolkit.fluxcd.io` carve-out, on the
  strength of a completeness inventory against controller Go constants.
- **Closed claims are a maintenance SLA, and automerge must respect it.**
  Sources carrying closed claims are excluded from blind Renovate automerge.
  A deterministic audit script — clone the upstream at the vendir-pinned tag,
  grep API packages for domain-bearing key constants, diff against the
  catalog — gates the merge: empty diff (the overwhelming majority of bumps)
  automerges untouched; non-empty diff blocks and hands the diff to review
  (Claude-assisted, per the established renovate-review pattern). The same
  script is the seed-inventory tool and the scheduled drift audit.

### 4. CEL: rejected in `x-kubernetes-validations` form

Two independent, verified reasons:

1. **The kube-flavored environment cannot express metadata rules — ever.**
   The apiserver CEL env restricts `self.metadata` to `name`/`generateName`
   (compile error: `undefined field 'annotations'`) and the evaluator never
   walks metadata subtrees. This is an ownership boundary, not a gap: type
   schemas cannot police the shared metadata namespace that the system and
   arbitrary controllers mutate on every write. Kubernetes' sanctioned home
   for metadata CEL is ValidatingAdmissionPolicy. Treat the restriction as
   permanent.
2. **Naive embedding is harmful, not inert.** When any
   `x-kubernetes-validations` is present, flux-schema converts the whole file
   to a structural schema; on native-format files (`$schema`, `definitions`,
   `$ref`) the conversion fails and surfaces as errors on _valid_ manifests.

Meanwhile, spec-level CEL from this site's CRD-derived schemas already works:
flux-schema evaluates Gateway API's upstream rules from the live site with
correct messages and paths (verified with an HTTPRoute timeout-rule
violation). The converter passes upstream rules through; nothing here should
disturb that.

The replacement ladder, each rung gated on a real seed rule needing it:

1. **Standard keywords** for cross-key rules — `requires` compiles to
   `dependentRequired`; value correlations to `if/then` + `const` within the
   annotations map. Covers the realistic rule set; works in every consumer.
2. **`x-` extension evaluated by yayamlls** (cel-go, `self` bound at the
   node, plain env) if editor-time runtime semantics ever prove necessary;
   inert everywhere else by construction. Pitchable to flux-schema second,
   with yayamlls as the reference implementation.
3. **A ValidatingAdmissionPolicy bundle as a separate compile target** —
   the kube-sanctioned home for true metadata CEL. `match` maps to
   `matchConstraints`, `warn` to `validationActions: [Warn]`; consumers exist
   today (the apiserver in-cluster; kyverno CLI offline in CI). Deliberately
   future work: a cluster-wide policy bundle is a more opinionated artifact
   than opt-in schemas, and machine-written-key rules would fire on
   controllers' own writes without `request.userInfo` conditions.

### 5. CI and verification

- Catalog files validate against the meta-schema on every PR.
- A fixture harness runs the real consumers — kubeconform, flux-schema,
  yayamlls — against patched schemas with pass/fail manifest pairs, per
  mechanism and per site shape. **No mechanism ships without a failing
  fixture.** This is a hard rule with receipts: the first fixture run caught
  two silent-failure modes (kubeconform spec-ignoring conditionals under the
  wrong dialect; flux-schema structural breakage on stamped files) and
  falsified a headline feature (metadata CEL) in an afternoon.
- Every patched file compiles under strict 2020-12 (see §2).
- The PR workflow gains a catalog job triggered by `annotations.yaml` files,
  the meta-schema, the merge tool, and fixture paths.

## Consequences

- Editors get completion/hover/squiggles for well-known keys with zero user
  action (yayamlls defaults to this site); CI consumers get the checks at the
  URLs they already use. The site gains the capability no other schema
  catalog has.
- Published schemas deliberately diverge from "faithful conversion": patched
  files re-declare their dialect and carry catalog `allOf` branches. The
  `$comment` marker keeps the divergence identifiable.
- The repo gains a Go toolchain (merge tool + tests) alongside its
  bash/yaml/vendir character, and closed claims introduce a standing
  maintenance obligation, mitigated by the audit-gated automerge.
- Companion work lands in yayamlls: `x-warn` evaluation and a `propertyNames`
  case in diagnostic anchoring (point at the offending key).
- Full ObjectMeta grafting into CRD-derived schemas is explicitly **not**
  part of this decision — it's separable, and best pursued upstream where it
  benefits every consumer.

## Sequencing

1. [sholdee/crd-schema-publisher#211] (standalone render) — open, ours.
2. [fluxcd/flux-schema#78] ($schema tolerance) — open, ours; gates CRD-file
   dialect stamping only, nothing else.
3. Seed inventories: Flux controllers (ground truth: Go constants in each
   controller's API package; completeness is the bar a closed claim must
   meet) and the curated kubernetes.io set. Written as reusable scripts —
   they become the automerge gate and drift audit.
4. PR: meta-schema, two seed catalog files, merge tool, one workflow step,
   fixtures.

[sholdee/crd-schema-publisher#211]: https://github.com/sholdee/crd-schema-publisher/pull/211
[fluxcd/flux-schema#78]: https://github.com/fluxcd/flux-schema/pull/78
