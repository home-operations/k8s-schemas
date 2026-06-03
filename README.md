# k8s-schemas

JSON schemas for the Kubernetes CRDs used across the home-operations ecosystem.
Point a YAML editor at these schemas and your cluster manifests get
autocomplete, hover documentation, and validation against the real upstream
API.

The rendered site is at
[`k8s-schemas.home-operations.com`](https://k8s-schemas.home-operations.com),
and the same content is mirrored as a cosign-signed OCI artifact at
`ghcr.io/home-operations/k8s-schemas:latest`.

## How it works

Each upstream project gets a small `vendir.yml` under `sources/`. The build
fetches that upstream's CRDs at the pinned version, keeps only the
`CustomResourceDefinition` documents, and hands the whole set to
[`crd-schema-publisher`](https://github.com/sholdee/crd-schema-publisher),
which renders a single searchable docs site.

A handful of operators (KubeVirt, CDI, …) only register their CRDs at install
time rather than shipping them as static YAML. Those sources add a `kind.yaml`
alongside the `vendir.yml`; the build spins up a throwaway
[kind](https://kind.sigs.k8s.io/) cluster, lets the operator reconcile, and
dumps the registered CRDs.

The site is published to GitHub Pages and the same payload is pushed as a
OCI artifact, signed with cosign. Renovate watches every source file natively
and opens a PR when an upstream cuts a release.

## Using the schemas

### In your editor

Browse the [site](https://k8s-schemas.home-operations.com), find the
kind you want, and copy its schema URL into a magic comment at the top of
your manifest:

```yaml
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/cert-manager.io/certificate_v1.json
apiVersion: cert-manager.io/v1
kind: Certificate
# ...
```

The [Red Hat YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml)
for VS Code and most other YAML language-server integrations honor this
comment.

### Native Kubernetes types

Schemas for the built-in API types (Pod, Deployment, Service, …) come from a
throwaway [kind](https://kind.sigs.k8s.io/) cluster's OpenAPI spec, which
`crd-schema-publisher`'s `--openapi` mode renders into the same site, naming, and
search index as the CRDs — so they're indistinguishable from any other kind:

```yaml
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/apps/deployment_v1.json
apiVersion: apps/v1
kind: Deployment
# ...
```

Core-group kinds live under `core/` (e.g. `core/pod_v1.json`). The k8s version
follows kind's default node image, set by the `kind` tool version (bumped by Renovate).

### Kustomize

`crd-schema-publisher`'s `--kustomize` mode publishes a schema for kustomize's
client-side `Kustomization` type, reflected from the `sigs.k8s.io/kustomize/api`
Go types in the binary (no CRD, no cluster). The schema follows the pinned
`crd-schema-publisher` version, bumped by Renovate.

```yaml
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# ...
```

## Contributing

To add a new upstream CRD source:

1. **Check what the upstream publishes.**

    ```sh
    gh release view --repo <owner>/<repo>
    ```

    Look for a CRDs-only YAML in the release assets (`*-crds.yaml`,
    `install.yaml`, `bundle.yaml`, etc.). If there isn't one, the next-best
    option is a stable path of CRD YAMLs in the source tree
    (`config/crd/bases/`, `pkg/.../crds/`, etc.).

2. **Pick the source type**, in this order:
    - `githubRelease` — upstream publishes a CRDs YAML as a release asset.
      This is the cleanest path because we just grab a pre-rendered file.
    - `git` — upstream ships raw CRD YAMLs in their tree at a tag we can
      pin. We sparse-check-out only the listed paths.
    - `kind` — upstream is an operator that registers its CRDs at runtime,
      not as static YAML. See [Operator-runtime sources](#operator-runtime-sources)
      below.

    Rendering a helm chart is intentionally out of scope — open an issue if
    you hit a chart whose CRDs only materialize via `helm template --set ...`
    (values-dependent generation, not just inert `{{ }}` decoration).

3. **Create `sources/<owner>/<repo>/vendir.yml`.** Folders are nested by
   GitHub owner so two upstreams can never collide. Use one of these two
   shapes (the body is identical except for the upstream block):

    GitHub release asset:

    ```yaml
    ---
    apiVersion: vendir.k14s.io/v1alpha1
    kind: Config
    directories:
        - path: vendor
          contents:
              - path: .
                githubRelease:
                    slug: <owner>/<repo>
                    tag: <upstream-version>
                    assetNames:
                        - <crds-asset-filename>
                    disableAutoChecksumValidation: true
    ```

    Git tree:

    ```yaml
    ---
    apiVersion: vendir.k14s.io/v1alpha1
    kind: Config
    directories:
        - path: vendor
          contents:
              - path: .
                git:
                    url: https://github.com/<owner>/<repo>
                    ref: <upstream-tag>
                    skipInitSubmodules: true
                    includePaths:
                        - config/crd/bases/*.yaml
    ```

4. **Test locally.**

    ```sh
    mise install
    mise run all
    ```

    This builds every source and renders the merged site at `./out/site/`.
    Open `out/site/index.html` to spot-check your new entry shows up under
    the right API group. Per-source intermediate YAMLs land in `out/crds/`
    if you need to inspect them.

5. **Open a pull request.** The PR workflow builds only the sources you
   touched. On merge to `main`, the release workflow rebuilds everything,
   redeploys the Pages site, and pushes a new OCI artifact.

### Operator-runtime sources

For an operator whose CRDs only exist after the operator reconciles a CR (the
KubeVirt and CDI pattern), the source directory holds two files instead of
one — the upstream-published install manifest and trigger CR are both fetched
by `vendir`:

```sh
sources/<owner>/<repo>/
├── vendir.yml     # fetches install manifest into vendor/operator/ and
│                  # the trigger CR (e.g. kubevirt-cr.yaml) into vendor/cr/
├── kind.yaml      # kind.x-k8s.io/v1alpha4 Cluster spec — a minimal stub
│                  # is usually fine; pin a node image, enable a feature
│                  # gate, etc. only if the operator needs it.
└── extract.yaml   # optional; override the default `Available` readiness
                   # condition (e.g. `readyCondition: Ready`).
```

The build runs both YAMLs through a throwaway kind cluster: apply the
operator, wait for it to come up, apply the CR, wait for the readiness
condition, then `kubectl get crd -o yaml`. Renovate bumps both the install
manifest and the CR together since they share a release tag.

See `sources/kubevirt/kubevirt/` for the canonical shape and
`sources/controlplaneio-fluxcd/flux-operator/` for the inline-vendir trigger
CR and `extract.yaml` override.
