# Windows 11 plan

Architecture review and implementation plan, written 2026-10-21 on the Windows
dev machine. It **supersedes Phase 4 of
[`DEVELOPMENT_PLAN.md`](./DEVELOPMENT_PLAN.md)** and the Windows checklist in
[`PLATFORMS.md`](./PLATFORMS.md), which were drafted before anyone built on
Windows. Read [`ARCHITECTURE.md`](./ARCHITECTURE.md) first.

**Revised 2026-10-21 after two independent adversarial reviews** (architecture, then security + quality; findings in [`REVIEW_2026-10-21.md`](./REVIEW_2026-10-21.md)) (senior-model
pass over this plan and PRs #1-#3). It changed the plan materially: the shell
is now a three-way spike that starts from GIST's existing Windows stack, a
capture-reliability spike is the first gate, v1 is much smaller, and the
process model is an open decision. Items neither the reviewer nor we could
verify are marked **(unverified)**.

## 1. What the review found

| # | Finding | Consequence |
|---|---------|-------------|
| W1 | **Share Target is not the Windows analog of macOS Services.** Share is a *source-initiated* contract: an app opens the Share sheet with content it chooses (a link, a file). Most desktop apps (Notepad, Word, PDF viewers, terminals) offer no "share my current text selection" command. A Share Target also needs package identity (MSIX, or a sparse package for unpackaged exes — [MS Learn: receive shares](https://learn.microsoft.com/windows/apps/develop/windows-integration/integrate-sharesheet-receive)). | The plan's "primary" entry point would cover few real apps. Demote it to a secondary entry point. |
| W2 | **There is no OS-brokered "selection" channel on Windows.** The app must go and fetch the selection, so it needs a resident process and a global hotkey. | Conflicts with the macOS "exit when idle" rule (Phase 0). Needs a deliberate, disclosed resident-tray design (section 3). |
| W3 | **The "Ctrl+C fallback" is better than the old plan assumed, and also worse.** Better: the documented clipboard formats `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` and `CanUploadToCloudClipboard` ([MS Learn](https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats)) can keep our restore out of Clipboard History and cloud sync. Worse: the *synthetic copy itself* is written by the source app, which does not set those formats, so the selection can still land in history. | Prefer UI Automation (no clipboard) first; Ctrl+C is last resort, opt-in, and disclosed (section 4). |
| W4 | **Tauri conflicts with the project's own guiding constraint.** A WebView UI means the pacing engine is re-implemented in JS, the third hand-port `DEVELOPMENT_PLAN.md` says not to make. It also adds an npm supply chain outside `cargo deny`, depends on the WebView2 runtime, ~100 MB+ of resident memory for a one-word popup, and a WebView2 user-data folder on disk unless run InPrivate. | Do not default to Tauri (section 2). |
| W5 | **Pacing reuse is large but not total.** `gist_rsvp::RsvpSession` is pure and timer-free and has `token_at_elapsed`, `elapsed_at_token_end`, `seek`, `pause`, `resume`, `back_words` and `set_wpm`, so no pacing *math* is hand-ported. It has **no forward skip** (Swift's `skipWords(+1)` is a local extension), and `RsvpSession::new` runs `split_oversized_tokens` (256-byte cap) while the FFI `tokenize` output and the Swift engine do not, so token indices diverge for a word over 256 bytes. `FfiRsvpConfig` also omits `pause_on_punctuation` (default true, equal today). | One small shared helper `skip_words(tokens, from, n, dir)` and a decision on oversized tokens live in `contextgist-core`, not in a shell. Golden cases cover forward skip, oversized tokens and start/end clamps. |
| W6 | **MSIX "sandboxed, no filesystem" is not achievable for a full-trust app.** Reading another process's selection (UIA) and sending input needs a `runFullTrust` (restricted-capability) packaged Win32 app, not an AppContainer. | The "sandboxed" item in the security baseline cannot be matched on Windows. Disclose it in `PRIVACY.md` rather than claiming parity. |
| W7 | **UIPI (integrity levels).** A normal-integrity process cannot read from or send input to an elevated window. | Selections in "Run as administrator" apps will fail. Show a clear message; never ask users to run contextGIST elevated. Document as a known limit. |
| W8 | **Real bug on this machine: golden test fails on a stock Windows checkout.** `core.autocrlf=true` checks `golden.json` (and `tools/*.sh`) out with CRLF; `golden_file_matches_gist_rsvp` compares bytes, so `cargo test --workspace --locked` reports 14 passed / 1 failed (verified 2026-10-21; `git ls-files --eol` shows `w/crlf`). Shell scripts checked out with CRLF would also break if run from Git Bash/WSL. | Fix first (step 0). CI on `windows-latest` would hit the same failure. |
| W9 | `rust-toolchain.toml` lists only Apple targets, so Windows contributors get Apple std libs downloaded and no Windows ARM64 target. | Leave the Apple targets in the toml for macOS; install Windows targets from the packaging script only (step 0, 5a). |
| W10 | The parent `develop/CLAUDE.md` assumes Flutter/Dart for all targets; this repo is Rust + native shells, per its own `CLAUDE.md` and `ARCHITECTURE.md`. | The repo-level CLAUDE.md governs here. Platform-guard comments still apply to any shared code that gains `#[cfg(windows)]` paths. |
| W11 | **GIST already ships a Windows stack** (the pinned `5e25545` checkout): WinUI 3 on .NET, uniffi C# bindings via a SHA-pinned third-party generator, `IRsvpEngine` with `BackWords`/`SetWpm`/`SetPauseOnPunctuation`, UI tests, and a bindgen security review (`docs/windows-development-plan.md` ADR-015/017/018, `docs/security-review-windows-bindgen.md`). The first draft of this plan ignored it and called WinUI "overkill" without evidence. | Section 2 starts from this prior art; its findings (unreviewed bindgen pin, DLL search order) are inherited if we go that way. |
| W12 | **Capture reliability is asserted, not measured.** v1's value depends on UIA `TextPattern` hit rate across real apps, and `TextPattern` makes cross-process calls with no caching ([MS Learn](https://learn.microsoft.com/windows/win32/winauto/uiauto-about-text-and-textrange-patterns)). `GetSelection` returns an *empty range* when nothing is selected and NULL when unsupported. | A capture spike with numeric go/no-go is the first gate (section 8, phase W0.5). Chromium/Electron coverage is **(unverified)** until measured. |
| W13 | **A resident hotkey process changes the privacy model in kind.** It breaks "app quits when the window closes" and the "process exit is the effective wipe" argument in `SECURITY_REVIEW.md` finding #2, and sits in the same behavioural class as screen scrapers for AV/EDR heuristics. | Process model is an open decision with a launcher-per-invocation option (section 3). |
| W14 | `tools/upstream-review.sh` uses BSD `sed -i ''` (line 115) and `python3`; it cannot move the shared GIST pin from Windows/Linux. | Until made portable, macOS owns the pin (`PLATFORMS.md`). |

Environment checked on 2026-10-21: Windows 11 x64, Rust (MSVC host, 1.97.1
pinned toolchain), Node, WebView2 155, Windows SDK 10.0.26100 present; `cl`/
`link`/`signtool`/`makeappx` are not on `PATH` (use a VS Developer prompt or
add their directories in the packaging script).

## 2. Shell decision (three-way spike, starting from prior art)

**Prior art in GIST.** The sibling GIST repo already decided and spiked a
Windows stack: WinUI 3 + C# + uniffi-cs (ADR-015/017/018), with measured
results, a bindgen security review, UI tests and a prepared MSIX manifest.
Start by reading `docs/windows-development-plan.md`, `windows-ui-spec.md` and
`security-review-windows-bindgen.md` in the pinned checkout
(`~/.cargo/git/checkouts/gist-*/<rev>/docs/`). Inherit what applies. Known
costs of that route: an unreviewed, unmerged third-party generator pinned by
SHA, the Windows App SDK / .NET runtime weight, and an unqualified-DLL-load
finding (F8).

| Option | Pacing | Footprint / supply chain | Accessibility / text | Note |
|--------|--------|--------------------------|----------------------|------|
| **A. Native Rust UI (egui/eframe)** | Calls `RsvpSession` directly | One exe, all deps under `cargo deny` | AccessKit exposes UIA, but quality for a custom-drawn, rapidly changing word is **(unverified)**; no ClearType, weaker RTL/CJK/emoji shaping; a no-activate popup needs raw `WS_EX_NOACTIVATE`/`WS_EX_TOOLWINDOW` through winit | Slint rejected unless its licence passes `deny.toml` |
| **B. WinUI 3 via GIST's uniffi-cs approach** | `FfiRsvpEngine` wraps Rust | .NET + Windows App SDK; third-party bindgen | Best Narrator, high-contrast, DPI, text rendering | Strongest on UX; heaviest toolchain |
| **C. Minimal Win32 window** (`windows` crate + DirectWrite) | Calls `RsvpSession` | Smallest | Must hand-build UIA live-region and DPI handling | Only if A and B fail |
| Tauri | JS engine or IPC per tick | WebView2 + npm tree | Good | Rejected: forces a JS pacing hand-port |

Spike pass/fail checks (each with a number and a method, see section 8):
(a) word-to-word frame delta at 1000 WPM on 60 Hz and 144 Hz displays; (b)
Narrator reads the word as one element without flooding announcements; (c)
always-on-top popup that never steals focus and returns it on close; (d) cold
start to first word; (e) ARM64 builds; (f) licence and `cargo deny` fit; (g)
`WDA_EXCLUDEFROMCAPTURE` works on the popup. Record the decision in
`ARCHITECTURE.md`. Linux reuses whichever Rust-side pieces survive.

## 3. Process model (open decision, decide before any code)

A global hotkey needs a live process; Windows has no OS-brokered selection
channel. Two models, in order of honesty:

1. **Launcher-per-invocation (preferred).** A tiny resident stub owns only
   the `RegisterHotKey` registration and holds no text. On the hotkey it
   spawns a short-lived reader process that captures, tokenizes, shows the
   popup and **exits when the window closes**, so the text never lives in the
   resident process and "process exit is the wipe" still holds for the part
   that touches text. Cost: two processes and some extra latency
   **(unverified)**.
2. **Single resident process.** Simpler, but the popup text sits in a
   long-lived address space; the privacy docs must be rewritten for Windows
   and the "effective wipe" argument retired. Needs documented, tested memory
   hygiene.

Common rules:
- `RegisterHotKey` only. Never a low-level keyboard hook.
- Start-at-login is **off by default**, opt-in, post-v1.
- Single instance via a mutex with a **per-user SID-scoped name** and **no
  command channel**: a second launch accepts no parameters, so a squatting
  process can only deny service, not trigger reads.
- `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR)`
  at startup in every process (the unsigned-app DLL hijack finding F8 in GIST's
  review).
- Reject selections over 512 KiB (same constant as macOS); tokenize on a worker
  thread with a spinner. No logging of selected text; panic hook silent.
- Rewrite `PRIVACY.md` for Windows **before** coding, so the code is built to
  match the promise.

## 4. Capture strategy

**v1 is UI Automation plus manual paste only.** Ctrl+C simulation and Share
Target are post-v1 (see below).

Capture runs on a **worker thread with a timeout** (UIA calls into a hung
target block the caller; the hotkey handler never runs on the UI thread):

1. Get the focused element; refuse **password fields** (`IsPassword`) before
   reading anything. This is a privacy promise, not a nicety.
2. `IUIAutomationTextPattern::GetSelection`. Distinguish and message each
   outcome: *empty selection* (degenerate range, not an error), *unsupported*
   (NULL / no TextPattern), *blocked by elevation* (UIPI), *timeout/hung*,
   *too large*. Never fall back silently to stale clipboard text.
3. Read with `GetText(cap + 1)` (UTF-16 units), then measure **UTF-8 bytes**
   and refuse above 512 KiB, so the Windows cap means the same as the macOS
   one. Keep a **running UTF-8 byte total across all ranges** and stop as soon
   as it exceeds the cap; also cap the range count. (Per-range character caps
   do not bound memory: S-03.)
4. Multiple non-contiguous ranges: join in document order with a single
   paragraph break; document this.
5. The first call into Chromium/Electron may be slow or return an incomplete
   tree; retry once. Behaviour is version-dependent **(unverified)**.
6. **Classic Win32 `Edit`/`RichEdit` fallback.** Measured in the W0.5 spike:
   classic Notepad exposes only `ValuePattern`, so UIA alone returns nothing.
   Match the class name case-insensitively (`RICHEDIT50W` etc.). For plain
   `Edit`: `EM_GETSEL` for the range, `WM_GETTEXTLENGTH` checked against the
   cap **before** allocating, then `WM_GETTEXT`. For RichEdit: `EM_GETSELTEXT`
   with a buffer sized from the (bounded) selection, because `EM_GETSEL`
   offsets count CR as one character while `WM_GETTEXT` returns CRLF
   *(reasoned, not yet run)*. Never size a buffer from a target-supplied
   offset without bounding it first (S-02). Re-check `ES_PASSWORD`. Short
   timeouts. Blocked by UIPI for elevated targets, like everything else here.
7. **Manual paste floor:** an empty reader accepts Ctrl+V. It needs no
   privileges, works for elevated windows, and is the answer when 1-6 fail.

**Post-v1 (separate, documented releases):**
- *Explicit Share Target* (`Text` only, MSIX/sparse identity). Share is
  source-initiated so few apps offer selected text, but it is the one entry
  point that needs **no resident process** and fits the launcher model.
- *Opt-in Ctrl+C simulation.* Cut from v1: exact restoration of delayed-render
  or OLE clipboard data is not achievable; the source app's own copy can still
  enter Clipboard History and cloud sync despite the exclusion formats we set
  on the restore; `SendInput` is blocked to elevated windows and can land in
  the wrong window if focus shifts. If it returns, disclose it in the UI and
  `PRIVACY.md`.

## 5. Code layout and shared-core work (PRs against `main`, in order)

0. **Hygiene, small PR (#1):** add `.gitattributes` pinning explicit file
   types (no bare `* text=auto`; see 5a), re-normalize, confirm
   `cargo test --workspace --locked` is 15/15 on Windows; handle the Windows
   targets from the packaging script, leaving the Apple targets in
   `rust-toolchain.toml` untouched (W9, 5a).
1. **Extract `crates/contextgist-core`** (plain Rust, no uniffi; `tokenize`,
   `default_config`, `orp_index`, `contain`, the 512 KiB cap) and make
   `contextgist-ffi` a thin wrapper, and add the shared `skip_words` helper plus
   the oversized-token decision (W5). Keep uniffi out of core. The silent panic
   hook becomes an explicit function each shell calls, not an accidental
   process-wide side effect. macOS tests must stay green (see 5a). Move the
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

| Risk | Rule |
|------|------|
| `contextgist-core` extraction changes the uniffi surface | `contextgist-ffi` keeps its exported function, record and enum names, `crate-type = ["staticlib", "rlib"]` (no `cdylib`, see the comment in its `Cargo.toml`), and `panic = "unwind"`. Gate: regenerate bindings with `tools/gen-bindings.sh` and diff `apps/macos/Generated/*.swift` against the pre-change output: zero diff expected |
| `golden.json` moved or reformatted | Keep `apps/macos/Tests/golden.json` where it is until the macOS project is updated in a macOS session (Apple-side files are off limits from Windows, `CLAUDE.md` section 7). Core tests may read the same path. Gate: file bytes unchanged; Swift `xcodebuild test` green in CI |
| New Windows crate breaks `cargo test --workspace` on macOS/Linux CI | Make `apps/windows` a member but gate it: `windows` dependencies under `[target.'cfg(windows)'.dependencies]`, the `main` and modules under `#[cfg(windows)]` (with a stub `main` elsewhere). Gate: the existing `rust` (ubuntu) and `macos` jobs pass unchanged |
| `Cargo.lock` grows (`windows`, UI toolkit) | The macOS build uses `--locked`, so commit the updated lock in the same PR. Re-run `tools/gen-third-party.sh` (it regenerates the bundled macOS `ThirdPartyNotices.txt` too) and `cargo deny --exclude-dev check`; confirm the macOS notices only gain entries that actually ship there, or scope the generator per platform. Gate: `deny` job green |
| `.gitattributes` changes line endings or touches binaries | Pin LF for `*.json`, `*.sh`, `*.rs`, `*.toml`, `*.yml`, `*.swift`, `*.plist`, `*.entitlements`, plus `*.md`, `*.txt`, `.gitignore` and `.gitattributes` (the `.txt` pin matters because `ThirdPartyNotices.txt` and `INSTALL.txt` are copied into the DMG); mark `*.dmg`, `*.png`, `*.icns` as `binary`. No bare `* text=auto`: explicit types only, so an unlisted binary is never rewritten. Gate: `git ls-files --eol` shows no `w/crlf` on those types and `git diff --stat` after `git add --renormalize .` lists no binary files |
| `rust-toolchain.toml` targets | Keep `aarch64-apple-darwin` and `x86_64-apple-darwin` (macOS Release is universal). Do not add Windows targets there, because rustup would install them everywhere; have `package-windows.ps1` run `rustup target add` instead. Gate: macOS `gen-bindings.sh` Release lipo still works |
| Pin or `UPSTREAM_BASELINE` moves | Windows work never moves the GIST pin. Only `tools/upstream-review.sh --record` does, and it runs tests for every platform first (`PLATFORMS.md` rule 4) |
| Windows-only `#[cfg]` leaks into shared crates | Shared crates (`contextgist-core`, `contextgist-ffi`) stay platform-neutral; OS code lives only in `apps/windows`. Where shared code ever needs a branch, use a `[PLATFORM: Windows]` guard comment and flag it for review |
| `deny.toml` `[graph] targets` lists only Apple triples | Windows-only crates (`windows`, UI toolkit) are never checked until a Windows triple is added. Add `x86_64-pc-windows-msvc` in the same PR as the first Windows dependency; check licences on both |
| `--workspace` still resolves Windows-only crates on macOS/Linux | `default-members` does not stop `--workspace`, and CI uses it, so the cfg-gated stub `main` is what keeps non-Windows jobs green. Add `cargo check --workspace --locked` on all three OSes |
| `gen-third-party.sh` lists crates that don't ship on macOS | Make the generator per-platform before the lock grows |
| `upstream-review.sh --record` is BSD-only (`sed -i ''`, `python3`) | Only macOS can move the pin until the script is made portable. A pin-bump PR already triggers `windows.yml` (it watches `Cargo.toml`/`Cargo.lock`) |
| Rev-pinned git dependency on GIST | Hash-locked and source-restricted in `deny.toml` (good), but a force-push, rate limit or GIST going private breaks cold builds; CI's `~/.cargo/git` cache masks it. Mirror or tag the rev in this org, or `cargo vendor` for release builds; note as residual risk in `ARCHITECTURE.md` |
| `golden.json` path moves with the test | Keep the path unchanged until a macOS session; `UPDATE_GOLDEN=1` must write LF (guaranteed by `.gitattributes`) |
| One platform's CI gating another | Path-filter jobs (never make a path-filtered workflow a *required* check without an always-run aggregator job, or docs-only PRs hang): macOS jobs run on `crates/**`, `apps/macos/**`, `tools/**`; the Windows job on `crates/**`, `apps/windows/**`. Anything under `crates/**` runs both, which is the intended gate for shared changes |

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

- **v1: x64 only, direct download** (zip or MSIX), signed if the owner is
  eligible below, otherwise documented unsigned with `INSTALL.txt` explaining
  SmartScreen. No Store, no ARM64, no auto-start in v1.
- **Later: full-trust MSIX** (`runFullTrust`, a restricted capability that
  needs a written justification) for Store or winget, x64 + ARM64 bundles, no
  network or file-system capabilities. Whether Store policy and
  Defender/SmartScreen accept a hotkey + cross-process-UIA app is
  **(unverified)**; do a pre-submission check and keep the non-Store path.
- **Signing options (check eligibility before choosing):** Azure Artifact
  Signing (formerly Trusted Signing) costs roughly US$10/month, but
  individuals must be in the USA or Canada, organisations need an established
  history, and it does not grant instant SmartScreen trust. OV certificates
  cost roughly US$150-500/year and need a hardware token or HSM. EV no longer
  bypasses SmartScreen. Store MSIX is re-signed by Microsoft for free. The
  owner's country and entity type decide the route
  ([MS Learn: code-signing options](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options)).
  Prices and eligibility are as reported by the review and should be
  re-checked before purchase.
- **Update path** must be decided before v1 is public: Store, winget, or a
  manual "new version" notice. An unsigned resident app with no update path
  never receives security fixes.
- `tools/package-windows.ps1` builds, packages, signs (cert from env/CI
  secret) and writes `dist/windows/` plus `INSTALL.txt`. It also runs
  `rustup target add` for Windows triples (not `rust-toolchain.toml`).
- Release workflow on `windows-v*` tags; installers go to GitHub Releases, not
  the repo.
- Eventually, not v1: installer/uninstaller UX, settings UI and hotkey
  rebinding, localisation, high-contrast and dark mode, multi-monitor DPI,
  hotkey-conflict UX, reduced-motion and flash-safety for RSVP at high WPM.

## 7. Security and privacy baseline for Windows

**Nothing here is implemented yet.** The column is the *target*; the spike
already violates several rows and must not be reused as production code
(`REVIEW_2026-10-21.md`: S-02, S-03, S-14).

| Baseline item | Windows target (implementation pending) |
|---------------|-----------------------------------------|
| Sandboxed | **Cannot be met** (full-trust, W6). Disclose. Mitigate: no network capability, minimal Win32 surface, `/GUARD:CF`, `SetDefaultDllDirectories` |
| No network | No networking crates (`deny.toml` ban) **and** no networking Win32 features in the `windows` crate feature list (CI check). Not OS-enforced, because there is no sandbox |
| No telemetry / no text logging | By design; test the silent panic hook; review for `println!`/`dbg!` on text |
| Input-only | UIA `GetSelection` and `EM_GETSEL`/`WM_GETTEXT` are read-only, **but a UIA query switches on accessibility inside Chromium/Electron targets**; disclose that side effect. Not applicable until post-v1 Ctrl+C mode exists |
| Memory-safe core | `#![deny(unsafe_code)]` everywhere except one `win32` module, each block with a `// SAFETY:` comment. The core also depends on unsafe crates (`encoding_rs`, `memchr`, ...) |
| Text discarded on close | Drop-counter test. Weaker under the resident model (section 3) |
| **Hand-off to the reader process** | Anonymous inherited pipe/handle only; **never** argv, env, files, named pipes or the clipboard (command lines are readable by same-user processes and logged by EDR/Event 4688) |
| **Install location / binary replacement** | A per-user install is replaceable by any same-user process. Resolve the reader by absolute path from `GetModuleFileNameW`; prefer an admin-writable location or document the trade-off |
| **Cumulative cap** | 512 KiB UTF-8 across all ranges; `EM_GETSEL` end bounded before allocation; `ES_PASSWORD` re-checked in the fallback |
| **Hotkey** | Avoid AltGr combinations (`Ctrl+Alt+R` is AltGr+R on many European layouts); single-flight capture; report registration failure, never override silently |
| **Popup text visible to other processes** | The popup's UIA tree exposes each word to screen readers and automation clients; screenshots and Windows Recall may capture it. Set `WDA_EXCLUDEFROMCAPTURE`; disclose that it does not stop UIA clients |
| **Crash dumps (WER)** | Cannot be fully disabled per process without machine-wide registry config (admin). Document the residual risk |
| **Pagefile / hibernation** | May hold text. Document; no explicit zeroing (same decision as macOS finding #2) |
| Auto-start persistence | Off by default; a standard malware indicator for EDR |
| Unsigned binary / DLL hijack / updates | Sections 3 and 6 |
| Persistence | None beyond non-text flags (hotkey) in `%LOCALAPPDATA%`; update `PRIVACY.md` |

## 8. Phases and exit criteria

Exit criteria are numeric and name a method; "works in Notepad..." is not a
criterion. The thresholds below are proposals for the owner to confirm.

| Phase | Work | Exit criteria |
|-------|------|---------------|
| W0 | PR #1 `.gitattributes`, PR #3 Windows CI | 15/15 tests on `windows-latest` and a fresh clone |
| **W0.5** | **Capture spike**: console prober (hotkey, focused element, `GetSelection`, `GetText(cap+1)`) | Matrix of ~15 apps (Notepad classic and Win11, Edge, Chrome, Firefox, Word, Edge PDF, Acrobat, Windows Terminal, conhost, VS Code, Slack/Teams, one elevated app). Record hit, miss, latency and hang per app. **Go** only if the core set (suggest classic and new Notepad, Edge, Chrome, Word, VS Code) has a **Wilson 95 % lower bound of at least 90 %** over **at least 60 trials each** (warm and cold), reports p50/p95/max with *n* (first-attempt latency separate from any retry sleep), and shows zero unrecoverable hangs; otherwise reposition the product around paste/Share |
| W1 | Shell spike (section 2), process-model decision (section 3), Windows section of `PRIVACY.md` | Written decision in `ARCHITECTURE.md`; p99 frame-to-frame delta of at most 2 ms over a 10-minute 1000 WPM soak logged **without text**; Narrator, no-activate and `WDA_EXCLUDEFROMCAPTURE` checks pass |
| W2 | `contextgist-core` extraction, `skip_words`, oversized-token golden cases | macOS CI green; Swift tests read the golden file and cover forward skip and clamps |
| W3 | Popup, hotkey, UIA capture, manual paste (x64) | W0.5 matrix reproduced in the app; password fields refused; a message per failure class; selections over 512 KiB refused |
| W4 | Packaging, `INSTALL.txt`, `WINDOWS_GUIDE.md`, `PRIVACY.md`/`THIRD-PARTY.md`, Windows security pass, update path | Clean install, use and uninstall on a fresh Windows 11 VM; `cargo deny` clean with Windows triples |
| W5 | First public release `windows-vX.Y.Z` (direct download) | Signed if eligible; privacy docs match behaviour |
| Post-v1 | Share Target, opt-in Ctrl+C, ARM64, MSIX/Store, start-at-login, hotkey rebinding UI | Each its own release with its own disclosure |

**Smallest v1:** `RegisterHotKey`, UIA capture with password refusal and cap,
manual paste, popup with play/pause/rewind/forward/speed, x64, direct
download, no settings file beyond the hotkey.

**W0.5 interim result (2026-10-21, not yet a go/no-go):** a prober at
`apps/windows/spikes/capture-prober/` found, with one trial per app: UIA works
for Edge, Chrome (after the retry), Word, Windows Terminal and WinForms
RichEdit; classic Notepad needs the Win32 `Edit` fallback; the password-field
refusal works; VS Code returned an empty range for select-all and needs
manual confirmation. The 20-trial thresholds above have not been run. Details
and the table are in the prober's README.

**Review follow-ups before more spike data is collected:** fix the spike per
`REVIEW_2026-10-21.md` (S-02, S-03, S-13, S-14, Q-05 to Q-12), commit raw
metadata CSVs with app label, trial id, timestamp, OS build and app version,
and add multi-line CRLF, CJK, RTL, emoji, over-cap and elevated samples.
Core work to land first: durations must use `f32` arithmetic in Swift (Q-01),
the 256-byte token split must be applied in the core (Q-02), and the core must
enforce the 512 KiB cap and parse as UTF-8 (S-04, S-12).

## 9. Testing notes (per `CLAUDE.md` section 9)

Cannot be completed on this x64 dev machine: ARM64 runtime (post-v1), a clean-VM
install/uninstall, Narrator on other languages, high-DPI/multi-monitor mixes.
Mark with `// TODO(test): verify on [PLATFORM: Windows/ARM64]` and add to the
release checklist. The app is compiled for Windows only; any shared code that
gains OS-specific branches needs `[PLATFORM: Windows]` comment guards.

## 10. Open decisions for the owner

1. Build on GIST's WinUI 3 + uniffi-cs stack, or native Rust (the spike decides).
2. Process model: launcher-per-invocation or single resident process.
3. Capture go/no-go thresholds for W0.5 (suggested numbers above).
4. Signing route; depends on the owner's country and entity type.
5. Distribution after v1: Store, winget, or direct only.
6. Who owns `UPSTREAM_BASELINE` moves until `upstream-review.sh` is portable.
7. Default hotkey.
