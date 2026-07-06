#!/usr/bin/env bash
set -u
NAME="${1:?usage: create-github-repo.sh <name> <private|public>}"
VIS="${2:-private}"

# 1. Ensure remote repo (idempotent)
if gh repo view "$NAME" >/dev/null 2>&1; then
  echo "gh: repo $NAME exists, reusing"
else
  gh repo create "$NAME" "--$VIS" --source=. --remote=origin --push=false >/dev/null 2>&1 \
    || { echo "gh: repo create failed" >&2; exit 1; }
  echo "gh: repo $NAME created"
fi

# 2. Ensure origin points at it
url="$(gh repo view "$NAME" --json url -q .url 2>/dev/null)"
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$(gh repo view "$NAME" --json sshUrl -q .sshUrl 2>/dev/null)" 2>/dev/null || true
fi

# 3. Ensure main + dev branches and push both
git branch -M main
git push -u origin main >/dev/null 2>&1 || echo "gh: main push skipped/failed (continuing)"
if ! git show-ref --verify --quiet refs/heads/dev; then git branch dev; fi
git push -u origin dev >/dev/null 2>&1 || echo "gh: dev push skipped/failed (continuing)"

echo "$url"
