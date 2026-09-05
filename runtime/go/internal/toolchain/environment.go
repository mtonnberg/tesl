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
