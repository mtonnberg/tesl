let
  identity = import ../release-identity.nix;
  revision = "0123456789abcdef0123456789abcdef01234567";
  defaults = { baseVersion = "0.3.1"; inherit revision; sourceDateEpoch = 1788602400; };
  continuous = identity defaults;
  expected = "0.3.1-dev.1788602400.g${revision}";
  rejects = args: !(builtins.tryEval (builtins.deepSeq (identity (defaults // args)) true)).success;
  tests = {
    continuous-version = continuous.version == expected;
    continuous-channel = continuous.channel == "continuous";
    continuous-tag = continuous.tag == "v${expected}";
    artifact-name = continuous.artifactPrefix == "tesl-${expected}";
    publishable-commit = continuous.publishableSource;
    repeat-build = continuous == identity defaults;
    next-epoch = (identity (defaults // { sourceDateEpoch = 1788602401; })).version != expected;
    same-time-distinct-commit = (identity (defaults // {
      revision = "0123456789abcdef0123456789abcdef01234568";
    })).version != expected;
    base-bump = (identity (defaults // { baseVersion = "0.4.0"; })).baseVersion == "0.4.0";
    stable = identity (defaults // { releaseTag = "v0.3.1"; }) == {
      baseVersion = "0.3.1"; version = "0.3.1"; channel = "stable";
      tag = "v0.3.1"; artifactPrefix = "tesl-0.3.1"; publishableSource = true;
    };
    worktree = identity { baseVersion = "0.3.1"; } == {
      baseVersion = "0.3.1"; version = "0.3.1-dev.worktree"; channel = "development";
      tag = null; artifactPrefix = "tesl-0.3.1-dev.worktree"; publishableSource = false;
    };
    dirty-timestamp = (identity (defaults // { revision = "worktree"; })).channel == "development";
    stable-version-mismatch = rejects { releaseTag = "v0.4.0"; };
    stable-missing-v = rejects { releaseTag = "0.3.1"; };
    stable-prerelease = rejects { releaseTag = "v0.3.1-rc.1"; };
    stable-empty-tag = rejects { releaseTag = ""; };
    stable-wrong-type = rejects { releaseTag = 1; };
    stable-worktree = rejects { releaseTag = "v0.3.1"; revision = "worktree"; };
    missing-epoch = rejects { sourceDateEpoch = 0; };
    negative-epoch = rejects { sourceDateEpoch = -1; };
    string-epoch = rejects { sourceDateEpoch = "1788602400"; };
    float-epoch = rejects { sourceDateEpoch = 1788602400.5; };
    null-epoch = rejects { sourceDateEpoch = null; };
    abbreviated-revision = rejects { revision = "0123456789ab"; };
    uppercase-revision = rejects { revision = "0123456789ABCDEF0123456789ABCDEF01234567"; };
    dirty-revision = rejects { revision = "${revision}-dirty"; };
    unknown-revision = rejects { revision = "main"; };
    null-revision = rejects { revision = null; };
    version-prefix = rejects { baseVersion = "v0.3.1"; };
    version-short = rejects { baseVersion = "0.3"; };
    version-leading-zero = rejects { baseVersion = "0.03.1"; };
    version-prerelease = rejects { baseVersion = "0.3.1-dev.1"; };
    version-metadata = rejects { baseVersion = "0.3.1+build"; };
    version-newline = rejects { baseVersion = "0.3.1\n"; };
    version-path = rejects { baseVersion = "../0.3.1"; };
    null-version = rejects { baseVersion = null; };
    zero-version = (identity (defaults // { baseVersion = "0.0.0"; })).baseVersion == "0.0.0";
    multi-digit-version = (identity (defaults // { baseVersion = "12.34.567"; })).baseVersion == "12.34.567";
  };
  failures = builtins.filter (name: !tests.${name}) (builtins.attrNames tests);
in
if failures != [] then throw "Release identity tests failed: ${builtins.concatStringsSep ", " failures}"
else { passed = builtins.length (builtins.attrNames tests); }
