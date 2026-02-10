#!/usr/bin/env bash
set -euo pipefail

GIT_DIR="$HOME/dusky"
WORK_TREE="$HOME"
BRANCH="main"

gitcmd=(git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE")

echo "[INFO] Fetching upstream..."
"${gitcmd[@]}" fetch upstream

echo "[INFO] Switching to $BRANCH..."
"${gitcmd[@]}" checkout "$BRANCH" >/dev/null 2>&1 || true

echo "[INFO] Merging upstream/$BRANCH into $BRANCH..."
if ! "${gitcmd[@]}" merge --no-edit "upstream/$BRANCH"; then
  echo "[ERROR] Merge conflict. Resolve conflicts, then run:"
  echo "  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE status"
  echo "  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE add -u"
  echo "  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE commit"
  echo "Or abort:"
  echo "  git --git-dir=$GIT_DIR --work-tree=$WORK_TREE merge --abort"
  exit 1
fi

echo "[INFO] Pushing to origin..."
"${gitcmd[@]}" push origin "$BRANCH"

echo "[OK] Upstream merged + pushed."
