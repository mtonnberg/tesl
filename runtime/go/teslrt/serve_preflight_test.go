package teslrt

import (
	"strings"
	"testing"
)

// `publicOrigin fromEnv "VAR"` and `sessionPreviousKey "VAR"` are read when needed, and a
// server refuses to start — naming the variable — when one is unset.
func TestBootPreflightNamesMissingEnvironment(t *testing.T) {
	SetPublicOriginEnv("TESL_TEST_PREFLIGHT_ORIGIN")
	defer SetPublicOriginEnv("")
	t.Setenv("TESL_TEST_PREFLIGHT_ORIGIN", "")
	err := preflightBootConfiguration(Server{})
	if err == nil || !strings.Contains(err.Error(), "TESL_TEST_PREFLIGHT_ORIGIN") {
		t.Fatalf("preflight = %v", err)
	}
	t.Setenv("TESL_TEST_PREFLIGHT_ORIGIN", "https://app.example.com")
	if got := PublicOrigin(); got != "https://app.example.com" {
		t.Fatalf("PublicOrigin() = %q", got)
	}
	SetPreviousSessionKeyEnv("TESL_TEST_PREFLIGHT_PREVIOUS")
	defer SetPreviousSessionKeyEnv("")
	if err := preflightBootConfiguration(Server{}); err == nil || !strings.Contains(err.Error(), "TESL_TEST_PREFLIGHT_PREVIOUS") {
		t.Fatalf("missing previous key must be refused, got %v", err)
	}
	t.Setenv("TESL_TEST_PREFLIGHT_PREVIOUS", "old-key")
	if err := preflightBootConfiguration(Server{}); err != nil {
		t.Fatal(err)
	}
	if keys := sessionKeys(Secret{Value: MakeSecret("new-key")}); len(keys) != 2 || keys[1] != "old-key" {
		t.Fatalf("sessionKeys = %v", keys)
	}
}
