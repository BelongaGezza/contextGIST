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
2. **Pacing and tokenizing live in one place.** Never hand-port pacing logic
   again (see `DEVELOPMENT_PLAN.md`, "Guiding constraint"). New platforms consume
   the shared core and must pass the golden parity tests.
3. **Branches and releases.** Branch `platform/<name>/<topic>`; merge to `main`
   via PR with that platform's CI job green. Tag releases per platform:
   `macos-vX.Y.Z`, `windows-vX.Y.Z`, `linux-vX.Y.Z`. A release of one platform
   never waits on another.
4. **Upstream review is shared.** `tools/upstream-review.sh --record` moves the
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
| Windows 11 | no | no | no | no |
| Linux | no | no | no | no |

## TODO: shared (unblocks Windows and Linux; do first)

- [ ] Extract `crates/contextgist-core`: plain Rust (no uniffi) exposing
  `tokenize`, `default_config`, `orp_index`; make `contextgist-ffi` a thin uniffi
  wrapper over it. The Windows/Linux Rust shells depend on it directly.
- [ ] Port the wall-clock `PacingEngine` to Rust once in the core, tested against
  `apps/macos/Tests/golden.json`, so desktop shells don't each re-port it
  (macOS may keep its Swift engine, guarded by the existing parity tests).
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

Full rationale, phases and exit criteria: [`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md).

- [ ] **W0** `.gitattributes` (LF for `*.json`/`*.sh`) so `golden_file_matches_gist_rsvp`
  passes on Windows checkouts; Windows target handling in `rust-toolchain.toml`.
- [ ] **W0** `windows-latest` CI job (build, tests, clippy, `cargo deny`), path-filtered.
- [ ] **W1** Time-boxed shell spike (native Rust UI vs Tauri): ORP jitter at
  1000 WPM, Narrator, focus behaviour, toolkit licence vs `deny.toml`.
  Record the decision in `ARCHITECTURE.md`.
- [ ] **W2** Drive `gist_rsvp::RsvpSession` directly (no hand-ported engine);
  parity test against `golden.json` plus rewind/fast-forward/speed semantics test.
- [ ] **W3** Scaffold `apps/windows`: tray-resident, single instance,
  `RegisterHotKey`, popup with play/pause/rewind/fast-forward/speed, ORP-centred word.
- [ ] **W3** Capture: UI Automation `TextPattern` first; manual paste floor;
  clear errors for elevated windows (UIPI). Reject selections over 512 KiB; discard text on close.
- [ ] **W4** Opt-in Ctrl+C capture with full-format clipboard restore and
  history/cloud exclusion formats; disclosed in the UI and `PRIVACY.md`.
- [ ] **W4** Share Target (`Text` only) via MSIX; start-at-login as opt-in.
- [ ] **W5** `tools/package-windows.ps1`: full-trust MSIX, x64 + ARM64, minimal
  capabilities; populate `dist/windows/`; `INSTALL.txt` (SmartScreen steps while unsigned).
- [ ] **W5** Add Windows to `docs/PRIVACY.md` (resident process, not sandboxed,
  clipboard behaviour, WER dumps), `docs/THIRD-PARTY.md`, refresh `SECURITY_REVIEW.md`;
  README section and `docs/WINDOWS_GUIDE.md`.
- [ ] **W6** Code signing route decided; Microsoft Store submission; tag `windows-vX.Y.Z`.
- [ ] `// TODO(test): verify on [PLATFORM: Windows/ARM64]` for ARM64 and clean-VM install runs.

## TODO: Linux

- [ ] Spike first (time-boxed): X11 PRIMARY selection via global shortcut;
  Wayland primary-selection support per compositor; Flatpak portal limits.
  Record findings in `docs/ARCHITECTURE.md` before building.
- [ ] Scaffold `apps/linux`, reusing the Windows Tauri shell where possible.
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
