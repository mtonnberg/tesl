let inputs = import ./toolchain-inputs.nix;
in final: prev: {
  # buildGoModule uses the versioned compiler; keep shipped tools on the pin too.
  go_1_26 = prev.go_1_26.overrideAttrs (_: {
    version = inputs.go.version;
    src = final.fetchurl {
      url = "https://go.dev/dl/go${inputs.go.version}.src.tar.gz";
      sha256 = inputs.go.sourceHash;
    };
  });
  go = final.go_1_26;
}
