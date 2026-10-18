#!/usr/bin/env bash
# Builds and checks a Famio release in one run, from the tagged commit:
#
#   bash tool/release.sh <version>
#
# 1. sources to the Linux and Windows build machines, their builds in the
#    background (FAMIO_LINUX_BUILD_HOST / FAMIO_WINDOWS_BUILD_HOST: ssh
#    destinations; unset = that package is left out)
# 2. web app and server package (Docker), smoke test against the previous
#    server package
# 3. macOS (ad hoc signed) and the two Android packages (all phones with the
#    recognition built in; 64-bit with it from Google Play)
# 4. SHA256SUMS.txt, its Ed25519 signature, the check the apps do, and a
#    scan of every package for private data
#
# The release folder (FAMIO_RELEASE_DIR, default
# ~/Desktop/Famio-Release-v<version>-Upload) then waits for the release
# text; publishing and rolling out stay separate steps
# (tool/publish_gitea_release.sh).
#
# Other settings: FAMIO_RELEASE_WORK (server packages of each version for
# the next smoke test, default ~/Famio/release-work), FAMIO_PRIVATE_PATTERNS
# (file with one extended regex per line: names, team ids, device ids, home
# network addresses – kept outside the repository).
set -euo pipefail

V=${1:?Aufruf: bash tool/release.sh <version>}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
R=${FAMIO_RELEASE_DIR:-$HOME/Desktop/Famio-Release-v$V-Upload}
WORK=${FAMIO_RELEASE_WORK:-$HOME/Famio/release-work}
LINUX=${FAMIO_LINUX_BUILD_HOST:-}
WINDOWS=${FAMIO_WINDOWS_BUILD_HOST:-}
PATTERNS=${FAMIO_PRIVATE_PATTERNS:-}
ANDROID_SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
BUILD_TOOLS=$(ls -d "$ANDROID_SDK"/build-tools/* | sort -V | tail -1)
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

# --- 0. the right state -------------------------------------------------------
step "Stand prüfen"
[ "$(git describe --tags --exact-match 2>/dev/null)" = "v$V" ] ||
  fail "HEAD ist nicht der Tag v$V"
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
  fail "Arbeitskopie hat Änderungen"
[ "$(cat VERSION)" = "$V" ] || fail "VERSION ist $(cat VERSION), nicht $V"
dart tool/check_versions.dart
mkdir -p "$R" "$WORK"
LOGS="$WORK/logs-$V"
mkdir -p "$LOGS"

# --- 1. remote builds ---------------------------------------------------------
step "Quellen für Linux und Windows"
SRC="$WORK/famio-src-$V.tgz"
git archive --format=tar.gz -o "$SRC" "v$V"
LINUX_PID=""
WINDOWS_PID=""
if [ -n "$LINUX" ]; then
  scp -q "$SRC" "$LINUX:famio-src.tgz"
  scp -q tool/release/build_linux.sh "$LINUX:famio-build-linux.sh"
  ssh "$LINUX" "sh famio-build-linux.sh $V" > "$LOGS/linux.log" 2>&1 &
  LINUX_PID=$!
else
  echo "FAMIO_LINUX_BUILD_HOST nicht gesetzt: kein Linux-Paket"
fi
if [ -n "$WINDOWS" ]; then
  scp -q "$SRC" "$WINDOWS:famio-src.tgz"
  scp -q tool/release/build_windows.ps1 "$WINDOWS:famio-build-windows.ps1"
  ssh "$WINDOWS" "powershell -NoProfile -ExecutionPolicy Bypass -File famio-build-windows.ps1 -V $V" \
    > "$LOGS/windows.log" 2>&1 &
  WINDOWS_PID=$!
else
  echo "FAMIO_WINDOWS_BUILD_HOST nicht gesetzt: kein Windows-Paket"
fi

# --- 2. web app, server package, smoke test ----------------------------------
step "Web-App"
sh app/tool/build_web.sh > "$LOGS/web.log" 2>&1 || { tail -20 "$LOGS/web.log"; fail "Web-Build"; }
grep -q "\"version\":\"$V\"" server/web/version.json || fail "Web-App hat nicht Version $V"

step "Server-Paket (Docker)"
docker build --platform linux/amd64 --target build -t "famio-build:$V" . > "$LOGS/docker.log" 2>&1 ||
  { tail -20 "$LOGS/docker.log"; fail "Docker-Build"; }
SRV="$WORK/server-$V"
rm -rf "$SRV" && mkdir -p "$SRV"
cid=$(docker create --platform linux/amd64 "famio-build:$V")
docker cp -q "$cid:/out/bundle" "$SRV/bundle"
docker container rm "$cid" > /dev/null
grep -q "\"version\":\"$V\"" "$SRV/bundle/web/version.json" || fail "Server-Paket hat nicht Version $V"
(cd "$SRV" && COPYFILE_DISABLE=1 tar --no-xattrs -czf "$R/famio-server-$V-linux-x64.tar.gz" bundle)

step "Smoke-Test"
PREV=$(git describe --tags --abbrev=0 "v$V^" 2>/dev/null || true)
OLD=${FAMIO_SMOKE_OLD:-$WORK/server-${PREV#v}/bundle}
if [ -n "$PREV" ] && [ -d "$OLD" ]; then
  SMOKE="$WORK/smoke-$V"
  rm -rf "$SMOKE" && mkdir -p "$SMOKE/data" "$SMOKE/old" "$SMOKE/new"
  cp -R "$OLD" "$SMOKE/old/bundle"
  cp -R "$SRV/bundle" "$SMOKE/new/bundle"
  sh tool/release/smoke.sh "$SMOKE" | tee "$LOGS/smoke.log"
  grep -q "\"version\":\"$V\"" "$LOGS/smoke.log" || fail "Smoke-Test: neue Version antwortet nicht"
  grep -q "admin sees tasks: \['muell'\]" "$LOGS/smoke.log" || fail "Smoke-Test: Daten fehlen nach dem Update"
  grep -q "weak password: weak_password" "$LOGS/smoke.log" || fail "Smoke-Test: Passwortregel"
else
  echo "Kein Server-Paket von ${PREV:-einer Vorversion} in $WORK: Smoke-Test übersprungen" \
    "(FAMIO_SMOKE_OLD=<bundle-Ordner> setzen)"
fi

# --- 3. macOS and Android -----------------------------------------------------
step "macOS"
(cd app && flutter build macos --release 2>&1 | tail -1)
APP=app/build/macos/Build/Products/Release/Famio.app
[ "$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)" = "$V" ] ||
  fail "macOS-App hat nicht Version $V"
sh app/tool/sign_macos.sh --adhoc "$APP" | tail -1
# Read first: with pipefail, grep -q ending the pipe early fails codesign.
sig=$(codesign -dvv "$APP" 2>&1 || true)
[[ "$sig" == *"Signature=adhoc"* ]] || fail "macOS-App nicht ad hoc signiert"
rm -rf "$R/Famio.app" "$R/Famio-$V-macOS.zip"
ditto -c -k --keepParent "$APP" "$R/Famio-$V-macOS.zip"
ditto "$APP" "$R/Famio.app"
# A bundle under build/ shows up in Spotlight and could open the real data.
rm -rf "$APP"

step "Android"
(cd app && flutter build apk --release --flavor prod 2>&1 | tail -1)
cp app/build/app/outputs/flutter-apk/app-prod-release.apk "$R/Famio-$V-android.apk"
(cd app && flutter build apk --release --flavor prod --target-platform android-arm64 -P famioArm64=true 2>&1 | tail -1)
cp app/build/app/outputs/flutter-apk/app-prod-release.apk "$R/Famio-$V-android-arm64.apk"
cert() {
  local out
  out=$("$BUILD_TOOLS/apksigner" verify --print-certs "$1")
  sed -n 's/.*certificate SHA-256 digest: //p' <<< "$out" | head -1
}
code() {
  local out
  out=$("$BUILD_TOOLS/aapt2" dump badging "$1" 2> /dev/null || true)
  grep -o "versionCode='[0-9]*' versionName='[^']*'" <<< "$out" | head -1
}
A1="$R/Famio-$V-android.apk"
A2="$R/Famio-$V-android-arm64.apk"
[ "$(cert "$A1")" = "$(cert "$A2")" ] || fail "Android-Pakete mit verschiedenen Schlüsseln signiert"
[ "$(code "$A1")" = "$(code "$A2")" ] || fail "Android-Pakete mit verschiedener Versionsnummer"
[[ "$(code "$A1")" == *"versionName='$V'"* ]] || fail "Android-Paket hat nicht Version $V"
[[ "$(unzip -l "$A1")" == *libmlkit_google_ocr_pipeline* ]] ||
  fail "Paket für alle Handys ohne eingebaute Erkennung"
[[ "$(unzip -l "$A2")" != *libmlkit_google_ocr_pipeline* ]] ||
  fail "arm64-Paket hat die Erkennung eingebaut (famioArm64 nicht gewirkt)"
for f in "$A1" "$A2"; do
  printf '%s: %s MB, %s\n' "$(basename "$f")" "$(($(stat -f %z "$f") / 1048576))" "$(code "$f")"
done

# --- 4. collect, sign, check --------------------------------------------------
step "Linux- und Windows-Pakete abholen"
FILES=("Famio-$V-android.apk" "Famio-$V-android-arm64.apk" "Famio-$V-macOS.zip" "famio-server-$V-linux-x64.tar.gz")
if [ -n "$LINUX_PID" ]; then
  wait "$LINUX_PID" || { tail -20 "$LOGS/linux.log"; fail "Linux-Build"; }
  scp -q "$LINUX:Famio-$V-linux-x86_64.tar.gz" "$R/"
  FILES+=("Famio-$V-linux-x86_64.tar.gz")
fi
if [ -n "$WINDOWS_PID" ]; then
  wait "$WINDOWS_PID" || { tail -20 "$LOGS/windows.log"; fail "Windows-Build"; }
  grep -q "zipped $V" "$LOGS/windows.log" || { tail -20 "$LOGS/windows.log"; fail "Windows-Build"; }
  scp -q "$WINDOWS:Famio-$V-windows-x86_64.zip" "$R/"
  FILES+=("Famio-$V-windows-x86_64.zip")
fi

step "Prüfsummen und Signatur"
(cd "$R" && shasum -a 256 "${FILES[@]}" > SHA256SUMS.txt && cat SHA256SUMS.txt)
sh tool/sign_release.sh "$R"
(cd packages/famio_shared && dart run tool/verify_release.dart "$R" "$V") || {
  [ -n "$LINUX" ] && [ -n "$WINDOWS" ] && fail "Prüfung wie in den Apps"
  echo "(Linux/Windows fehlen absichtlich)"
}

step "Datenschutz-Scan"
SCAN="$WORK/scan-$V"
rm -rf "$SCAN" && mkdir -p "$SCAN"
for f in "${FILES[@]}"; do
  d="$SCAN/$f.d"
  mkdir -p "$d"
  case "$f" in
    *.apk) unzip -qo "$R/$f" -d "$d" || true ;;
    *.zip) ditto -x -k "$R/$f" "$d" ;;
    *.tar.gz) tar -xzf "$R/$f" -C "$d" ;;
  esac
  cp "$R/$f" "$SCAN/"
done
[ -f "$R/RELEASE-TEXT-v$V.md" ] && cp "$R/RELEASE-TEXT-v$V.md" "$SCAN/"
chmod -R u+rwx "$SCAN"
found=0
check() {
  local hits
  hits=$(grep -r -a -l -i -E "$1" "$SCAN" 2>/dev/null | sed "s|$SCAN/||" | head -5 || true)
  if [ -n "$hits" ]; then
    printf 'Treffer für ein privates Muster (%s):\n%s\n' "$2" "$hits"
    found=1
  fi
}
check 'Apple Development' 'Entwicklerzertifikat'
if [ -n "$PATTERNS" ] && [ -f "$PATTERNS" ]; then
  n=0
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in "#"*) continue ;; esac
    n=$((n + 1))
    check "$pattern" "Muster $n aus FAMIO_PRIVATE_PATTERNS"
  done < "$PATTERNS"
  echo "$n private Muster geprüft"
else
  echo "FAMIO_PRIVATE_PATTERNS nicht gesetzt: nur die eingebauten Muster geprüft"
fi
rm -rf "$SCAN"
[ "$found" = 0 ] || fail "Private Daten in den Paketen"

step "Fertig: $R"
ls -la "$R" | awk 'NR > 1 {print $5, $9}'
[ -f "$R/RELEASE-TEXT-v$V.md" ] || echo "Es fehlt noch RELEASE-TEXT-v$V.md."
echo "Weiter: GITEA_TOKEN=… sh tool/publish_gitea_release.sh $V <Ordner nur mit den Dateien aus SHA256SUMS.txt und der .sig>"
