package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
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
	project := flag.String("project", "", "project directory containing .tesl-stuff/debug.sock or debug.port")
	socket := flag.String("socket", "", "Unix debug socket")
	tcp := flag.String("tcp", "", "loopback debug address")
	operation := flag.String("operation", "bridge", "bridge, once, snapshot, ping, or detach")
	bridgeOnce := flag.Bool("bridge-once", false, "process one bridge request and exit")
	once := flag.Bool("once", false, "arm breakpoints, wait for one stop, and return")
	snapshot := flag.Bool("snapshot", false, "return the current paused snapshot")
	ping := flag.Bool("ping", false, "check whether the endpoint is alive")
	detach := flag.Bool("detach", false, "resume and detach from the endpoint")
	timeoutMS := flag.Int("timeout-ms", 30000, "connection timeout in milliseconds")
	var breakAt stringFlags
	flag.Var(&breakAt, "break-at", "arm a breakpoint as FILE:LINE; repeatable")
	when := flag.String("when", "", "condition applied to each --break-at")
	hit := flag.String("hit", "", "hit condition applied to each --break-at")
	flag.Parse()
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
		fail("-timeout-ms must be positive")
	}
	if *operation != "bridge" && *operation != "once" && *operation != "snapshot" && *operation != "ping" && *operation != "detach" {
		fail("unsupported operation %q", *operation)
	}
	if *socket != "" && *tcp != "" {
		fail("-socket and -tcp are mutually exclusive")
	}
	if *socket == "" && *tcp == "" && *project == "" {
		fail("one of -project, -socket, or -tcp is required")
	}
	if *project != "" && *socket == "" && *tcp == "" {
		var err error
		*socket, *tcp, err = projectEndpoint(*project)
		if err != nil {
			fail("discover debug endpoint: %v", err)
		}
	}
	connection, err := dial(*socket, *tcp, time.Duration(*timeoutMS)*time.Millisecond)
	if err != nil {
		fail("connect debug endpoint: %v", err)
	}
	client, err := dap.NewControlClient(connection)
	if err != nil {
		fail("handshake: %v", err)
	}
	defer client.Close()
	if len(breakAt) > 0 {
		specifications := make([]teslrt.DebugBreakpointSpec, 0, len(breakAt))
		for index, value := range breakAt {
			file, line, err := parseBreakpoint(value)
			if err != nil {
				fail("invalid --break-at #%d: %v", index+1, err)
			}
			specifications = append(specifications, teslrt.DebugBreakpointSpec{
				ID: fmt.Sprintf("attach-bp-%d", index+1), File: file, Line: line,
				Condition: *when, Hit: *hit,
			})
		}
		results, err := client.SetBreakpointSpecs(specifications)
		if err != nil {
			fail("set breakpoints: %v", err)
		}
		for index, result := range results {
			if !result.Verified {
				fail("breakpoint #%d is not verified: %s", index+1, result.Message)
			}
		}
	}

	switch *operation {
	case "bridge":
		bridge(client, *bridgeOnce)
	case "ping":
		if err := client.Ping(); err != nil {
			fail("ping: %v", err)
		}
		writeJSON(map[string]any{"version": 2, "ok": true})
	case "detach":
		if err := client.Detach(); err != nil {
			fail("detach: %v", err)
		}
		writeJSON(map[string]any{"version": 2, "detached": true})
	case "snapshot":
		snapshot, err := client.SnapshotState()
		if err != nil {
			fail("snapshot: %v", err)
		}
		writeJSON(snapshotOutput(snapshot))
	case "once":
		if len(breakAt) == 0 {
			fail("once operation requires at least one --break-at")
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
				fail("snapshot after breakpoint: %v", err)
			}
			writeJSON(snapshotOutput(snapshot))
			_ = client.Continue()
		case <-time.After(time.Duration(*timeoutMS) * time.Millisecond):
			writeJSON(map[string]any{"version": 2, "stopped": false, "reason": "breakpoint-not-hit"})
		}
	}
}

func bridge(client *dap.ControlClient, once bool) {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request struct {
			Command     string                       `json:"command"`
			Breakpoints []teslrt.DebugBreakpointSpec `json:"breakpoints,omitempty"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			writeJSON(map[string]any{"error": err.Error()})
		} else {
			switch request.Command {
			case "ping":
				writeJSON(map[string]any{"ok": client.Ping() == nil})
			case "set-breakpoints":
				result, err := client.SetBreakpointSpecs(request.Breakpoints)
				writeJSON(map[string]any{"result": result, "error": errorText(err)})
			case "clear-breakpoints":
				err := client.ClearBreakpoints()
				writeJSON(map[string]any{"ok": err == nil, "error": errorText(err)})
			case "continue":
				err := client.Continue()
				writeJSON(map[string]any{"ok": err == nil, "error": errorText(err)})
			case "snapshot":
				snapshot, err := client.SnapshotState()
				if err != nil {
					writeJSON(map[string]any{"error": err.Error()})
				} else {
					writeJSON(snapshotOutput(snapshot))
				}
			case "detach":
				_ = client.Detach()
				writeJSON(map[string]any{"detached": true})
				return
			default:
				writeJSON(map[string]any{"error": "unsupported command: " + request.Command})
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
	contents, err := os.ReadFile(filepath.Join(stuff, "debug.port"))
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

func writeJSON(value any) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fail("write JSON: %v", err)
	}
}

func fail(format string, arguments ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "tesl-debug-attach: "+format+"\n", arguments...)
	os.Exit(1)
}
