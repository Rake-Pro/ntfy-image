# ntfy-image

Thin in-house repackage of the upstream [ntfy](https://github.com/binwiederhier/ntfy)
server binary. Published as `ghcr.io/rake-pro/ntfy`, a drop-in replacement for
`binwiederhier/ntfy`.

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
  `linux_amd64` tarball: they run unmodified on musl/alpine.

## Version scheme

| | |
|---|---|
| Image tag | Our own plain semver `X.Y.Z` (fleet standard: no upstream version or build-hash suffix in the tag). The git release tag carries a `v` prefix (`vX.Y.Z`); the published Docker tag drops it. |
| Upstream version | Recorded as `ARG NTFY_VERSION` in `Dockerfile`, the `io.rake-pro.upstream-version` OCI label, and the release notes |
| Why not `v2.28.0`-style tags | The owner's semver standard bans build-suffixed tags; an upstream-derived tag would also break the moment we need to rebuild for OUR reasons (e.g. an alpine CVE) without an upstream bump, since there would be no next tag to mint |
| First release | git tag `v1.0.0` -> image tags `1.0.0` / `1.0` / `latest` = alpine `3.24.2` + ntfy `2.28.0` |

Bumping alpine alone (security rebuild, no upstream change) is a patch.
Bumping the pinned `NTFY_VERSION` is a patch/minor per normal semver judgment
(patch for a routine upstream patch release, minor if upstream ships a new
feature you want to call out); use the `release:minor` / `release:major` PR
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
   automatically when it notices upstream is ahead; this is the same
   procedure that issue asks for.

## How to: release

1. Merge a promotion PR (`dev` -> `main`, opened automatically by
   `sync-main.yml`). Label it `release:minor` or `release:major` beforehand to
   override the default patch bump.
2. `release.yml` mints the next `vX.Y.Z` tag, builds+pushes
   `ghcr.io/rake-pro/ntfy:X.Y.Z` (+ `X.Y` + `latest` + `sha-<short>`) for
   `linux/amd64,linux/arm64`, then Trivy-gates on CRITICAL.
3. Update wherever you deploy this image (Compose file, Kubernetes manifest,
   or Helm values) to the new tag and roll out.

## How to: roll back

* Deploy side: pin your deployment's image tag back to the previous
  `X.Y.Z` (or back to `binwiederhier/ntfy`, if rolling all the way off this
  image) and re-apply.
* Image side: no image deletion needed, since GHCR keeps every pushed tag. A
  broken release just gets superseded by the next patch tag.

## Deploying

This image runs as uid 1000 and listens on an unprivileged port, so
`NTFY_LISTEN_HTTP` must be set to something other than upstream's default
`:80`.

Plain `docker run`:

```
docker run -d -p 8080:8080 -e NTFY_LISTEN_HTTP=:8080 \
  -v /var/lib/ntfy:/var/lib/ntfy ghcr.io/rake-pro/ntfy:1.0.0 serve
```

Kubernetes/Helm values (e.g. deploying this in place of the upstream chart's
default image):

```yaml
image:
  repository: ghcr.io/rake-pro/ntfy
  tag: "1.0.0"
```

The `ghcr.io/rake-pro/ntfy` package is public, so no `imagePullSecrets` are
needed.

This image runs as uid 1000 (`restricted`-profile compatible), unlike the
stock `binwiederhier/ntfy` image, which runs as root by default. If your
existing deployment assumes a root filesystem owner, switch its pod security
context to non-root/restricted (or set an explicit `fsGroup: 1000`) so any
volume mounted at `/var/lib/ntfy` stays writable by uid 1000. This is not
required for the image to run, but leaving it root after switching to a
non-root image gets no benefit from the hardening.
