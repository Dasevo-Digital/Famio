# Famio add-on built by Home Assistant itself from the prebuilt server
# packages next to this file – no container registry needed. Home Assistant
# passes BUILD_ARCH (amd64 or aarch64).
FROM debian:bookworm-slim AS unpack
ARG BUILD_ARCH
COPY famio-server-${BUILD_ARCH}.tar.gz /tmp/famio.tar.gz
RUN mkdir -p /out/data && tar -xzf /tmp/famio.tar.gz -C /out

# Same runtime as the standalone image: glibc and CA certificates only.
FROM gcr.io/distroless/cc-debian12
COPY --from=unpack /out/bundle /opt/famio
COPY --from=unpack /out/data /data
ENV FAMIO_DATA_DIR=/data
EXPOSE 8765 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/opt/famio/bin/server", "--healthcheck"]
ENTRYPOINT ["/opt/famio/bin/server"]
