# Development plan

Written 2026-09-25, after the macOS app's first working build and a
security review ([`docs/SECURITY_REVIEW.md`](./SECURITY_REVIEW.md)); **rebased
2026-10-21** after the second review
([`REVIEW_2026-10-21.md`](./REVIEW_2026-10-21.md)) and PRs #1-#8. This plan
does two things: closes the gaps those reviews found, and lays out adding
contextGIST's capability to Windows 11, iPhone, iPad, Linux, and Chrome.
Platform order and the reason for it are per-phase below (Windows is now
driven by [`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md) and is being worked first
because a Windows dev machine is active; iOS remains the cheapest macOS-side
phase and needs a Mac).

Read [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) first if you haven't —
this plan assumes its framing (narrow reuse of GIST's Rust core, no
persistence, one popup per invocation).

> Working contract and per-platform TODO checklists for parallel
> Windows/Linux/macOS work: [`PLATFORMS.md`](./PLATFORMS.md).

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

## Status snapshot (2026-10-21)

| Area | State |
|------|-------|
| macOS app | Working; Services flow verified; Phase 0 hardening done except signing. Needs a Mac session for the parity items in `PENDING_APPLE_CHANGES.md` |
| Rust core (`contextgist-ffi`) | 25 tests; cap, UTF-8-only parse and 256-byte split enforced (PR #6); fmt/clippy clean and CI-gated |
| Upstream (GIST) | Pin == `UPSTREAM_BASELINE` == `5e25545`; CI asserts equality; no unreviewed upstream changes |
| CI | `ci.yml` + `windows.yml`; fmt, clippy, tests, `cargo deny`, XCTest, weekly upstream check; Dependabot on |
| Windows | Plan merged; capture spike hardened on `platform/windows/spike-fixes` (PR pending); no go/no-go data yet |
| Linux, iOS/iPadOS, WASM, Chrome | Not started |
| Release | Blocked: Apple Developer account (signing), S-01 DMG rebuild, `main` unprotected (`ci-ok` check now exists to require) |

### Next actions, in order

1. **Windows W0.5** (any machine): merge the spike fixes, run the app matrix,
   commit the raw metadata CSVs, apply the go/no-go in `WINDOWS_PLAN.md` section 8.
2. **Repo hygiene, small PRs** (any machine): branch protection on `main` with an
   always-run aggregator check; `deny.toml` Windows triples plus the
   RUSTSEC-2026-0374 decision; `.gitignore` secret patterns; `SECURITY.md`;
   portable `upstream-review.sh` (Q-04); Q-20 (upstream job opens an issue
   instead of going red).
3. **Shared core extraction** (`contextgist-core`, W2) once W0.5 says go, with
   `skip_words` and the missing golden cases (T3-T5, T14 in the review).
4. **Next macOS session**: everything in `PENDING_APPLE_CHANGES.md`, then rebuild
   the DMG without `get-task-allow` (S-01).
5. **Windows W1 shell spike and process-model decision**, then W3 onward.
6. Phases 1-3, 5 below, in the order the owner chooses.

## Phase 0 — Harden the macOS baseline

Every later phase reuses this code or its shape. **Done** (details in git
history and `SECURITY_REVIEW.md`): selection cap in `readSelection` (512 KiB);
off-main-thread tokenizing with a spinner; adversarial-input tests plus
`contain` around the FFI exports; memory-scrubbing decision (no explicit
zeroing, finding #2); explicit exit when idle (`quitIfIdle()` plus a 10 s idle
timeout; verified hands-on on Release); `deny.toml` policy and a `cargo deny`
CI job; third-party notices (`tools/gen-third-party.sh`); `docs/PRIVACY.md`;
unsigned DMG packaging (`tools/build-dmg.sh`, universal arm64 + x86_64, the
x86_64 slice linked but never run); app icon; VoiceOver labels and ORP contrast
(hands-on VoiceOver check still wanted); Swift parity tests against
`golden.json` (11 tests, CI); upstream-review tooling and the weekly CI check;
GIST `fb6946a` adoption (grapheme-cluster `orp_index`), and every later review
logged in `ARCHITECTURE.md`.

Still open from Phase 0:

- [ ] **Developer ID signing + Hardened Runtime + notarization** (finding #3).
  Blocked on an Apple Developer account. `tools/release-sign.sh` is ready; its
  ad-hoc path is tested. Do this before the build leaves the current machine.

### From the 2026-10-21 review (see its "Pending fixes" table for IDs)

Done in PR #6 (Rust core): 512 KiB cap and UTF-8-only parsing in the core
(S-04, S-12, Q-13), 256-byte token split (Q-02), extended golden (T1-T4, T6-T9).
Done in PR #8 (CI): `cargo fmt`/clippy gates, spike build, baseline==pin check,
XcodeGen checksum, `persist-credentials: false`, PR-only `cancel-in-progress`,
Dependabot.

- [ ] Swift `tokenDurationMs` to `Float`; adopt `golden_extended.json` (Q-01) — **macOS session**.
- [ ] Release build without `get-task-allow`; gate in packaging; rebuild or retire the
  committed DMG, preferably move DMGs to GitHub Releases with a published SHA-256 (S-01, S-09) — **macOS session**.
- [ ] Other Swift fixes: S-10, S-11, Q-14-Q-18, Q-21 — **macOS session** (`PENDING_APPLE_CHANGES.md`).
- [ ] Portable `upstream-review.sh`; `--record` reviews the diff before running tests; keychain
  profile and entitlement allow-list in `release-sign.sh` (Q-04, Q-24, S-07, S-15).
- [ ] Repo settings: branch protection on `main` + always-run `ci-ok` aggregator,
  `sha_pinning_required`, approval for outside workflow runs (S-08, Q-19).
- [ ] `deny.toml` Windows triples and RUSTSEC-2026-0374 handling (S-05, S-16); `.gitignore`
  secret/`*.bak`/`*.csv` patterns (S-17); `SECURITY.md`; `gen-third-party.sh` flags (Q-23).
- [ ] Core: `tokenize` status/`Result` (Q-18, uniffi signature change, needs Swift),
  `contain` stderr subprocess test, bulk `tokenize_with_orp` (Q-22); remaining tests T5, T10, T11, T13, T14.
- [ ] Q-20: the weekly `upstream` job should open or update one issue rather than go red.
- [ ] Refresh `docs/SECURITY_REVIEW.md` before any public distribution (re-done in
  part on 2026-10-21; repeat after the Swift/signing fixes above).

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

## Phase 2 — Build a WASM core (foundation for Chrome; desktop shells use the native Rust core instead)

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

**Superseded by [`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md)** (architecture review,
2026-10-21, revised after an independent adversarial review). Status: W0 done
(`.gitattributes`, Windows CI); W0.5 capture spike built and hardened, no
go/no-go data yet. Summary:

- **Gates first:** a capture-reliability spike (UI Automation hit rate across
  ~15 apps, numeric go/no-go), then a three-way shell spike that starts from
  GIST's existing WinUI 3 + uniffi-cs Windows stack versus native Rust UI
  versus a minimal Win32 window. Tauri is rejected (forces a JS pacing port).
- **Pacing:** no pacing math is hand-ported; `gist_rsvp::RsvpSession` is used,
  plus one shared `skip_words` helper in `contextgist-core`.
- **v1 scope:** global hotkey (`RegisterHotKey` only), UI Automation capture
  with password-field refusal and a 512 KiB cap, manual paste fallback, x64,
  direct download. Share Target, opt-in Ctrl+C, ARM64, MSIX/Store and
  start-at-login are post-v1.
- **Process model** (launcher-per-invocation vs resident) is decided before
  code, because a resident process changes the privacy promises.
- **Security baseline:** "sandboxed" cannot be matched (full-trust); disclosed,
  not claimed.

## Phase 5 — Linux

- [ ] Reuse whichever Rust-side pieces survive the Phase 4 shell spike; packaging is the
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
  the Windows/Linux shells) as each one comes online — this is the concrete answer to "how do
  we know pacing hasn't silently drifted between platforms," which is
  otherwise just trust.
- [ ] **Security baseline checklist per platform**, carried from
  `docs/SECURITY_REVIEW.md`'s "strengths worth preserving" list: sandboxed
  (or platform-equivalent), no network capability, no telemetry, no
  logging of selected text, input-only (no write-back to clipboard/
  source), memory-safe core. Treat any platform where one of these can't be
  matched (the post-v1 Windows Ctrl+C mode in Phase 4 is the one already
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
- [ ] **Ongoing** (last run 2026-10-21: baseline and pin `5e25545`, nothing
  to adopt): when the build shows the upstream warning, or at the start of a
  work session, run `tools/upstream-review.sh`, act on it, and `--record` it
  (macOS only until Q-04). The weekly CI `upstream` job also checks.
- [ ] Re-run a security review pass (informal is fine) at the end of each
  phase before that platform ships — this doc's Phase 0 review was cheap
  precisely because the codebase was still small; don't let five platforms'
  worth of code accumulate before the next real look.
