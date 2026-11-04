# Vigil

A macOS resource monitor with the information density of
[btop](https://github.com/aristocratos/btop), shown as Liquid Glass panels that live
on your desktop — behind your windows, out of the way, always there when you look.

It's built to be unnoticeable: the default layout uses about **0.1 % of one CPU core
and under 20 MB of memory**, with no network access and no telemetry.

## What it shows

| Panel | |
| --- | --- |
| **CPU** | Load and history, user/system split, load average, every core grouped by your Mac's core types |
| **Memory** | Used (as Activity Monitor counts it), app/wired/compressed/cached, macOS memory pressure, swap |
| **Network** | Download and upload speed with an auto-scaling graph, totals |
| **Disk** | Read and write speed, free space on your volumes |
| **Top Processes** | The busiest processes by CPU or memory — click one to see it in the Dashboard |
| **GPU** | Load, rendering/geometry, memory in use |
| **Battery** | Charge, time left, health, cycles, power in or out, adapter |
| **Thermals** | macOS's thermal pressure; optionally chip, SSD and battery temperatures, fans and power |
| **This Mac** | macOS version, uptime, chip, memory |

Every panel comes in three sizes (extra small, small, medium), and a panel turns
amber or red when something runs hot for a while.

## Install

1. Download `Vigil-<version>.dmg` from the releases page and drag **Vigil** to
   **Applications**.
2. Open it. Panels appear at the top right of your main display, and a gauge icon
   appears in the menu bar.

Requires **macOS 26 (Tahoe) or later**; Apple Silicon recommended. Vigil asks for
no permissions: no Accessibility, Screen Recording or administrator access.

## Using Vigil

Everything starts from the **gauge icon in the menu bar**.

- **Arrange panels — Edit Layout (⌃⌥E).** Drag panels anywhere (they snap to
  edges, each other and a grid; hold ⌘ to place freely), resize from the corner,
  click ⚙ for a panel's display, position, desktop, size and look, or **Add
  Panel…** for the gallery. Arrow keys nudge, ⌘Z undoes, Esc finishes.
- **Layouts.** Keep several layouts and switch from the menu bar, or start from a
  preset: Standard, Minimal, btop, Sidebar, Developer. A layout can switch on by
  itself when you connect a particular set of displays (Settings → Layouts).
- **Peek (⌃⌥Space).** Brings the panels above your windows; press again to send
  them back.
- **Processes (⌃⌥V).** Every process with filter (`/regex/` works too), list or tree,
  sorting, details and Send Signal. Keys: j/k move, h/l change the sort column, r
  reverses, t toggles the tree, / filters, Return shows details, S sends a signal,
  Space pauses, p/⇧p switch layouts.
- **Settings (⌘,).** Glass, solid or no background, transparency, tint, theme,
  graph style, what happens when the pointer is over a panel, update rate, units,
  alert levels, shortcuts, open at login, and hiding panels from screenshots.

Your layouts are saved in `~/Library/Application Support/Vigil/Layouts/`.

## Good to know

- **Other users' processes.** macOS lets apps see every process but only measure
  your own. System processes (WindowServer, kernel_task, …) are listed with "—"
  for CPU and memory. A privileged helper to fill these in is planned.
- **Temperatures, fans and power** come from interfaces macOS doesn't document, so
  they're off until you turn on **Settings → General → Sensors**. If a macOS update
  breaks one, Vigil just stops showing that reading.
- **Desktop N.** Pinning a panel to a specific desktop also uses an undocumented
  interface; if it's unavailable, the panel shows on all desktops instead.
- **Energy.** Each glass panel costs the system's window server a little; for many
  panels, a solid background or a slower update rate is lighter. A live number in
  the menu bar is optional for the same reason.
- **Crash reports** stay on your Mac in `~/Library/Logs/Vigil/`. Attach them to a
  bug report if you like; Vigil never sends anything.

## Building from source

Requires Xcode 26 or later.

```sh
git clone <repo-url> vigil && cd vigil
make                                # list every task
make test                           # swift test
make ci                             # what CI checks: lint, warnings-as-errors build, tests
make run                            # run the app without bundling
make app                            # dist/Vigil.app (universal, ad-hoc signed)
make dmg                            # dist/Vigil-<version>.dmg (see scripts/release.sh for signing/notarizing)
```

Every target is a thin wrapper around `swift` or a script in `scripts/`, so you
can run those directly too.

### Tools for contributors

```sh
swift run -c release vigil-probe                    # live readout of everything the core library sees
swift run -c release vigil-probe --bench 10000      # sampling cost: tick p50/p95, CPU, memory, Mach ports
swift run -c release vigil-probe --only gpu,battery,sensors --private-sensors
scripts/perf-signoff.sh             # every performance budget, PASS/FAIL (idle Mac, ~12 min)
scripts/soak.sh 24                  # 24-hour stability run, CPU/memory every 5 minutes
scripts/panel-cost.sh               # cost of 0, 1, 6, 12 panels
scripts/windowserver-ab.sh          # where window-server cost comes from (idle Mac)
```

Developer flags for the app (all optional): `--layout-file PATH` (scratch layout and
settings), `--preset NAME`, `--edit`, `--gallery`, `--inspect ID`, `--settings [tab]`,
`--dashboard`, `--desktop N`, `--list-spaces`, `--measure …` (see
`Sources/Vigil/LaunchOptions.swift`).

| Path | Contents |
| --- | --- |
| `Sources/CVigilSys` | C declarations for system interfaces Swift can't import (SMC, HID, SkyLight) |
| `Sources/VigilCore` | Collectors, sampler, history, layout engine, appearance, settings. No UI. |
| `Sources/VigilUI` | Panel views (Core Animation layers), graphs, `MetricsStore` |
| `Sources/Vigil` | The app: desktop windows, Edit Mode, Dashboard, Settings, menu bar |
| `Sources/vigil-probe` | Command-line readout and benchmark |
| `Tests/VigilCoreTests` | Unit tests and integration tests on real hardware |
| `Tests/VigilUITests` | Smoke tests: every panel in every size and style |
| `tools/` | Icon generator |

## Contributing

Project status and what's left before the first release: [docs/STATUS.md](docs/STATUS.md).
See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).
Security issues: [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE).
