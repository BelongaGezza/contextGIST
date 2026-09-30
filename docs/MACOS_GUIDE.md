# macOS: install, use, remove

There's no signed release yet (see `docs/SECURITY_REVIEW.md` finding #3),
so today the only way to run contextGIST is building it from source. This
doc covers that, day-to-day use once it's installed, and a clean removal.

## Requirements

- Xcode (for `xcodebuild`) and `xcodegen` — `brew install xcodegen` if you
  don't have it.
- A Rust toolchain matching `rust-toolchain.toml` (`rustup` will install it
  automatically on first build).
- **`~/develop/reader` must exist on disk** — contextGIST builds against it
  via relative path dependencies (see `CLAUDE.md`'s "Relationship to GIST").
  It doesn't need to be built itself, just present.

## Install

Run from the repo root (`~/develop/contextGIST`) unless noted otherwise.

1. **Install `uniffi-bindgen` once** (uniffi 0.28+ stopped shipping a
   prebuilt binary on crates.io, so `tools/gen-bindings.sh` needs one built
   locally):
   ```bash
   cargo install --path crates/contextgist-ffi --bin uniffi-bindgen \
       --features uniffi-bindgen-bin --root ~/.cargo-uniffi-bindgen
   ```
   Add `~/.cargo-uniffi-bindgen/bin` to your `PATH` (in `.zshrc`/`.bashrc`),
   or prefix the commands below with it for a one-off shell.

2. **Build the Rust core and generate Swift bindings:**
   ```bash
   ./tools/gen-bindings.sh
   ```

3. **Generate the Xcode project** (gitignored, regenerate any time
   `project.yml` changes or a source file is added):
   ```bash
   cd apps/macos && xcodegen generate
   ```

4. **Build a Release binary** (not Debug — Debug builds are ad-hoc signed
   with Hardened Runtime effectively disabled, fine for development but not
   for the copy you'll actually use day to day):
   ```bash
   xcodebuild -scheme contextGIST -configuration Release build
   ```

5. **Move the built app somewhere stable.** Xcode builds into
   `~/Library/Developer/Xcode/DerivedData/...`, which gets cleaned/rebuilt
   over time — copy it into `/Applications` so it has a permanent home:
   ```bash
   APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 \
       -name "contextGIST.app" -path "*/Release/*" | head -1)
   rm -rf /Applications/contextGIST.app
   cp -R "$APP_PATH" /Applications/
   ```

6. **Register it with Launch Services** so the Services menu picks it up.
   This is two systems, not one: Launch Services needs to know the app
   bundle exists and read its declared `NSServices` entry, and the
   pasteboard-services daemon (`pbs`) that actually drives the Services
   menu needs to pick that registration up. Do it in order:

   **a. Register the app bundle with Launch Services:**
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/contextGIST.app
   ```
   `-f` forces re-registration even if Launch Services already has a
   record for this bundle identifier (`com.contextgist.macos`) — you'll
   need this same command again any time you rebuild and replace the app
   in `/Applications`, not just on first install.

   **b. Launch it once**, so `AppDelegate.applicationDidFinishLaunching`
   actually runs (`NSApp.servicesProvider = ...` + `NSUpdateDynamicServices()`)
   — the plist declaration alone isn't enough to populate a *live* Services
   menu; the app needs to run at least once after being registered:
   ```bash
   open /Applications/contextGIST.app
   ```
   Nothing visible happens — the app is `LSUIElement` (no Dock icon, no
   window) and quits itself a moment later since it has no open window.
   That's expected.

   **c. Verify the registration took**, rather than guessing from the menu:
   ```bash
   /System/Library/CoreServices/pbs -dump_pboard | grep -A6 "Speed Read with contextGIST"
   ```
   You should see an entry with `NSMessage = readSelection;` and your app's
   bundle path. If this prints nothing, continue to (d).

   **d. If (c) came up empty, flush the Services cache and recheck** — it
   can lag behind a fresh registration:
   ```bash
   /System/Library/CoreServices/pbs -flush
   ```
   Re-run the `pbs -dump_pboard` check from (c). If it's *still* missing,
   log out and back in — the Services menu is rebuilt at login, which
   reliably picks up registrations that `pbs -flush` alone sometimes
   doesn't.

7. **Confirm it's there:** System Settings → Keyboard → Keyboard
   Shortcuts… → Services → Text — you should see "Speed Read with
   contextGIST" listed (and can assign it a keyboard shortcut here if you
   want one). If it's missing, see Troubleshooting below.

You don't need to add it to Login Items — macOS launches it on demand
whenever the Services item fires.

### Optional: package a DMG

To hand the build to another Mac you control, package the Release app:
```bash
./tools/build-dmg.sh /Applications/contextGIST.app ~/Desktop/contextGIST.dmg
```
The DMG holds the app, an `Applications` shortcut, and
`Third-Party Notices.txt`. It is **unsigned and host-arch only** (an Apple
silicon build won't run on an Intel Mac). Gatekeeper will block it on
other machines until Developer ID signing and notarization exist
(`docs/SECURITY_REVIEW.md` finding #3).

## Use

1. Select text in any app that supports Services (TextEdit, Safari, Mail,
   Notes, Preview, Pages, most text editors and PDF viewers).
2. Right-click the selection → **Services** → **Speed Read with
   contextGIST** (or use the keyboard shortcut you assigned in step 7
   above, if any). Not every app implements Services for text — if the
   item doesn't show up for a particular app, that app just doesn't
   support it.
3. A small floating popup opens and starts playing the selection
   RSVP-style — one word at a time, centered on its focal letter (shown in
   red).

**Controls:**

| Action | How |
|---|---|
| Play / pause | Space, or the play/pause button |
| Rewind 5 words | Left arrow, or the rewind button |
| Fast-forward 5 words | Right arrow, or the fast-forward button |
| Reading speed | The WPM slider (100–1000) |
| Close | Escape, the window's close button, or ⌘W |

The word count under the display shows progress (words shown / total).
Closing the popup — any way — discards the text immediately. Nothing is
saved: no history, no library, no reading position, no settings.

## Remove

contextGIST never writes preferences, history, or any file of its own (see
`docs/SECURITY_REVIEW.md`), so removing it is close to just deleting the
app:

1. **Quit it if it's running** (normally unnecessary — it terminates
   itself once its popup closes):
   ```bash
   pkill -f "contextGIST.app/Contents/MacOS/contextGIST"
   ```

2. **Unregister it from Launch Services** — do this *before* deleting the
   app in step 3, while `lsregister` still has a bundle on disk to look
   up:

   **a. Unregister the bundle:**
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/contextGIST.app
   ```
   `-u` tells `lsregister` to remove this bundle's record instead of
   adding one (the opposite of the `-f` used during install).

   **b. Flush the Services cache**, so the menu item disappears right away
   instead of waiting for your next login:
   ```bash
   /System/Library/CoreServices/pbs -flush
   ```

   **c. Verify it's gone:**
   ```bash
   /System/Library/CoreServices/pbs -dump_pboard | grep -A6 "Speed Read with contextGIST"
   ```
   This should now print nothing.

   **If you already deleted the app before running (a)**: `lsregister -u`
   has nothing left at that path to unregister. Rebuild Launch Services'
   entire database instead — heavier, but guaranteed to drop every
   reference to a bundle ID that no longer exists on disk:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
   ```
   This rescans every installed app and can take a few seconds, briefly
   making Spotlight/Open-With menus unresponsive — it doesn't touch any
   app's data, just Launch Services' own database.

3. **Delete the app:**
   ```bash
   rm -rf /Applications/contextGIST.app
   ```

4. **Optional, for a fully clean removal:** macOS creates a sandbox
   container for every sandboxed app it launches, whether or not the app
   itself writes anything there — contextGIST's is empty scaffolding, but
   remove it if you want zero trace:
   ```bash
   rm -rf ~/Library/Containers/com.contextgist.macos
   rm -rf "~/Library/Saved Application State/com.contextgist.macos.savedState"
   ```

That's everything — there's no login item, launch agent, preferences
file, or cache beyond the sandbox container above.

## Troubleshooting

- **Menu item doesn't appear:** confirm you built a Release binary and
  copied it to `/Applications` (not left it in DerivedData), and that
  `lsregister -f` ran against that exact path. The Services menu cache can
  be sticky — logging out and back in forces a refresh if the item still
  doesn't show. You can also check the live registry directly:
  ```bash
  /System/Library/CoreServices/pbs -dump_pboard | grep -A5 contextGIST
  ```
- **Build fails with "tools/gen-bindings.sh failed … refusing to link":**
  the Rust build failed, and Xcode now stops rather than linking a stale
  `libcontextgist_ffi.a`. Before 2026-09-30 it silently fell back to the
  old library and still reported success. The cargo error is just above
  that line in the build log. If it's `mis-aligned LINKEDIT string pool` on
  a proc-macro `.dylib`, the build cache is corrupted: run `cargo clean
  --release` (or `cargo clean` for Debug) and rebuild.
- **"contextGIST: no text was selected"**: the source app didn't actually
  have a text selection, or doesn't implement the Services text-sending
  side of the protocol.
- **Popup doesn't open / app crashes:** check Console.app or
  `~/Library/Logs/DiagnosticReports` for a contextGIST crash report. Be
  aware (per `docs/SECURITY_REVIEW.md` finding #1) that a crash report can
  contain the text you had selected at the time — keep that in mind before
  sharing one.
