package toolchain

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuiltIdentityAndManifestPrecedence(t *testing.T) {
	for _, mode := range []string{"built", "nix", "nix-same-version", "manifest", "broken", "missing-explicit"} {
		t.Run(mode, func(t *testing.T) {
			r, env, root := fixture(t)
			r.builtVersion, r.builtRevision = "0.4.0-dev.123.g"+strings.Repeat("b", 40), strings.Repeat("b", 40)
			wantVersion, wantRevision := r.builtVersion, r.builtRevision
			switch mode {
			case "nix":
				env["TESL_VERSION"] = "0.5.0"
				wantVersion, wantRevision = "0.5.0", ""
			case "nix-same-version":
				env["TESL_VERSION"] = r.builtVersion
			case "manifest":
				manifestFixture(t, root, "bin/compiler")
				env["TESL_VERSION"] = "0.5.0"
				wantVersion, wantRevision = "0.3.1-test", strings.Repeat("a", 40)
			case "broken":
				writeFixture(t, root, "share/tesl/toolchain.json", "{bad manifest", 0600)
			case "missing-explicit":
				env["TESL_TOOLCHAIN_ROOT"] = root
			}
			version, err := r.Version()
			report := r.Doctor()
			if mode == "broken" || mode == "missing-explicit" {
				if err == nil || version != "" || report.OK || report.ToolchainVersion != "" || report.SourceRevision != "" {
					t.Fatalf("damaged installation used fallback identity: %q %v %+v", version, err, report)
				}
				return
			}
			if err != nil || version != wantVersion || report.ToolchainVersion != wantVersion || report.SourceRevision != wantRevision {
				t.Fatalf("identity: %q %v %+v; want %q at %q", version, err, report, wantVersion, wantRevision)
			}
		})
	}
}

func TestVersionRejectsUnreadableManifest(t *testing.T) {
	r, _, root := fixture(t)
	r.builtVersion = "0.4.0"
	// A directory is invalid on every host, including Windows and privileged CI.
	if err := os.MkdirAll(filepath.Join(root, "share/tesl/toolchain.json"), 0700); err != nil {
		t.Fatal(err)
	}
	if version, err := r.Version(); err == nil || version != "" {
		t.Fatalf("manifest error hidden by embedded version: %q %v", version, err)
	}
}

func TestDefaultCarriesLinkedIdentity(t *testing.T) {
	r := Default()
	if r.builtVersion != buildVersion || r.builtRevision != buildRevision {
		t.Fatalf("linked identity missing from default resolver: %+v", r)
	}
}
