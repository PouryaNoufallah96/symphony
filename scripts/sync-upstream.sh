#!/usr/bin/env bash
#
# Safely sync this fork's customization branch with upstream openai/symphony main.
#
# Guarantees the fork's customizations never end up in a broken state:
#   1. Refuses to run on a dirty working tree.
#   2. Fetches upstream and shows exactly what is incoming.
#   3. Pre-checks for conflicts before touching the tree.
#   4. Merges WITHOUT committing, then runs the FULL test suite.
#   5. Test failure  -> `git merge --abort` (tree restored, nothing committed).
#      Merge conflict -> stops with instructions (never auto-resolves).
#      All green      -> commits the merge and rebuilds the escript.
#
# Push is never automatic. Pass --push to push to the fork remote on success.
#
# Usage:
#   scripts/sync-upstream.sh            # sync + test, leave commit local
#   scripts/sync-upstream.sh --push     # also push to the fork remote on success
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elixir_dir="$repo_root/elixir"
branch="${SYNC_BRANCH:-ultrabusiness-team-key}"
upstream="${SYNC_UPSTREAM:-origin}"          # openai/symphony
fork="${SYNC_FORK:-fork}"                     # PouryaNoufallah96/symphony
test_cmd="${SYNC_TEST_CMD:-mix test}"         # full suite by default
do_push=0
[ "${1:-}" = "--push" ] && do_push=1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$repo_root"

# 1. Preconditions ----------------------------------------------------------
[ -d "$elixir_dir" ] || die "elixir dir not found at $elixir_dir"
command -v mise >/dev/null 2>&1 || die "mise is not on PATH"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "$branch" ] || die "on branch '$current_branch', expected '$branch' (set SYNC_BRANCH to override)"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short
  die "working tree has uncommitted changes — commit or stash first"
fi

# 2. Fetch + report ---------------------------------------------------------
say "Fetching $upstream/main"
git fetch "$upstream" main

incoming="$(git rev-list --count "HEAD..$upstream/main")"
if [ "$incoming" -eq 0 ]; then
  say "Already up to date with $upstream/main — nothing to sync."
  exit 0
fi

say "$incoming new upstream commit(s):"
git --no-pager log --oneline "HEAD..$upstream/main"

# 3. Conflict pre-check (read-only) -----------------------------------------
say "Pre-checking for merge conflicts (no changes made yet)"
if git merge-tree --write-tree "$upstream/main" HEAD >/dev/null 2>&1; then
  echo "No conflicts expected — merge should be clean."
else
  echo "Conflicts expected. The merge will stop for you to resolve them manually."
fi

# 4. Merge without committing ----------------------------------------------
say "Merging $upstream/main (no commit yet)"
if ! git merge --no-commit --no-ff "$upstream/main"; then
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo
    echo "Conflicts in:"
    git diff --name-only --diff-filter=U | sed 's/^/  - /'
    cat <<EOF

Resolve them so your customizations win where they overlap (these are usually
additive — keep both sides), then verify and commit:

  # ...edit the files above to remove conflict markers...
  git add -A
  cd elixir && mise exec -- $test_cmd     # MUST be green
  cd "$repo_root" && git commit --no-edit
  cd elixir && mise exec -- mix build      # rebuild escript

The merge is left in progress. To bail out entirely: git merge --abort
EOF
    exit 2
  fi
fi

# 5. Gate on the full test suite -------------------------------------------
say "Running tests: $test_cmd  (failure auto-rolls-back the merge)"
if ! ( cd "$elixir_dir" && mise exec -- $test_cmd ); then
  say "Tests FAILED — aborting merge, restoring pre-sync state"
  git merge --abort
  die "sync rolled back; your branch is unchanged. Investigate the upstream change before retrying."
fi

# 6. Commit + rebuild -------------------------------------------------------
say "Tests green — committing merge"
git commit --no-edit

say "Rebuilding escript"
( cd "$elixir_dir" && mise exec -- mix build )

if [ "$do_push" -eq 1 ]; then
  say "Pushing to $fork/$branch"
  git push "$fork" "$branch"
else
  say "Done (local). Review, then push with:  git push $fork $branch"
fi

say "Synced with $upstream/main and tests pass — customizations intact."
