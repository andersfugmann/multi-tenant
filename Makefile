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

deb:
	sed -i "1s/([^)]*)/($(VERSION))/" debian/changelog
	dpkg-buildpackage -us -uc -b -d
	@mkdir -p _build/deb
	mv ../url-router_$(VERSION)_*.deb _build/deb/
	mv ../url-router-client_$(VERSION)_*.deb _build/deb/
	@echo "Built packages in _build/deb/"
