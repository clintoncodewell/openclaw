#!/usr/bin/env bash
# sync-upstream.sh — pull the latest openclaw/openclaw into this fork's fork/main branch.
#
# Model: origin = clintoncodewell/openclaw (your fork), upstream = openclaw/openclaw.
# Your changes live on `fork/main`; upstream lands on `upstream/main`. We MERGE upstream
# into fork/main (not rebase) so the fork keeps a stable history you can always push.
#
# Usage:
#   fork/sync-upstream.sh           # fetch + merge upstream/main into fork/main, then drift-check
#   fork/sync-upstream.sh --check   # fetch + show what's new upstream, no merge
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
BRANCH="fork/main"

echo "==> Fetching upstream"
git fetch upstream --prune

AHEAD="$(git rev-list --count fork/main..upstream/main 2>/dev/null || echo '?')"
echo "==> upstream/main is ${AHEAD} commits ahead of ${BRANCH}"

if [[ "${1:-}" == "--check" ]]; then
  echo "==> New upstream commits:"
  git log --oneline "fork/main..upstream/main" | head -40 || true
  echo "==> iOS-relevant upstream changes since fork/main:"
  git log --oneline "fork/main..upstream/main" -- apps/ios apps/shared/OpenClawKit apps/swabble | head -40 || true
  exit 0
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${CURRENT}" != "${BRANCH}" ]]; then
  echo "==> Switching to ${BRANCH} (was ${CURRENT})"
  git checkout "${BRANCH}"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit or stash before syncing." >&2
  git status --short >&2
  exit 1
fi

echo "==> Merging upstream/main into ${BRANCH}"
git merge --no-edit upstream/main

# Drift check: our project.fork.yml mirrors the upstream OpenClaw app target. If upstream
# changed that target (new SPM dep, build setting, Info.plist key), mirror it by hand.
echo ""
echo "==> Drift check: did upstream touch the iOS app target config?"
if git diff --quiet "ORIG_HEAD..HEAD" -- apps/ios/project.yml; then
  echo "    apps/ios/project.yml unchanged — project.fork.yml likely still in sync."
else
  echo "    apps/ios/project.yml CHANGED upstream. Review the OpenClaw target and mirror any new"
  echo "    deps/settings/Info.plist keys into apps/ios/project.fork.yml:"
  echo "      git diff ORIG_HEAD..HEAD -- apps/ios/project.yml"
fi

echo ""
echo "==> Regenerate + rebuild:  fork/build-ios.sh sim   (then 'open' for device)"
echo "==> Push your synced fork:  git push origin ${BRANCH}"
