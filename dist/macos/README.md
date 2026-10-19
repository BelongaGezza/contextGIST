# dist/macos

Output of `tools/package-macos.sh` — the compiled macOS build. Everything here
except this file is gitignored.

| File | What it is |
|------|------------|
| `contextGIST.dmg` | Unsigned, universal (arm64 + x86_64) disk image: the app, an `Applications` shortcut, `Install Instructions.txt` and `Third-Party Notices.txt`. |
| `contextGIST.app` | The Release app the DMG was made from (sign this with `tools/release-sign.sh` for a notarized release). |
| `INSTALL.txt` | The same install instructions that are inside the DMG. |

Regenerate with `./tools/package-macos.sh` from the repo root. The DMG is not
notarized, so Gatekeeper blocks it on first launch; the install instructions
explain how to open it. Source of the instructions: `tools/dmg/INSTALL.txt`.
