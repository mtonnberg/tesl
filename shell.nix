# Pin nixpkgs to the SAME revision the flake locks (flake.lock), so the dev shell
# (direnv `use nix`) and the flake-installed `tesl` share one Go/OCaml toolchain.
# Previously this used `import <nixpkgs>` (the ambient channel), which drifted from
# the flake, causing tool-version mismatches. We read the revision
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
    export TESL_REPO_ROOT="''${TESL_REPO_ROOT:-$PWD}"
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"
  '' + builtins.readFile ./nix/tesl-cli-body.sh);
  tesl-go-tool = name: pkgs.writeShellScriptBin name ''
    set -euo pipefail
    root="''${TESL_REPO_ROOT:-$PWD}"
    cd "$root/runtime/go"
    exec ${pkgs.go}/bin/go run "./cmd/${name}" "$@"
  '';
  tesl-dap = tesl-go-tool "tesl-dap";
  tesl-debug-attach = tesl-go-tool "tesl-debug-attach";
  tesl-debug-inspect = tesl-go-tool "tesl-debug-inspect";
  tesl-lsp = tesl-go-tool "tesl-lsp";
  tesl-mcp = tesl-go-tool "tesl-mcp";
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
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    curl
    jq
    nodejs
    postgresql
    go
    staticcheck
    gosec
    govulncheck
    golangci-lint
    nilaway
    tesl-cli
    tesl-dap
    tesl-debug-attach
    tesl-debug-inspect
    tesl-lsp
    tesl-mcp
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
    zap       # default Tesl DAST scanner
    nuclei    # complementary template-based scanner
  ];

  shellHook = ''
    _tesl_root="''${PWD}"
    while [ "$_tesl_root" != "/" ] && [ ! -f "$_tesl_root/flake.nix" ]; do
      _tesl_root="$(dirname "$_tesl_root")"
    done
    export TESL_REPO_ROOT="''${TESL_REPO_ROOT:-$_tesl_root}"
    unset _tesl_root
    export TESL_OCAML_COMPILER="$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe"
    export TESL_DEFAULT_BACKEND="''${TESL_DEFAULT_BACKEND:-go}"

    if [ -z "''${TESL_SKIP_AUTO_BUILD:-}" ] && [ ! -x "$TESL_OCAML_COMPILER" ]; then
      echo "[tesl] OCaml compiler not built; building compiler/bin/main.exe..."
      (cd "$TESL_REPO_ROOT/compiler" && dune build bin/main.exe) || \
        echo "[tesl] warning: automatic OCaml compiler build failed" >&2
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
