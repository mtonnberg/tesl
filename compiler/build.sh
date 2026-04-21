#!/bin/bash
# Build script for Tesl OCaml compiler
# Requires: OCaml 5.4.1, dune 3.21, menhir via nix
# Install toolchain: nix profile install nixpkgs#ocaml nixpkgs#ocamlPackages.dune_3 nixpkgs#ocamlPackages.menhir nixpkgs#ocamlPackages.sedlex nixpkgs#ocamlPackages.alcotest nixpkgs#ocamlPackages.yojson

export OCAMLPATH=~/.nix-profile/lib/ocaml/5.4.1/site-lib
exec dune "$@"
