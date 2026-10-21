# Platforms: parallel development and release

How macOS, Windows 11 and Linux (and later iOS/iPadOS and Chrome) are
developed and released independently. Strategy and ordering rationale live in
[`DEVELOPMENT_PLAN.md`](./DEVELOPMENT_PLAN.md); this doc is the working
contract and the per-platform TODOs.

## Layout

```
crates/                    shared Rust core (one place; never forked per platform)
apps/{macos,windows,linux} one app per platform, each owning its own folder
tools/package-<platform>.* one packaging script per platform
dist/{macos,windows,linux} that platform's final installer + INSTALL.txt
```

## Rules for working in parallel

1. **Stay in your lane.** A platform branch touches its own `apps/<platform>/`,
   `tools/package-<platform>.*`, `dist/<platform>/`, its section in this doc and
   its CI job. Shared files (`crates/`, root `Cargo.toml`, `UPSTREAM_BASELINE`,
   `docs/ARCHITECTURE.md`) change in small separate PRs that every platform
   rebases on.
2. **Pacing and tokenizing live in one place** (Swift pacing math uses `Float`, matching Rust's `f32`). Never hand-port pacing logic
   again (see `DEVELOPMENT_PLAN.md`, "Guiding constraint"). New platforms consume
   the shared core and must pass the golden parity tests.
3. **Branches and releases.** Branch `platform/<name>/<topic>`; merge to `main`
   via PR with that platform's CI job green. Tag releases per platform:
   `macos-vX.Y.Z`, `windows-vX.Y.Z`, `linux-vX.Y.Z`. A release of one platform
   never waits on another.
4. **Upstream review is shared.** Until `tools/upstream-review.sh` is made
   portable (it uses BSD `sed -i ''`), only macOS can run `--record`. `tools/upstream-review.sh --record` moves the
   one GIST pin for every platform; run the other platforms' tests before
   recording it.
5. **Disclosures stay true per platform.** `docs/PRIVACY.md` and
   `docs/THIRD-PARTY.md` must describe each shipped platform; any platform that
   can't match the security baseline (sandboxed, no network, no telemetry, no
   text logging, input-only) discloses the gap.

## Status

| Platform | Code | CI | Package script | Signed release |
|----------|------|----|----------------|----------------|
| macOS | yes | yes | `tools/package-macos.sh` | no (unsigned) |
| Windows 11 | spike only (`apps/windows/spikes/capture-prober`) | yes (`windows.yml`) | no | no |
| Linux | no | no | no | no |

## TODO: shared (unblocks Windows and Linux; do first)

- [ ] Extract `crates/contextgist-core`: plain Rust (no uniffi) exposing
  `tokenize`, `default_config`, `orp_index`; make `contextgist-ffi` a thin uniffi
  wrapper over it. The Windows/Linux Rust shells depend on it directly.
- [ ] Desktop Rust shells (Windows, Linux) drive `gist_rsvp::RsvpSession`
  directly instead of porting `PacingEngine`; golden-test against `golden.json`
  (macOS keeps its Swift engine, guarded by the parity tests).
- [ ] **Parity hardening (from `REVIEW_2026-10-21.md`; Rust side done in PR #6, Swift `Float` + adopting the extended golden pending a macOS session):** Swift durations use
  `Float` like Rust (Q-01); golden covers every integer WPM 100-1000, a
  non-default config, oversized tokens, `skip_words`, `set_wpm` and Unicode
  punctuation (T1-T7); the core applies the 256-byte token split (Q-02),
  enforces the 512 KiB cap (S-04) and parses as UTF-8 (S-12/Q-13).
- [ ] Add a CI matrix (`windows-latest`, `ubuntu-latest`) running
  `cargo test --workspace --locked`, with per-platform jobs path-filtered so one
  platform's changes don't gate the others.
- [ ] Add `.github/CODEOWNERS` mapping each `apps/<platform>/`, `dist/<platform>/`
  and `tools/package-<platform>.*` to its maintainer.
- [ ] Per-platform release workflow triggered by `windows-v*` / `linux-v*` tags
  (mirror what macOS does locally in `tools/release-sign.sh`).
- [ ] Decide DMG/installer storage: committed binaries (current for macOS) vs
  Git LFS vs GitHub Releases, before Windows/Linux installers add more weight.

## TODO: Windows 11

Rationale, phases and numeric exit criteria: [`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md).
v1 = hotkey + UI Automation capture + manual paste, x64, direct download.

- [x] **W0** `.gitattributes` (#1) and `windows-latest` CI (#3) merged 2026-10-21. Still to add: `cargo fmt --check`, spike clippy/build (Q-03).
- [ ] **W0.5** Capture spike: console prober over ~15 apps, numeric go/no-go.
- [ ] **W1** Read GIST's Windows stack (ADR-015/017/018, bindgen security review),
  then a three-way shell spike (native Rust / WinUI 3 + uniffi-cs / minimal Win32).
  Decide the process model (launcher-per-invocation vs resident). Write the
  Windows section of `PRIVACY.md` before coding.
- [ ] **W2** `contextgist-core` extraction with a shared `skip_words` helper and
  oversized-token golden cases; keep Swift/golden paths unchanged until a macOS session.
- [ ] **W3** `apps/windows`: popup, `RegisterHotKey`, UIA capture (password refusal,
  512 KiB cap, worker thread + timeout), manual paste, per-failure messages.
- [ ] **W4** `tools/package-windows.ps1`, `dist/windows/`, `INSTALL.txt`,
  `WINDOWS_GUIDE.md`, `THIRD-PARTY.md`, Windows security pass, update path.
- [ ] **W5** First release `windows-vX.Y.Z` (signing per owner eligibility).
- [ ] Post-v1, separate releases: Share Target, opt-in Ctrl+C, ARM64, MSIX/Store,
  start-at-login, hotkey rebinding UI.
- [ ] `// TODO(test): verify on [PLATFORM: Windows/ARM64]` when ARM64 work starts.

## TODO: Linux

- [ ] Spike first (time-boxed): X11 PRIMARY selection via global shortcut;
  Wayland primary-selection support per compositor; Flatpak portal limits.
  Record findings in `docs/ARCHITECTURE.md` before building.
- [ ] Scaffold `apps/linux`, reusing whichever Rust-side pieces the Windows shell spike keeps.
- [ ] Entry point per spike outcome; document unsupported desktops.
- [ ] Reject oversized selections and discard text on close.
- [ ] Golden parity tests against `apps/macos/Tests/golden.json`.
- [ ] Flatpak packaging (sandboxed, no network); write `tools/package-linux.sh`
  to populate `dist/linux/`; AppImage as an optional second target.
- [ ] `dist/linux/INSTALL.txt` (including how to bind the shortcut).
- [ ] Add Linux to `docs/PRIVACY.md`, `docs/THIRD-PARTY.md` and a security-baseline pass.
- [ ] Linux section in the README and a `docs/LINUX_GUIDE.md`.

## TODO: macOS (remaining)

- [ ] Developer ID signing and notarization via `tools/release-sign.sh`
  (`SECURITY_REVIEW.md` finding #3); then commit the notarized DMG.
- [ ] Tag `macos-vX.Y.Z` releases once the above is done.
