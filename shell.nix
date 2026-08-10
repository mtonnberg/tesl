# Pin nixpkgs to the SAME revision the flake locks (flake.lock), so the dev shell
# (direnv `use nix`) and the flake-installed `tesl` share one racket/ocaml toolchain.
# Previously this used `import <nixpkgs>` (the ambient channel), which drifted from
# the flake — the dev shell shipped racket 8.18 while `nix profile` shipped 9.2,
# causing a compiled-collection version mismatch in the debugger. We read the rev
# straight out of flake.lock and fetchTree it (no copy of the working tree, so a
# running .tesl-postgres socket can't break evaluation).
{ system ? builtins.currentSystem
, pkgs ? import
    (builtins.fetchTree
      (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked)
    { inherit system; } }:
let
  # The CLI verb body is the single source of truth shared with flake.nix
  # (nix/tesl-cli-body.sh).  Here we prepend the DEV preamble: it points the
  # compiler at the local dune build and exports TESL_REPO_ROOT so the shared
  # body resolves templates + runtime collections from the live checkout.
  tesl-cli = pkgs.writeShellScriptBin "tesl" (''
    #!/usr/bin/env bash
    export TESL_REPO_ROOT="${toString ./.}"
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"
  '' + builtins.readFile ./nix/tesl-cli-body.sh);
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    racket
    curl
    jq
    postgresql
    go
    gosec
    govulncheck
    golangci-lint
    nilaway
    libsodium   # dlopen()ed by tesl/crypto.rkt — see TESL_LIBSODIUM below
    tesl-cli
    ocamlPackages.ocaml
    ocamlPackages.dune_3
    ocamlPackages.findlib
    ocamlPackages.alcotest
    # playground/build.sh: compiles the pure-OCaml compiler library to
    # JavaScript for the browser playground.  ci.sh's playground-parity phase is
    # soundness-required (a SKIP counts as a FAIL), so the legacy shell needs
    # them for the same reason `nix develop` does.
    ocamlPackages.js_of_ocaml
    ocamlPackages.js_of_ocaml-compiler
    # Integration test mock servers
    mailhog   # SMTP mock for email integration tests (MailHog binary in PATH as MailHog)
    python3   # HTTP mock server for httpclient integration tests
  ];

  shellHook = ''
    export TESL_REPO_ROOT="${toString ./.}"
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"

    # Native library for Tesl.Crypto: `tesl/crypto.rkt` dlopen()s libsodium
    # through `ffi/unsafe` and prefers this absolute store path, falling back to
    # a plain `ffi-lib "libsodium"` lookup off the ambient loader path.  The
    # flake's installed wrappers export it (flake.nix `libsodiumPath`); this dev
    # shell did NOT, so `./ci.sh` inside it failed every crypto/JWT/session test
    # with "libsodium is required by Tesl.Crypto and could not be loaded" — the
    # dev shell could not run the gate the flake-installed CLI passes.  Same
    # `:-` idiom as the wrappers, so an explicit TESL_LIBSODIUM still wins, and
    # `extensions.sharedLibrary` covers .so (Linux) and .dylib (Darwin) alike.
    export TESL_LIBSODIUM="''${TESL_LIBSODIUM:-${pkgs.libsodium}/lib/libsodium${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}}"

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

    # Never let a Postgres connection attempt hang the shell hook. On WSL2
    # (mirrored networking) Windows can reserve our port in a Hyper-V excluded
    # port range: binds fail and connects black-hole instead of refusing, so
    # without a timeout every psql/createdb below blocks `cd` forever.
    export PGCONNECT_TIMEOUT=3

    export TESL_POSTGRES_HOST="127.0.0.1"
    export TESL_POSTGRES_PORT="55432"
    export TESL_POSTGRES_USER="tesl"
    export TESL_POSTGRES_PASSWORD=""
    unset  TESL_POSTGRES_DATABASE
    unset  TESL_POSTGRES_SOCKET

    _TESL_PG_OK=1
    bash "$TESL_REPO_ROOT/scripts/postgres-start.sh" || _TESL_PG_OK=0

    if [ "$_TESL_PG_OK" = 1 ]; then
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
    fi

    echo "Tesl dev shell ready. Run 'tesl help' to get started."
    if [ "$_TESL_PG_OK" = 1 ]; then
      echo "[postgres] Shared cluster ready at 127.0.0.1:55432 (user: tesl)"
      echo "[postgres] Databases: todo-api  admin-task-api  chat"
      echo "[postgres] Run: TESL_POSTGRES_DATABASE=todo-api tesl watch example/todo-api.tesl"
    else
      echo "[postgres] NOT running (start failed, see error above); retry with: bash scripts/postgres-start.sh"
    fi
    unset _TESL_PG_OK
  '';
}
