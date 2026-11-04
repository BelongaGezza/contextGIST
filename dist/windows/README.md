# dist/windows

Output of the Windows packaging script, `tools/package-windows.ps1`.
**Prototype**: there is no contextGIST Windows app yet, so the script packages
the throwaway capture-prober spike to prove the install and uninstall
mechanics. See [`docs/WINDOWS_PLAN.md`](../../docs/WINDOWS_PLAN.md) section 6
and [`docs/INSTALL_TODO.md`](../../docs/INSTALL_TODO.md).

```powershell
pwsh tools/package-windows.ps1                 # builds the spike, writes the zip
pwsh tools/package-windows.ps1 -PayloadDir <dir> -ExeName contextGIST.exe -Version 0.1.0   # a real build, later
```

| File | What it is |
|------|------------|
| `contextGIST-<version>-x64.zip` | Unsigned x64 package (gitignored; installers go to GitHub Releases). Contains `bin\`, `install.cmd`/`install.ps1`, `uninstall.cmd`/`uninstall.ps1`, `app.json`, `INSTALL.txt`. |
| `SHA256SUMS` | Hash of the zip (gitignored, written by the script). |
| `INSTALL.txt` | Install / use / remove instructions including the SmartScreen steps for unsigned builds (committed). |

The installer is per-user and needs no administrator rights: it copies the app
to `%LOCALAPPDATA%\Programs\contextGIST`, adds a Start menu shortcut and an
Apps & Features entry under `HKCU`, and writes nothing else. Uninstalling
(Settings > Apps, or `uninstall.cmd`) removes exactly those three things.
Authenticode signing is not done yet (certificate route undecided).

Unpacked staging trees are gitignored (see `.gitignore`).
