# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue or pull request:

- Use GitHub's **Report a vulnerability** button on the
  [Security tab](https://github.com/BelongaGezza/contextGIST/security/advisories/new).

Include what you found, the version or commit, and steps to reproduce. This is a
small, single-maintainer project: expect an acknowledgement within about a week,
and a fix or a decision on a best-effort basis. Please allow time for a fix
before disclosing publicly. Credit is given in the advisory if you want it.

## Supported versions

There is no signed release yet. Only the current `main` branch is supported, and
the committed macOS DMG is an unsigned development build that must not be
distributed (see S-01 in [`docs/REVIEW_2026-10-21.md`](./docs/REVIEW_2026-10-21.md)).
The Windows installer is a prototype with no app payload.

## Scope

In scope: the Rust core and FFI crates, the macOS app, the Windows installer
scripts under `tools/windows/`, and the CI workflows.

Out of scope: the upstream [GIST](https://github.com/BelongaGezza/gist) crates
(report those there), and issues that need an already-compromised machine or
user account.

## What the app does and does not do

contextGIST handles selected text locally and discards it when the popup closes.
It has no accounts, no network access and no persistence. The details are in
[`docs/PRIVACY.md`](./docs/PRIVACY.md); the known findings and their status are in
[`docs/SECURITY_REVIEW.md`](./docs/SECURITY_REVIEW.md). Please check those before
reporting, in case the issue is already tracked.

## Repository protections

Secret scanning with push protection, Dependabot alerts and security updates, and
private vulnerability reporting are enabled. `main` requires the `ci-ok` check and
blocks force-pushes. Dependencies are audited with `cargo deny` in CI.
