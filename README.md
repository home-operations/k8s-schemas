# k8s-schemas

JSON schemas for the Kubernetes CRDs used across the home-operations ecosystem.
Point a YAML editor at these schemas and your cluster manifests get
autocomplete, hover documentation, and validation against the real upstream
API.

The rendered site is at
[`home-operations.github.io/k8s-schemas`](https://home-operations.github.io/k8s-schemas/),
and the same content is mirrored as a cosign-signed OCI artifact at
`ghcr.io/home-operations/k8s-schemas:latest`.

## How it works

Each upstream project gets a small `vendir.yaml` under `sources/`. The build
fetches that upstream's CRDs at the pinned version, keeps only the
`CustomResourceDefinition` documents, and hands the whole set to
[`crd-schema-publisher`](https://github.com/sholdee/crd-schema-publisher),
which renders a single searchable docs site.

The site is published to GitHub Pages and the same payload is pushed as a
OCI artifact, signed with cosign. Renovate watches every source file natively
and opens a PR when an upstream cuts a release.

## Using the schemas

### In your editor

Browse the [site](https://home-operations.github.io/k8s-schemas/), find the
kind you want, and copy its schema URL into a magic comment at the top of
your manifest:

```yaml
# yaml-language-server: $schema=https://home-operations.github.io/k8s-schemas/cert-manager.io/certificate_v1.json
apiVersion: cert-manager.io/v1
kind: Certificate
# ...
```

The [Red Hat YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml)
for VS Code and most other YAML language-server integrations honor this
comment.

### As a Flux source

If you want the schemas inside the cluster (offline mirror, fleet-wide schema
serving, etc.):

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: k8s-schemas
  namespace: flux-system
spec:
  interval: 24h
  url: oci://ghcr.io/home-operations/k8s-schemas
  ref:
    tag: latest
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/home-operations/k8s-schemas.*$
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

   Anything more involved (rendering a helm chart, mirroring an upstream
   that doesn't publish anything usable) is out of scope here — open an
   issue and we'll talk about it.

3. **Create `sources/<name>/vendir.yaml`.** One of these two shapes:

   GitHub release asset:

   ```yaml
   ---
   apiVersion: vendir.k14s.io/v1alpha1
   kind: Config
   directories:
     - path: vendor
       contents:
         - path: <name>
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
         - path: <name>
           git:
             url: https://github.com/<owner>/<repo>
             ref: <upstream-tag>
             includePaths:
               - config/crd/bases/*.yaml
   ```

4. **Test locally.**

   ```sh
   mise install
   mise run all
   ```

   This builds every source and renders the merged site at `./site/`. Open
   `site/index.html` to spot-check your new entry shows up under the right
   API group.

5. **Open a pull request.** The PR workflow builds only the sources you
   touched. On merge to `main`, the release workflow rebuilds everything,
   redeploys the Pages site, and pushes a new OCI artifact.

## Maintaining a fork

This repository follows the home-operations conventions for CI and Renovate.
If you fork it:

1. **Set up a Renovate GitHub App** following the instructions
   [here](https://github.com/renovatebot/github-action). Store the
   credentials as repository secrets named `BOT_APP_ID` and
   `BOT_APP_PRIVATE_KEY`.

2. **Enable GitHub Pages** with **Source: GitHub Actions** in the
   repository settings.

3. **Use lowercase names.** GHCR requires the owner and repository name to
   be entirely lowercase.
