package teslrt

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgIndexControlTestIntent(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	art := strings.Repeat("b", 64)
	f.call(t, "select notes_app.tesl_begin_expansion(2,$1,$2,$3,$4,1,true)", strings.Repeat("2", 64), art, pgTestSourceABI, pgTestStoredValueCompatibility)
	return pgMigrationObjectHash(art, 0)
}

func pgIndexControlTestRegister(t *testing.T, f *pgControlTestFixture, id, table, index string, columns []string) {
	t.Helper()
	f.call(t, "select notes_app.tesl_register_index($1,2,0,$2,$3,$4,false)", id, table, index, columns)
}

func pgIndexControlTestRead(ctx context.Context, tx pgx.Tx) ([]pgMigrationIndexJob, error) {
	intents, err := pgReadExpansionIntents(ctx, tx, "notes_app")
	if err != nil {
		return nil, err
	}
	return pgReadMigrationIndexJobs(ctx, tx, "notes_app", intents)
}

func pgIndexControlTestJobs(t *testing.T, f *pgControlTestFixture) []pgMigrationIndexJob {
	t.Helper()
	var jobs []pgMigrationIndexJob
	if err := pgControlSnapshotMode(f.ctx, f.worker, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		jobs, err = pgIndexControlTestRead(f.ctx, tx)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return jobs
}

func TestPgMigrationControlIndexRegistrationIsImmutableAtomicProgress(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	index, table, key := "雪 \"quoted idx__v2", "quoted table", "x\" y"
	pgIndexControlTestRegister(t, f, id, table, index, []string{key})
	before := pgIndexControlTestJobs(t, f)
	if len(before) != 1 || before[0].ID != id || before[0].ObjectHash != id || before[0].SourceABI != pgTestSourceABI ||
		before[0].Index.Name != index || before[0].Table != table || before[0].State != "pending" || before[0].Token != 0 {
		t.Fatalf("lost immutable parameterized descriptor: %+v", before)
	}
	pgIndexControlTestRegister(t, f, id, table, index, []string{key})
	f.call(t, "select notes_app.tesl_record_expanded(2)")
	pgIndexControlTestRegister(t, f, id, table, index, []string{key})
	if !reflect.DeepEqual(before, pgIndexControlTestJobs(t, f)) {
		t.Fatal("registration retry rewrote descriptor or lease")
	}
	for _, args := range [][]any{
		{id, 2, 0, "other", index, []string{key}, false},
		{id, 2, 0, table, "other", []string{key}, false},
		{id, 2, 0, table, index, []string{"other"}, false},
		{id, 2, 0, table, index, []string{key}, true},
		{id, 2, 0, table, index, []string{key, key}, false},
		{id, 2, 0, table, index, []string{}, false},
		{id, 2, 0, table, index, []string{strings.Repeat("é", 32)}, false},
		{strings.Repeat("f", 64), 2, 0, table, index, []string{key}, false},
		{id, 2, 1, table, index, []string{key}, false},
	} {
		if _, err := f.worker.Exec(f.ctx, "select notes_app.tesl_register_index($1,$2,$3,$4,$5,$6,$7)", args...); err == nil {
			t.Fatalf("invalid registration accepted: %v", args)
		}
	}
	if !reflect.DeepEqual(before, pgIndexControlTestJobs(t, f)) {
		t.Fatal("refused registration changed descriptor")
	}
}

func TestPgMigrationControlIndexRegistrationRollsBackBeforeOrdinalProgress(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	art := strings.Repeat("b", 64)
	f.call(t, "select notes_app.tesl_begin_expansion(2,$1,$2,$3,$4,2,true)", strings.Repeat("2", 64), art, pgTestSourceABI, pgTestStoredValueCompatibility)
	id := pgMigrationObjectHash(art, 1)
	if _, err := f.worker.Exec(f.ctx, "select notes_app.tesl_register_index($1,2,1,'notes','active_idx__v2',array['active'],false)", id); err == nil {
		t.Fatal("index descriptor bypassed sequential object progress")
	}
	var jobs, leases, objects int
	if err := f.worker.QueryRow(f.ctx, `select (select count(*) from notes_app.tesl_schema_index),
 (select count(*) from notes_app.tesl_schema_leases),(select count(*) from notes_app.tesl_schema_expansion_objects where version=2)`).Scan(&jobs, &leases, &objects); err != nil || jobs != 0 || leases != 0 || objects != 0 {
		t.Fatalf("failed ordinal leaked job or lease: %d/%d/%d %v", jobs, leases, objects, err)
	}
}

func TestPgMigrationControlIndexLeaseFencesStaleLiveAndDeadExecutors(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	f.call(t, "select notes_app.tesl_record_expanded(2)")
	f.call(t, "set application_name='tesl-exec:first'")
	claim := "select notes_app.tesl_claim_index($1,$2,$3,$4)"
	for _, args := range [][]any{{id, 1, pgTestSourceABI, 30000}, {id, 2, "other-abi", 30000}, {id, 2, pgTestSourceABI, 0}, {id, 2, pgTestSourceABI, 600001}} {
		if _, err := f.worker.Exec(f.ctx, claim, args...); err == nil {
			t.Fatalf("invalid executor claim accepted: %v", args)
		}
	}
	var first int64
	if err := f.worker.QueryRow(f.ctx, claim, id, 2, pgTestSourceABI, 30000).Scan(&first); err != nil || first != 1 {
		t.Fatalf("first lease: %d %v", first, err)
	}
	second, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = second.Close(context.Background()) }()
	if _, err := second.Exec(f.ctx, "set application_name='tesl-exec:second'"); err != nil {
		t.Fatal(err)
	}
	for _, expired := range []bool{false, true} {
		if expired {
			if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_leases set expires_at=clock_timestamp()-interval '1 second'"); err != nil {
				t.Fatal(err)
			}
		}
		var token int64
		if err := second.QueryRow(f.ctx, claim, id, 2, pgTestSourceABI, 30000).Scan(&token); err != nil || token != 0 {
			t.Fatalf("live backend lease was stolen (expired=%v): %d %v", expired, token, err)
		}
	}
	var accepted bool
	if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_renew_index($1,$2,30000)", id, first).Scan(&accepted); err != nil || accepted {
		t.Fatalf("expired holder renewed after losing its lease: %v %v", accepted, err)
	}
	pid := f.worker.PgConn().PID()
	if err := f.worker.Close(f.ctx); err != nil {
		t.Fatal(err)
	}
	for {
		var present bool
		if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_stat_activity where pid=$1)", pid).Scan(&present); err != nil {
			t.Fatal(err)
		}
		if !present {
			break
		}
		time.Sleep(time.Millisecond)
	}
	var token int64
	if err := second.QueryRow(f.ctx, claim, id, 2, pgTestSourceABI, 30000).Scan(&token); err != nil || token != first+1 {
		t.Fatalf("dead holder takeover did not increment token: %d %v", token, err)
	}
	for _, statement := range []string{
		"select notes_app.tesl_renew_index($1,$2,30000)",
		"select notes_app.tesl_release_index($1,$2)",
		"select notes_app.tesl_record_index_state($1,$2,'valid',null)",
	} {
		if err := second.QueryRow(f.ctx, statement, id, first).Scan(&accepted); err != nil || accepted {
			t.Fatalf("stale token retained authority: %v %v", accepted, err)
		}
	}
	for _, state := range []string{"building", "failed", "building", "valid"} {
		var detail *string
		if state == "failed" {
			value := "controlled failure"
			detail = &value
		}
		if err := second.QueryRow(f.ctx, "select notes_app.tesl_record_index_state($1,$2,$3,$4)", id, token, state, detail).Scan(&accepted); err != nil || !accepted {
			t.Fatalf("owned state %s: %v %v", state, accepted, err)
		}
	}
	if err := second.QueryRow(f.ctx, "select notes_app.tesl_record_index_state($1,$2,'building',null)", id, token).Scan(&accepted); err != nil || accepted {
		t.Fatalf("valid job became mutable: %v %v", accepted, err)
	}
	var attempts int64
	if err := second.QueryRow(f.ctx, "select attempts from notes_app.tesl_schema_index").Scan(&attempts); err != nil || attempts != 2 {
		t.Fatalf("attempt accounting: %d %v", attempts, err)
	}
}

func TestPgMigrationControlIndexReaderRefusesCorruptBindings(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	for _, statement := range []string{
		"delete from notes_app.tesl_schema_leases",
		"insert into notes_app.tesl_schema_leases(name) values('index:orphan')",
		"update notes_app.tesl_schema_index set id=repeat('f',64)",
		"delete from notes_app.tesl_schema_expansion_objects where version=2",
		"update notes_app.tesl_schema_index set key_columns=array['active','active']",
		"update notes_app.tesl_schema_index set key_columns=array[]::text[]",
		"update notes_app.tesl_schema_index set key_columns='[0:0]={active}'::text[]",
		"update notes_app.tesl_schema_index set key_columns=array[array['active']]",
		"update notes_app.tesl_schema_index set table_name=''",
		"update notes_app.tesl_schema_index set state='failed'",
		"update notes_app.tesl_schema_index set state='failed',error=''",
		"update notes_app.tesl_schema_index set state='failed',error=repeat('x',8193)",
		"update notes_app.tesl_schema_index set error=''",
		"update notes_app.tesl_schema_index set state='building',attempts=0",
		"update notes_app.tesl_schema_index set state='terminal',terminal_version=1",
		"update notes_app.tesl_schema_leases set holder='tesl-exec:',expires_at=now(),token=1",
		"update notes_app.tesl_schema_leases set holder='tesl-exec:worker',expires_at=now(),token=0",
	} {
		tx, err := f.installer.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, statement); err != nil {
			_ = tx.Rollback(f.ctx)
			t.Fatal(err)
		}
		_, err = pgIndexControlTestRead(f.ctx, tx)
		_ = tx.Rollback(f.ctx)
		if err == nil {
			t.Fatalf("corrupt protected binding accepted: %s", statement)
		}
	}
}

func TestPgMigrationControlIndexTerminalNeverAuthorizesJobOrFloorChanges(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	f.call(t, "select notes_app.tesl_record_expanded(2)")
	f.call(t, "set application_name='tesl-exec:terminal-test'")
	var token int64
	if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,30000)", id, pgTestSourceABI).Scan(&token); err != nil || token == 0 {
		t.Fatalf("claim: %d %v", token, err)
	}
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set state='terminal',terminal_version=3"); err != nil {
		t.Fatal(err)
	}
	before := pgIndexControlTestJobs(t, f)
	var current, minimum, floor int
	if err := f.worker.QueryRow(f.ctx, "select current,min_version,compat_floor from notes_app.tesl_schema_state").Scan(&current, &minimum, &floor); err != nil {
		t.Fatal(err)
	}
	if current != 2 || minimum != 1 || floor != 1 {
		t.Fatalf("terminal fixture unexpectedly narrowed admission: %d %d %d", current, minimum, floor)
	}
	for _, statement := range []string{
		"select notes_app.tesl_renew_index($1,$2,30000)",
		"select notes_app.tesl_release_index($1,$2)",
		"select notes_app.tesl_record_index_state($1,$2,'building',null)",
		"select notes_app.tesl_record_index_state($1,$2,'valid',null)",
	} {
		var accepted bool
		if err := f.worker.QueryRow(f.ctx, statement, id, token).Scan(&accepted); err != nil || accepted {
			t.Fatalf("terminal job accepted mutation: %v %v", accepted, err)
		}
	}
	if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,30000)", id, pgTestSourceABI).Scan(&token); err != nil || token != 0 {
		t.Fatalf("terminal job allowed takeover: %d %v", token, err)
	}
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	if !reflect.DeepEqual(before, pgIndexControlTestJobs(t, f)) {
		t.Fatal("terminal job, removal target or lease changed")
	}
	var unchanged bool
	if err := f.worker.QueryRow(f.ctx, "select current=$1 and min_version=$2 and compat_floor=$3 from notes_app.tesl_schema_state", current, minimum, floor).Scan(&unchanged); err != nil || !unchanged {
		t.Fatalf("job transition changed admission state: %v %v", unchanged, err)
	}
}

func TestPgMigrationControlIndexPrivilegesAndReadOnlyRequest(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	f.call(t, "select notes_app.tesl_record_expanded(2)")
	if _, err := request.Exec(f.ctx, "set application_name='tesl-exec:spoof'"); err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		"select notes_app.tesl_register_index('x',2,0,'notes','x',array['active'],false)",
		"select notes_app.tesl_claim_index('x',2,'abi',30000)",
		"select notes_app.tesl_renew_index('x',1,30000)",
		"select notes_app.tesl_release_index('x',1)",
		"select notes_app.tesl_record_index_state('x',1,'valid',null)",
		"select notes_app.tesl_lock_expired_index_holder('x','tesl-exec:old',1,2,'abi')",
	} {
		if _, err := request.Exec(f.ctx, statement); err == nil || !strings.Contains(err.Error(), "permission denied") {
			t.Fatalf("request acquired index transition authority: %s: %v", statement, err)
		}
	}
	for _, conn := range []*pgx.Conn{f.worker, request} {
		for _, statement := range []string{
			"update notes_app.tesl_schema_index set state='valid'",
			"delete from notes_app.tesl_schema_index",
			"update notes_app.tesl_schema_leases set token=token+1",
			"delete from notes_app.tesl_schema_leases",
			"alter table notes_app.tesl_schema_index add column unauthorized int",
		} {
			if _, err := conn.Exec(f.ctx, statement); err == nil {
				t.Fatalf("long-lived login changed protected index metadata: %s", statement)
			}
		}
	}
	if err := pgControlSnapshotMode(f.ctx, request, pgx.ReadOnly, func(tx pgx.Tx) error {
		var temporary bool
		if err := tx.QueryRow(f.ctx, "select pg_catalog.has_database_privilege(current_user,current_database(),'TEMP')").Scan(&temporary); err != nil {
			return err
		}
		if temporary {
			t.Fatal("request fixture unexpectedly has TEMP authority")
		}
		if _, err := pgInspectControlReadOnly(f.ctx, tx, f.namespace, f.roles); err != nil {
			return err
		}
		jobs, err := pgIndexControlTestRead(f.ctx, tx)
		if err == nil && (len(jobs) != 1 || jobs[0].ID != id) {
			t.Fatalf("read-only request lost job visibility: %+v", jobs)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	for _, fn := range pgMigrationIndexFunctions(f.namespace) {
		tx, err := f.installer.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := pgControlSession(f.ctx, tx); err != nil {
			t.Fatal(err)
		}
		name := pgx.Identifier{f.namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
		if _, err := tx.Exec(f.ctx, "grant execute on function "+name+" to public"); err != nil {
			t.Fatal(err)
		}
		err = pgControlFunctionCatalog(f.ctx, tx, f.namespace, f.roles, fn)
		_ = tx.Rollback(f.ctx)
		if err == nil {
			t.Fatalf("PUBLIC transition authority accepted: %s", fn.name)
		}
	}
}

func TestPgMigrationControlIndexFormat3CatalogDrift(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	for _, statement := range []string{
		"alter table notes_app.tesl_schema_index alter key_columns type jsonb using to_jsonb(key_columns)",
		"alter table notes_app.tesl_schema_index alter attempts set default 1",
		"alter table notes_app.tesl_schema_index drop constraint tesl_schema_index_version_ordinal_key",
		"alter table notes_app.tesl_schema_index enable row level security",
		"grant update(state) on notes_app.tesl_schema_index to " + quoteIdentifier(f.roles.Worker),
		"alter table notes_app.tesl_schema_leases alter token type integer",
		"alter table notes_app.tesl_schema_leases alter holder set not null",
		"create table notes_app.tesl_schema_future(id int)",
		"create table notes_app.hidden_control(id int); alter table notes_app.hidden_control owner to " + quoteIdentifier(f.roles.Owner),
	} {
		tx, err := f.installer.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := pgControlSession(f.ctx, tx); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, statement); err != nil {
			_ = tx.Rollback(f.ctx)
			t.Fatal(err)
		}
		_, err = pgInspectControl(f.ctx, tx, f.namespace, f.roles)
		_ = tx.Rollback(f.ctx)
		if err == nil {
			t.Fatalf("format3 catalog drift accepted: %s", statement)
		}
	}
}
