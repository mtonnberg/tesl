package cli

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestDASTScopeAndArguments(t *testing.T) {
	for _, sample := range []struct {
		args []string
		ok   bool
	}{
		{[]string{"http://127.0.0.1:8080", "--active"}, true},
		{[]string{"http://[::1]:8080/api", "--active"}, true},
		{[]string{"https://localhost:8443", "--active"}, true},
		{[]string{"https://example.com", "--active"}, false},
		{[]string{"https://example.com", "--active", "--allow-remote"}, true},
		{[]string{"https://user:password@example.com"}, false},
		{[]string{"http://localhost:99999"}, false},
		{[]string{"http://localhost", "--authorization-env", "BAD-NAME"}, false},
		{[]string{"http://localhost", "--zap-port", "0"}, false},
		{[]string{"http://localhost", "--spec"}, false},
		{[]string{"http://localhost", "--scanner", "unknown"}, false},
		{[]string{"app.tesl", "AppServer", "--target", "http://localhost"}, true},
	} {
		t.Run(strings.Join(sample.args, " "), func(t *testing.T) {
			_, err := parseDAST(sample.args)
			if (err == nil) != sample.ok {
				t.Fatalf("parse = %v", err)
			}
		})
	}
}

func TestDASTPlanContainsOnlySecretReferencesAndEscapedScope(t *testing.T) {
	options := dastOptions{Target: "https://example.com/api.v1", AuthorizationEnv: "TEST_TOKEN", CookieEnv: "TEST_COOKIE"}
	plan := dastPlan(options, `C:\path with spaces\openapi.json`, `C:\reports å`)
	data, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, ref := range []string{"${TEST_TOKEN}", "${TEST_COOKIE}"} {
		if !strings.Contains(string(data), ref) {
			t.Fatalf("missing reference %s", ref)
		}
	}
	if strings.Contains(string(data), "activeScan") {
		t.Fatal("default plan contains active scans")
	}
	contexts := plan["env"].(map[string]any)["contexts"].([]map[string]any)
	pattern := contexts[0]["includePaths"].([]string)[0]
	compiled, err := regexp.Compile(pattern)
	if err != nil {
		t.Fatal(err)
	}
	if !compiled.MatchString("https://example.com/api.v1/resource") || compiled.MatchString("https://exampleXcom/apiXv1/resource") || compiled.MatchString("https://example.com/api.v12/resource") {
		t.Fatalf("incorrect scan scope: %s", pattern)
	}
}
