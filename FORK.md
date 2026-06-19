# Clinton's OpenClaw fork — iOS build + upstream-merge guide

This is a personal fork of [`openclaw/openclaw`](https://github.com/openclaw/openclaw). The goal:
run the **iOS app** on a personal iPhone against my own gateway, and keep pulling in upstream
improvements as the (super-alpha) app evolves.

- `origin`   → `clintoncodewell/openclaw` (this fork)
- `upstream` → `openclaw/openclaw` (the source project)
- Working branch → **`fork/main`** (my changes live here; `main` tracks upstream untouched)

## Why a fork spec instead of the normal build

The canonical `apps/ios/project.yml` builds **five targets** (app + Share Extension +
Activity/Live-Activity Widget + Watch app + Watch extension) and signs an `aps-environment`
(push) entitlement. Those need **Push Notifications + App Groups** capabilities and **>3 App IDs** —
none of which a **free personal Apple team** can provision (free teams also expire profiles every
7 days and cap at 3 App IDs).

So this fork adds **`apps/ios/project.fork.yml`**: the **OpenClaw app target only**, with no push
entitlement and no extensions. The app's own Sources use no App Groups, read the bundle id
dynamically, and degrade gracefully without push/watch/widget (APNs registration just fails its
callback — see `apps/ios/README.md` → "APNs Expectations"). A single-target build is therefore sound.

**What you give up** on the free-team build: background push delivery, the share-sheet extension,
the Watch app, and the Live-Activity widget. The upstream README already lists these as
foreground-first / not-yet-reliable, so for "talk to my gateway from my phone" this loses little.
To get them back, use a **paid** Apple Developer team and the normal `pnpm ios:open` flow instead.

## Build it

```bash
fork/build-ios.sh sim      # build for the iOS Simulator (no signing) — fastest sanity check
fork/build-ios.sh open     # configure signing + generate, then open Xcode → Run on your iPhone
```

`build-ios.sh` runs `scripts/ios-configure-signing.sh` (pinned to team **HJH7DK6VNJ**, the free
personal team with a working local cert), then `xcodegen generate --spec project.fork.yml`.

**Device install (free team):** easiest via Xcode — `fork/build-ios.sh open`, pick the `OpenClaw`
scheme + your iPhone, Run. Xcode handles the interactive free-team provisioning + the on-device
"trust developer" prompt (Settings → General → VPN & Device Management). Rebuild every ~7 days when
the free provisioning profile expires. Override the team with `OPENCLAW_FORK_TEAM=XXXXXXXXXX`.

Toolchain: Xcode 16+/26, `xcodegen` (`brew install xcodegen`). The fork spec drops the
swiftformat/swiftlint pre-build lint scripts, so you do **not** need those installed (the canonical
`project.yml` build does — `brew install swiftformat swiftlint`).

## Connect to my gateway

The app connects to an OpenClaw Gateway as a `role: node`. Two ways in:

### A) Public — no Tailscale on the phone (recommended), via Tailscale Funnel

The gateway is exposed publicly over TLS by Tailscale Funnel:
**`wss://clinton-dev-vm-1.tail405bf7.ts.net:8443`** → proxied to the gateway's `localhost:18789`.

- In the app: **Settings → Gateway → manual host** → host `clinton-dev-vm-1.tail405bf7.ts.net`,
  port **`8443`**, TLS **on**.
- Works from anywhere on the internet (verified: public-DNS → Funnel ingress → TLS 1.3 → gateway
  WS `101`). The real Let's Encrypt cert means the app can pin it and **autoconnect on launch**.
- The security boundary is now the gateway's **pairing + token auth**, not the tailnet — the gateway
  is internet-reachable. That's the trade for not needing Tailscale on every client.

Funnel admin (on `advisewell-vm`):
```bash
tailscale funnel --bg --https=8443 http://127.0.0.1:18789   # enable (persists)
tailscale funnel status                                      # show
tailscale funnel --https=8443 off                            # disable -> back to tailnet-only
```
Requires a Tailscale **Standard+** plan and the `funnel` node attribute enabled for the node
(one-time approve at `https://login.tailscale.com/f/funnel?node=<id>`). The separate `443 → :3100`
serve mapping is untouched.

### B) Tailnet-only (Tailscale required on the client)

host `100.65.245.83`, port `18789`, TLS **off** (the gateway's direct tailnet bind). The phone/Mac
must be on the tailnet; Bonjour discovery won't cross the tailnet, so use manual host/port.

### Pairing (once, either way)

On the gateway: `openclaw pair qr` (or `openclaw pair` for a setup code), scan/enter it in the app,
then approve: `openclaw devices approve <id>` + `openclaw nodes approve <id>`.
(On the VM the CLI needs `--url ws://100.65.245.83:18789 --token <gateway token>`.)

Verify: chat/talk round-trips, and `node.invoke` capabilities (camera, screen, location, etc.) work
in the foreground.

## Keep up with upstream

```bash
fork/sync-upstream.sh --check   # see what's new upstream (and what touched apps/ios)
fork/sync-upstream.sh           # fetch + merge upstream/main into fork/main + drift-check
git push origin fork/main       # publish the synced fork
```

**Drift to watch:** `project.fork.yml` is a hand-mirrored copy of the upstream `OpenClaw` app target.
It's a new file upstream never touches, so merges don't conflict on it — but if upstream adds an SPM
dependency, build setting, or Info.plist key to the app target in `project.yml`, mirror that change
into `project.fork.yml`. After a sync, `sync-upstream.sh` detects whether `project.yml` changed and
prints the exact `git diff <pre-merge-sha>..HEAD -- apps/ios/project.yml` command to run — it captures
the pre-merge SHA itself, so you don't rely on the global `ORIG_HEAD` (unreliable after prior merges).

## Fork-local files (everything this fork adds)

- `apps/ios/project.fork.yml` — single-target, push-free XcodeGen spec
- `fork/build-ios.sh` — configure signing + generate + open/build/install
- `fork/sync-upstream.sh` — fetch + merge upstream + drift check
- `FORK.md` — this file

`apps/ios/.local-signing.xcconfig` (the generated team/bundle-id override) is **git-ignored** and
stays local to this Mac.
