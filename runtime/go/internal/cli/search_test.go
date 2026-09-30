package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestBuiltinSearchThroughNativeCLI(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	compiler := filepath.Join(filepath.Dir(file), "../../../../compiler/_build/default/bin/main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("built compiler unavailable")
	}
	app := New()
	app.Directory = t.TempDir() // Discovery does not require a project or source file.
	getenv := app.Resolver.Getenv
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		return getenv(key)
	}
	for _, args := range [][]string{
		{"search", "String -> Int"},
		{"search", "--json", "String -> Int"},
		{"--search-json", "String -> Int"},
		{"search", "--json", "String -> Int requires [time]"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			var output, errors bytes.Buffer
			app.Stdout, app.Stderr = &output, &errors
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			err := app.Run(ctx, args)
			unsupported := strings.Contains(args[len(args)-1], "requires")
			if (err != nil) != unsupported {
				t.Fatalf("search status: %v\n%s\n%s", err, &output, &errors)
			}
			if len(args) == 2 && args[0] == "search" {
				if !strings.Contains(output.String(), "fn String.length(") || !strings.Contains(output.String(), ") -> Int") {
					t.Fatalf("text search lost signatures: %s", &output)
				}
				return
			}
			var response struct {
				Version int               `json:"version"`
				Query   string            `json:"query"`
				Results []json.RawMessage `json:"results"`
				Error   *string           `json:"error"`
			}
			if err := json.Unmarshal(output.Bytes(), &response); err != nil {
				t.Fatalf("search did not return compiler JSON: %v\n%s", err, &output)
			}
			if response.Version != 1 || response.Query != args[len(args)-1] ||
				(response.Error != nil) != unsupported || (!unsupported && len(response.Results) == 0) {
				t.Fatalf("search contract changed: %s", &output)
			}
		})
	}
}
