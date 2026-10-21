# apps/windows

Windows 11 app. **Not started.** Planned: native Rust shell driving
`gist_rsvp::RsvpSession`, tray-resident with a global hotkey, UI Automation
capture. Design, phases and open decisions: [`docs/WINDOWS_PLAN.md`](../../docs/WINDOWS_PLAN.md).
Owns everything Windows-specific; must not edit `apps/macos/`, `apps/linux/`
or the shared core except via the process in [`docs/PLATFORMS.md`](../../docs/PLATFORMS.md).
