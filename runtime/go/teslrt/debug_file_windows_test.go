//go:build windows

package teslrt

import (
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// SDDL may render a numeric SID as an alias such as LA or SY. Compare the
// permission structure and binary SID, rather than its display spelling.
func debugTokenACLMatchesUser(sd *windows.SECURITY_DESCRIPTOR, user *windows.SID) bool {
	control, _, err := sd.Control()
	if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
		return false
	}
	dacl, _, err := sd.DACL()
	if err != nil || dacl == nil || dacl.AceCount != 1 {
		return false
	}
	var ace *windows.ACCESS_ALLOWED_ACE
	if err := windows.GetAce(dacl, 0, &ace); err != nil || ace == nil {
		return false
	}
	if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags != 0 {
		return false
	}
	const required = windows.FILE_GENERIC_READ | windows.FILE_GENERIC_WRITE | windows.DELETE
	if ace.Mask&required != required {
		return false
	}
	// SidStart begins the variable-length SID stored within this native ACE.
	sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
	return sid.Equals(user)
}

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
	if !debugTokenACLMatchesUser(sd, user.User.Sid) {
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

func TestWindowsDebugTokenACLIdentityAndPermissions(t *testing.T) {
	system, err := windows.StringToSid("S-1-5-18")
	if err != nil {
		t.Fatal(err)
	}
	for _, sample := range []struct {
		name, descriptor string
		want             bool
	}{
		{"SID alias", "D:P(A;;FA;;;SY)", true},
		{"numeric SID", "D:P(A;;FA;;;S-1-5-18)", true},
		{"unprotected", "D:(A;;FA;;;SY)", false},
		{"wrong user", "D:P(A;;FA;;;WD)", false},
		{"extra user", "D:P(A;;FA;;;SY)(A;;FR;;;WD)", false},
		{"deny ACE", "D:P(D;;FA;;;SY)", false},
		{"inherit-only ACE", "D:P(A;IO;FA;;;SY)", false},
		{"read-only", "D:P(A;;FR;;;SY)", false},
		{"empty DACL", "D:P", false},
		{"null DACL", "D:NO_ACCESS_CONTROL", false},
	} {
		t.Run(sample.name, func(t *testing.T) {
			sd, err := windows.SecurityDescriptorFromString(sample.descriptor)
			if err != nil {
				t.Fatal(err)
			}
			if got := debugTokenACLMatchesUser(sd, system); got != sample.want {
				t.Fatalf("ACL matches user = %v, want %v: %s", got, sample.want, sd.String())
			}
		})
	}
}
