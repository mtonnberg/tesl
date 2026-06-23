{ pkgs ? import <nixpkgs> {} }:
let
  tesl-cli = pkgs.writeShellScriptBin "tesl" ''
    #!/usr/bin/env bash
    export TESL_REPO_ROOT="${toString ./.}"
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"

    _tesl_require_compiler() {
      if [ ! -x "$TESL_OCAML_COMPILER" ]; then
        echo "error: Tesl compiler not found. Build with: cd $TESL_REPO_ROOT/compiler && dune build bin/main.exe" >&2
        exit 1
      fi
    }

    _tesl_compile_to_stdout() {
      local FILE="$1"
      _tesl_require_compiler
      "$TESL_OCAML_COMPILER" "$FILE"
    }

    _tesl_check() {
      [ $# -gt 0 ] || { echo "Usage: tesl check <file.tesl> [more.tesl ...]" >&2; exit 1; }
      _tesl_require_compiler
      "$TESL_OCAML_COMPILER" --check "$@"
    }

    CMD="''${1:-help}"
    shift || true

    case "$CMD" in
      compile)
        FILE="''${1:?Usage: tesl compile <file.tesl>}"
        OUT="''${FILE%.tesl}.rkt"
        OUT_TMP="$(mktemp --suffix=.rkt)"
        if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
          mv "$OUT_TMP" "$OUT"
          echo "compiled $FILE → $OUT"
        else
          RET=$?
          rm -f "$OUT_TMP"
          exit "$RET"
        fi
        ;;
      check)
        _tesl_check "$@"
        ;;
      check-json)
        [ $# -gt 0 ] || { echo "Usage: tesl check-json <file.tesl>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --check-json "$@"
        ;;
      definition-json)
        [ $# -eq 3 ] || { echo "Usage: tesl definition-json <file.tesl> <line> <col>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --definition-json "$@"
        ;;
      occurrences-json)
        [ $# -eq 3 ] || { echo "Usage: tesl occurrences-json <file.tesl> <line> <col>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --occurrences-json "$@"
        ;;
      type-at-json)
        [ $# -eq 3 ] || { echo "Usage: tesl type-at-json <file.tesl> <line> <col>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --type-at-json "$@"
        ;;
      field-at-json)
        [ $# -eq 3 ] || { echo "Usage: tesl field-at-json <file.tesl> <line> <col>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --field-at-json "$@"
        ;;
      completions-json)
        [ $# -eq 3 ] || { echo "Usage: tesl completions-json <file.tesl> <line> <col>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --completions-json "$@"
        ;;
      local-bindings-json)
        [ $# -gt 0 ] || { echo "Usage: tesl local-bindings-json <file.tesl>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --local-bindings-json "$@"
        ;;
      semantic-json)
        [ $# -gt 0 ] || { echo "Usage: tesl semantic-json <file.tesl>" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --semantic-json "$@"
        ;;
      lint)
        [ $# -gt 0 ] || { echo "Usage: tesl lint <file.tesl> [more.tesl ...]" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --lint "$@"
        ;;
      fmt|format)
        [ $# -gt 0 ] || { echo "Usage: tesl fmt <file.tesl> [more.tesl ...]" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --fmt "$@"
        ;;
      fmt-check)
        [ $# -gt 0 ] || { echo "Usage: tesl fmt-check <file.tesl> [more.tesl ...]" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --fmt-check "$@"
        ;;
      run)
        FILE="''${1:?Usage: tesl run <file.tesl> [args…]}"
        shift
        OUT="$(mktemp --suffix=.rkt)"
        RET=0
        if _tesl_compile_to_stdout "$FILE" > "$OUT"; then
          if [ "''${TESL_VERBOSE:-0}" = "1" ]; then
            racket "$OUT" "$@"; RET=$?
          else
            STDERR_TMP="$(mktemp)"
            racket "$OUT" "$@" 2>"$STDERR_TMP"; RET=$?
            grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
            rm -f "$STDERR_TMP"
          fi
        else
          RET=$?
        fi
        rm -f "$OUT"
        exit "$RET"
        ;;
      test)
        [ $# -gt 0 ] || { echo "Usage: tesl test <file.tesl> [more.tesl ...]" >&2; exit 1; }
        RET=0
        for FILE in "$@"; do
          OUT="''${FILE%.tesl}.rkt"
          OUT_TMP="$(mktemp --suffix=.rkt)"
          if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
            mv "$OUT_TMP" "$OUT"
            if [ "''${TESL_VERBOSE:-0}" = "1" ]; then
              raco test "$OUT" || RET=$?
            else
              STDERR_TMP="$(mktemp)"
              raco test "$OUT" 2>"$STDERR_TMP"; STATUS=$?
              grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
              rm -f "$STDERR_TMP"
              if [ "$STATUS" -ne 0 ]; then
                RET="$STATUS"
              fi
            fi
          else
            STATUS=$?
            rm -f "$OUT_TMP"
            RET="$STATUS"
          fi
        done
        exit "$RET"
        ;;
      watch)
        FILE="''${1:?Usage: tesl watch <file.tesl>}"
        shift
        OUT="''${FILE%.tesl}.rkt"
        RACKET_PID=""
        PREV_SNAP=""
        trap '[ -n "$RACKET_PID" ] && kill "$RACKET_PID" 2>/dev/null' EXIT

        # Collect dependency snapshot using the compiler's --deps flag (if available),
        # falling back to all .tesl files in the same directory.
        _tesl_dep_snapshot() {
          local f="$1"
          local deps
          if command -v "$TESL_OCAML_COMPILER" >/dev/null 2>&1; then
            deps="$("$TESL_OCAML_COMPILER" --deps "$f" 2>/dev/null)"
            # Always include the entry file itself
            deps="$f''${deps:+$'\n'$deps}"
          else
            local dir
            dir="$(dirname "$(realpath "$f")")"
            deps="$(find "$dir" -name "*.tesl" 2>/dev/null)"
          fi
          echo "$deps" | sort -u | xargs -d '\n' stat -c "%n %Y" 2>/dev/null | sort
        }

        echo "[tesl watch] Watching $(realpath "$FILE") and its imports (Ctrl+C to stop)"
        while true; do
          CURR_SNAP="$(_tesl_dep_snapshot "$FILE")"
          if [ "$CURR_SNAP" != "$PREV_SNAP" ]; then
            PREV_SNAP="$CURR_SNAP"
            echo "[tesl watch] Compiling..."
            STDERR_TMP="$(mktemp)"
            if _tesl_compile_to_stdout "$FILE" > "$OUT" 2>"$STDERR_TMP"; then
              grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
              rm -f "$STDERR_TMP"
              if [ -n "$RACKET_PID" ]; then
                kill "$RACKET_PID" 2>/dev/null
                wait "$RACKET_PID" 2>/dev/null
              fi
              racket "$OUT" "$@" &
              RACKET_PID=$!
              echo "[tesl watch] Server running (pid $RACKET_PID)"
            else
              grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
              rm -f "$STDERR_TMP"
              echo "[tesl watch] Compile error — previous server kept running" >&2
            fi
          fi
          sleep 0.3
        done
        ;;
      generate)
        SUBCMD="''${1:-help}"
        shift || true
        case "$SUBCMD" in
          ir)
            FILE="''${1:?Usage: tesl generate ir <file.tesl>}"
            _tesl_require_compiler
            "$TESL_OCAML_COMPILER" --ir "$FILE"
            ;;
          ts)
            FILE="''${1:?Usage: tesl generate ts <file.tesl>}"
            shift || true
            _tesl_require_compiler
            if [ "''${1:-}" = "--out" ]; then
              OUT="''${2:?--out requires a filename}"
              "$TESL_OCAML_COMPILER" --generate-ts "$FILE" --out "$OUT"
            else
              "$TESL_OCAML_COMPILER" --generate-ts "$FILE"
            fi
            ;;
          elm)
            FILE="''${1:?Usage: tesl generate elm <file.tesl>}"
            shift || true
            _tesl_require_compiler
            if [ "''${1:-}" = "--out" ]; then
              OUT="''${2:?--out requires a filename}"
              "$TESL_OCAML_COMPILER" --generate-elm "$FILE" --out "$OUT"
            else
              "$TESL_OCAML_COMPILER" --generate-elm "$FILE"
            fi
            ;;
          help|*)
            echo "Usage: tesl generate <ir|ts|elm> <file.tesl> [--out <file>]"
            ;;
        esac
        ;;
      validate)
        [ $# -gt 0 ] || { echo "Usage: tesl validate <file.tesl> [more.tesl ...]" >&2; exit 1; }
        _tesl_require_compiler
        "$TESL_OCAML_COMPILER" --check "$@" && "$TESL_OCAML_COMPILER" --lint "$@" && "$TESL_OCAML_COMPILER" --fmt-check "$@"
        ;;
      help|--help|-h)
        if [ -n "$1" ]; then
          _tesl_require_compiler
          "$TESL_OCAML_COMPILER" --help "$@"
        else
          cat <<'EOF'
Tesl language CLI

Usage:
  tesl compile             <file.tesl>                    Compile .tesl → .rkt
  tesl check               <file.tesl> [more.tesl ...]   Type-check without output
  tesl lint                <file.tesl> [more.tesl ...]   Run the opinionated linter
  tesl fmt                 <file.tesl> [more.tesl ...]   Format in-place
  tesl fmt-check           <file.tesl> [more.tesl ...]   Check formatting without modifying
  tesl validate            <file.tesl> [more.tesl ...]   Run check + lint + fmt-check
  tesl run                 <file.tesl> [args…]           Compile then execute
  tesl test                <file.tesl> [more.tesl ...]   Compile and run tests
  tesl watch               <file.tesl> [args…]           Watch, recompile, and restart on changes
  tesl generate ir         <file.tesl>                   Emit API IR as JSON
  tesl generate ts         <file.tesl> [--out <file>]    Emit TypeScript + Zod client
  tesl generate elm        <file.tesl> [--out <file>]    Emit Elm HTTP client

Documentation:
  tesl help manual                                             Show full documentation index
  tesl help manual <section>                                   Show specific documentation section
  tesl help manual full                                        Show ALL documentation (for LLMs)
  tesl help examples                                           List all examples
  tesl help search <query>                                     Search documentation

Editor / Language Server (LSP) flags:
  tesl check-json          <file.tesl>                   Type-check, diagnostics as IR-2 JSON
  tesl local-bindings-json <file.tesl>                   Inferred local binding types as JSON
  tesl semantic-json       <file.tesl>                   Full module semantic snapshot as JSON
  tesl definition-json     <file.tesl> <line> <col>      Jump-to-definition location as JSON
  tesl occurrences-json    <file.tesl> <line> <col>      Same-file symbol occurrences as JSON
  tesl type-at-json        <file.tesl> <line> <col>      Inferred type at cursor as JSON
  tesl field-at-json       <file.tesl> <line> <col>      Record field info at cursor as JSON
  tesl completions-json    <file.tesl> [line] [col]      Context-aware completions as JSON

Verbose logging (set before running the compiled app):
  TESL_VERBOSE=1 racket your-api.rkt

Logs HTTP requests/responses, SQL queries, queue operations, and
pub/sub events to stderr. Zero overhead when TESL_VERBOSE is unset.
EOF
        fi
        ;;
      *)
        echo "unknown command: $CMD  (try: tesl help)" >&2
        exit 1
        ;;
    esac
  '';
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    racket
    curl
    jq
    postgresql
    tesl-cli
    ocamlPackages.ocaml
    ocamlPackages.dune_3
    ocamlPackages.findlib
    ocamlPackages.alcotest
  ];

  shellHook = ''
    export TESL_REPO_ROOT="${toString ./.}"
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"

    if [ -z "''${TESL_SKIP_AUTO_BUILD:-}" ] && [ ! -x "$TESL_OCAML_COMPILER" ]; then
      echo "[tesl] OCaml compiler not built; building compiler/bin/main.exe..."
      (cd "$TESL_REPO_ROOT/compiler" && dune build bin/main.exe) || \
        echo "[tesl] warning: automatic OCaml compiler build failed" >&2
    fi

    # Keep the tesl Racket package linked to this repo.
    # Skip entirely if the package is already linked to the correct path.
    if ! raco pkg show tesl 2>/dev/null | grep -qF "link $TESL_REPO_ROOT"; then
      if raco pkg show tesl 2>/dev/null | grep -Eq '^[[:space:]]*tesl([[:space:]]|$)'; then
        raco pkg update --auto --link "$TESL_REPO_ROOT" 2>/dev/null || true
      else
        raco pkg install --auto --link "$TESL_REPO_ROOT" 2>/dev/null || true
      fi
    fi

    export TESL_POSTGRES_HOST="127.0.0.1"
    export TESL_POSTGRES_PORT="55432"
    export TESL_POSTGRES_USER="tesl"
    export TESL_POSTGRES_PASSWORD=""
    unset  TESL_POSTGRES_DATABASE
    unset  TESL_POSTGRES_SOCKET

    bash "$TESL_REPO_ROOT/scripts/postgres-start.sh" 2>/dev/null || true

    _PGSU=""
    for _try in tesl "$(whoami)" postgres; do
      if psql -h 127.0.0.1 -p 55432 -U "$_try" -d postgres -c "SELECT 1" >/dev/null 2>&1; then
        _PGSU="$_try"
        break
      fi
    done
    if [ -n "$_PGSU" ] && [ "$_PGSU" != "tesl" ]; then
      psql -h 127.0.0.1 -p 55432 -U "$_PGSU" -d postgres \
        -c "CREATE ROLE tesl SUPERUSER LOGIN" >/dev/null 2>&1 || true
    fi
    unset _PGSU _try

    for _db in todo-api admin-task-api chat; do
      createdb -h 127.0.0.1 -p 55432 -U tesl "$_db" 2>/dev/null || true
    done
    unset _db

    echo "Tesl dev shell ready. Run 'tesl help' to get started."
    echo "[postgres] Shared cluster ready at 127.0.0.1:55432 (user: tesl)"
    echo "[postgres] Databases: todo-api  admin-task-api  chat"
    echo "[postgres] Run: TESL_POSTGRES_DATABASE=todo-api tesl watch example/todo-api.tesl"
  '';
}
