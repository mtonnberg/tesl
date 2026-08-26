package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tesl.dev/runtime/go/internal/dap"
	"tesl.dev/runtime/go/teslrt"
)

type local struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Value string `json:"value"`
}

type output struct {
	Version int    `json:"version"`
	Stopped bool   `json:"stopped"`
	Reason  string `json:"reason,omitempty"`
	Source  *struct {
		File string `json:"file"`
		Line int    `json:"line"`
	} `json:"source,omitempty"`
	Locals []local                 `json:"locals"`
	Domain teslrt.DebugDomainState `json:"domain"`
	SQL    *teslrt.DebugSQLCapture `json:"sql,omitempty"`
}

type stringFlags []string

func (values *stringFlags) String() string { return strings.Join(*values, ",") }

func (values *stringFlags) Set(value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("value must not be empty")
	}
	*values = append(*values, value)
	return nil
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout))
}

// run carries the whole CLI so the lifecycle classes (timeout, EOF, re-arm,
// NDJSON streaming) are exercisable in-process against a real control server.
// It returns the process exit code; stdout/stderr are injectable for tests.
func run(arguments []string, stdin io.Reader, stdout io.Writer) int {
	flags := flag.NewFlagSet("tesl-debug-attach", flag.ContinueOnError)
	project := flags.String("project", "", "project directory containing .tesl-stuff/debug.sock or debug.port")
	socket := flags.String("socket", "", "Unix debug socket")
	tcp := flags.String("tcp", "", "loopback debug address")
	operation := flags.String("operation", "bridge", "bridge, once, snapshot, ping, or detach")
	bridgeOnce := flags.Bool("bridge-once", false, "process one bridge request and exit")
	once := flags.Bool("once", false, "arm breakpoints, wait for one stop, and return")
	snapshot := flags.Bool("snapshot", false, "return the current paused snapshot")
	ping := flags.Bool("ping", false, "check whether the endpoint is alive")
	detach := flags.Bool("detach", false, "resume and detach from the endpoint")
	timeoutMS := flags.Int("timeout-ms", 30000, "connection timeout in milliseconds")
	var breakAt stringFlags
	flags.Var(&breakAt, "break-at", "arm a breakpoint as FILE:LINE; repeatable")
	when := flags.String("when", "", "condition applied to each --break-at")
	hit := flags.String("hit", "", "hit condition applied to each --break-at")
	if err := flags.Parse(arguments); err != nil {
		return fail("argument error: %v", err)
	}
	emit := func(value any) {
		_ = json.NewEncoder(stdout).Encode(value)
	}
	if *once {
		*operation = "once"
	} else if *snapshot {
		*operation = "snapshot"
	} else if *ping {
		*operation = "ping"
	} else if *detach {
		*operation = "detach"
	}
	if *timeoutMS < 1 {
		return fail("-timeout-ms must be positive")
	}
	if *operation != "bridge" && *operation != "once" && *operation != "snapshot" && *operation != "ping" && *operation != "detach" {
		return fail("unsupported operation %q", *operation)
	}
	if *socket != "" && *tcp != "" {
		return fail("-socket and -tcp are mutually exclusive")
	}
	if *socket == "" && *tcp == "" && *project == "" {
		return fail("one of -project, -socket, or -tcp is required")
	}
	if *project != "" && *socket == "" && *tcp == "" {
		var err error
		*socket, *tcp, err = projectEndpoint(*project)
		if err != nil {
			return fail("discover debug endpoint: %v", err)
		}
	}
	connection, err := dial(*socket, *tcp, time.Duration(*timeoutMS)*time.Millisecond)
	if err != nil {
		return fail("connect debug endpoint: %v", err)
	}
	client, err := dap.NewControlClient(connection)
	if err != nil {
		return fail("handshake: %v", err)
	}
	defer client.Close()
	if len(breakAt) > 0 {
		specifications := make([]teslrt.DebugBreakpointSpec, 0, len(breakAt))
		for index, value := range breakAt {
			file, line, err := parseBreakpoint(value)
			if err != nil {
				return fail("invalid --break-at #%d: %v", index+1, err)
			}
			specifications = append(specifications, teslrt.DebugBreakpointSpec{
				ID: fmt.Sprintf("attach-bp-%d", index+1), File: file, Line: line,
				Condition: *when, Hit: *hit,
			})
		}
		results, err := client.SetBreakpointSpecs(specifications)
		if err != nil {
			return fail("set breakpoints: %v", err)
		}
		for index, result := range results {
			if !result.Verified {
				return fail("breakpoint #%d is not verified: %s", index+1, result.Message)
			}
		}
	}

	switch *operation {
	case "bridge":
		bridge(client, *bridgeOnce, stdin, emit)
	case "ping":
		if err := client.Ping(); err != nil {
			return fail("ping: %v", err)
		}
		emit(map[string]any{"version": 2, "ok": true})
	case "detach":
		if err := client.Detach(); err != nil {
			return fail("detach: %v", err)
		}
		emit(map[string]any{"version": 2, "detached": true})
	case "snapshot":
		snapshot, err := client.SnapshotState()
		if err != nil {
			return fail("snapshot: %v", err)
		}
		emit(snapshotOutput(snapshot))
	case "once":
		if len(breakAt) == 0 {
			return fail("once operation requires at least one --break-at")
		}
		stopped := make(chan struct{}, 1)
		detach := client.Attach(func(event teslrt.DebugEvent) {
			if event.Kind == "stopped" {
				select {
				case stopped <- struct{}{}:
				default:
				}
			}
		})
		defer detach()
		select {
		case <-stopped:
			snapshot, err := client.SnapshotState()
			if err != nil {
				return fail("snapshot after breakpoint: %v", err)
			}
			emit(snapshotOutput(snapshot))
			_ = client.Continue()
		case <-time.After(time.Duration(*timeoutMS) * time.Millisecond):
			// A quiet timeout is an ANSWER (the breakpoint never fired), not an
			// error: the caller reads `stopped:false` and the exit code stays 0.
			emit(map[string]any{"version": 2, "stopped": false, "reason": "breakpoint-not-hit"})
		}
	}
	return 0
}

func bridge(client *dap.ControlClient, once bool, stdin io.Reader, emit func(any)) {
	scanner := bufio.NewScanner(stdin)
	for scanner.Scan() {
		var request struct {
			Command     string                       `json:"command"`
			Breakpoints []teslrt.DebugBreakpointSpec `json:"breakpoints,omitempty"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			emit(map[string]any{"error": err.Error()})
		} else {
			switch request.Command {
			case "ping":
				emit(map[string]any{"ok": client.Ping() == nil})
			case "set-breakpoints":
				result, err := client.SetBreakpointSpecs(request.Breakpoints)
				emit(map[string]any{"result": result, "error": errorText(err)})
			case "clear-breakpoints":
				err := client.ClearBreakpoints()
				emit(map[string]any{"ok": err == nil, "error": errorText(err)})
			case "continue":
				err := client.Continue()
				emit(map[string]any{"ok": err == nil, "error": errorText(err)})
			case "snapshot":
				snapshot, err := client.SnapshotState()
				if err != nil {
					emit(map[string]any{"error": err.Error()})
				} else {
					emit(snapshotOutput(snapshot))
				}
			case "detach":
				_ = client.Detach()
				emit(map[string]any{"detached": true})
				return
			default:
				emit(map[string]any{"error": "unsupported command: " + request.Command})
			}
		}
		if once {
			return
		}
	}
}

func snapshotOutput(snapshot teslrt.DebugSnapshot) output {
	locals := make([]local, 0, len(snapshot.Frame.Locals))
	for _, value := range snapshot.Frame.Locals {
		locals = append(locals, local{Name: value.Name, Type: value.Type, Value: value.Value.Display})
	}
	result := output{Version: 2, Stopped: snapshot.Paused, Locals: locals, Domain: snapshot.Runtime.Domain, SQL: snapshot.Runtime.SQL}
	if snapshot.Frame.Location.File != "" || snapshot.Frame.Location.Line != 0 {
		result.Source = &struct {
			File string `json:"file"`
			Line int    `json:"line"`
		}{File: snapshot.Frame.Location.File, Line: snapshot.Frame.Location.Line}
	}
	return result
}

func projectEndpoint(project string) (string, string, error) {
	stuff := filepath.Join(project, ".tesl-stuff")
	socket := filepath.Join(stuff, "debug.sock")
	if _, err := os.Stat(socket); err == nil {
		return socket, "", nil
	}
	contents, err := os.ReadFile(filepath.Join(stuff, "debug.port")) // #nosec G304 -- read only the selected project's debug port.
	if err != nil {
		return "", "", err
	}
	port := strings.TrimSpace(string(contents))
	if _, err := strconv.Atoi(port); err != nil {
		return "", "", err
	}
	return "", "127.0.0.1:" + port, nil
}

func parseBreakpoint(value string) (string, int, error) {
	separator := strings.LastIndexByte(value, ':')
	if separator <= 0 || separator == len(value)-1 {
		return "", 0, fmt.Errorf("expected FILE:LINE")
	}
	line, err := strconv.Atoi(value[separator+1:])
	if err != nil || line < 1 {
		return "", 0, fmt.Errorf("line must be a positive integer")
	}
	return value[:separator], line, nil
}

func dial(socket, tcp string, timeout time.Duration) (net.Conn, error) {
	if socket != "" {
		return net.DialTimeout("unix", socket, timeout)
	}
	return net.DialTimeout("tcp4", tcp, timeout)
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func fail(format string, arguments ...any) int {
	fmt.Fprintf(os.Stderr, "tesl-debug-attach: "+format+"\n", arguments...)
	return 1
}
