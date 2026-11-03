// Package compilerfixture provides integrity checks for test-only compiler reuse.
package compilerfixture

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

func Digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// Key uses unambiguous framing; callers supply the captured input manifest,
// complete environment, toolchain identities and exact build/edit recipe.
func Key(parts []string) (string, error) {
	// Environment strings can contain arbitrary bytes. JSON would replace invalid
	// UTF-8 and could give different inputs the same key.
	data := []byte("tesl-test-compiler-key-v1:")
	data = strconv.AppendInt(data, int64(len(parts)), 10)
	data = append(data, ':')
	for _, part := range parts {
		data = strconv.AppendInt(data, int64(len(part)), 10)
		data = append(data, ':')
		data = append(data, part...)
	}
	return Digest(data), nil
}

// Check refuses a changed candidate instead of silently rebuilding under a
// second key. Empty expected means first use, not an integrity bypass for hits.
func Check(expected, actual string) error {
	if expected != "" && expected != actual {
		return fmt.Errorf("compiler cache rejected changed inputs/environment/recipe")
	}
	return nil
}

func Binary(path, expected string) (string, error) {
	directory, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return "", err
	}
	defer func() { _ = directory.Close() }()
	info, err := directory.Lstat(filepath.Base(path))
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0100 == 0 {
		return "", fmt.Errorf("cached compiler is not a regular executable: %s", path)
	}
	data, err := directory.ReadFile(filepath.Base(path))
	if err != nil {
		return "", err
	}
	hash := Digest(data)
	if expected != "" && expected != hash {
		return "", fmt.Errorf("compiler cache rejected binary tampering: %s", path)
	}
	return hash, nil
}
