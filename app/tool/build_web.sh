#!/bin/sh
# Builds the web app (Home Assistant sidebar, /app/ of every Famio server)
# and puts it into server/web: the server packages, the Docker image and the
# add-on take it from there.
set -eu
cd "$(dirname "$0")/.."
flutter build web --release --no-web-resources-cdn "$@"
rm -rf ../server/web
mkdir -p ../server/web
cp -R build/web/. ../server/web/
# Not registered (see web/flutter_bootstrap.js); an old copy must not linger.
rm -f ../server/web/flutter_service_worker.js
echo "Web-App: server/web ($(du -sh ../server/web | cut -f1))"
