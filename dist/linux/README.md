# dist/linux

Output of the Linux packaging script (`tools/package-linux.sh`, not yet
written). **Not started** — see the Linux checklist in
[`docs/PLATFORMS.md`](../../docs/PLATFORMS.md) and Phase 5 of
[`docs/DEVELOPMENT_PLAN.md`](../../docs/DEVELOPMENT_PLAN.md). The text-selection
entry point needs a spike before packaging is worth doing.

Expected contents once built:

| File | What it is |
|------|------------|
| `contextGIST-<version>.flatpak` / `.AppImage` | Installable package. |
| `INSTALL.txt` | Install / use / remove instructions, including how to bind the global shortcut. |

Commit the package and `INSTALL.txt`; gitignore unpacked build trees (see `.gitignore`).
