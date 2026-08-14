package teslrt

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// The point of the type: an accidental print must not disclose the payload.
func TestSecretRedactsEverywhere(t *testing.T) {
	secret := MakeSecret("hunter2")
	for label, rendered := range map[string]string{
		"%v":     fmt.Sprintf("%v", secret),
		"%s":     fmt.Sprintf("%s", secret),
		"%#v":    fmt.Sprintf("%#v", secret),
		"Sprint": fmt.Sprint(secret),
		"inside a struct": fmt.Sprintf("%v", struct {
			Password SecretString
		}{Password: secret}),
	} {
		if strings.Contains(rendered, "hunter2") {
			t.Errorf("%s disclosed the payload: %s", label, rendered)
		}
		if !strings.Contains(rendered, SecretRedaction) {
			t.Errorf("%s did not redact: %s", label, rendered)
		}
	}
	encoded, err := json.Marshal(secret)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(encoded) != `"`+SecretRedaction+`"` {
		t.Errorf("JSON = %s", encoded)
	}
	// The redaction carries no length, prefix or hash — partial disclosure is what erodes
	// the guarantee.
	if SecretRedaction != "[redacted]" {
		t.Errorf("redaction text drifted from the Racket side: %q", SecretRedaction)
	}
	if secret.Reveal() != "hunter2" {
		t.Error("Reveal must hand back the plaintext")
	}
}

func TestSecretEqualIsConstantTime(t *testing.T) {
	if !SecretEqual(MakeSecret("abc"), MakeSecret("abc")) {
		t.Error("equal secrets must compare equal")
	}
	if SecretEqual(MakeSecret("abc"), MakeSecret("abd")) {
		t.Error("different secrets must not compare equal")
	}
	// Differing lengths answer false without comparing, which is what subtle does.
	if SecretEqual(MakeSecret("abc"), MakeSecret("abcd")) {
		t.Error("different lengths must not compare equal")
	}
}
