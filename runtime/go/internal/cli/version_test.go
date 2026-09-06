package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/toolchain"
)

func TestVersionUsesSelectedInstallationIdentity(t *testing.T) {
	for _, mode := range []string{"development", "nix", "manifest", "broken-manifest", "missing-explicit-manifest"} {
		for _, verb := range []string{"version", "--version", "-v"} {
			t.Run(mode+"/"+verb, func(t *testing.T) {
				app, calls := fakeApp(t)
				getenv := app.Resolver.Getenv
				root := app.Directory
				want := "dev"
				app.Resolver.Getenv = func(key string) string {
					if key == "TESL_VERSION" && mode != "development" {
						return "0.3.1-nix"
					}
					if key == "TESL_TOOLCHAIN_ROOT" && mode != "development" && mode != "nix" {
						return root
					}
					return getenv(key)
				}
				if mode == "nix" {
					want = "0.3.1-nix"
				}
				switch mode {
				case "manifest":
					manifest := toolchain.Manifest{Version: 1, ToolchainVersion: "0.4.0-selected", SourceRevision: strings.Repeat("a", 40), Components: map[string]toolchain.Component{"compiler": {Path: "bin/compiler", Version: "0.4.0-selected"}}}
					data, err := json.Marshal(manifest)
					if err != nil {
						t.Fatal(err)
					}
					writeProjectFile(t, root, "share/tesl/toolchain.json", string(data))
					want = manifest.ToolchainVersion
				case "broken-manifest":
					writeProjectFile(t, root, "share/tesl/toolchain.json", "{bad manifest")
				}
				err := app.Run(context.Background(), []string{verb})
				output := app.Stdout.(*bytes.Buffer).String()
				if strings.Contains(mode, "manifest") && mode != "manifest" {
					if err == nil || output != "" {
						t.Fatalf("invalid selected installation reported a version: %q, %v", output, err)
					}
				} else {
					compiler, pathErr := filepath.Abs(app.Resolver.Getenv("TESL_COMPILER"))
					if pathErr != nil {
						t.Fatal(pathErr)
					}
					if err != nil || output != "tesl "+want+"\ncompiler: "+compiler+"\n" {
						t.Fatalf("version output %q: %v", output, err)
					}
					if got := app.Resolver.Doctor().ToolchainVersion; got != want {
						t.Fatalf("doctor identity %q disagrees with version %q", got, want)
					}
				}
				if len(*calls) != 0 {
					t.Fatal("version reporting executed a tool")
				}
			})
		}
	}
}

func TestVersionWithoutCompiler(t *testing.T) {
	app, _ := fakeApp(t)
	app.Resolver.Getenv = func(string) string { return "" }
	app.Resolver.LookPath = func(string) (string, error) { return "", os.ErrNotExist }
	if err := app.Run(context.Background(), []string{"version"}); err != nil {
		t.Fatal(err)
	}
	if got := app.Stdout.(*bytes.Buffer).String(); got != "tesl dev\n" {
		t.Fatal(got)
	}
}
