// Package toolchain resolves one selected Tesl installation for every frontend.
package toolchain

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type Component struct {
	Path     string `json:"path"`
	Version  string `json:"version"`
	Optional bool   `json:"optional,omitempty"`
}

type Manifest struct {
	Version          int                  `json:"version"`
	ToolchainVersion string               `json:"toolchain_version"`
	SourceRevision   string               `json:"source_revision"`
	Target           string               `json:"target"`
	Components       map[string]Component `json:"components"`
}

type Resolver struct {
	Executable string
	Getenv     func(string) string
	LookPath   func(string) (string, error)
	GOOS       string
}

func Default() Resolver {
	executable, _ := os.Executable()
	return Resolver{Executable: executable, Getenv: os.Getenv, LookPath: exec.LookPath, GOOS: runtime.GOOS}
}

func (r Resolver) env(key string) string {
	if r.Getenv == nil {
		return ""
	}
	return r.Getenv(key)
}

func (r Resolver) suffix() string {
	if r.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func (r Resolver) root() (string, error) {
	if value := r.env("TESL_TOOLCHAIN_ROOT"); value != "" {
		return filepath.Abs(value)
	}
	path, err := filepath.EvalSymlinks(r.Executable)
	if err != nil {
		return "", fmt.Errorf("toolchain: resolve launcher: %w", err)
	}
	return filepath.Dir(filepath.Dir(path)), nil
}

// Load rejects incompatible or escaping component paths before any command is
// executed. A present but broken installation must not silently mix PATH tools.
func (r Resolver) Load() (Manifest, string, error) {
	root, err := r.root()
	if err != nil {
		return Manifest{}, "", err
	}
	file, err := os.Open(filepath.Join(root, "share", "tesl", "toolchain.json"))
	if err != nil {
		return Manifest{}, root, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Manifest{}, root, err
	}
	if !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return Manifest{}, root, errors.New("toolchain: manifest must be a regular file no larger than 1 MiB")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 1<<20))
	decoder.DisallowUnknownFields()
	var manifest Manifest
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, root, fmt.Errorf("toolchain: read manifest: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return Manifest{}, root, errors.New("toolchain: trailing manifest data")
	}
	if manifest.Version != 1 || manifest.ToolchainVersion == "" || manifest.SourceRevision == "" || len(manifest.Components) == 0 {
		return Manifest{}, root, errors.New("toolchain: incomplete or unsupported manifest")
	}
	for name, component := range manifest.Components {
		if name == "" || component.Version == "" || !safeRelative(component.Path) {
			return Manifest{}, root, fmt.Errorf("toolchain: invalid component %q", name)
		}
	}
	return manifest, root, nil
}

func safeRelative(path string) bool {
	// Manifests use slash-separated paths on every host, including Windows.
	if path == "" || strings.ContainsAny(path, "\\:\x00") || strings.HasPrefix(path, "/") {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

var overrides = map[string][]string{
	"compiler": {"TESL_COMPILER", "TESL_OCAML_COMPILER"}, "go": {"TESL_GO"},
	"templates": {"TESL_TEMPLATES_DIR"}, "doc": {"TESL_DOCS_DIR"},
	"tesl-lsp": {"TESL_LSP_BIN"}, "tesl-dap": {"TESL_DAP_BIN"}, "tesl-mcp": {"TESL_MCP_BIN"},
	"tesl-debug-inspect": {"TESL_DEBUG_INSPECT_BIN"}, "tesl-debug-attach": {"TESL_DEBUG_ATTACH_BIN"},
	"zap": {"TESL_ZAP"}, "nuclei": {"TESL_NUCLEI"},
}

func directoryComponent(name string) bool {
	return name == "templates" || name == "doc" || name == "go-modules"
}

func (r Resolver) check(path, name string) (string, error) {
	if !strings.ContainsAny(path, "/\\") && !directoryComponent(name) && r.LookPath != nil {
		resolved, err := r.LookPath(path)
		if err != nil {
			return "", err
		}
		path = resolved
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("toolchain: %s at %s: %w", name, path, err)
	}
	if directoryComponent(name) != info.IsDir() || (!info.IsDir() && (!info.Mode().IsRegular() || (r.GOOS != "windows" && info.Mode().Perm()&0111 == 0))) {
		return "", fmt.Errorf("toolchain: %s has incorrect file type or permissions: %s", name, path)
	}
	return filepath.Abs(path)
}

func (r Resolver) Resolve(name string) (string, error) {
	for _, key := range overrides[name] {
		if value := r.env(key); value != "" {
			return r.check(value, name)
		}
	}
	if pg := r.env("TESL_POSTGRES_BIN"); pg != "" && postgresTool(name) {
		return r.check(filepath.Join(pg, name+r.suffix()), name)
	}
	manifest, root, err := r.Load()
	if err == nil {
		component, found := manifest.Components[name]
		if !found {
			if optionalExternal(name) && r.LookPath != nil {
				path, err := r.LookPath(name)
				if err != nil {
					return "", err
				}
				return r.check(path, name)
			}
			return "", fmt.Errorf("toolchain: installation has no %s component", name)
		}
		return r.check(filepath.Join(root, filepath.FromSlash(component.Path)), name)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if r.env("TESL_TOOLCHAIN_ROOT") != "" {
		return "", fmt.Errorf("toolchain: explicit installation has no manifest: %w", err)
	}
	// Older Nix layouts keep tools together in bin without a manifest.
	if !directoryComponent(name) {
		binary := name
		if name == "compiler" {
			binary = "tesl-compiler"
		}
		if candidate, checkErr := r.check(filepath.Join(root, "bin", binary+r.suffix()), name); checkErr == nil {
			return candidate, nil
		}
	}
	if repo := r.env("TESL_REPO_ROOT"); repo != "" {
		var candidate string
		switch name {
		case "compiler":
			candidate = filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
		case "templates":
			candidate = filepath.Join(repo, "templates")
		case "doc":
			candidate = filepath.Join(repo, "manual")
		}
		if candidate != "" {
			return r.check(candidate, name)
		}
	}
	if !directoryComponent(name) && r.LookPath != nil {
		candidates := []string{name}
		if name == "compiler" {
			candidates = []string{"tesl-compiler", "tesl"}
		}
		for _, candidate := range candidates {
			if path, pathErr := r.LookPath(candidate); pathErr == nil {
				// Never recurse through the portable CLI when looking for its compiler.
				selected, _ := filepath.EvalSymlinks(path)
				self, _ := filepath.EvalSymlinks(r.Executable)
				if selected != "" && selected == self {
					continue
				}
				return r.check(path, name)
			}
		}
	}
	return "", fmt.Errorf("toolchain: cannot find %s; select an installation with TESL_TOOLCHAIN_ROOT or its documented override", name)
}

func optionalExternal(name string) bool {
	return name == "git" || name == "docker" || name == "zap" || name == "nuclei"
}

func postgresTool(name string) bool {
	switch name {
	case "initdb", "pg_ctl", "createdb", "psql", "postgres":
		return true
	}
	return false
}

type Check struct {
	Name     string `json:"name"`
	Path     string `json:"path,omitempty"`
	Version  string `json:"version,omitempty"`
	Optional bool   `json:"optional"`
	Error    string `json:"error,omitempty"`
}

type Report struct {
	Version          int     `json:"version"`
	OK               bool    `json:"ok"`
	Root             string  `json:"root,omitempty"`
	ToolchainVersion string  `json:"toolchain_version,omitempty"`
	SourceRevision   string  `json:"source_revision,omitempty"`
	Components       []Check `json:"components"`
}

func (r Resolver) Doctor() Report {
	report := Report{Version: 1, OK: true}
	manifest, root, _ := r.Load()
	report.Root, report.ToolchainVersion, report.SourceRevision = root, manifest.ToolchainVersion, manifest.SourceRevision
	for _, name := range []string{"compiler", "go", "templates", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach", "initdb", "pg_ctl", "createdb", "psql", "zap", "nuclei"} {
		component := Check{Name: name, Optional: name == "zap" || name == "nuclei", Version: manifest.Components[name].Version}
		path, err := r.Resolve(name)
		if err != nil {
			component.Error = err.Error()
			if !component.Optional {
				report.OK = false
			}
		} else {
			component.Path = path
		}
		report.Components = append(report.Components, component)
	}
	return report
}
