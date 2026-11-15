# ListenTogether

A Mac app for two people to listen to the same song at the same moment, even when one uses **Apple Music** and the other uses **Qobuz**. Play, pause, seek and track changes made by either person are copied to the other.

## How it works

```
 Mac A (Qobuz)                    relay (Node)                   Mac B (Apple Music)
 ListenTogether ── WebSocket ──>  room "amber-tide-42"  <── WebSocket ── ListenTogether
   │ Node inspector                 + clock pings                      │ WKWebView
   ▼                                                                   ▼
 Qobuz.app (Redux store)                                  music.apple.com (MusicKit)
```

- **Shared timeline.** The room has a single state: a track, whether it's playing, and a position at a given relay time. A change one person makes becomes the new state. The other Mac finds that track on its own service, then copies play/pause and the position. Drift over 1.2 s is fixed by seeking.
- **Clock.** Each app pings the relay and keeps the clock offset from the fastest round trip, so positions line up even if the two Macs' clocks differ.
- **Matching.** Tracks are matched by ISRC first, then by normalized title and artist plus duration (see `Matcher` in `Models.swift`). Live versions, remixes and covers that reuse an ISRC are rejected.
- **Qobuz.** Qobuz has no scripting support. The app sends Qobuz's Electron main process `SIGUSR1`, which opens Node's inspector on 127.0.0.1. Through it, the app installs `js/qobuz-host.js` and `js/qobuz-page.js`. These read the player from Qobuz's Redux store, play tracks with `REPLACE_PLAYQUEUE_FROM_RELEASE_EPIC`, seek with the player bar's `seek` and play/pause through the media-key IPC. Search uses the Qobuz API with the app's own credentials. This works alongside `qobuz-now-playing`. **A Qobuz update could break it.** It was tested against Qobuz 8.3.0.
- **Apple Music.** Music.app can't be told to play a catalog song. Instead, the app hosts the official web player (music.apple.com) in a window and drives its MusicKit instance through `js/apple.js`. Sign in once in that window; without a subscription you only get 30-second previews. WebKit plays that audio in a shared system helper process, not in ListenTogether's own, so per-app volume tools can't reach it. Use the app's volume slider (⌘↑ / ⌘↓) instead. It follows a cubic curve (50% ≈ −18 dB), because a linear slider barely changes how loud it sounds until it's near zero. In mixers like Vorssaint, this audio appears under **ListenTogether**, not Apple Music. Volume is per person and never synced. It's saved and applied again whenever the web player reloads, since MusicKit resets to 50% on load.

## Build and run

```sh
./build.sh                         # -> build/ListenTogether.app + .zip (universal, ad-hoc signed)
OUT=build/next ./build.sh          # build elsewhere, e.g. while build/ is running
open build/ListenTogether.app
swift test                         # matcher tests
```

## Relay

Both Macs need to reach the same relay. It has no state beyond the open rooms.

```sh
cd relay && npm install && npm start      # listens on $PORT (default 47900)
```

To use it from anywhere, deploy `relay/` to any Node host that supports WebSockets (Render, Fly.io, Railway, a VPS). In the app, set Relay to `wss://<your-host>`. On a single network, `ws://<mac-ip>:47900` works too.

## Use

**Create a room (easiest).** Install cloudflared first with `brew install cloudflared`. Then, in the app:

1. Click **Create Room**. The app runs the relay itself (`HostServer.swift`) and opens a Cloudflare quick tunnel to it (`CloudflareTunnel.swift`). No account is needed.
2. Click **Copy Link** and send it. It looks like `https://….trycloudflare.com/join/<room>`.
3. Your friend opens the link. The page has a download for the app and an **Open in ListenTogether** button, which uses the `listentogether://` link type. They can also paste the link into the **Join with Link** tab.

The room exists while the host's app is open. The link changes each time a room is created. The room code doubles as the password: the relay refuses connections that don't have it.

**Own relay.** In the **Own Relay** tab, enter a relay address and room code (see Relay above).

**Shared queue.** Use **Add to Queue** or **Play Next** in Qobuz or the Apple Music window as usual. The app notices what was added to its own queue and puts it in the room's **Up Next** list, which both people see. When a song ends, the next one in Up Next plays for both of you, found on each person's service. Play Next songs go to the front (the latest one first, as in both apps), and Add to Queue songs go to the back in the order they were added. In the list you can play any song now, remove it, or clear the list; ⏭ skips to the next one. Every copy of the queue merges the same way (added songs minus removed ones, in a computed order), so two people queueing at the same moment don't lose anything. See `SharedQueue.swift`.

Whoever is already in the room sets what plays, and the person joining follows. After that, play, pause, seek or change tracks in Qobuz, the Apple Music window, or the app's own controls.

Closing the window doesn't quit the app (the Apple Music player and a hosted room live in it). Click the Dock icon to bring the window back.

`LT_PROFILE=<name>` gives a copy its own settings, for example to run two copies on one Mac.

Debug: `LT_DEBUG=1 build/ListenTogether.app/Contents/MacOS/ListenTogether` prints player state changes.

Headless host, without the player: `build/ListenTogether.app/Contents/MacOS/ListenTogether --host-room "Your Name"`.

## Files

| Path | What |
| --- | --- |
| `Sources/ListenTogether/SyncEngine.swift` | Detects local changes, applies remote ones, corrects drift |
| `Sources/ListenTogether/QobuzPlayer.swift` | Inspector connection to Qobuz |
| `Sources/ListenTogether/AppleMusicPlayer.swift` | Web player window and MusicKit bridge |
| `Sources/ListenTogether/RelayClient.swift` | WebSocket, reconnects, clock sync |
| `js/` | The bridges injected into Qobuz and the web player (embedded by `build.sh`) |
| `relay/server.mjs` | Relay server |
