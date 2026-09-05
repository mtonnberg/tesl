let
  # Package stubs let schema/propagation tests run without a Nix daemon or fetch.
  package = version: { inherit version; src = { urls = [ "https://example.invalid/source.tar.gz" ]; outputHash = "pinned-source-hash"; }; };
  pkgs = {
    go = package "1.2.3";
    postgresql = package "17.1";
    ocamlPackages = { ocaml = package "5.4.1"; dune_3 = package "3.21.1"; alcotest = package "1.9.1"; };
  };
  baseVersion = (import ../toolchain-inputs.nix).version;
  revision = "0123456789abcdef0123456789abcdef01234567";
  plan = import ../release-plan.nix { inherit pkgs revision; sourceDateEpoch = 1788602400; };
  stable = import ../release-plan.nix { inherit pkgs revision; sourceDateEpoch = 1788602400; releaseTag = "v${baseVersion}"; };
  version = "${baseVersion}-dev.1788602400.g${revision}";
  targets = [ "darwin-amd64" "darwin-arm64" "linux-amd64" "linux-arm64" "windows-amd64" ];
  all = predicate: builtins.all (target: predicate target plan.payloads.${target}) targets;
  tests = {
    schema = plan.version == 1;
    pinned-version = plan.release.baseVersion == baseVersion;
    exact-revision = plan.sourceRevision == revision;
    identity = plan.toolchainVersion == version && plan.release.version == version;
    complete-matrix = builtins.attrNames plan.payloads == targets;
    source-pins = plan.sources.go.hash == "pinned-source-hash" && plan.sources.go.version == "1.2.3";
    source-urls = plan.sources.go.urls == pkgs.go.src.urls;
    module-inputs = plan.moduleInputs == [ "runtime/go/go.mod" "runtime/go/go.sum" ];
    module-lock-hashes = plan.moduleInputHashes == {
      "runtime/go/go.mod" = builtins.hashString "sha256" (builtins.readFile ../../runtime/go/go.mod);
      "runtime/go/go.sum" = builtins.hashString "sha256" (builtins.readFile ../../runtime/go/go.sum);
    };
    manifest-identity = all (target: payload: payload.manifest.toolchain_version == version
      && payload.manifest.source_revision == revision && payload.manifest.target == target && payload.manifest.version == 1);
    component-inventory = all (_: payload: builtins.attrNames payload.manifest.components == [
      "compiler" "createdb" "doc" "go" "go-modules" "initdb" "licenses" "pg_ctl" "postgres" "psql"
      "stdlib" "templates" "tesl" "tesl-dap" "tesl-debug-attach" "tesl-debug-inspect" "tesl-lsp" "tesl-mcp"
    ]);
    component-versions = all (_: payload: payload.manifest.components.compiler.version == version
      && payload.manifest.components.go.version == "1.2.3" && payload.manifest.components.postgres.version == "17.1");
    unix-compiler-path = plan.payloads.linux-amd64.manifest.components.compiler.path == "libexec/tesl/tesl-compiler";
    unix-archive = plan.payloads.darwin-arm64.archiveName == "tesl-${version}-darwin-arm64.tar.gz";
    windows-archive = plan.payloads.windows-amd64.archiveName == "tesl-${version}-windows-amd64.zip";
    windows-executables = builtins.all (name:
      builtins.match ".*\\.exe" plan.payloads.windows-amd64.manifest.components.${name}.path != null
    ) (plan.commands ++ [ "compiler" "go" "postgres" "initdb" "pg_ctl" "createdb" "psql" ]);
    windows-directories = builtins.all (name:
      builtins.match ".*\\.exe" plan.payloads.windows-amd64.manifest.components.${name}.path == null
    ) [ "stdlib" "templates" "doc" "go-modules" "licenses" ];
    no-absolute-or-drive-paths = all (_: payload: builtins.all (item:
      builtins.substring 0 1 item.path != "/" && builtins.match ".*[:\\\\].*" item.path == null
    ) (builtins.attrValues payload.manifest.components));
    no-optional-default-components = all (_: payload: builtins.all (item: !(item.optional or false)) (builtins.attrValues payload.manifest.components));
    stable-version-propagates = stable.toolchainVersion == baseVersion
      && stable.payloads.windows-amd64.archiveName == "tesl-${baseVersion}-windows-amd64.zip"
      && stable.payloads.windows-amd64.manifest.components.tesl.version == baseVersion;
    complete-release-required = plan.releasePolicy.requireCompleteMatrix && plan.releasePolicy.preserveMainRuns;
    offline-gate-required = builtins.elem "offline-install" plan.releasePolicy.mandatoryChecks;
  };
  failures = builtins.filter (name: !tests.${name}) (builtins.attrNames tests);
in
if failures != [] then throw "Release plan tests failed: ${builtins.concatStringsSep ", " failures}"
else { passed = builtins.length (builtins.attrNames tests); }
