{
  description = "Tesl language toolchain — compiler, formatter, linter, and LSP";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── OCaml compiler binary ─────────────────────────────────────────────
        # Builds compiler/_build/default/bin/main.exe via dune.
        # Dependencies: ocaml, dune_3, findlib (all stdlib — no opam packages).
        tesl-compiler = pkgs.stdenv.mkDerivation {
          pname   = "tesl-compiler";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = with pkgs.ocamlPackages; [ ocaml dune_3 findlib ];

          buildPhase   = "(cd compiler && dune build bin/main.exe)";
          installPhase = ''
            install -Dm755 compiler/_build/default/bin/main.exe $out/bin/tesl-compiler
            
            # Install documentation files
            mkdir -p $out/share/tesl/doc
            if [ -d "manual" ]; then
              cp -r manual/* $out/share/tesl/doc/ || true
            fi
            if [ -f "LANGUAGE-SPEC.md" ]; then
              cp LANGUAGE-SPEC.md $out/share/tesl/doc/ || true
            fi
            if [ -f "TESL.md" ]; then
              cp TESL.md $out/share/tesl/doc/ || true
            fi
            if [ -f "INSTALL.md" ]; then
              cp INSTALL.md $out/share/tesl/doc/ || true
            fi
            if [ -f "README.md" ]; then
              cp README.md $out/share/tesl/doc/ || true
            fi
            if [ -d "dev-docs" ]; then
              cp -r dev-docs/* $out/share/tesl/doc/dev-docs/ || true
            fi
            if [ -d "example" ]; then
              cp -r example $out/share/tesl/doc/ 2>/dev/null || true
            fi
          '';

          meta = {
            description = "Tesl OCaml compiler — compiles .tesl → Racket";
            mainProgram = "tesl-compiler";
          };
        };

        # ── Racket runtime collections ────────────────────────────────────────
        # Lays out three Racket collection trees that compiled Tesl programs
        # depend on, mirroring how `raco pkg install --link` exposes them:
        #
        #   $out/share/tesl-collections/tesl/dsl/   → (require tesl/dsl/…)
        #   $out/share/tesl-collections/tesl/tesl/  → (require tesl/tesl/…)
        #   $out/share/tesl-collections/tesl/lang/  → (require tesl/lang/…)
        #
        # Pre-compiling the .rkt sources here means the first `tesl run` is
        # instant.  The build uses `|| true` so a pre-compile failure (e.g. a
        # Racket version mismatch in CI) degrades gracefully — the wrapper's
        # PLTCOMPILEDROOTS user cache picks up the slack at runtime.
        tesl-racket = pkgs.stdenv.mkDerivation {
          pname   = "tesl-racket-collections";
          version = "0.1.0";

          src = pkgs.lib.cleanSourceWith {
            src    = ./.;
            filter = path: _type:
              let rel = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
              in  pkgs.lib.any (p: pkgs.lib.hasPrefix p rel)
                    [ "dsl/" "tesl/" "lang/" "dsl" "tesl" "lang" ]
                  # Drop in-repo .zo caches — we recompile inside the sandbox
                  # to guarantee they match the nixpkgs Racket version.
                  && !(pkgs.lib.hasInfix "/compiled/" (toString path));
          };

          nativeBuildInputs = [ pkgs.racket ];

          buildPhase = ''
            # Build the PLTCOLLECTS tree:
            #   build/collections/tesl/{dsl,tesl,lang}
            mkdir -p build/collections/tesl
            cp -r dsl  build/collections/tesl/dsl
            cp -r tesl build/collections/tesl/tesl
            cp -r lang build/collections/tesl/lang

            export HOME=$(mktemp -d)
            export PLTCOLLECTS="${pkgs.racket}/share/racket/collects:$(pwd)/build/collections"

            # Pre-compile all .rkt files; non-fatal (see comment above).
            find build/collections -name "*.rkt" -print0 \
              | xargs -0 -P"$(nproc)" raco make 2>&1 \
              || echo "warning: tesl-racket: raco pre-compilation failed — first run will be slower" >&2
          '';

          installPhase = ''
            mkdir -p $out/share/tesl-collections
            cp -r build/collections/tesl $out/share/tesl-collections/tesl
          '';

          meta.description = "Tesl Racket runtime collections (dsl, tesl, lang)";
        };

        # ── LSP Racket script ─────────────────────────────────────────────────
        # Bundle the LSP entry-point so tesl-lsp can reference it by absolute
        # store path without assuming a live repo checkout.
        tesl-lsp-script = pkgs.stdenv.mkDerivation {
          pname   = "tesl-lsp-script";
          version = "0.1.0";

          src = pkgs.lib.cleanSourceWith {
            src    = ./editor/tesl-lsp;
            filter = path: _type:
              !(pkgs.lib.hasInfix "/compiled/" (toString path));
          };

          dontBuild    = true;
          installPhase = ''
            install -Dm644 tesl-lsp.rkt $out/share/tesl-lsp/tesl-lsp.rkt
          '';
        };

        # ── Shared preamble injected at the top of all installed wrappers ─────
        # Sets the Racket collection path so the wrapper works with the
        # pre-compiled .zo files baked into the tesl-racket Nix derivation.
        #
        # PLTCOLLECTS order matters: ${pkgs.racket}/share/racket/collects MUST
        # come first.  In Racket 9.x (nixpkgs) the compiler-lib package is
        # registered as providing the raco/ collection but is missing
        # raco/main.rkt (moved to collects/).  When any PLTCOLLECTS is set the
        # package-link lookup shadows the built-in collects path, causing raco
        # to fail.  Prepending the collects dir ensures the path-based lookup
        # wins before the broken package link is reached.
        #
        # PLTCOMPILEDROOTS is intentionally NOT set.  On Racket 9.x (nixpkgs)
        # setting PLTCOMPILEDROOTS to any non-empty value triggers a slow
        # startup path (≥60 s on typical hardware).  The default compiled/
        # directory lookup (equivalent to "@") finds the pre-compiled .zo files
        # in the Nix store automatically and is fast (≈2 s).
        runtimePreamble = ''
          export TESL_OCAML_COMPILER="${tesl-compiler}/bin/tesl-compiler"
          export PLTCOLLECTS="${pkgs.racket}/share/racket/collects:${tesl-racket}/share/tesl-collections''${PLTCOLLECTS:+:$PLTCOLLECTS}"

          export PATH="${pkgs.racket}/bin:$PATH"
        '';

        # ── CLI body (shared between installed and dev wrappers) ──────────────
        # Everything after the preamble — the case statement and helpers.
        cliBody = ''

          _tesl_require_compiler() {
            if [ ! -x "$TESL_OCAML_COMPILER" ]; then
              echo "error: Tesl compiler not found at $TESL_OCAML_COMPILER" >&2
              exit 1
            fi
          }

          _tesl_compile_to_stdout() {
            local FILE="$1"
            _tesl_require_compiler
            "$TESL_OCAML_COMPILER" "$FILE"
          }
          
          _tesl_compile_deps() {
            local FILE="$1"
            _tesl_require_compiler
            "$TESL_OCAML_COMPILER" --deps "$FILE"
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
              
              # Get all dependencies (transitive imports) of the file
              DEPS="$(_tesl_compile_deps "$FILE" 2>/dev/null)"
              
              # Compile all dependencies first to .rkt files in their directories
              RET=0
              for DEP in $DEPS; do
                if [ -n "$DEP" ] && [ "$DEP" != "$FILE" ]; then
                  DEP_RKT="''${DEP%.tesl}.rkt"
                  if ! _tesl_compile_to_stdout "$DEP" > "$DEP_RKT" 2>&1; then
                    echo "error: Failed to compile dependency: $DEP" >&2
                    rm -f "$DEP_RKT"
                    RET=1
                  fi
                fi
              done
              if [ "$RET" -ne 0 ]; then
                rm -f "$OUT_TMP"; exit 1
              fi
              
              if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
                mv "$OUT_TMP" "$OUT"
                echo "compiled $FILE → $OUT"
              else
                RET=$?; rm -f "$OUT_TMP"; exit "$RET"
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
              OUT="''${FILE%.tesl}.rkt"
              RET=0
              
              # Get all dependencies (transitive imports) of the file
              DEPS="$(_tesl_compile_deps "$FILE" 2>/dev/null)"
              
              # Compile all dependencies first to .rkt files in their directories
              for DEP in $DEPS; do
                if [ -n "$DEP" ] && [ "$DEP" != "$FILE" ]; then
                  DEP_RKT="''${DEP%.tesl}.rkt"
                  if ! _tesl_compile_to_stdout "$DEP" > "$DEP_RKT" 2>&1; then
                    echo "error: Failed to compile dependency: $DEP" >&2
                    rm -f "$DEP_RKT"
                    RET=1
                  fi
                fi
              done
              
              if [ "$RET" -eq 0 ]; then
                OUT_TMP="$(mktemp --suffix=.rkt)"
                if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"; then
                  # Only update $OUT if content changed — preserves mtime for Racket's .zo cache
                  if ! cmp -s "$OUT_TMP" "$OUT"; then
                    mv "$OUT_TMP" "$OUT"
                  else
                    rm -f "$OUT_TMP"
                  fi
                  echo "[tesl] Starting..." >&2
                  if [ "''${TESL_VERBOSE:-0}" = "1" ]; then
                    racket "$OUT" "$@"; RET=$?
                  else
                    STDERR_TMP="$(mktemp)"
                    racket "$OUT" "$@" 2>"$STDERR_TMP"; RET=$?
                    grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
                    rm -f "$STDERR_TMP"
                  fi
                else
                  RET=$?; rm -f "$OUT_TMP"
                fi
              fi
              exit "$RET"
              ;;
            test)
              # Optional: --test-name "name" runs only the named test case.
              TEST_NAME=""
              if [ "''${1:-}" = "--test-name" ]; then
                TEST_NAME="''${2:?--test-name requires a test name argument}"
                shift 2
              fi
              [ $# -gt 0 ] || { echo "Usage: tesl test [--test-name <name>] <file.tesl> [more.tesl ...]" >&2; exit 1; }
              RET=0
              for FILE in "$@"; do
                OUT="''${FILE%.tesl}.rkt"
                OUT_TMP="$(mktemp --suffix=.rkt)"
                _tesl_require_compiler
                if [ -n "$TEST_NAME" ]; then
                  "$TESL_OCAML_COMPILER" --test-name "$TEST_NAME" "$FILE" > "$OUT_TMP"
                else
                  _tesl_compile_to_stdout "$FILE" > "$OUT_TMP"
                fi
                if [ $? -eq 0 ]; then
                  mv "$OUT_TMP" "$OUT"
                  if [ "''${TESL_VERBOSE:-0}" = "1" ]; then
                    raco test "$OUT" || RET=$?
                  else
                    STDERR_TMP="$(mktemp)"
                    raco test "$OUT" 2>"$STDERR_TMP"; STATUS=$?
                    grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
                    rm -f "$STDERR_TMP"
                    [ "$STATUS" -ne 0 ] && RET="$STATUS"
                  fi
                else
                  rm -f "$OUT_TMP"; RET=1
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

              _tesl_dep_snapshot() {
                local f="$1" deps
                if command -v "$TESL_OCAML_COMPILER" >/dev/null 2>&1; then
                  deps="$("$TESL_OCAML_COMPILER" --deps "$f" 2>/dev/null)"
                  deps="$f''${deps:+$'\n'$deps}"
                else
                  local dir; dir="$(dirname "$(realpath "$f")")"
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
                  OUT_TMP="$(mktemp --suffix=.rkt)"
                  if _tesl_compile_to_stdout "$FILE" > "$OUT_TMP" 2>"$STDERR_TMP"; then
                    grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
                    rm -f "$STDERR_TMP"
                    if ! cmp -s "$OUT_TMP" "$OUT"; then
                      mv "$OUT_TMP" "$OUT"
                    else
                      rm -f "$OUT_TMP"
                    fi
                    [ -n "$RACKET_PID" ] && { kill "$RACKET_PID" 2>/dev/null; wait "$RACKET_PID" 2>/dev/null; }
                    echo "[tesl watch] Starting..." >&2
                    racket "$OUT" "$@" &
                    RACKET_PID=$!
                    echo "[tesl watch] Server running (pid $RACKET_PID)"
                  else
                    grep -Ev "^raco (setup|make|link|test):" "$STDERR_TMP" >&2 || true
                    rm -f "$STDERR_TMP"
                    rm -f "$OUT_TMP"
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
                    "$TESL_OCAML_COMPILER" --generate-ts "$FILE" --out "''${2:?--out requires a filename}"
                  else
                    "$TESL_OCAML_COMPILER" --generate-ts "$FILE"
                  fi
                  ;;
                elm)
                  FILE="''${1:?Usage: tesl generate elm <file.tesl>}"
                  shift || true
                  _tesl_require_compiler
                  if [ "''${1:-}" = "--out" ]; then
                    "$TESL_OCAML_COMPILER" --generate-elm "$FILE" --out "''${2:?--out requires a filename}"
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
              "$TESL_OCAML_COMPILER" --check "$@" \
                && "$TESL_OCAML_COMPILER" --lint "$@" \
                && "$TESL_OCAML_COMPILER" --fmt-check "$@"
              ;;
            help|--help|-h)
              if [ -n "$1" ]; then
                # Pass help subcommands to the compiler
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
  tesl completions-json    <file.tesl> <line> <col>      Context-aware completions as JSON

Verbose logging:
  TESL_VERBOSE=1 tesl run your-api.tesl

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

        # ── Installed tesl CLI ────────────────────────────────────────────────
        # For `nix run`, `nix profile install`, home-manager, etc.
        # All paths are baked into the Nix store; no live repo checkout needed.
        tesl-cli = pkgs.writeShellScriptBin "tesl" (runtimePreamble + cliBody);
        
        # ── Dev tesl CLI ──────────────────────────────────────────────────────
        # Used inside devShells.default so developers run against their local
        # compiler/_build/  rather than the pinned store binary.
        tesl-cli-dev = pkgs.writeShellScriptBin "tesl" (''
          export TESL_REPO_ROOT="${toString ./.}"
          export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"
          export PLTCOLLECTS="${pkgs.racket}/share/racket/collects:${tesl-racket}/share/tesl-collections''${PLTCOLLECTS:+:$PLTCOLLECTS}"

          export PATH="${pkgs.racket}/bin:$PATH"
        '' + cliBody);

        # ── tesl-lsp wrapper ──────────────────────────────────────────────────
        # Sets TESL_COMPILER so the LSP Racket script finds the binary without
        # needing TESL_REPO_ROOT.
        tesl-lsp = pkgs.writeShellScriptBin "tesl-lsp" (runtimePreamble + ''
          export TESL_COMPILER="$TESL_OCAML_COMPILER"
          exec racket "${tesl-lsp-script}/share/tesl-lsp/tesl-lsp.rkt" "$@"
        '');

        # ── Combined default: CLI + LSP in one profile install ─────────────────
        tesl-full = pkgs.symlinkJoin {
          name = "tesl";
          paths = [ tesl-cli tesl-lsp ];
        };

      in {
        # ── Packages ──────────────────────────────────────────────────────────
        packages = {
          inherit tesl-compiler tesl-racket tesl-cli tesl-lsp tesl-full;
          default = tesl-full;
        };

        # ── Apps (for `nix run github:mtonnberg/tesl`) ────────────────────────
        apps = {
          default  = { type = "app"; program = "${tesl-cli}/bin/tesl"; };
          tesl-lsp = { type = "app"; program = "${tesl-lsp}/bin/tesl-lsp"; };
        };

        # ── Dev shell ─────────────────────────────────────────────────────────
        # `nix develop` gives the same workflow as the legacy `nix-shell`,
        # while the shellHook retains the auto-build + raco-link logic.
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            tesl-cli-dev
            racket
            curl
            jq
            postgresql
            ocamlPackages.ocaml
            ocamlPackages.dune_3
            ocamlPackages.findlib
            ocamlPackages.alcotest
            # Integration test mock servers
            mailhog   # SMTP mock for email integration tests (MailHog binary in PATH as MailHog)
            python3   # HTTP mock server for httpclient integration tests
          ];

          shellHook = ''
            export TESL_REPO_ROOT="${toString ./.}"
            export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"

            if [ -z "''${TESL_SKIP_AUTO_BUILD:-}" ] && [ ! -x "$TESL_OCAML_COMPILER" ]; then
              echo "[tesl] OCaml compiler not built; building compiler/bin/main.exe..."
              (cd "$TESL_REPO_ROOT/compiler" && dune build bin/main.exe) || \
                echo "[tesl] warning: automatic OCaml compiler build failed" >&2
            fi

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
                _PGSU="$_try"; break
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
        };
      }
    );
}
