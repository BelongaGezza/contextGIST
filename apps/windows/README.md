# apps/windows

Windows 11 app. **No product code yet**: only the W0.5 capture spike at
[`spikes/capture-prober/`](./spikes/capture-prober/README.md), a throwaway
console tool that measures how reliably another app's selection can be read.
Planned: a shell driving `gist_rsvp::RsvpSession`, hotkey-triggered, UI
Automation capture; the shell (native Rust, WinUI 3 or Win32) and process model
are still open decisions. Design, phases and open decisions:
[`docs/WINDOWS_PLAN.md`](../../docs/WINDOWS_PLAN.md).
Owns everything Windows-specific; must not edit `apps/macos/`, `apps/linux/`
or the shared core except via the process in [`docs/PLATFORMS.md`](../../docs/PLATFORMS.md).
