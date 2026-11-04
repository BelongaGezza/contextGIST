# Install / uninstall TODO

Source: install/uninstall feasibility review, 2026-11-04. Goal: a one-click
install and a trivial uninstall on every platform. Related plans:
[`WINDOWS_PLAN.md`](./WINDOWS_PLAN.md) section 6,
[`PLATFORMS.md`](./PLATFORMS.md), [`DEVELOPMENT_PLAN.md`](./DEVELOPMENT_PLAN.md).

Legend: **[Win]** doable on the Windows dev machine, **[Mac]** needs the
MacBook (CLAUDE.md section 7), **[Acct]** blocked on a purchase or decision.

## Windows (this machine) — explore the install method

Nothing here depends on the app being finished; the packaging pipeline can be
proven with the capture-prober spike as a stand-in payload.

- [ ] **[Win]** Decide the process model (launcher-per-invocation vs resident
      tray + hotkey; WINDOWS_PLAN section 3). It drives uninstall: a resident app
      needs start-at-login cleanup, a launcher does not.
- [ ] **[Win]** Check signing eligibility (country / entity type) for Azure
      Artifact Signing vs OV certificate vs unsigned (WINDOWS_PLAN section 6).
      Re-check prices before buying.
- [x] **[Win]** (done: PR for windows/packaging-prototype) Prototype `tools/package-windows.ps1` using the
      `apps/windows/spikes/capture-prober` binary as the payload: `cargo build
      --release` for x64, stage files, produce `dist/windows/*.zip`, write
      `SHA256SUMS`. No absolute paths; `rustup target add` inside the script, not
      in `rust-toolchain.toml`.
- [x] **[Win]** (compared in `docs/WINDOWS_INSTALL_OPTIONS.md`; MSIX and winget installs still unverified, need admin; Inno Setup/WiX not built) Compare install formats with the prototype and record the
      trade-offs: (a) zip + `INSTALL.txt`, (b) per-user MSIX, (c) winget manifest
      pointing at a GitHub Release, (d) Inno Setup / WiX per-user installer.
      Criteria: one-click, SmartScreen behaviour when unsigned, clean uninstall,
      update path, binary-replacement risk of a per-user install location
      (WINDOWS_PLAN section 7).
- [ ] **[Win]** Test the unsigned SmartScreen experience on this machine
      (download a zip/MSIX from a GitHub Release, note the exact prompts) and
      document the steps in `dist/windows/INSTALL.txt`.
- [ ] **[Win]** Test install and uninstall on a clean Windows 11 VM or Windows
      Sandbox: confirm no residue (files, registry keys, Start menu, startup
      entries) after removal.
- [ ] **[Win]** Decide the update path before v1 is public (Store, winget, or
      a manual new-version notice).
- [ ] **[Win]** Add `windows-v*` tag release workflow (`windows-latest`) that
      runs the packaging script, signs with secrets if available, and publishes
      to GitHub Releases with the hash. Installers do not go in the repo.
- [x] **[Win]** Write the Windows section of `docs/PRIVACY.md` (not sandboxed
      unless MSIX; what is and isn't persisted) and an `INSTALL.txt` including a
      "Remove" section. Update `dist/windows/README.md`.
- [ ] **[Win]** Pre-submission check for Store / Defender acceptance of a
      hotkey + cross-process UIA app if MSIX is chosen (marked unverified in
      WINDOWS_PLAN).

## macOS

Quick wins (no Apple account needed):

- [x] **[Win]** Fix `docs/MACOS_GUIDE.md` "Remove" step 4: `rm -rf "~/Library/..."`
      does not expand the quoted `~`, so it silently does nothing. Fold the
      container and saved-state cleanup into one correct line.
- [x] **[Win]** Rewrite `docs/MACOS_GUIDE.md` to lead with the DMG install and
      move the source build to an appendix. Rewrite `tools/dmg/INSTALL.txt` so
      "Open Anyway" comes before `xattr -dr com.apple.quarantine` (S-09), and
      mark `lsregister` / `pbs -flush` as optional troubleshooting.
- [ ] **[Win]** (`build-dmg.sh` already refuses a `get-task-allow` build; this adds it to CI, which needs an ad-hoc-signed Release build there) CI step that fails if `get-task-allow` is present in the
      built app's entitlements (`codesign -d --entitlements`), on the `macos` job.
- [x] **[Win]** Add a `SHA256SUMS` step to `tools/package-macos.sh` /
      `build-dmg.sh` (`.sh` edit only; no Apple project files).
- [x] **[Win]** Uninstall text in `INSTALL.txt`.

Needs the Mac:

- [ ] **[Mac]** Rebuild the DMG without `get-task-allow`, publish it via GitHub
      Releases with a hash, and remove the committed `dist/macos/contextGIST.dmg`
      from git (S-01, S-09, Q-25). The current committed DMG must not be
      distributed.
- [ ] **[Mac]** Verify on a fresh Mac whether a plain drag-install makes the
      Services item appear without `lsregister -f` or `pbs -flush`. If a first
      launch is enough, drop the manual steps and get a 2-step install.

Blocked on an Apple Developer account:

- [ ] **[Acct]** Decide whether to buy an Apple Developer ID. If not, "Open
      Anyway" is the ceiling for macOS.
- [ ] **[Acct]** Run `tools/release-sign.sh` for real (sign, notarize, staple).
- [ ] **[Acct]** `macos-v*` tag release workflow on `macos-latest`
      (package, sign, publish, hash).
- [ ] **[Acct]** Homebrew cask in a tap, with `zap` for
      `~/Library/Containers/com.contextgist.macos`. Needs the notarized URL.

## Linux, iOS/iPadOS, Chrome

- [ ] **[Win]** Linux: do the Wayland/X11 selection-capture spike first
      (PLATFORMS.md). Then Flatpak (first) or AppImage. Confirm Flatpak-only is
      acceptable given portal limits.
- [ ] iOS/iPadOS and Chrome: stores provide install and uninstall; nothing to
      do until Phases 1 and 3.

## Open questions for the owner

1. Buy an Apple Developer account, or accept "Open Anyway" on macOS?
2. Windows signing route and distribution: Azure Artifact Signing, OV cert,
   Store, winget, or direct download?
3. Windows process model: resident tray + hotkey, or launch per invocation?
4. Is GitHub Releases the agreed home for binaries? Homebrew tap wanted?
5. Linux: is Flatpak-only acceptable?
