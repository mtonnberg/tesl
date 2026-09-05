package cli

import (
	"bytes"
	"context"
	"fmt"
	"hash/fnv"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tesl.dev/runtime/go/internal/toolchain"
)

func freeManagedPort(seed string) (string, error) {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(seed))
	base := int(hash.Sum32() % 1000)
	for i := 0; i < 1000; i++ {
		port := strconv.Itoa(54000 + (base+i)%1000)
		listener, err := net.Listen("tcp4", "127.0.0.1:"+port)
		if err == nil {
			if err := listener.Close(); err != nil {
				return "", err
			}
			return port, nil
		}
	}
	return "", fmt.Errorf("no free managed PostgreSQL port in 54000..54999")
}

func validPort(value string) bool {
	port, err := strconv.Atoi(value)
	return err == nil && port > 0 && port <= 65535
}

func (app *App) capture(ctx context.Context, tool, directory string, args ...string) (string, error) {
	path, err := app.Resolver.Resolve(tool)
	if err != nil {
		return "", err
	}
	var output bytes.Buffer
	err = app.Execute(ctx, Invocation{Executable: path, Args: args, Directory: directory, Environment: app.Environment, Stdout: &output, Stderr: &output})
	return output.String(), err
}

func (app *App) database(ctx context.Context, root, action string) (string, error) {
	if action != "start" && action != "stop" && action != "status" {
		return "", fmt.Errorf("usage: tesl db start|stop|status")
	}
	manifest, err := readManifest(root)
	if err != nil {
		return "", err
	}
	directory := filepath.Join(root, ".tesl-postgres")
	data := filepath.Join(directory, "data")
	port := manifest.value("env", "TESL_POSTGRES_PORT", "5432")
	if saved, err := os.ReadFile(filepath.Join(directory, "PORT")); err == nil { // #nosec G304 -- fixed managed-database state path in the selected project.
		port = strings.TrimSpace(string(saved))
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if !validPort(port) {
		return "", fmt.Errorf("invalid managed PostgreSQL port: %q", port)
	}
	_, versionErr := os.Stat(filepath.Join(data, "PG_VERSION"))
	if versionErr != nil && !os.IsNotExist(versionErr) {
		return "", versionErr
	}
	if os.IsNotExist(versionErr) && action != "start" {
		_, _ = fmt.Fprintln(app.Stdout, "tesl db: no managed cluster (run tesl db start)")
		return port, nil
	}
	// Resolve required tools before creating persistent project data.
	if _, err := app.Resolver.Resolve("pg_ctl"); err != nil {
		return "", err
	}
	running := false
	if versionErr == nil {
		_, err := app.capture(ctx, "pg_ctl", root, "-D", data, "status")
		running = err == nil
	}
	if running {
		// PostgreSQL's own pid file reports its actual port. This also avoids
		// moving a running cluster when the manifest has subsequently changed.
		pid, err := os.ReadFile(filepath.Join(data, "postmaster.pid")) // #nosec G304 -- fixed PostgreSQL state filename in the selected cluster.
		if err != nil {
			return "", err
		}
		fields := strings.Split(string(pid), "\n")
		if len(fields) < 4 || !validPort(fields[3]) {
			return "", fmt.Errorf("managed PostgreSQL has an invalid postmaster.pid")
		}
		port = fields[3]
	}
	if action == "status" {
		state := "stopped"
		if running {
			state = "running"
		}
		_, _ = fmt.Fprintf(app.Stdout, "tesl db: %s (%s, port %s)\n", state, data, port)
		return port, nil
	}
	if action == "stop" {
		if running {
			if err := app.invoke(ctx, "pg_ctl", root, app.Environment, "-D", data, "-m", "fast", "-w", "stop"); err != nil {
				return "", err
			}
		}
		_, _ = fmt.Fprintln(app.Stdout, "tesl db: stopped", data)
		return port, nil
	}
	user := manifest.value("env", "TESL_POSTGRES_USER", "app")
	database := manifest.value("env", "TESL_POSTGRES_DATABASE", "app")
	if versionErr != nil {
		if _, err := app.Resolver.Resolve("initdb"); err != nil {
			return "", err
		}
		if err := os.MkdirAll(directory, 0700); err != nil {
			return "", err
		}
		if err := app.invoke(ctx, "initdb", root, app.Environment, "-D", data, "-A", "trust", "-U", user, "--locale=C"); err != nil {
			return "", err
		}
	} else {
		// Never silently start a different database major version on existing data.
		major, err := os.ReadFile(filepath.Join(data, "PG_VERSION")) // #nosec G304 -- fixed PostgreSQL state filename in the selected cluster.
		if err != nil {
			return "", err
		}
		version, err := app.capture(ctx, "pg_ctl", root, "--version")
		if err != nil {
			return "", err
		}
		fields := strings.Fields(version)
		selectedMajor := ""
		if len(fields) > 0 {
			selectedMajor, _, _ = strings.Cut(fields[len(fields)-1], ".")
		}
		if selectedMajor == "" || selectedMajor != strings.TrimSpace(string(major)) {
			return "", fmt.Errorf("managed PostgreSQL data needs major %s; selected tools report %s", strings.TrimSpace(string(major)), strings.TrimSpace(version))
		}
	}
	if !running {
		listener, err := net.Listen("tcp4", "127.0.0.1:"+port)
		if err != nil {
			port, err = freeManagedPort(data)
			if err != nil {
				return "", err
			}
		} else if err := listener.Close(); err != nil {
			return "", err
		}
		// pg_ctl's -o is parsed by PostgreSQL. Only validated numeric values and
		// fixed settings enter it; project paths remain separate native arguments.
		options := "-F -p " + port + " -c listen_addresses=127.0.0.1 -c unix_socket_directories=''"
		if err := app.invoke(ctx, "pg_ctl", root, app.Environment, "-D", data, "-l", filepath.Join(directory, "postgres.log"), "-o", options, "-w", "start"); err != nil {
			return "", err
		}
	}
	if err := os.WriteFile(filepath.Join(directory, "PORT"), []byte(port+"\n"), 0600); err != nil { // #nosec G703 -- selected project's fixed state path; validated numeric port is file content, never a path component.
		return "", err
	}
	connection := []string{"-h", "127.0.0.1", "-p", port, "-U", user}
	if _, err := app.capture(ctx, "createdb", root, append(connection, database)...); err != nil {
		if _, err := app.capture(ctx, "psql", root, append(connection, "-d", database, "-tAc", "select 1")...); err != nil {
			return "", fmt.Errorf("cannot create or reach managed database %s: %w", database, err)
		}
	}
	_, _ = fmt.Fprintf(app.Stdout, "tesl db: ready — database %s at 127.0.0.1:%s\n", database, port)
	return port, nil
}

func environmentValue(environment []string, key string) (string, bool) {
	for i := len(environment) - 1; i >= 0; i-- {
		name, value, found := strings.Cut(environment[i], "=")
		if found && strings.EqualFold(name, key) {
			return value, true
		}
	}
	return "", false
}

func (app *App) projectEnvironment(ctx context.Context, root string, autostart bool) ([]string, error) {
	env := append([]string(nil), app.Environment...)
	noDotenv, _ := environmentValue(env, "TESL_NO_DOTENV")
	if noDotenv != "1" {
		data, err := os.ReadFile(filepath.Join(root, ".env")) // #nosec G304 -- explicit project dotenv support; values are parsed, never shell-evaluated.
		if err != nil && !os.IsNotExist(err) {
			return nil, err
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "export ") {
				line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
			}
			key, value, found := strings.Cut(line, "=")
			key = strings.TrimSpace(key)
			if !found || !manifestName.MatchString(key) {
				continue
			}
			if _, exists := environmentValue(env, key); exists {
				continue
			}
			value = strings.TrimSpace(value)
			if len(value) >= 2 && (value[0] == '\'' && value[len(value)-1] == '\'' || value[0] == '"' && value[len(value)-1] == '"') {
				value = value[1 : len(value)-1]
			}
			env = toolchain.Setenv(env, key, value)
		}
	}
	manifest, err := readManifest(root)
	if os.IsNotExist(err) {
		return env, nil
	}
	if err != nil {
		return nil, err
	}
	if manifest.value("database", "mode", "none") != "managed" {
		return env, nil
	}
	port := manifest.value("env", "TESL_POSTGRES_PORT", "5432")
	if data, err := os.ReadFile(filepath.Join(root, ".tesl-postgres", "PORT")); err == nil { // #nosec G304 -- fixed managed-database state path in the selected project.
		port = strings.TrimSpace(string(data))
	}
	if !validPort(port) {
		return nil, fmt.Errorf("invalid managed PostgreSQL port: %q", port)
	}
	noStart, _ := environmentValue(env, "TESL_NO_DB_AUTOSTART")
	if autostart && noStart != "1" {
		port, err = app.database(ctx, root, "start")
		if err != nil {
			return nil, err
		}
	}
	env = toolchain.Setenv(toolchain.Setenv(env, "TESL_POSTGRES_PORT", port), "TESL_POSTGRES_HOST", "127.0.0.1")
	return env, nil
}
