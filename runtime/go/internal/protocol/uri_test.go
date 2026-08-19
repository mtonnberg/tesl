package protocol

import "testing"

func TestFileURIPathRoundTrip(t *testing.T) {
	path, err := URIToPath("file:///tmp/a%20b.tesl")
	if err != nil {
		t.Fatal(err)
	}
	if path != "/tmp/a b.tesl" {
		t.Fatalf("URIToPath() = %q", path)
	}
	if got := PathToURI(path); got != "file:///tmp/a%20b.tesl" {
		t.Fatalf("PathToURI() = %q", got)
	}
}

func TestURIToPathRejectsNonFileURI(t *testing.T) {
	if _, err := URIToPath("untitled:demo.tesl"); err == nil {
		t.Fatal("URIToPath() accepted non-file URI")
	}
}
