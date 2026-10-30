#!/usr/bin/env bash
# Keeps the SQLite library that the sqlite3 build hook downloads from
# github.com between CI runs, so a run does not depend on reaching
# github.com (Gitea runner famio-linux: its home directory persists).
# The hook checks the SHA-256 of a kept file before using it and downloads
# it again if it does not match, so a damaged copy costs only a download.
#
#   tool/ci_hook_cache.sh restore   before the first `dart pub get`
#   tool/ci_hook_cache.sh save      at the end, also after a failed step
set -euo pipefail

cache="${FAMIO_HOOK_CACHE:-$HOME/.cache/famio-ci/sqlite3-hook}"
packages=(packages/famio_client server app)
shared=.dart_tool/hooks_runner/shared/sqlite3/build

case "${1:-}" in
  restore)
    if [ ! -d "$cache" ]; then
      echo "No kept SQLite libraries yet."
      exit 0
    fi
    for package in "${packages[@]}"; do
      mkdir -p "$package/$shared"
      cp -R "$cache/." "$package/$shared/"
    done
    echo "Kept SQLite libraries: $(find "$cache" -type f | wc -l | tr -d ' ')"
    ;;
  save)
    for package in "${packages[@]}"; do
      [ -d "$package/$shared" ] || continue
      (cd "$package/$shared" && find . -path './download-*' -type f ! -name '*.tmp') |
        while read -r file; do
          source="$package/$shared/$file"
          target="$cache/$file"
          cmp -s "$source" "$target" && continue
          # Another download than the kept one: the hook only leaves a
          # file there after checking it, so it replaces the kept copy.
          mkdir -p "$(dirname "$target")"
          cp "$source" "$target.$$"
          mv "$target.$$" "$target"
          echo "Kept ${file#./}"
        done
    done
    ;;
  *)
    echo "usage: $0 restore|save" >&2
    exit 2
    ;;
esac
