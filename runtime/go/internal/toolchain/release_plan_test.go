package toolchain

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The native matrix supplies the actual Nix export. This catches drift between
// the release generator's schema/path layout and every frontend's Go resolver.
func TestGeneratedReleaseManifests(t *testing.T) {
	path := os.Getenv("TESL_RELEASE_PLAN")
	if path == "" {
		t.Skip("set TESL_RELEASE_PLAN to the Nix release-plan JSON")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var plan struct {
		ToolchainVersion string
		SourceRevision   string
		Candidates       []struct{ Target string }
		Payloads         map[string]struct{ Manifest json.RawMessage }
	}
	if err := json.Unmarshal(data, &plan); err != nil {
		t.Fatal(err)
	}
	if len(plan.Candidates) == 0 || len(plan.Payloads) != len(plan.Candidates) {
		t.Fatal("missing candidate payload metadata")
	}
	for _, candidate := range plan.Candidates {
		t.Run(candidate.Target, func(t *testing.T) {
			r, _, root := fixture(t)
			r.GOOS = strings.Split(candidate.Target, "-")[0]
			writeFixture(t, root, "share/tesl/toolchain.json", string(plan.Payloads[candidate.Target].Manifest), 0644)
			manifest, _, err := r.Load()
			if err != nil {
				t.Fatalf("generated manifest is incompatible: %v", err)
			}
			if manifest.ToolchainVersion != plan.ToolchainVersion || manifest.SourceRevision != plan.SourceRevision || manifest.Target != candidate.Target {
				t.Fatalf("manifest identity differs from release plan: %+v", manifest)
			}
			for name, component := range manifest.Components {
				path := filepath.Join(root, filepath.FromSlash(component.Path))
				if directoryComponent(name) {
					if err := os.MkdirAll(path, 0755); err != nil {
						t.Fatal(err)
					}
				} else {
					writeFixture(t, root, component.Path, "native component fixture", 0755)
				}
				if resolved, err := r.Resolve(name); err != nil || resolved != path {
					t.Fatalf("generated %s component does not resolve: %q %v", name, resolved, err)
				}
			}
			if report := r.Doctor(); !report.OK || report.ToolchainVersion != plan.ToolchainVersion || report.SourceRevision != plan.SourceRevision {
				t.Fatalf("complete generated installation failed doctor: %+v", report)
			}
		})
	}
}
