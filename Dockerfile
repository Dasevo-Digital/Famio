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
# server/web is not in the repository: a web app left over from an older
# build must not end up in the package (1.0.6 to 1.0.14 shipped 1.0.5).
RUN dart build cli -t bin/server.dart -o /out \
    && mkdir -p /out/data \
    && if [ -f web/index.html ]; then \
         v=$(sed -n 's/^version: *//p' pubspec.yaml); \
         grep -q "\"version\":\"$v\"" web/version.json \
           || { echo "server/web ist nicht Version $v: app/tool/build_web.sh ausführen" >&2; exit 1; }; \
         cp -R web /out/bundle/web; \
       fi

# Distroless: glibc and CA certificates only (needed for fetching https
# calendar subscriptions), no shell or package manager.
FROM gcr.io/distroless/cc-debian12@sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa
# Runs as the unprivileged user "nonroot" (65532) of the base image. The
# Home Assistant add-on gets /data from the Supervisor as root and is built
# with --build-arg FAMIO_UID=0.
ARG FAMIO_UID=65532
COPY --from=build /out/bundle /opt/famio
# A new named volume takes over this owner, so a fresh install just works;
# an existing ./data of a root container needs a one-time chown (README).
COPY --from=build --chown=${FAMIO_UID}:${FAMIO_UID} /out/data /data
ENV FAMIO_DATA_DIR=/data
USER ${FAMIO_UID}:${FAMIO_UID}
VOLUME /data
EXPOSE 8765 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/opt/famio/bin/server", "--healthcheck"]
ENTRYPOINT ["/opt/famio/bin/server"]
