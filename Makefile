.PHONY: build test diff-proofs diff-proofs-full bench bench-quick test-net-off

# embedded_docs.ml is auto-generated on every `dune build` via the rule in
# compiler/lib/dune — no separate step needed.  Just build normally:
build:
	cd compiler && dune build

test:
	cd compiler && dune test

# ---------------------------------------------------------------------------
# Zero-cost-proofs audit harness (roadmap A / agent ZC-HARNESS).
# ---------------------------------------------------------------------------

# Compiler binary used by the proof targets.  Override with `make TESL_MAIN=…`.
TESL_MAIN ?= compiler/_build/default/bin/main.exe

# diff-proofs — behavioral-equivalence audit (net-off vs net-on) across a quick
# subset of the corpus.  Compiles each testable .tesl twice (env unset / set),
# asserts the emitted .rkt is byte-identical, then runs each test submodule in
# both modes and diffs normalized output.  Until ZC-SWITCH wires the erasure
# this passes trivially (net-on == net-off).
#
# Each run loads the linked tesl/dsl, which in a fresh checkout is NOT
# precompiled, so every Racket invocation pays a one-time ~10-13s DSL expansion
# — the same cost compile-examples.sh's test sweep pays ("will take a few
# minutes").  The default subset is kept small for inner-loop use; warm the DSL
# bytecode first (run compile-examples.sh once, or `raco make` the dsl entry
# points) to make larger runs fast.
#
# diff-proofs-full audits the WHOLE corpus (the gate for net deletion).
# ZC-FINALIZE should run it with DIFFPROOFS_FORCE_DSL_PURGE=1 so the toggle is
# re-read fresh per mode (strict; required once the toggle is real):
#     DIFFPROOFS_FORCE_DSL_PURGE=1 make diff-proofs-full
diff-proofs: build
	scripts/differential-proofs.sh --subset 5

diff-proofs-full: build
	scripts/differential-proofs.sh

# bench — proof-overhead benchmark.  Prints a {net-off, net-on} table of
# ns/call and bytes/call for a proof-heavy hot path (fn with 3 proof params).
# Both rows match until ZC-SWITCH lands; the table is ready to show the delta.
# `make bench` runs a moderate size; `make bench-quick` is a CI smoke run.
bench:
	racket tests/bench/proof-overhead.rkt --iters 300000 --trials 5

bench-quick:
	racket tests/bench/proof-overhead.rkt --quick

# test-net-off — run the positive corpus test submodules with the net DISABLED
# (TESL_ZERO_COST_PROOFS=1, i.e. the future zero-cost mode) and report pass/fail.
# Verification step 4: every positive expect/expectHasProof still passes with
# the net off.  Self-contained: compiles every testable .tesl fresh into a
# scratch mirror (never touching tracked .rkt), purges bytecode so the
# expansion-time switch is read fresh, then drives tests/example-test-batch.rkt.
test-net-off: build
	@set -eu; \
	ROOT="$$(pwd)"; \
	MAIN="$(TESL_MAIN)"; \
	WORK="$$(mktemp -d "$${TMPDIR:-/tmp}/tesl-netoff.XXXXXX")"; \
	trap 'rm -rf "$$WORK"' EXIT; \
	printf '\n  Compiling testable corpus into scratch mirror...\n'; \
	count=0; \
	for f in tests/*.tesl example/learn/*.tesl; do \
		grep -qE '^[[:space:]]*test[[:space:]]+"' "$$f" || continue; \
		rel="$$f"; mkdir -p "$$WORK/$$(dirname "$$rel")"; \
		cp "$$f" "$$WORK/$$rel"; \
		if ! "$$MAIN" "$$f" > "$$WORK/$${rel%.tesl}.rkt" 2>"$$WORK/$${rel%.tesl}.err"; then \
			printf '  \033[31m✗ compile failed:\033[0m %s\n' "$$rel"; \
			sed 's/^/      /' "$$WORK/$${rel%.tesl}.err" | head -6; \
			exit 1; \
		fi; \
		count=$$((count + 1)); \
	done; \
	printf '  Compiled %d testable file(s).\n' "$$count"; \
	printf '  Purging bytecode and running test submodules with TESL_ZERO_COST_PROOFS=1...\n\n'; \
	find "$$WORK" -type d -name compiled -prune -exec rm -rf {} + 2>/dev/null || true; \
	cd "$$WORK"; \
	files=""; \
	for f in tests/*.tesl example/learn/*.tesl; do \
		[ -f "$$f" ] || continue; files="$$files $$f"; \
	done; \
	rc=0; \
	TESL_ZERO_COST_PROOFS=1 racket "$$ROOT/tests/example-test-batch.rkt" $$files || rc=$$?; \
	exit $$rc
