package teslrt

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestWorkerLifetimeSIGTERMBeforeServeJoinsWorker(t *testing.T) {
	if os.Getenv("TESL_WORKER_LIFETIME_CHILD") == "1" {
		database := NewDatabase("signal", PostgresConfig{}, nil)
		connection := &PostgresDB{}
		queue := NewQueue("signal", 1)
		Enqueue(queue, "active")
		Enqueue(queue, "pending")
		started := make(chan struct{})
		withDatabaseBinding(database, connection, func() {
			StartWorkers(queue, func(value any) JobOutcome {
				if value != "active" {
					panic("pending work claimed during shutdown")
				}
				close(started)
				_, err := bufio.NewReader(os.Stdin).ReadString('\n')
				if err != nil {
					panic(err)
				}
				if database.bound() != connection || boundDatabase.Load() != database {
					panic("worker lost binding")
				}
				fmt.Println("worker-handler-finished")
				return JobOutcome{OK: true}
			}, 1, false)
			<-started
			fmt.Println("worker-ready-for-signal")
			<-currentRuntimeLifecycle().Done()
			// The database scope caught SIGTERM before Serve began. Serve must
			// inherit cancellation, avoid listening, and return into the join.
			Serve(Server{}, ServeOptions{Port: -1, ListenAddress: "127.0.0.1"})
			fmt.Println("worker-scope-draining")
		})
		if PendingJobCount(queue).String() != "1" {
			t.Fatal("pending work was not preserved")
		}
		fmt.Println("worker-scope-joined")
		return
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-test.run=^TestWorkerLifetimeSIGTERMBeforeServeJoinsWorker$", "-test.count=1")
	command.Env = append(os.Environ(), "TESL_WORKER_LIFETIME_CHILD=1")
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = input.Close() }()
	command.Stderr = command.Stdout
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	lines := make(chan string, 32)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
	}()
	waitForLine := func(want string) {
		t.Helper()
		for {
			select {
			case line, ok := <-lines:
				if !ok {
					t.Fatalf("child exited before %s", want)
				}
				if strings.Contains(line, want) {
					return
				}
			case <-ctx.Done():
				t.Fatalf("child did not reach %s", want)
			}
		}
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(time.Second):
		}
	}()
	waitForLine("worker-ready-for-signal")
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	waitForLine("worker-scope-draining")
	select {
	case err := <-done:
		t.Fatal("scope failed to retain active worker", err)
	case <-time.After(30 * time.Millisecond):
	}
	if _, err := fmt.Fprintln(input, "finish"); err != nil {
		t.Fatal(err)
	}
	waitForLine("worker-handler-finished")
	waitForLine("worker-scope-joined")
	if err := workerLifetimeReceive(t, done); err != nil {
		t.Fatal(err)
	}
}
