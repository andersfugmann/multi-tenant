.PHONY: build test test-extension clean fmt lint install deb help

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build all targets
	dune build @all

test: ## Run tests
	dune runtest

test-extension: build ## Build and run extension tests
	cd extension && npm test

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
	sed -i 's/"external_version": "[^"]*"/"external_version": "$(VERSION)"/' debian/dihkhgdagigaecpjlbfbiecpocnbeheh.json
	dpkg-buildpackage -us -uc -b -d
	@mkdir -p _build/deb
	mv ../url-router_$(VERSION)_*.deb _build/deb/
	mv ../url-router-client_$(VERSION)_*.deb _build/deb/
	@echo "Built packages in _build/deb/"
