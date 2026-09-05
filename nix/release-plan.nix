{ pkgs, revision ? "worktree", sourceDateEpoch ? 0, releaseTag ? null }:
let
  inputs = import ./toolchain-inputs.nix;
  release = import ./release-identity.nix {
    baseVersion = inputs.version;
    inherit revision sourceDateEpoch releaseTag;
  };
  source = package: {
    version = package.version;
    urls = package.src.urls or [ package.src.url ];
    hash = package.src.outputHash;
    hashAlgorithm = "sha256";
  };
in rec {
  version = 1;
  toolchainVersion = release.version;
  sourceRevision = revision;
  inherit sourceDateEpoch release;
  sources = {
    go = source pkgs.go;
    ocaml = source pkgs.ocamlPackages.ocaml;
    dune = source pkgs.ocamlPackages.dune_3;
    postgresql = source pkgs.postgresql;
  };
  moduleInputs = [ "runtime/go/go.mod" "runtime/go/go.sum" ];
  moduleInputHashes = builtins.listToAttrs (map (path: {
    name = path;
    value = builtins.hashString "sha256" (builtins.readFile (../. + "/${path}"));
  }) moduleInputs);
  testPackages = { alcotest = pkgs.ocamlPackages.alcotest.version; };
  commands = [ "tesl" "tesl-lsp" "tesl-dap" "tesl-mcp" "tesl-debug-inspect" "tesl-debug-attach" ];
  layout = {
    manifest = "share/tesl/toolchain.json";
    frontendsDirectory = "bin";
    compiler = "libexec/tesl/tesl-compiler";
    go = "libexec/tesl/go/bin/go";
    postgresDirectory = "libexec/tesl/postgresql/bin";
    stdlib = "share/tesl/stdlib";
    templates = "share/tesl/templates";
    doc = "share/tesl/doc";
    moduleProxy = "share/tesl/go-modules";
    licenses = "share/tesl/licenses";
  };
  # These are build/verification candidates. They do not advertise support until
  # the clean-host, offline workflow and distribution gates have run on them.
  candidates = [
    { target = "linux-amd64"; runner = "ubuntu-22.04"; baseline = "glibc 2.35"; }
    { target = "linux-arm64"; runner = "ubuntu-22.04-arm"; baseline = "glibc 2.35"; }
    { target = "darwin-amd64"; runner = "macos-15-intel"; baseline = "macOS 13"; }
    { target = "darwin-arm64"; runner = "macos-15"; baseline = "macOS 13"; }
    { target = "windows-amd64"; runner = "windows-2025"; baseline = "Windows 11"; }
  ];
  payloads = builtins.listToAttrs (map (candidate: {
    name = candidate.target;
    value = {
      archiveName = "${release.artifactPrefix}-${candidate.target}"
        + (if builtins.match "windows-.*" candidate.target != null then ".zip" else ".tar.gz");
      manifest = import ./native-manifest.nix {
        inherit toolchainVersion revision commands layout sources;
        inherit (candidate) target;
      };
    };
  }) candidates);
  releasePolicy = {
    channel = release.channel;
    immutableTagPrefix = "v";
    identity = "semantic version with full source commit SHA for development builds";
    requireCompleteMatrix = true;
    preserveMainRuns = true;
    mandatoryChecks = [ "authoritative-gate" "native-parity" "offline-install" "payload-audit" "provenance" ];
  };
}
