#!/usr/bin/env bash
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TESL_BIN="$REPO_ROOT/compiler/_build/default/bin/main.exe"

# Pre-compile kanel example files with the OCaml compiler to warm up
# the Racket package (generates .rkt artefacts that raco can cache).
# Both PascalCase (KanelBackend.rkt) and kebab-case (kanel-backend.rkt) are
# generated — inter-module require statements use the kebab-case form.
if [ -x "$TESL_BIN" ]; then
  for tesl_file in "$REPO_ROOT"/example/kanel/*.tesl; do
    [ -f "$tesl_file" ] || continue
    # PascalCase output (KanelFoo.tesl → KanelFoo.rkt)
    "$TESL_BIN" "$tesl_file" > "${tesl_file%.tesl}.rkt" 2>/dev/null || true
    # Kebab-case output (KanelFoo.tesl → kanel-foo.rkt) used by collection requires
    pascal=$(basename "${tesl_file%.tesl}")
    kebab=$(echo "$pascal" | sed 's/\([A-Z]\)/-\L\1/g; s/^-//')
    dir=$(dirname "$tesl_file")
    "$TESL_BIN" "$tesl_file" > "$dir/$kebab.rkt" 2>/dev/null || true
  done
fi

# Link the tesl Racket package — skip if already linked to the correct path.
if ! raco pkg show tesl 2>/dev/null | grep -qF "link $REPO_ROOT"; then
  if raco pkg show tesl 2>/dev/null | grep -Eq '^[[:space:]]*tesl([[:space:]]|$)'; then
    raco pkg update --auto --link "$REPO_ROOT"
  else
    raco pkg install --auto --link "$REPO_ROOT"
  fi
fi

# Pre-compile DSL and stdlib .rkt files to .zo bytecode so that subsequent
# `tesl test` / `tesl run` invocations skip recompilation and start in ~0.3s
# rather than ~2.5s.  This is safe to run repeatedly; raco make is idempotent.
echo "Pre-compiling Tesl DSL and stdlib with raco make..."
raco make \
  "$REPO_ROOT"/dsl/*.rkt \
  "$REPO_ROOT"/dsl/private/*.rkt \
  "$REPO_ROOT"/tesl/*.rkt \
  "$REPO_ROOT"/tesl/lang/*.rkt \
  "$REPO_ROOT"/tesl/private/*.rkt \
  2>/dev/null || true
echo "Done."
