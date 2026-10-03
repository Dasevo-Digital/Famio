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

# Inspect the branch intended for publication. Local backup and
# remote-tracking refs are deliberately excluded because a normal branch push
# does not publish them.
if identities=$(git log HEAD --format='%aN <%aE>%n%cN <%cE>' | sort -u | grep -vFx "$IDENTITY" || true); then
  if [[ -n "$identities" ]]; then
    report "Non-project author or committer identity in reachable Git history:"
    printf '%s\n' "$identities" >&2
  fi
fi

# Commit and tag messages are published as well: no addresses besides the
# project's and no co-author or generator trailers.
readonly MESSAGE_RE='[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|co-authored-by:|generated with'
for commit in $(git rev-list HEAD); do
  if hits=$(git log -1 --format=%B "$commit" | grep -i -E "$MESSAGE_RE" | grep -vF "$PROJECT_EMAIL" || true); [[ -n "$hits" ]]; then
    report "Commit ${commit:0:7}: message names a person or a tool:"
    printf '%s\n' "$hits" >&2
  fi
done
while IFS= read -r tag; do
  if hits=$(git for-each-ref "refs/tags/$tag" --format='%(contents)' | grep -i -E "$MESSAGE_RE" | grep -vF "$PROJECT_EMAIL" || true); [[ -n "$hits" ]]; then
    report "Tag $tag: message names a person or a tool:"
    printf '%s\n' "$hits" >&2
  fi
done < <(git tag -l)

# Typical secrets (private keys, GitHub/AWS/Slack/API tokens) in tracked
# files and anywhere in the published history.
readonly SECRET_RE='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}'
readonly SELF=':(exclude)tool/repo_privacy_check.sh'
if matches=$(git grep -n -I -E -e "$SECRET_RE" -- . "$SELF" || true); [[ -n "$matches" ]]; then
  report "Possible secret in a tracked file:"
  printf '%s\n' "$matches" >&2
fi
if commits=$(git log HEAD --format='%h %s' --extended-regexp -G"$SECRET_RE" -- . "$SELF"); [[ -n "$commits" ]]; then
  report "Possible secret added or removed in Git history:"
  printf '%s\n' "$commits" >&2
fi

if (( fail )); then
  exit 1
fi
printf 'Repository privacy check passed.\n'
