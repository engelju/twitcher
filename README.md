# Twitcher

A minimal native macOS app for watching Twitch and YouTube channels, built
with SwiftUI + AVPlayer.

## Features

- **Channel sidebar** driven by `channels.json`, with Twitch and YouTube
  sections: live channels show what's on and start playing on selection;
  offline channels open on their recent broadcasts. Drag channels to
  reorder them within their section; right-click → **Remove from Sidebar**
  to drop one. Both are saved to `channels.json`.
- **YouTube sign-in** (Twitcher → Sign In to YouTube…, or **Add Channel…**
  at the end of the sidebar's YouTube section). **Add Channel…** opens a
  page of the channels you're subscribed to, searchable, where any of them
  can be added to the sidebar in one click. The login is remembered across
  launches.
- **Stream / Broadcasts tabs** in the toolbar: browse a channel's VOD
  archive even while it's live, and jump back to the stream with one click
  (switching tabs pauses/resumes playback).
- **Read-only chat** pane on the right (toggle with the bubble button in the
  toolbar): live streams get IRC chat via Twitch's WebSocket gateway, and
  Twitch VODs get a **chat replay** synced to playback (including after
  seeking). Twitch only — the pane auto-hides on YouTube channels.
- **Full archives**: Twitch broadcasts are listed completely (cursor
  pagination; VODs expire platform-side after 7–60 days anyway), and
  YouTube channels list every upload with durations via yt-dlp (without
  yt-dlp, the RSS feed's latest 15). **Shorts are left out**: the app
  subtracts the channel's hidden shorts playlist (`UUSH…`) from its uploads
  (`UU…`). Past livestreams stay in, which is why it doesn't use the
  "long-form" playlist (`UULF…`) — that one omits them.
- **Native playback** via AVPlayer: low-latency HLS for live streams,
  Picture-in-Picture and fullscreen from the player controls.
- **Quality picker** in the toolbar, for both Twitch and YouTube. Defaults
  to **Best available**, which pins playback to the highest rendition on
  offer; **Auto** adapts to your connection instead, and every individual
  rendition (e.g. 1080p60 → 160p) can be chosen directly. Your choice is
  remembered across sessions and reapplied to whatever you watch next.
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
```

This installs `/Applications/Twitcher.app` (replacing the previous build),
so it can be launched from Spotlight.

For native YouTube playback, install yt-dlp (optional but recommended):

```bash
brew install yt-dlp
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
  "channels": ["twitch", "twitchdev"],
  "youtube": ["YouTube", "GoogleDevelopers"]
}
```

`channels` are Twitch logins; `youtube` are YouTube handles (the `@name`
from the channel URL, with or without the @) or `UC…` channel IDs.
Channels added from your subscriptions are appended here automatically,
removing a channel from the sidebar deletes its entry, and dragging
reorders the entries (each kept as you wrote it). The "Edit
channels.json" button at the bottom of the sidebar reveals the active file
in Finder.
Restart the app (or hit refresh) after editing.

## How it works

**Twitch**
- `TwitchAPI` fetches channel metadata (live status, title, viewers, recent
  VODs) from Twitch's GraphQL endpoint using the public web-player client ID.
- `StreamResolver` requests a playback access token via GQL, builds an HLS
  master-playlist URL on `usher.ttvnw.net`, and verifies it responds before
  handing it to `AVPlayer`.
- `ChatClient` joins chat read-only as an anonymous `justinfan` user over
  `wss://irc-ws.chat.twitch.tv`.
- `ChatReplayClient` replays VOD chat from the GQL video-comments API,
  paging by content offset (cursor paging trips Twitch's integrity check),
  buffering ~30s ahead of the playhead and refetching after seeks.

**YouTube**
- `YouTubeAPI` scrapes the channel's `/live` page for the channel ID,
  avatar, and live status, and reads the official RSS feed
  (`youtube.com/feeds/videos.xml`) for the recent-videos list. No API key.
- `YouTubeResolver` shells out to yt-dlp (searched in Homebrew/usr-local
  paths) to get an HLS URL AVPlayer can play — YouTube's own endpoints
  require proof-of-origin tokens these days, an arms race only actively
  maintained extractors keep up with. Without yt-dlp, playback falls back
  to the official YouTube embed player in a web view (works, but no PiP or
  progress tracking, and ads may play).
- YouTube hands out an HLS manifest only to *some* of the player clients
  yt-dlp rotates through; the non-HLS path tops out at a 360p progressive
  stream. The resolver therefore retries a few times to land on the HLS
  master (1080p down to 144p), and only falls back to the low-quality
  single rendition — with an on-screen note — if every attempt misses.

- `YouTubeSignInView` shows Google's sign-in page in a web view (with a
  Safari user agent — Google rejects WKWebView's default one). The session
  lands in WebKit's cookie store, which doesn't reliably survive a relaunch
  for an unbundled executable, so `YouTubeAccount` also saves the YouTube
  and Google cookies to
  `~/Library/Application Support/Twitcher/youtube-session.plist`
  (owner-only permissions) and restores them at launch. Sign out from the
  app menu or the subscriptions page; that deletes the file too.
- `YouTubeAccount` copies the session cookies out of that store to load
  `/feed/channels`, collects every `channelRenderer` in its `ytInitialData`,
  and follows continuation tokens through the innertube browse API (signed
  with the `SAPISIDHASH` header the web client uses). No API key or OAuth
  client needed.

**Quality**
- `HLSPlaylist` parses the master playlist's `#EXT-X-STREAM-INF` entries
  into a rendition list (audio-only entries skipped, labels derived from
  resolution + frame rate so Twitch and YouTube read alike).
- Choosing a quality plays that rendition's **own media playlist** rather
  than the adaptive master. Since a single-rendition playlist gives AVPlayer
  nothing to switch between, the quality is genuinely pinned — capping
  `preferredPeakBitRate` on the master would only set a ceiling and still
  drift downward. "Auto" plays the master and lets AVPlayer adapt.
- The preference persists as a *mode* (`best`, `auto`, or a height), not a
  specific variant, since every stream offers a different ladder. It's
  resolved against each new stream: `best` takes the tallest, and an
  explicit height takes the exact match, else the next one down, else the
  lowest available — so a 1080p preference survives watching something that
  only goes up to 720p.
- Renditions are resolved before the player is created, so starting a stream
  never has to swap mid-playback. Changing quality during playback swaps the
  player item, preserving position (VODs) and play state.

**App bundle**
- `scripts/bundle.sh` builds a release binary, draws the app icon with a
  small AppKit script (`scripts/make-icon.swift` → `iconutil`), assembles
  `build/Twitcher.app`, ad-hoc signs it, and moves it to `/Applications`
  (refusing to replace an app there with a different bundle ID).

## Caveats

- The Twitch GQL/usher endpoints and the YouTube page scraping are
  **unofficial** and can break when the platforms change things. Bypassing
  the web players also skips ads, which is against both platforms' Terms of
  Service — treat this as a personal-use tool, not something to distribute.
- Without yt-dlp, YouTube cards have no duration badge (the RSS feed doesn't
  include durations).
- Chat is Twitch-only and read-only.
- Google occasionally refuses sign-in from embedded browsers ("This browser
  or app may not be secure"). If that happens, retrying later usually
  works; there's no workaround short of the official OAuth API.
- YouTube playback quality depends on yt-dlp keeping up with YouTube; if
  videos start resolving at 360p often, `brew upgrade yt-dlp` (or
  `pip install -U yt-dlp`) is the first thing to try.
- "Best available" cannot fall back to a lower rendition mid-stream — that
  is the point of pinning, but on a weak connection it buffers where
  "Auto" would have degraded gracefully instead.

## Ideas for next steps

- Auto-refresh live status on a timer.
- YouTube live chat (needs the innertube live_chat endpoint or an embed).
- Context menu on VOD cards: mark watched/unwatched, clear progress.
