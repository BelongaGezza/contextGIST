# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

contextGIST is a macOS Services-menu item: select text in any app that
supports Services, invoke "Speed Read with contextGIST", and a small
floating popup shows that text RSVP-style (one word at a time, paced) with
play/pause/rewind/fast-forward/speed controls. On close, the text is
discarded — no library, no persistence, no accounts.

It lives at <https://github.com/BelongaGezza/contextGIST>. It is a narrow reuse of [GIST](https://github.com/BelongaGezza/gist)'s RSVP pacing engine and
tokenizer, not a fork of its git history. See
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the full design and
**read it before touching `crates/contextgist-ffi` or
`apps/macos/Sources/RsvpView.swift`'s `PacingEngine`** — both exist to stay
behaviorally identical to specific code in GIST, and that
file explains exactly what must stay in sync and why.

Also see [`docs/SECURITY_REVIEW.md`](./docs/SECURITY_REVIEW.md) (point-in-time
manual review, 2026-09-25 — re-check its findings before any public
distribution), [`docs/DEVELOPMENT_PLAN.md`](./docs/DEVELOPMENT_PLAN.md)
(remediation for that review, plus the phased plan for iOS/iPadOS, a WASM
core, Chrome, Windows 11, and Linux), and
[`docs/MACOS_GUIDE.md`](./docs/MACOS_GUIDE.md) (install/use/remove for the
current macOS build — there's no signed release yet, so this is the only
way to run it today). [`docs/PRIVACY.md`](./docs/PRIVACY.md) and
[`docs/THIRD-PARTY.md`](./docs/THIRD-PARTY.md) are user-facing
disclosures, so keep them true when the code changes.

## Relationship to GIST (https://github.com/BelongaGezza/gist)

`crates/contextgist-ffi` depends on `gist-model`, `gist-parse-txt`, and
`gist-rsvp` as **git dependencies on `https://github.com/BelongaGezza/gist`, pinned by commit `rev`**
in the workspace `Cargo.toml` (`[workspace.dependencies]`) — not a vendored
copy, not a git fork. GitHub is the source of truth. This means:

- **No local GIST checkout is needed or consulted.** Cargo fetches the pinned
  commit itself (network needed the first time; then cached in `~/.cargo`).
  Any clone at `~/develop/reader` is just a personal working copy of GIST
  and has no effect on this build.
- Pacing/tokenization logic is never edited in this repo — if it needs to
  change, change it in GIST (PR/merge on GitHub), then adopt it here by
  moving the pin via the upstream review below. To try an unmerged GIST
  change locally, use a throwaway `[patch]` override
  (`cargo --config 'patch."https://github.com/BelongaGezza/gist".gist-rsvp.path="/path/to/gist/crates/gist-rsvp"' test`)
  and never commit it.
- `UPSTREAM_BASELINE` records the last GIST commit (normally on `main`)
  this repo was reviewed and tested against; it always equals the `rev` in
  `Cargo.toml` (`--record` moves both).
- **Upstream review is part of the development cycle.** At the start of a
  work session, and whenever the build prints `warning: GIST ... changed
  ... since the last upstream review`, run `tools/upstream-review.sh`.
  For each item, decide adopt, port or skip, following
  `docs/ARCHITECTURE.md` "Upstream baseline". Tell the user what's
  applicable before making non-trivial changes. Once handled, run
  `tools/upstream-review.sh --record "<summary>"` and commit. Releases are
  blocked (`release-sign.sh`) until this is done.
- `rust-toolchain.toml` here is pinned independently of GIST's own pin
  (1.88.0) — contextGIST's uniffi version needs a newer rustc than that to
  resolve its transitive deps, and the git-dependency crates have no MSRV
  requirement forcing a match.

## Build / test commands

```bash
# Rust workspace (crates/contextgist-ffi) — fetches GIST's crates from GitHub on first build
cargo test --workspace
cargo test -p contextgist-ffi tokenize_splits_words_and_paragraphs   # single test

# macOS app
./tools/gen-bindings.sh                   # builds contextgist-ffi + regenerates apps/macos/Generated/
cd apps/macos && xcodegen generate        # generates contextGIST.xcodeproj (gitignored, never committed)
xcodebuild -scheme contextGIST build

# Release packaging / disclosures
./tools/gen-third-party.sh                # regenerate docs/THIRD-PARTY.md + bundled notices after any Cargo.lock change
./tools/build-dmg.sh <path/to/contextGIST.app> <out.dmg>   # unsigned DMG (Release = universal)
./tools/release-sign.sh <path/to/contextGIST.app> <out.dmg> # sign + DMG + notarize (SIGN_IDENTITY, APPLE_* env; ad-hoc if unset)
cargo deny --exclude-dev check            # licence/advisory/source policy (deny.toml); advisories need cargo-deny >= 0.20
./tools/gen-app-icon.sh [--refresh-source]   # regenerate apps/macos/AppIcon.icon from GIST's icon artwork

# Upstream (GIST) review
./tools/upstream-review.sh [--fetch]      # what changed in GIST (GitHub main) since UPSTREAM_BASELINE, grouped by impact
./tools/upstream-review.sh --record "..." # after reviewing: move the Cargo.toml rev + baseline, run tests, log it in ARCHITECTURE.md
```

CI (`.github/workflows/ci.yml`, on push to `main`, PRs and weekly) runs
`cargo test --workspace --locked`, `cargo deny --exclude-dev check`, and an
unsigned Debug `xcodebuild` of the app. Keep those three green; signing and
notarization stay local (`tools/release-sign.sh`).

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
  close is what discards the reading session. It rejects selections over
  `maxSelectionBytes` (512 KiB) with an alert. `RsvpPlayer` tokenizes off
  the main thread. `RsvpView.swift` has the
  SwiftUI view, the `RsvpPlayer`/`PacingEngine` playback logic (a Swift
  port of `gist-rsvp`'s pacing math — see architecture doc), and the
  ORP-centered word display.
- **`tools/gen-bindings.sh`** — builds `contextgist-ffi` (host arch for
  Debug; a lipo'd arm64 + x86_64 staticlib in `target/universal/release/`
  for Release) and regenerates `apps/macos/Generated/*.swift`. No `.xcframework` step
  (unlike GIST) — `apps/macos/project.yml` links the staticlib directly via
  `LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS`, since this is macOS-only.

## Current state

Scaffolded 2026-09-25. `cargo test --workspace` passes (13 tests in
`contextgist-ffi`, including adversarial-input tests against the upstream
tokenizer/ORP code). `./tools/gen-bindings.sh` + `xcodegen generate` +
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
`RsvpView.swift`. This bug doesn't exist upstream in GIST
(GIST's own RSVP view has no ORP centering at all yet), so it was filed as
[gist#71](https://github.com/BelongaGezza/gist/issues/71) for that repo's
own consideration rather than fixed there.

A full security review has since been done — see
`docs/SECURITY_REVIEW.md` — and its findings, plus the platform expansion
(iOS/iPadOS, Chrome, Windows 11, Linux), are tracked in
`docs/DEVELOPMENT_PLAN.md`. No Windows/Linux/browser-extension integration
exists yet; macOS Services (+ the not-yet-started iOS Share Extension) is
the only integration point today.

2026-09-30: reviewed upstream GIST changes since the scaffold (baseline now
GIST `24f4138`). Adopted: GIST's `elapsedMs` rounding fix in
`PacingEngine`, a VoiceOver/contrast pass on the popup,
`tools/build-dmg.sh`, licence notices (`tools/gen-third-party.sh`,
bundled as `Resources/ThirdPartyNotices.txt`), and `docs/PRIVACY.md`.
Deliberately not ported: GIST's punctuation-pause toggle, scrub slider,
session stats, and rotary dial (see `docs/ARCHITECTURE.md`).
