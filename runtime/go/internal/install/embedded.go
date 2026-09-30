package install

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"math"
	"os"
)

// FooterMagic is exactly 16 bytes. A setup executable ends with this magic,
// uint64 little-endian ZIP offset, uint64 length, and the raw SHA-256 (64 bytes).
const FooterMagic = "TESL-INSTALL-V1\x00"
const FooterSize = 64

type EmbeddedPayload struct {
	Offset, Length int64
	SHA256         string
}

func FindEmbedded(executable string) (*EmbeddedPayload, error) {
	file, err := os.Open(executable) // #nosec G304 -- inspect the explicitly selected local setup executable, not an archive entry.
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("installer executable is not a regular file")
	}
	if info.Size() < FooterSize {
		return nil, nil
	}
	var footer [FooterSize]byte
	if _, err := file.ReadAt(footer[:], info.Size()-FooterSize); err != nil {
		return nil, err
	}
	if string(footer[:16]) != FooterMagic {
		return nil, nil
	}
	offset, length := binary.LittleEndian.Uint64(footer[16:24]), binary.LittleEndian.Uint64(footer[24:32])
	if offset > math.MaxInt64 || length > math.MaxInt64 {
		return nil, errors.New("invalid embedded ZIP bounds")
	}
	start, size := int64(offset), int64(length)
	available := info.Size() - FooterSize
	if start <= 0 || start > available || size <= 0 || size > maxArchiveBytes || size != available-start {
		return nil, errors.New("invalid embedded ZIP bounds")
	}
	var magic [2]byte
	if _, err := file.ReadAt(magic[:], start); err != nil {
		return nil, err
	}
	if string(magic[:]) != "PK" {
		return nil, errors.New("embedded payload is not a ZIP archive")
	}
	return &EmbeddedPayload{Offset: start, Length: size, SHA256: hex.EncodeToString(footer[32:])}, nil
}

func ExtractEmbedded(ctx context.Context, executable string) (string, string, func(), error) {
	embedded, err := FindEmbedded(executable)
	if err != nil {
		return "", "", nil, err
	}
	if embedded == nil {
		return "", "", nil, errors.New("this installer has no embedded ZIP; pass --archive and --sha256")
	}
	input, err := os.Open(executable) // #nosec G304 -- the caller-selected setup is bounds-checked above and extracted bytes must match its SHA-256.
	if err != nil {
		return "", "", nil, err
	}
	defer func() { _ = input.Close() }()
	output, err := os.CreateTemp("", ".tesl-embedded-*.zip")
	if err != nil {
		return "", "", nil, err
	}
	cleanup := func() { _ = os.Remove(output.Name()) }
	hash := sha256.New()
	_, err = io.Copy(io.MultiWriter(output, hash), &contextReader{ctx: ctx, reader: io.NewSectionReader(input, embedded.Offset, embedded.Length)})
	err = errors.Join(err, output.Close())
	if err == nil && hex.EncodeToString(hash.Sum(nil)) != embedded.SHA256 {
		err = errors.New("embedded ZIP checksum does not match")
	}
	if err != nil {
		cleanup()
		return "", "", nil, err
	}
	return output.Name(), embedded.SHA256, cleanup, nil
}

func launcherHash(executable string) (string, error) {
	embedded, err := FindEmbedded(executable)
	if err != nil {
		return "", err
	}
	if embedded == nil {
		return hashFile(executable)
	}
	file, err := os.Open(executable) // #nosec G304 -- hash the selected local setup prefix; no archive-provided path is opened here.
	if err != nil {
		return "", err
	}
	defer func() { _ = file.Close() }()
	hash := sha256.New()
	if _, err := io.CopyN(hash, file, embedded.Offset); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
