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
python3 - ../server/web <<'PY'
import gzip, json, os, re, shutil, sys
web = sys.argv[1]
# Not registered (see web/flutter_bootstrap.js); an old copy must not linger.
for name in ['flutter_service_worker.js']:
    path = os.path.join(web, name)
    if os.path.exists(path):
        os.remove(path)
# Only the CanvasKit renderer is used (dart2js build): the other engines and
# debug symbols would only make the server packages bigger.
kit = os.path.join(web, 'canvaskit')
for name in os.listdir(kit):
    if re.match(r'(skwasm|wimp|experimental_webparagraph)', name):
        path = os.path.join(kit, name)
        shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
for root, _, files in os.walk(kit):
    for name in files:
        if name.endswith('.symbols'):
            os.remove(os.path.join(root, name))
# The browser loads every font of the manifest at start: drop the icon
# fonts the app never uses (Lucide weights, Cupertino).
manifest = os.path.join(web, 'assets', 'FontManifest.json')
fonts = json.load(open(manifest))
keep = []
for family in fonts:
    if re.search(r'(Lucide\d+|CupertinoIcons)$', family['family']):
        for font in family['fonts']:
            path = os.path.join(web, 'assets', font['asset'])
            if os.path.exists(path):
                os.remove(path)
    else:
        keep.append(family)
json.dump(keep, open(manifest, 'w'))
# Compressed copies: the server sends them to browsers that accept gzip.
for root, _, files in os.walk(web):
    for name in files:
        if re.search(r'\.(js|mjs|wasm|json|ttf|otf|html|css|bin|frag)$', name):
            path = os.path.join(root, name)
            data = open(path, 'rb').read()
            packed = gzip.compress(data, 9, mtime=0)
            if len(packed) < len(data) * 0.9:
                open(path + '.gz', 'wb').write(packed)
PY
echo "Web-App: server/web ($(du -sh ../server/web | cut -f1))"
