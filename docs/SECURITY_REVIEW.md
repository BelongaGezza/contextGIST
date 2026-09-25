# Security review — 2026-09-25

Point-in-time manual review of the full codebase (no commits exist yet, so
there was no meaningful diff to review against — every file below was read
in full). Scope: `crates/contextgist-ffi`, `apps/macos/Sources`,
`apps/macos/Info.plist`/`project.yml`/`contextGIST.entitlements`,
`tools/gen-bindings.sh`, and the Cargo/toolchain manifests. Re-run (or at
minimum re-skim this doc) before each new platform ships, and again before
any public distribution.

## Summary

Attack surface is genuinely small: no network access, no file I/O, no
persistence, App Sandbox already enabled with zero extra entitlements, and
the only external input is text delivered by the OS through the Services
mechanism. No memory-safety bugs were found — there is no `unsafe` Rust
anywhere in the dependency chain this crate actually uses
(`contextgist-ffi`, `gist-model`, `gist-parse-txt`, `gist-rsvp`), and the
Swift code has no force-unwraps and consistently bounds-checks array
access. Nothing here rises to "vulnerability" in the RCE/injection/auth-
bypass sense — there's no auth and nothing to inject into. The findings
below are robustness/privacy-hygiene gaps, ranked by what could actually go
wrong.

## Findings

### 1. [Medium] Unbounded selection size → main-thread DoS, and a crash-report privacy leak

`AppServiceProvider.readSelection` (`apps/macos/Sources/AppServiceProvider.swift:15`)
accepts whatever string the sending app puts on the pasteboard, with no
length check, before handing it to `RsvpPlayer.init` → `tokenize(text:)`
(`apps/macos/Sources/RsvpView.swift:202-204`), which runs synchronously on
the main thread (`DispatchQueue.main.async` in `AppServiceProvider.swift:19`
just schedules `show(text:)`, it doesn't move tokenization off-main). The
Rust side has a real ceiling (`gist_model::ParseLimits::default().max_bytes`
= 256 MB — see `~/develop/reader/crates/gist-model/src/lib.rs:11`), but
nothing stops a misbehaving or malicious Services-sending app from handing
over a pasteboard string near that size, and `tokens = ffiTokens.map(DisplayToken.init)`
then eagerly materializes the *entire* token stream (each with an `orp_index`
FFI round-trip) before the popup can render anything.

Two consequences:
- **Availability**: a large-enough selection freezes the popup (and briefly
  the whole accessory process) on the main thread, worst case an OOM kill.
  Low severity on its own — it's a small helper app, not a privileged
  service — but,
- **Privacy**: contextGIST's entire value proposition is "the text never
  persists." If a pathological or malformed input causes the app to crash
  while that text is still in memory (e.g. a panic surfacing as a Swift/Rust
  trap), macOS's crash reporter can write a diagnostic report — including
  memory/backtrace contents — to `~/Library/Logs/DiagnosticReports`. That
  would silently break the "nothing persists" guarantee via a path nobody
  audits.

**Recommendation**: cap accepted selection length in
`AppServiceProvider.readSelection` (a few hundred KB is generous for an
RSVP reading session — nobody speed-reads a 256 MB selection) with a clean
user-facing error above the cap; move tokenization off the main thread or
show a loading state; add adversarial-input tests (very long words, mixed
RTL/bidi text, zero-width joiners, degenerate whitespace) against
`gist-parse-txt`/`gist-rsvp` to catch panics before they reach a shipped
build, since a panic is exactly what would trigger the crash-report
exposure above.

### 2. [Low] No explicit memory scrubbing of sensitive text after close

Swift `String`/Rust `String` heap allocations aren't zeroed on
deallocation. `PopupController`'s `windowWillClose` → `onClose()` →
`popup = nil` (`AppServiceProvider.swift:31`) drops all *references*, which
is correct and sufficient for the stated "no persistence" claim (nothing is
ever written to disk deliberately), but doesn't scrub the freed heap pages.
macOS's default encrypted swap mitigates the on-disk-swap case; the
realistic residual risk is a future crash dump (see #1) or a memory-
inspection tool run against a live process. Not recommending heavyweight
mitigation (`mlock`/explicit zeroing) unless the product wants to make a
stronger claim than "we don't persist it ourselves" — flagging as a
conscious decision point, not a bug.

### 3. [Low] Distribution signing story is unproven

The build log shows `note: Disabling hardened runtime with ad-hoc
codesigning` — expected and fine for local `xcodebuild` runs
(`CODE_SIGN_STYLE: Automatic` in `project.yml` with no team configured), but
means Hardened Runtime (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml:12`)
isn't actually engaged in the build that's been tested so far. Before this
ever leaves this machine: sign Release builds with a real Developer ID,
confirm Hardened Runtime is actually active (not silently downgraded like
the ad-hoc debug build), and notarize — otherwise Gatekeeper blocks or
scares off every other user.

### 4. [Low] Supply-chain: unpinned path dependency

`crates/contextgist-ffi/Cargo.toml` depends on `gist-model`/`gist-parse-txt`/
`gist-rsvp` via relative path into `~/develop/reader/crates/`
(`Cargo.toml:15-17`). `Cargo.lock` doesn't hash path dependencies the way it
hashes registry deps, so there's no integrity check between builds — any
change in the sibling repo (intentional, accidental, or malicious if that
repo's supply chain is ever compromised) flows into contextGIST's very next
build with no review gate specific to this repo. Fine for solo local dev
(today's reality); becomes a real gap the moment there's a second
contributor or a CI pipeline. `~/develop/reader` already has a `deny.toml`
(license + advisory policy) that contextGIST doesn't currently mirror.

**Recommendation**: once this project has more than one builder, replace
the loose path dependency with something pinned (a git dependency at a
specific rev, or promote the shared crates into a proper internal
workspace/registry) and adopt the same `deny.toml` convention. This also
directly sets up the multi-platform plan below, which needs a real answer
to "what does the shared core crate look like" anyway.

## Strengths worth preserving on every future platform

These aren't gaps — they're the baseline every new platform target should
be held to, not just "nice to have":

- App Sandbox on, zero extra entitlements (`contextGIST.entitlements`).
- No network entitlement/capability anywhere, no telemetry, no analytics.
- No logging of selected text (or anything else) — `grep` for
  `print`/`NSLog`/`os_log`/`Logger` across `apps/macos/Sources` and
  `crates/contextgist-ffi/src` returns nothing.
- No `unsafe` Rust in the entire dependency chain actually used.
- No force-unwraps (`!`/`try!`/`as!`) in the Swift code; every array
  subscript in the pacing/index logic is bounds-checked.
- Input-only Services registration (`NSSendTypes` only, no
  `NSReturnTypes`) — contextGIST structurally cannot write back to the
  pasteboard or the source document.
