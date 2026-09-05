package toolchain

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func Setenv(environment []string, key, value string) []string {
	result := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		if !strings.EqualFold(name, key) {
			result = append(result, entry)
		}
	}
	return append(result, key+"="+value)
}

// GoEnvironment pins the selected host toolchain. A release's module archive is
// a local file proxy, so immutable payloads work with empty writable user caches.
// A missing module fails offline instead of triggering a network/toolchain fetch.
func (r Resolver) GoEnvironment(environment []string) ([]string, error) {
	if environment == nil {
		environment = os.Environ()
	}
	environment = Setenv(environment, "GOTOOLCHAIN", "local")
	manifest, _, err := r.Load()
	if err != nil {
		if os.IsNotExist(err) && r.env("TESL_TOOLCHAIN_ROOT") == "" {
			return environment, nil
		}
		return nil, err
	}
	goPath, err := r.Resolve("go")
	if err != nil {
		return nil, err
	}
	environment = Setenv(environment, "GOROOT", filepath.Dir(filepath.Dir(goPath)))
	environment = Setenv(environment, "GOWORK", "off")
	// User-level Go configuration and private-module patterns must not bypass
	// the installed proxy. Generated programs need no host C compiler or VCS.
	for key, value := range map[string]string{
		"GOENV": "off", "GO111MODULE": "on", "GOPRIVATE": "", "GONOPROXY": "none",
		"GOVCS": "*:off", "CGO_ENABLED": "0",
	} {
		environment = Setenv(environment, key, value)
	}
	if _, found := manifest.Components["go-modules"]; found {
		modules, err := r.Resolve("go-modules")
		if err != nil {
			return nil, err
		}
		path := filepath.ToSlash(modules)
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}
		environment = Setenv(environment, "GOPROXY", (&url.URL{Scheme: "file", Path: path}).String())
	} else {
		environment = Setenv(environment, "GOPROXY", "off")
	}
	environment = Setenv(environment, "GOSUMDB", "off")
	cache, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}
	for key, subdir := range map[string]string{"GOCACHE": "build", "GOMODCACHE": "modules"} {
		if r.env(key) == "" {
			environment = Setenv(environment, key, filepath.Join(cache, "tesl", "go", subdir))
		}
	}
	return environment, nil
}

// CompilerEnvironment makes bundled source libraries discoverable from any cwd,
// including a retained session's private mirror. Explicit stdlib overrides win;
// an installed manifest otherwise owns its resources, independent of a checkout.
func (r Resolver) CompilerEnvironment(environment []string) ([]string, error) {
	if environment == nil {
		environment = os.Environ()
	}
	if r.env("TESL_STDLIB_DIR") != "" {
		directory, err := r.Resolve("stdlib")
		if err != nil {
			return nil, err
		}
		return Setenv(environment, "TESL_STDLIB_DIR", directory), nil
	}
	manifest, root, err := r.Load()
	if err != nil {
		if os.IsNotExist(err) && r.env("TESL_TOOLCHAIN_ROOT") == "" {
			return environment, nil
		}
		return nil, err
	}
	if _, found := manifest.Components["stdlib"]; found {
		directory, err := r.Resolve("stdlib")
		if err != nil {
			return nil, err
		}
		return Setenv(environment, "TESL_STDLIB_DIR", directory), nil
	}
	// Compatibility with older distributions' collections layout.
	return Setenv(environment, "TESL_REPO_ROOT", root), nil
}
