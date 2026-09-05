let
  # Package stubs let schema/propagation tests run without a Nix daemon or fetch.
  pinnedHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  package = version: { inherit version; src = { urls = [ "https://example.invalid/source.tar.gz" ]; outputHash = pinnedHash; }; };
  pkgs = {
    go = package "1.2.3";
    postgresql = (package "17.1") // { src = (package "17.1").src // { outputHashMode = "recursive"; stripRoot = true; }; };
    meson = package "1.10.2";
    ninja = package "1.13.2";
    perl = (package "5.42.3") // { src = (package "5.42.3").src // { urls = [ "mirror://cpan/src/perl.tar.gz" ]; }; };
    flex = (package "2.6.4") // { src = (package "2.6.4").src // { outputHash = "15g9bv236nzi665p9ggqjlfn4dwck5835vf0bbw2cz7h5c1swyp8"; }; };
    bison = (package "3.8.2") // { src = (package "3.8.2").src // { urls = [ "mirror://gnu/bison/bison.tar.gz" ]; }; };
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
    source-pins = plan.sources.go.hash == pinnedHash && plan.sources.go.version == "1.2.3";
    source-urls = plan.sources.go.urls == pkgs.go.src.urls;
    windows-build-tools = builtins.attrNames plan.windowsBuildTools == [ "bison" "flex" "meson" "ninja" "perl" ]
      && plan.windowsBuildTools.meson.version == pkgs.meson.version
      && plan.windowsBuildTools.perl.hash == pkgs.perl.src.outputHash;
    windows-compiler-no-compression = plan.windowsOcamlCompiler == "ocaml-variants.5.4.1+options,ocaml-option-no-compression";
    native-download-urls = plan.windowsBuildTools.perl.urls == [ "https://www.cpan.org/src/perl.tar.gz" ]
      && plan.windowsBuildTools.bison.urls == [ "https://ftp.gnu.org/gnu/bison/bison.tar.gz" ];
    native-source-hash-format = plan.windowsBuildTools.flex.hash == "sha256-6HquAyvwfCb4WsDtMlCZjDdiHZX4vXSLMfFbM8Re6ZU=";
    source-hash-mode = plan.sources.go.hashMode == "flat" && !plan.sources.go.stripRoot;
    recursive-source-hash = plan.sources.postgresql.hashMode == "recursive" && plan.sources.postgresql.stripRoot;
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
    windows-setup = plan.payloads.windows-amd64.installerName == "tesl-${version}-setup-windows-amd64.exe";
    windows-signing-optional = plan.releasePolicy.windowsSigning == "optional";
    macos-signing-optional = plan.releasePolicy.macOSSigning == "optional"
      && plan.releasePolicy.macOSDistribution == "ad-hoc-portable-archive"
      && plan.releasePolicy.macOSRecommendedInstall == "nix";
    windows-compiler-inputs = builtins.attrNames plan.windowsCompilerSources == [ "flexdll" "winpthreads" ]
      && plan.windowsCompilerSources.flexdll.version == "0.44"
      && plan.windowsCompilerSources.winpthreads.hashMode == "flat";
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
