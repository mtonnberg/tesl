package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"tesl.dev/runtime/go/internal/dap"
	"tesl.dev/runtime/go/teslrt"
)

type inspectSource struct {
	File string `json:"file"`
	Line int    `json:"line"`
}

type inspectBreakpoint struct {
	Line      int    `json:"line"`
	Condition string `json:"condition,omitempty"`
	Hit       string `json:"hit,omitempty"`
}

type inspectLocal struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Value string `json:"value"`
}

type inspectOutput struct {
	Version    int                     `json:"version"`
	Stopped    bool                    `json:"stopped"`
	Reason     string                  `json:"reason,omitempty"`
	Source     *inspectSource          `json:"source,omitempty"`
	Breakpoint *inspectBreakpoint      `json:"breakpoint,omitempty"`
	Locals     []inspectLocal          `json:"locals"`
	Domain     teslrt.DebugDomainState `json:"domain"`
	SQL        *teslrt.DebugSQLCapture `json:"sql,omitempty"`
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
	socket := flag.String("socket", "", "Unix debug socket")
	tcp := flag.String("tcp", "", "loopback debug address")
	operation := flag.String("operation", "snapshot", "snapshot, ping, or detach")
	timeoutMS := flag.Int("timeout-ms", 30000, "connection timeout in milliseconds")
	var breakAt stringFlags
	flag.Var(&breakAt, "break-at", "arm a breakpoint as FILE:LINE; repeatable")
	when := flag.String("when", "", "condition applied to each --break-at")
	hit := flag.String("hit", "", "hit condition applied to each --break-at")
	flag.Parse()
	if (*socket == "") == (*tcp == "") {
		fail("exactly one of -socket or -tcp is required")
	}
	if *timeoutMS < 1 {
		fail("-timeout-ms must be positive")
	}
	if *operation != "snapshot" && *operation != "ping" && *operation != "detach" {
		fail("unsupported operation %q", *operation)
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
	if len(breakAt) > 0 && *operation != "snapshot" {
		fail("--break-at is valid only with snapshot operation")
	}
	if len(breakAt) > 0 {
		specifications := make([]teslrt.DebugBreakpointSpec, 0, len(breakAt))
		for index, value := range breakAt {
			file, line, err := parseBreakpoint(value)
			if err != nil {
				fail("invalid --break-at #%d: %v", index+1, err)
			}
			specifications = append(specifications, teslrt.DebugBreakpointSpec{
				ID: fmt.Sprintf("inspect-bp-%d", index+1), File: file, Line: line,
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
		var breakpoint *inspectBreakpoint
		if len(breakAt) > 0 {
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
			case <-time.After(time.Duration(*timeoutMS) * time.Millisecond):
				snapshot, err := client.SnapshotState()
				if err != nil {
					fail("snapshot after breakpoint timeout: %v", err)
				}
				writeJSON(snapshotOutput(snapshot, "breakpoint-not-hit", breakpointFromFlags(breakAt, *when, *hit)))
				return
			}
			breakpoint = breakpointFromFlags(breakAt, *when, *hit)
		}
		snapshot, err := client.SnapshotState()
		if err != nil {
			fail("snapshot: %v", err)
		}
		writeJSON(snapshotOutput(snapshot, "", breakpoint))
	}
}

func snapshotOutput(snapshot teslrt.DebugSnapshot, reason string, breakpoints ...*inspectBreakpoint) inspectOutput {
	locals := make([]inspectLocal, 0, len(snapshot.Frame.Locals))
	for _, local := range snapshot.Frame.Locals {
		locals = append(locals, inspectLocal{Name: local.Name, Type: local.Type, Value: local.Value.Display})
	}
	output := inspectOutput{
		Version: 2, Stopped: snapshot.Paused, Reason: reason, Locals: locals,
		Domain: snapshot.Runtime.Domain, SQL: snapshot.Runtime.SQL,
	}
	if len(breakpoints) > 0 {
		output.Breakpoint = breakpoints[0]
	}
	if snapshot.Frame.Location.File != "" || snapshot.Frame.Location.Line != 0 {
		output.Source = &inspectSource{File: snapshot.Frame.Location.File, Line: snapshot.Frame.Location.Line}
	}
	return output
}

func breakpointFromFlags(values []string, condition, hit string) *inspectBreakpoint {
	if len(values) == 0 {
		return nil
	}
	_, line, err := parseBreakpoint(values[0])
	if err != nil {
		return nil
	}
	return &inspectBreakpoint{Line: line, Condition: condition, Hit: hit}
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

func writeJSON(value any) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fail("write JSON: %v", err)
	}
}

func fail(format string, arguments ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "tesl-debug-inspect: "+format+"\n", arguments...)
	os.Exit(1)
}
