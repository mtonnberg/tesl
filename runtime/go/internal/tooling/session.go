package tooling

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"

	"tesl.dev/runtime/go/internal/childprocess"
)

// WorkspaceSessions retains one compiler and one private project mirror per
// client. Switching roots/toolchains closes the previous session. Its gate also
// serializes mirror updates with queries; a canceled waiter cannot start work.
// Construct with NewWorkspaceSessions; Close belongs to the LSP/MCP owner.
type WorkspaceSessions struct {
	lifetime                    context.Context
	cancel                      context.CancelFunc
	gate                        chan struct{}
	closed                      bool
	root, shadow, configuration string
	sources                     map[string][]byte
	process                     *workspaceProcess
	starts, writes              uint64
}

func NewWorkspaceSessions() *WorkspaceSessions {
	ctx, cancel := context.WithCancel(context.Background())
	return &WorkspaceSessions{gate: make(chan struct{}, 1), lifetime: ctx, cancel: cancel}
}

func (sessions *WorkspaceSessions) Close() error {
	sessions.cancel()
	sessions.gate <- struct{}{}
	defer func() { <-sessions.gate }()
	sessions.closed = true
	sessions.reset()
	return nil
}

func (client Client) Close() error {
	if client.Sessions != nil {
		return client.Sessions.Close()
	}
	return nil
}

func (sessions *WorkspaceSessions) reset() {
	if sessions.process != nil {
		sessions.process.close()
		sessions.process = nil
	}
	if sessions.shadow != "" {
		_ = os.RemoveAll(sessions.shadow)
	}
	sessions.root, sessions.shadow, sessions.configuration = "", "", ""
	sessions.sources = nil
}

func sessionFlag(flag string) bool {
	return flag != "--doc-json" && (knownCompilerJSONFlag(flag) || flag == "--config-context-json")
}

func (sessions *WorkspaceSessions) query(ctx context.Context, client Client, flag, path string, overlays []SourceOverlay, position []string) ([]byte, Result, error) {
	if client.DiscoveryError != nil {
		return nil, Result{}, client.DiscoveryError
	}
	timeout := client.Timeout
	if timeout <= 0 {
		timeout = DefaultCompilerTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	stop := context.AfterFunc(sessions.lifetime, cancel)
	defer stop()
	select {
	case sessions.gate <- struct{}{}:
	case <-ctx.Done():
		return nil, Result{}, ctx.Err()
	}
	defer func() { <-sessions.gate }()
	if sessions.closed {
		return nil, Result{}, errors.New("compiler: workspace session is closed")
	}
	if err := ctx.Err(); err != nil {
		return nil, Result{}, err
	}
	root, entry, sources, err := snapshotSources(ctx, flag, path, overlays)
	if err != nil {
		return nil, Result{}, err
	}
	environment := withoutEnvironment(client.Environment, "TESL_LOGICAL_PATH")
	// Resolve through PATH before pinning a session; changed executable identity,
	// environment, root or working directory force a new process and snapshot.
	executable, err := exec.LookPath(client.Executable)
	if err != nil {
		return nil, Result{}, err
	}
	executable, err = filepath.Abs(executable)
	if err != nil {
		return nil, Result{}, err
	}
	info, err := os.Stat(executable)
	if err != nil {
		return nil, Result{}, err
	}
	config, _ := json.Marshal([]any{executable, info.Size(), info.ModTime().UnixNano(), environment, client.Directory})
	if sessions.root != root || sessions.configuration != string(config) {
		sessions.reset()
		shadow, err := os.MkdirTemp("", "tesl-workspace-*")
		if err != nil {
			return nil, Result{}, err
		}
		sessions.root, sessions.shadow, sessions.configuration = root, shadow, string(config)
	}
	// Read bytes on every query: timestamp-only invalidation misses same-size
	// saves on coarse filesystems. Only changed files are written to the mirror.
	for old := range sessions.sources {
		if _, present := sources[old]; !present {
			target, err := shadowSourcePath(root, sessions.shadow, old)
			if err != nil {
				sessions.reset()
				return nil, Result{}, err
			}
			if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
				sessions.reset()
				return nil, Result{}, err
			}
		}
	}
	for path, source := range sources {
		previous, present := sessions.sources[path]
		if !present || !bytes.Equal(previous, source) {
			if err := writeShadowSource(root, sessions.shadow, path, source); err != nil {
				sessions.reset()
				return nil, Result{}, err
			}
			sessions.writes++
		}
	}
	sessions.sources = sources
	snapshot := snapshotHash(sources)
	shadowEntry, err := shadowSourcePath(root, sessions.shadow, entry)
	if err != nil {
		return nil, Result{}, err
	}
	if err := ctx.Err(); err != nil {
		return nil, Result{}, err
	}
	if sessions.process == nil {
		process, err := startWorkspaceProcess(executable, environment, client.Directory)
		if err != nil {
			return nil, Result{}, err
		}
		sessions.process = process
		sessions.starts++
		if err := process.handshake(ctx); err != nil {
			process.close()
			sessions.process = nil
			return nil, Result{}, fmt.Errorf("compiler: workspace handshake: %w (set TESL_COMPILER_SESSION=0 for a legacy compiler)", err)
		}
	}
	payload, result, err := sessions.process.query(ctx, snapshot, flag, shadowEntry, position, client.MaxOutput)
	if err != nil {
		sessions.process.close()
		sessions.process = nil
		// Do not turn a crash/cancellation into a successful empty result or silently
		// retry a possibly stale request. The next query rebuilds compiler state.
		return nil, result, err
	}
	mapped, err := mapShadowFilePaths(payload, sessions.shadow, root)
	if err != nil {
		return nil, result, err
	}
	result.Stdout = mapped
	return mapped, result, nil
}

func snapshotHash(sources map[string][]byte) string {
	paths := make([]string, 0, len(sources))
	for path := range sources {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	hash := sha256.New()
	for _, path := range paths {
		_ = writeWorkspaceFrame(hash, []byte(path))
		_ = writeWorkspaceFrame(hash, sources[path])
	}
	return hex.EncodeToString(hash.Sum(nil))
}

type workspaceProcess struct {
	child         *childprocess.Child
	input, output *os.File
	done          chan struct{}
	stderr        *boundedSessionLog
}

type boundedSessionLog struct {
	sync.Mutex
	data []byte
}

func (log *boundedSessionLog) Write(data []byte) (int, error) {
	log.Lock()
	defer log.Unlock()
	count := min(len(data), max(0, (64<<10)-len(log.data)))
	log.data = append(log.data, data[:count]...)
	return len(data), nil
}
func (log *boundedSessionLog) String() string {
	log.Lock()
	defer log.Unlock()
	return string(log.data)
}

func startWorkspaceProcess(executable string, environment []string, directory string) (*workspaceProcess, error) {
	input, writer, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	output, outputWriter, err := os.Pipe()
	if err != nil {
		_ = input.Close()
		_ = writer.Close()
		return nil, err
	}
	stderr, stderrWriter, err := os.Pipe()
	if err != nil {
		_ = input.Close()
		_ = writer.Close()
		_ = output.Close()
		_ = outputWriter.Close()
		return nil, err
	}
	command := exec.Command(executable, "--workspace-session") // #nosec G204 -- explicit local compiler selected by the toolchain resolver.
	command.Env, command.Dir = environment, directory
	command.Stdin, command.Stdout, command.Stderr = input, outputWriter, stderrWriter
	child, err := childprocess.Start(command)
	_ = input.Close()
	_ = outputWriter.Close()
	_ = stderrWriter.Close()
	if err != nil {
		_ = writer.Close()
		_ = output.Close()
		_ = stderr.Close()
		return nil, err
	}
	process := &workspaceProcess{child: child, input: writer, output: output, done: make(chan struct{}), stderr: &boundedSessionLog{}}
	drained := make(chan struct{})
	go func() { _, _ = io.Copy(process.stderr, stderr); _ = stderr.Close(); close(drained) }()
	go func() { _ = child.Wait(); <-drained; close(process.done) }()
	return process, nil
}

func (process *workspaceProcess) close() {
	process.child.Kill()
	_ = process.input.Close()
	_ = process.output.Close()
	<-process.done
}

// perform owns all pipe I/O for a single exchange. Canceling kills the complete
// child tree, closes the pipes and waits for the I/O goroutine before returning.
func (process *workspaceProcess) perform(ctx context.Context, action func() ([]byte, error)) ([]byte, error) {
	type answer struct {
		payload []byte
		err     error
	}
	done := make(chan answer, 1)
	go func() { payload, err := action(); done <- answer{payload, err} }()
	select {
	case result := <-done:
		return result.payload, result.err
	case <-ctx.Done():
		process.child.Kill()
		_ = process.input.Close()
		_ = process.output.Close()
		<-done
		return nil, ctx.Err()
	}
}

func (process *workspaceProcess) handshake(ctx context.Context) error {
	payload, err := process.perform(ctx, func() ([]byte, error) { return readWorkspaceFrame(process.output, 4096) })
	if err != nil {
		return fmt.Errorf("%w: %s", err, process.stderr.String())
	}
	var hello struct {
		Version  int    `json:"version"`
		Protocol string `json:"protocol"`
	}
	if err := json.Unmarshal(payload, &hello); err != nil {
		return err
	}
	if hello.Version != 1 || hello.Protocol != "tesl-workspace" {
		return errors.New("unsupported workspace protocol")
	}
	return nil
}

func (process *workspaceProcess) query(ctx context.Context, snapshot, flag, path string, position []string, maxOutput int) ([]byte, Result, error) {
	line, col := "", ""
	if len(position) == 2 {
		line, col = position[0], position[1]
	} else if len(position) != 0 {
		return nil, Result{}, errors.New("compiler: invalid query position")
	}
	if maxOutput <= 0 {
		maxOutput = DefaultCompilerOutput
	}
	payload, err := process.perform(ctx, func() ([]byte, error) {
		fields := []string{snapshot, flag, path, line, col}
		limits := []int{128, 64, 4096, 20, 20}
		for i, field := range fields {
			if len(field) > limits[i] {
				return nil, errors.New("compiler: session request exceeds field limit")
			}
		}
		for _, field := range fields {
			if err := writeWorkspaceFrame(process.input, []byte(field)); err != nil {
				return nil, err
			}
		}
		return readWorkspaceFrame(process.output, min(DefaultCompilerOutput, maxOutput))
	})
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: workspace query: %w", err)
	}
	var response struct {
		Version  int             `json:"version"`
		Snapshot string          `json:"snapshot"`
		ExitCode *int            `json:"exit_code"`
		Result   json.RawMessage `json:"result"`
		Error    *string         `json:"error"`
	}
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, Result{}, err
	}
	if response.Version != 1 || response.Snapshot != snapshot || response.ExitCode == nil || *response.ExitCode < 0 || *response.ExitCode > 1 {
		return nil, Result{}, errors.New("compiler: invalid or stale workspace response")
	}
	result := Result{Stdout: response.Result, ExitCode: *response.ExitCode}
	if response.Error != nil {
		return nil, result, fmt.Errorf("compiler: workspace query: %s", *response.Error)
	}
	if len(response.Result) == 0 || bytes.Equal(response.Result, []byte("null")) {
		return nil, result, errors.New("compiler: missing workspace query result")
	}
	if err := ValidateCompilerJSON(flag, response.Result); err != nil {
		return nil, result, err
	}
	return response.Result, result, nil
}

func readWorkspaceFrame(reader io.Reader, limit int) ([]byte, error) {
	if limit < 0 || limit > DefaultCompilerOutput {
		return nil, errors.New("compiler: invalid workspace frame limit")
	}
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header[:])
	if int64(size) > int64(limit) {
		return nil, errors.New("compiler: workspace response exceeds limit")
	}
	payload := make([]byte, int(size))
	_, err := io.ReadFull(reader, payload)
	return payload, err
}

func writeWorkspaceFrame(writer io.Writer, payload []byte) error {
	if len(payload) > DefaultCompilerOutput {
		return errors.New("compiler: workspace frame exceeds limit")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload))) // #nosec G115 -- len is nonnegative and bounded to 8 MiB immediately above.
	if n, err := writer.Write(header[:]); err != nil {
		return err
	} else if n != len(header) {
		return io.ErrShortWrite
	}
	n, err := writer.Write(payload)
	if err == nil && n != len(payload) {
		return io.ErrShortWrite
	}
	return err
}
