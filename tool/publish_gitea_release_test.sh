#!/usr/bin/env bash
# Self-test of publish_gitea_release.sh without network: a stand-in curl
# notes the uploads. Only the files in SHA256SUMS.txt, the list and its
# signature may go up, never the unpacked app or the release text beside
# them, and nothing without a passed CI (or a stated reason to skip it).
set -euo pipefail

readonly ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly WORK=$(mktemp -d "${TMPDIR:-/tmp}/famio-publish-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/release/Famio.app/Contents/MacOS"
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
for arg; do
  case "$arg" in
    *'/assets?name='*) echo "${arg##*name=}" >> "$UPLOADS" ;;
  esac
done
case " $* " in
  *' -X POST '*'/releases '* | *'/releases/tags/'*) echo '{"id":42,"author":{"id":7}}' ;;
esac
EOF
chmod +x "$WORK/bin/curl"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" remote add origin https://gitea.invalid/owner/Famio.git

cd "$WORK/release"
printf 'apk\n' > Famio-9.9.9-android.apk
printf 'zip\n' > Famio-9.9.9-macOS.zip
shasum -a 256 Famio-9.9.9-android.apk Famio-9.9.9-macOS.zip > SHA256SUMS.txt
printf 'sig\n' > SHA256SUMS.txt.sig
printf 'binary\n' > Famio.app/Contents/MacOS/Famio
printf '# Famio 9.9.9\n' > RELEASE-TEXT-v9.9.9.md

publish() {
  : > "$WORK/uploads"
  (cd "$WORK/repo" && env -u GITHUB_TOKEN PATH="$WORK/bin:$PATH" \
    UPLOADS="$WORK/uploads" GITEA_TOKEN=test \
    FAMIO_CI_OVERRIDE="${CI_OVERRIDE-Selbsttest}" \
    sh "$ROOT/tool/publish_gitea_release.sh" 9.9.9 "$WORK/release")
}

# Without a passed CI (here: no token to ask GitHub) nothing goes up.
if CI_OVERRIDE='' publish > /dev/null 2>&1 || [[ -s "$WORK/uploads" ]]; then
  printf 'Published without checking the CI.\n' >&2
  exit 1
fi

output=$(publish 2>&1)
expected=$'Famio-9.9.9-android.apk\nFamio-9.9.9-macOS.zip\nSHA256SUMS.txt\nSHA256SUMS.txt.sig'
if [[ "$(sort "$WORK/uploads")" != "$expected" ]]; then
  printf 'Unexpected uploads:\n%s\n' "$(cat "$WORK/uploads")" >&2
  exit 1
fi
if [[ "$output" != *'CI check skipped: Selbsttest'* ]]; then
  printf 'The skipped CI check is not reported:\n%s\n' "$output" >&2
  exit 1
fi
for skipped in Famio.app RELEASE-TEXT-v9.9.9.md; do
  if [[ "$output" != *"Not uploaded (not in SHA256SUMS.txt): $skipped"* ]]; then
    printf 'No note about skipping %s:\n%s\n' "$skipped" "$output" >&2
    exit 1
  fi
done

# A listed file that is missing stops it before anything goes up.
mv Famio-9.9.9-macOS.zip "$WORK/"
if publish > /dev/null 2>&1 || [[ -s "$WORK/uploads" ]]; then
  printf 'A missing file was not refused before uploading.\n' >&2
  exit 1
fi

printf 'Publish script uploads only the listed files.\n'
