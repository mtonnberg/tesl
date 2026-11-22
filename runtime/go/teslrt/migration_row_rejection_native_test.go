//go:build tesl_migration_test

package teslrt

import (
	"os"
	"strings"
	"testing"
	"time"
)

// pgForwardNativeWorkerReportsRejection runs the ongoing Worker until it
// reports a stored row its checked migration rejected, checks that it is still
// running (one rejected row does not stop it), then stops it and returns its
// output.
func pgForwardNativeWorkerReportsRejection(t *testing.T, f *pgControlTestFixture, root, version string) string {
	t.Helper()
	cmd := pgForwardNativeCommand(f, root, version, "worker")
	var output pgRowAppOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	stop := func() {
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case <-done:
		case <-time.After(20 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	}
	deadline := time.After(60 * time.Second)
	for !strings.Contains(output.String(), "was rejected by its checked migration") {
		select {
		case err := <-done:
			t.Fatalf("%s worker exited before reporting the rejected row: %v\n%s", version, err, output.String())
		case <-deadline:
			stop()
			t.Fatalf("%s worker did not report the rejected row\n%s", version, output.String())
		case <-time.After(50 * time.Millisecond):
		}
	}
	select {
	case err := <-done:
		t.Fatalf("%s worker exited on a rejected row: %v\n%s", version, err, output.String())
	default:
	}
	stop()
	return output.String()
}
