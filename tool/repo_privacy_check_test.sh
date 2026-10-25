#!/usr/bin/env bash
set -euo pipefail

readonly ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/famio-privacy-check.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/tool"
cp "$ROOT/tool/repo_privacy_check.sh" "$FIXTURE/tool/"
cd "$FIXTURE"
git init -q
git config user.name superkuh86
git config user.email '335995236+superkuh86''@''users.noreply.github.com'
printf 'harmlos\n' > README.md
git add README.md tool/repo_privacy_check.sh
git commit -qm baseline

private_email='private''@''sensitive.invalid'
private_token='ghp_''0123456789abcdefghijklmnopqrstuvwxyz'
printf '%s\n%s\n' "$private_email" "$private_token" > leak.txt
git add leak.txt

set +e
output=$(bash tool/repo_privacy_check.sh 2>&1)
status=$?
set -e

if (( status == 0 )); then
  printf 'Privacy check accepted a fixture containing private values.\n' >&2
  exit 1
fi
if [[ "$output" == *"$private_email"* || "$output" == *"$private_token"* ]]; then
  printf 'Privacy check printed a private value.\n' >&2
  exit 1
fi
if [[ "$output" != *'leak.txt:1: [masked]'* || "$output" != *'leak.txt:2: [masked]'* ]]; then
  printf 'Privacy check did not report the masked locations.\n' >&2
  exit 1
fi

printf 'Repository privacy check masking test passed.\n'
