# Famio server image, used standalone and as Home Assistant add-on.
# Build from the repository root: docker build -t famio-server .
# The web app comes from server/web (app/tool/build_web.sh), if built.
# Pinned multi-architecture image digests make release builds reproducible.
FROM dart:3.12.2@sha256:5ac89dbcae4327278b257920e2786df0f22c87adc630017266b67cfcceef8348 AS build
WORKDIR /src
COPY packages/famio_shared packages/famio_shared
COPY server/pubspec.* server/
WORKDIR /src/server
RUN dart pub get
COPY server .
RUN dart build cli -t bin/server.dart -o /out \
    && mkdir -p /out/data \
    && if [ -f web/index.html ]; then cp -R web /out/bundle/web; fi

# Distroless: glibc and CA certificates only (needed for fetching https
# calendar subscriptions), no shell or package manager.
FROM gcr.io/distroless/cc-debian12@sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa
COPY --from=build /out/bundle /opt/famio
COPY --from=build /out/data /data
ENV FAMIO_DATA_DIR=/data
VOLUME /data
EXPOSE 8765 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/opt/famio/bin/server", "--healthcheck"]
ENTRYPOINT ["/opt/famio/bin/server"]
