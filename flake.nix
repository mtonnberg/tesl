{
  description = "Tesl language toolchain — compiler, formatter, linter, and LSP";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Go is PINNED to a patch release nixpkgs has not packaged yet.
        #
        # `govulncheck` is a mandatory gate (ci.sh phase 2a), and go1.26.4 — what
        # nixpkgs-unstable carried — is subject to three advisories that are all in the
        # standard library and therefore unavoidable from Tesl's side: GO-2026-6218
        # (quadratic `net/url.resolvePath`), GO-2026-6090 (`crypto/tls`) and GO-2026-6089
        # (`net/http`).  All three are fixed in go1.26.6.
        #
        # Bumping the whole channel does NOT deliver it: nixpkgs-unstable was at go1.26.5 when
        # this was written, which still trips all three, while moving staticcheck,
        # golangci-lint and every other pinned tool underneath the gates for no gain.  So the
        # OVERLAY pins exactly the one thing the gate is about and leaves the rest of the
        # channel where it is.
        #
        # Remove this the moment nixpkgs carries go1.26.6 or newer — `nix flake update
        # nixpkgs` then gives the same result with no local patch to maintain.
        goOverlay = final: prev: {
          go = prev.go.overrideAttrs (old: rec {
            version = "1.26.6";
            src = final.fetchurl {
              url = "https://go.dev/dl/go${version}.src.tar.gz";
              sha256 = "1c9czy9wnbp9h89qkzsm0xrp9i57gvnb7nbssx419448qra1qwm0";
            };
          });
        };
        pkgs = import nixpkgs { inherit system; overlays = [ goOverlay ]; };
        staticcheck = pkgs.buildGoModule rec {
          pname = "staticcheck";
          version = "2026.1";
          src = pkgs.fetchFromGitHub {
            owner = "dominikh";
            repo = "go-tools";
            rev = version;
            hash = "sha256-cj/pHKwp7eGuOO1zhv5bFmuPHgsFytktLQmihhdYkfY=";
          };
          vendorHash = "sha256-Wu8+e0r0bkztLbxekbHktoKjg6c8q7ls5APSEdO8CKs=";
          subPackages = [ "cmd/staticcheck" ];
          meta.mainProgram = "staticcheck";
        };

        # ── OCaml compiler binary ─────────────────────────────────────────────
        # Builds compiler/_build/default/bin/main.exe via dune.
        # Dependencies: ocaml, dune_3, findlib (all stdlib — no opam packages).
        tesl-compiler = pkgs.stdenv.mkDerivation {
          pname   = "tesl-compiler";
          version = "0.3.1";

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
            description = "Tesl OCaml compiler — compiles .tesl → Go";
            mainProgram = "tesl-compiler";
          };
        };

        # ── Project templates ────────────────────────────────────────────────
        # Bundle templates/{minimal,api,docker} into the store so the INSTALLED
        # `tesl init` / `tesl build` can scaffold and stage Dockerfiles without
        # a live repo checkout.  The CLI body locates this via TESL_TEMPLATES_DIR
        # (baked into the preamble), with $TESL_REPO_ROOT/templates as the dev
        # fallback.
        tesl-templates = pkgs.stdenv.mkDerivation {
          pname   = "tesl-templates";
          version = "0.3.1";

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

        # ── Go editor/debug/MCP tools ─────────────────────────────────────────
        tesl-go-tools = pkgs.buildGoModule {
          pname = "tesl-go-tools";
          version = "0.3.1";
          src = ./.;
          modRoot = "runtime/go";
          vendorHash = "sha256-SMXMkfkj5ehtjri4CCWPMwOyLIGcaoSgBv8k4DVG86c=";
          subPackages = [
            "cmd/tesl-dap"
            "cmd/tesl-debug-attach"
            "cmd/tesl-debug-inspect"
            "cmd/tesl-lsp"
            "cmd/tesl-mcp"
          ];
          meta.description = "Tesl Go LSP, DAP, headless debugger, and MCP tools";
        };

        # DAST tools are part of the shipped workflow, not runtime downloads.
        dastTools = [ pkgs.nuclei ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.zap ];

        # ── GNU userland pinned into the wrappers' PATH ────────────────────────
        # #46: on macOS the BSD variants of these tools are what a fresh
        # `nix profile install` finds on PATH, and the CLI expects GNU semantics.
        # Prepending the store
        # paths here makes them real runtime dependencies of the installed
        # package — correctly GC-rooted, identical on Linux and macOS, zero user
        # action.  The CLI body is ALSO written to be BSD-clean (see the
        # portable-shims section there), so this is the belt to that suspenders:
        # neither layer alone has to be perfect.
        gnuUserland = pkgs.lib.makeBinPath [
          pkgs.coreutils   # mktemp, stat, readlink, realpath, dirname, cksum …
          pkgs.gnused
          pkgs.gnugrep
          pkgs.gawk
          pkgs.findutils
          pkgs.diffutils   # cmp
        ];

        # Go-only shipped profile.
        goRuntimePreamble = ''
           export TESL_VERSION="0.3.1"
          export TESL_OCAML_COMPILER="${tesl-compiler}/bin/tesl-compiler"
          export TESL_DEFAULT_BACKEND="''${TESL_DEFAULT_BACKEND:-go}"
          export TESL_TEMPLATES_DIR="${tesl-templates}/share/tesl-templates"
          export TESL_DEBUG_ATTACH_BIN="${tesl-go-tools}/bin/tesl-debug-attach"
          export TESL_DEBUG_INSPECT_BIN="${tesl-go-tools}/bin/tesl-debug-inspect"
          export TESL_GO="${pkgs.go}/bin/go"
          export TESL_ZAP="${pkgs.zap}/bin/zap"
          export TESL_NUCLEI="${pkgs.nuclei}/bin/nuclei"
          export PATH="${gnuUserland}:$PATH"
        '';

        # ── CLI body (shared between installed and dev wrappers) ──────────────
        # Everything after the preamble — the case statement and helpers.
        cliBody = builtins.readFile ./nix/tesl-cli-body.sh;

        tesl-go-cli = pkgs.writeShellScriptBin "tesl" (goRuntimePreamble + cliBody);
        
        # ── Dev tesl CLI ──────────────────────────────────────────────────────
        # Used inside devShells.default so developers run against their local
        # compiler/_build/  rather than the pinned store binary.
        tesl-cli-dev = pkgs.writeShellScriptBin "tesl" (''
           export TESL_REPO_ROOT="''${TESL_REPO_ROOT:-${toString ./.}}"
           export TESL_OCAML_COMPILER="''${TESL_OCAML_COMPILER:-$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe}"
           export TESL_DEFAULT_BACKEND="''${TESL_DEFAULT_BACKEND:-go}"
           export TESL_TEMPLATES_DIR="''${TESL_TEMPLATES_DIR:-$TESL_REPO_ROOT/templates}"
           export TESL_DEBUG_ATTACH_BIN="''${TESL_DEBUG_ATTACH_BIN:-${tesl-go-tools}/bin/tesl-debug-attach}"
           export TESL_DEBUG_INSPECT_BIN="''${TESL_DEBUG_INSPECT_BIN:-${tesl-go-tools}/bin/tesl-debug-inspect}"
           export TESL_GO="''${TESL_GO:-${pkgs.go}/bin/go}"
           export TESL_ZAP="''${TESL_ZAP:-${pkgs.zap}/bin/zap}"
           export TESL_NUCLEI="''${TESL_NUCLEI:-${pkgs.nuclei}/bin/nuclei}"
           export PATH="${gnuUserland}:$PATH"
        '' + cliBody);

        # ── tesl-lsp wrapper ──────────────────────────────────────────────────
         # Sets TESL_COMPILER for the Go LSP without needing TESL_REPO_ROOT. An
         # inherited TESL_COMPILER wins: the editor
        # extension points a repo checkout's LSP at that checkout's fresh
        # compiler/_build binary, and clobbering it here is what silently pinned
        # every diagnostic to the store compiler of whatever revision the user
        # last ran `nix profile install` on — new checks looked simply absent.
        tesl-lsp = pkgs.writeShellScriptBin "tesl-lsp" (''
          export TESL_OCAML_COMPILER="${tesl-compiler}/bin/tesl-compiler"
          export TESL_COMPILER="''${TESL_COMPILER:-$TESL_OCAML_COMPILER}"
          exec "${tesl-go-tools}/bin/tesl-lsp" "$@"
        '');

        # ── tesl-mcp wrapper ──────────────────────────────────────────────────
        # MCP stdio server exposing the Tesl agent API to AI agents (Claude Code,
        # etc.). Same compiler discovery as tesl-lsp — sets TESL_COMPILER, so no
        # TESL_REPO_ROOT / repo checkout is needed.
        tesl-mcp = pkgs.writeShellScriptBin "tesl-mcp" (''
          export TESL_OCAML_COMPILER="${tesl-compiler}/bin/tesl-compiler"
          export TESL_COMPILER="''${TESL_COMPILER:-$TESL_OCAML_COMPILER}"
          export TESL_DEBUG_ATTACH="${tesl-go-tools}/bin/tesl-debug-attach"
          export TESL_DEBUG_INSPECT_BIN="${tesl-go-tools}/bin/tesl-debug-inspect"
          exec "${tesl-go-tools}/bin/tesl-mcp" "$@"
        '');

        tesl-debug-tools = pkgs.symlinkJoin {
          name = "tesl-debug-tools";
          paths = [ tesl-go-tools ];
        };

        # ── Combined default: CLI + LSP + MCP in one profile install ───────────
        tesl-full = pkgs.symlinkJoin {
          name = "tesl";
          paths = [ tesl-go-cli tesl-compiler tesl-lsp tesl-mcp tesl-debug-tools ] ++ dastTools;
        };

      in {
        # ── Packages ──────────────────────────────────────────────────────────
          packages = {
           inherit tesl-compiler tesl-go-cli tesl-lsp tesl-mcp tesl-go-tools tesl-debug-tools tesl-full staticcheck;
          default = tesl-full;
          # Reusable PostgreSQL so the managed-PG lifecycle (`tesl db`) can source
          # initdb / pg_ctl / createdb via nix without entering a dev shell.
          postgresql = pkgs.postgresql;
        };

        # ── Apps (for `nix run github:mtonnberg/tesl`) ────────────────────────
        apps = {
          default  = { type = "app"; program = "${tesl-go-cli}/bin/tesl"; };
          tesl-lsp = { type = "app"; program = "${tesl-lsp}/bin/tesl-lsp"; };
          tesl-mcp = { type = "app"; program = "${tesl-mcp}/bin/tesl-mcp"; };
        };

        # ── Dev shell ─────────────────────────────────────────────────────────
        # `nix develop` gives the same workflow as the legacy `nix-shell`,
        # while the shellHook retains compiler auto-build logic.
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            tesl-cli-dev
            tesl-go-tools
            curl
            jq
            nodejs
            postgresql
            pgbouncer
            tlaplus
            go
            staticcheck
            gosec
            govulncheck
            golangci-lint
            nilaway
            ocamlPackages.ocaml
            ocamlPackages.dune_3
            ocamlPackages.findlib
            ocamlPackages.alcotest
            # playground/build.sh: compiles the pure-OCaml compiler library to
            # JavaScript for the browser playground.  Opt-in — the jsoo stanza is
            # gated on the release profile (compiler/playground/dune), so nothing
            # in the normal dev/CI path needs these.
            ocamlPackages.js_of_ocaml
            ocamlPackages.js_of_ocaml-compiler
            # Integration test mock servers
            mailhog   # SMTP mock for email integration tests (MailHog binary in PATH as MailHog)
            python3   # HTTP mock server for httpclient integration tests
          ] ++ dastTools;

          shellHook = ''
            # `${toString ./.}` is an immutable Nix-store source during `nix develop`,
            # so compiler auto-builds must resolve the live checkout from the shell cwd.
            _tesl_root="''${PWD}"
            while [ "$_tesl_root" != "/" ] && [ ! -f "$_tesl_root/flake.nix" ]; do
              _tesl_root="$(dirname "$_tesl_root")"
            done
            export TESL_REPO_ROOT="''${TESL_REPO_ROOT:-$_tesl_root}"
            unset _tesl_root
            export TESL_OCAML_COMPILER="''${TESL_OCAML_COMPILER:-$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe}"

            if [ -z "''${TESL_SKIP_AUTO_BUILD:-}" ] && [ ! -x "$TESL_OCAML_COMPILER" ]; then
              echo "[tesl] OCaml compiler not built; building compiler/bin/main.exe..."
              (cd "$TESL_REPO_ROOT/compiler" && dune build bin/main.exe) || \
                echo "[tesl] warning: automatic OCaml compiler build failed" >&2
            fi

            # CI: skip the convenience PostgreSQL. Its PGDATA would sit in the
            # read-only Nix store, and exporting TESL_POSTGRES_* hijacks ci.sh
            # into reusing that fragile cluster instead of managing its own temp
            # cluster. Interactive dev shells (CI unset) keep it.
            if [ -z "''${CI:-}" ]; then
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
            fi
          '';
        };
      }
    );
}
