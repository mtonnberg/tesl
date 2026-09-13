package migrationtest

import (
	"strings"
	"testing"
)

// INV-LIFECYCLE, INV-HISTORY; TR-CONTRACT, TR-REPAIR, TR-EXPAND.
func TestPostgresTemplateRejectsIllegalLifecycleEdges(t *testing.T) {
	cases := []struct{ name, sql, want string }{
		{"contract unexpanded", "tesl_record_contracted(8,'c',1,'tesl-1','fixture')", "never expanded"},
		{"contract before retirement", "tesl_record_contracted(8,'c',1,'tesl-1','fixture')", "before V7 is retired"},
		{"begin before retirement", "tesl_begin_contract(8,'c',1,'tesl-1','fixture')", "still admitted"},
		{"repair unexpanded", "tesl_record_repair(9,1,'r',1,'tesl-1','fixture')", "never expanded"},
		{"repair gap", "tesl_record_repair(8,2,'r',1,'tesl-1','fixture')", "gap"},
		{"repair zero", "tesl_record_repair(8,0,'r',1,'tesl-1','fixture')", "gap"},
		{"expand gap", "tesl_record_expanded(10,'s','m',1,'tesl-1',true,'fixture')", "in order"},
		{"expand without classification", "tesl_record_expanded(9,'s','m',1,'tesl-1',null,'fixture')", "classification"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newDatabaseFixture(t)
			if tc.name != "contract unexpanded" {
				f.expanded(t, 8)
			}
			_, err := f.conn.Exec(f.ctx, "select "+f.schema+"."+tc.sql)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected %q; got %v", tc.want, err)
			}
		})
	}
}

// INV-PRIVILEGE; TR-RETIRE, TR-EXPAND, TR-CONTRACT, TR-REPAIR.
func TestPostgresTemplateControlOwnerIsTheOnlyDirectWriter(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	for _, role := range []string{f.app, f.worker} {
		for _, statement := range []string{
			"update " + f.schema + ".tesl_schema_state set min_version=8",
			"delete from " + f.schema + ".tesl_schema_versions",
			"update " + f.schema + ".tesl_schema_meta set retirement_protocol_floor=999",
			"delete from " + f.schema + ".tesl_schema_instances",
			"delete from " + f.schema + ".tesl_schema_activation_plans",
			"delete from " + f.schema + ".tesl_schema_protocol_activations",
			"delete from " + f.schema + ".tesl_schema_barriers",
			"select " + f.schema + ".tesl_lifecycle_core__(7,'retired',0,null,'forged',1,'tesl-1',null,'fixture')",
		} {
			f.exec(t, "set role "+role)
			_, err := f.conn.Exec(f.ctx, statement)
			f.exec(t, "reset role")
			if err == nil || !strings.Contains(err.Error(), "permission denied") {
				t.Fatalf("%s bypassed control API with %s: %v", role, statement, err)
			}
		}
	}
	for _, call := range []string{"tesl_record_expanded(9,'s','m',1,'tesl-1',true,'app')", "tesl_begin_contract(8,'c',1,'tesl-1','app')", "tesl_record_repair(8,1,'r',1,'tesl-1','app')", "tesl_advance_floor(7,8,'r',1,'tesl-1','app')"} {
		f.exec(t, "set role "+f.app)
		_, err := f.conn.Exec(f.ctx, "select "+f.schema+"."+call)
		f.exec(t, "reset role")
		if err == nil || !strings.Contains(err.Error(), "permission denied") {
			t.Fatalf("app invoked privileged %s: %v", call, err)
		}
	}
	// The worker CAN use the validated path. Restricting all writes would pass
	// the negative tests above but fail to implement the privilege model.
	f.exec(t, "set role "+f.worker)
	f.exec(t, "select "+f.schema+".tesl_record_repair(8,1,'repair',1,'tesl-1','worker')")
	f.exec(t, "reset role")
}

// INV-PRIVILEGE, INV-READ; TR-ADMIT.
func TestPostgresTemplateAdmissionIgnoresTemporaryLookalikes(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	f.exec(t, "begin")
	f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
	f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','fixture'); commit")
	f.exec(t, "create temporary table tesl_schema_state (id int,min_version int,compat_floor int)")
	f.exec(t, "insert into pg_temp.tesl_schema_state values (1,1,0)")
	f.exec(t, "set search_path=pg_temp,public")
	if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_admit(7)"); err == nil {
		t.Fatal("temporary lookalike bypassed admission")
	}
	var floor int
	if err := f.conn.QueryRow(f.ctx, "select "+f.schema+".tesl_admit(8)").Scan(&floor); err != nil || floor != 7 {
		t.Fatalf("surviving reader admission=%d: %v", floor, err)
	}
}

// INV-VERSION, INV-INSTALL-TARGET, INV-HISTORY; TR-INSTALL-RECORD, TR-EXPAND.
func TestPostgresInitialHistoryRejectsReservedVersionsAndMissingIdentity(t *testing.T) {
	f := newUninstalledDatabaseFixture(t)
	for _, version := range []int{-1, 0, 2147483647} {
		f.exec(t, "update "+f.schema+".tesl_schema_state set installing_version=$1", version)
		if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_record_expanded($1,'snapshot','migration',1,'tesl-1',true,'fixture')", version); err == nil {
			t.Fatalf("reserved or nonpositive initial version %d was recorded", version)
		}
	}
	f.exec(t, "update "+f.schema+".tesl_schema_state set installing_version=8")
	for _, snapshot := range []any{nil, ""} {
		if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_record_expanded(8,$1,'migration',1,'tesl-1',true,'fixture')", snapshot); err == nil {
			t.Fatalf("missing snapshot identity %v was recorded", snapshot)
		}
	}
	for _, identity := range []struct {
		protocol int
		domain   string
	}{{-1, "tesl-1"}, {1, ""}} {
		if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_record_expanded(8,'snapshot','migration',$1,$2,true,'fixture')", identity.protocol, identity.domain); err == nil {
			t.Fatalf("invalid protocol identity %+v was recorded", identity)
		}
	}
	var versions, current, floor int
	if err := f.conn.QueryRow(f.ctx, "select (select count(*) from "+f.schema+".tesl_schema_versions),current,min_version from "+f.schema+".tesl_schema_state").Scan(&versions, &current, &floor); err != nil {
		t.Fatal(err)
	}
	if versions != 0 || current != 0 || floor != 0 {
		t.Fatalf("refused identity changed bootstrap history: %d %d %d", versions, current, floor)
	}
	// The highest usable version is legal for a fresh database; the adjacent
	// reserved advisory-lock key is the upper bound, not an arbitrary cutoff.
	f.exec(t, "update "+f.schema+".tesl_schema_state set installing_version=2147483646")
	f.expanded(t, 2147483646)
}
