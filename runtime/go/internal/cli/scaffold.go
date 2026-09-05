package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

func (app *App) init(ctx context.Context, args []string) (err error) {
	name, template, pgmode := "", "", ""
	yes, noGit := false, false
	for len(args) > 0 {
		arg := args[0]
		args = args[1:]
		switch arg {
		case "--yes", "-y":
			yes = true
		case "--no-git":
			noGit = true
		case "--template", "--postgres":
			if len(args) == 0 {
				return fmt.Errorf("%s requires a value", arg)
			}
			value := args[0]
			args = args[1:]
			if arg == "--template" {
				template = value
			} else {
				pgmode = value
			}
		case "--help", "-h":
			fmt.Fprintln(app.Stdout, "Usage: tesl init [name] [--template api|minimal] [--postgres managed|existing|none] [--yes] [--no-git]")
			return nil
		default:
			if strings.HasPrefix(arg, "-") || name != "" {
				return fmt.Errorf("unexpected init argument: %s", arg)
			}
			name = arg
		}
	}
	reader := bufio.NewReader(app.Stdin)
	prompt := func(question, fallback string) string {
		if yes {
			return fallback
		}
		fmt.Fprintf(app.Stdout, "%s [%s]: ", question, fallback)
		answer, _ := reader.ReadString('\n')
		answer = strings.TrimSpace(answer)
		if answer == "" {
			return fallback
		}
		return answer
	}
	if name == "" {
		name = prompt("Project name", "demoapp")
	}
	if template == "" {
		template = prompt("Template (api|minimal)", "api")
	}
	if template != "api" && template != "minimal" {
		return fmt.Errorf("unknown template: %s", template)
	}
	defaultPG := "none"
	if template == "api" {
		defaultPG = "managed"
	}
	if pgmode == "" {
		pgmode = prompt("PostgreSQL (managed|existing|none)", defaultPG)
	}
	if pgmode != "managed" && pgmode != "existing" && pgmode != "none" {
		return fmt.Errorf("unknown postgres mode: %s", pgmode)
	}
	dest := name
	if !filepath.IsAbs(dest) {
		dest = filepath.Join(app.Directory, dest)
	}
	appName := filepath.Base(dest)
	if strings.ContainsAny(appName, "\"\\\r\n\x00") {
		return fmt.Errorf("project name cannot contain quotes, backslashes, or line breaks")
	}
	if _, err := os.Lstat(dest); err == nil {
		return fmt.Errorf("project already exists: %s", dest)
	} else if !os.IsNotExist(err) {
		return err
	}
	if !yes && strings.EqualFold(prompt("Create "+dest+"? (yes/no)", "yes"), "no") {
		return fmt.Errorf("aborted")
	}
	templates, err := app.Resolver.Resolve("templates")
	if err != nil {
		return err
	}
	contents := map[string][]byte{}
	for _, file := range []string{"app.tesl", "tesl.toml", "README.md"} {
		data, err := os.ReadFile(filepath.Join(templates, template, file))
		if err != nil {
			return err
		}
		contents[file] = []byte(strings.ReplaceAll(string(data), "__APP_NAME__", appName))
	}
	manifest, err := ParseManifest(string(contents["tesl.toml"]))
	if err != nil {
		return err
	}
	manifest["database"]["mode"] = pgmode
	manifestText := strings.Replace(string(contents["tesl.toml"]), "mode = "+strconv.Quote(defaultPG), "mode = "+strconv.Quote(pgmode), 1)
	if pgmode == "managed" {
		port, err := freeManagedPort(dest)
		if err != nil {
			return err
		}
		old := manifest.value("env", "TESL_POSTGRES_PORT", "5432")
		manifest["env"]["TESL_POSTGRES_PORT"] = port
		manifestText = strings.Replace(manifestText, "TESL_POSTGRES_PORT = "+strconv.Quote(old), "TESL_POSTGRES_PORT = "+strconv.Quote(port), 1)
	}
	contents["tesl.toml"] = []byte(manifestText)
	var dotenv strings.Builder
	dotenv.WriteString("# Generated from tesl.toml [env]. Existing process variables take precedence.\n")
	keys := make([]string, 0, len(manifest["env"]))
	for key := range manifest["env"] {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		fmt.Fprintf(&dotenv, "%s=%s\n", key, manifest["env"][key])
	}
	contents[".env"] = []byte(dotenv.String())
	contents[".gitignore"] = []byte(".tesl-postgres/\n.env\n.tesl-stuff/\nresult\n")
	contents["AGENTS.md"] = []byte("# " + appName + "\n\nThis Tesl project uses the " + template + " template.\n\nAfter editing app.tesl, run `tesl agent-context app.tesl` and resolve diagnostics.\nRun `tesl check`, `tesl test`, and `tesl build` before publishing changes.\nUse types and proofs to enforce input validation and capability boundaries.\nKeep secrets in environment variables; never commit .env or .tesl-postgres.\nUse `tesl debug-inspect app.tesl --break-at LINE` to inspect runtime state.\n")
	contents["CLAUDE.md"] = contents["AGENTS.md"]
	env := map[string]string{"TESL_DAP_LOG": "stderr"}
	if pgmode != "none" {
		for key, value := range manifest["env"] {
			if strings.HasPrefix(key, "TESL_POSTGRES_") {
				env[key] = value
			}
		}
	}
	if pgmode == "managed" {
		env["TESL_POSTGRES_HOST"] = "127.0.0.1"
	}
	configurations := []map[string]any{}
	for _, mode := range []string{"program", "test"} {
		configurations = append(configurations, map[string]any{"type": "tesl", "request": "launch", "name": "Debug Tesl " + mode, "program": "${workspaceFolder}/app.tesl", "cwd": "${workspaceFolder}", "mode": mode, "env": env})
	}
	launch, err := json.MarshalIndent(map[string]any{"version": "0.2.0", "configurations": configurations}, "", "  ")
	if err != nil {
		return err
	}
	contents[".vscode/launch.json"] = append(launch, '\n')
	if err := os.Mkdir(dest, 0755); err != nil {
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(dest)
		}
	}()
	for file, data := range contents {
		path := filepath.Join(dest, file)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return err
		}
		mode := os.FileMode(0644)
		if file == ".env" || file == ".vscode/launch.json" {
			mode = 0600
		}
		if err := os.WriteFile(path, data, mode); err != nil {
			return err
		}
	}
	complete = true
	if !noGit {
		if git, err := app.Resolver.Resolve("git"); err == nil {
			for _, arguments := range [][]string{{"init", "-q"}, {"add", "-A"}, {"commit", "-q", "-m", "tesl init: scaffold " + appName + " (" + template + ")"}} {
				if err := app.Execute(ctx, Invocation{Executable: git, Args: arguments, Directory: dest, Environment: app.Environment, Stdout: app.Stdout, Stderr: app.Stderr}); err != nil {
					break
				}
			}
		}
	}
	fmt.Fprintf(app.Stdout, "Created %s (template: %s, postgres: %s).\n\n  cd %s\n  tesl check\n  tesl test\n  tesl run\n", dest, template, pgmode, strconv.Quote(name))
	return nil
}
