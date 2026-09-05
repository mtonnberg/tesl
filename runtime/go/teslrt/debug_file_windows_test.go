//go:build windows

package teslrt

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsDebugTokenHasProtectedCurrentUserACL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "debug token å.txt")
	file, err := createPrivateDebugFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("sensitive debugger credential"); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if dacl == nil || dacl.AceCount != 1 || !strings.HasPrefix(sd.String(), "D:P") || !strings.Contains(sd.String(), user.User.Sid.String()) {
		t.Fatalf("token DACL is not protected/current-user-only: %s", sd.String())
	}
	if other, err := createPrivateDebugFile(path); err == nil {
		_ = other.Close()
		t.Fatal("exclusive creation overwrote a credential")
	}
	contents, err := os.ReadFile(path)
	if err != nil || string(contents) != "sensitive debugger credential" {
		t.Fatalf("credential changed: %q, %v", contents, err)
	}
}
