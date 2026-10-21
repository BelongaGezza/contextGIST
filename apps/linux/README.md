# apps/linux

Linux app. **Not started.** The entry point (X11 PRIMARY selection and a global
shortcut, Wayland support per compositor, Flatpak portal limits) needs a
time-boxed spike first; the shell reuses whichever Rust-side pieces survive the
Windows shell spike. Owns everything Linux-specific; must not edit
`apps/macos/`, `apps/windows/` or the shared core except via the process in
[`docs/PLATFORMS.md`](../../docs/PLATFORMS.md). Checklist: "Linux" there.
