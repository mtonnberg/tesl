package cli

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectEnvironmentNeverControlsBuildTools(t *testing.T) {
	for _, mode := range []string{"test", "run"} {
		t.Run(mode, func(t *testing.T) {
			app, calls := fakeApp(t)
			app.Environment = append(app.Environment, "GOFLAGS=-p=2")
			writeProjectFile(t, app.Directory, "app.tesl", "module App exposing []\n")
			writeProjectFile(t, app.Directory, ".env", "GOFLAGS=-toolexec=attacker\nCC=attacker\nGOTOOLCHAIN=attacker\nAPP_SECRET=application-only\n")
			record := app.Execute
			app.Execute = func(ctx context.Context, inv Invocation) error {
				if err := record(ctx, inv); err != nil {
					return err
				}
				for i, arg := range inv.Args {
					if arg == "--out" {
						return os.MkdirAll(filepath.Join(inv.Args[i+1], "cmd", "app"), 0700)
					}
					if arg == "-o" && inv.Args[0] == "test" {
						return os.WriteFile(filepath.Join(inv.Args[i+1], "app.test"), nil, 0600)
					}
				}
				return nil
			}
			if err := app.Run(context.Background(), []string{mode, "app.tesl"}); err != nil {
				t.Fatal(err)
			}
			if len(*calls) != 3 {
				t.Fatalf("expected emit, compile, execute; got %d calls", len(*calls))
			}
			for _, inv := range (*calls)[:2] {
				for _, key := range []string{"CC", "APP_SECRET"} {
					if _, found := environmentValue(inv.Environment, key); found {
						t.Fatalf("%s reached build tools", key)
					}
				}
				if got, _ := environmentValue(inv.Environment, "GOFLAGS"); got != "-p=2" {
					t.Fatalf("operator GOFLAGS lost: %q", got)
				}
			}
			last := (*calls)[2]
			if got, _ := environmentValue(last.Environment, "APP_SECRET"); got != "application-only" {
				t.Fatal("application dotenv lost")
			}
			if mode == "test" && !strings.HasSuffix(last.Executable, ".test") {
				t.Fatal("tests must execute the compiled binary")
			}
		})
	}
}
