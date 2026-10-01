# Development plan

Written 2026-09-25, after the macOS app's first working build and a
security review ([`docs/SECURITY_REVIEW.md`](./SECURITY_REVIEW.md)). This
plan does two things: closes the gaps that review found, and lays out
adding contextGIST's capability to Windows 11, iPhone, iPad, Linux, and
Chrome — in that order for a reason explained per-phase below.

Read [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) first if you haven't —
this plan assumes its framing (narrow reuse of GIST's Rust core, no
persistence, one popup per invocation).

## Guiding constraint: don't hand-port the pacing engine a third time

`PacingEngine` in `apps/macos/Sources/RsvpView.swift` is already a
hand-ported Swift copy of `gist_rsvp`'s wall-clock pacing math, "kept in
sync by comment reference" per the architecture doc — i.e. by a human
remembering to check. We already found one real bug in a piece of
platform-specific UI code that had no upstream equivalent to copy from (the
ORP-centering flicker — see the GitHub issue filed against
GIST, `BelongaGezza/gist`). Every additional hand-port of the *pacing* logic
itself (not just UI) is another opportunity for exactly that kind of
silent divergence, and pacing correctness is the one thing this whole
project exists to get right.

So the platform order below is chosen to maximize reuse of the *existing*
Rust core and Swift port before introducing a second implementation
language, and Phase 2 explicitly builds a second reusable core (WASM)
specifically so Chrome/Windows/Linux don't each need their own hand-port
either.

## Phase 0 — Harden the macOS baseline (do this first)

Every later phase either reuses this code directly (iOS/iPadOS) or reuses
its *shape* (everyone else). Fix it once, here, before multiplying it.

- [x] Cap accepted selection length in `AppServiceProvider.readSelection`
  (finding #1) with a clean user-facing error above the cap. 512 KiB
  (`maxSelectionBytes`, ~85,000 words); above it an alert explains the limit.
  Verified via the real Services path on 2026-09-30.
- [x] Move `tokenize(text:)`/`DisplayToken` construction off the main
  thread, or show a loading state for large-but-under-cap input. Done:
  `RsvpPlayer` tokenizes in a detached task and shows a spinner until
  ready, then auto-plays. Word counts for the progress readout are
  precomputed, so each tick is O(1).
- [x] Add adversarial-input tests against `gist-parse-txt`/`gist-rsvp`
  (long words, bidi/RTL text, zero-width joiners, degenerate whitespace) —
  a panic here is what would trigger finding #1's crash-report exposure.
  Done in `contextgist-ffi`'s tests (plus control characters, line-ending
  styles, and a 5,000-case seeded pseudo-fuzz). No panics found. As a
  second layer, the FFI exports now contain panics (`contain`) rather than
  letting them trap in Swift.
- [x] Decide and document the memory-scrubbing stance (finding #2) — even
  if the decision is "encrypted swap is enough, we're not doing explicit
  zeroing," write down *why* so it's a decision, not an oversight.
  Decision recorded under finding #2: no explicit zeroing.
- [x] Make sure the app process exits when it has nothing open (finding #2's
  decision relies on it). A 2026-09-30 hands-on check found the app still
  running after the popup was closed. That couldn't be reproduced, but a
  real gap turned up: a launch that never opened a popup (empty selection,
  "too long" alert, plain launch) never exited. Exit is now explicit
  (`AppServiceProvider.quitIfIdle()`, plus a 10 s idle timeout after
  launch) rather than relying only on AppKit's
  `applicationShouldTerminateAfterLastWindowClosed`. Verified with Debug-only
  test hooks (`CONTEXTGIST_TEST_AUTOCLOSE_AFTER` etc., see
  `PopupController.showWindow`) across five scenarios, including a
  Services-launched instance. Confirmed hands-on on the Release build
  (2026-09-30): after closing the popup, `pgrep -lf contextGIST` printed
  nothing.
- [ ] Prove out real Developer ID signing + Hardened Runtime + notarization
  on a Release build (finding #3) — do this before, not during, the first
  time this leaves the current machine. **Blocked on an Apple Developer
  account** (no signing identity on the dev machine).
  `tools/release-sign.sh` is ready and its ad-hoc path is tested.
- [x] Mirror GIST's `deny.toml` license/advisory policy in this
  workspace's `Cargo.toml` (finding #4). Done as a root `deny.toml` (the
  standard cargo-deny location, not `Cargo.toml`). `cargo deny --exclude-dev
  check` passes all four checks with cargo-deny 0.20.2. The local 0.18.3
  can't parse the current advisory DB; `cargo install cargo-deny --locked`
  fixes that.
- [x] Run `cargo deny` in CI: done in `.github/workflows/ci.yml` (`deny` job,
  also weekly so new advisories surface). Originally: no CI existed, so there
  was no automated dependency-vulnerability gate at all. CI needs no GIST checkout — Cargo fetches
  the pinned git dependency.

Release-readiness items adopted from upstream GIST's M4/M5 work (reviewed
2026-09-30; see `docs/ARCHITECTURE.md` "Upstream baseline"):

- [x] Third-party licence disclosure: `docs/THIRD-PARTY.md` plus a bundled
  `Contents/Resources/ThirdPartyNotices.txt`, both generated by
  `tools/gen-third-party.sh` (mirrors GIST `401a972`). Re-run it after any
  `Cargo.lock` change.
- [x] `docs/PRIVACY.md` (mirrors GIST `17154ea`).
- [x] `tools/build-dmg.sh`: unsigned DMG packaging, adapted from GIST
  `b20908d`. GIST's `release-macos.yml` workflow wasn't ported because this
  repo has no CI yet (the GitHub remote exists now); port it once CI is set up. Signing and
  notarization remain finding #3 above.
- [x] Universal (arm64 + x86_64) build before shipping a DMG to anyone else.
  Release builds are now universal (`gen-bindings.sh` lipo's both slices;
  `project.yml` sets per-configuration library paths). Both slices link the
  Rust core; the x86_64 slice hasn't been *run* (no Intel Mac or Rosetta on
  the dev machine).
- [x] App icon: `AppIcon.icon`, generated from GIST's macOS artwork by
  `tools/gen-app-icon.sh` (see `docs/ARCHITECTURE.md` "App icon").
- [x] VoiceOver pass on the popup (labels, one-element word display) and a
  contrast check on the ORP letter (mirrors GIST `0e44caa`'s approach).
  Hands-on VoiceOver verification is still needed.

### Added by the 2026-10-01 status review

State at review: `main` == `origin/main`, tree clean, 13/13 Rust tests,
`cargo deny` clean, CI green (the first CI run failed only because
`uniffi-bindgen` wasn't installed; fixed in `44eb967`).

- [x] **Adopt GIST `fb6946a`** (done 2026-10-01) (gist#79, fixes #78: `orp_index` counts
  grapheme clusters, not chars — the ORP could land inside an emoji, flag
  or accented letter, and disagreed with Swift's `OrpCalculator`). Baseline
  and pin are at `9dc537c`; GIST `main` is `fb6946a`. Steps: check how
  `orp_index` is used in `contextgist-ffi` and `RsvpView.swift`
  (`WordDisplay` computes the reticle offset from character counts, so
  confirm it counts the same units); add emoji/flag/combining-mark ORP
  cases to the FFI tests (extend
  `zero_width_joiners_emoji_and_combining_marks`); move the pin with
  `tools/upstream-review.sh --record "..."`; commit. **Blocks
  `release-sign.sh`** until recorded. Other review categories (Swift
  pacing/ORP, icon, security policy) had no changes.
- [x] **Swift-side test coverage** (done 2026-10-01). `contextGISTTests`
  (`apps/macos/Tests/PacingParityTests.swift`, 11 tests) checks
  `PacingEngine`, `DisplayToken` and `skipWords` against
  `Tests/golden.json`, which `contextgist-ffi`'s
  `golden_file_matches_gist_rsvp` generates from the real GIST crates
  (tokenization, ORP offsets, per-token durations at 7 WPMs,
  `token_at_elapsed`). The Rust test fails when the file is stale, so moving
  the GIST pin forces `UPDATE_GOLDEN=1 cargo test -p contextgist-ffi golden`
  and a Swift re-run. Runs in CI (`xcodebuild test`). Mutation-checked:
  dropping the `elapsedMs` rounding or a clause rule fails the suite. Not
  covered: rendering/`WordDisplay` layout, VoiceOver, the Services flow.
- [x] **Run `upstream-review.sh --check --strict` in CI** (done 2026-10-01):
  the `upstream` job in `.github/workflows/ci.yml` clones GIST and runs it,
  printing the full report on failure. Scheduled (weekly) and manual
  (`workflow_dispatch`) only, not on push/PR, so an unrelated GIST commit
  never turns a contextGIST PR red.
- [ ] **Refresh `docs/SECURITY_REVIEW.md`** before any public distribution
  (it is a 2026-09-25 point-in-time review; re-check its findings against
  current code, including CI/workflow changes made since).
- [x] **Regenerate `docs/THIRD-PARTY.md`** (done 2026-10-01: ran, no diff — `unicode-segmentation` was already in the tree) only if the pin bump changes
  `Cargo.lock` (`tools/gen-third-party.sh`); keep `docs/PRIVACY.md` true.
- [ ] Update `CLAUDE.md` "Current state" with the 2026-10-01 review and the
  CI addition once the adoption above lands.

## Phase 1 — iPhone / iPadOS: Share Extension

**Why first**: lowest effort of the five, because almost everything is
already built. `crates/contextgist-ffi` already exports through uniffi to
Swift; the Swift port of the pacing math and the ORP-centered `WordDisplay`
already exist in `apps/macos/Sources/RsvpView.swift`; SwiftUI views are
largely cross-platform as-is. This phase is mostly *packaging*, not new
logic — which also makes it the cheapest place to prove the Phase 0 input
cap actually matters: iOS App Extensions run under a hard memory ceiling
(historically tens of MB for a Share Extension) and get jetsam-killed, not
gracefully degraded, if they exceed it. A 256 MB tokenized-text buffer that
was merely slow on macOS is fatal here — Phase 0's cap becomes load-bearing,
not just tidy.

- [ ] Add an iOS/iPadOS target + a Share Extension target to `project.yml`
  (same XcodeGen tool, new platform entries).
  `gen-bindings.sh` builds `contextgist-ffi` for macOS only (host arch for
  Debug, universal for Release) — extend it (or add a sibling script) to build for iOS device +
  simulator slices via `cargo build --target aarch64-apple-ios` etc., and
  decide whether to introduce the `.xcframework` step GIST's own repo uses
  (contextGIST deliberately skipped it for macOS-only — that reasoning no
  longer holds once iOS is in the picture).
- [ ] Share Extension entry point: `NSExtensionActivationRule` restricted to
  plain text (mirrors the macOS `NSSendTypes` restriction — same "input
  only" principle from Security Review strength #6).
- [ ] Reuse `RsvpView`/`RsvpPlayer`/`PacingEngine`/`WordDisplay` as a shared
  Swift source group between the macOS and iOS targets rather than
  duplicating — this is the whole point of doing iOS second.
- [ ] Re-verify every Phase 0 item actually holds under the extension's
  memory ceiling (this is where the cap gets load-bearing, per above).
- [ ] App Store review: sandboxed, no network, no persistence — should be a
  straightforward privacy story, but confirm the App Privacy "nutrition
  label" answers match reality (no data collected, full stop) before
  submitting.

## Phase 2 — Build a WASM core (foundation for Chrome, later Windows/Linux)

**Why before Chrome**: same "don't hand-port pacing a third time" reasoning
as above. Compile `gist-model`/`gist-parse-txt`/`gist-rsvp` to WASM via
`wasm-bindgen`, exposing the same three-function surface
`contextgist-ffi` already settled on (`tokenize`, `default_config`,
`orp_index`) — a new thin crate, e.g. `crates/contextgist-wasm`, mirroring
`contextgist-ffi`'s shape rather than modifying it.

- [ ] New `contextgist-wasm` crate: same three pure functions, same
  pinned git dependencies on `BelongaGezza/gist`, `wasm-bindgen` instead of
  `uniffi`.
- [ ] Port `PacingEngine`'s wall-clock tick logic to TypeScript/JS *once*,
  written against this WASM module — this becomes the JS-side reference the
  same way the Swift `PacingEngine` is the Swift-side reference. Document
  the sync relationship the same way `RsvpView.swift`'s header comment
  already does for Swift, so the next platform doesn't have to rediscover
  this convention.
- [ ] Note on the FFI-per-tick question: the architecture doc explains why
  GIST's Swift shell avoids driving playback through FFI every frame
  (uniffi/ObjC-bridge round-trip jitter). A same-process WASM call has
  different, generally lower and more deterministic overhead than crossing
  a language-runtime IPC-style bridge — worth actually measuring before
  assuming the same avoidance is necessary here, rather than copying the
  constraint by default. If ticking through WASM directly is smooth, that's
  a simpler design than another hand-ported wall-clock engine.
- [ ] Property/golden tests: feed the same fixed set of inputs to
  `contextgist-ffi` (Swift/uniffi) and `contextgist-wasm`, assert identical
  token streams, ORP indices, and durations. This is the concrete guard
  against the "kept in sync by comment reference" fragility — turn the
  comment into a test.

## Phase 3 — Chrome extension

Built on Phase 2's WASM core, so no fourth pacing-logic hand-port.

- [ ] Manifest V3, minimal permissions: `contextMenus` only. Chrome's
  `contextMenus` API delivers the selected text directly via
  `info.selectionText` when the menu item fires — **no `activeTab`, no host
  permissions, and no content-script injection needed**, which both
  minimizes attack surface and matches contextGIST's existing "narrow,
  input-only" design principle (Security Review strength #6) better than
  any content-script-based approach would.
- [ ] Render the popup as a dedicated extension window
  (`chrome.windows.create({type: "popup"})`) rather than an in-page overlay
  — avoids fighting the host page's CSS/CSP and keeps the same "floating,
  separate window" feel as the macOS `NSWindow`.
- [ ] CSP: Manifest V3 requires `'wasm-unsafe-eval'` in the extension's CSP
  to run WASM — standard and allowed, just don't forget it.
- [ ] No network calls, no remote code, no data collection — should map to
  a clean Chrome Web Store privacy disclosure; write it accurately rather
  than from a template.
- [ ] Firefox/Edge/Safari-extension portability is a near-free follow-on
  once the Manifest V3 + WASM core exists (Edge is Chromium already; Safari
  Web Extensions and Firefox both support the same `contextMenus`+WASM
  shape with small manifest differences) — not in scope for this plan, but
  worth noting so Phase 3's design doesn't accidentally lock into a
  Chrome-only API.

## Phase 4 — Windows 11

- [ ] **Recommended shell: Tauri.** Reuses `contextgist-ffi`-shaped Rust
  core as a native Rust dependency directly (no WASM layer needed on
  desktop — that's a browser constraint, not a Windows one), small
  footprint, and the same shell can very likely be reused for Phase 5
  (Linux) with only packaging differences.
- [ ] **Entry point, primary**: register as a Windows Share Target (the
  Share contract most text-capable apps already support) — the closest
  real analog to macOS Services. Not universal (not every app implements
  Share), but clean and requires no synthetic input.
- [ ] **Entry point, fallback, flag explicitly to the user before
  building**: a global hotkey that programmatically sends Ctrl+C to grab
  the current selection when the target app has no Share support. This is
  a real security/privacy tradeoff, not a free convenience feature — it
  (a) requires input-simulation privileges, and (b) **overwrites the
  user's actual clipboard**, which can propagate into Windows Clipboard
  History and any cloud clipboard sync the user has enabled. If built:
  save and restore the clipboard's prior contents immediately after
  reading, and disclose the momentary clipboard overwrite in the UI, not
  just a changelog.
- [ ] Packaging: MSIX with a minimal capability list (no network, no
  filesystem capabilities declared — mirror the macOS entitlements file's
  "sandboxed, nothing extra" posture), signed with a real code-signing
  cert to avoid SmartScreen friction, Microsoft Store distribution
  preferred for the trust baseline it gives for free.

## Phase 5 — Linux

- [ ] Reuse the Tauri shell from Phase 4 where possible; packaging is the
  main divergence (target Flatpak for the sandboxing story it gives —
  comparable in spirit to the macOS App Sandbox entitlement).
- [ ] **Entry point — needs an early spike before committing, flagged as
  higher-uncertainty than every other phase in this plan**: there is no
  single Linux desktop-integration standard the way Services/Share/
  context-menu APIs exist elsewhere. The most promising angle is X11's
  PRIMARY selection (the buffer that's already populated by the act of
  selecting text, no explicit copy needed — genuinely the closest
  behavioral match to macOS's Services flow of any option across any
  platform in this plan) via `xclip`/direct X11 calls, bound to a
  user-configured global shortcut. Wayland support for the equivalent
  primary-selection buffer is compositor-dependent (`wl-clipboard` covers
  some but not all compositors) and needs to be spiked rather than assumed.
  Flatpak's portal model may also restrict clipboard/input-capture access
  in ways that need checking against whatever this spike lands on.
- [ ] Because of the above, don't sequence Linux work assuming a fixed
  design going in — budget explicit spike time before the "real" Linux
  build starts.

## Cross-cutting, ongoing across all phases

- [ ] **Behavioral parity tests**: the golden-file approach from Phase 2
  (same fixed inputs → identical tokenization/ORP/duration output) should
  extend to cover every shipped core (Swift/uniffi, WASM, native Rust in
  Tauri) as each one comes online — this is the concrete answer to "how do
  we know pacing hasn't silently drifted between platforms," which is
  otherwise just trust.
- [ ] **Security baseline checklist per platform**, carried from
  `docs/SECURITY_REVIEW.md`'s "strengths worth preserving" list: sandboxed
  (or platform-equivalent), no network capability, no telemetry, no
  logging of selected text, input-only (no write-back to clipboard/
  source), memory-safe core. Treat any platform where one of these can't be
  matched (the Windows clipboard fallback in Phase 4 is the one already
  identified) as requiring explicit disclosure, not silent scope creep.
- [x] **Upstream review built into the development cycle** (2026-09-30):
  `tools/upstream-review.sh` reports GIST changes since `UPSTREAM_BASELINE`,
  grouped by how they reach contextGIST. Every build warns when watched
  GIST code has changed; `release-sign.sh` refuses to sign until it's been
  reviewed and recorded (`--record`, which also runs the tests). Procedure:
  `docs/ARCHITECTURE.md` "Upstream baseline". Motivation: GIST's own
  2026-09-29 review (its finding F30) found that reviews done only on
  explicit request let ~4,700 lines land unreviewed. Don't repeat that
  here.
- [ ] **Ongoing** (last run 2026-10-01: `fb6946a` adopted, baseline
  now `fb6946a`): when the
  build shows the upstream warning, or at the
  start of a work session, run the review, act on it, and `--record` it.
  The weekly CI `upstream` job now does the check too.
- [ ] Re-run a security review pass (informal is fine) at the end of each
  phase before that platform ships — this doc's Phase 0 review was cheap
  precisely because the codebase was still small; don't let five platforms'
  worth of code accumulate before the next real look.
