# Security policy

contextGIST processes text the user selects, entirely on the user's device. It
has no network access, accounts or telemetry, and it keeps nothing after the
popup closes (see [`docs/PRIVACY.md`](docs/PRIVACY.md)).

## Reporting a vulnerability

Please report privately, not in a public issue: use GitHub's
[private vulnerability reporting](https://github.com/BelongaGezza/contextGIST/security/advisories/new)
for this repository. Include the version or commit, the platform, and steps to
reproduce. Do not include real personal text in a report; a synthetic sample
that reproduces the problem is enough.

Reports of particular interest: any path by which selected text is written to
disk, logged, sent over a network, or left in a crash report; and any way for
another process to trigger a read or observe the popup.

## Scope and status

There is no signed release yet. The most recent reviews and their open
findings are in [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) and
[`docs/REVIEW_2026-10-21.md`](docs/REVIEW_2026-10-21.md); the committed macOS
DMG is an unsigned developer build and must not be distributed.
