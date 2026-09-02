package main

import (
	"flag"
	"fmt"
	"os"

	"tesl.dev/runtime/go/internal/dap"
	"tesl.dev/runtime/go/teslrt"
)

func main() {
	socket := flag.String("socket", "", "attach directly to a Unix debug socket")
	tcp := flag.String("tcp", "", "attach directly to a loopback debug address")
	flag.Parse()
	if *socket != "" && *tcp != "" {
		fail("-socket and -tcp are mutually exclusive")
	}

	if *socket != "" || *tcp != "" {
		var backend *dap.ControlClient
		var err error
		if *socket != "" {
			backend, err = dap.DialControlUnix(*socket)
		} else {
			backend, err = dap.DialControlTCP(*tcp)
		}
		if err != nil {
			fail("connect debug endpoint: %v", err)
		}
		defer backend.Close()
		if err := dap.NewServerWithBackend(os.Stdin, os.Stdout, backend).Serve(); err != nil {
			fail("DAP server: %v", err)
		}
		return
	}

	server := dap.NewServerWithTarget(os.Stdin, os.Stdout, teslrt.NewDebugger(), dap.NewProcessTarget())
	if err := server.Serve(); err != nil {
		fail("DAP server: %v", err)
	}
}

func fail(format string, arguments ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "tesl-dap: "+format+"\n", arguments...)
	os.Exit(1)
}
