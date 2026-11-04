# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - unreleased (first public build)

### Added

- Hardening against crafted layout and settings files: size, panel-count and
  length limits; finite, clamped geometry and alert thresholds; sensor readings
  outside plausible ranges are dropped; long `/regex/` filters fall back to text.
- GitHub Actions: CI (lint, build with warnings as errors, tests with coverage,
  release bundle check), tag-triggered signed/notarized release, CodeQL, Dependabot.
- `Makefile`: `make` lists build, test, lint, coverage, bundle, release and measurement tasks.
- `VigilUITests`: every panel kind × size rendered empty and with live data.
- App icon; release pipeline producing a signed, notarized DMG (`scripts/release.sh`).
- Crash and hang diagnostics saved locally to `~/Library/Logs/Vigil/` (MetricKit; nothing is sent).
- Panels re-assert their place when the Dock or Finder restarts.
- Performance sign-off and soak scripts.
- Project scaffolding: license, contribution guidelines, code of conduct, security policy.
- `VigilCore`: CPU (per core, grouped by the Mac's performance tiers), memory (Activity
  Monitor definitions, pressure, swap), network (64-bit per-interface counters, primary
  interface), disk I/O (per physical disk) and volume capacity collectors.
- Demand-driven `Sampler` actor with a single coalescing timer, gap and counter-reset
  handling, and an `AsyncStream` of immutable snapshots.
- Fixed-capacity `RingBuffer` for metric history.
- `vigil-probe` command-line readout and sampling benchmark.
- Desktop panels: CPU, Memory, Network and Disk in Small and Medium sizes, each in
  its own Liquid Glass window above the desktop icons and below app windows.
  Panel content is drawn with Core Animation layers (≈0.5 MB and 0.014% CPU per
  panel), chosen over SwiftUI by measurement.
- Placement by display, 9-point anchor and offset; panels stay in their corner
  when resolution or the Dock changes, and return when a disconnected display
  comes back.
- Desktop (Space) choice per panel: all desktops, this desktop, or Desktop N.
- Sampling follows visibility: metrics of covered panels or panels on other
  desktops stop being collected; the timer stops entirely when nothing is needed.
- Disk hot-plug and default-route changes are event-driven (no polling).
- Pause/resume across sleep and display sleep; menu bar item with Pause and Quit.
- Edit Mode (⌃⌥E or menu bar): drag panels with snapping to screen margins,
  other panels and an 8 pt grid (hold ⌘ for free placement), resize from the
  corner grip with magnetic size classes, no-overlap on drop, arrow-key nudge,
  Delete to remove, unlimited undo/redo.
- Panel Gallery with live previews of every panel kind and size; warns when more
  than 6 glass panels are visible.
- Panel settings popover: display, 9-point anchor and offset, desktop, size,
  background (glass, clear glass, solid), layer, click-through, hide, remove.
- Layout is saved automatically (atomic writes, last-good backup, lenient
  loading of older/newer files); menu bar "Panels" list to show/hide panels and
  "Gather All Panels".
- Lower WindowServer cost: one batched redraw per tick and change-only updates.
- Extra small panel size: one number and a sparkline (two compact lines for rates).
- Settings window with a live preview: background (glass, solid, none),
  transparency, content opacity, tint, corners, border, theme (System, btop, Mono),
  graph style (area, line), hover fade/hide, update rate, units (binary/decimal,
  network in bits) and alert thresholds. Each panel can override any of these.
- Alerts tint a panel amber or red: sustained CPU load, macOS memory pressure,
  and disk fullness.
- Process collector: every process via one `KERN_PROC_ALL` call, CPU/memory/disk
  for the user's own processes, identities that survive PID reuse.
- Top Processes panel (by CPU or memory, three sizes); click a row to open the
  Dashboard on that process.
- Process Dashboard (⌃⌥V): sortable table with app icons, filter (substring or
  /regex/), list or tree view, detail pane with arguments, threads, open files and
  live CPU/memory graphs, Send Signal with identity check, context menu, btop-style
  keys. Shows a Dock icon while open; samples processes only while visible.
- Hardware panels: GPU (utilization, rendering/geometry, memory), Battery (charge,
  time left, health, cycles, power, adapter), Thermals (macOS thermal pressure;
  optionally chip/SSD/battery temperatures, fans and power) and This Mac.
- Opt-in sensor reading (Settings → General → Sensors) through undocumented
  interfaces, isolated so a failure only hides that reading.
- Layouts: any number of saved layouts, five presets (Standard, Minimal, btop,
  Sidebar, Developer), import/export as `.vigillayout`, and automatic switching
  by connected displays. Older layout files migrate automatically.
- Settings → General: optional live readout in the menu bar, open at login,
  rebindable global shortcuts (Edit Layout ⌃⌥E, Processes ⌃⌥V, Peek ⌃⌥Space),
  hide panels from screenshots and screen sharing, and slower updates in Low
  Power Mode or when the Mac is hot.
- Peek (⌃⌥Space) brings panels above your windows until pressed again.
- Settings → Layouts lists every panel of the current layout with show/hide,
  duplicate and remove.
- Accessibility: Reduce Transparency switches panels to solid, Increase Contrast
  adds borders and an opaque backing, Reduce Motion turns off fades and pulses.
