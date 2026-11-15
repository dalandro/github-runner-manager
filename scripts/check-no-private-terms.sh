#!/usr/bin/env bash
# Fail when tracked files, outgoing commit messages or author names contain a private term.
#
# Terms live in a file OUTSIDE the repo (one extended regex per line, matched
# case-insensitively; blank lines and lines starting with # are ignored).
# Point PRIVATE_TERMS_FILE at it. Unset: print a notice and exit 0 (CI runs it so).
#
# As a pre-push hook (git passes "<local ref> <local sha> <remote ref> <remote sha>"
# lines on stdin): checks every pushed commit's tree, message and ref name.
# Run by hand (stdin is a terminal, or --worktree): checks the tracked files in the
# working tree and the messages of commits no remote has yet.
set -euo pipefail

usage() {
  echo "usage: PRIVATE_TERMS_FILE=<file> $0 [--worktree] [<remote> <url>]" >&2
  exit 2
}

if [[ -z ${PRIVATE_TERMS_FILE:-} ]]; then
  echo "private-terms: PRIVATE_TERMS_FILE not set; skipping (no-op)."
  exit 0
fi
if [[ ! -r $PRIVATE_TERMS_FILE ]]; then
  echo "private-terms: cannot read PRIVATE_TERMS_FILE" >&2
  exit 2
fi

mode=hook
if [[ ${1:-} == --worktree ]]; then
  mode=worktree
  shift
elif [[ -t 0 ]]; then
  mode=worktree
fi
[[ $# -le 2 ]] || usage

terms=$(mktemp)
trap 'rm -f "$terms"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$PRIVATE_TERMS_FILE" > "$terms" || true
if [[ ! -s $terms ]]; then
  echo "private-terms: term file has no terms" >&2
  exit 2
fi

zero=0000000000000000000000000000000000000000
hits=0
commits=0

report() { # <label> <matching lines>
  local count
  count=$(printf '%s\n' "$2" | grep -c '') || true
  hits=$((hits + count))
  printf 'private-terms: %s\n%s\n' "$1" "$2" >&2
}

check_text() { # <label> <text>
  local found
  found=$(printf '%s\n' "$2" | grep -n -i -E -f "$terms") || return 0
  report "$1" "$found"
}

check_tree() { # <tree-ish or empty for the working tree>
  local found
  if [[ -n $1 ]]; then
    found=$(git grep -I -n -i -E -f "$terms" "$1" --) || return 0
  else
    found=$(git grep -I -n -i -E -f "$terms" --) || return 0
  fi
  report "tracked files${1:+ in $1}" "$found"
}

check_commits() { # <rev-list args...>
  local sha
  while read -r sha; do
    commits=$((commits + 1))
    check_text "message of $sha" "$(git log -1 --format=%B "$sha")"
    check_text "author/committer name of $sha" "$(git log -1 --format='%an%n%cn' "$sha")"
    if [[ $mode == hook ]]; then
      check_tree "$sha"
    fi
  done < <(git rev-list "$@" 2>/dev/null)
}

if [[ $mode == worktree ]]; then
  check_tree ""
  check_commits HEAD --not --remotes
else
  while read -r local_ref local_sha remote_ref remote_sha; do
    [[ $local_sha == "$zero" ]] && continue # deleting a remote ref
    check_text "ref name" "$local_ref $remote_ref"
    if [[ $remote_sha == "$zero" ]]; then
      check_commits "$local_sha" --not --remotes
    else
      check_commits "$remote_sha..$local_sha"
    fi
  done
fi

echo "private-terms: $hits hit(s); $commits commit(s) checked ($mode mode)."
[[ $hits -eq 0 ]]
