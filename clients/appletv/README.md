# Stream for Apple TV

The Apple TV client (PROPOSAL §11 Phase 6): SwiftUI and AVPlayer over the same
`/api/v1` the web app uses (`swagger/v1/openapi.yaml`, served at `/api-docs`).

- **Sign in** with the server's address, then a code entered at `<server>/pair`
  on a phone (the TV pairing flow), then "Who's watching?" with PINs.
- **Browse** as the web does, down a sidebar: Home's hero (its trailer behind
  it) and rows, On now; film, show, season, person, collection, channel, video
  and playlist pages; libraries as poster walls (sort, Unwatched), YouTube as
  channels, home videos through time; Search in all the web's groups,
  transcript hits included. A long press on any card offers what the web's
  card menu does.
- **Grid**: the web's guide grid with a live preview of the focused
  channel; channels change with ▲▼, already tuned; the banner, LIVE / Jump to
  live, Restart, and the guide over the picture.
- **Baseball**, once the household has an MLB.tv account: the day's games
  as the web's scoreboard (logos, score, inning, count, outs and bases, line
  score, probable pitchers), days stepped with ◀▶. Choosing a game plays the
  first team's broadcast in the stream player; a long press picks the other's.
- **Play** behind Stream's own controls (the web player's): the app sends what
  this Apple TV decodes (native HLS, HEVC and HDR / Dolby Vision on a 4K model,
  Dolby Digital Plus), and Stream answers with the original file or a stream,
  exactly as for a browser. A click plays or pauses, ◀▶ jump ten seconds, a
  swipe scrubs with trickplay thumbnails and chapters, ▼ reaches Subtitles,
  Audio, Speed and Related. Skip intro (and Always skip), SponsorBlock, Up
  next with its countdown and "Still watching?" take focus as they come.
  Progress is reported every ten seconds; Now Playing and Control Center work.
- **Be played to**: it names itself after the Apple TV ("Living Room") and
  listens, so "play the next Severance in the living room" over MCP, or
  "Play on another screen" in the web app, reaches it.
- **Top Shelf**: Continue watching and On now, from a snapshot the app writes
  when Home loads (`Shared/TopShelfSnapshot.swift`) into the
  `group.com.fogstack.stream` app group — the extension never signs in. Its
  items open `stream://` links: a page, the player, or a channel.

Not here: styled (ASS) subtitles and the admin screens — those stay in the
browser. Reduce Motion is honoured throughout (focus by ring and colour alone,
fades for slides); on tvOS 18 pages zoom out of the cards that open them.

```bash
brew install xcodegen
make gen      # StreamTV.xcodeproj from project.yml
make build    # for the tvOS simulator
make test     # colour lint, then decodes real API responses (StreamTVTests/Fixtures) and more
make ui       # drives the showcase with the Siri Remote; screenshots in build/screenshots
make open     # then run it on an Apple TV from Xcode
```

The simulator builds unsigned, where there is no app group and so no Top
Shelf — everything else works.

Running on a real Apple TV signs both targets with your own Apple Developer
team: put `STREAM_TEAM_ID = <your team ID>` in `Local.mk` (untracked) before
`make gen`, or pass `STREAM_TEAM_ID=…` to make. The bundle identifiers
(`com.fogstack.stream`, `.topshelf`) and the app group
(`group.com.fogstack.stream`) belong to the maintainer's account; to sign
under your own, change them in `project.yml`, both `.entitlements` files and
`Shared/TopShelfSnapshot.swift`. Automatic signing registers the app group;
the App Groups capability has to be allowed for your team.

`make release` is the maintainer's: it archives a Release build and uploads
it to TestFlight (`ExportOptions.plist`: App Store Connect, automatic
signing, build numbers managed on upload); `make bump-version V=1.1` sets
both targets' version first.

The app icon (layered, for parallax) and the Top Shelf image are drawn from
`Artwork/stream-logo.png` by `Scripts/icons.sh` (ImageMagick) into
`StreamTV/Assets.xcassets`; run it again when the logo changes.

`make build` and `make test` need Xcode's tvOS platform
(`xcodebuild -downloadPlatform tvOS`); pick a simulator on that runtime with
`SIMULATOR=…` if the default name matches an older one. Refresh the fixtures from a seeded
harness (`bin/rails e2e:seed`) when a serializer the app reads changes.

## Design and the showcase

The app draws the web's look natively: every colour comes from `Palette`
(`StreamTV/Design/Theme.swift`, the web's oklch tokens in sRGB) and `make lint`
fails on a raw one, like the web's `bin/design-guard`. `-StreamShowcase YES`
runs the app on made-up titles bundled in `StreamTV/Resources/Showcase`
(regenerate with `python3 Scripts/showcase.py`) instead of a server — what the
UI tests drive; add `-StreamGallery YES` for every design piece on one screen.
