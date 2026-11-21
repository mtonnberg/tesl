package teslrt

import (
	"os"
	"testing"
)

// shortSocketDir is a fresh directory for a test's unix socket. A socket path is limited to
// ~108 bytes (sockaddr_un), and t.TempDir() embeds the test name under $TMPDIR — inside a nix
// build sandbox that is already long, so binding failed with `bind: invalid argument`. A short
// /tmp prefix keeps the path well inside the limit wherever /tmp is writable.
func shortSocketDir(t *testing.T) string {
	t.Helper()
	base := ""
	if info, err := os.Stat("/tmp"); err == nil && info.IsDir() {
		base = "/tmp"
	}
	dir, err := os.MkdirTemp(base, "tesl-sock-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}
