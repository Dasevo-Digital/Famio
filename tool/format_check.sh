#!/usr/bin/env bash
# Every Dart file in the repository is formatted the way `dart format` of the
# pinned SDK (see tool/check_versions.dart) writes it. Generated code that is
# not checked in stays out.
#
#   bash tool/format_check.sh        check (pre-push hook and CI)
#   bash tool/format_check.sh --fix  format them
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ "${1:-}" = --fix ]; then
  git ls-files -z '*.dart' | xargs -0 dart format
else
  git ls-files -z '*.dart' |
    xargs -0 dart format --output=none --set-exit-if-changed || {
    echo "Nicht formatiert (bash tool/format_check.sh --fix)" >&2
    exit 1
  }
fi
