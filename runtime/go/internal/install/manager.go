package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"tesl.dev/runtime/go/internal/toolchain"
)

var Frontends = []string{"tesl", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"}
var versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$`)

type State struct {
	Version    int    `json:"version"`
	Active     string `json:"active_version"`
	Previous   string `json:"previous_version"`
	Generation uint64 `json:"generation"`
}
type Version struct {
	Version       string `json:"toolchain_version"`
	Target        string `json:"target"`
	ArchiveSHA256 string `json:"archive_sha256"`
}
type Result struct {
	Version   int       `json:"version"`
	Action    string    `json:"action"`
	Root      string    `json:"root"`
	Bin       string    `json:"path_directory"`
	State     State     `json:"state"`
	Installed []Version `json:"installed"`
}
type marker struct {
	Version        int    `json:"version"`
	Kind           string `json:"kind"`
	LauncherSHA256 string `json:"launcher_sha256"`
}
type fileRecord struct {
	Mode      uint32 `json:"mode"`
	SHA256    string `json:"sha256,omitempty"`
	Link      string `json:"link,omitempty"`
	Directory bool   `json:"directory,omitempty"`
}
type receipt struct {
	Version          int                   `json:"version"`
	ToolchainVersion string                `json:"toolchain_version"`
	Target           string                `json:"target"`
	ArchiveSHA256    string                `json:"archive_sha256"`
	ManifestSHA256   string                `json:"manifest_sha256"`
	Files            map[string]fileRecord `json:"files"`
}

type Manager struct {
	Root string
	// Executable is the native tesl-install binary used for the initial shims.
	Executable string
	// beforeCommit is a failure-injection seam for transaction regression tests.
	beforeCommit func() error
}

func DefaultRoot() (string, error) {
	if runtime.GOOS == "windows" {
		root := os.Getenv("LOCALAPPDATA")
		if root == "" {
			return "", errors.New("LOCALAPPDATA is unavailable; pass --root")
		}
		return filepath.Join(root, "Programs", "Tesl"), nil
	}
	home, err := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "tesl"), err
}

func validVersion(value string) bool { return len(value) <= 160 && versionPattern.MatchString(value) }
func validHash(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}
func binarySuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = file.Close() }()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readJSON(path string, value any, limit int64) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return fmt.Errorf("invalid managed metadata file %s", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	decoder := json.NewDecoder(io.LimitReader(file, limit))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("managed metadata contains trailing data")
	}
	return nil
}

func atomicJSON(path string, value any) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(file.Name()) }()
	err = json.NewEncoder(file).Encode(value)
	if err == nil {
		err = file.Sync()
	}
	err = errors.Join(err, file.Close())
	if err != nil {
		return err
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func realDirectory(path string, create bool) error {
	if create {
		if err := os.Mkdir(path, 0700); err != nil && !os.IsExist(err) {
			return err
		}
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("managed directory is not a real directory: %s", path)
	}
	return nil
}

func (m *Manager) open(create bool, exclusive bool) (*fileLock, marker, error) {
	root, err := filepath.Abs(m.Root)
	if err != nil {
		return nil, marker{}, err
	}
	if create {
		if err := os.MkdirAll(root, 0700); err != nil {
			return nil, marker{}, err
		}
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return nil, marker{}, err
	}
	m.Root = root
	markPath := filepath.Join(root, ".tesl-install.json")
	var mark marker
	err = readJSON(markPath, &mark, 4096)
	if os.IsNotExist(err) && create {
		entries, listErr := os.ReadDir(root)
		if listErr != nil {
			return nil, marker{}, listErr
		}
		for _, entry := range entries {
			if entry.Name() != ".install.lock" {
				return nil, marker{}, errors.New("refusing to manage a nonempty directory without a Tesl installation marker")
			}
		}
	} else if err != nil {
		return nil, marker{}, fmt.Errorf("not a managed Tesl installation: %w", err)
	}
	lock, err := acquireLock(filepath.Join(root, ".install.lock"), exclusive)
	if err != nil {
		return nil, marker{}, err
	}
	fail := func(err error) (*fileLock, marker, error) { _ = lock.Close(); return nil, marker{}, err }
	err = readJSON(markPath, &mark, 4096)
	if os.IsNotExist(err) && create {
		digest, hashErr := hashFile(m.Executable)
		if hashErr != nil {
			return fail(hashErr)
		}
		mark = marker{Version: 1, Kind: "tesl-managed-installation", LauncherSHA256: digest}
		if err := atomicJSON(markPath, mark); err != nil {
			return fail(err)
		}
	} else if err != nil {
		return fail(err)
	}
	if mark.Version != 1 || mark.Kind != "tesl-managed-installation" || !validHash(mark.LauncherSHA256) {
		return fail(errors.New("unsupported Tesl installation marker"))
	}
	for _, directory := range []string{"versions", "leases", "bin"} {
		if err := realDirectory(filepath.Join(root, directory), create); err != nil {
			return fail(err)
		}
	}
	return lock, mark, nil
}

func (m *Manager) readState() (State, error) {
	state := State{Version: 1}
	err := readJSON(filepath.Join(m.Root, "state.json"), &state, 4096)
	if os.IsNotExist(err) {
		return State{Version: 1}, nil
	}
	if err != nil {
		return State{}, err
	}
	if state.Version != 1 || state.Active != "" && !validVersion(state.Active) || state.Previous != "" && !validVersion(state.Previous) || state.Active == "" && state.Previous != "" || state.Active != "" && state.Active == state.Previous {
		return State{}, errors.New("invalid installation selection state")
	}
	for _, version := range []string{state.Active, state.Previous} {
		if version != "" {
			if _, _, err := m.loadVersion(version); err != nil {
				return State{}, err
			}
		}
	}
	return state, nil
}

func (m *Manager) commit(state State) error {
	if m.beforeCommit != nil {
		if err := m.beforeCommit(); err != nil {
			return err
		}
	}
	if state.Generation == ^uint64(0) {
		return errors.New("installation selection generation exhausted")
	}
	state.Generation++
	return atomicJSON(filepath.Join(m.Root, "state.json"), state)
}

func validatePayload(root string) (toolchain.Manifest, error) {
	resolver := toolchain.Resolver{Executable: filepath.Join(root, "bin", "tesl"+binarySuffix()), GOOS: runtime.GOOS}
	manifest, _, err := resolver.Load()
	if err != nil {
		return manifest, err
	}
	if !validVersion(manifest.ToolchainVersion) || manifest.Target != runtime.GOOS+"-"+runtime.GOARCH {
		return manifest, errors.New("toolchain version or native target is invalid")
	}
	for _, name := range append(append([]string{}, Frontends...), "compiler", "go", "postgres", "initdb", "pg_ctl", "createdb", "psql", "stdlib", "templates", "doc", "go-modules", "licenses") {
		if _, err := resolver.Resolve(name); err != nil {
			return manifest, err
		}
	}
	for _, name := range Frontends {
		if manifest.Components[name].Path != "bin/"+name+binarySuffix() || manifest.Components[name].Version != manifest.ToolchainVersion {
			return manifest, fmt.Errorf("invalid frontend component %s", name)
		}
	}
	return manifest, nil
}

func (m *Manager) loadVersion(version string) (receipt, string, error) {
	if !validVersion(version) {
		return receipt{}, "", errors.New("invalid version")
	}
	root := filepath.Join(m.Root, "versions", version)
	if err := realDirectory(root, false); err != nil {
		return receipt{}, "", err
	}
	var record receipt
	if err := readJSON(filepath.Join(root, receiptName), &record, 64<<20); err != nil {
		return record, root, err
	}
	if record.Version != 1 || record.ToolchainVersion != version || record.Target != runtime.GOOS+"-"+runtime.GOARCH || !validHash(record.ArchiveSHA256) || !validHash(record.ManifestSHA256) || len(record.Files) == 0 {
		return record, root, errors.New("invalid installed version receipt")
	}
	digest, err := hashFile(filepath.Join(root, "share", "tesl", "toolchain.json"))
	if err != nil {
		return record, root, err
	}
	if digest != record.ManifestSHA256 {
		return record, root, errors.New("installed manifest differs from its verified receipt")
	}
	manifest, err := validatePayload(root)
	if err != nil {
		return record, root, err
	}
	if manifest.ToolchainVersion != version {
		return record, root, errors.New("installed manifest version differs from directory")
	}
	return record, root, nil
}

func snapshot(ctx context.Context, root string) (map[string]fileRecord, error) {
	files := map[string]fileRecord{}
	err := filepath.WalkDir(root, func(name string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		relative, err := filepath.Rel(root, name)
		if err != nil {
			return err
		}
		if relative == receiptName {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		record := fileRecord{Mode: uint32(info.Mode().Perm()), Directory: entry.IsDir()}
		if entry.Type()&os.ModeSymlink != 0 {
			record.Link, err = os.Readlink(name)
		} else if !entry.IsDir() {
			record.SHA256, err = hashFile(name)
		}
		files[filepath.ToSlash(relative)] = record
		return err
	})
	return files, err
}

func removeOwnedTree(root string) error {
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.Chmod(path, 0700)
		}
		if runtime.GOOS == "windows" && entry.Type()&os.ModeSymlink == 0 {
			return os.Chmod(path, 0600)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return os.RemoveAll(root)
}

func freeze(root string) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.Type()&os.ModeSymlink != 0 {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if runtime.GOOS == "windows" {
			return nil
		}
		return os.Chmod(path, info.Mode().Perm()&0555)
	})
}

func (m *Manager) result(action string) (Result, error) {
	state, err := m.readState()
	if err != nil {
		return Result{}, err
	}
	result := Result{Version: 1, Action: action, Root: m.Root, Bin: filepath.Join(m.Root, "bin"), State: state, Installed: []Version{}}
	entries, err := os.ReadDir(filepath.Join(m.Root, "versions"))
	if err != nil {
		return result, err
	}
	for _, entry := range entries {
		record, _, err := m.loadVersion(entry.Name())
		if err != nil {
			return result, err
		}
		result.Installed = append(result.Installed, Version{Version: record.ToolchainVersion, Target: record.Target, ArchiveSHA256: record.ArchiveSHA256})
	}
	sort.Slice(result.Installed, func(i, j int) bool { return result.Installed[i].Version < result.Installed[j].Version })
	return result, nil
}

func (m *Manager) List() (Result, error) {
	lock, _, err := m.open(false, false)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = lock.Close() }()
	return m.result("list")
}

func (m *Manager) Install(ctx context.Context, archive, checksum string) (Result, error) {
	if !validHash(checksum) {
		return Result{}, errors.New("--sha256 must be a 64-character SHA-256 checksum")
	}
	lock, _, err := m.open(true, true)
	if err != nil {
		return Result{}, err
	}
	_, stateErr := m.readState()
	closeErr := lock.Close()
	if err := errors.Join(stateErr, closeErr); err != nil {
		return Result{}, err
	}
	stage, err := os.MkdirTemp(m.Root, ".install-stage-")
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = removeOwnedTree(stage) }()
	payload := filepath.Join(stage, "payload")
	if err := os.Mkdir(payload, 0700); err != nil {
		return Result{}, err
	}
	prefix, err := extractArchive(ctx, archive, checksum, payload)
	if err != nil {
		return Result{}, err
	}
	manifest, err := validatePayload(payload)
	if err != nil {
		return Result{}, err
	}
	if prefix != "tesl-"+manifest.ToolchainVersion+"-"+manifest.Target {
		return Result{}, errors.New("archive root differs from its toolchain identity")
	}
	// Expensive extraction and hashing do not block existing frontend launches.
	if err := sealPayload(ctx, payload, manifest, checksum); err != nil {
		return Result{}, err
	}
	lock, mark, err := m.open(false, true)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = lock.Close() }()
	state, err := m.readState()
	if err != nil {
		return Result{}, err
	}
	destination := filepath.Join(m.Root, "versions", manifest.ToolchainVersion)
	if _, err := os.Lstat(destination); err == nil {
		record, _, err := m.loadVersion(manifest.ToolchainVersion)
		if err != nil {
			return Result{}, err
		}
		if !strings.EqualFold(record.ArchiveSHA256, checksum) {
			return Result{}, errors.New("version already exists with a different archive checksum")
		}
	} else if !os.IsNotExist(err) {
		return Result{}, err
	} else {
		if err := ctx.Err(); err != nil {
			return Result{}, err
		}
		if err := os.Rename(payload, destination); err != nil {
			return Result{}, err
		}
	}
	if err := m.ensureLaunchers(mark); err != nil {
		return Result{}, err
	}
	if state.Active != manifest.ToolchainVersion {
		state.Previous, state.Active = state.Active, manifest.ToolchainVersion
		if err := m.commit(state); err != nil {
			return Result{}, err
		}
	}
	return m.result("install")
}

func sealPayload(ctx context.Context, payload string, manifest toolchain.Manifest, checksum string) error {
	if err := freeze(payload); err != nil {
		return err
	}
	files, err := snapshot(ctx, payload)
	if err != nil {
		return err
	}
	digest, err := hashFile(filepath.Join(payload, "share", "tesl", "toolchain.json"))
	if err != nil {
		return err
	}
	record := receipt{Version: 1, ToolchainVersion: manifest.ToolchainVersion, Target: manifest.Target, ArchiveSHA256: strings.ToLower(checksum), ManifestSHA256: digest, Files: files}
	info, err := os.Stat(payload)
	if err != nil {
		return err
	}
	if err := os.Chmod(payload, 0700); err != nil {
		return err
	}
	if err := atomicJSON(filepath.Join(payload, receiptName), record); err != nil {
		return err
	}
	return os.Chmod(payload, info.Mode().Perm())
}

func (m *Manager) Select(version string) (Result, error) {
	lock, _, err := m.open(false, true)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = lock.Close() }()
	state, err := m.readState()
	if err != nil {
		return Result{}, err
	}
	if _, _, err := m.loadVersion(version); err != nil {
		return Result{}, err
	}
	if state.Active != version {
		state.Previous, state.Active = state.Active, version
		if err := m.commit(state); err != nil {
			return Result{}, err
		}
	}
	return m.result("select")
}

func (m *Manager) Rollback() (Result, error) {
	lock, _, err := m.open(false, true)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = lock.Close() }()
	state, err := m.readState()
	if err != nil {
		return Result{}, err
	}
	if state.Previous == "" {
		return Result{}, errors.New("no previous version is available for rollback")
	}
	state.Active, state.Previous = state.Previous, state.Active
	if err := m.commit(state); err != nil {
		return Result{}, err
	}
	return m.result("rollback")
}

func (m *Manager) Uninstall(ctx context.Context, version string) (Result, error) {
	lock, _, err := m.open(false, true)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = lock.Close() }()
	state, err := m.readState()
	if err != nil {
		return Result{}, err
	}
	record, directory, err := m.loadVersion(version)
	if err != nil {
		return Result{}, err
	}
	lease, err := acquireLock(filepath.Join(m.Root, "leases", version+".lock"), true)
	if err != nil {
		return Result{}, fmt.Errorf("version is in use; close its tools before uninstalling: %w", err)
	}
	defer func() { _ = lease.Close() }()
	files, err := snapshot(ctx, directory)
	if err != nil {
		return Result{}, err
	}
	if !reflect.DeepEqual(files, record.Files) {
		return Result{}, errors.New("installed files were modified or user files were added; refusing to remove them")
	}
	trash, err := os.MkdirTemp(m.Root, ".uninstall-stage-")
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = os.Remove(trash) }()
	removed := filepath.Join(trash, "payload")
	if err := os.Rename(directory, removed); err != nil {
		return Result{}, err
	}
	if state.Active == version {
		state.Active, state.Previous = state.Previous, ""
	} else if state.Previous == version {
		state.Previous = ""
	}
	if err := m.commit(state); err != nil {
		return Result{}, errors.Join(err, os.Rename(removed, directory))
	}
	if err := removeOwnedTree(removed); err != nil {
		return Result{}, fmt.Errorf("version deselected; cannot remove its staged payload: %w", err)
	}
	return m.result("uninstall")
}
