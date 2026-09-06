package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"

	"tesl.dev/runtime/go/internal/sourceedit"
)

type migrationWizardOptions struct {
	entry, database string
	resume          bool
	selection       migrationWizardSelection
}

type migrationWizardSelection struct {
	EntryFile, Database, Family, SchemaRoot string
	RevisionBefore, RevisionAfter           int
}

func parseMigrationWizard(args []string) (options migrationWizardOptions, err error) {
	if len(args) > 0 && args[0] == "--" {
		if len(args) != 2 {
			return options, fmt.Errorf("usage: tesl migrate -- <entry.tesl>")
		}
		options.entry = args[1]
		if options.entry == "" {
			return options, fmt.Errorf("an application entry file is required")
		}
		return options, nil
	}
	if len(args) == 0 || args[0] == "" {
		return options, fmt.Errorf("an application entry file is required")
	}
	options.entry = args[0]
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--resume":
			if options.resume {
				return options, fmt.Errorf("duplicate --resume")
			}
			options.resume = true
		case "--database":
			if options.database != "" || i+1 == len(args) || args[i+1] == "" || strings.HasPrefix(args[i+1], "--") {
				return options, fmt.Errorf("--database requires one database identity")
			}
			i++
			options.database = args[i]
		default:
			return options, fmt.Errorf("unexpected guided migration option %q; use migrate generate for noninteractive generation", args[i])
		}
	}
	return options, nil
}

func (options migrationWizardOptions) generateArgs(start bool) []string {
	args := []string{"migrate", "generate"}
	if options.database != "" {
		args = append(args, "--database", options.database)
	}
	if start {
		args = append(args, "--new-revision")
	}
	return append(args, "--", options.entry)
}

// Only the native terminal is implicit interactive input. A non-file reader is
// an explicit embedding/test seam, never the production os.Stdin from New.
func (app *App) migrationInteractiveInput() error {
	for _, entry := range app.Environment {
		if value, ok := strings.CutPrefix(entry, "CI="); ok && value != "" && value != "0" && !strings.EqualFold(value, "false") {
			return fmt.Errorf("guided migrations are disabled in CI; use tesl migrate generate and tesl migrate plan")
		}
	}
	if app.Stdin == nil {
		return fmt.Errorf("guided migrations require interactive input")
	}
	if file, ok := app.Stdin.(*os.File); ok && !migrationTerminal(file) {
		return fmt.Errorf("guided migrations require an interactive terminal; use tesl migrate generate and tesl migrate plan")
	}
	return nil
}

type migrationWizardDiagnostic struct {
	File      string                  `json:"file"`
	Code      string                  `json:"code"`
	Severity  string                  `json:"severity"`
	Message   string                  `json:"message"`
	Start     struct{ Line, Col int } `json:"start"`
	Line, Col int
}

type migrationWizardReport struct {
	Version     int
	Kind        string
	OK          bool
	Compilable  bool
	Selection   migrationWizardSelection
	Diagnostics struct{ Diagnostics []migrationWizardDiagnostic }
	Errors      []migrationWizardDiagnostic
	Error       string
	Manifest    struct {
		Imports []struct{ Module, SourceResolved string }
		Edits   []struct{ Path string }
	}
}

type migrationWizardDiagnosticError struct{ cause error }

func (err *migrationWizardDiagnosticError) Error() string { return err.cause.Error() }
func (err *migrationWizardDiagnosticError) Unwrap() error { return err.cause }

func (app *App) migrationWizardGenerate(ctx context.Context, options migrationWizardOptions, start bool) (report migrationWizardReport, err error) {
	var output compilerOutput
	child := *app
	child.Stdout = &output
	child.Stdin = nil // Compiler subprocesses must never consume wizard answers.
	// Reuse exactly the noninteractive guarded source writer, including manifest
	// validation, durable recovery journal, and changed-input refusal semantics.
	err = child.migrationGenerate(ctx, options.generateArgs(start), func(preview *sourceedit.Preview) error {
		var proposed migrationWizardReport
		if err := json.Unmarshal(preview.JSON(), &proposed); err != nil {
			return err
		}
		if options.resume && !start && preview.Operation() != "refresh" {
			return fmt.Errorf("there is no current migration revision to resume; run tesl migrate without --resume")
		}
		if expected := options.selection; expected.RevisionAfter != 0 {
			actual := proposed.Selection
			if preview.Operation() != "refresh" || actual.EntryFile != expected.EntryFile || actual.Database != expected.Database ||
				actual.Family != expected.Family || actual.SchemaRoot != expected.SchemaRoot ||
				actual.RevisionBefore != expected.RevisionAfter || actual.RevisionAfter != expected.RevisionAfter {
				return fmt.Errorf("guided migration selection changed while you were editing; no further source edits were applied")
			}
		}
		return nil
	})
	if decodeErr := json.Unmarshal(output.Bytes(), &report); decodeErr != nil {
		if err != nil {
			return report, err
		}
		return report, fmt.Errorf("invalid migration source application response: %w", decodeErr)
	}
	if err != nil {
		if displayErr := app.migrationWizardDiagnostics(report.Errors); displayErr != nil {
			return report, displayErr
		}
		if report.Version == 1 && report.Kind == "migration-source-preview" && !report.OK && len(report.Errors) > 0 {
			return report, &migrationWizardDiagnosticError{err}
		}
		return report, err
	}
	if report.Version != 1 || report.Kind != "migration-source-application" || !report.OK || report.Selection.RevisionAfter < 2 {
		return report, fmt.Errorf("compiler did not return a successful supported migration source application")
	}
	return report, nil
}

func (app *App) migrationWizardDiagnostics(diagnostics []migrationWizardDiagnostic) error {
	for _, diagnostic := range diagnostics {
		line, col := diagnostic.Start.Line, diagnostic.Start.Col
		if diagnostic.Line != 0 || diagnostic.Col != 0 {
			line, col = diagnostic.Line, diagnostic.Col
		}
		if _, err := fmt.Fprintf(app.Stdout, "  %s:%d:%d %s %s\n", strconv.Quote(diagnostic.File), line+1, col+1, diagnostic.Code, diagnostic.Message); err != nil {
			return err
		}
	}
	return nil
}

func (app *App) migrationWizardPrompt(ctx context.Context, prompt string) (bool, error) {
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if _, err := fmt.Fprint(app.Stdout, prompt+" [Enter/q]: "); err != nil {
			return false, err
		}
		line, err := migrationReadLine(ctx, app.Stdin)
		if err != nil {
			return false, fmt.Errorf("guided migration stopped; prepared files remain saved (continue with --resume): %w", err)
		}
		switch strings.TrimSpace(line) {
		case "":
			return true, nil
		case "q", "Q":
			_, err := fmt.Fprintln(app.Stdout, "Stopped. Prepared files remain saved; use --resume to continue this undeployed revision.")
			return false, err
		default:
			if _, err := fmt.Fprintln(app.Stdout, "Press Enter after saving, or q to stop."); err != nil {
				return false, err
			}
		}
	}
}

func migrationReadLine(ctx context.Context, reader io.Reader) (string, error) {
	var line strings.Builder
	for line.Len() < 4096 {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if file, ok := reader.(*os.File); ok {
			if err := migrationWaitInput(ctx, file); err != nil {
				return "", err
			}
		}
		var next [1]byte
		n, err := reader.Read(next[:])
		if n > 0 {
			if next[0] == '\n' {
				return line.String(), nil
			}
			line.WriteByte(next[0])
		}
		if err != nil {
			return "", err
		}
		if n == 0 {
			return "", io.ErrNoProgress
		}
	}
	return "", fmt.Errorf("guided migration input exceeds 4096 bytes")
}

func (app *App) migrationWizard(ctx context.Context, args []string) error {
	options, err := parseMigrationWizard(args)
	if err != nil {
		return err
	}
	if err := app.migrationInteractiveInput(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	var report migrationWizardReport
	for {
		report, err = app.migrationWizardGenerate(ctx, options, !options.resume)
		if err == nil {
			break
		}
		var diagnostic *migrationWizardDiagnosticError
		if !options.resume || !errors.As(err, &diagnostic) {
			return err
		}
		proceed, err := app.migrationWizardPrompt(ctx, "Resolve the saved revision diagnostics above, then save")
		if err != nil || !proceed {
			return err
		}
	}
	options.selection = report.Selection
	options.database = report.Selection.Database
	if _, err := fmt.Fprintf(app.Stdout, "Prepared %s revision V%d.\n", report.Selection.Database, report.Selection.RevisionAfter); err != nil {
		return err
	}
	for _, edit := range report.Manifest.Edits {
		if _, err := fmt.Fprintf(app.Stdout, "  %s\n", strconv.Quote(edit.Path)); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintln(app.Stdout, "Current schema files to edit:"); err != nil {
		return err
	}
	for _, path := range migrationWizardCurrentPaths(report) {
		if _, err := fmt.Fprintf(app.Stdout, "  %s\n", strconv.Quote(path)); err != nil {
			return err
		}
	}
	if err := app.migrationWizardDiagnostics(report.Diagnostics.Diagnostics); err != nil {
		return err
	}
	prompt := "Edit the current schema files above and save your changes"
	if options.resume && !report.Compilable {
		prompt = "Resolve the diagnostics in your schema or current migration, then save"
	}
	for {
		proceed, err := app.migrationWizardPrompt(ctx, prompt)
		if err != nil || !proceed {
			return err
		}
		report, err = app.migrationWizardGenerate(ctx, options, false)
		if err != nil {
			var diagnostic *migrationWizardDiagnosticError
			if errors.As(err, &diagnostic) {
				prompt = "Resolve the generation diagnostics above, then save"
				continue
			}
			return err
		}
		if err := app.migrationWizardDiagnostics(report.Diagnostics.Diagnostics); err != nil {
			return err
		}
		if !report.Compilable {
			prompt = "Fill the migration decisions and resolve the diagnostics above, then save"
			continue
		}
		// Check the actual saved application after publication, including edits
		// a user may have made since the compiler prepared the guarded manifest.
		checker := *app
		checker.Stdin = nil
		if err := checker.compiler(ctx, "--check", report.Selection.EntryFile); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			var exit interface{ ExitCode() int }
			if !errors.As(err, &exit) {
				return err
			}
			prompt = "Resolve the application diagnostics, then save"
			continue
		}
		return app.migrationWizardPlan(ctx, options, report.Selection.RevisionAfter)
	}
}

func migrationWizardCurrentPaths(report migrationWizardReport) []string {
	paths := []string{}
	root := report.Selection.SchemaRoot
	for _, imported := range report.Manifest.Imports {
		if imported.SourceResolved != "" && (imported.Module == root || strings.HasPrefix(imported.Module, root+".")) {
			paths = append(paths, imported.SourceResolved)
		}
	}
	slices.Sort(paths)
	paths = slices.Compact(paths)
	if len(paths) == 0 {
		return []string{root}
	}
	return paths
}

func (app *App) migrationWizardPlan(ctx context.Context, options migrationWizardOptions, current int) error {
	var output compilerOutput
	child := *app
	child.Stdout = &output
	child.Stdin = nil
	args := []string{"migrate", "plan"}
	if options.database != "" {
		args = append(args, "--database", options.database)
	}
	err := child.compiler(ctx, append(args, "--", options.entry)...)
	var plan struct {
		Version          int
		Kind             string
		OK               bool
		Database, Family string
		Errors           []migrationWizardDiagnostic
		Steps            []struct {
			Version         int
			EpochPreserving bool
			Operations      []struct {
				Kind, Table string
				Column      struct{ Name string }
				Index       struct {
					Name   string
					Unique bool
				}
			}
		}
	}
	if decodeErr := json.Unmarshal(output.Bytes(), &plan); decodeErr != nil {
		if err != nil {
			return err
		}
		return fmt.Errorf("invalid migration plan response: %w", decodeErr)
	}
	if err != nil {
		if displayErr := app.migrationWizardDiagnostics(plan.Errors); displayErr != nil {
			return displayErr
		}
		return fmt.Errorf("migration sources compile, but PostgreSQL planning is not ready: %w", err)
	}
	if plan.Version != 1 || plan.Kind != "migration-plan-preview" || !plan.OK {
		return fmt.Errorf("compiler did not return a successful supported migration plan")
	}
	if plan.Database != options.selection.Database || plan.Family != options.selection.Family ||
		len(plan.Steps) == 0 || plan.Steps[len(plan.Steps)-1].Version != current {
		return fmt.Errorf("guided migration plan selection changed after the saved application check; review the current source before deploying")
	}
	if _, err := fmt.Fprintf(app.Stdout, "Application checks passed. PostgreSQL plan for %s V%d:\n", plan.Database, current); err != nil {
		return err
	}
	for _, step := range plan.Steps {
		if step.Version != current {
			continue
		}
		for _, operation := range step.Operations {
			object := operation.Table
			if operation.Column.Name != "" {
				object += "." + operation.Column.Name
			}
			if operation.Index.Name != "" {
				object += "." + operation.Index.Name
			}
			if _, err := fmt.Fprintf(app.Stdout, "  %s %s\n", operation.Kind, strconv.Quote(object)); err != nil {
				return err
			}
		}
	}
	_, err = fmt.Fprintln(app.Stdout, "\nReview the migration and run your application tests, then build the release.\nFor Worker deployments, start the release with --schema worker and wait for\nschema-worker-ready before rolling out request processes. Use installer credentials\nwith --schema install when provisioning or explicitly upgrading control metadata.\nThis session prepared source files; it did not connect to PostgreSQL.")
	return err
}
