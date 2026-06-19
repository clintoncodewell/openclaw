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

# Version vars resolve from the checked-in apps/ios/Config/Version.xcconfig. The optional
# build/Version.xcconfig writer needs `tsx` (from `pnpm install`). Only skip when tsx is
# genuinely unavailable; otherwise run it for real so real failures (bad version metadata,
# refused symlinked build path) aren't silently swallowed.
if (cd "${ROOT_DIR}" && node --import tsx -e '' ) >/dev/null 2>&1; then
  echo "==> Writing build/Version.xcconfig"
  "${ROOT_DIR}/scripts/ios-write-version-xcconfig.sh"
else
  echo "==> tsx not installed (run 'pnpm install'); using checked-in Config/Version.xcconfig"
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
    # Resolve a connected iPhone/iPad via devicectl (CoreDevice). Unlike `xctrace list devices`,
    # devicectl does NOT list the host Mac, so we can't accidentally pick the Mac's UDID. The
    # `|| true` keeps `set -e`/pipefail from aborting before the friendly empty-result check.
    DEVJSON="$(mktemp)"
    xcrun devicectl list devices --json-output "${DEVJSON}" >/dev/null 2>&1 || true
    UDID="$(python3 - "${DEVJSON}" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    cp = dev.get("connectionProperties", {})
    dtype = (hw.get("deviceType") or "").lower()
    connected = (cp.get("tunnelState") or "").lower() == "connected"
    # Only pick a currently-connected iPhone/iPad (skip the host Mac + paired-but-absent devices).
    if dtype in ("iphone", "ipad") and connected and dev.get("identifier"):
        print(dev["identifier"]); break
PY
)"
    rm -f "${DEVJSON}"
    if [[ -z "${UDID}" ]]; then
      echo "ERROR: no connected iPhone/iPad found. Plug in + unlock the device and trust this Mac," >&2
      echo "       or use 'fork/build-ios.sh open' (Xcode Run handles the free-team trust prompt)." >&2
      exit 1
    fi
    echo "==> Building for connected device ${UDID} (free-team auto-provisioning)"
    xcodebuild -project OpenClaw.xcodeproj -scheme OpenClaw -configuration Debug \
      -destination "id=${UDID}" \
      -allowProvisioningUpdates \
      -derivedDataPath build/DerivedData \
      build
    APP_PATH="build/DerivedData/Build/Products/Debug-iphoneos/OpenClaw.app"
    echo "==> Installing ${APP_PATH} to ${UDID}"
    xcrun devicectl device install app --device "${UDID}" "${APP_PATH}"
    echo "==> Installed. First run only: trust the developer in"
    echo "    Settings > General > VPN & Device Management. (First-ever install is smoothest via"
    echo "    'fork/build-ios.sh open' + Xcode Run.)"
    ;;
  *)
    echo "Unknown mode: ${MODE} (use: open | sim | gen | device)" >&2
    exit 1
    ;;
esac
