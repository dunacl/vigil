# Contributing to Vigil

Thanks for your interest! This document explains how to propose changes.

## Ground rules

Vigil's principles, in priority order:

1. **Unnoticeable** — CPU, RAM and energy use must stay within the performance budgets.
2. **Simple** — every setting and feature must earn its place.
3. **Small** — no third-party dependencies.
4. **Correct** — values must match Activity Monitor and never show garbage.

Changes that conflict with these will likely be declined, however well built.
For larger features, please open an issue to discuss before writing code.

## Development setup

- macOS 26 or later, Xcode 26 or later.
- `make` lists every task. `make test` runs the tests; run `make ci` (lint,
  warnings-as-errors build, tests) before opening a pull request — it is what CI runs.

## Making a change

1. Fork and create a branch from `main` (`feature/…`, `fix/…`).
2. Keep commits focused; write messages in the imperative mood
   ("Add network collector", not "Added…").
3. Add or update tests. Core logic (collectors, layout engine, appearance
   resolution) must be unit-tested.
4. Run `make ci` and make sure it passes with no warnings
   (Swift 6 strict concurrency is on).
5. Open a pull request using the template and describe *what* and *why*.

## Code style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Format with `swift format` using the repository configuration.
- No force unwraps or `try!` in `VigilCore`.
- Sampling hot paths: no per-tick allocations, no `String` creation,
  no bridging CF dictionaries to Swift dictionaries.
- Undocumented system APIs live only in `CVigilSys` / their bridge file, are
  resolved at runtime, and must degrade gracefully when missing.

## Performance changes

If your change touches sampling or rendering, include before/after numbers
(Instruments CPU and memory for Vigil and WindowServer) in the pull request.
For sampling changes, `swift run -c release vigil-probe --bench 10000` before and
after is the minimum: tick p95 must stay ≤ 2 ms and Mach ports must not grow.

## Reporting bugs

Open an issue with your macOS version, Mac model, steps to reproduce and,
if relevant, a screenshot. For security issues, follow [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), as described in section 5 of the license.
