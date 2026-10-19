# dist/windows

Output of the Windows 11 packaging script (`tools/package-windows.ps1`, not
yet written). **Not started** — see the Windows checklist in
[`docs/PLATFORMS.md`](../../docs/PLATFORMS.md) and Phase 4 of
[`docs/DEVELOPMENT_PLAN.md`](../../docs/DEVELOPMENT_PLAN.md).

Expected contents once built:

| File | What it is |
|------|------------|
| `contextGIST-<version>-x64.msix` (or `.msi`) | Installer. Sign it before release. |
| `INSTALL.txt` | Install / use / remove instructions, including any SmartScreen steps for unsigned builds. |

Commit the installer and `INSTALL.txt`; gitignore unpacked build trees (see `.gitignore`).
