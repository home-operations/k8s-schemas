# 🚀 k8s-schemas

> ✨ **Renovate-tracked, automatically published JSON schemas for Kubernetes CRDs.** Powered by [`vendir`](https://carvel.dev/vendir/) and [`crd-schema-publisher`](https://github.com/sholdee/crd-schema-publisher).

📡 **Published to**: GitHub Pages • `oci://ghcr.io/<owner>/<repo>:latest` (Flux-pushed artifact, cosign-signed via OIDC keyless)

## ⭐ Highlights

- 📦 **Declarative sources** — one `vendir.yaml` per upstream
- 🤖 **Fully Renovate-native** — zero custom regex managers
- 🛠️ **Minimal toolchain** — pinned via [`mise`](https://mise.jdx.dev/)
- ⚡ **Parallel matrix builds** → single merged GitHub Pages deploy
- 🎯 **Universal coverage** — git refs, GitHub release assets, helm charts

## 📂 Layout

```
sources/<name>/vendir.yaml   # 📥 what to fetch
scripts/build.sh             # 🔧 extract CRDs from one source
.mise.toml                   # 📌 pinned tools + task runner
.renovaterc.json5            # 🤖 Renovate config
```

## 🎯 Source priority

Pick **in order** when adding a new source:

| # | Type | When |
|---|---|---|
| 1️⃣ | `githubRelease` ✅ | Upstream ships a CRDs YAML release asset |
| 2️⃣ | `git` ✅ | Upstream ships raw CRDs in-tree (use `includePaths`) |
| 3️⃣ | `helmChart` ⚠️ | Last resort — re-adds `helm` to the toolchain |

## 🏃 Local development

```sh
mise install                                                # 📥 install pinned tools
mise run build sources/cert-manager build/cert-manager.yaml # 🔧 extract one source
mise run publish build site                                 # 🎨 render merged site
mise run all                                                # 🚀 do it all
```

## 🚦 CI

| Workflow | Trigger | Purpose |
|---|---|---|
| `release.yaml` | push to `main` | 🚀 Build all → render → deploy Pages + push OCI artifact |
| `pull-request.yaml` | PR / merge group | ✅ Build only changed sources |
| `renovate.yaml` | config touched | 🤖 Dispatches central Renovate workflow via bot |

> 📌 All actions pinned to commit SHA with semver in a trailing comment. Renovate's `github-actions` manager handles bumps natively.

## 🔐 Required repo settings

- **Pages**: source = `GitHub Actions`
- **Secrets**: `BOT_APP_ID`, `BOT_APP_PRIVATE_KEY`
