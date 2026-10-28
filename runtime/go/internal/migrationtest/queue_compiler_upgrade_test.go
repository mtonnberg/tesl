package migrationtest

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// INV-ABI, INV-DECODER, INV-HISTORY, INV-QUEUE-FLOOR, INV-REPAIR-HISTORY;
// TR-ENQUEUE, TR-COMPLETE, TR-CONTRACT.
// Actual compiler artifacts, checked frozen source and public commands. The
// Python runner owns a private PostgreSQL cluster and never patches metadata.
func TestCompiledQueueCompilerUpgradeRetainsPayloads(t *testing.T) {
	if os.Getenv("TESL_MIGRATION_TEST_DSN") == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("mandatory compiler-upgrade queue test requires PostgreSQL")
		}
		t.Skip("run scripts/run-migration-tests.sh")
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		t.Fatal("compiler variant inputs require TESL_REPO_ROOT")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	a, b, c := buildMigrationCompilerVariants(t, ctx, root)
	output := filepath.Join(t.TempDir(), "queue-compiler-upgrade")
	cmd := exec.CommandContext(ctx, "python3", filepath.Join(root, "example/queue-three-upgrades/run.py"),
		"--output", output, "--compiler", a, "--upgrade-compiler", b, "--incompatible-compiler", c)
	data, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cross-compiler public queue rollout: %v\n%s", err, data)
	}
	if !strings.Contains(string(data), "PASS: three ordinary non-additive queue upgrades") {
		t.Fatalf("runner omitted acceptance result: %s", data)
	}
	read := func(release string) struct{ ABI, Compatibility string } {
		t.Helper()
		contents, err := os.ReadFile(filepath.Join(output, release, "go", "queue-history.json"))
		if err != nil {
			t.Fatal(err)
		}
		var header struct {
			ABI           string `json:"compilerAbi"`
			Compatibility string `json:"storedValueCompatibility"`
		}
		if err := json.Unmarshal(contents, &header); err != nil {
			t.Fatal(err)
		}
		return struct{ ABI, Compatibility string }{header.ABI, header.Compatibility}
	}
	first, successor, incompatible := read("v1"), read("v2"), read("v1-incompatible")
	if first.ABI == successor.ABI || first.Compatibility != successor.Compatibility || first.Compatibility == incompatible.Compatibility {
		t.Fatal("compiler A/B/C identities did not test the intended compatibility boundary", first, successor, incompatible)
	}
}
