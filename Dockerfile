# syntax=docker/dockerfile:1

# ntfy built from upstream source with the current Go toolchain, on a current
# alpine base with `apk upgrade --no-cache`.
#
# Why a source build (2026-10-21): upstream's release binaries are built with
# whatever Go upstream had at release time (v2.32.0 = go1.27.1), so every Go
# stdlib advisory sat in the image until upstream rebuilt. Compiling here with
# the pinned GO_VERSION decouples the two. The build mirrors upstream's
# .goreleaser.yml exactly: CGO_ENABLED=1 for go-sqlite3, static external link,
# tags sqlite_omit_load_extension,osusergo,netgo, web UI and docs embedded via
# //go:embed (server/site, server/docs). Source is pinned by tag AND commit sha.
#
# Bump procedure: see README.md "How to: bump the upstream ntfy version".
ARG NTFY_VERSION=2.37.2
ARG NTFY_COMMIT=05109571fd0931affb6f92b17bbfd62c4d2ea68a
ARG GO_VERSION=1.27.3
ARG NODE_VERSION=24
ARG PYTHON_VERSION=3.13
ARG ALPINE_VERSION=3.24.3

# ---- source checkout (native; verified against the pinned commit) ----
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS src
ARG NTFY_VERSION
ARG NTFY_COMMIT
RUN apk add --no-cache git
WORKDIR /src
RUN set -eu; \
    git clone -q --depth 1 --branch "v${NTFY_VERSION}" https://github.com/binwiederhier/ntfy .; \
    head="$(git rev-parse HEAD)"; \
    [ "${head}" = "${NTFY_COMMIT}" ] || { echo "tag v${NTFY_VERSION} is ${head}, expected ${NTFY_COMMIT}" >&2; exit 1; }; \
    rm -rf .git

# ---- web UI (native; upstream Makefile `web-build`) ----
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS web
COPY --from=src /src/web /src/web
WORKDIR /src/web
RUN set -eu; \
    npm ci --no-audit --no-fund; \
    npm run build; \
    mv build/index.html build/app.html; \
    rm -f build/config.js

# ---- docs site (native; upstream Makefile `docs-build`) ----
FROM --platform=$BUILDPLATFORM python:${PYTHON_VERSION}-slim AS docs
COPY --from=src /src /src
WORKDIR /src
RUN set -eu; \
    pip install --no-cache-dir -r requirements.txt; \
    python -m mkdocs build -d /out/docs

# ---- Go build (native host toolchain, cross-compiled per TARGETARCH) ----
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build
ARG TARGETARCH
ARG NTFY_VERSION
ARG NTFY_COMMIT
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
 && rm -rf /var/lib/apt/lists/*
COPY --from=src /src /src
COPY --from=web /src/web/build /src/server/site
COPY --from=docs /out/docs /src/server/docs
WORKDIR /src
# Module bumps on top of the upstream go.mod: upstream 2.37.2 still pins x/net 0.61.0
# (GO-2026-6860 / GO-2026-6866 in x/net/html). Drop the line once upstream catches up.
RUN go get golang.org/x/net@v0.62.0 && go mod tidy
RUN go mod download
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) CC=gcc ;; \
      arm64) CC=aarch64-linux-gnu-gcc ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    CGO_ENABLED=1 GOOS=linux GOARCH="${TARGETARCH}" CC="${CC}" \
    go build -trimpath \
      -tags sqlite_omit_load_extension,osusergo,netgo \
      -ldflags "-linkmode=external -extldflags=-static -s -w -X main.version=${NTFY_VERSION} -X main.commit=${NTFY_COMMIT} -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      -o /out/ntfy .; \
    go version -m /out/ntfy | head -3

# ---- runtime ----
FROM alpine:${ALPINE_VERSION}
ARG NTFY_VERSION

# Pull distro security fixes newer than the tagged base.
RUN apk upgrade --no-cache && \
    apk add --no-cache tzdata && \
    rm -rf /var/cache/apk/*

LABEL org.opencontainers.image.title="ntfy" \
      org.opencontainers.image.description="Rake-Pro build of upstream ntfy from source with the current Go toolchain (current alpine + apk upgrade)" \
      org.opencontainers.image.source="https://github.com/Rake-Pro/ntfy-image" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.rake-pro.upstream-project="https://github.com/binwiederhier/ntfy" \
      io.rake-pro.upstream-version="${NTFY_VERSION}"

# Non-root. uid/gid 1000 must own the mounted cache/auth db directory
# (NTFY_CACHE_FILE / NTFY_AUTH_FILE parent dir) - see GitOps values before
# rolling this out (fsGroup / runAsUser must match).
RUN adduser -D -u 1000 ntfy
# No Multipath TCP listeners: nothing on the fleet dials MPTCP, and a listening MPTCP
# socket was the precondition of the CVE-2026-98432 host-kernel exploit. Upstream go.mod
# is not ours to edit, so the opt-out is a runtime GODEBUG instead of a godebug directive.
ENV GODEBUG=multipathtcp=0

USER ntfy

COPY --from=build --chown=1000:1000 /out/ntfy /usr/bin/ntfy

# Upstream default listen-http is :80 (needs root); this image runs as uid
# 1000, so any deployment must set NTFY_LISTEN_HTTP to an unprivileged port
# (the GitOps chart already sets 8080).
EXPOSE 8080/tcp
ENTRYPOINT ["ntfy"]
CMD ["serve"]
