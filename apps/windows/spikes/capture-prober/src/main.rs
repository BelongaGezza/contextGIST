//! Capture prober: a console tool for the W0.5 capture spike.
//!
//! Select text in any app, press Ctrl+Alt+R. The prober asks UI Automation for
//! the focused element's TextPattern selection (same steps as the planned v1
//! capture path) and prints/logs ONE LINE of metadata: process, control type,
//! outcome class, size, latency. It NEVER prints or stores the selected text.
//!
//! Usage:
//!   capture-prober [--csv results.csv]        wait for Ctrl+Alt+R (Ctrl+C quits)
//!   capture-prober --after SECS [--csv ...]   capture once after SECS, then exit
//!
//! Outcome classes: ok, empty, no_text_pattern, null_selection, password,
//! too_large, timeout, error:<hr>. See docs/WINDOWS_PLAN.md section 4.

use std::io::Write;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use windows::core::{BSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationTextPattern, UIA_TextPatternId,
    UIA_TextPattern2Id, UIA_ValuePatternId,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    RegisterHotKey, UnregisterHotKey, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClassNameW, GetGUIThreadInfo, GetMessageW, SendMessageTimeoutW, GUITHREADINFO, MSG,
    SMTO_ABORTIFHUNG, SMTO_BLOCK, WM_GETTEXT, WM_HOTKEY,
};
use windows::Win32::Foundation::{LPARAM, WPARAM};

/// Same cap as the macOS app (`maxSelectionBytes`).
const MAX_SELECTION_BYTES: usize = 512 * 1024;
const TIMEOUT: Duration = Duration::from_millis(2000);
const MAX_PARENT_LEVELS: u32 = 3;

#[derive(Debug, Default, Clone)]
struct Probe {
    exe: String,
    class: String,
    control_type: i32,
    level: u32,
    outcome: String,
    chars: usize,
    bytes: usize,
    latency_ms: u128,
    first_attempt: String,
    via: String,
    patterns: String,
}

fn exe_name(pid: u32) -> String {
    unsafe {
        let h: HANDLE = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(h) => h,
            // Access denied here is the typical sign of an elevated target (UIPI).
            Err(e) => return format!("pid{pid}(open_failed:{:#x})", e.code().0),
        };
        let mut buf = [0u16; 520];
        let mut len = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
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

/// One capture attempt, mirroring the planned v1 steps (WINDOWS_PLAN section 4).
fn attempt(uia: &IUIAutomation) -> windows::core::Result<Attempt> {
    unsafe {
        let focused = uia.GetFocusedElement()?;
        let done = |outcome: &str, chars, bytes, level, focused: &IUIAutomationElement| {
            Ok(Attempt { outcome: outcome.into(), chars, bytes, level, focused: focused.clone() })
        };
        if focused.CurrentIsPassword()?.as_bool() {
            return done("password", 0, 0, 0, &focused);
        }
        let walker = uia.ControlViewWalker()?;
        let mut el = focused.clone();
        let mut saw_pattern = false;
        for level in 0..=MAX_PARENT_LEVELS {
            if let Ok(tp) = el.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
                saw_pattern = true;
                if let Ok(ranges) = tp.GetSelection() {
                    let n = ranges.Length()?;
                    if n == 0 {
                        return done("null_selection", 0, 0, level, &focused);
                    }
                    let mut out = String::new();
                    for i in 0..n {
                        let r = ranges.GetElement(i)?;
                        // +1 so "exactly at cap" is distinguishable from "over cap".
                        let t: BSTR = r.GetText((MAX_SELECTION_BYTES + 1) as i32)?;
                        if i > 0 && !out.is_empty() {
                            out.push_str("\n\n");
                        }
                        out.push_str(&t.to_string());
                    }
                    let (chars, bytes) = (out.chars().count(), out.len());
                    let outcome = if bytes == 0 {
                        "empty"
                    } else if bytes > MAX_SELECTION_BYTES {
                        "too_large"
                    } else {
                        "ok"
                    };
                    // `out` (the selection) is dropped here and never printed.
                    return done(outcome, chars, bytes, level, &focused);
                }
            }
            match walker.GetParentElement(&el) {
                Ok(p) => el = p,
                Err(_) => break,
            }
        }
        let outcome = if saw_pattern { "null_selection" } else { "no_text_pattern" };
        done(outcome, 0, 0, 0, &focused)
    }
}

/// Tier 1b: classic Win32 Edit/RichEdit controls (e.g. classic Notepad) often
/// expose no UIA TextPattern. Read the selection with EM_GETSEL + WM_GETTEXT
/// on the focused HWND instead. Length-checked before any text is fetched.
fn win32_edit_fallback() -> Option<(String, usize, usize)> {
    unsafe {
        let mut gti = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        GetGUIThreadInfo(0, &mut gti).ok()?;
        let hwnd = gti.hwndFocus;
        if hwnd.0.is_null() {
            return None;
        }
        let mut cls = [0u16; 128];
        let n = GetClassNameW(hwnd, &mut cls);
        let class = String::from_utf16_lossy(&cls[..n.max(0) as usize]);
        if !(class.starts_with("Edit") || class.starts_with("RichEdit")) {
            return None;
        }
        let (mut start, mut end) = (0u32, 0u32);
        // EM_GETSEL = 0x00B0; wParam/lParam receive start/end pointers.
        let mut res = 0usize;
        let ok = SendMessageTimeoutW(
            hwnd, 0x00B0, WPARAM(&mut start as *mut u32 as usize), LPARAM(&mut end as *mut u32 as isize),
            SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, Some(&mut res),
        );
        if ok.0 == 0 {
            return None;
        }
        if end <= start {
            return Some(("empty".into(), 0, 0));
        }
        let want = (end - start) as usize;
        if want * 2 > MAX_SELECTION_BYTES {
            return Some(("too_large".into(), want, want * 2));
        }
        let mut buf = vec![0u16; end as usize + 1];
        let ok = SendMessageTimeoutW(
            hwnd, WM_GETTEXT, WPARAM(buf.len()), LPARAM(buf.as_mut_ptr() as isize),
            SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, Some(&mut res),
        );
        if ok.0 == 0 {
            return None;
        }
        let sel = String::from_utf16_lossy(&buf[start as usize..(end as usize).min(res)]);
        let (chars, bytes) = (sel.chars().count(), sel.len());
        Some((if bytes > MAX_SELECTION_BYTES { "too_large" } else { "ok" }.into(), chars, bytes))
    }
}

fn pattern_flags(el: &IUIAutomationElement) -> String {
    unsafe {
        let mut f = String::new();
        if el.GetCurrentPattern(UIA_TextPatternId).is_ok() { f.push('T'); }
        if el.GetCurrentPattern(UIA_TextPattern2Id).is_ok() { f.push('2'); }
        if el.GetCurrentPattern(UIA_ValuePatternId).is_ok() { f.push('V'); }
        f
    }
}

fn capture() -> Probe {
    let mut p = Probe::default();
    let t0 = Instant::now();
    unsafe {
        if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
            p.outcome = "error:coinit".into();
            return p;
        }
        let uia: IUIAutomation = match CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) {
            Ok(u) => u,
            Err(e) => {
                p.outcome = format!("error:{:#x}", e.code().0);
                CoUninitialize();
                return p;
            }
        };
        for n in 0..2 {
            match attempt(&uia) {
                Ok(a) => {
                    if n == 0 {
                        p.first_attempt = a.outcome.clone();
                        p.exe = exe_name(a.focused.CurrentProcessId().unwrap_or(0) as u32);
                        p.class = a.focused.CurrentClassName().map(|b| b.to_string()).unwrap_or_default();
                        p.control_type = a.focused.CurrentControlType().map(|c| c.0).unwrap_or(0);
                        p.patterns = pattern_flags(&a.focused);
                    }
                    p.via = "uia".into();
                    p.outcome = a.outcome;
                    p.chars = a.chars;
                    p.bytes = a.bytes;
                    p.level = a.level;
                    // Retry once only when nothing usable came back (Chromium/Electron
                    // may enable accessibility on the first UIA query).
                    if matches!(p.outcome.as_str(), "ok" | "password" | "too_large") {
                        break;
                    }
                }
                Err(e) => {
                    p.outcome = format!("error:{:#x}", e.code().0);
                    if n == 0 {
                        p.first_attempt = p.outcome.clone();
                    }
                }
            }
            if n == 0 {
                std::thread::sleep(Duration::from_millis(300));
            }
        }
        drop(uia);
        CoUninitialize();
    }
    if matches!(p.outcome.as_str(), "no_text_pattern" | "null_selection" | "empty") {
        if let Some((outcome, chars, bytes)) = win32_edit_fallback() {
            if outcome != "empty" || p.outcome != "empty" {
                p.outcome = outcome;
                p.chars = chars;
                p.bytes = bytes;
                p.via = "win32edit".into();
            }
        }
    }
    p.latency_ms = t0.elapsed().as_millis();
    p
}

/// Runs `capture` on a worker thread so a hung target app cannot hang us.
fn capture_with_timeout() -> Probe {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(capture());
    });
    match rx.recv_timeout(TIMEOUT) {
        Ok(p) => p,
        Err(_) => Probe {
            outcome: "timeout".into(),
            latency_ms: TIMEOUT.as_millis(),
            ..Default::default()
        },
    }
}

fn report(p: &Probe, csv: Option<&str>) {
    println!(
        "{:<18} class={:<24} ctl={:<5} pat={:<3} lvl={} via={:<9} outcome={:<16} chars={:<7} {:>5} ms first={}",
        p.exe, p.class, p.control_type, p.patterns, p.level, p.via, p.outcome, p.chars, p.latency_ms, p.first_attempt
    );
    if let Some(path) = csv {
        let new = !std::path::Path::new(path).exists();
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            if new {
                let _ = writeln!(f, "exe,class,control_type,patterns,level,via,outcome,chars,bytes,latency_ms,first_attempt");
            }
            let _ = writeln!(
                f,
                "{},{},{},{},{},{},{},{},{},{},{}",
                p.exe, p.class, p.control_type, p.patterns, p.level, p.via, p.outcome, p.chars, p.bytes, p.latency_ms, p.first_attempt
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let csv = arg("--csv");

    if let Some(secs) = arg("--after").and_then(|s| s.parse::<u64>().ok()) {
        std::thread::sleep(Duration::from_secs(secs));
        report(&capture_with_timeout(), csv.as_deref());
        return;
    }

    unsafe {
        if RegisterHotKey(None, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'R' as u32).is_err() {
            eprintln!("could not register Ctrl+Alt+R (already in use?)");
            std::process::exit(2);
        }
    }
    println!("capture-prober ready: select text in a target app, press Ctrl+Alt+R. Ctrl+C here to quit.");
    println!("(only metadata is printed/logged; selected text is never stored)");
    let mut msg = MSG::default();
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.message == WM_HOTKEY {
                report(&capture_with_timeout(), csv.as_deref());
            }
        }
        let _ = UnregisterHotKey(None, 1);
    }
}
