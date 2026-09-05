// Package install manages explicitly selected, checksum-verified local Tesl
// archives. It never downloads artifacts or modifies projects and databases.
package install

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
)

const maxArchiveBytes int64 = 2 << 30
const maxExpandedBytes int64 = 4 << 30
const maxArchiveEntries = 150000
const receiptName = ".tesl-install-receipt.json"

type archiveEntry struct {
	kind byte
	link string
}

type extractor struct {
	ctx          context.Context
	root, prefix string
	entries      map[string]archiveEntry
	folded       map[string]string
	parents      map[string]bool
	count        int
	bytes        int64
}

func portablePath(name string) bool {
	if name == "" || strings.ContainsAny(name, "\\:\x00\r\n") || strings.HasPrefix(name, "/") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == "" || part == "." || part == ".." || strings.TrimRight(part, " .") != part {
			return false
		}
		base, _, _ := strings.Cut(strings.ToUpper(part), ".")
		if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" || len(base) == 4 && (strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT")) && base[3] >= '1' && base[3] <= '9' {
			return false
		}
		for _, character := range part {
			if character < 32 || strings.ContainsRune(`<>"|?*`, character) {
				return false
			}
		}
	}
	return true
}

func (x *extractor) entry(name string, kind byte, link string, size int64, mode os.FileMode, reader io.Reader) error {
	if err := x.ctx.Err(); err != nil {
		return err
	}
	x.count++
	if x.count > maxArchiveEntries {
		return errors.New("archive contains too many entries")
	}
	name = strings.TrimSuffix(name, "/")
	if !portablePath(name) {
		return fmt.Errorf("unsafe archive path %q", name)
	}
	first, rest, nested := strings.Cut(name, "/")
	if x.prefix == "" {
		x.prefix = first
	}
	if first != x.prefix {
		return errors.New("archive must contain one toolchain root")
	}
	if !nested {
		if kind != 'd' {
			return errors.New("archive root must be a directory")
		}
		return nil
	}
	if rest == receiptName {
		return errors.New("archive contains installer-owned metadata")
	}
	if _, exists := x.entries[rest]; exists {
		return fmt.Errorf("duplicate archive entry %s", rest)
	}
	if len(x.entries) >= maxArchiveEntries || size < 0 || size > maxExpandedBytes-x.bytes {
		return errors.New("archive exceeds its extraction limits")
	}
	if runtime.GOOS != "linux" {
		folded := strings.ToLower(rest)
		if previous, found := x.folded[folded]; found && previous != rest {
			return fmt.Errorf("case-colliding archive entries %s and %s", previous, rest)
		}
		x.folded[folded] = rest
	}
	for parent := path.Dir(rest); parent != "."; parent = path.Dir(parent) {
		if entry, exists := x.entries[parent]; exists && entry.kind != 'd' {
			return fmt.Errorf("archive entry descends through a non-directory: %s", parent)
		}
		x.parents[parent] = true
	}
	if kind != 'd' {
		if x.parents[rest] {
			return fmt.Errorf("archive replaces a parent directory: %s", rest)
		}
	}
	x.entries[rest] = archiveEntry{kind: kind, link: link}
	destination := filepath.Join(x.root, filepath.FromSlash(rest))
	if kind == 'd' {
		return os.MkdirAll(destination, 0755)
	}
	if kind == 'l' {
		if runtime.GOOS == "windows" || link == "" || strings.ContainsAny(link, "\\:\x00\r\n") || strings.HasPrefix(link, "/") {
			return fmt.Errorf("unsupported archive link %s", rest)
		}
		resolved := path.Clean(path.Join(path.Dir(rest), link))
		if resolved == ".." || strings.HasPrefix(resolved, "../") || resolved == "." {
			return fmt.Errorf("archive link escapes toolchain: %s", rest)
		}
		return nil // Create links only after all regular files have been written.
	}
	if kind != 'f' {
		return fmt.Errorf("unsupported archive entry type: %s", rest)
	}
	x.bytes += size
	if err := os.MkdirAll(filepath.Dir(destination), 0755); err != nil {
		return err
	}
	permissions := os.FileMode(0644)
	if mode.Perm()&0111 != 0 {
		permissions = 0755
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, permissions)
	if err != nil {
		return err
	}
	_, copyErr := io.CopyN(file, &contextReader{ctx: x.ctx, reader: reader}, size)
	if copyErr == nil {
		copyErr = file.Sync()
	}
	closeErr := file.Close()
	return errors.Join(copyErr, closeErr)
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(data)
}

func extractArchive(ctx context.Context, archive, expected, destination string) (string, error) {
	digest, err := hex.DecodeString(expected)
	if err != nil || len(digest) != sha256.Size {
		return "", errors.New("--sha256 must be a 64-character SHA-256 checksum")
	}
	input, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	defer func() { _ = input.Close() }()
	info, err := input.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() > maxArchiveBytes {
		return "", errors.New("archive must be a regular file no larger than 2 GiB")
	}
	// Extract a private verified copy, not a second read of the caller's mutable
	// archive. A concurrent change to the original cannot race checksum checking.
	file, err := os.CreateTemp(filepath.Dir(destination), ".verified-archive-*")
	if err != nil {
		return "", err
	}
	defer func() { _ = file.Close(); _ = os.Remove(file.Name()) }()
	hash := sha256.New()
	copied, err := io.Copy(io.MultiWriter(file, hash), io.LimitReader(&contextReader{ctx: ctx, reader: input}, maxArchiveBytes+1))
	if err != nil {
		return "", err
	}
	if copied > maxArchiveBytes {
		return "", errors.New("archive exceeds size limit")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expected) {
		return "", errors.New("archive SHA-256 checksum does not match")
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	var magic [4]byte
	if _, err := io.ReadFull(file, magic[:]); err != nil {
		return "", err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	x := extractor{ctx: ctx, root: destination, entries: map[string]archiveEntry{}, folded: map[string]string{}, parents: map[string]bool{}}
	if magic[0] == 0x1f && magic[1] == 0x8b {
		compressed, err := gzip.NewReader(file)
		if err != nil {
			return "", err
		}
		defer func() { _ = compressed.Close() }()
		limited := &io.LimitedReader{R: &contextReader{ctx: ctx, reader: compressed}, N: maxExpandedBytes + maxArchiveEntries*1024}
		reader := tar.NewReader(limited)
		for {
			header, err := reader.Next()
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				return "", err
			}
			kind := byte('?')
			switch header.Typeflag {
			case tar.TypeReg, 0: // NUL is the legacy tar regular-file type.
				kind = 'f'
			case tar.TypeDir:
				kind = 'd'
			case tar.TypeSymlink:
				kind = 'l'
			}
			if err := x.entry(header.Name, kind, header.Linkname, header.Size, header.FileInfo().Mode(), reader); err != nil {
				return "", err
			}
		}
		// Consume the gzip trailer as well, so truncated or corrupt compression
		// cannot be accepted merely because tar reached its end marker first.
		if _, err := io.Copy(io.Discard, limited); err != nil {
			return "", err
		}
		if limited.N == 0 {
			return "", errors.New("archive exceeds decompression limit")
		}
	} else if magic[0] == 'P' && magic[1] == 'K' {
		reader, err := zip.NewReader(file, copied)
		if err != nil {
			return "", err
		}
		for _, header := range reader.File {
			kind := byte('f')
			if header.FileInfo().IsDir() {
				kind = 'd'
			} else if !header.Mode().IsRegular() {
				return "", fmt.Errorf("ZIP contains a non-regular file: %s", header.Name)
			}
			if header.UncompressedSize64 > uint64(maxExpandedBytes) {
				return "", errors.New("ZIP entry exceeds extraction limit")
			}
			stream, err := header.Open()
			if err != nil {
				return "", err
			}
			err = x.entry(header.Name, kind, "", int64(header.UncompressedSize64), header.Mode(), stream)
			if err == nil {
				_, err = io.Copy(io.Discard, stream)
			} // Validate the ZIP CRC.
			err = errors.Join(err, stream.Close())
			if err != nil {
				return "", err
			}
		}
	} else {
		return "", errors.New("expected a .tar.gz or .zip toolchain archive")
	}
	if len(x.entries) == 0 {
		return "", errors.New("archive contains no toolchain files")
	}
	for name, entry := range x.entries {
		if entry.kind == 'l' {
			to := filepath.Join(destination, filepath.FromSlash(name))
			if err := os.MkdirAll(filepath.Dir(to), 0755); err != nil {
				return "", err
			}
			if err := os.Symlink(entry.link, to); err != nil {
				return "", err
			}
		}
	}
	for name, entry := range x.entries {
		if entry.kind == 'l' {
			resolved, err := filepath.EvalSymlinks(filepath.Join(destination, filepath.FromSlash(name)))
			if err != nil {
				return "", fmt.Errorf("invalid archive link %s: %w", name, err)
			}
			relative, err := filepath.Rel(destination, resolved)
			if err != nil || !filepath.IsLocal(relative) {
				return "", fmt.Errorf("archive link escapes toolchain: %s", name)
			}
		}
	}
	return x.prefix, nil
}
