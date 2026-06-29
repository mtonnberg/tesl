.PHONY: build test bench bench-quick

# embedded_docs.ml is auto-generated on every `dune build` via the rule in
# compiler/lib/dune — no separate step needed.  Just build normally:
build:
	cd compiler && dune build

test:
	cd compiler && dune test

# ---------------------------------------------------------------------------
# Proof-overhead benchmark.
# ---------------------------------------------------------------------------

# bench — proof-overhead benchmark.  Prints ns/call and bytes/call for a
# proof-heavy hot path (fn with 3 proof params) under the zero-cost erasure.
# `make bench` runs a moderate size; `make bench-quick` is a CI smoke run.
bench:
	racket tests/bench/proof-overhead.rkt --iters 300000 --trials 5

bench-quick:
	racket tests/bench/proof-overhead.rkt --quick
