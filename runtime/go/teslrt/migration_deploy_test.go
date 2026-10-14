package teslrt

import (
	"bytes"
	"strings"
	"testing"
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
