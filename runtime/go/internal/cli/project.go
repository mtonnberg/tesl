package cli

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type Manifest map[string]map[string]string

var manifestName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*$`)

// ParseManifest implements the documented flat Tesl manifest subset. Quotes
// protect # and =; malformed or duplicate keys are reported with a line number.
func ParseManifest(source string) (Manifest, error) {
	result := Manifest{}
	section := ""
	var values map[string]string
	scanner := bufio.NewScanner(strings.NewReader(source))
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		if strings.HasPrefix(text, "[") {
			end := strings.IndexByte(text, ']')
			if end < 0 || !manifestName.MatchString(text[1:end]) || (strings.TrimSpace(text[end+1:]) != "" && !strings.HasPrefix(strings.TrimSpace(text[end+1:]), "#")) {
				return nil, fmt.Errorf("tesl.toml:%d: invalid section", line)
			}
			section = text[1:end]
			values = result[section]
			if values == nil {
				values = map[string]string{}
				result[section] = values
			}
			continue
		}
		key, value, found := strings.Cut(text, "=")
		key = strings.TrimSpace(key)
		if !found || !manifestName.MatchString(key) || values == nil {
			return nil, fmt.Errorf("tesl.toml:%d: expected section key = value", line)
		}
		parsed, err := configValue(value)
		if err != nil {
			return nil, fmt.Errorf("tesl.toml:%d: %w", line, err)
		}
		if _, exists := values[key]; exists {
			return nil, fmt.Errorf("tesl.toml:%d: duplicate %s.%s", line, section, key)
		}
		values[key] = parsed
	}
	return result, scanner.Err()
}

func configValue(value string) (string, error) {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, `"`) {
		escaped := false
		for i := 1; i < len(value); i++ {
			if escaped {
				escaped = false
				continue
			}
			if value[i] == '\\' {
				escaped = true
				continue
			}
			if value[i] == '"' {
				rest := strings.TrimSpace(value[i+1:])
				if rest != "" && !strings.HasPrefix(rest, "#") {
					return "", fmt.Errorf("unexpected text after quoted value")
				}
				return strconv.Unquote(value[:i+1])
			}
		}
		return "", fmt.Errorf("unterminated quoted value")
	}
	value, _, _ = strings.Cut(value, "#")
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "[]{}'\"\r\n") {
		return "", fmt.Errorf("expected scalar value")
	}
	return value, nil
}

func projectRoot(start string) string {
	start, _ = filepath.Abs(start)
	for directory := start; ; directory = filepath.Dir(directory) {
		if info, err := os.Stat(filepath.Join(directory, "tesl.toml")); err == nil && info.Mode().IsRegular() {
			return directory
		}
		if filepath.Dir(directory) == directory {
			return start
		}
	}
}

func readManifest(root string) (Manifest, error) {
	data, err := os.ReadFile(filepath.Join(root, "tesl.toml")) // #nosec G304 -- fixed manifest name in the user's selected project.
	if err != nil {
		return nil, err
	}
	return ParseManifest(string(data))
}

func (manifest Manifest) value(section, key, fallback string) string {
	if value, exists := manifest[section][key]; exists {
		return value
	}
	return fallback
}

// Resolve the complete source link chain against the project selected before
// following that chain. Pass this canonical path to the compiler so its sibling
// imports refer to the checked source location, as in the installed shell CLI.
func resolveProjectSource(root, file string) (string, error) {
	project, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", fmt.Errorf("cannot resolve source project root %s: %w", root, err)
	}
	resolved, err := filepath.EvalSymlinks(file)
	if err != nil {
		return "", fmt.Errorf("cannot resolve source file %s: %w", file, err)
	}
	relative, err := filepath.Rel(project, resolved)
	if err != nil || relative == "." || !filepath.IsLocal(relative) {
		return "", fmt.Errorf("source file %s resolves outside the project root %s", file, root)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("cannot inspect source file %s: %w", file, err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("source file %s is not a regular file", file)
	}
	return resolved, nil
}

func (app *App) sourceFile(file string) (string, string, error) {
	if !filepath.IsAbs(file) {
		file = filepath.Join(app.Directory, file)
	}
	file, err := filepath.Abs(file)
	if err != nil {
		return "", "", fmt.Errorf("cannot resolve source file: %w", err)
	}
	root := projectRoot(filepath.Dir(file))
	resolved, err := resolveProjectSource(root, file)
	return resolved, root, err
}

func (app *App) files(args []string) ([]string, error) {
	if len(args) > 0 {
		return args, nil
	}
	root := projectRoot(app.Directory)
	manifest, err := readManifest(root)
	if err != nil {
		return nil, fmt.Errorf("supply a .tesl file or a tesl.toml with [project].entrypoint: %w", err)
	}
	entry := manifest.value("project", "entrypoint", "")
	if entry == "" {
		return nil, fmt.Errorf("tesl.toml has no [project].entrypoint")
	}
	if !filepath.IsAbs(entry) {
		entry = filepath.Join(root, entry)
	}
	if _, err := resolveProjectSource(root, entry); err != nil {
		return nil, err
	}
	_, _ = fmt.Fprintln(app.Stderr, "tesl: using", entry)
	return []string{entry}, nil
}
