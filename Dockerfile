# syntax=docker/dockerfile:1

# Thin repackage of the upstream ntfy release binary: current alpine base +
# `apk upgrade --no-cache` + the pinned upstream linux tarball, sha256-verified
# against upstream's checksums.txt. No source build - upstream's own release
# binaries are statically linked (CGO_ENABLED=1, -extldflags=-static, for
# go-sqlite3), so they run unmodified on musl/alpine.
#
# Bump procedure: see README.md "Bump upstream ntfy version".
ARG NTFY_VERSION=2.28.0
ARG ALPINE_VERSION=3.24.2

# ---- fetch (always native: avoids QEMU for a plain curl+tar+sha256sum) ----
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS fetch
ARG NTFY_VERSION
ARG TARGETARCH
# Update together when NTFY_VERSION bumps - verify against upstream's
# checksums.txt for the release (see README.md).
ARG NTFY_SHA256_AMD64=881a1530e30e01f1dec202c7f41e1664e57edfb7844e73e21e345159ac3ea9b7
ARG NTFY_SHA256_ARM64=18a13411e315ba44781df222c432d27527fc089c2229a994c593beb9c1e247a0

RUN apk add --no-cache curl
WORKDIR /fetch
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) sha256="${NTFY_SHA256_AMD64}" ;; \
      arm64) sha256="${NTFY_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    file="ntfy_${NTFY_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    url="https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/${file}"; \
    curl -fsSL -o "${file}" "${url}"; \
    echo "${sha256}  ${file}" | sha256sum -c -; \
    tar -xzf "${file}" --strip-components=1 "ntfy_${NTFY_VERSION}_linux_${TARGETARCH}/ntfy"; \
    chmod 0755 ntfy

# ---- runtime ----
FROM alpine:${ALPINE_VERSION}
ARG NTFY_VERSION

# Pull distro security fixes newer than the tagged base.
RUN apk upgrade --no-cache && \
    apk add --no-cache tzdata && \
    rm -rf /var/cache/apk/*

LABEL org.opencontainers.image.title="ntfy" \
      org.opencontainers.image.description="Rake-Pro thin repackage of the upstream ntfy release binary (current alpine + apk upgrade)" \
      org.opencontainers.image.source="https://github.com/Rake-Pro/ntfy-image" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.rake-pro.upstream-project="https://github.com/binwiederhier/ntfy" \
      io.rake-pro.upstream-version="${NTFY_VERSION}"

# Non-root. uid/gid 1000 must own the mounted cache/auth db directory
# (NTFY_CACHE_FILE / NTFY_AUTH_FILE parent dir) - see GitOps values before
# rolling this out (fsGroup / runAsUser must match).
RUN adduser -D -u 1000 ntfy
USER ntfy

COPY --from=fetch --chown=1000:1000 /fetch/ntfy /usr/bin/ntfy

# Upstream default listen-http is :80 (needs root); this image runs as uid
# 1000, so any deployment must set NTFY_LISTEN_HTTP to an unprivileged port
# (the GitOps chart already sets 8080).
EXPOSE 8080/tcp
ENTRYPOINT ["ntfy"]
CMD ["serve"]
