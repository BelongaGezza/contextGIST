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
  wrapper over it. Tauri (Windows/Linux) depends on it directly.
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

- [ ] Scaffold `apps/windows` (Tauri) depending on `contextgist-core`; popup with
  play/pause/rewind/fast-forward/speed, ORP-centred word, matching macOS behaviour.
- [ ] Entry point: Windows Share Target registration (primary).
- [ ] Entry point fallback: global hotkey sending Ctrl+C. Decide whether to ship;
  if so, restore the prior clipboard and disclose the overwrite in the UI.
- [ ] Reject oversized selections (macOS limit is 512 KiB) and discard text on close.
- [ ] Golden parity tests against `apps/macos/Tests/golden.json`.
- [ ] MSIX packaging with minimal capabilities (no network, no filesystem);
  write `tools/package-windows.ps1` to populate `dist/windows/`.
- [ ] Code-signing certificate; Microsoft Store submission.
- [ ] `dist/windows/INSTALL.txt` (including SmartScreen steps while unsigned).
- [ ] Add Windows to `docs/PRIVACY.md`, `docs/THIRD-PARTY.md` and a security-baseline pass.
- [ ] Windows section in the README and a `docs/WINDOWS_GUIDE.md`.

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
