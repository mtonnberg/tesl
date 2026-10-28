package teslrt

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestPgRowForwardCompiledCalibration(t *testing.T) {
	root := os.Getenv("TESL_ROW_FORWARD_CALIBRATION")
	if root == "" {
		t.Skip("separate compiler-emitted calibration artifacts required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	run := func(version, mode string, ok bool) []byte { return pgForwardNativeRun(t, f, root, version, mode, ok) }
	run("v1", "install", true)
	run("v1", "worker", true)
	run("v1", "observe", true)
	if _, err := request.Exec(f.ctx, `insert into notes.notes(id,author,title) values('one','original','hello'),('reject','rejected author','rejected title')`); err != nil {
		t.Fatal(err)
	}
	run("v2", "worker", true)
	run("v1", "observe", true)
	run("v2", "observe", true)
	read := run("v2", "read", true)
	if !strings.Contains(string(read), `"Owner":"original"`) || !strings.Contains(string(read), `"Count":7`) {
		t.Fatalf("wrong actual callback result: %s", read)
	}
	var processing int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 0 {
		t.Fatal("read latched ABI", processing, err)
	}
	rejected := run("v2", "reject", false)
	if !strings.Contains(string(rejected), "stored row rejected by its checked migration") {
		t.Fatalf("wrong actual Tesl rejection: %s", rejected)
	}
	var untouched bool
	if err := request.QueryRow(f.ctx, `select author='rejected author' and title='rejected title' and _tesl_v=1 and owner is null and count is null from notes.notes where id='reject'`).Scan(&untouched); err != nil || !untouched {
		t.Fatal("rejected row changed", untouched, err)
	}
	run("v2", "cancel", true)
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 0 {
		t.Fatal("canceled write latched ABI", processing, err)
	}
	var canceled int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where id='canceled'").Scan(&canceled); err != nil || canceled != 0 {
		t.Fatal("swallowed cancellation committed target DML", canceled, err)
	}
	run("v2", "insert", true)
	var author, owner string
	var marker, count int
	if err := request.QueryRow(f.ctx, `select author,owner,_tesl_v,count from notes.notes where id='two'`).Scan(&author, &owner, &marker, &count); err != nil || author != "new owner" || owner != author || marker != 2 || count != 7 {
		t.Fatal(author, owner, marker, count, err)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 1 {
		t.Fatal("target write did not latch ABI", processing, err)
	}
	if _, err := request.Exec(f.ctx, `update notes.notes set author='late author',title='late old' where id='one'`); err != nil {
		t.Fatal(err)
	}
	run("v2", "update", true)
	if err := request.QueryRow(f.ctx, `select author,owner,_tesl_v,count from notes.notes where id='one'`).Scan(&author, &owner, &marker, &count); err != nil || author != "late author" || owner != author || marker != 2 || count != 7 {
		t.Fatal("RMW did not materialize previous-generation row", author, owner, marker, count, err)
	}
	var current int
	if err := request.QueryRow(f.ctx, "select current from notes.tesl_schema_state").Scan(&current); err != nil || current != 2 {
		t.Fatal(current, err)
	}
	if _, err := request.Exec(f.ctx, `update notes.notes set title='late old' where id='one'`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.worker.Exec(f.ctx, `alter table notes.notes add column unrecorded text`); err != nil {
		t.Fatal(err)
	}
	run("v1", "observe", false)
	run("v2", "observe", false)
}

func pgForwardNativeCommand(f *pgControlTestFixture, root, version, mode string) *exec.Cmd {
	cmd := exec.CommandContext(f.ctx, filepath.Join(root, version, "app"), mode)
	ddl := f.worker.Config().ConnString()
	if mode == "install" {
		ddl = f.installer.Config().ConnString()
	}
	cmd.Env = append(os.Environ(), "GORACE=atexit_sleep_ms=0", "ROW_DATABASE="+f.worker.Config().Database, "ROW_OWNER="+f.roles.Owner, "ROW_WORKER="+f.roles.Worker, "ROW_REQUEST="+f.roles.Request, "ROW_DDL="+ddl)
	if mode != "worker" {
		cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET=")
	}
	return cmd
}
func pgForwardNativeRun(t *testing.T, f *pgControlTestFixture, root, version, mode string, ok bool) []byte {
	t.Helper()
	cmd := pgForwardNativeCommand(f, root, version, mode)
	var out []byte
	var err error
	if mode == "worker" && ok {
		var errors bytes.Buffer
		cmd.Stderr = &errors
		pipe, pipeErr := cmd.StdoutPipe()
		if pipeErr != nil {
			t.Fatal(pipeErr)
		}
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() { _ = cmd.Process.Kill() }()
		scanner := bufio.NewScanner(pipe)
		if !scanner.Scan() {
			_ = cmd.Wait()
			t.Fatalf("worker did not publish readiness: %s", errors.String())
		}
		out = append(out, scanner.Bytes()...)
		if !strings.Contains(string(out), "schema-worker-ready") {
			t.Fatalf("wrong worker output: %s", out)
		}
		if signalErr := cmd.Process.Signal(os.Interrupt); signalErr != nil {
			t.Fatal(signalErr)
		}
		err = cmd.Wait()
		out = append(out, errors.Bytes()...)
	} else {
		out, err = cmd.CombinedOutput()
	}
	if (err == nil) != ok {
		t.Fatalf("%s %s err=%v output=%s", version, mode, err, out)
	}
	t.Logf("%s %s success=%t", version, mode, err == nil)
	return out
}
