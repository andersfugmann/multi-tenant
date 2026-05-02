.PHONY: build test test-extension clean fmt lint install deb

build:
	dune build @all

test:
	dune runtest

test-extension: build
	cd extension && npm test

clean:
	dune clean

fmt:
	dune fmt

lint:
	dune build @check

install:
	dune install

VERSION ?= 0.0.0

extension/key.pem:
	gh api repos/:owner/:repo/actions/variables/EXTENSION_SIGNING_KEY --jq '.value' > $@

deb: extension/key.pem
	sed -i "1s/([^)]*)/($(VERSION))/" debian/changelog
	sed -i 's/"version": "[^"]*"/"version": "$(VERSION)"/' extension/manifest.json
	sed -i 's/"external_version": "[^"]*"/"external_version": "$(VERSION)"/' debian/dihkhgdagigaecpjlbfbiecpocnbeheh.json
	dpkg-buildpackage -us -uc -b -d
	@mkdir -p _build/deb
	mv ../url-router_$(VERSION)_*.deb _build/deb/
	mv ../url-router-client_$(VERSION)_*.deb _build/deb/
	@echo "Built packages in _build/deb/"
