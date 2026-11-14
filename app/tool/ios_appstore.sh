#!/bin/sh
# Builds Famio for TestFlight and the App Store: an archive and an IPA
# signed for App Store Connect. Nothing is uploaded; that stays a step of
# its own (Xcode → Window → Organizer, or Transporter).
#
#   app/tool/ios_appstore.sh [build number] [output folder]
#
# The build number (CFBundleVersion) defaults to the one in pubspec.yaml.
# App Store Connect takes each build number of a version only once, so a
# second upload of the same version needs a higher one, e.g. 105.1.
#
# Needs the team of the Apple developer account in
# ios/Flutter/Signing.xcconfig (DEVELOPMENT_TEAM = …, not in the repository)
# and Xcode signed in to that account. The build is the store variant
# (FAMIO_STORE: no tip link) and is made from the project as committed:
# local changes to the Xcode project are refused, so what is uploaded is
# what the repository holds.
set -eu

cd "$(dirname "$0")/.."
signing=ios/Flutter/Signing.xcconfig
team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' \
  "$signing" 2> /dev/null | head -1)
if [ -z "$team" ]; then
  echo "In $signing fehlt DEVELOPMENT_TEAM = <Team-ID>." >&2
  exit 2
fi
if ! git diff --quiet -- ios/Runner.xcodeproj ios/Runner ios/Flutter/AppInfo.xcconfig; then
  echo "Das Xcode-Projekt hat lokale Änderungen. Bitte vorher beiseitelegen:" >&2
  echo "  git stash push -- app/ios/Runner.xcodeproj" >&2
  exit 2
fi

version=$(sed -n 's/^version: *\([0-9.]*\)+\([0-9]*\).*/\1/p' pubspec.yaml)
build=${1:-$(sed -n 's/^version: *[0-9.]*+\([0-9]*\).*/\1/p' pubspec.yaml)}
case $build in
  *[!0-9.]* | .* | *. | *..*)
    echo "Ungültige Build-Nummer: $build" >&2
    exit 2
    ;;
esac
out=${2:-"$HOME/Desktop/Famio-TestFlight-v$version-$build"}
if [ -e "$out" ]; then
  echo "$out gibt es schon." >&2
  exit 2
fi
mkdir -p "$out"
log="$out/build.log"

echo "Famio $version ($build) für den App Store …"
flutter build ios --release --config-only --dart-define=FAMIO_STORE=true \
  --build-number="$build" > "$log" 2>&1

cat > "$out/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

(
  cd ios
  xcodebuild -workspace Runner.xcworkspace -scheme Runner \
    -configuration Release -destination generic/platform=iOS \
    -archivePath "$out/Famio.xcarchive" -allowProvisioningUpdates archive
  xcodebuild -exportArchive -archivePath "$out/Famio.xcarchive" \
    -exportPath "$out" -exportOptionsPlist "$out/ExportOptions.plist" \
    -allowProvisioningUpdates
) >> "$log" 2>&1 || {
  echo "Build fehlgeschlagen, siehe $log" >&2
  exit 1
}

ipa=$(ls "$out"/*.ipa)
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
unzip -q "$ipa" -d "$check"
app=$(ls -d "$check"/Payload/*.app)
plist="$app/Info.plist"
echo "Bundle-ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
echo "Version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
  "($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
echo "Mindestens iOS $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")"
if codesign -d --entitlements - --xml "$app" 2> /dev/null | grep -q get-task-allow; then
  if codesign -d --entitlements - --xml "$app" 2> /dev/null |
    plutil -extract get-task-allow raw -o - - 2> /dev/null | grep -q true; then
    echo "Fehler: Das Paket ist für die Entwicklung signiert (get-task-allow)." >&2
    exit 1
  fi
fi
if security cms -D -i "$app/embedded.mobileprovision" 2> /dev/null |
  grep -q ProvisionedDevices; then
  echo "Fehler: Das Profil nennt einzelne Geräte, es ist kein App-Store-Profil." >&2
  exit 1
fi
if [ ! -f "$app/PrivacyInfo.xcprivacy" ]; then
  echo "Fehler: PrivacyInfo.xcprivacy fehlt im Paket." >&2
  exit 1
fi
echo "Fertig: $ipa"
echo "Hochladen: Famio.xcarchive in Xcode öffnen (Organizer → Distribute App)"
echo "oder die IPA mit Transporter."
