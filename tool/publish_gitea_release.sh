#!/bin/sh
# Creates (or reuses) a Gitea release and uploads verified release artifacts.
# Usage: GITEA_TOKEN=... tool/publish_gitea_release.sh 0.22.0 /path/to/release
set -eu

VERSION=${1:?Usage: GITEA_TOKEN=... $0 VERSION RELEASE_DIR}
RELEASE_DIR=${2:?Usage: GITEA_TOKEN=... $0 VERSION RELEASE_DIR}
: "${GITEA_TOKEN:?Set a short-lived Gitea API token in GITEA_TOKEN}"
[ -f "$RELEASE_DIR/SHA256SUMS.txt" ] || {
  echo "Missing $RELEASE_DIR/SHA256SUMS.txt" >&2
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
TAG="v$VERSION"
AUTH="Authorization: token $GITEA_TOKEN"
RELEASE=$(curl -fsS -H "$AUTH" "$API_BASE/releases/tags/$TAG" 2>/dev/null || true)
if [ -z "$RELEASE" ]; then
  RELEASE=$(curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    --data "{\"tag_name\":\"$TAG\",\"target_commitish\":\"$TAG\",\"name\":\"Famio $VERSION\"}" \
    "$API_BASE/releases")
fi
RELEASE_ID=$(printf '%s' "$RELEASE" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1)
[ -n "$RELEASE_ID" ] || { echo "Could not read Gitea release id." >&2; exit 1; }

find "$RELEASE_DIR" -type f ! -name '.DS_Store' -print | while IFS= read -r FILE; do
  NAME=$(basename "$FILE")
  curl -fsS -X POST -H "$AUTH" --upload-file "$FILE" \
    "$API_BASE/releases/$RELEASE_ID/assets?name=$NAME" >/dev/null
  echo "Uploaded $NAME"
done
