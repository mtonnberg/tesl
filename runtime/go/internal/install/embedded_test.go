package install

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func embeddedFixture(t *testing.T, prefix, archive []byte, editFooter func([]byte)) string {
	t.Helper()
	footer := make([]byte, FooterSize)
	copy(footer, FooterMagic)
	binary.LittleEndian.PutUint64(footer[16:24], uint64(len(prefix)))
	binary.LittleEndian.PutUint64(footer[24:32], uint64(len(archive)))
	digest := sha256.Sum256(archive)
	copy(footer[32:], digest[:])
	if editFooter != nil {
		editFooter(footer)
	}
	path := filepath.Join(t.TempDir(), "tesl setup å.exe")
	data := append(append(append([]byte{}, prefix...), archive...), footer...)
	if err := os.WriteFile(path, data, 0755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestEmbeddedFooterBoundsAndRecognition(t *testing.T) {
	if len(FooterMagic) != 16 || FooterSize != 64 {
		t.Fatal("setup artifact footer contract changed")
	}
	for _, scenario := range []struct {
		name string
		edit func([]byte)
	}{
		{"zero offset", func(f []byte) { binary.LittleEndian.PutUint64(f[16:24], 0) }},
		{"zero length", func(f []byte) { binary.LittleEndian.PutUint64(f[24:32], 0) }},
		{"offset outside", func(f []byte) { binary.LittleEndian.PutUint64(f[16:24], 9999) }},
		{"overflow offset", func(f []byte) { binary.LittleEndian.PutUint64(f[16:24], ^uint64(0)) }},
		{"overflow length", func(f []byte) { binary.LittleEndian.PutUint64(f[24:32], ^uint64(0)) }},
		{"short section", func(f []byte) { binary.LittleEndian.PutUint64(f[24:32], 2) }},
		{"oversized section", func(f []byte) { binary.LittleEndian.PutUint64(f[24:32], uint64(maxArchiveBytes)+1) }},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			path := embeddedFixture(t, []byte("executable"), []byte("PK payload"), scenario.edit)
			if _, err := FindEmbedded(path); err == nil {
				t.Fatal("accepted invalid footer bounds")
			}
		})
	}
	path := embeddedFixture(t, []byte("executable"), []byte("not zip"), nil)
	if _, err := FindEmbedded(path); err == nil {
		t.Fatal("accepted non-ZIP payload")
	}
	for _, value := range []string{"plain executable", strings.Repeat("x", FooterSize+20), FooterMagic + strings.Repeat("x", FooterSize)} {
		path := filepath.Join(t.TempDir(), "standalone")
		if err := os.WriteFile(path, []byte(value), 0755); err != nil {
			t.Fatal(err)
		}
		payload, err := FindEmbedded(path)
		if err != nil || payload != nil {
			t.Fatalf("recognized a footer absent from EOF: %+v, %v", payload, err)
		}
	}
}

func TestEmbeddedExtractionVerifiesHashAndCleansTemporaryArchive(t *testing.T) {
	archive, digest := fixtureArchive(t, "0.3.1", "zip", fixtureEntries(t, "0.3.1"))
	data, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	prefix := []byte("native installer executable")
	path := embeddedFixture(t, prefix, data, nil)
	payload, err := FindEmbedded(path)
	if err != nil || payload == nil || payload.Offset != int64(len(prefix)) || payload.Length != int64(len(data)) || payload.SHA256 != digest {
		t.Fatalf("footer: %+v, %v", payload, err)
	}
	temporary, checksum, cleanup, err := ExtractEmbedded(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cleanup)
	got, err := os.ReadFile(temporary)
	if err != nil || !bytes.Equal(got, data) || checksum != digest {
		t.Fatalf("extracted archive differs: %v", err)
	}
	info, err := os.Stat(temporary)
	if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
		t.Fatalf("temporary archive is not private: %v, %v", info, err)
	}
	cleanup()
	if _, err := os.Stat(temporary); !os.IsNotExist(err) {
		t.Fatalf("temporary archive survived cleanup: %v", err)
	}
	bad := embeddedFixture(t, prefix, data, func(f []byte) { f[32] ^= 1 })
	if _, _, _, err := ExtractEmbedded(context.Background(), bad); err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("bad embedded checksum: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, _, err := ExtractEmbedded(ctx, path); !errors.Is(err, context.Canceled) {
		t.Fatalf("embedded extraction ignored cancellation: %v", err)
	}
}

func TestEmbeddedSetupInstallsOnlyNativePrefixAsBootstrap(t *testing.T) {
	m := testManager(t)
	archive, checksum := fixtureArchive(t, "0.3.1", "zip", fixtureEntries(t, "0.3.1"))
	data, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	prefix := []byte("native installer prefix")
	m.Executable = embeddedFixture(t, prefix, data, nil)
	if _, err := m.Install(context.Background(), archive, checksum); err != nil {
		t.Fatal(err)
	}
	bootstrap := filepath.Join(m.Root, "bin", "tesl-install"+binarySuffix())
	got, err := os.ReadFile(bootstrap)
	if err != nil || !bytes.Equal(got, prefix) {
		t.Fatalf("bootstrap duplicated the setup archive: %d bytes, %v", len(got), err)
	}
	var mark marker
	if err := readJSON(filepath.Join(m.Root, ".tesl-install.json"), &mark, 4096); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(prefix)
	if mark.LauncherSHA256 != hex.EncodeToString(digest[:]) {
		t.Fatal("managed launcher checksum included embedded ZIP")
	}
	if payload, err := FindEmbedded(bootstrap); err != nil || payload != nil {
		t.Fatalf("installed bootstrap still auto-installs a payload: %+v %v", payload, err)
	}
	// A newer downloaded setup may change its executable prefix. Existing
	// frontends must keep their original consistent protocol-v1 bootstrap.
	m.Executable = embeddedFixture(t, []byte("newer native installer prefix"), data, nil)
	installFixture(t, m, "0.3.2")
	for _, name := range append([]string{"tesl-install"}, Frontends...) {
		contents, err := os.ReadFile(filepath.Join(m.Root, "bin", name+binarySuffix()))
		if err != nil || !bytes.Equal(contents, prefix) {
			t.Fatalf("upgrade changed stable launcher %s: %v", name, err)
		}
	}
}
