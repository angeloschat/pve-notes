#!/usr/bin/env bash
# bump.sh — semantic version bumper
set -euo pipefail
BUMP_TYPE="${1:-}"; DRY_RUN="0"; DO_PUSH="0"; ALLOW_DIRTY="0"
shift || true
while (( "$#" )); do case "$1" in -n|--dry-run) DRY_RUN="1";; -p|--push) DO_PUSH="1";; --allow-dirty) ALLOW_DIRTY="1";; *) echo "Unknown option: $1" >&2; exit 2;; esac; shift || true; done
[[ "$BUMP_TYPE" =~ ^(patch|minor|major)$ ]] || { echo "Usage: $0 patch|minor|major [--dry-run|-n] [--push|-p] [--allow-dirty]"; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not in a git repo." >&2; exit 1; }
[[ "$ALLOW_DIRTY" == "1" || -z "$(git status --porcelain)" ]] || { echo "Working tree not clean. Use --allow-dirty."; exit 1; }
latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1 || true)"
if [[ -n "$latest_tag" ]]; then CURRENT="${latest_tag#v}"; else CURRENT="$(git ls-files '*.sh' | xargs -r grep -h -oE 'SCRIPT_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"' | head -n1 | sed -E 's/.*\"([0-9]+\.[0-9]+\.[0-9]+)\".*/\1/')"; fi
[[ -n "${CURRENT:-}" ]] || CURRENT="0.0.0"
IFS='.' read -r MA MI PA <<<"$CURRENT"
case "$BUMP_TYPE" in patch) PA=$((PA+1));; minor) MI=$((MI+1)); PA=0;; major) MA=$((MA+1)); MI=0; PA=0;; esac
NEW="${MA}.${MI}.${PA}"
echo "Current: v$CURRENT -> New: v$NEW"
mapfile -t files_to_update < <(git ls-files '*.sh' | xargs -r grep -l 'SCRIPT_VERSION="' || true)
[[ "${#files_to_update[@]}" -gt 0 ]] || echo "Warning: no SCRIPT_VERSION found."
[[ "$DRY_RUN" == "1" ]] && { echo "[dry-run] would update SCRIPT_VERSION and tag v$NEW"; exit 0; }
for f in "${files_to_update[@]}"; do sed -i -E "s/^(SCRIPT_VERSION=)\"[0-9]+\.[0-9]+\.[0-9]+\"/\1\"$NEW\"/g" "$f"; done
git add "${files_to_update[@]}" 2>/dev/null || true
git commit -m "chore(release): bump version to v$NEW"
git tag -a "v$NEW" -m "Release v$NEW"
[[ "$DO_PUSH" == "1" ]] && { git push && git push --tags; echo "Pushed."; } || echo "Created tag v$NEW (not pushed)."
