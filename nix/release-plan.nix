{ pkgs, revision ? "worktree", sourceDateEpoch ? 0 }:
let
  inputs = import ./toolchain-inputs.nix;
  source = package: {
    version = package.version;
    urls = package.src.urls or [ package.src.url ];
    hash = package.src.outputHash;
    hashAlgorithm = "sha256";
  };
in {
  version = 1;
  toolchainVersion = inputs.version;
  sourceRevision = revision;
  inherit sourceDateEpoch;
  sources = {
    go = source pkgs.go;
    ocaml = source pkgs.ocamlPackages.ocaml;
    dune = source pkgs.ocamlPackages.dune_3;
    postgresql = source pkgs.postgresql;
  };
  moduleInputs = [ "runtime/go/go.mod" "runtime/go/go.sum" ];
  testPackages = { alcotest = pkgs.ocamlPackages.alcotest.version; };
  commands = [ "tesl" "tesl-lsp" "tesl-dap" "tesl-mcp" "tesl-debug-inspect" "tesl-debug-attach" ];
  layout = {
    manifest = "share/tesl/toolchain.json";
    compiler = "libexec/tesl/tesl-compiler";
    go = "libexec/tesl/go/bin/go";
    postgresDirectory = "libexec/tesl/postgresql/bin";
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
  releasePolicy = {
    channel = "continuous";
    immutableTagPrefix = "continuous-";
    identity = "full source commit SHA";
    requireCompleteMatrix = true;
    preserveMainRuns = true;
    mandatoryChecks = [ "authoritative-gate" "native-parity" "offline-install" "payload-audit" "provenance" ];
  };
}
