package tooling

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
)

// QuerySourceJSON runs a compiler JSON query against an unsaved document. The
// source is written only to a system temporary file; TESL_LOGICAL_PATH keeps
// imports and diagnostic locations anchored to the real document path.
func (client Client) QuerySourceJSON(ctx context.Context, flag, logicalPath, source string, position ...string) ([]byte, Result, error) {
	if flag == "" || logicalPath == "" {
		return nil, Result{}, errors.New("compiler: query flag and logical path are required")
	}
	temporary, err := os.CreateTemp("", "tesl-tool-*.tesl")
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: create temporary source: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err := temporary.WriteString(source); err != nil {
		_ = temporary.Close()
		return nil, Result{}, fmt.Errorf("compiler: write temporary source: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return nil, Result{}, fmt.Errorf("compiler: close temporary source: %w", err)
	}
	queryClient := client
	queryClient.Environment = withEnvironment(client.Environment, "TESL_LOGICAL_PATH", logicalPath)
	arguments := append([]string{flag, temporaryPath}, position...)
	payload, result, err := queryClient.QueryJSON(ctx, arguments...)
	return payload, result, err
}

// QueryFileJSON is the on-disk counterpart used for saved documents.
func (client Client) QueryFileJSON(ctx context.Context, flag, filePath string, position ...string) ([]byte, Result, error) {
	if flag == "" || filePath == "" {
		return nil, Result{}, errors.New("compiler: query flag and file path are required")
	}
	arguments := append([]string{flag, filePath}, position...)
	return client.QueryJSON(ctx, arguments...)
}

// FormatSource runs the compiler's in-place formatter against a system
// temporary file and returns the resulting source. Formatting failures return
// an error without exposing the temporary path to callers.
func (client Client) FormatSource(ctx context.Context, logicalPath, source string) ([]byte, Result, error) {
	if logicalPath == "" {
		return nil, Result{}, errors.New("compiler: logical path is required")
	}
	temporary, err := os.CreateTemp("", "tesl-format-*.tesl")
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: create formatting source: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err := temporary.WriteString(source); err != nil {
		_ = temporary.Close()
		return nil, Result{}, fmt.Errorf("compiler: write formatting source: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return nil, Result{}, fmt.Errorf("compiler: close formatting source: %w", err)
	}
	formatClient := client
	formatClient.Environment = withEnvironment(client.Environment, "TESL_LOGICAL_PATH", logicalPath)
	result, err := formatClient.Run(ctx, "--fmt", temporaryPath)
	if err != nil {
		return nil, result, err
	}
	formatted, err := os.ReadFile(temporaryPath)
	if err != nil {
		return nil, result, fmt.Errorf("compiler: read formatted source: %w", err)
	}
	return formatted, result, nil
}

func withEnvironment(environment []string, name, value string) []string {
	base := environment
	if base == nil {
		base = os.Environ()
	}
	result := make([]string, 0, len(base)+1)
	found := false
	prefix := name + "="
	for _, entry := range base {
		if strings.HasPrefix(entry, prefix) {
			if !found {
				result = append(result, prefix+value)
				found = true
			}
			continue
		}
		result = append(result, entry)
	}
	if !found {
		result = append(result, prefix+value)
	}
	return result
}
