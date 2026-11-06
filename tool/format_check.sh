#!/usr/bin/env bash
# Every Dart file in the repository is formatted the way `dart format` of the
# pinned SDK (see tool/check_versions.dart) writes it. Generated code that is
# not checked in stays out.
#
#   bash tool/format_check.sh        check (pre-push hook and CI)
#   bash tool/format_check.sh --fix  format them
#
# The style depends on each package's language version. The formatter reads
# it from the package config of `pub get`; the CI checks before that, so the
# version comes from the package's pubspec (sdk: ^3.12.2 → 3.12) instead.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
check=(--output=none --set-exit-if-changed)
[ "${1:-}" = --fix ] && check=()

# New files too: otherwise --fix passes them over until they are committed.
dart_files() {
  git ls-files --cached --others --exclude-standard "$1" | grep '\.dart$' || true
}

failed=0
packages=()
for pubspec in $(git ls-files '*pubspec.yaml'); do
  dir=$(dirname "$pubspec")
  version=$(sed -nE 's/^[[:space:]]+sdk:[[:space:]]*["'\'']?[\^>=]*([0-9]+\.[0-9]+).*/\1/p' "$pubspec" | head -1)
  [ -n "$version" ] || { echo "$pubspec: keine SDK-Version" >&2; exit 1; }
  packages+=("$dir")
  files=$(dart_files "$dir")
  [ -n "$files" ] || continue
  printf '%s\n' "$files" | tr '\n' '\0' |
    xargs -0 dart format ${check[@]+"${check[@]}"} --language-version="$version" 2>/dev/null ||
    failed=1
done
# Files outside every package (tool/): the SDK's own language version.
rest=$(dart_files . | grep -v -E "^($(IFS='|'; echo "${packages[*]}"))/" || true)
if [ -n "$rest" ]; then
  printf '%s\n' "$rest" | tr '\n' '\0' | xargs -0 dart format ${check[@]+"${check[@]}"} || failed=1
fi
if [ "$failed" -ne 0 ] && [ ${#check[@]} -gt 0 ]; then
  echo "Nicht formatiert (bash tool/format_check.sh --fix)" >&2
  exit 1
fi
