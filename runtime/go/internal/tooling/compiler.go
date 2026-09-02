// Package tooling contains process clients shared by the Go editor tools.
package tooling

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

const (
	DefaultCompilerTimeout = 15 * time.Second
	DefaultCompilerOutput  = 8 << 20
)

type Client struct {
	Executable  string
	Timeout     time.Duration
	MaxOutput   int
	Environment []string
	Directory   string
}

type Result struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

func (client Client) Run(ctx context.Context, args ...string) (Result, error) {
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
	configureProcess(command)
	command.Dir = client.Directory
	command.Env = append([]string(nil), client.Environment...)
	if command.Env == nil {
		command.Env = os.Environ()
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return Result{}, fmt.Errorf("compiler: stdout pipe: %w", err)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		return Result{}, fmt.Errorf("compiler: stderr pipe: %w", err)
	}
	if err := command.Start(); err != nil {
		return Result{}, fmt.Errorf("compiler: start: %w", err)
	}
	processDone := make(chan struct{})
	go func() {
		select {
		case <-queryContext.Done():
			terminateProcess(command)
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
	wait.Wait()
	waitErr := command.Wait()
	close(processDone)
	result := Result{Stdout: output, Stderr: diagnostics, ExitCode: exitCode(waitErr)}
	if outputErr != nil {
		return result, fmt.Errorf("compiler: read stdout: %w", outputErr)
	}
	if diagnosticsErr != nil {
		return result, fmt.Errorf("compiler: read stderr: %w", diagnosticsErr)
	}
	if errors.Is(queryContext.Err(), context.DeadlineExceeded) {
		return result, fmt.Errorf("compiler: query timed out after %s", timeout)
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
