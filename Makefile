.PHONY: build test

# embedded_docs.ml is auto-generated on every `dune build` via the rule in
# compiler/lib/dune — no separate step needed.  Just build normally:
build:
	cd compiler && dune build

test:
	cd compiler && dune test
