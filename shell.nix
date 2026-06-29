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
    tesl-cli
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
