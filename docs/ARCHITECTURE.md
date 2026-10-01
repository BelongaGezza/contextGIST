# Architecture

## What contextGIST is

contextGIST is a system Services-menu item for macOS: select text in any
Cocoa app (Word, Preview, Safari, TextEdit, most PDF viewers), right-click
(or use the Services submenu), choose "Speed Read with contextGIST", and a
small floating popup window displays that text RSVP-style — one word at a
time, at a controllable pace, with play/pause/rewind/fast-forward. When the
popup closes, the text is gone. There is no library, no import flow, and no
persistence of any kind.

This is a deliberately narrow slice of [GIST](https://github.com/BelongaGezza/gist) (the
full reader app, cloned locally at `~/develop/reader`): its RSVP pacing engine and
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

### Upstream baseline

Because the dependency is a path, contextGIST builds against whatever
branch/commit `~/develop/reader` happens to have checked out — not
necessarily GitHub `main`. contextGIST exists to reuse GIST, so reviewing
upstream changes is part of the normal development cycle, not a one-off.

**How it's enforced.** `UPSTREAM_BASELINE` records the last GIST commit
contextGIST was reviewed and tested against. `tools/upstream-review.sh`
compares the current `~/develop/reader` checkout (including uncommitted
edits) with it:

- **Every build:** `gen-bindings.sh` runs `upstream-review.sh --check`,
  which prints an Xcode build warning when GIST code that contextGIST uses
  has changed since the baseline. The build doesn't fail.
- **Every release:** `release-sign.sh` runs `--check --strict` and refuses to
  sign until the review is done (`ALLOW_UNREVIEWED_UPSTREAM=1` overrides,
  with a warning).
- **Start of a work session:** run `tools/upstream-review.sh` (add `--fetch`
  to see GitHub too), so work starts from a reviewed upstream.

**Doing a review.** `tools/upstream-review.sh` groups changes by how they
can reach contextGIST. For each item, decide *adopt*, *port* or *skip*:

1. **Shared crates** (`gist-model`, `gist-parse-txt`, `gist-rsvp`): compiled
   in, so their changes arrive on the next build with no action. Check the
   behaviour change is wanted, and update any contextGIST test that pins
   upstream behaviour (e.g. `line_ending_styles`).
2. **GIST's Swift pacing/ORP code** (`apps/apple/macOS/RsvpView.swift`):
   `PacingEngine` is a hand port, so diff it and port pacing fixes. UI-only
   features are a product decision (see the "Not ported" list above).
3. **Icon artwork** (`assets/`): `tools/gen-app-icon.sh --refresh-source`.
4. **Security/dependency policy** (`deny.toml`, GIST's security reviews):
   mirror what applies to contextGIST's much smaller surface.
5. **Everything else**: usually GIST-only (library, storage, Windows), but
   skim for fixes to ideas contextGIST shares.
6. **GIST issues mentioning contextGIST**: a closed one may need a matching
   change here.

Then record it with `tools/upstream-review.sh --record "<what was adopted,
ported or skipped>"`. That refuses a GIST checkout with uncommitted changes
in watched paths, runs `cargo test --workspace` against it, and on success
updates `UPSTREAM_BASELINE` and adds a row below. Commit both, together with
any adopted changes.

History of reviews:

| Date | `~/develop/reader` commit | Branch | Notes |
|---|---|---|---|
| 2026-09-30 | `24f4138` | `integration/m4-2026-09-28` (24 commits ahead of `origin/main` `75700c6`) | Upstream changes since the 2026-09-25 scaffold (`5ab99ab`) reviewed. Path-dep crates changed only additively (`gist-model::ParseError`, tests, a `gist-parse-txt` benchmark), with no pacing or tokenization change. Ported the `elapsedMs` rounding fix from GIST's `RsvpWallClockEngine` (reader `6717ca5`). |
| 2026-09-30 | `9dc537c` | `main` | First review under the new process (24f4138 to `9dc537c`, GIST `main`). Adopted: the #76 paragraph fix (filed from here; reviewed as `695fba1` on its branch, merged to `main` as PR #77 `9dc537c` with an identical tree) arrives via `gist-parse-txt`; `line_ending_styles` now expects a break for CRLF, CR, U+2029 and whitespace-only blank lines. No change: `fb33b2e` commits icon art byte-identical to `IconSource/`. Skipped: `4e391db` (GIST string catalog). #71 closed upstream; contextGIST already centres the ORP letter. |

See also `docs/SECURITY_REVIEW.md` finding #4.

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

`tokenize` and `orp_index` wrap their work in `contain`, which turns a panic
into a neutral result (no tokens / offset 0) and installs a silent panic
hook once. For infallible exports, uniffi's generated Swift uses `try!`, so
an uncaught panic would otherwise trap and write a crash report while the
selection is in memory (`docs/SECURITY_REVIEW.md` finding #1). The tests
include adversarial inputs (bidi, ZWJ, huge words, degenerate whitespace, a
seeded pseudo-fuzz) run against the upstream crates *without* `contain`, so
a real upstream panic still fails a test instead of being hidden.

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

GIST later wrote up why its Swift shell keeps a `Task.sleep`-driven,
state-published redraw rather than a manual `CVDisplayLink` integration
(the doc comment on `RsvpWallClockEngine` in
`reader/apps/apple/macOS/RsvpView.swift`, reader commit `6717ca5`). The
reasoning applies unchanged to `PacingEngine`: drift is already fixed at the
model level, and a `CVDisplayLink` callback would still have to go through
SwiftUI's state system to change pixels. Revisit only if hands-on testing
at 800–1000 WPM shows visible per-word jitter.

Not ported from GIST's newer RSVP view (reader `6717ca5`), by decision: the
punctuation-pause toggle (it changes the pacing math this port must match;
adopt it verbatim or not at all), the scrub slider, session stats, and the
rotary dial. GIST's Swift-side `OrpCalculator` isn't needed either:
contextGIST gets ORP from `gist_rsvp::orp_index` over FFI, so it can't
drift from the Rust rule.

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
  writes it anywhere. `AppServiceProvider.quitIfIdle()` then quits the app,
  as it does whenever there's no popup (alert dismissed, empty selection, or
  10 s after a launch that never got text), so no reading outlives its
  window. Debug builds have test hooks that close the popup and alert on a
  timer (`CONTEXTGIST_TEST_AUTOCLOSE_AFTER`, `..._VIA=escape`,
  `CONTEXTGIST_TEST_AUTOCLOSE_ALERT_AFTER`), so these exit paths can be
  checked without UI automation. Pass them with `open --env`, or with
  `launchctl setenv` for a Services-launched instance, and unset them
  afterwards.
- **`RsvpView.swift`** — the SwiftUI view, its `RsvpPlayer`
  (`ObservableObject` driving playback) and `PacingEngine` (see above), and
  the ORP-centered word display (`WordDisplay`, using the standard
  "reticle" technique: offset the word by half the difference between its
  prefix and suffix widths so the focal letter's x-position stays fixed).
  VoiceOver reads the word display as one element (not three fragments
  split at the ORP letter), marked `.updatesFrequently` so playback
  doesn't produce a stream of announcements. The red focal letter
  (`systemRed`, 40pt) measures 3.57:1 against the window background in
  light mode and 4.86:1 in dark mode, which passes WCAG AA's 3:1 bar for
  large text.
- **`Resources/ThirdPartyNotices.txt`**: bundled licence notices,
  generated by `tools/gen-third-party.sh` along with `docs/THIRD-PARTY.md`.
  There's no About screen to show them from, so `tools/build-dmg.sh` also
  copies them to the DMG root.

### App icon

`apps/macos/AppIcon.icon` (Icon Composer format) is generated by
`tools/gen-app-icon.sh` from GIST's macOS icon artwork
(`~/develop/reader/assets/a-macos-app-icon.png`, same author). The artwork
is copied into `apps/macos/IconSource/` because it isn't committed
upstream. Don't hand-edit the `.icon`; change the source and re-run the
script.

- **Why it's reshaped:** GIST's artwork has its own rounded body shape and a
  blue glow on a white background. macOS 26+ masks app icons itself and
  puts any icon that isn't full-bleed on a grey backing tile, which is what
  the artwork looked like when used as-is. The script repaints the
  background with the body colour and places the artwork on Apple's grid
  (824 px body in a 1024 canvas), so the system's own mask replaces GIST's
  corners.
- **Older macOS:** Xcode derives the flat `AppIcon.icns` that macOS 13–15
  use from the same `.icon`. A separate asset-catalog `AppIcon` would be
  ignored (actool output is byte-identical with or without one), so there
  isn't one.
- **GIST itself** will hit the same grey tile on macOS 26+ if it ships that
  artwork unmodified.

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
