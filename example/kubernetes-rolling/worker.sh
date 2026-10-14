#!/bin/sh
# A running process is insufficient: expansion must finish before app rollout.
set -u
state=/tmp/schema-worker
if [ "${1:-}" = --ready ]; then
    test -f "$state.ready" && test -f "$state.pid" || exit 1
    kill -0 "$(cat "$state.pid")" 2>/dev/null
    exit $?
fi
rm -f "$state.ready" "$state.pid" "$state.pipe"
mkfifo "$state.pipe" || exit 1
cleanup() { rm -f "$state.ready" "$state.pid" "$state.pipe"; }
trap cleanup EXIT
(
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if printf '%s\n' "$line" | jq -e '.kind == "schema-worker-ready"' >/dev/null 2>&1; then
            touch "$state.ready"
        fi
    done < "$state.pipe"
) &
reader=$!
/app --schema worker --json > "$state.pipe" &
child=$!
printf '%s\n' "$child" > "$state.pid"
terminate() {
    trap '' TERM INT
    kill -TERM "$child" 2>/dev/null || true
    wait "$child"
    status=$?
    wait "$reader" || true
    exit "$status"
}
trap terminate TERM INT
wait "$child"
status=$?
wait "$reader" || true
exit "$status"
