let inputs = import ./toolchain-inputs.nix;
in final: prev: {
  go = prev.go.overrideAttrs (_: {
    version = inputs.go.version;
    src = final.fetchurl {
      url = "https://go.dev/dl/go${inputs.go.version}.src.tar.gz";
      sha256 = inputs.go.sourceHash;
    };
  });
}
