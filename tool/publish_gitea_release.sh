#!/bin/sh
# Creates (or reuses) a Gitea release and uploads verified release artifacts:
# exactly the files listed in SHA256SUMS.txt, the list and its signature.
# Usage: GITEA_TOKEN=... GITHUB_TOKEN=... tool/publish_gitea_release.sh VERSION /path/to/release
# (GITHUB_TOKEN reads the Actions runs of the tag, see tool/check_ci.dart.)
set -eu

VERSION=${1:?Usage: GITEA_TOKEN=... $0 VERSION RELEASE_DIR}
RELEASE_DIR=${2:?Usage: GITEA_TOKEN=... $0 VERSION RELEASE_DIR}
: "${GITEA_TOKEN:?Set a short-lived Gitea API token in GITEA_TOKEN}"
[ -f "$RELEASE_DIR/SHA256SUMS.txt" ] || {
  echo "Missing $RELEASE_DIR/SHA256SUMS.txt" >&2
  exit 64
}
# Servers hand out app updates only from signed releases.
[ -f "$RELEASE_DIR/SHA256SUMS.txt.sig" ] || {
  echo "Missing $RELEASE_DIR/SHA256SUMS.txt.sig (sh tool/sign_release.sh $RELEASE_DIR)" >&2
  exit 64
}

ORIGIN=$(git remote get-url origin)
case "$ORIGIN" in
  https://*/*.git)
    API_BASE=$(printf '%s\n' "$ORIGIN" | sed -E 's#(https://[^/]+)/(.+)\.git#\1/api/v1/repos/\2#')
    ;;
  *)
    echo "origin must be an HTTPS Gitea URL, got: $ORIGIN" >&2
    exit 64
    ;;
esac

(cd "$RELEASE_DIR" && shasum -a 256 -c SHA256SUMS.txt)
# Only the files SHA256SUMS.txt lists, the list and its signature: the
# release folder also holds the unpacked Famio.app (whose every inner file
# a recursive upload would publish) and the release text.
NAMES="$(awk '{ sub(/^\*/, "", $2); print $2 }' "$RELEASE_DIR/SHA256SUMS.txt" | tr '\n' ' ')SHA256SUMS.txt SHA256SUMS.txt.sig"
for NAME in $NAMES; do
  case "$NAME" in
    */* | .*)
      echo "Unexpected file name in SHA256SUMS.txt: $NAME" >&2
      exit 65
      ;;
  esac
  [ -f "$RELEASE_DIR/$NAME" ] || { echo "Missing $RELEASE_DIR/$NAME" >&2; exit 66; }
done
# Gitea has no runner: GitHub (the mirror) is the only CI. Publish only a
# tag whose tests and build checks passed there; an exception needs a
# stated reason (a GitHub outage, say).
if [ -n "${FAMIO_CI_OVERRIDE:-}" ]; then
  echo "CI check skipped: $FAMIO_CI_OVERRIDE"
else
  dart "$(dirname "$0")/check_ci.dart" "v$VERSION" || {
    echo "Not published. Wait for or rerun the runs, or set FAMIO_CI_OVERRIDE=<reason>." >&2
    exit 1
  }
fi
TAG="v$VERSION"
AUTH="Authorization: token $GITEA_TOKEN"
RELEASE=$(curl -fsS -H "$AUTH" "$API_BASE/releases/tags/$TAG" 2>/dev/null || true)
if [ -z "$RELEASE" ]; then
  RELEASE=$(curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$TAG\",\"name\":\"Famio $VERSION\"}" \
    "$API_BASE/releases")
fi
# The response contains nested objects (for example `author.id`).  Match
# only the root object's first field, otherwise an upload is sent to an
# unrelated release ID and Gitea replies with 404.
RELEASE_ID=$(printf '%s' "$RELEASE" | sed -nE 's/^[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')
[ -n "$RELEASE_ID" ] || { echo "Could not read Gitea release id." >&2; exit 1; }

for NAME in $NAMES; do
  curl -fsS -X POST -H "$AUTH" --upload-file "$RELEASE_DIR/$NAME" \
    "$API_BASE/releases/$RELEASE_ID/assets?name=$NAME" >/dev/null
  echo "Uploaded $NAME"
done
for FILE in "$RELEASE_DIR"/*; do
  case " $NAMES " in
    *" $(basename "$FILE") "*) ;;
    *) echo "Not uploaded (not in SHA256SUMS.txt): $(basename "$FILE")" ;;
  esac
done
