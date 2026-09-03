#!/usr/bin/env bash
# Run one Go fuzz target for the gate, retrying ONLY the fuzz engine's own
# deadline race.
#
#   scripts/go-fuzz-target.sh <package> <FuzzTarget> [fuzztime]
#
# `go test -fuzz` ends the run with a context deadline (-fuzztime).  In Go's
# internal/fuzz coordinator (fuzz.go, CoordinateFuzzing) the timer fires on the
# parent context and the coordinator wakes on its Done channel and calls
# stop(ctx.Err()); stop suppresses the error only if it equals fuzzCtx.Err(), the
# CHILD context's error.  context closes a parent's Done channel BEFORE it cancels
# the children, so on a busy machine the child's error can still be nil in that
# window, the deadline is recorded as the run's error, and the target FAILS with
# nothing but "context deadline exceeded" — no crasher, no input to re-run.  Seen
# twice on the 4-core GitHub runner (protocol.FuzzUTF16PositionsNeverPanic,
# protocol.FuzzReaderAcceptsWriterFrames), never in 15 loaded local runs.
#
# A REAL finding is different in kind: the coordinator writes the input to
# testdata/fuzz/<Target>/ and prints "Failing input written to …".  So this
# script retries (twice) only when the output has the bare deadline error and no
# crasher line; every other failure is reported at once, exactly as before.
set -uo pipefail

package="${1:?package (e.g. ./teslrt)}"
target="${2:?fuzz target name}"
fuzztime="${3:-${TESL_GO_FUZZTIME:-3s}}"
attempts="${TESL_GO_FUZZ_ATTEMPTS:-3}"

for attempt in $(seq 1 "$attempts"); do
    output="$(go test "$package" -run '^$' -fuzz "^${target}\$" -fuzztime="$fuzztime" 2>&1)"
    status=$?
    printf '%s\n' "$output"
    [ "$status" -eq 0 ] && exit 0
    if grep -q 'context deadline exceeded' <<<"$output" \
        && ! grep -q 'Failing input written to' <<<"$output" \
        && [ "$attempt" -lt "$attempts" ]; then
        printf 'go-fuzz-target: %s %s ended in the fuzz engine'"'"'s deadline race (no crasher written) — retrying (%d/%d)\n' \
            "$package" "$target" "$((attempt + 1))" "$attempts" >&2
        continue
    fi
    exit "$status"
done
exit 1
