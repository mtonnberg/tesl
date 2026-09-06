package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/sourceedit"
)

const migrationUsage = `Usage: tesl migrate <entry.tesl> [--database D] [--resume]
       tesl migrate generate <entry.tesl> [--database D] [--new-revision]
       tesl migrate generate <entry.tesl> --manifest-json [--database D] [--new-revision]
       tesl migrate recover-source --project-root DIR
       tesl migrate plan <entry.tesl> [--database D] [--initial-version N]

The guided flow prepares a new revision, waits for your saved schema changes,
then refreshes migration sources and checks the application until it compiles.
--resume continues an existing undeployed revision instead of freezing the next one.
The guided flow requires an interactive terminal; use explicit commands in CI.
generate refreshes migration sources and reports the result as JSON.
--manifest-json previews the edits without writing files.
The report separates source generation from compilation: decision holes need filling.
recover-source restores an interrupted source write, or finishes committed cleanup.
plan reports PostgreSQL expansion and retained storage across checked source history.
--initial-version selects the first installed revision (default 1), not the current floor.
These commands do not connect to a database or migrate stored rows.
`

// compilerOutput bounds captured protocol data; compiler failure/oversize output
// never reaches the source writer. Preview transport itself still streams directly.
type compilerOutput struct{ buffer bytes.Buffer }

func (out *compilerOutput) Bytes() []byte { return out.buffer.Bytes() }
func (out *compilerOutput) Write(data []byte) (int, error) {
	if out.buffer.Len()+len(data) > 64<<20 {
		return 0, fmt.Errorf("migration compiler response exceeds 64 MiB")
	}
	return out.buffer.Write(data)
}
func (app *App) migrate(ctx context.Context, args []string) error {
	rest := args[1:]
	if len(rest) == 0 || slices.Equal(rest, []string{"--help"}) || slices.Equal(rest, []string{"-h"}) || slices.Equal(rest, []string{"generate", "--help"}) || slices.Equal(rest, []string{"recover-source", "--help"}) {
		_, err := fmt.Fprint(app.Stdout, migrationUsage)
		return err
	}
	if rest[0] == "recover-source" {
		if len(rest) != 3 || rest[1] != "--project-root" || rest[2] == "" {
			return fmt.Errorf("usage: tesl migrate recover-source --project-root DIR")
		}
		root, err := migrationRecoveryRoot(app.Directory, rest[2])
		if err != nil {
			return err
		}
		report, err := sourceedit.Recover(ctx, root)
		result := map[string]any{"version": 1, "kind": "migration-source-recovery", "ok": err == nil, "sourceTransaction": report}
		if err != nil {
			result["error"] = err.Error()
		}
		if writeErr := json.NewEncoder(app.Stdout).Encode(result); writeErr != nil {
			return writeErr
		}
		return err
	}
	if strings.HasSuffix(rest[0], ".tesl") || rest[0] == "--" {
		return app.migrationWizard(ctx, rest)
	}
	if rest[0] != "generate" || slices.Contains(rest, "--manifest-json") {
		return app.compiler(ctx, args...)
	}
	return app.migrationGenerate(ctx, args, nil)
}

// A host may add selection preconditions before publication. The compiler still
// owns every edit and the shared writer enforces the identical file guards.
func (app *App) migrationGenerate(ctx context.Context, args []string, validate func(*sourceedit.Preview) error) error {
	rest := args[1:]
	// The compiler owns selection, arguments, source validation and every edit.
	// The native host supplies only guarded saved-file publication and recovery.
	var output compilerOutput
	child := *app
	child.Stdout = &output
	previewArgs := append([]string{"migrate", "generate", "--manifest-json"}, rest[1:]...)
	if err := child.compiler(ctx, previewArgs...); err != nil {
		if _, writeErr := app.Stdout.Write(output.Bytes()); writeErr != nil {
			return writeErr
		}
		return err
	}
	preview, err := sourceedit.DecodePreview(output.Bytes())
	if err != nil {
		return fmt.Errorf("invalid migration compiler response: %w", err)
	}
	if validate != nil {
		if err := validate(preview); err != nil {
			return err
		}
	}
	report, applyErr := preview.Manifest().Apply(ctx)
	result := make(map[string]json.RawMessage)
	if err := json.Unmarshal(preview.JSON(), &result); err != nil {
		return err
	}
	result["kind"] = json.RawMessage(`"migration-source-application"`)
	result["ok"], _ = json.Marshal(applyErr == nil)
	result["sourceTransaction"], _ = json.Marshal(report)
	if applyErr != nil {
		result["error"], _ = json.Marshal(applyErr.Error())
	}
	if err := json.NewEncoder(app.Stdout).Encode(result); err != nil {
		return err
	}
	return applyErr
}

// Check components before lexical normalization: alias/.. must not silently
// select a different recovery journal from the path supplied by the caller.
func migrationRecoveryRoot(base, spelling string) (string, error) {
	if spelling == "" || !utf8.ValidString(spelling) || strings.ContainsRune(spelling, 0) {
		return "", fmt.Errorf("invalid recovery project path")
	}
	absolute := spelling
	if !filepath.IsAbs(absolute) {
		absolute = base + string(filepath.Separator) + absolute
	}
	volume := filepath.VolumeName(absolute)
	current := volume + string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(absolute, volume), string(filepath.Separator)) {
		switch component {
		case "", ".":
			continue
		case "..":
			current = filepath.Dir(current)
		default:
			current = filepath.Join(current, component)
		}
		info, err := os.Lstat(current)
		if err != nil {
			return "", err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("recovery project path must contain only real directories: %s", current)
		}
	}
	return current, nil
}
