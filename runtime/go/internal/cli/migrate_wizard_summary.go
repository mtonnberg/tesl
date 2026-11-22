package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
)

type migrationPlanIndex struct {
	Name    string
	Columns []string
	Unique  bool
}

type migrationPlanTable struct {
	Entity, Table string
	Generation    int
	Indexes       []migrationPlanIndex
}

type migrationPlanStep struct {
	Version                 int
	RequiresContractVersion *int
	Tables                  []migrationPlanTable
	Transforms              []struct {
		Entity, Table, Mode                                   string
		FromGeneration, ToGeneration, RequiresFinalGeneration int
		Fields                                                []struct {
			Target, Kind, TargetColumn             string
			Source, SourceColumn, ProofEnforcement *string
		}
	}
	CodecChanges []json.RawMessage
	Contract     *struct {
		SourceFile, SourceHash string
		OperationCount         int
	}
	EpochPreserving bool
	Operations      []struct {
		Kind, Table      string
		Column           struct{ Name string }
		Index            migrationPlanIndex
		WindowRisk       *string
		RequiresContract bool
	}
}

type migrationPlanPreview struct {
	Version          int
	Kind             string
	OK               bool
	Database, Family string
	Errors           []migrationWizardDiagnostic
	PlanType         string
	Executable       *bool
	InitialVersion   int
	Steps            []migrationPlanStep
}

func migrationIndexText(table string, index migrationPlanIndex) string {
	kind := "index"
	if index.Unique {
		kind = "unique index"
	}
	return fmt.Sprintf("%s %s on %s (%s)", kind, strconv.Quote(index.Name), strconv.Quote(table), strings.Join(index.Columns, ", "))
}

// Table and index changes of a row-history step, from the difference between
// its declared inventory and the previous revision's.
func migrationRowInventoryChanges(previous, current *migrationPlanStep) []string {
	if previous == nil {
		return nil
	}
	tables := func(step *migrationPlanStep) map[string]migrationPlanTable {
		result := map[string]migrationPlanTable{}
		for _, table := range step.Tables {
			result[table.Table] = table
		}
		return result
	}
	before, after := tables(previous), tables(current)
	var lines []string
	for _, table := range current.Tables {
		old, existed := before[table.Table]
		if !existed {
			lines = append(lines, fmt.Sprintf("create table %s for entity %s", strconv.Quote(table.Table), strconv.Quote(table.Entity)))
		}
		for _, index := range table.Indexes {
			if !slices.ContainsFunc(old.Indexes, func(other migrationPlanIndex) bool { return other.Name == index.Name }) {
				lines = append(lines, "build "+migrationIndexText(table.Table, index))
			}
		}
		for _, index := range old.Indexes {
			if existed && !slices.ContainsFunc(table.Indexes, func(other migrationPlanIndex) bool { return other.Name == index.Name }) {
				lines = append(lines, "stop using "+migrationIndexText(table.Table, index)+"; a Contract removes it")
			}
		}
	}
	for _, table := range previous.Tables {
		if _, kept := after[table.Table]; !kept {
			lines = append(lines, fmt.Sprintf("stop using table %s (entity %s); a Contract removes it", strconv.Quote(table.Table), strconv.Quote(table.Entity)))
		}
	}
	return lines
}

func migrationOperationText(kind, table, column string, index migrationPlanIndex) string {
	switch kind {
	case "create-table":
		return fmt.Sprintf("create table %s", strconv.Quote(table))
	case "add-column":
		return fmt.Sprintf("add column %s", strconv.Quote(table+"."+column))
	case "build-index-concurrently":
		return "build " + migrationIndexText(table, index) + " concurrently"
	case "retain-table":
		return fmt.Sprintf("keep table %s, no longer in the schema, until a Contract removes it", strconv.Quote(table))
	case "retain-index":
		return "keep " + migrationIndexText(table, index) + ", no longer in the schema, until a Contract removes it"
	}
	object := table
	if column != "" {
		object += "." + column
	}
	if index.Name != "" {
		object += "." + index.Name
	}
	return fmt.Sprintf("%s %s", kind, strconv.Quote(object))
}

func (app *App) migrationWizardSummary(ctx context.Context, options migrationWizardOptions, plan migrationPlanPreview, current int) error {
	out := &migrationSummaryWriter{w: app.Stdout}
	out.printf("Application checks passed. PostgreSQL plan for %s V%d:\n", plan.Database, current)
	var step, previous *migrationPlanStep
	for i := range plan.Steps {
		if plan.Steps[i].Version == current {
			step = &plan.Steps[i]
			if i > 0 {
				previous = &plan.Steps[i-1]
			}
		}
	}
	if step == nil {
		return fmt.Errorf("guided migration plan does not describe V%d", current)
	}
	rowHistory := plan.PlanType == "row-history"
	var windowRisks []string
	needsContract := false
	if rowHistory {
		if step.RequiresContractVersion != nil {
			out.printf("  Requires the prior Contract for V%d before this revision.\n", *step.RequiresContractVersion)
		}
		for _, line := range migrationRowInventoryChanges(previous, step) {
			out.printf("  %s\n", line)
			if strings.HasPrefix(line, "stop using") {
				needsContract = true
			}
		}
		for _, table := range step.Tables {
			out.printf("  entity %s: table %s, generation %d\n", strconv.Quote(table.Entity), strconv.Quote(table.Table), table.Generation)
		}
		for _, transform := range step.Transforms {
			needsContract = true
			out.printf("  %s %s: generation %d -> %d; required final generation %d\n", transform.Mode, strconv.Quote(transform.Entity), transform.FromGeneration, transform.ToGeneration, transform.RequiresFinalGeneration)
			for _, field := range transform.Fields {
				source, storage := "<computed>", "<none>"
				if field.Source != nil {
					source = strconv.Quote(*field.Source)
				}
				if field.SourceColumn != nil {
					storage = strconv.Quote(*field.SourceColumn)
				}
				out.printf("    %s %s -> %s; storage %s -> %s", field.Kind, source, strconv.Quote(field.Target), storage, strconv.Quote(field.TargetColumn))
				if field.ProofEnforcement != nil {
					out.printf("; proof enforcement: %s", strconv.Quote(*field.ProofEnforcement))
				}
				out.printf("\n")
			}
		}
		if step.Contract != nil {
			out.printf("  Checked Contract source: %s (%d operations)\n", strconv.Quote(step.Contract.SourceFile), step.Contract.OperationCount)
		}
		if len(step.CodecChanges) > 0 {
			out.printf("  %d stored codec change reports; review the full migrate plan output.\n", len(step.CodecChanges))
		}
		out.printf("This is a source preview, not persisted finality or decoder-removal evidence.\n")
	} else {
		for _, operation := range step.Operations {
			out.printf("  %s\n", migrationOperationText(operation.Kind, operation.Table, operation.Column.Name, operation.Index))
			if operation.RequiresContract || operation.Kind == "retain-table" || operation.Kind == "retain-index" {
				needsContract = true
			}
			if operation.WindowRisk != nil {
				windowRisks = append(windowRisks, migrationIndexText(operation.Table, operation.Index))
				out.printf("    window risk: %s\n", *operation.WindowRisk)
			}
		}
	}
	if out.err != nil {
		return out.err
	}

	// Next steps derived from the plan: what must happen in the database before
	// and after this release, in order.
	entry := options.entry
	transforming := rowHistory && len(step.Transforms) > 0
	closeThrough := 0
	switch {
	case rowHistory && transforming && previous != nil && len(previous.Transforms) == 0 && previous.Version >= 2:
		closeThrough = previous.Version
	case !rowHistory && !step.EpochPreserving && current >= 3:
		closeThrough = current - 1
	}
	out.printf("\nNext steps for V%d:\n", current)
	n := 0
	item := func(format string, args ...any) {
		n++
		out.printf("  %d. "+format+"\n", append([]any{n}, args...)...)
	}
	item("Review the migration and run your application tests, then build the release.")
	if step.RequiresContractVersion != nil {
		k := *step.RequiresContractVersion
		item("Before deploying V%d, the V%d Contract must have completed in the database: from the V%d release run\n       tesl run %s --schema contract V%d   (or the finite --schema deploy job)", current, k, k, entry, k)
	}
	if closeThrough > 0 {
		reason := "V" + strconv.Itoa(current) + " transforms stored rows"
		if !rowHistory {
			reason = "V" + strconv.Itoa(current) + " narrows what older versions may write"
		}
		retired := "V1"
		if closeThrough > 2 {
			retired = fmt.Sprintf("V1–V%d", closeThrough-1)
		}
		item("Before deploying V%d, close the additive epoch (%s). From the running V%d release:\n       tesl run %s --schema close-epoch --through V%d --dry-run --json\n       tesl run %s --schema close-epoch --through V%d --json\n     This permanently retires %s; stop those processes first. V%d keeps serving.",
			current, reason, closeThrough, entry, closeThrough, entry, closeThrough, retired, closeThrough)
	} else if !rowHistory && !step.EpochPreserving {
		item("V%d narrows what older versions may write; deploy it only after older application processes have stopped.", current)
	}
	for _, index := range windowRisks {
		item("Existing duplicate keys block the build of %s: the build fails and no rows are discarded. For a route with no refused writes, use staged uniqueness (manual/migration-contracts.md, \"Promoting staged uniqueness\").", index)
	}
	item("Deploy: start the release with --schema worker and wait for schema-worker-ready before rolling out request processes.\n     Use installer credentials with --schema install when provisioning or explicitly upgrading control metadata.")
	if needsContract {
		item("After every V%d request process has stopped, run the V%d Contract to retire the old storage:\n       tesl run %s --schema contract V%d   (or the finite --schema deploy job)\n     It is required before the next transforming revision.", current-1, current, entry, current)
	}
	out.printf("This session prepared source files; it did not connect to PostgreSQL.\n")
	if out.err != nil {
		return out.err
	}
	if needsContract && rowHistory && step.Contract == nil {
		return app.migrationWizardOfferContract(ctx, options, current)
	}
	return nil
}

type migrationSummaryWriter struct {
	w   io.Writer
	err error
}

func (out *migrationSummaryWriter) printf(format string, args ...any) {
	if out.err == nil {
		_, out.err = fmt.Fprintf(out.w, format, args...)
	}
}

// The Contract source is required before the next revision can start; offering
// it here avoids discovering that only through a later refusal.
func (app *App) migrationWizardOfferContract(ctx context.Context, options migrationWizardOptions, current int) error {
	command := fmt.Sprintf("tesl migrate contract %s --version %d", options.entry, current)
	if app.Stdin == nil {
		_, err := fmt.Fprintf(app.Stdout, "Generate the V%d Contract source with: %s\n", current, command)
		return err
	}
	if _, err := fmt.Fprintf(app.Stdout, "\nV%d needs Contract source (migrations/.../v%d-contract.tesl) before the next revision can start.\nGenerate it now? [Enter = yes / s = skip]: ", current, current); err != nil {
		return err
	}
	line, err := migrationReadLine(ctx, app.Stdin)
	if err != nil || strings.EqualFold(strings.TrimSpace(line), "s") {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_, writeErr := fmt.Fprintf(app.Stdout, "Skipped. Generate it later with: %s\n", command)
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		return writeErr
	}
	args := []string{"migrate", "contract", options.entry, "--version", strconv.Itoa(current)}
	if options.database != "" {
		args = append(args, "--database", options.database)
	}
	var output compilerOutput
	child := *app
	child.Stdout = &output
	child.Stdin = strings.NewReader("")
	contractErr := child.migrationGenerate(ctx, args, nil)
	var result migrationWizardReport
	if json.Unmarshal(output.Bytes(), &result) == nil && len(result.Errors) > 0 {
		if err := app.migrationWizardDiagnostics(result.Errors); err != nil {
			return err
		}
	}
	if contractErr != nil {
		return fmt.Errorf("the Contract source was not generated (run %s to retry): %w", command, contractErr)
	}
	if _, err := fmt.Fprintln(app.Stdout, "Wrote the Contract source:"); err != nil {
		return err
	}
	for _, edit := range result.Manifest.Edits {
		if _, err := fmt.Fprintf(app.Stdout, "  %s\n", strconv.Quote(edit.Path)); err != nil {
			return err
		}
	}
	_, err = fmt.Fprintf(app.Stdout, "Review it and rerun your tests; tesl migrate plan %s now lists it.\n", options.entry)
	return err
}
