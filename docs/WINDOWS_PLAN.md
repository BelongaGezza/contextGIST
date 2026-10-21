# Windows 11 plan

Architecture review and implementation plan, written 2026-10-21 on the Windows
dev machine. It **supersedes Phase 4 of
[`DEVELOPMENT_PLAN.md`](./DEVELOPMENT_PLAN.md)** and the Windows checklist in
[`PLATFORMS.md`](./PLATFORMS.md), which were drafted before anyone built on
Windows. Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) first.

## 1. What the review found

| # | Finding | Consequence |
|---|---------|-------------|
| W1 | **Share Target is not the Windows analog of macOS Services.** Share is a *source-initiated* contract: an app opens the Share sheet with content it chooses (a link, a file). Most desktop apps (Notepad, Word, PDF viewers, terminals) offer no "share my current text selection" command. A Share Target also needs package identity (MSIX, or a sparse package for unpackaged exes — [MS Learn: receive shares](https://learn.microsoft.com/windows/apps/develop/windows-integration/integrate-sharesheet-receive)). | The plan's "primary" entry point would cover few real apps. Demote it to a secondary entry point. |
| W2 | **There is no OS-brokered "selection" channel on Windows.** The app must go and fetch the selection, so it needs a resident process and a global hotkey. | Conflicts with the macOS "exit when idle" rule (Phase 0). Needs a deliberate, disclosed resident-tray design (section 3). |
| W3 | **The "Ctrl+C fallback" is better than the old plan assumed, and also worse.** Better: the documented clipboard formats `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` and `CanUploadToCloudClipboard` ([MS Learn](https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats)) can keep our restore out of Clipboard History and cloud sync. Worse: the *synthetic copy itself* is written by the source app, which does not set those formats, so the selection can still land in history. | Prefer UI Automation (no clipboard) first; Ctrl+C is last resort, opt-in, and disclosed (section 4). |
| W4 | **Tauri conflicts with the project's own guiding constraint.** A WebView UI means the pacing engine is re-implemented in JS, the third hand-port `DEVELOPMENT_PLAN.md` says not to make. It also adds an npm supply chain outside `cargo deny`, depends on the WebView2 runtime, ~100 MB+ of resident memory for a one-word popup, and a WebView2 user-data folder on disk unless run InPrivate. | Do not default to Tauri (section 2). |
| W5 | **A better reuse path exists than any port.** `gist_rsvp::RsvpSession` already has `token_at_elapsed`, `seek`, `pause`, `resume`, `back_words` and `set_wpm`, and it is pure and timer-free. A Rust shell calls it in-process, so the "no per-tick FFI" rule (which exists for the uniffi/Swift bridge) does not apply and no `PacingEngine` port is needed. | Windows pacing is *zero* hand-ported code. Parity is by construction, and the golden file becomes a regression check rather than the only guard. |
| W6 | **MSIX "sandboxed, no filesystem" is not achievable for a full-trust app.** Reading another process's selection (UIA) and sending input needs a `runFullTrust` (restricted-capability) packaged Win32 app, not an AppContainer. | The "sandboxed" item in the security baseline cannot be matched on Windows. Disclose it in `PRIVACY.md` rather than claiming parity. |
| W7 | **UIPI (integrity levels).** A normal-integrity process cannot read from or send input to an elevated window. | Selections in "Run as administrator" apps will fail. Show a clear message; never ask users to run contextGIST elevated. Document as a known limit. |
| W8 | **Real bug on this machine: golden test fails on a stock Windows checkout.** `core.autocrlf=true` checks `golden.json` (and `tools/*.sh`) out with CRLF; `golden_file_matches_gist_rsvp` compares bytes, so `cargo test --workspace --locked` reports 14 passed / 1 failed (verified 2026-10-21; `git ls-files --eol` shows `w/crlf`). Shell scripts checked out with CRLF would also break if run from Git Bash/WSL. | Fix first (step 0). CI on `windows-latest` would hit the same failure. |
| W9 | `rust-toolchain.toml` lists only Apple targets, so Windows contributors get Apple std libs downloaded and no Windows ARM64 target. | Move target lists out of the toml (installed by scripts) or add Windows targets (step 0). |
| W10 | The parent `develop/CLAUDE.md` assumes Flutter/Dart for all targets; this repo is Rust + native shells, per its own `CLAUDE.md` and `ARCHITECTURE.md`. | The repo-level CLAUDE.md governs here. Platform-guard comments still apply to any shared code that gains `#[cfg(windows)]` paths. |

Environment checked on 2026-10-21: Windows 11 x64, Rust (MSVC host, 1.97.1
pinned toolchain), Node, WebView2 155, Windows SDK 10.0.26100 present; `cl`/
`link`/`signtool`/`makeappx` are not on `PATH` (use a VS Developer prompt or
add their directories in the packaging script).

## 2. Shell decision

| Option | Pacing | Footprint / supply chain | Accessibility | Verdict |
|--------|--------|--------------------------|---------------|---------|
| **Native Rust UI (egui/eframe, or Slint)** | Calls `RsvpSession` directly. No port. | Single exe, no webview, all deps under `cargo deny`. | AccessKit gives UIA support; must be verified with Narrator. | **Recommended** |
| Tauri v2 | Needs a JS engine or a Rust-in-the-loop IPC per tick. | WebView2 + npm tree; InPrivate/data-dir hardening required. | Good (web a11y). | Fallback if the native spike fails a11y or text-rendering checks |
| WinUI 3 / windows-rs | Calls Rust core via a thin binding. | Big runtime, C#/C++ toolchain. | Best. | Overkill for one popup; revisit only if the Store requires it |

Run a **time-boxed spike (1–2 days)** before committing, with three pass/fail
checks on a prototype popup: (a) monospaced ORP-centred word with no jitter at
1000 WPM on a 60 Hz and a 144 Hz display; (b) Narrator reads the word as one
element, matching the macOS VoiceOver behaviour; (c) always-on-top, no-focus-
steal popup that returns focus to the source app on close. The spike must also
check the licence of the chosen toolkit against `deny.toml` (Slint has
non-MIT licensing terms; egui is MIT/Apache-2.0). Record the outcome in
`ARCHITECTURE.md`. Linux then reuses the same shell (egui and Slint both run
on X11 and Wayland).

## 3. Process model

- **Tray-resident app**, because a global hotkey needs a live process.
  `RegisterHotKey` only (never a low-level keyboard hook: it would see every
  keystroke, which is exactly the wrong privacy story).
- Start at login is **off by default** and opt-in (a tray menu toggle that
  writes the standard `Run` key / MSIX `StartupTask`). Disclose it.
- The resident process holds **no text**. Text exists only inside the popup
  controller from capture until the window closes; closing drops the
  `RsvpSession`/token `Vec`. No logging of selected text; panic hook silenced
  as in `contain()`.
- Single instance (named mutex); a second launch just focuses the tray icon or
  triggers a read.
- Cap: reject selections over 512 KiB (same constant as macOS), show a
  non-blocking message, tokenize on a worker thread with a spinner.

## 4. Capture strategy (replaces the old "Share primary, hotkey fallback")

Ordered, first success wins, all behind one hotkey (default `Ctrl+Alt+R`,
user-rebindable, with a clear message if the combo is already registered):

1. **UI Automation TextPattern** on the focused element
   (`IUIAutomationTextPattern::GetSelection`). Read-only, no clipboard, no
   synthetic input. Works for many Win32/WPF/WinUI/Edge/Word controls. Chromium
   and Electron expose it only when accessibility is active, so it will miss
   some apps.
2. **Explicit Share Target** (MSIX, `Text` data format only). Covers apps that
   do offer "Share" with text, and gives a store-friendly, permission-free
   path. Secondary because of W1.
3. **Simulated copy, off by default.** Settings toggle "Allow capture via
   Ctrl+C (briefly uses the clipboard)". When enabled: snapshot the clipboard
   (all formats), `SendInput` Ctrl+C, wait on `GetClipboardSequenceNumber`
   (timeout 300 ms), read `CF_UNICODETEXT`, then restore the snapshot while
   writing the three exclusion formats. State plainly in the UI and
   `PRIVACY.md` that the source app's own copy may still be recorded by
   Clipboard History or cloud sync (W3). Never touch the clipboard if the
   sequence number did not change.
4. **Manual paste** in the popup (Ctrl+V into an empty reader). This is the
   "always works" floor, including for elevated windows (W7), and it needs no
   special privileges.

Detect and report failure honestly ("couldn't read a selection from this
app — try Ctrl+C then the hotkey again, or paste") instead of silently
reading stale clipboard text.

## 5. Code layout and shared-core work (PRs against `main`, in order)

0. **Hygiene, small PR:** add `.gitattributes` (`* text=auto`, `*.json text
   eol=lf`, `*.sh text eol=lf`, `*.ps1 text eol=crlf`), re-normalize, confirm
   `cargo test --workspace --locked` is 15/15 on Windows; handle the Windows
   targets from the packaging script, leaving the Apple targets in
   `rust-toolchain.toml` untouched (W9, 5a).
1. **Extract `crates/contextgist-core`** (plain Rust, no uniffi; `tokenize`,
   `default_config`, `orp_index`, `contain`, the 512 KiB cap) and make
   `contextgist-ffi` a thin wrapper. macOS tests must stay green (see 5a). Move the
   golden test to the core, with a line-ending-tolerant comparison, and have
   it write to a platform-neutral path (`tests/golden.json`) that Swift also
   reads.
2. **Add a Windows parity test:** drive `RsvpSession` for the same inputs and
   assert the displayed token and duration sequences equal `golden.json`
   (Rust-vs-Rust, so cheap), plus a control-semantics test for rewind /
   fast-forward / speed that mirrors `skipWords` in the Swift tests, so
   rewind and fast-forward feel the same on both platforms.
3. **`apps/windows`** as a Cargo workspace member: `capture` (UIA, hotkey,
   clipboard fallback), `popup` (UI), `tray`, `single_instance`. Use the
   `windows` crate for Win32/UIA; keep every `unsafe` block small, commented
   and confined to `capture`.
4. CI: add a `windows-latest` job (build, `cargo test --workspace --locked`,
   `cargo clippy -D warnings` for the Windows crate), path-filtered so it does
   not gate macOS changes. Run `cargo deny --exclude-dev check` with the
   Windows target.

### 5a. Not breaking macOS (or Linux, iOS, Chrome later)

Status of this branch: only `docs/` and `apps/windows/README.md` changed.
Nothing in `crates/`, `tools/`, `.github/`, `Cargo.*`, `apps/macos/` or
`rust-toolchain.toml` is touched, and no script or workflow reads the edited
docs (only code comments mention them). The risks begin with the shared-core
steps above, so each carries a rule and a gate.

| Risk | Rule |
|------|------|
| `contextgist-core` extraction changes the uniffi surface | `contextgist-ffi` keeps its exported function, record and enum names, `crate-type = ["staticlib", "rlib"]` (no `cdylib`, see the comment in its `Cargo.toml`), and `panic = "unwind"`. Gate: regenerate bindings with `tools/gen-bindings.sh` and diff `apps/macos/Generated/*.swift` against the pre-change output: zero diff expected |
| `golden.json` moved or reformatted | Keep `apps/macos/Tests/golden.json` where it is until the macOS project is updated in a macOS session (Apple-side files are off limits from Windows, `CLAUDE.md` section 7). Core tests may read the same path. Gate: file bytes unchanged; Swift `xcodebuild test` green in CI |
| New Windows crate breaks `cargo test --workspace` on macOS/Linux CI | Make `apps/windows` a member but gate it: `windows` dependencies under `[target.'cfg(windows)'.dependencies]`, the `main` and modules under `#[cfg(windows)]` (with a stub `main` elsewhere), and set `default-members` so non-Windows jobs skip it. Gate: the existing `rust` (ubuntu) and `macos` jobs pass unchanged |
| `Cargo.lock` grows (`windows`, UI toolkit) | The macOS build uses `--locked`, so commit the updated lock in the same PR. Re-run `tools/gen-third-party.sh` (it regenerates the bundled macOS `ThirdPartyNotices.txt` too) and `cargo deny --exclude-dev check`; confirm the macOS notices only gain entries that actually ship there, or scope the generator per platform. Gate: `deny` job green |
| `.gitattributes` changes line endings or touches binaries | Only LF-pin `*.json`, `*.sh`, `*.rs`, `*.toml`, `*.yml`, `*.swift`; mark `*.dmg`, `*.png`, `*.icon` as `binary`. Do not use a bare `* text=auto` re-normalise of the whole tree. Gate: `git ls-files --eol` shows no `w/crlf` on those types and `git diff --stat` after `git add --renormalize .` lists no binary files |
| `rust-toolchain.toml` targets | Keep `aarch64-apple-darwin` and `x86_64-apple-darwin` (macOS Release is universal). Do not add Windows targets there, because rustup would install them everywhere; have `package-windows.ps1` run `rustup target add` instead. Gate: macOS `gen-bindings.sh` Release lipo still works |
| Pin or `UPSTREAM_BASELINE` moves | Windows work never moves the GIST pin. Only `tools/upstream-review.sh --record` does, and it runs tests for every platform first (`PLATFORMS.md` rule 4) |
| Windows-only `#[cfg]` leaks into shared crates | Shared crates (`contextgist-core`, `contextgist-ffi`) stay platform-neutral; OS code lives only in `apps/windows`. Where shared code ever needs a branch, use a `[PLATFORM: Windows]` guard comment and flag it for review |
| One platform's CI gating another | Path-filter jobs: macOS jobs run on `crates/**`, `apps/macos/**`, `tools/**`; the Windows job on `crates/**`, `apps/windows/**`. Anything under `crates/**` runs both, which is the intended gate for shared changes |

Merge order for shared changes: (1) `.gitattributes`, (2) core extraction,
(3) Windows crate. Each is its own PR and must show green `rust`, `deny`,
`macos` and `windows` jobs before the next starts. A Windows PR that turns the
macOS job red is reverted, not patched forward.

Hands-on check that cannot be done from this machine: building and launching
the macOS app after the core extraction. Record it as
`// TODO(test): verify on [PLATFORM: macOS]` and run
`./tools/gen-bindings.sh && cd apps/macos && xcodegen generate && xcodebuild test -scheme contextGIST`
in the next macOS session before tagging a macOS release.

## 6. Packaging, signing, distribution

- **MSIX (full-trust Win32)**, x64 and ARM64 bundles, capabilities limited to
  `runFullTrust`. No `internetClient`, no file-system capabilities. The Store
  needs a justification for `runFullTrust`; the answer is cross-process
  selection reading. Write it down before submission.
- `tools/package-windows.ps1` builds both architectures, makes the MSIX with
  `makeappx`, signs with `signtool` (cert from env/CI secret), and writes to
  `dist/windows/` along with `INSTALL.txt`.
- **Signing blocks public release**, same as notarization on macOS (security
  review finding #3). Until then ship an unsigned/self-signed MSIX plus
  `INSTALL.txt` explaining SmartScreen and how to trust the test cert. Decide
  between Azure Trusted Signing, an OV/EV cert, or Store-only distribution (the
  Store signs for you) before the first external build.
- Release workflow on `windows-v*` tags; installer storage (committed vs
  GitHub Releases) is decided in the shared TODO in `PLATFORMS.md`, preferring
  Releases for Windows so the repo does not accumulate binaries.

## 7. Security and privacy baseline for Windows

| Baseline item (from `SECURITY_REVIEW.md`) | Windows status |
|-------------------------------------------|----------------|
| Sandboxed | **Not met** (full-trust, W6). Disclose. Mitigate with no network capability, minimal Win32 surface, hardened build (CFG, `/GUARD:CF`, ASLR, DEP are default on MSVC target; verify) |
| No network | Met: no network capability in the manifest; no HTTP client dep (enforce in `deny.toml` bans) |
| No telemetry | Met |
| No logging of selected text | Met by design; add a test that the panic hook is silent and a code review check for `println!`/`dbg!` on text |
| Input-only | Met for UIA and Share. **Not met** for the optional Ctrl+C mode (temporarily writes the clipboard). Opt-in and disclosed |
| Memory-safe core | Met (Rust); `unsafe` confined to `capture` |
| Text discarded on close | Met; test that the controller drops tokens (leak check via drop counter in a test build) |
| Crash dumps | Disable WER user-mode dumps for our process or document them (macOS finding #1 equivalent). Verify with a forced crash on a debug build |
| Persistence | None. No settings file other than hotkey, start-at-login and "allow Ctrl+C" flags (no text) in `%LOCALAPPDATA%`. Document this in `PRIVACY.md`, which currently says "no persistence of any kind" |

## 8. Phases and exit criteria

| Phase | Work | Exit criteria |
|-------|------|---------------|
| W0 | Step 0 hygiene + CI Windows job | 15/15 tests pass on `windows-latest` and locally on a fresh clone |
| W1 | Shell spike (section 2) | Written decision in `ARCHITECTURE.md`; a11y and jitter checks pass |
| W2 | `contextgist-core` extraction + Windows parity tests | macOS CI still green; Windows parity tests green |
| W3 | Popup + tray + hotkey + UIA capture + manual paste | Works end to end in Notepad, Edge, Word, a PDF viewer, VS Code; fails gracefully in an elevated window |
| W4 | Opt-in Ctrl+C mode, Share Target, start-at-login | Clipboard restored byte-for-byte for text, RTF and image contents (test); history exclusion verified on a machine with Clipboard History on |
| W5 | MSIX packaging, `package-windows.ps1`, `INSTALL.txt`, `WINDOWS_GUIDE.md`, `PRIVACY.md` and `THIRD-PARTY.md` updates, security pass (refresh `SECURITY_REVIEW.md` for Windows) | Clean install, use and uninstall on a fresh Windows 11 VM, x64 and ARM64; `cargo deny` clean |
| W6 | Signing and Store submission, tag `windows-vX.Y.Z` | Signed MSIX; Store listing's privacy answers match `PRIVACY.md` |

## 9. Testing notes (per `CLAUDE.md` section 9)

Cannot be completed on this x64 dev machine: ARM64 runtime, a clean-VM
install/uninstall, Narrator on other languages, high-DPI/multi-monitor mixes.
Mark with `// TODO(test): verify on [PLATFORM: Windows/ARM64]` and add to the
release checklist. The app is compiled for Windows only; any shared code that
gains OS-specific branches needs `[PLATFORM: Windows]` comment guards.

## 10. Open decisions for the owner

1. Shell: native Rust (recommended) vs Tauri, after the spike.
2. Distribution: Store only, or Store plus a directly signed MSIX/MSI.
3. Signing route and budget (section 6).
4. Whether the Ctrl+C fallback ships at all, given W3.
5. Default hotkey, and whether start-at-login is offered in v1.
