#!/usr/bin/env bash
set -euo pipefail

# autoresearch-finalize — creates independent branches from an autoresearch session
#
# Usage: finalize.sh <groups.json>
#
# groups.json format:
# {
#   "base": "<full merge-base commit hash>",
#   "trunk": "main",
#   "final_tree": "<full HEAD hash of autoresearch branch>",
#   "goal": "short-slug",
#   "groups": [
#     {
#       "title": "Parallelize test groups",
#       "body": "Use forks instead of threads...\n\nExperiments: #3, #5\nMetric: 42.3s → 38.1s (-9.9%)",
#       "last_commit": "<full commit hash>",
#       "slug": "parallel-tests"
#     }
#   ]
# }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

DATA_DIR=""
ORIG_BRANCH=""
TRUNK=""
BASE=""
FINAL_TREE=""
GOAL=""
GROUP_COUNT=""
STASHED=false
CREATED_BRANCHES=()
declare -a GROUP_BRANCH

warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${GREEN}$1${NC}"; }
cleanup_data() { if [ -d "${DATA_DIR:-}" ]; then rm -rf "$DATA_DIR"; fi; }
fail() { cleanup_data; echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }

# Session artifacts are matched by basename so they're excluded regardless of
# directory depth — autoresearch runs may happen in subdirectories and none
# should leak into PR branches.
is_session_file() {
  local base
  base=$(basename "$1")
  case "$base" in autoresearch.*) return 0;; *) return 1;; esac
}

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

parse_groups() {
  local groups_file="$1"
  [ -f "$groups_file" ] || fail "$groups_file not found"

  # Serialize JSON fields into flat files so bash can consume them without jq.
  # Ruby is already a plugin dependency, so no new dep required.
  DATA_DIR=$(mktemp -d)
  ruby -rjson -e "
config = JSON.parse(File.read('$groups_file'))
out = '$DATA_DIR'
File.write(\"#{out}/base\", config['base'])
File.write(\"#{out}/trunk\", config['trunk'] || 'main')
File.write(\"#{out}/final_tree\", config['final_tree'])
File.write(\"#{out}/goal\", config['goal'])
File.write(\"#{out}/count\", config['groups'].length.to_s)
config['groups'].each_with_index do |g, i|
  File.write(\"#{out}/#{i}.title\", g['title'])
  File.write(\"#{out}/#{i}.body\", g['body'])
  File.write(\"#{out}/#{i}.last_commit\", g['last_commit'])
  File.write(\"#{out}/#{i}.slug\", g['slug'])
end
" || fail "Failed to parse $groups_file — check JSON syntax."

  BASE=$(cat "$DATA_DIR/base")
  TRUNK=$(cat "$DATA_DIR/trunk")
  FINAL_TREE=$(cat "$DATA_DIR/final_tree")
  GOAL=$(cat "$DATA_DIR/goal")
  GROUP_COUNT=$(cat "$DATA_DIR/count")
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

assert_on_feature_branch() {
  ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  [ -n "$ORIG_BRANCH" ] || fail "Detached HEAD — switch to the autoresearch branch first."
  [ "$ORIG_BRANCH" != "$TRUNK" ] || fail "On trunk ($TRUNK) — switch to the autoresearch branch first."
}

assert_commits_exist() {
  git rev-parse "$BASE" >/dev/null 2>&1 || fail "Base commit $BASE not found."
  git rev-parse "$FINAL_TREE" >/dev/null 2>&1 || fail "Final tree commit $FINAL_TREE not found."
}

collect_group_files() {
  local group_index="$1" prev_commit="$2"
  local last_commit

  last_commit=$(cat "$DATA_DIR/$group_index.last_commit")
  git cat-file -t "$last_commit" 2>/dev/null | grep -q "commit" \
    || fail "Group $((group_index+1)) last_commit $last_commit not found. Use full hashes (git rev-parse <short>)."

  local changed_file
  : > "$DATA_DIR/$group_index.files"
  while IFS= read -r -d '' changed_file; do
    [ -n "$changed_file" ] || continue
    is_session_file "$changed_file" || echo "$changed_file" >> "$DATA_DIR/$group_index.files"
  done < <(git diff --name-only -z "$prev_commit" "$last_commit")
}

assert_no_overlapping_files() {
  local new_files_path="$1" seen_files_path="$2"
  [ -s "$new_files_path" ] || return 0
  [ -s "$seen_files_path" ] || return 0
  local candidate
  while IFS= read -r candidate; do
    if grep -qxF "$candidate" "$seen_files_path"; then
      fail "File '$candidate' appears in multiple groups. Merge the overlapping groups and retry."
    fi
  done < "$new_files_path"
}

assert_branch_available() {
  local branch_name="$1"
  if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    fail "Branch '$branch_name' already exists. Delete it first or use a different goal slug."
  fi
}

# Git stores refs as files, so a branch named 'foo/bar' (a file at
# refs/heads/foo/bar) blocks creating any descendant like 'foo/bar/baz'
# (would need refs/heads/foo/bar/ as a directory). The most common case
# is the source branch sharing a path prefix with the generated PR
# branches — e.g., source 'autoresearch/sign-throughput' blocks
# 'autoresearch/sign-throughput/01-…'. Detect this in preflight so the
# user gets a clear instruction instead of a cryptic git error mid-run.
assert_namespace_available() {
  local branch_name="$1"
  local prefix="${branch_name%/*}"
  while [ "$prefix" != "$branch_name" ]; do
    if git rev-parse --verify "refs/heads/$prefix" >/dev/null 2>&1; then
      fail "Branch '$prefix' exists and blocks creating '$branch_name' — git stores refs as files, so a ref named '$prefix' cannot have descendants. Rename it first: git branch -m '$prefix' '${prefix}-source'"
    fi
    branch_name="$prefix"
    prefix="${prefix%/*}"
  done
}

preflight() {
  echo ""
  info "═══ Preflight ═══"
  echo ""

  assert_on_feature_branch
  assert_commits_exist

  local prev_commit="$BASE"
  local all_seen_path="$DATA_DIR/all_seen_files"
  : > "$all_seen_path"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    collect_group_files "$i" "$prev_commit"
    assert_no_overlapping_files "$DATA_DIR/$i.files" "$all_seen_path"
    cat "$DATA_DIR/$i.files" >> "$all_seen_path"

    local group_number branch_name
    group_number=$(printf "%02d" $((i + 1)))
    branch_name="autoresearch/${GOAL}/${group_number}-$(cat "$DATA_DIR/$i.slug")"
    assert_branch_available "$branch_name"
    assert_namespace_available "$branch_name"
    GROUP_BRANCH[$i]=""

    prev_commit=$(cat "$DATA_DIR/$i.last_commit")
  done

  assert_branch_available "autoresearch/${GOAL}/verify-tmp"
  assert_namespace_available "autoresearch/${GOAL}/verify-tmp"

  info "Preflight passed."
  echo "  Branch:     $ORIG_BRANCH"
  echo "  Base:       ${BASE:0:12}"
  echo "  Groups:     $GROUP_COUNT"
}

# ---------------------------------------------------------------------------
# Create branches
# ---------------------------------------------------------------------------

rollback_on_failure() {
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then return; fi

  echo ""
  echo -e "${RED}FAILED — rolling back...${NC}"
  git reset --quiet HEAD -- . 2>/dev/null || true
  # Iterate only when non-empty: bash < 4.4 + set -u treats "${arr[@]}"
  # on an empty array as unbound, so a failure before any branch was
  # created would explode the rollback itself.
  if [ "${#CREATED_BRANCHES[@]}" -gt 0 ]; then
    for branch in "${CREATED_BRANCHES[@]}"; do
      git branch -D "$branch" 2>/dev/null || true
    done
  fi
  if [ -n "${ORIG_BRANCH:-}" ]; then
    git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  fi
  if [ "$STASHED" = true ]; then
    git stash pop --quiet 2>/dev/null \
      || echo -e "${YELLOW}⚠ Could not restore stashed changes. Run 'git stash list' to recover.${NC}"
  fi
  cleanup_data
  echo -e "${RED}Rolled back to '$ORIG_BRANCH'. No branches left behind.${NC}"
}

stash_if_dirty() {
  if ! git diff --quiet 2>/dev/null \
    || ! git diff --cached --quiet 2>/dev/null \
    || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    warn "Stashing uncommitted changes..."
    git stash -u
    STASHED=true
  fi
}

create_group_branch() {
  local i="$1"
  local title body last_commit slug files group_number branch_name

  title=$(cat "$DATA_DIR/$i.title")
  body=$(cat "$DATA_DIR/$i.body")
  last_commit=$(cat "$DATA_DIR/$i.last_commit")
  slug=$(cat "$DATA_DIR/$i.slug")
  local files_path="$DATA_DIR/$i.files"

  group_number=$(printf "%02d" $((i + 1)))
  branch_name="autoresearch/${GOAL}/${group_number}-${slug}"

  info "[$group_number/$GROUP_COUNT] $title"

  if [ ! -s "$files_path" ]; then
    warn "No files changed — skipping this group"
    GROUP_BRANCH[$i]="skipped"
    return
  fi

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$branch_name"

  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    git checkout "$last_commit" -- "$changed_file"
  done < "$files_path"
  git commit -m "$title" -m "$body"

  CREATED_BRANCHES+=("$branch_name")
  GROUP_BRANCH[$i]="$branch_name"
  echo "  Branch: $branch_name"
  echo "  Files: $(tr '\n' ' ' < "$files_path")"
  echo ""
}

create_branches() {
  echo ""
  info "═══ Creating branches ═══"
  echo ""

  trap rollback_on_failure EXIT
  stash_if_dirty

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    create_group_branch "$i"
  done

  info "Created ${#CREATED_BRANCHES[@]} branches (all from merge-base, independent):"
  if [ "${#CREATED_BRANCHES[@]}" -gt 0 ]; then
    for branch in "${CREATED_BRANCHES[@]}"; do echo "  $branch"; done
  fi

  trap - EXIT
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

verify_union_matches_original() {
  local verify_branch="autoresearch/${GOAL}/verify-tmp"

  git checkout "$BASE" --quiet --detach 2>/dev/null || git checkout "$BASE" --quiet
  git checkout -b "$verify_branch"

  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local last_commit
    last_commit=$(cat "$DATA_DIR/$i.last_commit")
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      git checkout "$last_commit" -- "$changed_file"
    done < "$DATA_DIR/$i.files"
  done
  git commit --allow-empty -m "verify: union of all groups" --quiet

  local non_session_diff=""
  for changed_file in $(git diff --name-only HEAD "$FINAL_TREE" 2>/dev/null); do
    is_session_file "$changed_file" || non_session_diff="$non_session_diff $changed_file"
  done

  git checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true
  git branch -D "$verify_branch" 2>/dev/null || true

  if [ -n "$non_session_diff" ]; then
    echo -e "${RED}✗ Union of groups differs from autoresearch branch!${NC}"
    echo "  Files:$non_session_diff"
    return 1
  fi

  echo -e "${GREEN}✓ Union of all groups matches original autoresearch branch.${NC}"
  return 0
}

verify_no_session_artifacts() {
  local clean=true
  if [ "${#CREATED_BRANCHES[@]}" -gt 0 ]; then
    for branch in "${CREATED_BRANCHES[@]}"; do
      for changed_file in $(git diff-tree --no-commit-id --name-only -r "$(git rev-parse "$branch")" 2>/dev/null); do
        if is_session_file "$changed_file"; then
          echo -e "${RED}✗ Session artifact '$changed_file' in branch $branch!${NC}"
          clean=false
        fi
      done
    done
  fi

  if [ "$clean" = true ]; then
    echo -e "${GREEN}✓ No session artifacts in any branch.${NC}"
    return 0
  fi
  return 1
}

verify_no_empty_commits() {
  local errors=0
  if [ "${#CREATED_BRANCHES[@]}" -gt 0 ]; then
    for branch in "${CREATED_BRANCHES[@]}"; do
      local commit diff
      commit=$(git rev-parse "$branch" 2>/dev/null)
      diff=$(git diff-tree --no-commit-id --name-only -r "$commit" 2>/dev/null || echo "")
      if [ -z "$diff" ]; then
        echo -e "${RED}✗ Empty commit in $branch${NC}"
        errors=$((errors + 1))
      fi
    done
  fi
  return $errors
}

warn_missing_metric_data() {
  if [ "${#CREATED_BRANCHES[@]}" -eq 0 ]; then return; fi
  for branch in "${CREATED_BRANCHES[@]}"; do
    local msg short
    msg=$(git log -1 --format="%B" "$branch" 2>/dev/null || echo "")
    if ! echo "$msg" | grep -qiE '(metric|→|->|%\))'; then
      short=$(git log -1 --oneline "$branch" 2>/dev/null | head -c 80)
      warn "Commit $short — no metric data in message"
    fi
  done
}

verify_branches() {
  echo ""
  info "═══ Verifying ═══"
  echo ""

  local errors=0

  verify_union_matches_original || errors=$((errors + 1))
  verify_no_session_artifacts || errors=$((errors + 1))
  verify_no_empty_commits || errors=$((errors + $?))
  warn_missing_metric_data

  echo ""
  if [ $errors -gt 0 ]; then
    echo -e "${RED}Verification failed with $errors error(s).${NC}"
    echo -e "${RED}Branches are intact — inspect and fix manually, or delete and retry.${NC}"
    if [ "${#CREATED_BRANCHES[@]}" -gt 0 ]; then
      echo "  Branches: ${CREATED_BRANCHES[*]}"
    fi
    echo "  You are on: $(git branch --show-current 2>/dev/null || echo 'detached')"
    cleanup_data
    exit 1
  fi
  info "✓ All checks passed."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo ""
  info "═══ Summary ═══"
  echo ""

  echo "Goal: $GOAL"
  echo "Base: ${BASE:0:12}"
  echo "Source branch: $ORIG_BRANCH"
  echo ""

  echo "Branches:"
  for i in $(seq 0 $((GROUP_COUNT - 1))); do
    local title body branch group_number
    title=$(cat "$DATA_DIR/$i.title")
    body=$(cat "$DATA_DIR/$i.body")
    branch="${GROUP_BRANCH[$i]:-skipped}"
    group_number=$(printf "%02d" $((i + 1)))
    echo ""
    echo "  $group_number. $title"
    echo "     Branch: $branch"
    echo "     Files: $(tr '\n' ' ' < "$DATA_DIR/$i.files")"
    echo ""
    echo "$body" | sed 's/^/     /'
  done

  echo ""
  echo "Cleanup — after merging, delete the autoresearch branch and session files:"
  echo ""
  echo "  git branch -D $ORIG_BRANCH"
  echo "  rm -f autoresearch.jsonl autoresearch.sh autoresearch.md autoresearch.ideas.md"

  if [ -f "autoresearch.ideas.md" ]; then
    echo ""
    echo "Ideas backlog (from autoresearch.ideas.md):"
    echo ""
    sed 's/^/  /' autoresearch.ideas.md
  fi

  echo ""
  if [ "$STASHED" = true ]; then
    warn "Changes were stashed. Run 'git stash pop' to restore or 'git stash drop' to discard."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <groups.json>"
    exit 1
  fi

  parse_groups "$1"
  preflight
  create_branches
  verify_branches
  print_summary
  cleanup_data
}

# Skip main when sourced (e.g. by tests that exercise individual functions).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
