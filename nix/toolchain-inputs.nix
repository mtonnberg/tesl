# Authoritative product/override pins. Native release metadata is generated from
# this file and the package sources selected by flake.lock.
{
  version = "0.3.1";
  go = {
    version = "1.26.6";
    sourceHash = "sha256-oHIcVMaIkBRI13rZs+x+p8R0cwdV/4kTgukuy5P/LLE=";
  };
  # OCaml's native MSVC port needs these build sources. Pins match the upstream
  # opam flexdll.0.44 and conf-winpthreads.20240209-1 source declarations.
  windowsCompilerSources = {
    flexdll = {
      version = "0.44";
      urls = [ "https://github.com/ocaml/flexdll/archive/refs/tags/0.44.tar.gz" ];
      hash = "b7c6a92286f1f3065324d51083dcb16eec436a4e6e3b8df7cf836b6d7a8b9491";
    };
    winpthreads = {
      version = "20240209-1";
      urls = [ "https://github.com/ocaml/winpthreads/archive/20240209-1.tar.gz" ];
      hash = "bd6f1ea4fbfa7d537ebaa12c0d4feb7146e6d7667511e3864b82a67c11f23025";
    };
  };
  windowsRuntimeLicense = {
    version = "2015-2022";
    urls = [ "https://visualstudio.microsoft.com/wp-content/uploads/2021/09/Visual-C-Runtime-2015-2022-License-1.docx" ];
    hash = "sha256-8ePVbOsq1oquBxG5EDdQCeZRrFUw+gdg8N6m6B5U+uE=";
    hashAlgorithm = "sha256";
    hashMode = "flat";
    stripRoot = false;
  };
}
