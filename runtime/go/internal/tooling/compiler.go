// Package tooling contains process clients shared by the Go editor tools.
package tooling

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"sync"
	"time"

	"tesl.dev/runtime/go/internal/childprocess"
)

const (
	DefaultCompilerTimeout = 15 * time.Second
	DefaultCompilerOutput  = 8 << 20
)

type Client struct {
	Sessions       *WorkspaceSessions
	DiscoveryError error
	Executable     string
	Timeout        time.Duration
	MaxOutput      int
	Environment    []string
	Directory      string
}

type Result struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

func (client Client) Run(ctx context.Context, args ...string) (Result, error) {
	if client.DiscoveryError != nil {
		return Result{}, client.DiscoveryError
	}
	if client.Executable == "" {
		return Result{}, errors.New("compiler: executable is empty")
	}
	timeout := client.Timeout
	if timeout <= 0 {
		timeout = DefaultCompilerTimeout
	}
	maxOutput := client.MaxOutput
	if maxOutput <= 0 {
		maxOutput = DefaultCompilerOutput
	}
	queryContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := exec.CommandContext(queryContext, client.Executable, args...) // #nosec G204 -- compiler is an explicit local tool.
	command.Dir = client.Directory
	command.Env = append([]string(nil), client.Environment...)
	if command.Env == nil {
		command.Env = os.Environ()
	}
	// Own these pipes separately from exec.Cmd. Wait must observe parent exit
	// and close its process group/job even if a descendant inherited stdout;
	// conversely, Cmd.Wait must not close a reader before its output is drained.
	stdout, stdoutWriter, err := os.Pipe()
	if err != nil {
		return Result{}, fmt.Errorf("compiler: stdout pipe: %w", err)
	}
	defer func() { _ = stdout.Close() }()
	defer func() { _ = stdoutWriter.Close() }()
	stderr, stderrWriter, err := os.Pipe()
	if err != nil {
		return Result{}, fmt.Errorf("compiler: stderr pipe: %w", err)
	}
	defer func() { _ = stderr.Close() }()
	defer func() { _ = stderrWriter.Close() }()
	command.Stdout, command.Stderr = stdoutWriter, stderrWriter
	child, err := childprocess.Start(command)
	if err != nil {
		return Result{}, fmt.Errorf("compiler: start: %w", err)
	}
	_ = stdoutWriter.Close()
	_ = stderrWriter.Close()
	processDone := make(chan struct{})
	go func() {
		select {
		case <-queryContext.Done():
			child.Kill()
		case <-processDone:
		}
	}()

	var wait sync.WaitGroup
	wait.Add(2)
	var output, diagnostics []byte
	var outputErr, diagnosticsErr error
	go func() {
		defer wait.Done()
		output, outputErr = readBounded(stdout, maxOutput)
	}()
	go func() {
		defer wait.Done()
		diagnostics, diagnosticsErr = readBounded(stderr, maxOutput)
	}()
	waitErr := child.Wait()
	close(processDone)
	wait.Wait()
	result := Result{Stdout: output, Stderr: diagnostics, ExitCode: exitCode(waitErr)}
	if outputErr != nil {
		return result, fmt.Errorf("compiler: read stdout: %w", outputErr)
	}
	if diagnosticsErr != nil {
		return result, fmt.Errorf("compiler: read stderr: %w", diagnosticsErr)
	}
	if errors.Is(queryContext.Err(), context.DeadlineExceeded) {
		return result, fmt.Errorf("compiler: query timed out after %s: %w", timeout, context.DeadlineExceeded)
	}
	if errors.Is(queryContext.Err(), context.Canceled) {
		return result, context.Canceled
	}
	if waitErr != nil {
		return result, &ProcessError{Err: waitErr, Result: result}
	}
	return result, nil
}

type ProcessError struct {
	Err    error
	Result Result
}

func (error *ProcessError) Error() string {
	return fmt.Sprintf("compiler: process failed (exit %d): %v", error.Result.ExitCode, error.Err)
}

func (error *ProcessError) Unwrap() error { return error.Err }

func (client Client) QueryJSON(ctx context.Context, args ...string) (json.RawMessage, Result, error) {
	if client.Sessions != nil && len(args) >= 2 && sessionFlag(args[0]) {
		return client.QueryFileJSON(ctx, args[0], args[1], args[2:]...)
	}
	result, runErr := client.Run(ctx, args...)
	if runErr != nil && len(bytes.TrimSpace(result.Stdout)) == 0 {
		return nil, result, runErr
	}
	decoder := json.NewDecoder(bytes.NewReader(result.Stdout))
	var payload json.RawMessage
	if err := decoder.Decode(&payload); err != nil {
		if runErr != nil {
			return nil, result, runErr
		}
		return nil, result, fmt.Errorf("compiler: invalid JSON output: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, result, errors.New("compiler: JSON output contains trailing data")
		}
		return nil, result, fmt.Errorf("compiler: invalid trailing JSON: %w", err)
	}
	// --check-json intentionally exits 1 when diagnostics contain errors. A
	// valid JSON response is still useful to an editor; callers can inspect
	// Result.ExitCode when they need the compiler status.
	if len(args) > 0 {
		if err := ValidateCompilerJSON(args[0], payload); err != nil {
			return nil, result, fmt.Errorf("compiler: invalid %s response: %w", args[0], err)
		}
	}
	return payload, result, nil
}

func readBounded(reader io.Reader, limit int) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, int64(limit)+1))
	if len(data) > limit {
		// Keep draining the pipe. Returning immediately can leave a child blocked
		// in write(2), which would make the later Wait deadlock.
		_, _ = io.Copy(io.Discard, reader)
		return nil, errors.New("output exceeds configured limit")
	}
	return data, err
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return -1
}

const compilerProtocolVersion = 1

const (
	maxDiagnosticFixDepth = 16
	maxDiagnosticFixEdits = 256
)

// ValidateCompilerJSON checks the required version-1 fields consumed by editor
// tooling. Unknown flags are left alone so QueryJSON remains usable for future
// compiler commands, while every currently consumed schema fails closed.
func ValidateCompilerJSON(flag string, payload []byte) error {
	if !knownCompilerJSONFlag(flag) {
		return nil
	}
	root, err := decodeObject(payload, "compiler response")
	if err != nil {
		return err
	}
	if version, err := requiredInt(root, "version"); err != nil {
		return err
	} else if version != compilerProtocolVersion {
		return fmt.Errorf("unsupported compiler protocol version %d", version)
	}

	switch flag {
	case "--workspace-definition-json", "--workspace-references-json", "--workspace-rename-json":
		return validateWorkspaceJSON(flag, root, payload)
	case "--search-json":
		return validateSearchResponse(root)
	case "--check-json":
		items, err := requiredArray(root, "diagnostics")
		if err != nil {
			return err
		}
		for index, raw := range items {
			diagnostic, err := valueObject(raw, fmt.Sprintf("diagnostics[%d]", index))
			if err != nil {
				return err
			}
			if err := validateDiagnostic(diagnostic, index); err != nil {
				return err
			}
		}
	case "--agent-context-json", "agent-context":
		if _, err := requiredString(root, "file"); err != nil {
			return err
		}
		if _, err := requiredString(root, "content_hash"); err != nil {
			return err
		}
		if _, ok := root["ok"].(bool); !ok {
			return errors.New("compiler response field \"ok\" must be a boolean")
		}
		if _, err := requiredString(root, "summary"); err != nil {
			return err
		}
		if err := validateObjectArray(root, "diagnostics", validateAgentDiagnostic); err != nil {
			return err
		}
		if err := validateObjectArray(root, "symbols", validateAgentSymbol); err != nil {
			return err
		}
		if err := validateObjectArray(root, "proof_obligations", validateAgentObligation); err != nil {
			return err
		}
	case "--type-at-json":
		return validateNullableObject(root, "type_at", func(value map[string]any) error {
			return validateTypedLocation(value, "type_at", true, "type")
		})
	case "--field-at-json":
		return validateNullableObject(root, "field_at", func(value map[string]any) error {
			return validateTypedLocation(value, "field_at", true, "field", "record_type", "field_type")
		})
	case "--definition-json":
		return validateNullableObject(root, "definition", func(value map[string]any) error {
			return validateLocation(value, "definition", true)
		})
	case "--type-definition-json":
		return validateNullableObject(root, "type_definition", func(value map[string]any) error {
			return validateLocation(value, "type_definition", true)
		})
	case "--signature-help-json":
		return validateNullableObject(root, "signature", validateSignature)
	case "--completions-json":
		return validateObjectArray(root, "completions", func(value map[string]any, name string) error {
			for _, field := range []string{"label", "detail", "kind"} {
				if _, err := requiredString(value, field); err != nil {
					return fmt.Errorf("%s: %w", name, err)
				}
			}
			for _, field := range []string{"module", "documentation", "sort_text"} {
				if raw, found := value[field]; found && raw != nil {
					if _, ok := raw.(string); !ok {
						return fmt.Errorf("%s.%s must be a string or null", name, field)
					}
				}
			}
			if raw, found := value["requires_import"]; found {
				if _, ok := raw.(bool); !ok {
					return fmt.Errorf("%s.requires_import must be a boolean", name)
				}
			}
			for _, field := range []string{"text_edit", "import_edit"} {
				if raw, found := value[field]; found && raw != nil {
					count := 0
					if err := validateDiagnosticFix(raw, name+"."+field, true, 0, &count); err != nil {
						return err
					}
				}
			}
			return nil
		})
	case "--occurrences-json":
		return validateObjectArray(root, "occurrences", func(value map[string]any, name string) error {
			if err := validateLocation(value, name, true); err != nil {
				return err
			}
			_, err := requiredString(value, "kind")
			return err
		})
	case "--selection-range-json":
		return validateObjectArray(root, "ranges", func(value map[string]any, name string) error {
			return validateLocation(value, name, false)
		})
	case "--local-bindings-json":
		return validateObjectArray(root, "bindings", func(value map[string]any, name string) error {
			if err := validateLocation(value, name, false); err != nil {
				return err
			}
			for _, field := range []string{"name", "type"} {
				if _, err := requiredString(value, field); err != nil {
					return fmt.Errorf("%s: %w", name, err)
				}
			}
			return nil
		})
	case "--semantic-json":
		if err := validateObjectArray(root, "records", validateSemanticRecord); err != nil {
			return err
		}
		if err := validateObjectArray(root, "adts", validateSemanticADT); err != nil {
			return err
		}
		if err := validateObjectArray(root, "functions", validateSemanticFunction); err != nil {
			return err
		}
		if err := validateObjectArray(root, "local_bindings", validateSemanticBinding); err != nil {
			return err
		}
	case "--doc-json":
		return validateObjectArray(root, "entries", func(value map[string]any, name string) error {
			for _, field := range []string{"name", "doc"} {
				if _, err := requiredString(value, field); err != nil {
					return fmt.Errorf("%s: %w", name, err)
				}
			}
			return nil
		})
	}
	return nil
}

func validateAgentDiagnostic(value map[string]any, name string) error {
	for _, field := range []string{"code", "message"} {
		if _, err := requiredNonEmptyString(value, field); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	severity, err := requiredString(value, "severity")
	if err != nil || severity != "error" && severity != "warning" && severity != "info" {
		return fmt.Errorf("%s has invalid severity", name)
	}
	if err := validateFlatRange(value, name); err != nil {
		return err
	}
	if err := validateOptionalString(value, "file", name); err != nil {
		return err
	}
	if fix, present := value["fix"]; present && fix != nil {
		count := 0
		if err := validateDiagnosticFix(fix, name+".fix", true, 0, &count); err != nil {
			return err
		}
	}
	return nil
}

func validateAgentSymbol(value map[string]any, name string) error {
	for _, field := range []string{"name", "kind", "signature"} {
		if _, err := requiredNonEmptyString(value, field); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}

func validateAgentObligation(value map[string]any, name string) error {
	for _, field := range []string{"code", "message"} {
		if _, err := requiredNonEmptyString(value, field); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	for _, field := range []string{"line", "col"} {
		position, err := requiredInt(value, field)
		if err != nil || position < 0 {
			return fmt.Errorf("%s field %q must be a non-negative integer", name, field)
		}
	}
	return validateOptionalString(value, "file", name)
}

func validateSemanticRecord(value map[string]any, name string) error {
	if _, err := requiredNonEmptyString(value, "name"); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if err := validateObjectArray(value, "fields", func(field map[string]any, fieldName string) error {
		if _, err := requiredNonEmptyString(field, "name"); err != nil {
			return fmt.Errorf("%s: %w", fieldName, err)
		}
		return nil
	}); err != nil {
		return err
	}
	return validateOptionalSemanticLocation(value, name)
}

func validateSemanticADT(value map[string]any, name string) error {
	if _, err := requiredNonEmptyString(value, "name"); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if err := validateObjectArray(value, "variants", func(variant map[string]any, variantName string) error {
		if _, err := requiredNonEmptyString(variant, "constructor"); err != nil {
			return fmt.Errorf("%s: %w", variantName, err)
		}
		return nil
	}); err != nil {
		return err
	}
	return validateOptionalSemanticLocation(value, name)
}

func validateSemanticFunction(value map[string]any, name string) error {
	for _, field := range []string{"name", "kind"} {
		if _, err := requiredNonEmptyString(value, field); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return validateOptionalSemanticLocation(value, name)
}

func validateSemanticBinding(value map[string]any, name string) error {
	if _, err := requiredNonEmptyString(value, "name"); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return validateOptionalSemanticLocation(value, name)
}

func validateOptionalSemanticLocation(value map[string]any, name string) error {
	raw, present := value["loc"]
	if !present || raw == nil {
		return nil
	}
	location, err := valueObject(raw, name+".loc")
	if err != nil {
		return err
	}
	if _, err := requiredNonEmptyString(location, "file"); err != nil {
		return fmt.Errorf("%s.loc: %w", name, err)
	}
	startLine, err := requiredInt(location, "start_line")
	if err != nil {
		return fmt.Errorf("%s.loc: %w", name, err)
	}
	startCol, err := requiredInt(location, "start_col")
	if err != nil {
		return fmt.Errorf("%s.loc: %w", name, err)
	}
	endLine, err := requiredInt(location, "end_line")
	if err != nil {
		return fmt.Errorf("%s.loc: %w", name, err)
	}
	endCol, err := requiredInt(location, "end_col")
	if err != nil {
		return fmt.Errorf("%s.loc: %w", name, err)
	}
	if startLine < 0 || startCol < 0 || endLine < startLine || endCol < 0 || endLine == startLine && endCol < startCol {
		return fmt.Errorf("%s.loc has an invalid range", name)
	}
	return nil
}

func validateFlatRange(value map[string]any, name string) error {
	line, err := requiredInt(value, "line")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	col, err := requiredInt(value, "col")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	endLine, err := requiredInt(value, "end_line")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	endCol, err := requiredInt(value, "end_col")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if line < 0 || col < 0 || endLine < line || endCol < 0 || endLine == line && endCol < col {
		return fmt.Errorf("%s has an invalid range", name)
	}
	return nil
}

func validateOptionalString(value map[string]any, field, name string) error {
	if raw, present := value[field]; present {
		text, ok := raw.(string)
		if !ok || text == "" {
			return fmt.Errorf("%s field %q must be a non-empty string", name, field)
		}
	}
	return nil
}

func knownCompilerJSONFlag(flag string) bool {
	switch flag {
	case "--check-json", "--agent-context-json", "agent-context", "--type-at-json", "--field-at-json",
		"--definition-json", "--type-definition-json", "--signature-help-json", "--completions-json",
		"--workspace-definition-json", "--workspace-references-json", "--workspace-rename-json",
		"--occurrences-json", "--selection-range-json", "--local-bindings-json", "--semantic-json", "--doc-json", "--search-json":
		return true
	default:
		return false
	}
}

func validateDiagnostic(value map[string]any, index int) error {
	name := fmt.Sprintf("diagnostics[%d]", index)
	for _, field := range []string{"file", "code", "message", "source"} {
		text, err := requiredString(value, field)
		if err != nil || text == "" {
			return fmt.Errorf("%s field %q must be a non-empty string", name, field)
		}
	}
	severity, err := requiredString(value, "severity")
	if err != nil || severity != "error" && severity != "warning" && severity != "info" {
		return fmt.Errorf("%s has invalid severity", name)
	}
	start, err := requiredPosition(value, "start")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	end, err := requiredPosition(value, "end")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if end[0] < start[0] || end[0] == start[0] && end[1] < start[1] {
		return fmt.Errorf("%s has an inverted range", name)
	}
	fix, ok := value["fix"]
	if !ok {
		return fmt.Errorf("%s is missing required field \"fix\"", name)
	}
	if fix != nil {
		count := 0
		if err := validateDiagnosticFix(fix, name+".fix", true, 0, &count); err != nil {
			return err
		}
	}
	return nil
}

func validateDiagnosticFix(raw any, name string, topLevel bool, depth int, count *int) error {
	if depth > maxDiagnosticFixDepth {
		return fmt.Errorf("%s exceeds maximum nesting depth", name)
	}
	*count = *count + 1
	if *count > maxDiagnosticFixEdits {
		return fmt.Errorf("%s exceeds maximum edit count", name)
	}
	fix, err := valueObject(raw, name)
	if err != nil {
		return err
	}
	if topLevel {
		if _, err := requiredNonEmptyString(fix, "title"); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	kind, err := requiredString(fix, "kind")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	requirePosition := func(field string) (int, error) {
		position, err := requiredInt(fix, field)
		if err != nil || position < 0 {
			return 0, fmt.Errorf("%s field %q must be a non-negative integer", name, field)
		}
		return position, nil
	}
	requireText := func(field string) error {
		if _, err := requiredString(fix, field); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		return nil
	}
	switch kind {
	case "replace_line":
		if _, err := requirePosition("line"); err != nil {
			return err
		}
		return requireText("replacement")
	case "insert_line":
		if _, err := requirePosition("line"); err != nil {
			return err
		}
		return requireText("text")
	case "replace_span":
		start, err := requirePosition("start_line")
		if err != nil {
			return err
		}
		end, err := requirePosition("end_line")
		if err != nil {
			return err
		}
		if end < start {
			return fmt.Errorf("%s has an inverted line range", name)
		}
		return requireText("replacement")
	case "replace_range":
		startLine, err := requirePosition("start_line")
		if err != nil {
			return err
		}
		startCol, err := requirePosition("start_col")
		if err != nil {
			return err
		}
		endLine, err := requirePosition("end_line")
		if err != nil {
			return err
		}
		endCol, err := requirePosition("end_col")
		if err != nil {
			return err
		}
		if endLine < startLine || endLine == startLine && endCol < startCol {
			return fmt.Errorf("%s has an inverted range", name)
		}
		return requireText("replacement")
	case "multi":
		edits, err := requiredArray(fix, "edits")
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		if len(edits) == 0 {
			return fmt.Errorf("%s field \"edits\" must not be empty", name)
		}
		for index, edit := range edits {
			if err := validateDiagnosticFix(edit, fmt.Sprintf("%s.edits[%d]", name, index), false, depth+1, count); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("%s has unsupported kind %q", name, kind)
	}
}

func validateTypedLocation(value map[string]any, name string, requireFile bool, fields ...string) error {
	if err := validateLocation(value, name, requireFile); err != nil {
		return err
	}
	for _, field := range fields {
		text, err := requiredString(value, field)
		if err != nil || text == "" {
			return fmt.Errorf("%s field %q must be a non-empty string", name, field)
		}
	}
	return nil
}

func validateLocation(value map[string]any, name string, requireFile bool) error {
	if requireFile {
		if file, err := requiredString(value, "file"); err != nil || file == "" {
			return fmt.Errorf("%s field \"file\" must be a non-empty string", name)
		}
	}
	line, err := requiredInt(value, "line")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	col, err := requiredInt(value, "col")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	endLine, err := requiredInt(value, "end_line")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	endCol, err := requiredInt(value, "end_col")
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	if line < 0 || col < 0 || endLine < line || endCol < 0 || endLine == line && endCol < col {
		return fmt.Errorf("%s has an invalid range", name)
	}
	return nil
}

func validateSignature(value map[string]any) error {
	if label, err := requiredString(value, "label"); err != nil || label == "" {
		return errors.New("signature field \"label\" must be a non-empty string")
	}
	if _, err := requiredInt(value, "active_parameter"); err != nil {
		return err
	}
	return validateObjectArray(value, "parameters", func(parameter map[string]any, name string) error {
		for _, field := range []string{"label", "type"} {
			if _, err := requiredString(parameter, field); err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
		}
		return nil
	})
}

func validateNullableObject(root map[string]any, field string, validate func(map[string]any) error) error {
	value, ok := root[field]
	if !ok {
		return fmt.Errorf("compiler response is missing required field %q", field)
	}
	if value == nil {
		return nil
	}
	object, err := valueObject(value, field)
	if err != nil {
		return err
	}
	return validate(object)
}

func validateObjectArray(root map[string]any, field string, validate func(map[string]any, string) error) error {
	items, err := requiredArray(root, field)
	if err != nil {
		return err
	}
	for index, raw := range items {
		name := fmt.Sprintf("%s[%d]", field, index)
		value, err := valueObject(raw, name)
		if err != nil {
			return err
		}
		if err := validate(value, name); err != nil {
			return err
		}
	}
	return nil
}

func requiredPosition(root map[string]any, field string) ([2]int, error) {
	value, ok := root[field]
	if !ok {
		return [2]int{}, fmt.Errorf("missing required field %q", field)
	}
	object, err := valueObject(value, field)
	if err != nil {
		return [2]int{}, err
	}
	line, err := requiredInt(object, "line")
	if err != nil || line < 0 {
		return [2]int{}, fmt.Errorf("field %q has an invalid line", field)
	}
	col, err := requiredInt(object, "col")
	if err != nil || col < 0 {
		return [2]int{}, fmt.Errorf("field %q has an invalid col", field)
	}
	return [2]int{line, col}, nil
}

func decodeObject(payload []byte, name string) (map[string]any, error) {
	var value any
	if err := json.Unmarshal(payload, &value); err != nil {
		return nil, fmt.Errorf("invalid compiler JSON: %w", err)
	}
	return valueObject(value, name)
}

func valueObject(value any, name string) (map[string]any, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be an object", name)
	}
	return object, nil
}

func requiredArray(root map[string]any, field string) ([]any, error) {
	value, ok := root[field]
	if !ok {
		return nil, fmt.Errorf("compiler response is missing required field %q", field)
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("compiler response field %q must be an array", field)
	}
	return items, nil
}

func requiredString(root map[string]any, field string) (string, error) {
	value, ok := root[field]
	if !ok {
		return "", fmt.Errorf("compiler response is missing required field %q", field)
	}
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("compiler response field %q must be a string", field)
	}
	return text, nil
}

func requiredNonEmptyString(root map[string]any, field string) (string, error) {
	text, err := requiredString(root, field)
	if err != nil {
		return "", err
	}
	if text == "" {
		return "", fmt.Errorf("compiler response field %q must be a non-empty string", field)
	}
	return text, nil
}

func requiredInt(root map[string]any, field string) (int, error) {
	value, ok := root[field]
	if !ok {
		return 0, fmt.Errorf("compiler response is missing required field %q", field)
	}
	number, ok := value.(float64)
	if !ok || math.Trunc(number) != number || number > math.MaxInt || number < math.MinInt {
		return 0, fmt.Errorf("compiler response field %q must be an integer", field)
	}
	return int(number), nil
}
