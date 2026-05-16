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

### As a git hook

This repo also ships [`hooks/k8s-yaml-schema`](hooks/k8s-yaml-schema) — a
small bash script that walks your YAML files, derives the right schema URL
from each document's `apiVersion`/`kind`, and inserts or updates the
`# yaml-language-server: $schema=...` directive in place. Dependencies are
`bash`, `yq` (mikefarah), `jq`, and `awk` — most repos already pull these
in via mise/aqua.

Copy [`.k8s-schema-hook.example.yaml`](.k8s-schema-hook.example.yaml) to
your repo as `.k8s-schema-hook.yaml`, point `domain:` at your published
site, vendor the script (one curl is enough), and wire it into
[lefthook](https://lefthook.dev):

```toml
# .lefthook.toml
[pre-commit.commands.k8s-yaml-schema]
glob = ["kubernetes/**/*.yaml", "kubernetes/**/*.yml"]
run = "hooks/k8s-yaml-schema --config .k8s-schema-hook.yaml {staged_files}"
stage_fixed = true
```

```sh
curl -sLO https://raw.githubusercontent.com/home-operations/k8s-schemas/main/hooks/k8s-yaml-schema
chmod +x k8s-yaml-schema && mv k8s-yaml-schema hooks/
```

Overrides match on `kind`, `apiGroup`, or a HelmRelease's `chartRef` OCI
URL (resolved against a sidecar `ocirepository.yaml`). See the example
config.

## Extras

A small `extras/` tree lets the same pipeline publish hand-curated JSON
schemas that aren't CRDs (e.g. the bjw-s app-template HelmRelease schema).
Each source uses the same `vendir.yml` shape as the CRD sources but the
build copies the selected files verbatim into `out/site/extras/<owner>/<name>/`.
Use this for narrow, schema-shaped artifacts only — anything that needs
rendering or transformation belongs upstream.

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

4. **Enable auto-merge** under repo Settings → General, then add a branch
   protection rule on `main` requiring the `Build Success` status check.
   Renovate's package rule already sets `automerge: true` for vendir updates,
   so once `Build Success` is required, version bumps will land
   automatically when CI passes.
