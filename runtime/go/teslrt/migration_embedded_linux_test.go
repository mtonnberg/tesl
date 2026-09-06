//go:build linux

package teslrt

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPgMigrationEmbeddedSIGTERMDuringUniqueStartup(t *testing.T) {
	const childConfig = "TESL_EMBEDDED_SIGNAL_TEST_CONFIG"
	if encoded := os.Getenv(childConfig); encoded != "" {
		var config PostgresConfig
		if err := json.Unmarshal([]byte(encoded), &config); err != nil {
			t.Fatal(err)
		}
		history := pgIndexExpansionTestHistory(config.Schema, 2, true)
		database := &Database{Name: "Main", Config: config, migrationHistory: &history}
		failure := recoverDebugSQLFailure(func() {
			WithDatabase(database, func() { t.Fatal("unique startup published before index completion") })
		})
		if failure == nil || !strings.Contains(fmt.Sprint(failure), "canceled") || database.bound() != nil {
			t.Fatalf("SIGTERM did not cancel unready Embedded scope: %v", failure)
		}
		fmt.Println("embedded-unique-startup-canceled-and-joined")
		return
	}
	t.Setenv("TESL_LEASE_TTL_S", "2")
	t.Setenv("TESL_SCHEMA_POLL_S", "1")
	f := pgNewControlTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	pgExpandIndexTest(t, f, 2, true)
	_, closeBlocker := pgEmbeddedIndexBlocker(t, f)
	defer closeBlocker()
	database := pgEmbeddedIndexDatabase(t, f, true)
	encoded, err := json.Marshal(database.Config)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.CommandContext(f.ctx, executable, "-test.run=^TestPgMigrationEmbeddedSIGTERMDuringUniqueStartup$", "-test.count=1")
	command.Env = append(os.Environ(), childConfig+"="+string(encoded))
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	joined := false
	defer func() {
		if !joined {
			_ = command.Process.Kill()
			<-done
		}
	}()
	pgEmbeddedIndexWaiting(t, f, nil)
	job := pgIndexControlTestJobs(t, f)[0]
	if job.Holder == "" || job.State != "building" {
		t.Fatalf("child has no live build ownership: %+v", job)
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		joined = true
		if err != nil || !strings.Contains(output.String(), "embedded-unique-startup-canceled-and-joined") {
			t.Fatalf("child failed controlled startup cancellation: %v\n%s", err, &output)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("SIGTERM did not join the blocked unique executor promptly")
	}
	if tags := pgEmbeddedTestTags(t, f); len(tags) != 0 {
		t.Fatalf("SIGTERM left a tagged backend/fence: %v", tags)
	}
	current := pgIndexControlTestJobs(t, f)[0]
	if current.State == "valid" || current.Token != job.Token || current.Holder != job.Holder {
		t.Fatalf("cancellation fabricated completion or replacement ownership: before=%+v after=%+v", job, current)
	}
}

func TestPgMigrationEmbeddedSIGTERMBeforeServeIsNotLost(t *testing.T) {
	const childConfig = "TESL_EMBEDDED_BODY_TEST_CONFIG"
	const readyFile = "TESL_EMBEDDED_BODY_TEST_READY"
	if encoded := os.Getenv(childConfig); encoded != "" {
		var config PostgresConfig
		if err := json.Unmarshal([]byte(encoded), &config); err != nil {
			t.Fatal(err)
		}
		history := pgExpansionTestHistory(config.Schema, 1)
		database := &Database{Name: "Main", Config: config, migrationHistory: &history}
		WithDatabase(database, func() {
			if err := os.WriteFile(os.Getenv(readyFile), []byte("body-entered"), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := bufio.NewReader(os.Stdin).ReadString('\n'); err != nil {
				t.Fatal(err)
			}
			Serve(Server{}, ServeOptions{Port: -1, ListenAddress: "127.0.0.1"})
		})
		fmt.Println("embedded-signal-before-serve-propagated")
		return
	}
	f := pgNewControlTest(t)
	f.install(t, 1)
	database := pgBootTestDatabase(t, f, 1)
	encoded, err := json.Marshal(database.Config)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	readyPath := filepath.Join(t.TempDir(), "body-ready")
	command := exec.CommandContext(f.ctx, executable, "-test.run=^TestPgMigrationEmbeddedSIGTERMBeforeServeIsNotLost$", "-test.count=1")
	command.Env = append(os.Environ(), childConfig+"="+string(encoded), readyFile+"="+readyPath)
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stdin.Close() }()
	var output bytes.Buffer
	command.Stdout, command.Stderr = &output, &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	joined := false
	defer func() {
		if !joined {
			_ = command.Process.Kill()
			<-done
		}
	}()
	pgEmbeddedTestAwait(t, f, func() bool {
		data, err := os.ReadFile(readyPath)
		return err == nil && string(data) == "body-entered"
	})
	if len(pgEmbeddedTestTags(t, f)) != 1 {
		t.Fatal("child entered without a live Embedded service")
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	// Observe actual executor shutdown while the user body remains stopped
	// before Serve. Only then let it create the server's signal subscription.
	pgEmbeddedTestAwait(t, f, func() bool { return len(pgEmbeddedTestTags(t, f)) == 0 })
	if _, err := stdin.Write([]byte("continue\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		joined = true
		if err != nil || !strings.Contains(output.String(), "embedded-signal-before-serve-propagated") {
			t.Fatalf("Serve lost the consumed shutdown signal: %v\n%s", err, &output)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Serve did not inherit the already-consumed shutdown signal")
	}
}
