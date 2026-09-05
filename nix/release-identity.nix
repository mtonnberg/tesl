# Pure release identity: no wall clock, runner number, Git tag lookup, or network.
# Retrying the same inputs must produce the same names on every native runner.
{ baseVersion, revision ? "worktree", sourceDateEpoch ? 0, releaseTag ? null }:
let
  validVersion = builtins.isString baseVersion
    && builtins.match "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" baseVersion != null;
  clean = builtins.isString revision && builtins.match "[0-9a-f]{40}" revision != null;
  validEpoch = builtins.isInt sourceDateEpoch && sourceDateEpoch >= 0
    && (!clean || sourceDateEpoch > 0);
  stable = releaseTag != null;
  version = if stable then baseVersion
    else if clean then "${baseVersion}-dev.${toString sourceDateEpoch}.g${revision}"
    else "${baseVersion}-dev.worktree";
in
if !validVersion then throw "Tesl release baseVersion must be canonical MAJOR.MINOR.PATCH"
else if !clean && revision != "worktree" then throw "Tesl release revision must be a full lowercase commit SHA or worktree"
else if !validEpoch then throw "Tesl release sourceDateEpoch must be a nonnegative integer, positive for a commit"
else if stable && (!clean || releaseTag != "v${baseVersion}") then
  throw "Tesl stable release tag must match v<baseVersion> on a clean commit"
else {
  inherit version baseVersion;
  channel = if stable then "stable" else if clean then "continuous" else "development";
  tag = if clean then "v${version}" else null;
  artifactPrefix = "tesl-${version}";
  # This describes source identity only. Passing all distribution gates and an
  # authorized release ref are still required before anything can be published.
  publishableSource = clean;
}
