# AGENTS.md — context for LLMs and coding agents

ListenTogether is a native macOS app (Swift / SwiftUI, SwiftPM, macOS 14+) that lets two people listen to the same song at the same moment when one uses **Qobuz** and the other **Apple Music**. Play, pause, seek, track changes and a shared "Up Next" queue are synced over a WebSocket relay. Read `README.md` for the user-facing description; this file is about how the code works and what to watch out for.

## Build, run, test

```sh
./build.sh                    # generates EmbeddedJS.swift, builds universal release app -> build/ListenTogether.app + .zip
OUT=build/next ./build.sh     # build elsewhere (use this if build/ListenTogether.app is running)
swift test                    # unit tests (needs EmbeddedJS.swift -> run ./build.sh once first)
```

- `Sources/ListenTogether/EmbeddedJS.swift` is **generated** by `build.sh` from `js/` and is gitignored. Edit the files in `js/`, never the generated file. On a fresh clone, run `./build.sh` before `swift build`/`swift test`.
- Release: push a `v<version>` tag. `.github/workflows/release.yml` runs `./build.sh <version>` (→ `dist/ListenTogether-<version>-macos.zip`, version written into Info.plist), `swift test`, `gh release create --generate-notes`, and pushes the cask from `packaging/cask.sh` to `uifi95/homebrew-tap` (needs the `HOMEBREW_TAP_TOKEN` secret). Same scheme as the sibling project `qobuz-now-playing`. Work goes through feature branches and PRs (`feat:` / `fix:` / `docs:` commit prefixes).
- `build.sh` bundles `cloudflared` (pinned `CF_VERSION`, SHA-256 checked, arm64+amd64 merged with `lipo`, cached in `.build/`) into `Contents/Helpers/`. To update it, change `CF_VERSION` and both `CF_SHA_*` (the digests are on the GitHub release assets). It adds ~40 MB to the zip.
- Icon: `packaging/make_icon.py` draws it on a 32×32 grid (standard library only) and writes `AppIcon.icns` (copied into the app by `build.sh`) and `AppIcon.png`. Edit the grid and re-run it; don't edit the images by hand.
- Cask: `packaging/cask.sh` uses current Homebrew syntax (`depends_on macos: :sonoma`, `postflight_steps` with `run` and `{{appdir}}`); the old `postflight do` block and `">= :sonoma"` strings are deprecated.
- Toolchain: Swift tools version 5.10, built with a Swift 6 toolchain. Ad-hoc signed (`codesign --sign -`), no notarization; recipients must right-click → Open the first time.
- Env vars: `LT_PROFILE=<name>` (separate UserDefaults suite, to run two copies on one Mac), `LT_DEBUG=1` (prints player state to stdout), `LT_TEST_DIR=<dir>` (test-command hook; also hides windows).
- CLI mode: `ListenTogether --host-room "Name"` hosts a room (relay + tunnel) without the player.

## Architecture

```
SyncEngine (MainActor, ObservableObject) ── RelayClient (URLSessionWebSocketTask) ── relay (HostServer in-app, or relay/server.mjs)
   │                                                                                     ▲
   ├─ QobuzPlayer ── CDPClient ── Node inspector of Qobuz (SIGUSR1) ── js/qobuz-host.js ─┐│
   │                                                    webContents.executeJavaScript ── js/qobuz-page.js (Redux store)
   └─ AppleMusicPlayer ── WKWebView (music.apple.com) ── js/apple.js (MusicKit.getInstance())
                                                       CloudflareTunnel (cloudflared quick tunnel) exposes HostServer
```

| File | Role |
| --- | --- |
| `SyncEngine.swift` | Core. Settings, room lifecycle (create/join/leave), receiving remote state, 500 ms `tick` that polls the local player, detects local changes, corrects drift, watches the app's queue, advances the shared queue, Apple volume. |
| `Models.swift` | `TrackInfo`, `PlayerSnapshot`, `SharedState` (the wire format), `MusicPlayer` protocol, `Matcher` (cross-service track matching). |
| `SharedQueue.swift` | `QueueItem`, `SharedQueue` (mergeable queue), `QueueDiff.additions` (detects Add to Queue vs Play Next from key lists). |
| `QobuzPlayer.swift` | Sends SIGUSR1 to Qobuz, finds the inspector port via `lsof`, installs the JS bridges over CDP, `call(name, arg)`. |
| `AppleMusicPlayer.swift` | Hidden window with WKWebView (Safari UA, FairPlay), sign-in popups, `callAsyncJavaScript` bridge, volume restore after reload. |
| `RelayClient.swift` | WebSocket with reconnect (backoff ≤10 s), ping/pong clock offset (min RTT sample). |
| `HostServer.swift` | Hand-written HTTP + WebSocket server on 127.0.0.1 (the in-app relay). Serves the invite page, `/download`, and the room socket; rejects wrong room codes. Also `InviteLink` parsing. |
| `CloudflareTunnel.swift` | Runs `cloudflared tunnel --url` (the copy bundled in `Contents/Helpers`, else one on PATH), parses the trycloudflare URL, waits for "Registered tunnel connection" and for public DNS (DoH) before handing out the link. |
| `CDPClient.swift` | Minimal Chrome DevTools Protocol client (`Runtime.evaluate`, `awaitPromise`). |
| `ListenTogetherApp.swift` | `@main`, AppDelegate (URL scheme `listentogether://`, window close doesn't quit), menus (⌘⇧P player, ⌘↑/⌘↓ Apple volume), `HostCLI`. |
| `ContentView.swift` | SwiftUI UI: service picker, Create Room / Join with Link / Own Relay tabs, now playing, Up Next list, activity log. |
| `js/qobuz-host.js` | Runs in Qobuz's Electron **main** process. `global.__listenTogether.call()`, serialized; play/pause via media-controls IPC and waits for the state to flip. |
| `js/qobuz-page.js` | Runs in Qobuz's `app.html` renderer. Finds the Redux store via React fiber, reads `player.*`, `playqueue.items`, plays via `REPLACE_PLAYQUEUE_FROM_RELEASE_EPIC`, Qobuz API search with the app's own `X-App-Id` + user token. Has a `VERSION`; a newer version disposes the older one. |
| `js/apple.js` | Drives MusicKit: `setQueue`, `play`, `pause`, `seekToTime`, `volume`, catalog search/ISRC lookup, queue keys via `queueItemsDidChange` + WeakMap. Has a `VERSION`. |
| `relay/server.mjs` | Standalone Node `ws` relay (default port 47900) for self-hosting instead of the in-app one. |

## Sync model

- **Shared timeline**: `SharedState` = track + playing + positionMs at relay-clock time `at`, plus `from`/`fromName`, `queue`, `removed`. Last writer wins. When someone joins, whoever is already in the room leads.
- **Clock**: offset from the ping with the smallest round trip. All times on the wire are relay-clock.
- **Local change detection**: polling every 500 ms (no events from Qobuz). Guards `ticking` / `applying` prevent echoing a remote change back as a local one.
- **Drift**: seek when off by more than 1.2 s.
- **Matching** (`Matcher`): ISRC first, then normalized title + artist + duration, score ≥ 5. Rejects live/remix/cover variants that reuse an ISRC.
- **Volume is never synced** (explicit user decision). Apple volume is local only, cubic taper (`gain = position³`), saved and re-applied when the web player reloads (MusicKit resets to 0.5).

## Shared queue

- `SharedQueue` is CRDT-like: items = union of everything added minus removed ids (`removed` keeps the last 500). Order is **computed**, not stored: Play Next items first (newest first), then Add to Queue items (oldest first), then `seq`, then `id`. So copies converge regardless of message order.
- Each player exposes `queueKeys()` (stable per-item keys in play order) and a `queueVersion` in its snapshot. `watchAppQueue` diffs keys when the version changes: `QueueDiff.additions` treats new keys followed by old keys as **Play Next**, new keys at the end as **Add to Queue**, and a queue with nothing in common with the previous one as a replacement (not queueing).
  - Qobuz key: `queueItemId|trackId|contextUuid`. Add to Queue = `completeQueue` (append, new context); Play Next = `insertIntoQueue` (after current, new context).
  - Apple key: WeakMap id per MusicKit queue item object (objects survive appends, are recreated on replace). Only `queue.userAddedItems` (autoplay ∞ songs are left out). The order can't tell Play Next from Add to Queue there (shared songs start as a one-song queue; Add to Queue goes in before the autoplay songs), so `js/apple.js` wraps the instance's `playNext`/`playLater` and reports how each item was added; `MusicPlayer.addedAsPlayNext` overrides the diff's guess. Items already at or before the queue position (the web app's "Play" = Play Next + skip) aren't additions.
- When the shared track ends (within 3 s of its duration, or >4 s overdue), `playFromQueue` plays the first item for everyone. Each side resolves it on its own service.
- Known limitation: Play Next on the last song of a Qobuz queue looks identical to Add to Queue. No drag reordering.

## Gotchas

- **Qobuz control is a hack**: SIGUSR1 opens Node's inspector on 127.0.0.1:9229 (or another port; found via lsof). It depends on Qobuz's internal Redux shape and action names (tested on Qobuz 8.3.0). Any Qobuz update can break `js/qobuz-page.js`.
- Two app versions on one Mac fight over the Qobuz page bridge (each installs its own `VERSION`). Don't run old and new builds at once.
- Apple Music audio plays in WebKit's GPU process; per-app mixers see it under ListenTogether. Use the in-app volume.
- New trycloudflare hostnames can get cached as NXDOMAIN by resolvers if handed out too early; that's why `waitUntilPublic` exists.
- SwiftUI `Window` scene would quit the app when its window closes; `applicationShouldTerminateAfterLastWindowClosed` returns false on purpose.
- The `MusicPlayer` protocol and players are `@MainActor`; keep UI-touching and WebKit work on the main actor.
- Never commit `EmbeddedJS.swift`, `build/`, `.build/`, or `relay/node_modules/`.

## Conventions

- Keep the JS bridges self-contained and bump their `VERSION` when changing their API.
- Add unit tests in `Tests/ListenTogetherTests` for pure logic (matching, queue diff/merge, invite links, volume curve).
- User-facing messages are short and actionable (e.g. "Can't reach the room. If the host closed it, click Leave Room.").
