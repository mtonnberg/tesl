package lsp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
)

// Mock documents need native absolute paths too: Unix file:///tmp URIs are
// invalid on Windows. Include characters that require URI escaping on all hosts.
func testFilePath(name string) string {
	return filepath.Join(os.TempDir(), "tesl lsp å#%", name)
}

func testFileURI(name string) string {
	return protocol.PathToURI(testFilePath(name))
}

func testFilePathJSON(name string) string {
	encoded, _ := json.Marshal(testFilePath(name))
	return string(encoded)
}

func testFileURIJSON(name string) string {
	encoded, _ := json.Marshal(testFileURI(name))
	return string(encoded)
}

func TestMockDocumentPathsAreNativeAndJSONSafe(t *testing.T) {
	for _, name := range []string{"demo.tesl", "other file 雪.tesl"} {
		t.Run(name, func(t *testing.T) {
			path := testFilePath(name)
			if !filepath.IsAbs(path) {
				t.Fatalf("fixture path is not absolute: %q", path)
			}
			uri := testFileURI(name)
			decoded, err := protocol.URIToPath(uri)
			if err != nil || decoded != path {
				t.Fatalf("fixture URI %q resolves to %q, %v; want %q", uri, decoded, err, path)
			}
			for encoded, want := range map[string]string{testFilePathJSON(name): path, testFileURIJSON(name): uri} {
				var got string
				if err := json.Unmarshal([]byte(encoded), &got); err != nil || got != want {
					t.Fatalf("fixture JSON %s = %q, %v; want %q", encoded, got, err, want)
				}
			}
		})
	}
}
