.PHONY: build test test-extension clean fmt lint install deb help deps

.DEFAULT_GOAL := build

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build all targets
	dune build @all

test: ## Run OCaml tests
	dune runtest

_build/node_modules/.stamp: extension/package.json
	@mkdir -p _build
	cp extension/package.json _build/
	cd _build && npm install --no-package-lock --quiet
	@touch $@

deps: _build/node_modules/.stamp ## Install node dependencies

test-extension: build _build/node_modules/.stamp ## Build and run extension tests
	cd extension && NODE_PATH=../_build/node_modules ../_build/node_modules/.bin/jest --forceExit

clean: ## Clean build artifacts
	dune clean

fmt: ## Format source code
	dune fmt

lint: ## Run lint checks
	dune build @check

install: ## Install via dune
	dune install

VERSION ?= 0.0.0

extension/key.pem:
	gh api repos/:owner/:repo/actions/variables/EXTENSION_SIGNING_KEY --jq '.value' > $@

deb: extension/key.pem ## Build debian packages (VERSION=x.y.z)
	sed -i "1s/([^)]*)/($(VERSION))/" debian/changelog
	sed -i 's/"version": "[^"]*"/"version": "$(VERSION)"/' extension/manifest.json
	sed -i "/<updatecheck/s/version='[^']*'/version='$(VERSION)'/" debian/updates.xml
	sed -i 's/"external_version": "[^"]*"/"external_version": "$(VERSION)"/' debian/chromium-extension.json
	dpkg-buildpackage -us -uc -b -d
	@mkdir -p _build/deb
	mv ../alloyd_$(VERSION)_*.deb _build/deb/
	mv ../alloy_$(VERSION)_*.deb _build/deb/
	@echo "Built packages in _build/deb/"
