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
# Fallback fonts (emoji, symbols, other scripts) from the Famio server
# instead of Google's font service, which would learn the address of every
# browser: shipped under fonts/, the large Chinese, Japanese and Korean sets
# fetched by the server on demand (server/lib/src/fallback_fonts.dart).
# Downloaded once into build/fallback-fonts.
import urllib.request
main_js = open(os.path.join(web, 'main.dart.js')).read()
paths = sorted(set(re.findall(
    r'"([a-z0-9]+/v[0-9]+/[A-Za-z0-9_-]+(?:[.][0-9]+)?[.](?:woff2|ttf|otf))"',
    main_js)))
if len(paths) < 100:
    sys.exit(f'only {len(paths)} fallback fonts found in main.dart.js')
cjk = re.compile(r'^notosans(sc|tc|hk|jp|kr)/')
cache = os.path.join('build', 'fallback-fonts')
fonts = os.path.join(web, 'fonts')
for path in paths:
    if cjk.match(path):
        continue
    cached = os.path.join(cache, path)
    if not os.path.exists(cached):
        os.makedirs(os.path.dirname(cached), exist_ok=True)
        url = 'https://fonts.gstatic.com/s/' + path
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        open(cached + '.part', 'wb').write(data)
        os.replace(cached + '.part', cached)
    target = os.path.join(fonts, path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(cached, target)
open(os.path.join(fonts, 'remote.txt'), 'w').write(
    ''.join(p + '\n' for p in paths if cjk.match(p)))
# The scripts carry the version in their address: reverse proxies that cache
# .js files regardless of the server's no-cache (Nginx Proxy Manager's
# "Cache Assets") and browsers would otherwise run the old app after an
# update until the cache expires.
info = json.load(open(os.path.join(web, 'version.json')))
tag = f"{info['version']}+{info.get('build_number', '')}"
for name, old, new in [
    ('index.html', 'src="flutter_bootstrap.js"', f'src="flutter_bootstrap.js?v={tag}"'),
    ('flutter_bootstrap.js', '"mainJsPath":"main.dart.js"', f'"mainJsPath":"main.dart.js?v={tag}"'),
]:
    path = os.path.join(web, name)
    text = open(path).read()
    if old not in text:
        sys.exit(f'{name}: {old} not found')
    open(path, 'w').write(text.replace(old, new))
# The parts loaded later (deferred imports, see DeferredPage) carry the
# version as well: an old part next to a new main.dart.js would break. In
# the file name, because dart2js escapes a query in the part's address.
main = os.path.join(web, 'main.dart.js')
text = open(main).read()
safe = re.sub(r'[^A-Za-z0-9.-]', '-', tag)
for part in set(re.findall(r'"(main\.dart\.js_[0-9]+\.part\.js)"', text)):
    versioned = part[:-len('.js')] + f'.{safe}.js'
    os.rename(os.path.join(web, part), os.path.join(web, versioned))
    text = text.replace(f'"{part}"', f'"{versioned}"')
open(main, 'w').write(text)
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
