# Installation metadata for the payload builder. Paths are relative to the
# archive root and use '/' even for Windows; no Nix store paths are exported.
{ toolchainVersion, revision, target, commands, layout, sources }:
let
  suffix = if builtins.match "windows-.*" target != null then ".exe" else "";
  component = path: version: { inherit path version; };
  own = path: component path toolchainVersion;
  entries = names: make: builtins.listToAttrs (map (name: { inherit name; value = make name; }) names);
in {
  version = 1;
  toolchain_version = toolchainVersion;
  source_revision = revision;
  inherit target;
  components = (entries commands (name: own "${layout.frontendsDirectory}/${name}${suffix}"))
    // (entries [ "postgres" "initdb" "pg_ctl" "createdb" "psql" ]
      (name: component "${layout.postgresDirectory}/${name}${suffix}" sources.postgresql.version))
    // {
      compiler = own "${layout.compiler}${suffix}";
      go = component "${layout.go}${suffix}" sources.go.version;
      stdlib = own layout.stdlib;
      templates = own layout.templates;
      doc = own layout.doc;
      go-modules = own layout.moduleProxy;
      licenses = own layout.licenses;
    };
}
