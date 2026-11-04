# Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.
#
# Shortcuts for everyday tasks. `make` alone lists them. Each target wraps a
# SwiftPM command or a script in scripts/, so nothing here is required.

SHELL := /bin/zsh
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

LINT_PATHS := Sources Tests tools Package.swift
HOURS ?= 24

##@ Develop
build: ## Debug build
	swift build

test: ## Run all tests
	swift test --parallel

lint: ## Check formatting (as CI does)
	swift format lint --strict --recursive $(LINT_PATHS)

format: ## Fix formatting in place
	swift format --in-place --recursive $(LINT_PATHS)

coverage: ## Tests with a per-file coverage report (coverage.txt)
	swift test --enable-code-coverage --parallel
	bin=$$(swift build --show-bin-path); \
	xctest=$$(find "$$bin" -path '*PackageTests.xctest/Contents/MacOS/*' -type f -perm +111 | head -1); \
	xcrun llvm-cov report "$$xctest" -instr-profile "$$bin/codecov/default.profdata" \
	    -ignore-filename-regex='(Tests|\.build)/' | tee coverage.txt

ci: lint ## Everything CI checks: lint, warnings-as-errors build, tests
	swift build --build-tests -Xswiftc -warnings-as-errors
	$(MAKE) test

run: ## Run the app from source (release build, no bundle)
	swift run -c release Vigil

probe: ## Live readout of every collector
	swift run -c release vigil-probe

bench: ## Sampling cost benchmark (10,000 ticks)
	swift run -c release vigil-probe --bench 10000

##@ Ship
app: ## dist/Vigil.app (universal; SIGN_IDENTITY=... for Developer ID)
	scripts/bundle-app.sh

dmg: ## dist/Vigil-<version>.dmg (SIGN_IDENTITY + NOTARY_PROFILE to sign and notarize)
	scripts/release.sh

icon: ## Regenerate assets/AppIcon-1024.png and AppIcon.icns
	swift tools/make-icon.swift assets/AppIcon-1024.png
	tools/make-icns.sh

##@ Measure (on an idle Mac)
perf: ## Every performance budget, PASS/FAIL (~12 min)
	scripts/perf-signoff.sh

soak: ## Stability run; HOURS=24 by default
	scripts/soak.sh $(HOURS)

panel-cost: ## Cost of 0, 1, 6, 12 panels
	scripts/panel-cost.sh

windowserver: ## Where window-server cost comes from
	scripts/windowserver-ab.sh

##@ Housekeeping
clean: ## Remove build products and the coverage report
	swift package clean
	rm -f coverage.txt

distclean: clean ## Also remove .build/ and dist/ (built apps, DMGs, soak logs)
	rm -rf ./.build ./dist

help: ## List targets
	@awk 'BEGIN { FS = ":.*## " } \
	    /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
	    /^[a-z-]+:.*## / { printf "  \033[36mmake %-13s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: build test lint format coverage ci run probe bench app dmg icon perf soak panel-cost windowserver clean distclean help
