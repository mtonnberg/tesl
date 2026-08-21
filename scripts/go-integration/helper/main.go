// helper — the tiny Swiss-army server scripts/run-go-integration.sh needs to
// prove the full HTTP chain without depending on python3, curl, or nc.
//
// Subcommands:
//
//	upstream   serve on 127.0.0.1:0; GET answers "upstream-ok", POST echoes
//	           the body; prints "READY <addr>" once listening and serves until
//	           killed.
//	freeport   print a free TCP port number (bind :0, read it back, close).
//	get <url>  GET the URL; print "<status> <body>" on one line.
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: helper upstream|freeport|get <url>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "upstream":
		runUpstream()
	case "freeport":
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		addr := listener.Addr().(*net.TCPAddr)
		_ = listener.Close()
		fmt.Println(addr.Port)
	case "get":
		if len(os.Args) != 3 {
			fmt.Fprintln(os.Stderr, "usage: helper get <url>")
			os.Exit(2)
		}
		resp, err := http.Get(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer func() { _ = resp.Body.Close() }()
		body, _ := io.ReadAll(resp.Body)
		fmt.Printf("%d %s\n", resp.StatusCode, strings.TrimSpace(string(body)))
	default:
		fmt.Fprintln(os.Stderr, "unknown subcommand:", os.Args[1])
		os.Exit(2)
	}
}

func runUpstream() {
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			raw, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "text/plain")
			_, _ = fmt.Fprintf(w, "echo:%s", strings.TrimSpace(string(raw)))
		default:
			_, _ = io.WriteString(w, "upstream-ok")
		}
	})}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("READY %s\n", listener.Addr())
	go func() { _ = server.Serve(listener) }()
	select {} // serve until killed
}
