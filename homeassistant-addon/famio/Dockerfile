# Famio add-on, built by Home Assistant itself: the server package of this
# version comes from the project's GitHub release, checked against the
# release's signed checksums (the same Ed25519 key the apps trust), so no
# container registry is needed. Home Assistant passes BUILD_ARCH (amd64 or
# aarch64) and BUILD_VERSION (the version in config.yaml).
FROM debian:bookworm-slim AS fetch
ARG BUILD_ARCH
ARG BUILD_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssl \
    && rm -rf /var/lib/apt/lists/*
COPY release-key.pem /tmp/release-key.pem
RUN set -eu; \
    case "$BUILD_ARCH" in \
      amd64) arch=x64 ;; \
      aarch64) arch=arm64 ;; \
      *) echo "Famio gibt es nicht für $BUILD_ARCH" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/Dasevo-Digital/Famio/releases/download/v$BUILD_VERSION"; \
    file="famio-server-$BUILD_VERSION-linux-$arch.tar.gz"; \
    cd /tmp; \
    curl -fsSL --retry 3 -o SHA256SUMS.txt "$base/SHA256SUMS.txt"; \
    curl -fsSL --retry 3 -o SHA256SUMS.txt.sig "$base/SHA256SUMS.txt.sig"; \
    curl -fsSL --retry 3 -o "$file" "$base/$file"; \
    base64 -d SHA256SUMS.txt.sig > sig.bin; \
    openssl pkeyutl -verify -rawin -pubin -inkey release-key.pem \
      -in SHA256SUMS.txt -sigfile sig.bin; \
    grep "  $file\$" SHA256SUMS.txt | sha256sum -c -; \
    mkdir -p /out/data; \
    tar -xzf "$file" -C /out

# Same runtime as the standalone image: glibc and CA certificates only.
FROM gcr.io/distroless/cc-debian12
COPY --from=fetch /out/bundle /opt/famio
COPY --from=fetch /out/data /data
ENV FAMIO_DATA_DIR=/data
EXPOSE 8765 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/opt/famio/bin/server", "--healthcheck"]
ENTRYPOINT ["/opt/famio/bin/server"]
