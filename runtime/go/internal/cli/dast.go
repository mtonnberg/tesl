package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type dastOptions struct {
	Target, File, Server, Spec, Report, Scanner, Port, AuthorizationEnv, CookieEnv string
	Active, AllowRemote                                                            bool
}

func parseDAST(args []string) (dastOptions, error) {
	options := dastOptions{Scanner: "zap"}
	for len(args) > 0 {
		arg := args[0]
		args = args[1:]
		switch arg {
		case "--active":
			options.Active = true
		case "--allow-remote":
			options.AllowRemote = true
		case "--server", "--target", "--spec", "--report-dir", "--scanner", "--zap-port", "--authorization-env", "--cookie-env":
			if len(args) == 0 {
				return options, fmt.Errorf("%s requires a value", arg)
			}
			value := args[0]
			args = args[1:]
			switch arg {
			case "--server":
				options.Server = value
			case "--target":
				options.Target = value
			case "--spec":
				options.Spec = value
			case "--report-dir":
				options.Report = value
			case "--scanner":
				options.Scanner = value
			case "--zap-port":
				options.Port = value
			case "--authorization-env":
				options.AuthorizationEnv = value
			case "--cookie-env":
				options.CookieEnv = value
			}
		default:
			if strings.HasPrefix(arg, "http://") || strings.HasPrefix(arg, "https://") {
				if options.Target != "" {
					return options, fmt.Errorf("multiple target URLs")
				}
				options.Target = arg
			} else if strings.HasSuffix(arg, ".tesl") {
				if options.File != "" {
					return options, fmt.Errorf("multiple source files")
				}
				options.File = arg
			} else if !strings.HasPrefix(arg, "-") && options.File != "" && options.Server == "" {
				options.Server = arg
			} else {
				return options, fmt.Errorf("unexpected dast argument: %s", arg)
			}
		}
	}
	target, err := url.Parse(options.Target)
	if err != nil || target == nil || (target.Scheme != "http" && target.Scheme != "https") || target.Hostname() == "" || target.User != nil || target.Fragment != "" {
		return options, fmt.Errorf("dast target must be an HTTP(S) URL without userinfo or a fragment")
	}
	if target.Port() != "" && !validPort(target.Port()) {
		return options, fmt.Errorf("invalid target port")
	}
	host := target.Hostname()
	ip := net.ParseIP(host)
	if options.Active && !options.AllowRemote && !strings.EqualFold(host, "localhost") && (ip == nil || !ip.IsLoopback()) {
		return options, fmt.Errorf("--active against a non-loopback target requires --allow-remote")
	}
	if options.Scanner != "zap" {
		return options, fmt.Errorf("unsupported scanner %q (supported: zap)", options.Scanner)
	}
	for _, name := range []string{options.AuthorizationEnv, options.CookieEnv} {
		if name != "" && !regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`).MatchString(name) {
			return options, fmt.Errorf("invalid authentication environment variable name")
		}
	}
	if options.Port != "" && !validPort(options.Port) {
		return options, fmt.Errorf("invalid ZAP port")
	}
	return options, nil
}

func dastPlan(options dastOptions, spec, report string) map[string]any {
	jobs := []map[string]any{}
	for _, rule := range []struct{ header, env string }{{"Authorization", options.AuthorizationEnv}, {"Cookie", options.CookieEnv}} {
		if rule.env == "" {
			continue
		}
		jobs = append(jobs, map[string]any{"type": "replacer", "parameters": map[string]any{"deleteAllRules": false}, "rules": []map[string]any{{"description": "Tesl " + rule.header + " header", "matchType": "req_header", "matchString": rule.header, "replacementString": "${" + rule.env + "}"}}})
	}
	jobs = append(jobs, map[string]any{"type": "openapi", "parameters": map[string]any{"apiFile": spec, "targetUrl": options.Target, "context": "tesl"}}, map[string]any{"type": "passiveScan-wait", "parameters": map[string]any{"maxDuration": 1}})
	if options.Active {
		jobs = append(jobs, map[string]any{"type": "activeScan", "parameters": map[string]any{"context": "tesl", "defaultStrength": "Low", "defaultThreshold": "Medium", "maxScanDurationInMins": 1, "delayInMs": 100}})
	}
	jobs = append(jobs, map[string]any{"type": "report", "parameters": map[string]any{"template": "traditional-json", "reportDir": report, "reportFile": "zap-report.json"}}, map[string]any{"type": "exitStatus", "parameters": map[string]any{"errorLevel": "High", "warnLevel": "Medium", "errorExitValue": 1, "warnExitValue": 1, "okExitValue": 0}})
	return map[string]any{"env": map[string]any{"contexts": []map[string]any{{"name": "tesl", "urls": []string{options.Target}, "includePaths": []string{"^" + regexp.QuoteMeta(strings.TrimRight(options.Target, "/")) + "(?:/.*)?$"}}}}, "jobs": jobs}
}

func (app *App) dast(ctx context.Context, args []string) error {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		_, _ = fmt.Fprintln(app.Stdout, "Usage: tesl dast <URL> [file.tesl] [--server NAME] [--spec FILE] [--active --allow-remote] [--report-dir DIR] [--authorization-env NAME] [--cookie-env NAME]")
		return nil
	}
	options, err := parseDAST(args)
	if err != nil {
		return err
	}
	for _, name := range []string{options.AuthorizationEnv, options.CookieEnv} {
		if name != "" {
			if value, _ := environmentValue(app.Environment, name); value == "" {
				return fmt.Errorf("authentication environment variable %s is unset or empty", name)
			}
		}
	}
	if options.Spec == "" && options.File == "" {
		files, err := app.files(nil)
		if err != nil {
			return err
		}
		options.File = files[0]
	}
	absolute := func(path string) string {
		if filepath.IsAbs(path) {
			return path
		}
		return filepath.Join(app.Directory, path)
	}
	root := projectRoot(app.Directory)
	if options.File != "" {
		options.File = absolute(options.File)
		source, err := os.ReadFile(options.File)
		if err != nil {
			return err
		}
		root = projectRoot(filepath.Dir(options.File))
		if options.Server == "" {
			matches := regexp.MustCompile(`(?m)^server\s+([A-Za-z_][A-Za-z0-9_]*)\s`).FindAllStringSubmatch(string(source), -1)
			if len(matches) != 1 {
				return fmt.Errorf("source must define exactly one server or use --server NAME")
			}
			options.Server = matches[0][1]
		}
	}
	if options.Report == "" {
		options.Report = filepath.Join(root, ".tesl-stuff", "dast")
	} else {
		options.Report = absolute(options.Report)
	}
	if err := os.MkdirAll(options.Report, 0700); err != nil {
		return err
	}
	work, err := os.MkdirTemp("", "tesl-dast-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(work) }()
	if options.Spec == "" {
		options.Spec = filepath.Join(work, "openapi.json")
		if err := app.compiler(ctx, "generate-openapi", options.File, options.Server, "--output", options.Spec); err != nil {
			return err
		}
	} else {
		options.Spec = absolute(options.Spec)
		if _, err := os.Stat(options.Spec); err != nil {
			return err
		}
	}
	// JSON is a YAML 1.2 document; structured encoding preserves arbitrary paths
	// and keeps authentication values out of both plan and specification files.
	plan, err := json.MarshalIndent(dastPlan(options, options.Spec, options.Report), "", "  ")
	if err != nil {
		return err
	}
	planPath := filepath.Join(work, "plan.yaml")
	if err := os.WriteFile(planPath, plan, 0600); err != nil {
		return err
	}
	if options.Port == "" {
		options.Port, _ = environmentValue(app.Environment, "TESL_ZAP_PORT")
		if options.Port == "" {
			options.Port = "8090"
		}
	}
	if !validPort(options.Port) {
		return fmt.Errorf("invalid ZAP port")
	}
	port, _ := strconv.Atoi(options.Port)
	for ; port <= 65535; port++ {
		listener, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
		if err == nil {
			_ = listener.Close()
			break
		}
	}
	if port > 65535 {
		return fmt.Errorf("no free ZAP port")
	}
	_, _ = fmt.Fprintf(app.Stdout, "tesl dast: scanning %s (reports: %s)\n", options.Target, options.Report)
	return app.invoke(ctx, "zap", app.Directory, app.Environment, "-dir", filepath.Join(work, "zap"), "-port", strconv.Itoa(port), "-silent", "-cmd", "-autorun", planPath)
}
