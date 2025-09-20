#!/usr/bin/env bash
# export-to-github.sh
set -euo pipefail
[[ $# -lt 2 || $# -gt 3 ]] && { echo "Usage: $0 <github-username> <repo-name> [--ssh]"; exit 2; }
GH_USER="$1"; REPO="$2"; USE_SSH="${3:-}"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Run inside repo."; exit 1; }
branch="$(git rev-parse --abbrev-ref HEAD || echo HEAD)"
if [[ "$branch" == "HEAD" ]]; then git show-ref --verify --quiet refs/heads/main || git branch main; git checkout main; branch="main"; fi
git add -A; git commit -m "chore: sync before GitHub export" || true
git tag -l | grep -qx "working" || git tag working
remote_url="https://github.com/${GH_USER}/${REPO}.git"; [[ "$USE_SSH" == "--ssh" ]] && remote_url="git@github.com:${GH_USER}/${REPO}.git"
git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$remote_url" || git remote add origin "$remote_url"
if command -v gh >/dev/null 2>&1; then gh repo view "${GH_USER}/${REPO}" >/dev/null 2>&1 || gh repo create "${GH_USER}/${REPO}" --private -y >/dev/null; else echo "Note: install GitHub CLI or pre-create the repo."; fi
git push -u origin "$branch"
git push origin --tags
echo "Exported to $remote_url"
