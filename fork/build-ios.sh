#!/usr/bin/env bash
# build-ios.sh — one command to build Clinton's free-team OpenClaw iOS fork.
#
# Generates the single-target project from apps/ios/project.fork.yml (see that file
# and ../FORK.md for the why) and then opens / builds / installs it.
#
# Usage:
#   fork/build-ios.sh open      # configure signing + generate, then open Xcode   (best for DEVICE installs)
#   fork/build-ios.sh sim       # configure signing + generate + build for the iOS Simulator (no signing)
#   fork/build-ios.sh gen       # configure signing + generate only
#   fork/build-ios.sh device    # CLI build+install to a connected iPhone (free-team, interactive provisioning)
#
# Override the signing team with:  OPENCLAW_FORK_TEAM=XXXXXXXXXX fork/build-ios.sh ...
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
# HJH7DK6VNJ = the free personal team that has a working local Apple Development cert
# (the one Dropnote signs with). Override via OPENCLAW_FORK_TEAM if you switch Apple IDs.
TEAM="${OPENCLAW_FORK_TEAM:-HJH7DK6VNJ}"
MODE="${1:-open}"

echo "==> Configuring signing for team ${TEAM} (free personal, single-target, no push/app-groups)"
IOS_DEVELOPMENT_TEAM="${TEAM}" "${ROOT_DIR}/scripts/ios-configure-signing.sh"

# Version vars come from the checked-in apps/ios/Config/Version.xcconfig; the optional
# build/Version.xcconfig writer needs `tsx` (pnpm install) so we just skip it if absent.
if "${ROOT_DIR}/scripts/ios-write-version-xcconfig.sh" >/dev/null 2>&1; then
  echo "==> Wrote build/Version.xcconfig"
else
  echo "==> Skipping build/Version.xcconfig (using checked-in Config/Version.xcconfig)"
fi

echo "==> Generating OpenClaw.xcodeproj from project.fork.yml"
cd "${IOS_DIR}"
xcodegen generate --spec project.fork.yml

case "${MODE}" in
  gen)
    echo "==> Done (project generated)."
    ;;
  open)
    echo "==> Opening Xcode. Select the OpenClaw scheme + your iPhone, then Run."
    echo "    (Free-team device provisioning is interactive — Xcode handles the profile + trust prompt.)"
    open OpenClaw.xcodeproj
    ;;
  sim)
    echo "==> Building for the iOS Simulator (no signing required)"
    xcodebuild -project OpenClaw.xcodeproj -scheme OpenClaw -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/DerivedData \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    echo "==> Building + installing to a connected iPhone (free-team auto-provisioning)"
    xcodebuild -project OpenClaw.xcodeproj -scheme OpenClaw -configuration Debug \
      -destination 'generic/platform=iOS' \
      -allowProvisioningUpdates \
      -derivedDataPath build/DerivedData \
      build
    echo "    If install didn't happen automatically, run from Xcode (fork/build-ios.sh open)."
    ;;
  *)
    echo "Unknown mode: ${MODE} (use: open | sim | gen | device)" >&2
    exit 1
    ;;
esac
