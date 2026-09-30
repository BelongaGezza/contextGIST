#!/usr/bin/env bash
# Upstream review: what has changed in GIST (~/develop/reader) since the
# commit contextGIST was last reviewed against (UPSTREAM_BASELINE), and
# which of it can reach this app. See docs/ARCHITECTURE.md "Upstream
# baseline" for the procedure this supports.
#
# Usage:
#   tools/upstream-review.sh              full report (for a human or Claude)
#   tools/upstream-review.sh --fetch      same, after `git fetch` in GIST
#   tools/upstream-review.sh --check      one-line build warning if watched
#                                         paths changed; always exits 0
#                                         (run by gen-bindings.sh, i.e. on
#                                         every Xcode build)
#   tools/upstream-review.sh --check --strict
#                                         same, but exits 1 if unreviewed
#                                         (run by release-sign.sh)
#   tools/upstream-review.sh --record "<note>"
#                                         after reviewing: run the Rust tests
#                                         against the current GIST checkout
#                                         and, if they pass, make it the new
#                                         baseline and add a row to the
#                                         ARCHITECTURE.md table
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPSTREAM="$(cd "$REPO_ROOT/.." && pwd)/reader"
BASELINE_FILE="$REPO_ROOT/UPSTREAM_BASELINE"

# What of GIST can reach contextGIST, grouped by how it arrives.
# Shared crates: compiled in via path dependency, so changes arrive on the
# next build with no action here. Everything else needs a deliberate port.
SHARED_CRATES="crates/gist-model crates/gist-parse-txt crates/gist-rsvp"
# GIST's Swift pacing/ORP code, which PacingEngine in
# apps/macos/Sources/RsvpView.swift is a hand port of.
SWIFT_PORT="apps/apple/macOS/RsvpView.swift"
# Icon artwork tools/gen-app-icon.sh is built from.
ICON_ART="assets"
# Policy/tooling contextGIST mirrors (deny.toml, security reviews).
POLICY="deny.toml docs/security-review-v2.md docs/security-quality-review-2026-09-29.md SECURITY.md"
WATCHED="$SHARED_CRATES $SWIFT_PORT $ICON_ART"

MODE=report STRICT=0 FETCH=0 NOTE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --strict) STRICT=1 ;;
        --fetch) FETCH=1 ;;
        --record) MODE=record; NOTE="${2:?--record needs a note describing the review}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$BASELINE_FILE" ] || { echo "error: $BASELINE_FILE missing" >&2; exit 1; }
BASE="$(sed -n 's/^commit=//p' "$BASELINE_FILE")"
BASE_DATE="$(sed -n 's/^reviewed=//p' "$BASELINE_FILE")"

if [ ! -d "$UPSTREAM/.git" ]; then
    # Without GIST on disk the build fails anyway (path dependencies).
    echo "warning: upstream-review: $UPSTREAM not found" >&2
    [ "$MODE" = check ] && [ "$STRICT" = 0 ] && exit 0
    exit 1
fi

g() { git -C "$UPSTREAM" "$@"; }
HEAD_SHA="$(g rev-parse HEAD)"
BRANCH="$(g branch --show-current 2>/dev/null || true)"
BRANCH="${BRANCH:-(detached)}"

# Watched-path differences between the baseline and the GIST *working
# tree* (so uncommitted upstream edits count too; they're compiled in).
# shellcheck disable=SC2086
changed_paths() { g diff --name-only "$BASE" -- $WATCHED 2>/dev/null; }

# ── --check: build-time nudge ───────────────────────────────────────────────
if [ "$MODE" = check ]; then
    CHANGED="$(changed_paths | wc -l | tr -d ' ')"
    if [ "$CHANGED" != 0 ]; then
        MSG="GIST (~/develop/reader @ ${HEAD_SHA:0:7}, $BRANCH) has $CHANGED changed file(s) in code contextGIST uses since the last upstream review (${BASE:0:7}, $BASE_DATE). Run tools/upstream-review.sh."
        if [ "$STRICT" = 1 ]; then
            echo "error: $MSG" >&2
            exit 1
        fi
        echo "warning: $MSG"
    fi
    exit 0
fi

# ── --record: accept the current checkout as the new baseline ───────────────
if [ "$MODE" = record ]; then
    # shellcheck disable=SC2086
    if [ -n "$(g status --porcelain -- $WATCHED)" ]; then
        echo "error: GIST has uncommitted changes in watched paths; a baseline must be a commit:" >&2
        # shellcheck disable=SC2086
        g status --short -- $WATCHED >&2
        exit 1
    fi
    echo "→ Running contextGIST's tests against GIST ${HEAD_SHA:0:7} ($BRANCH)..."
    (cd "$REPO_ROOT" && cargo test --workspace)
    TODAY="$(date +%Y-%m-%d)"
    cat > "$BASELINE_FILE" <<EOF
# The last ~/develop/reader (GIST) commit contextGIST was reviewed and
# tested against. Written by \`tools/upstream-review.sh --record\`; don't edit
# by hand. History and notes: docs/ARCHITECTURE.md "Upstream baseline".
commit=$HEAD_SHA
branch=$BRANCH
reviewed=$TODAY
EOF
    python3 - "$REPO_ROOT/docs/ARCHITECTURE.md" "$TODAY" "${HEAD_SHA:0:7}" "$BRANCH" "$NOTE" <<'PY'
import sys
path, date, sha, branch, note = sys.argv[1:]
lines = open(path).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.startswith("### Upstream baseline"))
rows = [i for i in range(start, len(lines)) if lines[i].startswith("| 20")]
if not rows:
    sys.exit("error: no baseline table rows found under '### Upstream baseline'")
lines.insert(rows[-1] + 1, f"| {date} | `{sha}` | `{branch}` | {note} |")
open(path, "w").write("\n".join(lines))
PY
    echo "✓ Baseline is now ${HEAD_SHA:0:7} ($BRANCH); row added to docs/ARCHITECTURE.md. Commit both."
    exit 0
fi

# ── Report ──────────────────────────────────────────────────────────────────
if [ "$FETCH" = 1 ]; then
    g fetch --quiet origin || echo "(fetch failed; reporting on local refs)"
fi

echo "Upstream review: GIST (~/develop/reader)"
echo "  baseline : ${BASE:0:7} (reviewed $BASE_DATE)"
echo "  checkout : ${HEAD_SHA:0:7} on $BRANCH"
if g rev-parse -q --verify origin/main >/dev/null; then
    read -r AHEAD BEHIND <<<"$(g rev-list --left-right --count HEAD...origin/main)"
    echo "  vs origin/main: $AHEAD ahead, $BEHIND behind"
fi
MISSING="$(g rev-list --count "HEAD..$BASE" 2>/dev/null || echo "?")"
if [ "$MISSING" != 0 ]; then
    echo "  note: this checkout lacks $MISSING commit(s) of the baseline (older or different branch)."
fi
echo

SHOWN=""
section() {
    local title="$1"; shift
    local commits files dirty
    commits="$(g log --no-merges --format='    %h %ad %s' --date=short "$BASE..HEAD" -- "$@")"
    SHOWN="$SHOWN $(g log --no-merges --format=%h "$BASE..HEAD" -- "$@" | tr '\n' ' ')"
    files="$(g diff --stat=100 "$BASE" -- "$@" | tail -1)"
    dirty="$(g status --short -- "$@")"
    echo "■ $title"
    if [ -z "$commits" ] && [ -z "$dirty" ]; then
        echo "    no changes"
    else
        [ -n "$commits" ] && echo "$commits"
        [ -n "$dirty" ] && { echo "    uncommitted in GIST's working tree:"; echo "$dirty" | sed 's/^/      /'; }
        [ -n "$files" ] && echo "    total:$files"
    fi
    echo
}
# shellcheck disable=SC2086
section "Shared crates: compiled into contextGIST, changes arrive on the next build (check behaviour + tests)" $SHARED_CRATES
section "GIST's Swift pacing/ORP code: PacingEngine is a hand port, so diff and port applicable fixes" $SWIFT_PORT
section "Icon artwork: tools/gen-app-icon.sh --refresh-source picks up new artwork" $ICON_ART
# shellcheck disable=SC2086
section "Security/dependency policy: mirror applicable rules in deny.toml / SECURITY_REVIEW.md" $POLICY

# Commits not already listed in a section above.
OTHER=""
for sha in $(g log --no-merges --format=%h "$BASE..HEAD"); do
    case " $SHOWN " in *" $sha "*) ;; *) OTHER="$OTHER$(g log -1 --format='    %h %ad %s' --date=short "$sha")
" ;; esac
done
OTHER="${OTHER%
}"
echo "■ Everything else: usually GIST-only (library, storage, Windows...). Skim for fixes to shared ideas."
if [ -z "$OTHER" ]; then echo "    no changes"; else
    echo "$OTHER" | head -40
    N="$(echo "$OTHER" | wc -l | tr -d ' ')"
    [ "$N" -gt 40 ] && echo "    … and $((N - 40)) more"
fi
echo

if command -v gh >/dev/null 2>&1; then
    ISSUES="$(gh issue list --repo BelongaGezza/gist --state all --search 'contextGIST in:body' \
        --json number,state,title --jq '.[] | "    #\(.number) [\(.state)] \(.title)"' 2>/dev/null || true)"
    if [ -n "$ISSUES" ]; then
        echo "■ GIST issues that mention contextGIST (a closed one may need a matching change here)"
        echo "$ISSUES"
        echo
    fi
fi

echo "Next: decide adopt / port / skip for each item. When done, run the tests"
echo "and record the review:  tools/upstream-review.sh --record \"<what you adopted/skipped>\""
