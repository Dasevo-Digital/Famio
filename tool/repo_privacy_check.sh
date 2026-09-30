#!/usr/bin/env bash
# Fails when a personal identifier slips into tracked source or Git history.
set -euo pipefail

readonly PROJECT_EMAIL='noreply'@'famio.invalid'
readonly IDENTITY="Famio Contributors <$PROJECT_EMAIL>"
readonly EXCLUDED=(
  ':(exclude)app/assets/fonts/OFL-Fredoka.txt'
  ':(exclude)app/assets/fonts/OFL-Nunito.txt'
)

fail=0
report() {
  printf '%s\n' "$1" >&2
  fail=1
}

if matches=$(git grep -n -I -E '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' -- . "${EXCLUDED[@]}" || true); then
  if [[ -n "$matches" ]]; then
    report "Email address in a tracked file:"
    printf '%s\n' "$matches" >&2
  fi
fi

if identities=$(git log --all --format='%aN <%aE>%n%cN <%cE>' | sort -u | grep -vFx "$IDENTITY" || true); then
  if [[ -n "$identities" ]]; then
    report "Non-project author or committer identity in reachable Git history:"
    printf '%s\n' "$identities" >&2
  fi
fi

if (( fail )); then
  exit 1
fi
printf 'Repository privacy check passed.\n'
