package migrationtest

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"path/filepath"
	"testing"
	"time"
)

// INV-HARNESS; TR-SCHEDULE.
func TestProcessControllerPausesOnlyNamedArrival(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s := NewSchedule(nil)
	event := Event{"query-complete", "v7", 1}
	if err := s.Pause(event); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(t.TempDir(), "control.sock")
	p, err := ListenProcesses(ctx, socket, s)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	arrive := func(actor string) <-chan error {
		done := make(chan error, 1)
		go func() {
			conn, err := net.DialTimeout("unix", socket, time.Second)
			if err != nil {
				done <- err
				return
			}
			defer func() { _ = conn.Close() }()
			if err = conn.SetDeadline(time.Now().Add(4 * time.Second)); err == nil {
				_, err = fmt.Fprintf(conn, `{"version":1,"name":"query-complete","actor":%q,"occurrence":1}`+"\n", actor)
			}
			if err == nil {
				var reply string
				reply, err = bufio.NewReader(conn).ReadString('\n')
				if err == nil && reply != "continue\n" {
					err = fmt.Errorf("bad response %q", reply)
				}
			}
			done <- err
		}()
		return done
	}
	old := arrive("v7")
	if err = s.Await(ctx, event); err != nil {
		t.Fatal(err)
	}
	if err = <-arrive("v8"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-old:
		t.Fatalf("paused process returned: %v", err)
	default:
	}
	if err = s.Release(event); err != nil {
		t.Fatal(err)
	}
	if err = <-old; err != nil {
		t.Fatal(err)
	}
	p.Close()
	if errors := p.Errors(); len(errors) != 0 {
		t.Fatal(errors)
	}
}

// INV-HARNESS; TR-SCHEDULE.
func TestProcessControllerRefusesUnknownProtocol(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "control.sock")
	p, err := ListenProcesses(context.Background(), socket, NewSchedule(nil))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	if err = conn.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err = fmt.Fprintln(conn, `{"version":2,"name":"query-complete","actor":"v7","occurrence":1}`); err != nil {
		t.Fatal(err)
	}
	if response, err := bufio.NewReader(conn).ReadString('\n'); err == nil || response == "continue\n" {
		t.Fatalf("unrecognised protocol continued: %q %v", response, err)
	}
	p.Close()
	if len(p.Errors()) != 1 {
		t.Fatalf("protocol failure not recorded: %v", p.Errors())
	}
}
