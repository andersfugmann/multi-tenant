.PHONY: build test clean fmt lint install deb

build:
	dune build @all

test:
	dune runtest

clean:
	dune clean

fmt:
	dune fmt

lint:
	dune build @check

install:
	dune install

deb:
	@echo "TODO: Debian package build not yet implemented"
