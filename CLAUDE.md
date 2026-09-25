# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

contextGIST is a macOS Services-menu item: select text in any app that
supports Services, invoke "Speed Read with contextGIST", and a small
floating popup shows that text RSVP-style (one word at a time, paced) with
play/pause/rewind/fast-forward/speed controls. On close, the text is
discarded — no library, no persistence, no accounts.

It is a narrow reuse of [GIST](~/develop/reader)'s RSVP pacing engine and
tokenizer, not a fork of its git history. See
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the full design and
**read it before touching `crates/contextgist-ffi` or
`apps/macos/Sources/RsvpView.swift`'s `PacingEngine`** — both exist to stay
behaviorally identical to specific code in `~/develop/reader`, and that
file explains exactly what must stay in sync and why.

Also see [`docs/SECURITY_REVIEW.md`](./docs/SECURITY_REVIEW.md) (point-in-time
manual review, 2026-09-25 — re-check its findings before any public
distribution) and [`docs/DEVELOPMENT_PLAN.md`](./docs/DEVELOPMENT_PLAN.md)
(remediation for that review, plus the phased plan for iOS/iPadOS, a WASM
core, Chrome, Windows 11, and Linux).

## Relationship to GIST (~/develop/reader)

`crates/contextgist-ffi` depends on `gist-model`, `gist-parse-txt`, and
`gist-rsvp` via relative path dependencies into `~/develop/reader/crates/`
— not a vendored copy, not a git fork. This means:

- **`~/develop/reader` must exist on disk** at that relative path for this
  workspace to build at all.
- Pacing/tokenization logic is never edited in this repo — if it needs to
  change, change it upstream in `~/develop/reader` and this workspace picks
  it up on the next build.
- `rust-toolchain.toml` here is pinned independently of GIST's own pin
  (1.88.0) — contextGIST's uniffi version needs a newer rustc than that to
  resolve its transitive deps, and the path-dependency crates have no MSRV
  requirement forcing a match.

## Build / test commands

```bash
# Rust workspace (crates/contextgist-ffi) — requires ~/develop/reader present
cargo test --workspace
cargo test -p contextgist-ffi tokenize_splits_words_and_paragraphs   # single test

# macOS app
./tools/gen-bindings.sh                   # builds contextgist-ffi + regenerates apps/macos/Generated/
cd apps/macos && xcodegen generate        # generates contextGIST.xcodeproj (gitignored, never committed)
xcodebuild -scheme contextGIST build
```

`xcodegen` and Xcode are required for the macOS app; `brew install xcodegen`
if missing. The Xcode project's pre-build script runs
`tools/gen-bindings.sh` automatically, so a plain `xcodebuild` after
`xcodegen generate` is sufficient day-to-day — the two-step `gen-bindings.sh`
+ `xcodegen generate` above is only needed the first time, or after adding a
new source file (XcodeGen needs to re-scan `Sources/`).

## Architecture at a glance

- **`crates/contextgist-ffi`** — the entire Rust surface: three pure,
  one-shot uniffi-exported functions (`tokenize`, `default_config`,
  `orp_index`), no stateful session object, no I/O. Called once per popup,
  at load time only — see "Why playback isn't driven through FFI per tick"
  in `docs/ARCHITECTURE.md`.
- **`apps/macos/Sources/`** — the Services-menu app. `main.swift`/
  `AppDelegate.swift` start a windowless, Dock-icon-less (`LSUIElement`)
  `NSApplication` and register `AppServiceProvider`.
  `AppServiceProvider.readSelection(_:userData:error:)` is the OS entry
  point (wired via `NSServices` in `Info.plist`); it owns nothing beyond
  the current `PopupController`, and dropping that reference on window
  close is what discards the reading session. `RsvpView.swift` has the
  SwiftUI view, the `RsvpPlayer`/`PacingEngine` playback logic (a Swift
  port of `gist-rsvp`'s pacing math — see architecture doc), and the
  ORP-centered word display.
- **`tools/gen-bindings.sh`** — builds `contextgist-ffi` for the host arch
  and regenerates `apps/macos/Generated/*.swift`. No `.xcframework` step
  (unlike GIST) — `apps/macos/project.yml` links the staticlib directly via
  `LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS`, since this is macOS-only.

## Current state

Scaffolded 2026-09-25. `cargo test --workspace` passes (4 tests in
`contextgist-ffi`). `./tools/gen-bindings.sh` + `xcodegen generate` +
`xcodebuild -scheme contextGIST build` all succeed cleanly. The built app's
`NSServices` entry ("Speed Read with contextGIST") registers with Launch
Services and shows up in the live pasteboard-services registry
(`lsregister -f`, confirmed via `pbs -dump_pboard`), and the windowless
`LSUIElement` process launches and stays running.

The Services flow has been confirmed working hands-on: the menu item
appears in a real app, the popup plays back, and closing it discards the
text. One real bug was found and fixed in that first hands-on pass — the
ORP reticle (the red focal letter) was jittering left/right because
`WordDisplay` measured prefix/suffix pixel widths via `GeometryReader`/
`PreferenceKey`, which lags a render frame behind each word change. Fixed
by computing the offset synchronously from character counts against the
(monospaced) font's fixed advance width instead — see `WordDisplay` in
`RsvpView.swift`. This bug doesn't exist upstream in `~/develop/reader`
(GIST's own RSVP view has no ORP centering at all yet), so it was filed as
[gist#71](https://github.com/BelongaGezza/gist/issues/71) for that repo's
own consideration rather than fixed there.

A full security review has since been done — see
`docs/SECURITY_REVIEW.md` — and its findings, plus the platform expansion
(iOS/iPadOS, Chrome, Windows 11, Linux), are tracked in
`docs/DEVELOPMENT_PLAN.md`. No Windows/Linux/browser-extension integration
exists yet; macOS Services (+ the not-yet-started iOS Share Extension) is
the only integration point today.
