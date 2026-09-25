# Architecture

## What contextGIST is

contextGIST is a system Services-menu item for macOS: select text in any
Cocoa app (Word, Preview, Safari, TextEdit, most PDF viewers), right-click
(or use the Services submenu), choose "Speed Read with contextGIST", and a
small floating popup window displays that text RSVP-style — one word at a
time, at a controllable pace, with play/pause/rewind/fast-forward. When the
popup closes, the text is gone. There is no library, no import flow, and no
persistence of any kind.

This is a deliberately narrow slice of [GIST](https://github.com/) (the
full reader app, at `~/develop/reader`): its RSVP pacing engine and
tokenizer, with none of its library/storage/search/encryption machinery.

## Relationship to GIST

contextGIST is its own repository. It does not fork GIST's git history or
vendor a copy of its code. Instead, `crates/contextgist-ffi/Cargo.toml`
depends on three of GIST's crates directly via relative path dependencies
into `~/develop/reader/crates/`:

- **`gist-model`** — `Token`/`TokenKind`, and the `Document::build_token_stream`
  algorithm (whitespace-split words, blank-line-separated paragraphs).
- **`gist-parse-txt`** — turns a raw text blob into a `Document` (this is
  what contextGIST calls; a text selection is treated exactly like a `.txt`
  import).
- **`gist-rsvp`** — the pure, I/O-free, timer-free RSVP pacing engine:
  WPM-to-duration conversion, punctuation/paragraph pause multipliers, ORP
  (Optimal Recognition Point) calculation. No changes were made to this
  crate to build contextGIST.

Because these are path dependencies rather than a copy, pacing/tokenization
behavior never drifts from upstream GIST — a bug fix or pacing tweak in
`~/develop/reader` is picked up the next time contextGIST is built. The
trade-off is that the two repos must stay co-located on disk (both under
`~/develop/`); contextGIST does not build standalone if `~/develop/reader`
is moved or absent.

Everything else in GIST — `gist-store` (SQLite/FTS5/encryption),
`gist-core` (import pipeline), `gist-parse-epub`/`gist-parse-docx`/
`gist-parse-pdf`, `gist-web`, `gist-imageprep`, and `gist-ffi` (which is
wired to `gist-store` and therefore requires a `db_path`/`storage_dir` at
construction) — is intentionally not used. contextGIST never has a file
path or a database; its only input is a `String` already in memory.

## Rust core: `crates/contextgist-ffi`

A single small crate, exposed to Swift via [uniffi](https://mozilla.github.io/uniffi-rs/)
(same tool and version GIST's own `gist-ffi` uses). Its entire surface is
three pure, one-shot functions — no stateful session object, and no
persistence:

- `tokenize(text: String) -> Vec<FfiToken>` — calls `gist_parse_txt::parse`
  then returns its `token_stream`.
- `default_config() -> FfiRsvpConfig` — `gist_rsvp::Config::default()`.
- `orp_index(word: String) -> u32` — `gist_rsvp::orp_index`.

## Why playback isn't driven through FFI per tick

`gist-rsvp`'s own doc comment says it's meant to be driven "from
`CVDisplayLink` by calling `token_at_elapsed` on every frame" — but GIST's
own macOS shell moved away from that: `RsvpWallClockEngine` in
`reader/apps/apple/macOS/RsvpView.swift` is a hand-ported, wall-clock-
anchored copy of `token_duration_ms`/`token_at_elapsed`, called locally
every tick instead of round-tripping through FFI, specifically to avoid
scheduling jitter accumulating as drift.

contextGIST follows the same pattern: `PacingEngine` in
`apps/macos/Sources/RsvpView.swift` is a Swift port of the same pacing
math, kept in sync by comment reference back to `gist-rsvp`'s source. The
Rust side is called exactly once per popup, at load time, to tokenize the
selection and fetch the default config — never again until the window
closes.

## macOS app: `apps/macos`

- **`Info.plist`** — `LSUIElement = true` (no Dock icon, no menu bar) and
  an `NSServices` entry (`NSMessage = readSelection`) that's how the OS
  routes a Services-menu invocation into the app.
- **`main.swift` / `AppDelegate.swift`** — a plain `NSApplication` startup
  (no SwiftUI `App`/`Scene` lifecycle, since the app must be able to sit
  with zero windows between invocations) that registers
  `AppServiceProvider` as `NSApp.servicesProvider`.
- **`AppServiceProvider.swift`** — `readSelection(_:userData:error:)` is
  the method macOS calls with the selection already on an `NSPasteboard`.
  It hands the text straight to a new `PopupController` and holds no
  reference to anything else.
- **`PopupController.swift`** — owns the one `NSWindow` for a reading
  session. `windowWillClose` drops its only reference back to
  `AppServiceProvider`, which is what actually discards the text — nothing
  writes it anywhere.
- **`RsvpView.swift`** — the SwiftUI view, its `RsvpPlayer`
  (`ObservableObject` driving playback) and `PacingEngine` (see above), and
  the ORP-centered word display (`WordDisplay`, using the standard
  "reticle" technique: offset the word by half the difference between its
  prefix and suffix widths so the focal letter's x-position stays fixed).

`apps/macos/project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec, exactly like GIST's own `apps/apple/project.yml` — the `.xcodeproj`
is generated, never committed. Unlike GIST, there's no `.xcframework`:
contextGIST links `contextgist-ffi`'s staticlib directly
(`LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS` in `project.yml`), since it's
macOS-only for now and doesn't need iOS/multi-arch packaging.

## Not yet built

- Windows/browser-extension equivalents (macOS Services is the only
  integration point today — see the platform decision recorded when this
  project was scaffolded).
- Word-chunking (`chunk_size` > 1) — `default_config()` returns GIST's
  default of `1`, and the Swift side doesn't yet group multiple tokens into
  one display frame.
- Any UI polish beyond a functional popup (theming, window-position memory,
  etc. — deliberately out of scope: there is no settings persistence).
