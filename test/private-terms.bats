#!/usr/bin/env bats
load helpers

make_repository() {
  export TMPDIR="$BATS_TEST_TMPDIR"
  export GIT_AUTHOR_NAME=Example GIT_COMMITTER_NAME=Example
  export GIT_AUTHOR_EMAIL=placeholder GIT_COMMITTER_EMAIL=placeholder
  git init -q "$BATS_TEST_TMPDIR/repository"
  cd "$BATS_TEST_TMPDIR/repository"
  printf 'clean\n' > tracked
  git add tracked
  git commit -q -m 'Add example'
  export PRIVATE_TERMS_FILE="$BATS_TEST_TMPDIR/terms"
  printf '# placeholder terms\n\nrestricted-token\n' > "$PRIVATE_TERMS_FILE"
}

@test "private terms checker is a no-op without a terms file" {
  run env -u PRIVATE_TERMS_FILE "$GRM_ROOT/scripts/check-no-private-terms.sh" --worktree
  [ "$status" -eq 0 ]
  [[ $output == *'no-op'* ]]
}

@test "private terms checker rejects hits in tracked files" {
  make_repository
  printf 'restricted-token\n' > tracked
  run "$GRM_ROOT/scripts/check-no-private-terms.sh" --worktree
  [ "$status" -eq 1 ]
  [[ $output == *'tracked files'* ]]
}

@test "private terms checker rejects outgoing commit messages in hook mode" {
  make_repository
  git commit -q --allow-empty -m 'Add restricted-token example'
  sha=$(git rev-parse HEAD)
  run bash -c 'printf "refs/heads/example %s refs/heads/example %040d\n" "$1" 0 | "$GRM_ROOT/scripts/check-no-private-terms.sh"' _ "$sha"
  [ "$status" -eq 1 ]
  [[ $output == *'message of'* ]]
}

@test "private terms checker accepts clean trees and messages" {
  make_repository
  run "$GRM_ROOT/scripts/check-no-private-terms.sh" --worktree
  [ "$status" -eq 0 ]
  [[ $output == *'0 hit(s)'* ]]
}

@test "private terms checker rejects author names in hook and worktree modes" {
  make_repository
  GIT_AUTHOR_NAME=restricted-token git commit -q --allow-empty -m 'Add example change'
  sha=$(git rev-parse HEAD)
  run "$GRM_ROOT/scripts/check-no-private-terms.sh" --worktree
  [ "$status" -eq 1 ]
  [[ $output == *'author/committer name of'* && $output == *'restricted-token'* ]]
  run bash -c 'printf "refs/heads/example %s refs/heads/example %040d\n" "$1" 0 | "$GRM_ROOT/scripts/check-no-private-terms.sh"' _ "$sha"
  [ "$status" -eq 1 ]
  [[ $output == *'author/committer name of'* && $output == *'restricted-token'* ]]
}
