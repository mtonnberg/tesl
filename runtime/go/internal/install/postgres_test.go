package install

import (
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPostgresLeaseHelper(t *testing.T) {
	if os.Getenv("TESL_PG_LEASE_HELPER") != "1" {
		return
	}
	if err := os.WriteFile(os.Getenv("TESL_PG_LEASE_READY"), []byte("ready"), 0600); err != nil {
		os.Exit(2)
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(os.Getenv("TESL_PG_LEASE_STOP")); err == nil {
			os.Exit(0)
		}
		time.Sleep(10 * time.Millisecond)
	}
	os.Exit(3)
}

func TestPostgresLeaseSurvivesParentHandleAndReleasesOnExit(t *testing.T) {
	m := testManager(t)
	installFixture(t, m, "0.3.1")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ready, stop := filepath.Join(t.TempDir(), "ready"), filepath.Join(t.TempDir(), "stop")
	command := exec.Command(executable, "-test.run=^TestPostgresLeaseHelper$")
	command.Env = append(os.Environ(), "TESL_PG_LEASE_HELPER=1", "TESL_PG_LEASE_READY="+ready, "TESL_PG_LEASE_STOP="+stop)
	release, err := ConfigurePostgresLease(command, filepath.Join(m.Root, "versions", "0.3.1"))
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		release()
		t.Fatal(err)
	}
	release()
	waited := false
	t.Cleanup(func() {
		if !waited {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("lease helper never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil || !strings.Contains(err.Error(), "managed PostgreSQL") {
		t.Fatalf("inherited daemon lease did not block uninstall: %v", err)
	}
	// Process termination, including crashes, releases the kernel reference.
	if err := command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = command.Wait()
	waited = true
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err != nil {
		t.Fatalf("exited daemon left a stale lease: %v", err)
	}
}

func TestPostgresLeaseFailedStartAndCanceledCommandRelease(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		m := testManager(t)
		installFixture(t, m, "0.3.1")
		ctx, cancel := context.WithCancel(context.Background())
		if canceled {
			cancel()
		}
		command := exec.CommandContext(ctx, filepath.Join(t.TempDir(), "missing executable"))
		release, err := ConfigurePostgresLease(command, filepath.Join(m.Root, "versions", "0.3.1"))
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		err = command.Run()
		release()
		cancel()
		if err == nil || (canceled && !errors.Is(err, context.Canceled)) {
			t.Fatalf("failed command result: %v", err)
		}
		if _, err := m.Uninstall(context.Background(), "0.3.1"); err != nil {
			t.Fatalf("failed start retained a lease: %v", err)
		}
	}
}

func TestNativePostgresRetainsInstalledVersionLease(t *testing.T) {
	postgresRoot := os.Getenv("TESL_TEST_POSTGRES_ROOT")
	if postgresRoot == "" {
		t.Skip("set TESL_TEST_POSTGRES_ROOT to a native PostgreSQL component")
	}
	m := testManager(t)
	installFixture(t, m, "0.3.1")
	data := filepath.Join(t.TempDir(), "database å with spaces")
	log := filepath.Join(t.TempDir(), "postgres.log")
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, err := net.SplitHostPort(listener.Addr().String())
	_ = listener.Close()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	tool := func(name string, args ...string) *exec.Cmd {
		return exec.CommandContext(ctx, filepath.Join(postgresRoot, "bin", name+binarySuffix()), args...)
	}
	if output, err := tool("initdb", "-D", data, "-A", "trust", "-U", "tesl", "--locale=C", "--no-sync").CombinedOutput(); err != nil {
		t.Fatalf("initdb: %v\n%s", err, output)
	}
	stopped := false
	t.Cleanup(func() {
		if !stopped {
			cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cleanupCancel()
			command := exec.CommandContext(cleanupCtx, filepath.Join(postgresRoot, "bin", "pg_ctl"+binarySuffix()), "-D", data, "-m", "immediate", "-w", "stop")
			_, _ = command.CombinedOutput()
		}
	})
	command := tool("pg_ctl", "-D", data, "-l", log, "-o", "-F -p "+port+" -c listen_addresses=127.0.0.1 -c unix_socket_directories=''", "-w", "start")
	release, err := ConfigurePostgresLease(command, filepath.Join(m.Root, "versions", "0.3.1"))
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.CombinedOutput()
	release()
	if err != nil {
		serverLog, _ := os.ReadFile(log)
		t.Fatalf("pg_ctl: %v\n%s\n%s", err, output, serverLog)
	}
	if output, err := tool("psql", "-h", "127.0.0.1", "-p", port, "-U", "tesl", "-d", "postgres", "-Atc", "create table lease_persistence(value text); insert into lease_persistence values ('preserved')").CombinedOutput(); err != nil {
		t.Fatalf("psql: %v\n%s", err, output)
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil || !strings.Contains(err.Error(), "managed PostgreSQL") {
		t.Fatalf("actual postmaster did not retain inherited version lease: %v", err)
	}
	if output, err := tool("pg_ctl", "-D", data, "-m", "fast", "-w", "stop").CombinedOutput(); err != nil {
		t.Fatalf("pg_ctl stop: %v\n%s", err, output)
	}
	stopped = true
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err != nil {
		t.Fatalf("stopped postmaster left a stale lease: %v", err)
	}
	if _, err := os.Stat(filepath.Join(data, "PG_VERSION")); err != nil {
		t.Fatalf("uninstall removed project database: %v", err)
	}
	stopped = false
	if output, err := tool("pg_ctl", "-D", data, "-l", log, "-o", "-F -p "+port+" -c listen_addresses=127.0.0.1 -c unix_socket_directories=''", "-w", "start").CombinedOutput(); err != nil {
		t.Fatalf("restart preserved database: %v\n%s", err, output)
	}
	if output, err := tool("psql", "-h", "127.0.0.1", "-p", port, "-U", "tesl", "-d", "postgres", "-Atc", "select value from lease_persistence").CombinedOutput(); err != nil || strings.TrimSpace(string(output)) != "preserved" {
		t.Fatalf("database row did not survive stop/uninstall/restart: %v\n%s", err, output)
	}
	if output, err := tool("pg_ctl", "-D", data, "-m", "fast", "-w", "stop").CombinedOutput(); err != nil {
		t.Fatalf("stop restarted database: %v\n%s", err, output)
	}
	stopped = true
}
