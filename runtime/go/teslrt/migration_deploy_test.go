package teslrt

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestSchemaDeploymentArgumentsAndCredentials(t *testing.T) {
	t.Setenv("TESL_SCHEMA_INSTALLER_DSN", "host=localhost dbname=app user=installer")
	var out, diagnostics bytes.Buffer
	if handled, code := RunSchemaCommand(nil, &out, &diagnostics); handled || code != 0 || out.Len() != 0 || diagnostics.Len() != 0 {
		t.Fatal("Installer environment activated deployment during ordinary application startup")
	}
	command, handled, err := pgParseSchemaCommand([]string{"--schema", "deploy", "--database", "App.Main", "--json"})
	if err != nil || !handled || command.verb != "deploy" || command.database != "App.Main" || !command.json {
		t.Fatal("deployment command lost its compiled selection", command, handled, err)
	}
	for _, flag := range []string{"--force", "--dry-run", "--worker", "--request", "V2"} {
		if _, handled, err := pgParseSchemaCommand([]string{"--schema", "deploy", flag}); !handled || err == nil {
			t.Fatal("deployment accepted an authority/target override", flag)
		}
	}
	roles := PgMigrationControlRoles{Owner: "owner", Worker: "worker", Request: "request"}
	config := PostgresConfig{DDLConnection: "host=localhost dbname=app user=worker"}
	t.Setenv("TESL_SCHEMA_INSTALLER_DSN", "")
	if _, _, err := pgDeploymentConnections(config, roles); err == nil {
		t.Fatal("deployment reused Worker credentials as Installer")
	}
	t.Setenv("TESL_SCHEMA_INSTALLER_DSN", "postgres://installer:secret-sentinel@localhost:invalid/app")
	if _, _, err := pgDeploymentConnections(config, roles); err == nil || strings.Contains(err.Error(), "secret-sentinel") {
		t.Fatal("invalid Installer connection was accepted or exposed credentials", err)
	}
	for _, login := range []string{"worker", "request"} {
		t.Setenv("TESL_SCHEMA_INSTALLER_DSN", "host=localhost dbname=app user="+login)
		if _, _, err := pgDeploymentConnections(config, roles); err == nil {
			t.Fatal("service login selected as Installer", login)
		}
	}
	t.Setenv("TESL_SCHEMA_INSTALLER_DSN", "host=localhost dbname=app user=installer")
	installer, worker, err := pgDeploymentConnections(config, roles)
	if err != nil || installer.User != "installer" || worker.User != "worker" || installer.RuntimeParams["application_name"] == worker.RuntimeParams["application_name"] {
		t.Fatal("deployment connections do not retain separate identities", err)
	}
}

func TestSchemaDeploymentQueueStatusRetryClassification(t *testing.T) {
	transient := []string{"QUEUE_RETIRING_CLAIMS", "QUEUE_CONVERSION_ATTEMPTS", "RECENT_RETIRING_INSTANCES", "QUEUE_OLD_PAYLOADS"}
	terminal := []string{"QUEUE_MIGRATION_REJECTED", "QUEUE_PAYLOAD_INVALID", "QUEUE_MIGRATION_EXECUTION_FAILED", "SOURCE_DRIFT", "CATALOG_DRIFT", "UNKNOWN"}
	blocker := func(code string) string { return fmt.Sprintf(`{"code":%q,"count":1}`, code) }
	check := func(raw string, want bool) {
		t.Helper()
		got, err := pgQueueStatusCanWait([]byte(raw))
		if got != want || (want && err != nil) {
			t.Fatalf("status %s: wait=%v error=%v; want wait=%v", raw, got, err, want)
		}
	}
	t.Run("resolved", func(t *testing.T) { check(`{"blockers":[]}`, true) })
	for _, code := range transient {
		t.Run(code, func(t *testing.T) {
			check(`{"blockers":[`+blocker(code)+`]}`, true)
			for _, stop := range terminal {
				check(`{"blockers":[`+blocker(code)+`,`+blocker(stop)+`]}`, false)
				check(`{"blockers":[`+blocker(stop)+`,`+blocker(code)+`]}`, false)
			}
		})
	}
	for _, raw := range []string{
		``, `null`, `{}`, `[]`, `{"blockers":null}`, `{"blockers":{}}`, `{"blockers":"[]"}`,
		`{"blockers":[null]}`, `{"blockers":[{}]}`, `{"blockers":[{"code":1,"count":1}]}`,
		`{"blockers":[{"code":"QUEUE_OLD_PAYLOADS"}]}`,
		`{"blockers":[{"code":"QUEUE_OLD_PAYLOADS","count":0}]}`,
		`{"blockers":[{"code":"QUEUE_OLD_PAYLOADS","count":-1}]}`,
		`{"blockers":[{"code":"QUEUE_OLD_PAYLOADS","count":1.5}]}`,
		`{"blockers":[{"code":"QUEUE_OLD_PAYLOADS","count":"1"}]}`,
		`{"blockers":[{"Code":"QUEUE_OLD_PAYLOADS","count":1}]}`,
		`{"blockers":[{"code":"UNKNOWN","code":"QUEUE_OLD_PAYLOADS","count":1}]}`,
		`{"blockers":[{"code":"UNKNOWN","count":1}],"blockers":[]}`,
	} {
		t.Run("malformed/"+raw, func(t *testing.T) { check(raw, false) })
	}
}

func TestSchemaDeploymentUnclassifiedFailuresAreTerminal(t *testing.T) {
	// A nil connection proves these failures do not even consult queue status.
	for _, err := range []error{
		errors.New("converter failed"), errors.New("source changed"), errors.New("catalog changed"),
		errors.New("queue Contract is blocked"),
		&pgconn.PgError{Code: "P0001", Message: "checked conversion failed"},
		&pgconn.PgError{Code: "40001", Message: "serialization failure"},
	} {
		wait, inspectErr := pgDeploymentCanWait(context.Background(), nil, "unused", err)
		if wait || inspectErr != nil {
			t.Fatal("unclassified failure was retried", err, wait, inspectErr)
		}
	}
}

func TestSchemaWorkerInstallIsExplicit(t *testing.T) {
	command, handled, err := pgParseSchemaCommand([]string{"--schema", "worker", "--install", "--json", "--database", "App.Main"})
	if err != nil || !handled || !command.install || command.verb != "worker" || !command.json || command.database != "App.Main" {
		t.Fatal("combined worker did not retain explicit installation intent", command, handled, err)
	}
	for _, args := range [][]string{
		{"--schema", "worker", "--install", "--install"},
		{"--schema", "deploy", "--install"},
		{"--schema", "install", "--install"},
		{"--schema", "status", "--install"},
		{"--schema", "worker", "--install", "--worker", "other"},
		{"--schema", "worker", "--install", "--force"},
	} {
		if _, handled, err := pgParseSchemaCommand(args); !handled || err == nil {
			t.Fatal("invalid combined-worker command accepted", args)
		}
	}
}

func TestSchemaDeploymentPinsInstallationAcrossPhases(t *testing.T) {
	expected := PgMigrationControlState{DatabaseUUID: "installation", FenceNamespace: 7, FenceDomain: "tesl-1", Format: 5, InitialVersion: 1, Current: 1}
	advanced := expected
	advanced.Current = 4
	if err := pgCheckDeploymentIdentity(advanced, &expected); err != nil {
		t.Fatal("legitimate advancement changed installation identity", err)
	}
	for _, change := range []func(*PgMigrationControlState){
		func(s *PgMigrationControlState) { s.DatabaseUUID = "replacement" },
		func(s *PgMigrationControlState) { s.FenceNamespace++ },
		func(s *PgMigrationControlState) { s.InitialVersion++ },
		func(s *PgMigrationControlState) { s.FenceDomain = "replacement" },
		func(s *PgMigrationControlState) { s.Format++ },
	} {
		actual := expected
		change(&actual)
		if err := pgCheckDeploymentIdentity(actual, &expected); err == nil {
			t.Fatal("deployment adopted a different installation", actual)
		}
	}
	for _, value := range []string{"0", "-1", "86401", "99999999999999999999999", "secret-sentinel"} {
		t.Setenv("TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS", value)
		if _, err := pgDeploymentTimeout(); err == nil || strings.Contains(err.Error(), "secret-sentinel") {
			t.Fatal("invalid deployment budget accepted or exposed", err)
		}
	}
}
