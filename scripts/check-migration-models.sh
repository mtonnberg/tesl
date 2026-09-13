#!/usr/bin/env bash
# Exhaustive finite-state checks plus deliberately broken protocols. A mutation
# must produce its expected invariant counterexample, not a parser/JVM failure.
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
tlc_bin="${TESL_TLC:-tlc}"
command -v "$tlc_bin" >/dev/null || { echo 'migration models require tlc (nix develop)' >&2; exit 1; }
model_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tesl-migration-models.XXXXXXXX")"
trap 'rm -rf -- "$model_tmp"' EXIT

run_model() {
  local name="$1" config="$2" expected="${3:-}" result=0
  local log="$model_tmp/$name.log"
  JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Xmx512m" \
    timeout 90s "$tlc_bin" -workers 1 -fpmem 0.1 -metadir "$model_tmp/$name" \
      -config "$config" dev-docs/models/MigrationAdmission.tla >"$log" 2>&1 || result=$?
  if [ -z "$expected" ]; then
    if [ "$result" -ne 0 ] || ! grep -Fq 'Model checking completed. No error has been found.' "$log"; then
      cat "$log"; return 1
    fi
    printf '%s: ' "$name"
    grep -E '^[0-9]+ states generated, [0-9]+ distinct states found, 0 states left on queue\.' "$log"
  else
    if [ "$result" -eq 0 ] || ! grep -Fq "$expected" "$log"; then
      cat "$log"; printf 'mutation %s did not produce %s\n' "$name" "$expected" >&2; return 1
    fi
    printf '%s: expected counterexample found (%s)\n' "$name" "$expected"
  fi
}

run_model admission "$repo_root/dev-docs/models/MigrationAdmission.cfg"
run_model queue "$repo_root/dev-docs/models/MigrationQueue.cfg"
for scenario in \
  'writer-fence:Invariant INVWriter is violated.' \
  'read-lock:Invariant INVReadLock is violated.' \
  'final-pass:Invariant INVFinal is violated.' \
  'queue-floor:Invariant INVQueueFloor is violated.' \
  'claim-token:Invariant INVAttempt is violated.' \
  'read-admission:Action property ReadAdmissionSafe is violated.' \
  'survivor-restamp:Action property SurvivorAttemptPreserved is violated.'; do
  mutation="${scenario%%:*}"
  invariant="${scenario#*:}"
  config="$model_tmp/$mutation.cfg"
  sed "s/Mutation = \"none\"/Mutation = \"$mutation\"/" \
    "$repo_root/dev-docs/models/MigrationQueue.cfg" >"$config"
  run_model "$mutation" "$config" "$invariant"
done
