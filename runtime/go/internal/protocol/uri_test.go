package protocol

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFileURIPathRoundTrip(t *testing.T) {
	wantPath, wantURI := "/tmp/a b.tesl", "file:///tmp/a%20b.tesl"
	if filepath.Separator == '\\' {
		wantPath, wantURI = `C:\tmp\a b.tesl`, "file:///C:/tmp/a%20b.tesl"
	}
	path, err := URIToPath(wantURI)
	if err != nil {
		t.Fatal(err)
	}
	if path != wantPath {
		t.Fatalf("URIToPath() = %q", path)
	}
	if got := PathToURI(path); got != wantURI {
		t.Fatalf("PathToURI() = %q", got)
	}
}

func TestURIToPathRejectsNonFileURI(t *testing.T) {
	if _, err := URIToPath("untitled:demo.tesl"); err == nil {
		t.Fatal("URIToPath() accepted non-file URI")
	}
}

func TestURIToPathRejectsMalformedEscapes(t *testing.T) {
	if _, err := URIToPath("file:///tmp/bad%ZZ.tesl"); err == nil {
		t.Fatal("URIToPath() accepted malformed percent escape")
	}
}

func TestURIPathPreservesUnicodeAndUNCHost(t *testing.T) {
	path, err := URIToPath("file://server/share/%E9%9B%AA.tesl")
	if err != nil {
		t.Fatal(err)
	}
	want := "//server/share/雪.tesl"
	if filepath.Separator == '\\' {
		want = `\\server\share\雪.tesl`
	}
	if path != want {
		t.Fatalf("URIToPath() = %q", path)
	}
}

func TestURIPathSymlinkTargetRemainsAddressable(t *testing.T) {
	if filepath.Separator == '\\' {
		t.Skip("symlink semantics differ on Windows")
	}
	directory := t.TempDir()
	target := filepath.Join(directory, "target.tesl")
	link := filepath.Join(directory, "link.tesl")
	if err := os.WriteFile(target, []byte("module Target"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	path, err := URIToPath(PathToURI(link))
	if err != nil || path != link {
		t.Fatalf("symlink URI round trip = %q, %v", path, err)
	}
}
