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
	// The verb comes through a variable so that each case really does go through fmt's
	// formatting machinery: written literally, `fmt.Sprintf("%s", secret)` is a finding
	// (S1025) whose suggested rewrite — call String() directly — deletes the thing under test.
	formatted := func(verb string) string { return fmt.Sprintf(verb, secret) }
	for label, rendered := range map[string]string{
		"%v":     formatted("%v"),
		"%s":     formatted("%s"),
		"%#v":    formatted("%#v"),
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

// Deep redaction: a secret nested inside slices, maps and deeper structs must stay
// redacted through BOTH rendering paths — fmt (which reaches String on the field) and
// JSON (which reaches MarshalJSON). One nested path that leaks is a breach; this walks
// the shapes a real payload actually takes.
func TestDeeplyNestedSecretsStayRedacted(t *testing.T) {
	type apiKey struct {
		Name string
		Key  SecretString
	}
	type envelope struct {
		Keys  []apiKey
		Token SecretString
		Meta  map[string]SecretString
	}
	payload := envelope{
		Keys:  []apiKey{{Name: "prod", Key: MakeSecret("deep-plain")}},
		Token: MakeSecret("shallow-plain"),
		Meta:  map[string]SecretString{"billing": MakeSecret("map-plain")},
	}
	for label, rendered := range map[string]string{
		"fmt": fmt.Sprintf("%v", payload),
		"json": func() string {
			encoded, err := json.Marshal(payload)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			return string(encoded)
		}(),
	} {
		for _, plain := range []string{"deep-plain", "shallow-plain", "map-plain"} {
			if strings.Contains(rendered, plain) {
				t.Errorf("%s disclosed a nested secret payload %q: %s", label, plain, rendered)
			}
		}
		if !strings.Contains(rendered, SecretRedaction) {
			t.Errorf("%s did not carry the redaction marker: %s", label, rendered)
		}
	}
}
