# ntfy-image

Thin in-house repackage of the upstream [ntfy](https://github.com/binwiederhier/ntfy)
server binary. Published as `ghcr.io/rake-pro/ntfy`, replacing
`binwiederhier/ntfy` in GitOps (`cluster-apps/ntfy`).

## Why this exists

* Upstream `binwiederhier/ntfy:vX.Y.Z` only gets a new alpine base image when
  upstream cuts a release. Alpine/openssl security fixes in between wait on
  their release cadence.
* This repo builds `alpine:<pinned>` + `apk upgrade --no-cache` + the
  **unmodified upstream release binary** (sha256-verified), so we can rebuild
  on our own schedule (weekly Trivy rescan, Dependabot alpine bumps) without
  waiting on upstream.
* No source build: upstream's own Linux release binaries are already
  statically linked (`CGO_ENABLED=1`, `-extldflags=-static`, for
  `go-sqlite3`), confirmed via `file`/`ldd` against the v2.28.0
  `linux_amd64` tarball - they run unmodified on musl/alpine.

## Version scheme

| | |
|---|---|
| Image tag | Our own plain semver `vX.Y.Z` (fleet standard: no upstream version or build-hash suffix in the tag) |
| Upstream version | Recorded as `ARG NTFY_VERSION` in `Dockerfile`, the `io.rake-pro.upstream-version` OCI label, and the release notes |
| Why not `v2.28.0`-style tags | The owner's semver standard bans build-suffixed tags; an upstream-derived tag would also break the moment we need to rebuild for OUR reasons (e.g. an alpine CVE) without an upstream bump - there'd be no next tag to mint |
| First release | `v1.0.0` = alpine `3.24.2` + ntfy `2.28.0` |

Bumping alpine alone (security rebuild, no upstream change) is a patch.
Bumping the pinned `NTFY_VERSION` is a patch/minor per normal semver judgment
(patch for a routine upstream patch release, minor if upstream ships a new
feature you want to call out) - use the `release:minor` / `release:major` PR
label to override the default patch bump, same as every other Rake-Pro image
repo.

## Repo layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-arch (amd64+arm64) build: fetch + verify upstream binary, apk upgrade, non-root runtime |
| `.github/workflows/ci.yml` | Build-only validation on every `dev` push/PR |
| `.github/workflows/release.yml` | Mints next semver tag on `main` merge, builds + pushes to GHCR, Trivy-gates |
| `.github/workflows/sync-main.yml` | Opens the `dev` -> `main` promotion PR |
| `.github/workflows/trivy-rescan.yml` | Weekly CRITICAL/HIGH rescan of the released image |
| `.github/workflows/check-upstream.yml` | Weekly check for a new upstream ntfy release; opens a tracking issue |
| `.github/dependabot.yml` | Weekly PRs for GitHub Actions + the alpine base tag |

## How to: build locally

```
docker buildx build --platform linux/amd64,linux/arm64 -t ntfy-image:local .
```

Single-arch (native, faster for a quick check):

```
docker build -t ntfy-image:local .
```

## How to: smoke test

```
docker run --rm -p 8080:8080 -e NTFY_LISTEN_HTTP=:8080 ntfy-image:local serve &
curl -s http://localhost:8080/v1/health
# {"healthy":true}
```

## How to: bump the upstream ntfy version

1. Check the new release: `gh release view vX.Y.Z --repo binwiederhier/ntfy`
2. Download its `checksums.txt` and pull the two lines for
   `ntfy_X.Y.Z_linux_amd64.tar.gz` and `ntfy_X.Y.Z_linux_arm64.tar.gz`.
3. In `Dockerfile`, update:
   * `ARG NTFY_VERSION=X.Y.Z`
   * `ARG NTFY_SHA256_AMD64=<from checksums.txt>`
   * `ARG NTFY_SHA256_ARM64=<from checksums.txt>`
4. Build locally (above) to confirm the checksum verification passes and
   `/v1/health` responds.
5. Open a PR into `dev`. `check-upstream.yml` opens a tracking issue
   automatically when it notices upstream is ahead - this is the same
   procedure that issue asks for.

## How to: release

1. Merge a promotion PR (`dev` -> `main`, opened automatically by
   `sync-main.yml`). Label it `release:minor` or `release:major` beforehand to
   override the default patch bump.
2. `release.yml` mints the next `vX.Y.Z` tag, builds+pushes
   `ghcr.io/rake-pro/ntfy:X.Y.Z` (+ `X.Y` + `latest` + `sha-<short>`) for
   `linux/amd64,linux/arm64`, then Trivy-gates on CRITICAL.
3. Bump `cluster-apps/ntfy/values.yaml` (`image.repository` /
   `image.tag`) in GitOps to the new tag and merge/sync.

## How to: roll back

* GitOps side: pin `cluster-apps/ntfy/values.yaml` `image.tag` back to the
  previous `vX.Y.Z` (or to the last `binwiederhier/ntfy` tag + repository, if
  rolling all the way back off this image) and sync.
* Image side: no image deletion needed - GHCR keeps every pushed tag. A
  broken release just gets superseded by the next patch tag.

## Deploying (GitOps side)

`cluster-apps/ntfy/values.yaml` needs:

```yaml
image:
  repository: ghcr.io/rake-pro/ntfy
  tag: "1.0.0"

imagePullSecrets:
  - name: ghcr-ntfy
```

plus a `templates/ghcr-pull-secret.yaml` `ExternalSecret` (copy the pattern
from `cluster-apps/gopaste/templates/ghcr-pull-secret.yaml` - same shared GSM
key `ghcr-rakepro`, just renamed to `ghcr-ntfy`), since this is a private GHCR
package like the rest of the fleet's `ghcr.io/rake-pro/*` images.

This image runs as uid 1000 (`restricted`-profile compatible), unlike the
current `binwiederhier/ntfy` deployment which renders `securityProfile: root`.
Switching over should also flip `securityProfile` to `restricted` (or set an
explicit `podSecurityContext.fsGroup: 1000` so the PVC-mounted
`/var/lib/ntfy` is writable by uid 1000) - not required for the image to run,
but leaving `root` after switching to a non-root image gets no benefit from
the hardening.

## What is NOT done here

* Not pushed to GitHub, not built as a real multi-arch OCI image, no Trivy
  image scan (this container has no `docker`/`podman`/`buildah`; only a
  `trivy` binary). See the session report for exactly what was verified
  instead (checksum, static-binary check, binary smoke test via `ntfy serve`
  run directly).
* GitOps `cluster-apps/ntfy/values.yaml` change is drafted on a scratch clone,
  committed locally only - not pushed, not synced.
