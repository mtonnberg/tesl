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

        # ── Project templates ────────────────────────────────────────────────
        # Bundle templates/{minimal,api,docker} into the store so the INSTALLED
        # `tesl init` / `tesl build` can scaffold and stage Dockerfiles without
        # a live repo checkout.  The CLI body locates this via TESL_TEMPLATES_DIR
        # (baked into the preamble), with $TESL_REPO_ROOT/templates as the dev
        # fallback.
        tesl-templates = pkgs.stdenv.mkDerivation {
          pname   = "tesl-templates";
          version = "0.1.0";

          src = pkgs.lib.cleanSourceWith {
            src    = ./templates;
            filter = path: _type:
              !(pkgs.lib.hasInfix "/compiled/" (toString path));
          };

          dontBuild    = true;
          installPhase = ''
            mkdir -p $out/share/tesl-templates
            cp -r ./. $out/share/tesl-templates/
          '';

          meta.description = "Tesl project templates (minimal, api, docker)";
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

          # Assets baked into the store so the installed binary works with NO
          # repo checkout.  `tesl init`/`tesl build` read templates from here and
          # `tesl build` stages the runtime collections from the tesl-racket
          # derivation.  A live $TESL_REPO_ROOT (dev) takes precedence in the body.
          export TESL_TEMPLATES_DIR="${tesl-templates}/share/tesl-templates"
          export TESL_COLLECTIONS_DIR="${tesl-racket}/share/tesl-collections/tesl"

          export PATH="${pkgs.racket}/bin:$PATH"
        '';

        # ── CLI body (shared between installed and dev wrappers) ──────────────
        # Everything after the preamble — the case statement and helpers.
        cliBody = builtins.readFile ./nix/tesl-cli-body.sh;

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
          # Reusable PostgreSQL so the managed-PG lifecycle (`tesl db`) can source
          # initdb / pg_ctl / createdb via nix without entering a dev shell.
          postgresql = pkgs.postgresql;
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
