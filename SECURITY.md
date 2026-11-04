# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" under the repository's **Security** tab).

Include a description, affected version, macOS version and steps to reproduce.
We aim to acknowledge reports within 7 days and to share a fix timeline after triage.

## Scope

Vigil is not sandboxed and reads system and process information; it does not
open network connections. Issues of particular interest include anything that
lets another process or user abuse Vigil's access, or that crashes Vigil from
crafted system state.

## Security model

What Vigil does and doesn't do, so reports can be judged against it:

- **No network.** Vigil links no networking APIs and makes no connections; crash
  reports (MetricKit) are written to `~/Library/Logs/Vigil/` and never sent.
- **No elevated access.** It runs as the logged-in user and asks for no
  permissions (no Accessibility, Screen Recording, Full Disk Access or admin).
  Other users' processes are listed but not measured, as macOS allows.
- **Hardened runtime**, no entitlements, Developer ID signed and notarized
  releases. Not sandboxed: the App Sandbox blocks the per-process and IOKit
  reads a system monitor needs.
- **Undocumented interfaces** are opt-in or fail closed: SkyLight (Desktop N)
  and HID/SMC sensors are loaded with `dlopen` from absolute system paths and
  resolved with `dlsym`; the SMC is only ever read (key info and read-key
  commands), never written. Readings outside plausible ranges are dropped.
- **Signals** (Dashboard → Send Signal) go only to processes macOS lets the user
  signal anyway, and only after re-checking the process's start time so a reused
  PID is never hit.
- **Untrusted input is bounded:** layout files (imported or on disk) are capped
  at 1 MB, 64 panels per layout and 100 layouts, with sizes, offsets and names
  clamped; settings values are clamped on load; `/regex/` process filters are
  limited to 256 characters.
- **Privacy.** Process names, paths and arguments are shown only in Vigil's own
  windows and are never logged. Use Settings → General → *Hide panels in
  screenshots and screen sharing* if your panels show things you don't want captured.
