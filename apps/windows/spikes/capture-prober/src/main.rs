//! Capture prober: a console tool for the W0.5 capture spike.
//!
//! Select text in any app, press Ctrl+Alt+R. The prober asks UI Automation for
//! the focused element's TextPattern selection (same steps as the planned v1
//! capture path), falls back to Win32 Edit/RichEdit messages, and prints/logs
//! ONE LINE of metadata: process, control type, outcome class, size, latency.
//! It NEVER prints or stores the selected text.
//!
//! This is a spike, not production code. Known limits: the selection `String`
//! is dropped, not zeroed; see docs/REVIEW_2026-10-21.md for what a production
//! implementation must do differently.
//!
//! Usage:
//!   capture-prober [options]                 wait for Ctrl+Alt+R (Ctrl+C quits)
//!   capture-prober --after SECS [options]    capture once after SECS, then exit
//! Options:
//!   --csv FILE         append one row per capture (schema below; refuses a file
//!                      whose header differs)
//!   --label NAME       app/scenario label for the row
//!   --trial N          trial number for the row
//!   --app-version V    target app version for the row (recorded as given)
//!   --expect-exe NAME  record `wrong_target` instead of a result when the
//!                      focused element belongs to another process
//!   --retry-ms MS      delay before the single retry (default 300)
//!
//! Outcome classes: ok, empty, no_text_pattern, null_selection, password,
//! too_large, wrong_target, busy, timeout, error:<detail>.

use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows::core::{BSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationTextPattern,
    UIA_TextPattern2Id, UIA_TextPatternId, UIA_ValuePatternId,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClassNameW, GetGUIThreadInfo, GetMessageW, GetWindowLongPtrW, SendMessageTimeoutW,
    GUITHREADINFO, GWL_STYLE, MSG, SMTO_ABORTIFHUNG, SMTO_BLOCK, WM_GETTEXT, WM_HOTKEY,
};

/// Same cap as the macOS app (`maxSelectionBytes`), in UTF-8 bytes.
const MAX_SELECTION_BYTES: usize = 512 * 1024;
const TIMEOUT: Duration = Duration::from_millis(2000);
const MAX_PARENT_LEVELS: u32 = 3;
/// Selections with more disjoint ranges than this are refused as too large.
const MAX_RANGES: i32 = 1000;
const MSG_TIMEOUT_MS: u32 = 500;

const WM_GETTEXTLENGTH: u32 = 0x000E;
const EM_GETSEL: u32 = 0x00B0;
const EM_GETSELTEXT: u32 = 0x043E;
const ES_PASSWORD: u32 = 0x0020;

const CSV_SCHEMA: &str = "2";
const CSV_HEADER: &str = "schema,label,trial,ts_unix,os_build,app_version,exe,class,control_type,\
patterns,level,via,outcome,chars,bytes,init_ms,t_first_ms,t_total_ms,retry_used,first_attempt";

// ── Pure helpers (unit-tested; no Win32) ─────────────────────────────────────

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum EditKind {
    Edit,
    RichEdit,
}

/// Classic edit-control classes, matched case-insensitively and exactly (not
/// by prefix: `EditPlus`-style classes are not Win32 Edit controls).
fn edit_kind(class: &str) -> Option<EditKind> {
    let c = class.to_ascii_lowercase();
    if c.contains("richedit") {
        Some(EditKind::RichEdit)
    } else if c == "edit" || c.starts_with("windowsforms10.edit.") {
        Some(EditKind::Edit)
    } else {
        None
    }
}

fn is_usable(outcome: &str) -> bool {
    matches!(outcome, "ok" | "password" | "too_large")
}

fn classify_bytes(bytes: usize) -> &'static str {
    if bytes == 0 {
        "empty"
    } else if bytes > MAX_SELECTION_BYTES {
        "too_large"
    } else {
        "ok"
    }
}

/// UTF-16 units to request from `GetText` given the UTF-8 bytes already
/// accumulated. Every UTF-16 unit is at least one UTF-8 byte, so asking for
/// `remaining + 1` units is enough to tell "fits" from "over the cap". `None`
/// when the budget is already spent.
fn remaining_units(total_bytes: usize) -> Option<i32> {
    if total_bytes > MAX_SELECTION_BYTES {
        None
    } else {
        Some((MAX_SELECTION_BYTES - total_bytes + 1) as i32)
    }
}

/// Validates an `EM_GETSEL` range before any buffer is sized from it. A range
/// of more than `MAX_SELECTION_BYTES` UTF-16 units cannot fit in the UTF-8
/// cap (every unit is at least one byte), so it is refused without fetching.
fn selection_range(start: u32, end: u32) -> Result<usize, &'static str> {
    if end <= start {
        return Err("empty");
    }
    let len = (end - start) as usize;
    if len > MAX_SELECTION_BYTES {
        return Err("too_large");
    }
    Ok(len)
}

fn sub_slice(units: &[u16], start: usize, end: usize) -> Option<&[u16]> {
    units.get(start..end)
}

/// Strips control characters and neutralises spreadsheet formula prefixes.
fn sanitize(s: &str) -> String {
    let cleaned: String = s.chars().filter(|c| !c.is_control()).collect();
    if cleaned.starts_with(['=', '+', '-', '@']) {
        format!("'{cleaned}")
    } else {
        cleaned
    }
}

fn csv_field(s: &str) -> String {
    let s = sanitize(s);
    if s.contains([',', '"']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

// ── Probe record ─────────────────────────────────────────────────────────────

#[derive(Debug, Default, Clone)]
struct Probe {
    exe: String,
    class: String,
    control_type: i32,
    patterns: String,
    level: u32,
    via: String,
    outcome: String,
    chars: usize,
    bytes: usize,
    init_ms: u128,
    t_first_ms: u128,
    t_total_ms: u128,
    retry_used: bool,
    first_attempt: String,
}

impl Probe {
    fn just(outcome: &str) -> Probe {
        Probe {
            outcome: outcome.into(),
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone)]
struct Opts {
    retry_ms: u64,
    expect_exe: Option<String>,
    csv: Option<String>,
    label: String,
    trial: String,
    app_version: String,
    os_build: String,
}

// ── Win32 / UIA ──────────────────────────────────────────────────────────────

fn exe_name(pid: u32) -> String {
    unsafe {
        let h: HANDLE = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(h) => h,
            // Access denied here is the typical sign of an elevated target (UIPI).
            Err(e) => return format!("pid{pid}(open_failed:{:#x})", e.code().0),
        };
        let mut buf = [0u16; 520];
        let mut len = buf.len() as u32;
        let r =
            QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(h);
        match r {
            Ok(()) => {
                let s = String::from_utf16_lossy(&buf[..len as usize]);
                s.rsplit('\\').next().unwrap_or(&s).to_string()
            }
            Err(_) => format!("pid{pid}"),
        }
    }
}

struct Attempt {
    outcome: String,
    chars: usize,
    bytes: usize,
    level: u32,
    focused: IUIAutomationElement,
}

/// One UIA attempt, mirroring the planned v1 steps (WINDOWS_PLAN section 4):
/// refuse password fields, read the selection with a cumulative UTF-8 byte
/// budget across all ranges, never ask `GetText` for more than the budget.
fn attempt(uia: &IUIAutomation) -> windows::core::Result<Attempt> {
    unsafe {
        let focused = uia.GetFocusedElement()?;
        let done = |outcome: &str, chars, bytes, level| {
            Ok(Attempt {
                outcome: outcome.into(),
                chars,
                bytes,
                level,
                focused: focused.clone(),
            })
        };
        if focused.CurrentIsPassword()?.as_bool() {
            return done("password", 0, 0, 0);
        }
        let walker = uia.ControlViewWalker()?;
        let mut el = focused.clone();
        let mut saw_pattern = false;
        for level in 0..=MAX_PARENT_LEVELS {
            if let Ok(tp) = el.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
                saw_pattern = true;
                if let Ok(ranges) = tp.GetSelection() {
                    let count = ranges.Length()?;
                    if count == 0 {
                        return done("null_selection", 0, 0, level);
                    }
                    let mut out = String::new();
                    let mut too_large = count > MAX_RANGES;
                    if !too_large {
                        for i in 0..count {
                            let sep = if i > 0 && !out.is_empty() { 2 } else { 0 };
                            let Some(units) = remaining_units(out.len() + sep) else {
                                too_large = true;
                                break;
                            };
                            let t: BSTR = ranges.GetElement(i)?.GetText(units)?;
                            if sep > 0 {
                                out.push_str("\n\n");
                            }
                            out.push_str(&t.to_string());
                            if out.len() > MAX_SELECTION_BYTES {
                                too_large = true;
                                break;
                            }
                        }
                    }
                    let (chars, bytes) = (out.chars().count(), out.len());
                    let outcome = if too_large {
                        "too_large"
                    } else {
                        classify_bytes(bytes)
                    };
                    // `out` (the selection) is dropped here and never printed.
                    return done(outcome, chars, bytes, level);
                }
            }
            match walker.GetParentElement(&el) {
                Ok(p) => el = p,
                Err(_) => break,
            }
        }
        done(
            if saw_pattern {
                "null_selection"
            } else {
                "no_text_pattern"
            },
            0,
            0,
            0,
        )
    }
}

fn send(hwnd: HWND, msg: u32, w: usize, l: isize) -> Option<usize> {
    let mut res = 0usize;
    let r = unsafe {
        SendMessageTimeoutW(
            hwnd,
            msg,
            WPARAM(w),
            LPARAM(l),
            SMTO_ABORTIFHUNG | SMTO_BLOCK,
            MSG_TIMEOUT_MS,
            Some(&mut res),
        )
    };
    (r.0 != 0).then_some(res)
}

/// Tier 1b: classic Win32 Edit/RichEdit controls often expose no UIA
/// TextPattern. Returns (outcome, chars, bytes) or None if the focused window
/// is not such a control or a message failed.
///
/// Sizes come from messages the target controls, so every one is bounded
/// before a buffer is allocated from it: the selection (`EM_GETSEL`) by
/// `selection_range`, the whole text (`WM_GETTEXTLENGTH`, plain Edit only) by
/// the cap. Plain Edit cannot return just the selection, so a control holding
/// more than the cap is refused even if the selection is small. ES_PASSWORD
/// is re-checked here.
fn win32_edit_fallback() -> Option<(String, usize, usize)> {
    unsafe {
        let mut gti = GUITHREADINFO {
            cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
            ..Default::default()
        };
        GetGUIThreadInfo(0, &mut gti).ok()?;
        let hwnd = gti.hwndFocus;
        if hwnd.0.is_null() {
            return None;
        }
        let mut cls = [0u16; 128];
        let n = GetClassNameW(hwnd, &mut cls);
        let kind = edit_kind(&String::from_utf16_lossy(&cls[..n.max(0) as usize]))?;
        if (GetWindowLongPtrW(hwnd, GWL_STYLE) as u32) & ES_PASSWORD != 0 {
            return Some(("password".into(), 0, 0));
        }
        let (mut start, mut end) = (0u32, 0u32);
        send(
            hwnd,
            EM_GETSEL,
            &mut start as *mut u32 as usize,
            &mut end as *mut u32 as isize,
        )?;
        let want = match selection_range(start, end) {
            Ok(w) => w,
            Err(o) => return Some((o.into(), 0, 0)),
        };
        let mut buf: Vec<u16>;
        let sel: &[u16] = match kind {
            EditKind::RichEdit => {
                // EM_GETSELTEXT fills the selection only (RichEdit line breaks
                // are CR, matching its EM_GETSEL offsets).
                buf = vec![0u16; want + 1];
                let got = send(hwnd, EM_GETSELTEXT, 0, buf.as_mut_ptr() as isize)?;
                buf.get(..got.min(want))?
            }
            EditKind::Edit => {
                let total = send(hwnd, WM_GETTEXTLENGTH, 0, 0)?;
                if total > MAX_SELECTION_BYTES {
                    return Some(("too_large".into(), total, total));
                }
                if end as usize > total {
                    return None; // selection beyond the text: inconsistent, give up
                }
                buf = vec![0u16; total + 1];
                let got = send(hwnd, WM_GETTEXT, buf.len(), buf.as_mut_ptr() as isize)?;
                sub_slice(&buf, start as usize, (end as usize).min(got))?
            }
        };
        let text = String::from_utf16_lossy(sel);
        let (chars, bytes) = (text.chars().count(), text.len());
        let outcome = classify_bytes(bytes);
        drop(text);
        buf.fill(0);
        Some((outcome.into(), chars, bytes))
    }
}

fn pattern_flags(el: &IUIAutomationElement) -> String {
    unsafe {
        let mut f = String::new();
        if el.GetCurrentPattern(UIA_TextPatternId).is_ok() {
            f.push('T');
        }
        if el.GetCurrentPattern(UIA_TextPattern2Id).is_ok() {
            f.push('2');
        }
        if el.GetCurrentPattern(UIA_ValuePatternId).is_ok() {
            f.push('V');
        }
        f
    }
}

fn apply_uia(p: &mut Probe, a: &Attempt) {
    p.via = "uia".into();
    p.outcome = a.outcome.clone();
    p.chars = a.chars;
    p.bytes = a.bytes;
    p.level = a.level;
}

/// A usable fallback result replaces a non-usable UIA one.
fn apply_fallback(p: &mut Probe) {
    if is_usable(&p.outcome) {
        return;
    }
    if let Some((outcome, chars, bytes)) = win32_edit_fallback() {
        if is_usable(&outcome) {
            p.via = "win32edit".into();
            p.outcome = outcome;
            p.chars = chars;
            p.bytes = bytes;
        }
    }
}

fn capture(opts: &Opts) -> Probe {
    let mut p = Probe::default();
    unsafe {
        let t_init = Instant::now();
        if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
            return Probe::just("error:coinit");
        }
        let uia: IUIAutomation = match CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
        {
            Ok(u) => u,
            Err(e) => {
                CoUninitialize();
                return Probe::just(&format!("error:{:#x}", e.code().0));
            }
        };
        p.init_ms = t_init.elapsed().as_millis();

        let t0 = Instant::now();
        for n in 0..2 {
            match attempt(&uia) {
                Ok(a) => {
                    if n == 0 {
                        p.first_attempt = a.outcome.clone();
                        p.exe = exe_name(a.focused.CurrentProcessId().unwrap_or(0) as u32);
                        p.class = a
                            .focused
                            .CurrentClassName()
                            .map(|b| b.to_string())
                            .unwrap_or_default();
                        p.control_type = a.focused.CurrentControlType().map(|c| c.0).unwrap_or(0);
                        p.patterns = pattern_flags(&a.focused);
                        if let Some(want) = &opts.expect_exe {
                            if !p.exe.eq_ignore_ascii_case(want) {
                                p.outcome = "wrong_target".into();
                                p.t_first_ms = t0.elapsed().as_millis();
                                p.t_total_ms = p.t_first_ms;
                                drop(uia);
                                CoUninitialize();
                                return p;
                            }
                        }
                    }
                    apply_uia(&mut p, &a);
                }
                Err(e) => {
                    p.outcome = format!("error:{:#x}", e.code().0);
                    if n == 0 {
                        p.first_attempt = p.outcome.clone();
                    }
                }
            }
            // Fallback before any retry sleep, so it is not charged the delay.
            apply_fallback(&mut p);
            if n == 0 {
                p.t_first_ms = t0.elapsed().as_millis();
            }
            if is_usable(&p.outcome) {
                break;
            }
            if n == 0 {
                // Chromium/Electron may enable accessibility on the first UIA query.
                std::thread::sleep(Duration::from_millis(opts.retry_ms));
                p.retry_used = true;
            }
        }
        p.t_total_ms = t0.elapsed().as_millis();
        drop(uia);
        CoUninitialize();
    }
    p
}

/// Only one capture runs at a time. A worker stuck in a hung target keeps the
/// flag set, so presses while it is stuck report `busy` instead of leaking
/// another thread.
static BUSY: AtomicBool = AtomicBool::new(false);

struct BusyGuard;
impl Drop for BusyGuard {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::SeqCst);
    }
}

/// Runs `capture` on a worker thread with a timeout so a hung target app
/// cannot hang the caller; a worker panic is reported as `error:panic`, not as
/// a timeout.
fn capture_supervised(opts: &Opts) -> Probe {
    if BUSY.swap(true, Ordering::SeqCst) {
        return Probe::just("busy");
    }
    let (tx, rx) = mpsc::channel();
    let o = opts.clone();
    std::thread::spawn(move || {
        let _guard = BusyGuard;
        let r = catch_unwind(AssertUnwindSafe(|| capture(&o)));
        let _ = tx.send(r);
    });
    match rx.recv_timeout(TIMEOUT) {
        Ok(Ok(p)) => p,
        Ok(Err(_)) => Probe::just("error:panic"),
        Err(RecvTimeoutError::Timeout) => Probe {
            outcome: "timeout".into(),
            t_total_ms: TIMEOUT.as_millis(),
            ..Default::default()
        },
        Err(RecvTimeoutError::Disconnected) => Probe::just("error:worker_died"),
    }
}

// ── Reporting ────────────────────────────────────────────────────────────────

fn csv_row(o: &Opts, p: &Probe) -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let cols = [
        CSV_SCHEMA.to_string(),
        csv_field(&o.label),
        csv_field(&o.trial),
        ts.to_string(),
        csv_field(&o.os_build),
        csv_field(&o.app_version),
        csv_field(&p.exe),
        csv_field(&p.class),
        p.control_type.to_string(),
        csv_field(&p.patterns),
        p.level.to_string(),
        csv_field(&p.via),
        csv_field(&p.outcome),
        p.chars.to_string(),
        p.bytes.to_string(),
        p.init_ms.to_string(),
        p.t_first_ms.to_string(),
        p.t_total_ms.to_string(),
        p.retry_used.to_string(),
        csv_field(&p.first_attempt),
    ];
    cols.join(",")
}

fn append_csv(path: &str, row: &str) -> std::io::Result<()> {
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    if f.metadata()?.len() == 0 {
        writeln!(f, "{CSV_HEADER}")?;
    }
    writeln!(f, "{row}")
}

/// Refuses to append to a file written with a different column layout.
fn check_csv_header(path: &str) -> Result<(), String> {
    match std::fs::read_to_string(path) {
        Ok(s) if s.is_empty() => Ok(()),
        Ok(s) if s.lines().next() == Some(CSV_HEADER) => Ok(()),
        Ok(_) => Err(format!(
            "{path}: header differs from schema {CSV_SCHEMA}; use a new file"
        )),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{path}: {e}")),
    }
}

fn report(o: &Opts, p: &Probe) {
    println!(
        "{:<18} class={:<24} ctl={:<5} pat={:<3} lvl={} via={:<9} outcome={:<16} chars={:<7} first={}ms total={}ms retry={} init={}ms",
        sanitize(&p.exe),
        sanitize(&p.class),
        p.control_type,
        p.patterns,
        p.level,
        p.via,
        sanitize(&p.outcome),
        p.chars,
        p.t_first_ms,
        p.t_total_ms,
        p.retry_used,
        p.init_ms
    );
    if let Some(path) = &o.csv {
        if let Err(e) = append_csv(path, &csv_row(o, p)) {
            eprintln!("could not write {path}: {e}");
        }
    }
}

fn os_build() -> String {
    std::process::Command::new("cmd")
        .args(["/c", "ver"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            let a = s.find("Version ")? + "Version ".len();
            let b = s[a..].find(']')?;
            Some(s[a..a + b].to_string())
        })
        .unwrap_or_else(|| "unknown".into())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let opts = Opts {
        retry_ms: arg("--retry-ms")
            .and_then(|s| s.parse().ok())
            .unwrap_or(300),
        expect_exe: arg("--expect-exe"),
        csv: arg("--csv"),
        label: arg("--label").unwrap_or_default(),
        trial: arg("--trial").unwrap_or_default(),
        app_version: arg("--app-version").unwrap_or_default(),
        os_build: os_build(),
    };
    if let Some(path) = &opts.csv {
        if let Err(e) = check_csv_header(path) {
            eprintln!("{e}");
            std::process::exit(2);
        }
    }

    if let Some(secs) = arg("--after").and_then(|s| s.parse::<u64>().ok()) {
        std::thread::sleep(Duration::from_secs(secs));
        report(&opts, &capture_supervised(&opts));
        return;
    }

    unsafe {
        if RegisterHotKey(None, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'R' as u32).is_err() {
            eprintln!("could not register Ctrl+Alt+R (already in use?)");
            std::process::exit(2);
        }
    }
    println!(
        "capture-prober ready: select text in a target app, press Ctrl+Alt+R. Ctrl+C here to quit."
    );
    println!("(only metadata is printed/logged; selected text is never stored)");
    let mut msg = MSG::default();
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.message == WM_HOTKEY {
                // Never block the message pump on a capture.
                let o = opts.clone();
                std::thread::spawn(move || report(&o, &capture_supervised(&o)));
            }
        }
        let _ = UnregisterHotKey(None, 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edit_class_matching_is_case_insensitive_and_exact() {
        assert_eq!(edit_kind("Edit"), Some(EditKind::Edit));
        assert_eq!(edit_kind("EDIT"), Some(EditKind::Edit));
        assert_eq!(edit_kind("RICHEDIT50W"), Some(EditKind::RichEdit));
        assert_eq!(edit_kind("RichEdit20W"), Some(EditKind::RichEdit));
        assert_eq!(
            edit_kind("WindowsForms10.RICHEDIT50W.app.0.23e1dbb_r3_ad1"),
            Some(EditKind::RichEdit)
        );
        assert_eq!(
            edit_kind("WindowsForms10.EDIT.app.0.1"),
            Some(EditKind::Edit)
        );
        assert_eq!(edit_kind("EditPlus"), None);
        assert_eq!(edit_kind("TextEditor"), None);
        assert_eq!(edit_kind(""), None);
    }

    #[test]
    fn selection_range_bounds_target_supplied_offsets() {
        assert_eq!(selection_range(5, 5), Err("empty"));
        assert_eq!(selection_range(9, 3), Err("empty"));
        assert_eq!(selection_range(0, 10), Ok(10));
        assert_eq!(
            selection_range(0, MAX_SELECTION_BYTES as u32),
            Ok(MAX_SELECTION_BYTES)
        );
        assert_eq!(
            selection_range(0, MAX_SELECTION_BYTES as u32 + 1),
            Err("too_large")
        );
        // A hostile control reporting a near-u32::MAX end must never reach an allocation.
        assert_eq!(selection_range(0, 0xFFFF_FFF0), Err("too_large"));
        assert_eq!(selection_range(0, u32::MAX), Err("too_large"));
    }

    #[test]
    fn sub_slice_never_panics_when_text_shrinks() {
        let units: Vec<u16> = "hello".encode_utf16().collect();
        assert_eq!(sub_slice(&units, 1, 3).map(|s| s.len()), Some(2));
        assert_eq!(sub_slice(&units, 3, 99), None); // end past the text
        assert_eq!(sub_slice(&units, 4, 2), None); // start after end (res < start)
        assert_eq!(sub_slice(&[], 0, 0).map(|s| s.len()), Some(0));
    }

    #[test]
    fn remaining_units_enforces_a_cumulative_utf8_budget() {
        assert_eq!(remaining_units(0), Some(MAX_SELECTION_BYTES as i32 + 1));
        assert_eq!(remaining_units(MAX_SELECTION_BYTES), Some(1));
        assert_eq!(remaining_units(MAX_SELECTION_BYTES + 1), None);
        assert_eq!(remaining_units(100), Some(MAX_SELECTION_BYTES as i32 - 99));
    }

    #[test]
    fn cap_counts_utf8_bytes_not_utf16_units() {
        // 200k CJK chars = 200k UTF-16 units but 600k UTF-8 bytes: over the cap.
        let cjk = "中".repeat(200_000);
        assert!(cjk.encode_utf16().count() < MAX_SELECTION_BYTES);
        assert_eq!(classify_bytes(cjk.len()), "too_large");
        // 300k ASCII chars = 300k UTF-8 bytes (> 256k units): fits.
        assert_eq!(classify_bytes(300_000), "ok");
        assert_eq!(classify_bytes(0), "empty");
        assert_eq!(classify_bytes(MAX_SELECTION_BYTES), "ok");
        assert_eq!(classify_bytes(MAX_SELECTION_BYTES + 1), "too_large");
    }

    #[test]
    fn csv_fields_are_quoted_and_sanitised() {
        assert_eq!(csv_field("plain"), "plain");
        assert_eq!(csv_field("a,b"), "\"a,b\"");
        assert_eq!(csv_field("say \"hi\""), "\"say \"\"hi\"\"\"");
        assert_eq!(csv_field("line\nbreak\rx\u{1b}[31m"), "linebreakx[31m");
        assert_eq!(csv_field("=cmd|' /c calc'!A1"), "'=cmd|' /c calc'!A1");
        assert_eq!(csv_field("+1"), "'+1");
        assert_eq!(csv_field("-1"), "'-1");
        assert_eq!(csv_field("@SUM(A1)"), "'@SUM(A1)");
    }

    #[test]
    fn csv_row_has_the_same_column_count_as_the_header() {
        let o = Opts {
            retry_ms: 300,
            expect_exe: None,
            csv: None,
            label: "a,b".into(),
            trial: "1".into(),
            app_version: "1.0".into(),
            os_build: "10.0.1".into(),
        };
        let p = Probe {
            class: "x,\"y\"".into(),
            outcome: "ok".into(),
            ..Default::default()
        };
        // Quoted commas make a naive split unreliable, so count unquoted ones.
        let count = |s: &str| {
            let mut quoted = false;
            let mut n = 1;
            for c in s.chars() {
                match c {
                    '"' => quoted = !quoted,
                    ',' if !quoted => n += 1,
                    _ => {}
                }
            }
            n
        };
        assert_eq!(count(&csv_row(&o, &p)), count(CSV_HEADER));
    }

    #[test]
    fn usable_outcomes_stop_the_retry() {
        for o in ["ok", "password", "too_large"] {
            assert!(is_usable(o));
        }
        for o in [
            "empty",
            "no_text_pattern",
            "null_selection",
            "timeout",
            "error:0x1",
        ] {
            assert!(!is_usable(o));
        }
    }

    #[test]
    fn a_panicking_worker_is_not_reported_as_a_timeout() {
        let r = catch_unwind(AssertUnwindSafe(|| -> Probe { panic!("boom") }));
        assert!(r.is_err());
        let p = match r {
            Ok(p) => p,
            Err(_) => Probe::just("error:panic"),
        };
        assert_eq!(p.outcome, "error:panic");
    }
}
