package migrationtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type registryDatabase struct {
	f      *databaseFixture
	conn   *pgx.Conn
	config *pgx.ConnConfig
}

func newRegistryDatabase(t *testing.T) *registryDatabase {
	t.Helper()
	f := newDatabaseFixture(t)
	name := f.schema + "_registry"
	f.activityDatabases = []string{name}
	f.exec(t, "create database "+name)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := f.conn.Exec(ctx, "drop database "+name+" with (force)"); err != nil {
			t.Error(err)
		}
	})
	config, err := pgx.ParseConfig(f.dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.Database = name
	conn, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	f.execOn(t, conn, "set search_path = ''")
	// ConnString retains the original parsed string, including its old database.
	// Every reconnect must use a copy of the modified connection configuration.
	return &registryDatabase{f: f, conn: conn, config: config}
}

// The real registry CREATE comes from the normative bootstrap fixture. The
// independent expected catalog below is deliberately specified separately.
func registryFixtureDefinition(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("testdata/control-bootstrap.sql")
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	const start = "create table if not exists public.tesl_fence_namespaces ("
	const end = "-- HARNESS STEP assert_registry_owner_and_shape:"
	if strings.Count(source, start) != 1 || strings.Count(source, end) != 1 || strings.Index(source, end) < strings.Index(source, start) {
		t.Fatal("normative registry fixture has ambiguous boundaries")
	}
	return source[strings.Index(source, start):strings.Index(source, end)]
}

func (r *registryDatabase) install(t *testing.T) {
	t.Helper()
	r.f.execOn(t, r.conn, registryFixtureDefinition(t))
	r.f.execOn(t, r.conn, "alter table public.tesl_fence_namespaces owner to "+r.f.control)
}

func registryShape(t *testing.T, evidence string) string {
	t.Helper()
	var shape map[string]json.RawMessage
	if err := json.Unmarshal([]byte(evidence), &shape); err != nil {
		t.Fatal(err)
	}
	var relation map[string]any
	if err := json.Unmarshal(shape["relation"], &relation); err != nil {
		t.Fatal(err)
	}
	// Owner is verified against the trusted control role separately. The probe
	// table belongs to the installer; relation/index OIDs are not identities.
	delete(relation, "owner")
	var err error
	shape["relation"], err = json.Marshal(relation)
	if err != nil {
		t.Fatal(err)
	}
	for _, component := range []string{"constraints", "indexes"} {
		var objects []map[string]any
		if err := json.Unmarshal(shape[component], &objects); err != nil {
			t.Fatal(err)
		}
		var normalized []string
		for _, object := range objects {
			delete(object, "name")
			value, err := json.Marshal(object)
			if err != nil {
				t.Fatal(err)
			}
			normalized = append(normalized, string(value))
		}
		slices.Sort(normalized)
		shape[component], err = json.Marshal(normalized)
		if err != nil {
			t.Fatal(err)
		}
	}
	result, err := json.Marshal(shape)
	if err != nil {
		t.Fatal(err)
	}
	return string(result)
}

// verifyRegistry is a test implementation of the template's registry hook. A
// nested transaction confines the comparison table and any SQL failure to its
// savepoint, retaining the caller's transaction and its bootstrap lock.
// It is not the production installer or its complete role-membership audit.
func (r *registryDatabase) verifyRegistry(t *testing.T, outer pgx.Tx) error {
	t.Helper()
	f := r.f
	tx, err := outer.Begin(f.ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	if _, err = tx.Exec(f.ctx, "set local search_path = ''"); err != nil {
		return err
	}
	var owner, kind string
	var trusted, login, permanent, inherited, rewritten bool
	err = tx.QueryRow(f.ctx, `select pg_get_userbyid(c.relowner), c.relowner=$1::regrole, role.rolcanlogin, c.relkind::text,
		c.relpersistence='p', exists(select 1 from pg_inherits where inhrelid=c.oid or inhparent=c.oid),
		exists(select 1 from pg_rewrite where ev_class=c.oid)
		from pg_class c join pg_roles role on role.oid= c.relowner where c.oid=to_regclass('public.tesl_fence_namespaces')`, f.control).Scan(&owner, &trusted, &login, &kind, &permanent, &inherited, &rewritten)
	if err != nil {
		return fmt.Errorf("registry missing or unreadable: %w", err)
	}
	if !trusted || login || kind != "r" || !permanent || inherited || rewritten {
		return fmt.Errorf("registry owner/shape: owner=%s login=%t kind=%s permanent=%t inherited=%t rewritten=%t", owner, login, kind, permanent, inherited, rewritten)
	}
	const expected = `create temporary table expected_registry (
		fence_ns int generated always as identity primary key check(fence_ns between 1 and 2147483646),
		database_uuid uuid not null unique)`
	if _, err = tx.Exec(f.ctx, expected); err != nil {
		return err
	}
	live := registryShape(t, catalogEvidence(t, f, tx.Conn(), "public.tesl_fence_namespaces"))
	want := registryShape(t, catalogEvidence(t, f, tx.Conn(), "pg_temp.expected_registry"))
	if live != want {
		return fmt.Errorf("registry catalog shape differs from the expected control registry")
	}
	var sequence string
	err = tx.QueryRow(f.ctx, "select pg_get_serial_sequence('public.tesl_fence_namespaces','fence_ns')").Scan(&sequence)
	if err != nil {
		return fmt.Errorf("registry identity sequence: %w", err)
	}
	var sequenceOK bool
	err = tx.QueryRow(f.ctx, `select c.relowner=$1::regrole and s.seqtypid='int4'::regtype and s.seqstart=1 and s.seqincrement=1
		and s.seqmin=1 and s.seqmax=2147483647 and not s.seqcycle and s.seqcache=1
		from pg_sequence s join pg_class c on c.oid=s.seqrelid where s.seqrelid=$2::regclass`, f.control, sequence).Scan(&sequenceOK)
	if err != nil || !sequenceOK {
		return fmt.Errorf("registry identity sequence owner/definition differs: valid=%t error=%v", sequenceOK, err)
	}
	var unsafe string
	err = tx.QueryRow(f.ctx, `with permissions as (
		select c.relname::text as object, p.grantee,p.privilege_type,c.relowner as owner
		from pg_class c cross join lateral aclexplode(coalesce(c.relacl,acldefault(case c.relkind when 'S' then 'S'::"char" else 'r'::"char" end,c.relowner))) p
		where c.oid in ('public.tesl_fence_namespaces'::regclass,$1::regclass)
		union all
		select a.attname::text,p.grantee,p.privilege_type,c.relowner
		from pg_attribute a join pg_class c on c.oid=a.attrelid cross join lateral aclexplode(a.attacl) p
		where a.attrelid='public.tesl_fence_namespaces'::regclass
	) select coalesce(string_agg(object||':'||case when grantee=0 then 'PUBLIC' else pg_get_userbyid(grantee) end||':'||privilege_type,',' order by object,grantee,privilege_type),'')
		from permissions where grantee<>owner and privilege_type<>'SELECT'`, sequence).Scan(&unsafe)
	if err != nil {
		return err
	}
	if unsafe != "" {
		return fmt.Errorf("registry grants permit a non-owner mutation: %s", unsafe)
	}
	return nil
}

// INV-REGISTRY-OWNER, INV-REGISTRY-SHAPE, INV-PRIVILEGE; TR-REGISTRY-VERIFY.
func TestPostgresRegistryLookalikesAndWritableGrantsAreRefused(t *testing.T) {
	r := newRegistryDatabase(t)
	r.install(t)
	cases := []struct{ name, change, reason string }{
		{"wrong_owner", "alter table public.tesl_fence_namespaces owner to " + r.f.worker, "owner/shape"},
		{"login_owner", "alter role " + r.f.control + " login", "owner/shape"},
		{"range", "alter table public.tesl_fence_namespaces drop constraint tesl_fence_namespaces_fence_ns_check, add check(fence_ns between 0 and 2147483647)", "catalog shape"},
		{"missing_uuid_unique", "alter table public.tesl_fence_namespaces drop constraint tesl_fence_namespaces_database_uuid_key", "catalog shape"},
		{"nullable_uuid", "alter table public.tesl_fence_namespaces alter column database_uuid drop not null", "catalog shape"},
		{"identity_mode", "alter table public.tesl_fence_namespaces alter column fence_ns set generated by default", "catalog shape"},
		{"extra_column", "alter table public.tesl_fence_namespaces add column extra text", "catalog shape"},
		{"rls", "alter table public.tesl_fence_namespaces enable row level security", "catalog shape"},
		{"unlogged", "alter table public.tesl_fence_namespaces set unlogged", "owner/shape"},
		{"child", "create table public.registry_child() inherits(public.tesl_fence_namespaces)", "owner/shape"},
		{"rewrite_rule", "create rule swallow as on insert to public.tesl_fence_namespaces do instead nothing", "owner/shape"},
		{"public_insert", "grant insert on public.tesl_fence_namespaces to public", "PUBLIC:INSERT"},
		{"worker_delete", "grant delete on public.tesl_fence_namespaces to " + r.f.worker, r.f.worker + ":DELETE"},
		{"column_update", "grant update(database_uuid) on public.tesl_fence_namespaces to " + r.f.app, r.f.app + ":UPDATE"},
		{"sequence_usage", "grant usage on sequence public.tesl_fence_namespaces_fence_ns_seq to " + r.f.app, r.f.app + ":USAGE"},
		{"sequence_cycle", "alter sequence public.tesl_fence_namespaces_fence_ns_seq cycle", "sequence owner/definition"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := r.conn.Begin(r.f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(r.f.ctx) }()
			if _, err = tx.Exec(r.f.ctx, "select pg_advisory_xact_lock(32341,0)"); err != nil {
				t.Fatal(err)
			}
			if err = r.verifyRegistry(t, tx); err != nil {
				t.Fatalf("valid initial registry: %v", err)
			}
			if _, err = tx.Exec(r.f.ctx, tc.change); err != nil {
				t.Fatal(err)
			}
			before := catalogEvidence(t, r.f, r.conn, "public.tesl_fence_namespaces")
			err = r.verifyRegistry(t, tx)
			if err == nil || !strings.Contains(err.Error(), tc.reason) {
				t.Fatalf("expected %s refusal, got %v", tc.reason, err)
			}
			if after := catalogEvidence(t, r.f, r.conn, "public.tesl_fence_namespaces"); after != before {
				t.Fatal("registry verification changed caller-owned catalog work")
			}
			var one int
			if err = tx.QueryRow(r.f.ctx, "select 1").Scan(&one); err != nil || one != 1 {
				t.Fatalf("refusal aborted the caller transaction: %v", err)
			}
		})
	}
	// Read-only grants do not enable registration or sequence mutation.
	r.f.execOn(t, r.conn, "grant select on public.tesl_fence_namespaces to public")
	tx, err := r.conn.Begin(r.f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(r.f.ctx) }()
	if err = r.verifyRegistry(t, tx); err != nil {
		t.Fatalf("read-only registry grant: %v", err)
	}
}

// INV-REGISTRY-ALLOCATION, INV-VERSION; TR-REGISTRY-ALLOCATE.
func TestPostgresRegistryAllocationRollbackAndExhaustion(t *testing.T) {
	r := newRegistryDatabase(t)
	r.install(t)
	insert := "insert into public.tesl_fence_namespaces(database_uuid) values(gen_random_uuid()) returning fence_ns"
	var abandoned, committed int
	r.f.execOn(t, r.conn, "begin; select pg_advisory_xact_lock(32341,0); set local role "+r.f.control)
	if err := r.conn.QueryRow(r.f.ctx, insert).Scan(&abandoned); err != nil {
		t.Fatal(err)
	}
	r.f.execOn(t, r.conn, "rollback")
	r.f.execOn(t, r.conn, "begin; select pg_advisory_xact_lock(32341,0); set local role "+r.f.control)
	if err := r.conn.QueryRow(r.f.ctx, insert).Scan(&committed); err != nil {
		t.Fatal(err)
	}
	r.f.execOn(t, r.conn, "commit")
	if committed <= abandoned {
		t.Fatalf("rollback reused a namespace: abandoned=%d committed=%d", abandoned, committed)
	}
	r.f.execOn(t, r.conn, "alter sequence public.tesl_fence_namespaces_fence_ns_seq restart with 2147483646")
	var last int
	if err := r.conn.QueryRow(r.f.ctx, insert).Scan(&last); err != nil || last != 2147483646 {
		t.Fatalf("last permitted namespace: %d %v", last, err)
	}
	for _, code := range []string{"23514", "2200H"} {
		var pgErr *pgconn.PgError
		if _, err := r.conn.Exec(r.f.ctx, insert); !errors.As(err, &pgErr) || pgErr.Code != code {
			t.Fatalf("namespace exhaustion must fail closed with %s: %v", code, err)
		}
	}
	var count, minimum, maximum int
	if err := r.conn.QueryRow(r.f.ctx, "select count(*),min(fence_ns),max(fence_ns) from public.tesl_fence_namespaces").Scan(&count, &minimum, &maximum); err != nil {
		t.Fatal(err)
	}
	if count != 2 || minimum != committed || maximum != last {
		t.Fatalf("failed allocations changed committed registrations: count=%d min=%d max=%d", count, minimum, maximum)
	}
}

// INV-REGISTRY-ALLOCATION, INV-FENCE; TR-REGISTRY-ALLOCATE.
func TestPostgresConcurrentFamiliesReceiveDistinctFenceNamespaces(t *testing.T) {
	r := newRegistryDatabase(t)
	r.install(t)
	const families = 10
	type allocation struct {
		namespace int
		uuid      string
		err       error
	}
	results := make(chan allocation, families)
	r.f.execOn(t, r.conn, "select pg_advisory_lock(32341,0)")
	defer func() { _, _ = r.conn.Exec(context.Background(), "select pg_advisory_unlock(32341,0)") }()
	for range families {
		go func() {
			var result allocation
			conn, err := pgx.ConnectConfig(r.f.ctx, r.config.Copy())
			if err != nil {
				result.err = err
			} else {
				defer func() { _ = conn.Close(context.Background()) }()
				_, result.err = conn.Exec(r.f.ctx, "begin; select pg_advisory_xact_lock(32341,0); set local role "+r.f.control)
				if result.err == nil {
					result.err = conn.QueryRow(r.f.ctx, "insert into public.tesl_fence_namespaces(database_uuid) values(gen_random_uuid()) returning fence_ns,database_uuid::text").Scan(&result.namespace, &result.uuid)
				}
				if result.err == nil {
					_, result.err = conn.Exec(r.f.ctx, "commit")
				}
			}
			results <- result
		}()
	}
	// Observe every contender waiting on the allocation lock before releasing it.
	// A fast machine cannot turn this into ten non-overlapping allocations.
	for {
		var waiting int
		err := r.conn.QueryRow(r.f.ctx, `select count(*) from pg_locks
			where locktype='advisory' and classid=32341 and objid=0 and objsubid=2
			and database=(select oid from pg_database where datname=current_database()) and not granted`).Scan(&waiting)
		if err != nil {
			t.Fatalf("registry contenders did not reach the allocation lock: %v\n%s", err, r.f.dump())
		}
		if waiting == families {
			break
		}
		select {
		case result := <-results:
			t.Fatalf("allocation exited before the lock was released: %v\n%s", result.err, r.f.dump())
		default:
		}
		runtime.Gosched()
	}
	r.f.execOn(t, r.conn, "select pg_advisory_unlock(32341,0)")
	namespaces, identities := map[int]bool{}, map[string]bool{}
	var failures []string
	for range families {
		select {
		case result := <-results:
			if result.err != nil || result.namespace < 1 || result.namespace > 2147483646 || result.uuid == "" || namespaces[result.namespace] || identities[result.uuid] {
				failures = append(failures, fmt.Sprintf("namespace=%d uuid=%s error=%v", result.namespace, result.uuid, result.err))
				continue
			}
			namespaces[result.namespace], identities[result.uuid] = true, true
		case <-r.f.ctx.Done():
			t.Fatalf("registry allocation timed out: %s", r.f.dump())
		}
	}
	if len(failures) != 0 {
		t.Fatalf("invalid/duplicate registry allocations: %s\n%s", strings.Join(failures, "\n"), r.f.dump())
	}
	var count int
	if err := r.conn.QueryRow(r.f.ctx, "select count(*) from public.tesl_fence_namespaces").Scan(&count); err != nil || count != families {
		t.Fatalf("registry did not persist every family once: %d %v", count, err)
	}
	keys := make([]int, 0, len(namespaces))
	for key := range namespaces {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	other, err := pgx.ConnectConfig(r.f.ctx, r.config.Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = other.Close(context.Background()) }()
	r.f.execOn(t, r.conn, "select pg_advisory_lock($1,8)", keys[0])
	for _, tc := range []struct {
		namespace int
		want      bool
	}{{keys[0], false}, {keys[1], true}} {
		var acquired bool
		if err := other.QueryRow(r.f.ctx, "select pg_try_advisory_lock($1,8)", tc.namespace).Scan(&acquired); err != nil || acquired != tc.want {
			t.Fatalf("fence isolation for namespace %d: acquired=%t want=%t err=%v", tc.namespace, acquired, tc.want, err)
		}
	}
}
