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

Multi-platform layout, parallel-development rules and per-platform TODOs
(Windows, Linux, macOS): [`docs/PLATFORMS.md`](./docs/PLATFORMS.md). Packaged
builds live in `dist/<platform>/`.

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
./tools/package-macos.sh                  # Release build -> dist/macos/ (contextGIST.dmg + .app + INSTALL.txt; the DMG and INSTALL.txt are committed, the .app is not)
./tools/build-dmg.sh <path/to/contextGIST.app> <out.dmg>   # unsigned DMG (Release = universal); includes tools/dmg/INSTALL.txt
./tools/release-sign.sh <path/to/contextGIST.app> <out.dmg> # sign + DMG + notarize (SIGN_IDENTITY, APPLE_* env; ad-hoc if unset)
cargo deny --exclude-dev check            # licence/advisory/source policy (deny.toml); advisories need cargo-deny >= 0.20
./tools/gen-app-icon.sh [--refresh-source]   # regenerate apps/macos/AppIcon.icon from GIST's icon artwork

# Upstream (GIST) review
./tools/upstream-review.sh                # what changed in GIST (GitHub main) since UPSTREAM_BASELINE, grouped by impact (fetches; `--ref <ref>`, `--check [--strict]` also exist)
./tools/upstream-review.sh --record "..." # after reviewing: move the Cargo.toml rev + baseline, run tests, log it in ARCHITECTURE.md (macOS only until made portable, Q-04)
```

CI (`.github/workflows/ci.yml`, on push to `main`, PRs and weekly) runs
`cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace --locked`,
`cargo deny --exclude-dev check`, a check that `UPSTREAM_BASELINE` equals the
`Cargo.toml` GIST rev, and an unsigned Debug `xcodebuild` + XCTest of the app.
`.github/workflows/windows.yml` (path-filtered) repeats fmt/clippy/test on
`windows-latest` and builds the Windows spike. Keep these green; signing and
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

Last rebased 2026-10-21. The ordered work list and review findings live in
`docs/DEVELOPMENT_PLAN.md` (status snapshot at the top); this section is only
the engineering baseline.

- **Rust:** `cargo test --workspace --locked` passes (25 tests in
  `contextgist-ffi`: adversarial inputs, golden parity against the pinned
  GIST crates, the 512 KiB cap, UTF-8-only parsing, 256-byte token split).
  `cargo fmt --all --check` and `cargo clippy -D warnings` are clean and gated
  in CI. The Windows spike is its own workspace (`apps/windows/spikes/capture-prober`,
  9 unit tests, fmt/clippy clean, built in `windows.yml`).
- **Upstream:** `Cargo.toml` pin == `UPSTREAM_BASELINE` == GIST `5e25545`
  (asserted in CI; no unreviewed upstream changes as of 2026-10-21).
- **macOS app:** the Services flow is confirmed hands-on (popup plays, close
  discards text, the process exits when idle). `contextGISTTests` (11 parity
  tests against `apps/macos/Tests/golden.json`) runs in CI. Not yet verified
  on a Mac since the Rust-core changes of PR #6: see `PENDING_APPLE_CHANGES.md`
  (Swift `Float` durations, adopting `golden_extended.json`). Builds are
  unsigned; the committed DMG carries `get-task-allow` and must not be
  distributed (S-01). Developer ID signing/notarization is blocked on an Apple
  Developer account.
- **CI:** `ci.yml` (cargo test, fmt, clippy, cargo deny, baseline==pin,
  unsigned Debug `xcodebuild` + XCTest, weekly upstream check) and
  `windows.yml` (path-filtered, `windows-latest`, workspace + spike). Dependabot
  is on for Actions and Cargo (never the GIST pin).
- **Windows:** planning and a capture spike only; no app. See
  `docs/WINDOWS_PLAN.md`. Linux, iOS/iPadOS and Chrome are not started.
- **Reviews:** `docs/SECURITY_REVIEW.md` (2026-09-25, updated 2026-10-21) and
  `docs/REVIEW_2026-10-21.md` (S-01..S-17, Q-01..Q-27, status table at the end).
  Re-check them before any public distribution.

Landmarks worth remembering: the ORP reticle jitter (fixed by computing the
offset from character counts, filed upstream as gist#71) and the upstream
adoptions logged in `docs/ARCHITECTURE.md` "Upstream baseline". The
per-session upstream-review history is in that table, not here.
