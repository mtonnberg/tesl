//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// All commands below execute original ordinary-public CLI builds, including
// V1 built before history freeze. The only extra command is a Request-only
// inspection probe linked to the candidate's actual emitted MainDatabase.
func TestPgRowAdoptionOriginalPublicApplications(t *testing.T) {
	root := os.Getenv("TESL_ROW_ADOPTION_PROGRAMS")
	if root == "" {
		t.Skip("ordinary-public original adoption programs required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	command := func(version, binary string, args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, filepath.Join(root, version, binary), args...)
		config := f.worker.Config()
		ddl := config.ConnString()
		if len(args) > 1 && args[1] == "install" {
			ddl = f.installer.Config().ConnString()
		}
		cmd.Env = append(os.Environ(), "TESL_MIGRATION_TEST_SOCKET=", "ROW_CONTROL_OWNER="+f.roles.Owner, "ROW_REQUEST_ROLE="+f.roles.Request, "ROW_WORKER_ROLE="+f.roles.Worker, "ROW_DDL_CONNECTION="+ddl, "ROW_DB_NAME="+config.Database, "ROW_DB_USER="+f.roles.Request, "ROW_DB_PASSWORD="+request.Config().Password, "ROW_DB_HOST="+config.Host, "ROW_DB_PORT="+strconv.Itoa(int(config.Port)), "ADOPTION_REQUEST_CONNECTION="+request.Config().ConnString())
		return cmd
	}
	install := command("v1", "tesl-app", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("original installer: %v %s", err, out)
	}
	startWorker := func(version string) func() {
		output, stop := pgRowAdditiveProcess(t, command(version, "tesl-app", "--schema", "worker", "--json"))
		deadline := time.Now().Add(20 * time.Second)
		for !strings.Contains(output.String(), `"kind":"schema-worker-ready"`) {
			if time.Now().After(deadline) {
				t.Fatal("legacy worker readiness", output.String())
			}
			time.Sleep(20 * time.Millisecond)
		}
		return stop
	}
	startApp := func(version string) string {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := listener.Addr().String()
		_, port, _ := net.SplitHostPort(address)
		_ = listener.Close()
		cmd := command(version, "tesl-app")
		cmd.Env = append(cmd.Env, "ROW_PORT="+port)
		output, _ := pgRowAdditiveProcess(t, cmd)
		base := "http://" + address
		client := http.Client{Timeout: time.Second}
		deadline := time.Now().Add(20 * time.Second)
		for {
			response, err := client.Get(base + "/health")
			if err == nil {
				_ = response.Body.Close()
				if response.StatusCode == 200 {
					return base
				}
			}
			if time.Now().After(deadline) {
				t.Fatal("legacy app readiness", output.String())
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	// Capture immutable control/receipt bytes from an independent connection.
	// Heartbeats and ephemeral lease renewal are intentionally outside this hash.
	snapshot := func() string {
		var value string
		err := f.worker.QueryRow(ctx, `select jsonb_build_array(
   (select jsonb_agg(to_jsonb(x) order by id) from notes.tesl_schema_meta x),
   (select jsonb_agg(to_jsonb(x) order by id) from notes.tesl_schema_state x),
   (select jsonb_agg(to_jsonb(x) order by version,step,seq) from notes.tesl_schema_versions x),
   (select jsonb_agg(to_jsonb(x) order by version) from notes.tesl_schema_expansions x),
   (select jsonb_agg(to_jsonb(x) order by version,ordinal) from notes.tesl_schema_expansion_objects x),
   (select jsonb_agg(to_jsonb(x) order by version,ordinal) from notes.tesl_schema_index x))::text`).Scan(&value)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	inspect := func(want string, workerLogin bool) PgRowAdoptionSummary {
		before := snapshot()
		cmd := command("bridge", "inspect")
		if workerLogin {
			cmd.Env = append(cmd.Env, "ADOPTION_REQUEST_CONNECTION="+f.worker.Config().ConnString())
		}
		out, err := cmd.CombinedOutput()
		if after := snapshot(); after != before {
			t.Fatal("read-only inspection changed durable legacy provenance", string(out))
		}
		if want != "" {
			if err == nil || !strings.Contains(string(out), want) {
				t.Fatal("inspection wrong refusal", want, err, string(out))
			}
			return PgRowAdoptionSummary{}
		}
		if err != nil {
			t.Fatalf("inspection: %v %s", err, out)
		}
		var value PgRowAdoptionSummary
		if err := json.Unmarshal(out, &value); err != nil {
			t.Fatal(err, string(out))
		}
		return value
	}
	stopV1 := startWorker("v1")
	v1 := startApp("v1")
	call := func(base, method, path string) string { return pgCallRowAccessApp(t, ctx, base, method, path, 200) }
	call(v1, "POST", "/one")
	var uuid string
	var fence int
	if err := request.QueryRow(ctx, "select database_uuid::text,fence_ns from notes.tesl_schema_meta where id=1").Scan(&uuid, &fence); err != nil {
		t.Fatal(err)
	}
	inspect("current revision", false)
	stopV1()
	stopV2 := startWorker("v2")
	defer stopV2()
	bridge := startApp("bridge")
	first := inspect("", false)
	if first.AnchorVersion != 2 || first.LegacyInitialVersion != 1 || first.DatabaseUUID != uuid || first.FenceNamespace != fence || first.LegacyReceiptHash == "" || len(first.Tables) != 1 || first.Tables[0] != (PgRowAdoptionTable{Table: "notes", Generation: 1}) {
		t.Fatal("wrong adopted-anchor description", first)
	}
	if len(first.SourceSealInventory) != 2 || first.SourceSealInventory[0] != "complete" {
		t.Fatal("genuine frozen provenance lost", first.SourceSealInventory)
	}
	var markers, rowReceipts int
	if err := request.QueryRow(ctx, `select (select count(*) from information_schema.columns where table_schema='notes' and column_name='_tesl_v'),(select count(*) from pg_catalog.pg_tables where schemaname='notes' and tablename='tesl_row_physical')`).Scan(&markers, &rowReceipts); err != nil || markers != 0 || rowReceipts != 0 {
		t.Fatal("inspection enabled row protocol", markers, rowReceipts, err)
	}
	call(v1, "POST", "/two")
	call(bridge, "PUT", "/one")
	body := call(bridge, "GET", "/all")
	if !strings.Contains(body, `"id":"two"`) || !strings.Contains(body, `"memo":"edited"`) {
		t.Fatal("unchanged legacy handlers lost values", body)
	}
	second := inspect("", false)
	if second.LegacyReceiptHash != first.LegacyReceiptHash || second.CatalogHash != first.CatalogHash {
		t.Fatal("ordinary CRUD changed adoption source/receipt identity", first, second)
	}
	inspect("configured Request login", true)
	if _, err := f.worker.Exec(ctx, "alter table notes.notes add column benign_extra text"); err != nil {
		t.Fatal(err)
	}
	inspect("exact source table", false)
	if _, err := f.worker.Exec(ctx, "alter table notes.notes drop column benign_extra"); err != nil {
		t.Fatal(err)
	}
	inspect("", false)
	if _, err := f.worker.Exec(ctx, "create table notes.unrecorded_facility(id text)"); err != nil {
		t.Fatal(err)
	}
	inspect("unrecorded entity or facility", false)
	if _, err := f.worker.Exec(ctx, "drop table notes.unrecorded_facility"); err != nil {
		t.Fatal(err)
	}
	inspect("", false)
	call(v1, "GET", "/all")
	t.Log("ordinary format3 V1/V2 and unchanged candidate served; read-only exact N=2/gen1 observation preserved UUID/fence/all receipts and refused unsupported catalog/login without marker or row receipts")
}
