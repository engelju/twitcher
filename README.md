# Twitcher

A minimal native macOS app for watching Twitch streams and VODs, built with
SwiftUI + AVPlayer. No web view, no streamlink dependency — stream URLs are
resolved with a small built-in client for Twitch's playback-token endpoint.

## Features

- **Channel sidebar** driven by `channels.json`: live channels show game +
  viewer count and start playing on selection; offline channels open on
  their recent broadcasts.
- **Stream / Broadcasts tabs** in the toolbar: browse a channel's VOD
  archive even while it's live, and jump back to the stream with one click
  (switching tabs pauses/resumes playback).
- **Read-only chat** pane on the right (toggle with the bubble button in the
  toolbar) — connects anonymously to Twitch's IRC WebSocket gateway, no
  account needed.
- **Native playback** via AVPlayer: adaptive quality, low-latency HLS for
  live streams, Picture-in-Picture and fullscreen from the player controls.
- **UI zoom** with ⌘+ / ⌘− (⌘0 resets), also in the View menu. Scales the
  sidebar, chat, and broadcast grid; the video always renders at native
  size. Persists across launches.
- **Watch history**: VOD playback position is saved every few seconds to
  `~/Library/Application Support/Twitcher/watch-progress.json`. Partially
  watched VODs show a red progress bar on their thumbnail and resume where
  you left off; VODs watched past 95% get a "Watched" badge and restart
  from the beginning.

## Run

```bash
swift run
```

Or open `Package.swift` in Xcode and hit Run.

To build a proper app bundle with icon:

```bash
./scripts/bundle.sh
open build/Twitcher.app
```

## Configuring channels

The app reads `channels.json` on startup, looked up in this order:

1. `channels.json` in the current working directory (used by `swift run`
   from the repo — the repo ships one with example channels)
2. `~/Library/Application Support/Twitcher/channels.json` — created with
   defaults on first launch if missing (this is what the bundled app uses)

Format:

```json
{
  "channels": ["twitch", "twitchdev"]
}
```

The "Edit channels.json" button at the bottom of the sidebar reveals the
active file in Finder. Restart the app (or hit refresh) after editing.

## How it works

- `TwitchAPI` fetches channel metadata (live status, title, viewers, recent
  VODs) from Twitch's GraphQL endpoint using the public web-player client ID.
- `StreamResolver` requests a playback access token via GQL, builds an HLS
  master-playlist URL on `usher.ttvnw.net`, and verifies it responds before
  handing it to `AVPlayer`.
- `ChatClient` joins chat read-only as an anonymous `justinfan` user over
  `wss://irc-ws.chat.twitch.tv` and parses tagged `PRIVMSG` lines for
  display names, user colors, and message text.
- `scripts/bundle.sh` builds a release binary, draws the app icon with a
  small AppKit script (`scripts/make-icon.swift` → `iconutil`), assembles
  `build/Twitcher.app`, and ad-hoc signs it.

## Caveats

- The GQL/usher endpoints are **unofficial**. They can break when Twitch
  changes their player, and bypassing the web player skips ads, which is
  against Twitch's Terms of Service — treat this as a personal-use tool,
  not something to distribute.
- Quality is chosen adaptively by AVPlayer; no manual quality picker yet.
- Chat is live-only (no VOD chat replay) and read-only.

## Ideas for next steps

- Auto-refresh live status on a timer.
- Manual quality picker by parsing the master playlist variants.
- VOD chat replay via the GQL comments API.
- Followed-channels import via the official Helix API (needs OAuth).
