# Famio server image, used standalone and as Home Assistant add-on.
# Build from the repository root: docker build -t famio-server .
FROM dart:stable AS build
WORKDIR /src
COPY packages/famio_shared packages/famio_shared
COPY server/pubspec.* server/
WORKDIR /src/server
RUN dart pub get
COPY server .
RUN dart build cli -t bin/server.dart -o /out \
    && mkdir -p /out/data

# Distroless: glibc and CA certificates only (needed for fetching https
# calendar subscriptions), no shell or package manager.
FROM gcr.io/distroless/cc-debian12
COPY --from=build /out/bundle /opt/famio
COPY --from=build /out/data /data
ENV FAMIO_DATA_DIR=/data
VOLUME /data
EXPOSE 8765 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/opt/famio/bin/server", "--healthcheck"]
ENTRYPOINT ["/opt/famio/bin/server"]
