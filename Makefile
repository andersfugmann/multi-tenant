.PHONY: all build build-rust build-extension test test-rust lint lint-rust lint-extension \
       clean clean-rust clean-extension install deb deb-server deb-extension help

# Defaults
CARGO       ?= cargo
NPM         ?= npm
PREFIX      ?= /usr/local
DESTDIR     ?=
EXT_DIR     := extension
RELEASE_DIR := target/release

all: build ## Build everything (Rust + extension)

# ── Build ────────────────────────────────────────────────────────────

build: build-rust build-extension ## Build all components

build-rust: ## Build Rust workspace (release)
	$(CARGO) build --release

build-debug: ## Build Rust workspace (debug)
	$(CARGO) build

build-extension: $(EXT_DIR)/node_modules ## Build browser extension
	cd $(EXT_DIR) && $(NPM) run build

$(EXT_DIR)/node_modules: $(EXT_DIR)/package.json $(EXT_DIR)/package-lock.json
	cd $(EXT_DIR) && $(NPM) install
	@touch $@

# ── Test ─────────────────────────────────────────────────────────────

test: test-rust lint-extension ## Run all tests and lints

test-rust: ## Run Rust tests
	$(CARGO) test

# ── Lint ─────────────────────────────────────────────────────────────

lint: lint-rust lint-extension ## Run all linters

lint-rust: ## Clippy + format check
	$(CARGO) clippy --all-targets -- -D warnings
	$(CARGO) fmt --check

lint-extension: $(EXT_DIR)/node_modules ## Type-check browser extension
	cd $(EXT_DIR) && $(NPM) run lint

# ── Format ───────────────────────────────────────────────────────────

fmt: ## Auto-format Rust code
	$(CARGO) fmt

# ── Clean ────────────────────────────────────────────────────────────

clean: clean-rust clean-extension ## Remove all build artifacts

clean-rust:
	$(CARGO) clean

clean-extension:
	rm -rf $(EXT_DIR)/dist $(EXT_DIR)/node_modules

# ── Install ──────────────────────────────────────────────────────────

install: build ## Install binaries and config to DESTDIR/PREFIX
	install -Dm755 $(RELEASE_DIR)/url-router          $(DESTDIR)$(PREFIX)/bin/url-router
	install -Dm755 $(RELEASE_DIR)/url-router-client $(DESTDIR)$(PREFIX)/bin/url-router-client
	install -Dm644 dist/systemd/url-router.service    $(DESTDIR)/usr/lib/systemd/user/url-router.service
	install -Dm644 dist/systemd/url-router.tmpfiles    $(DESTDIR)/usr/lib/tmpfiles.d/url-router.conf
	install -Dm644 dist/url-router.desktop             $(DESTDIR)/usr/share/applications/url-router.desktop
	install -Dm644 dist/config/config.json             $(DESTDIR)/etc/url-router/config.json
	install -Dm644 dist/native-messaging-hosts/com.url_router.json \
	               $(DESTDIR)/etc/chromium/native-messaging-hosts/com.url_router.json
	install -d     $(DESTDIR)/usr/share/url-router/extension/dist
	install -Dm644 $(EXT_DIR)/manifest.json            $(DESTDIR)/usr/share/url-router/extension/manifest.json
	install -Dm644 $(EXT_DIR)/popup.html               $(DESTDIR)/usr/share/url-router/extension/popup.html
	install -Dm644 $(EXT_DIR)/dist/*.js                $(DESTDIR)/usr/share/url-router/extension/dist/
	install -d     $(DESTDIR)/usr/share/url-router/extension/icons
	install -Dm644 $(EXT_DIR)/icons/*.png              $(DESTDIR)/usr/share/url-router/extension/icons/

# ── Debian packages ─────────────────────────────────────────────────

deb: deb-server deb-extension ## Build all .deb packages

deb-server: build-rust ## Build url-router .deb
	$(CARGO) deb -p url-router --no-build

deb-extension: build-rust build-extension ## Build url-router-extension .deb
	$(CARGO) deb -p url-router-client --no-build

# ── Help ─────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
