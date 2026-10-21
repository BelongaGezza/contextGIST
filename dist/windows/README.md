# dist/windows

Output of the Windows 11 packaging script (`tools/package-windows.ps1`, not
yet written). **Not started** — see the Windows checklist in
[`docs/PLATFORMS.md`](../../docs/PLATFORMS.md) and section 6 of
[`docs/WINDOWS_PLAN.md`](../../docs/WINDOWS_PLAN.md).

Expected contents once built:

| File | What it is |
|------|------------|
| `contextGIST-<version>-x64.zip` (or `.msix`) | v1 is x64 direct download; sign it if the owner is eligible, otherwise document SmartScreen in `INSTALL.txt`. |
| `INSTALL.txt` | Install / use / remove instructions, including any SmartScreen steps for unsigned builds. |

Where the installer lives (committed here vs GitHub Releases, which `docs/WINDOWS_PLAN.md`
section 6 prefers) is an open item in `docs/PLATFORMS.md`. Always commit `INSTALL.txt`;
gitignore unpacked build trees (see `.gitignore`).
