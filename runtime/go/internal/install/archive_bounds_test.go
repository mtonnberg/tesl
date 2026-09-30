package install

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestZIPFinalReadRejectsBadCRCAndDeclaredSizes(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	stream, err := writer.CreateHeader(&zip.FileHeader{Name: "toolchain/data", Method: zip.Store})
	if err != nil {
		t.Fatal(err)
	}
	contents := []byte("payload with an exact declared length")
	if _, err := stream.Write(contents); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	central := bytes.Index(buffer.Bytes(), []byte{'P', 'K', 1, 2})
	if central < 0 {
		t.Fatal("missing ZIP central directory")
	}
	for _, change := range []string{"valid", "CRC", "too short", "too long", "zero size"} {
		t.Run(change, func(t *testing.T) {
			data := bytes.Clone(buffer.Bytes())
			switch change {
			case "CRC":
				data[central+16] ^= 1
			case "too short":
				binary.LittleEndian.PutUint32(data[central+24:], uint32(len(contents)-1))
			case "too long":
				binary.LittleEndian.PutUint32(data[central+24:], uint32(len(contents)+1))
			case "zero size":
				binary.LittleEndian.PutUint32(data[central+24:], 0)
			}
			root := t.TempDir()
			archive, destination := filepath.Join(root, "payload.zip"), filepath.Join(root, "extracted")
			if err := os.WriteFile(archive, data, 0600); err != nil {
				t.Fatal(err)
			}
			digest := sha256.Sum256(data)
			_, err := extractArchive(context.Background(), archive, hex.EncodeToString(digest[:]), destination)
			if change != "valid" {
				if err == nil {
					t.Fatal("accepted malformed ZIP despite matching archive checksum")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			actual, err := os.ReadFile(filepath.Join(destination, "data"))
			if err != nil || !bytes.Equal(actual, contents) {
				t.Fatalf("valid ZIP differs: %q, %v", actual, err)
			}
		})
	}
}

func TestFreezeAndCleanupPreserveExternalSymlinkTargets(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows archive policy rejects symlinks")
	}
	outside := filepath.Join(t.TempDir(), "external")
	if err := os.WriteFile(outside, []byte("preserve me"), 0640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(outside)
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "owned")
	if err := os.MkdirAll(filepath.Join(root, "nested"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "nested", "executable")
	if err := os.WriteFile(file, []byte("owned bytes"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "external-link")); err != nil {
		t.Fatal(err)
	}
	if err := freeze(root); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file)
	if err != nil || info.Mode().Perm() != 0555 {
		t.Fatalf("payload was not made read-only and executable: %v, %v", info, err)
	}
	if err := removeOwnedTree(root); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(outside)
	if err != nil || after.Mode() != before.Mode() {
		t.Fatalf("changed permissions of an external symlink target: %v", err)
	}
	data, err := os.ReadFile(outside)
	if err != nil || string(data) != "preserve me" {
		t.Fatalf("changed an external symlink target: %q, %v", data, err)
	}
}
