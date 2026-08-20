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

# bench — Go runtime replacements for the proof and codec overhead probes.
# `make bench` runs the normal Go benchmark budget; `make bench-quick` is a
# short CI smoke run.
bench:
	cd runtime/go && go test ./teslrt -run '^$$' -bench 'Benchmark(Proof|Codec)Overhead' -benchmem

bench-quick:
	cd runtime/go && go test ./teslrt -run '^$$' -bench 'Benchmark(Proof|Codec)Overhead' -benchtime=100ms -benchmem
