# dist

Packaged, installable builds, one folder per platform. Each platform is built
and released independently by its own `tools/package-<platform>` script, so
platform work can proceed in parallel without touching another platform's folder.

| Folder | Status | Produced by | Final artifact (committed) |
|--------|--------|-------------|----------------------------|
| [`macos/`](./macos/README.md) | Unsigned builds only; **do not distribute the committed DMG** (`get-task-allow`, S-01) | `tools/package-macos.sh` | `contextGIST.dmg`, `INSTALL.txt` |
| [`windows/`](./windows/README.md) | Not started | `tools/package-windows.ps1` (to write) | x64 zip or MSIX + `INSTALL.txt` (format per `docs/WINDOWS_PLAN.md` section 6) |
| [`linux/`](./linux/README.md) | Not started | `tools/package-linux.sh` (to write) | Flatpak/AppImage + `INSTALL.txt` |

Rules: only a platform's final installer and its `INSTALL.txt`/`README.md` are
committed; unpacked build trees are gitignored. See
[`docs/PLATFORMS.md`](../docs/PLATFORMS.md) for the multi-platform contract.
