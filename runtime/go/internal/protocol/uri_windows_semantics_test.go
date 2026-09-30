package protocol

import "testing"

func TestWindowsFileURIRoundTrip(t *testing.T) {
	for _, sample := range []struct{ path, uri string }{
		{`C:\Users\Ada\my app\å😀.tesl`, "file:///C:/Users/Ada/my%20app/%C3%A5%F0%9F%98%80.tesl"},
		{`c:\project\a#b%.tesl`, "file:///c:/project/a%23b%25.tesl"},
		{`\\server\share\project\app.tesl`, "file://server/share/project/app.tesl"},
		{`D:\`, "file:///D:/"},
	} {
		t.Run(sample.path, func(t *testing.T) {
			if got := pathToURI(sample.path, true); got != sample.uri {
				t.Fatalf("URI = %q, want %q", got, sample.uri)
			}
			if got, err := uriToPath(sample.uri, true); err != nil || got != sample.path {
				t.Fatalf("path = %q, %v", got, err)
			}
		})
	}
}

func TestURIRejectsAmbiguousAndNonFileLocations(t *testing.T) {
	for _, sample := range []string{"https://example.com/a", "file:relative.tesl", "file:///a?download", "file:///a#fragment", "file:///a%00b", "file://user@host/share/a", "file:///C:%5cfoo", "file://host:80/share/a"} {
		for _, windows := range []bool{false, true} {
			if got, err := uriToPath(sample, windows); err == nil {
				t.Fatalf("accepted %s (Windows=%v): %s", sample, windows, got)
			}
		}
	}
}

func TestWindowsLocalhostAndDriveRoot(t *testing.T) {
	if got, err := uriToPath("file://localhost/C:/a/../b.tesl", true); err != nil || got != `C:\b.tesl` {
		t.Fatalf("localhost = %s, %v", got, err)
	}
	if got, err := uriToPath("file:///C:", true); err != nil || got != `C:\` {
		t.Fatalf("root = %s, %v", got, err)
	}
}
