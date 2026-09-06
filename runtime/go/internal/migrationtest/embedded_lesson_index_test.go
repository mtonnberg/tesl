package migrationtest

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// The ordinary lesson's V3 adds a nullable Bool and a plain index. Both index
// executors run inside the actual compiled App/WithDatabase/Serve lifecycle;
// there is no separately launched schema worker. Only the first app has a test
// pause, used to acquire the old writer after the additive column commits.
func testCompiledEmbeddedIndexLifecycle(t *testing.T, ctx context.Context, observer *pgx.Conn,
	binary, taggedBinary string, environment []string, current, oldest string) {
	t.Helper()
	directory, err := os.MkdirTemp("", "tesl-embedded-lesson-")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.RemoveAll(directory) }()
	boundary := Event{Name: "index-before-create", Actor: "embedded-v3", Occurrence: 1}
	schedule := NewSchedule(nil)
	if err := schedule.Pause(boundary); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(directory, "control.sock")
	controller, err := ListenProcesses(ctx, socket, schedule)
	if err != nil {
		t.Fatal(err)
	}
	defer controller.Close()
	first := startWorkerLessonProcess(t, ctx, taggedBinary,
		append(append([]string(nil), environment...), "TESL_MIGRATION_TEST_SOCKET="+socket, "TESL_MIGRATION_TEST_ACTOR="+boundary.Actor), "embedded-v3-first")
	defer first.stop(t)
	// Release the test-only pause before joining the app on every failure path.
	defer func() { _ = schedule.Release(boundary) }()
	wait, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := schedule.Await(wait, boundary); err != nil {
		t.Fatalf("Embedded app did not dispatch its index: %v\n%s", err, first.output())
	}
	var expanded bool
	if err := observer.QueryRow(ctx, `select s.current=3 and
 (select count(*)=4 and bool_and(indexed is null) from additive_notes.lesson_migration_notes)
 from additive_notes.tesl_schema_state s where id=1`).Scan(&expanded); err != nil || !expanded {
		t.Fatalf("index started before the nullable expansion retained all rows: %v (%v)", expanded, err)
	}
	initial := readEmbeddedLessonIndex(t, ctx, observer)
	if initial.state != "building" || initial.holder == "" || initial.attempts != 1 || initial.valid {
		t.Fatalf("first Embedded executor did not own an unfinished index: %+v", initial)
	}
	immutable := embeddedLessonIndexAuthority(t, ctx, observer)
	client := &http.Client{Timeout: 3 * time.Second}
	ready := func(process *workerLessonProcess) {
		t.Helper()
		workerLessonWait(t, ctx, process, "Embedded full app HTTP readiness", func() bool {
			_, _, err := showcaseRequest(ctx, client, process.base, http.MethodGet, "/notes/readiness", "", http.StatusNotFound)
			return err == nil
		})
	}
	ready(first) // A plain index is still paused, yet the full API is available.
	config := observer.Config().Copy()
	for _, value := range environment {
		if user, found := strings.CutPrefix(value, "NOTES_DB_USER="); found {
			config.User = user
		}
	}
	if config.User == observer.Config().User {
		t.Fatal("old writer must use the application's non-administrative login")
	}
	connection, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close(context.Background()) }()
	writer, err := connection.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writer.Rollback(context.Background()) }()
	if _, err := writer.Exec(ctx, `insert into additive_notes.lesson_migration_notes(id,title)
 values('embedded-blocker','Uncommitted old-writer row')`); err != nil {
		t.Fatal(err)
	}
	if err := schedule.Release(boundary); err != nil {
		t.Fatal(err)
	}
	awaitBuild := func(process *workerLessonProcess) string {
		t.Helper()
		var tag string
		workerLessonWait(t, ctx, process, "actual Embedded CIC waiting for the old writer", func() bool {
			err := observer.QueryRow(ctx, `select a.application_name
 from pg_catalog.pg_stat_progress_create_index p join pg_catalog.pg_stat_activity a using(pid)
 where p.datid=(select oid from pg_catalog.pg_database where datname=current_database())
 and p.relid='additive_notes.lesson_migration_notes'::regclass and p.phase='waiting for writers before build'`).Scan(&tag)
			if errors.Is(err, pgx.ErrNoRows) {
				return false
			}
			if err != nil {
				t.Fatal(err)
			}
			return true
		})
		return tag
	}
	firstTag := awaitBuild(first)
	if firstTag != initial.holder {
		t.Fatalf("observed CIC is not the protected Embedded executor: %s %+v", firstTag, initial)
	}
	workerLessonRequest(t, ctx, client, first.base, http.MethodGet, "retained", "", http.StatusOK, "First note")
	workerLessonRequest(t, ctx, client, oldest, http.MethodPost, "embedded-old", `{"title":"Old app during Embedded index"}`, http.StatusOK, "Old app during Embedded index")
	workerLessonRequest(t, ctx, client, first.base, http.MethodGet, "embedded-old", "", http.StatusOK, "Old app during Embedded index")
	// SIGINT exercises Serve's drain and the enclosing scope's service release.
	// It must join the blocked DDL actor and its complete tagged backend set.
	first.stop(t)
	requireEmbeddedLessonTagGone(t, ctx, observer, firstTag)
	workerLessonRequest(t, ctx, client, current, http.MethodGet, "embedded-old", "", http.StatusOK, "Old app during Embedded index")

	restarted := startWorkerLessonProcess(t, ctx, binary, environment, "embedded-v3-restarted")
	defer restarted.stop(t)
	ready(restarted)
	var secondTag string
	workerLessonWait(t, ctx, restarted, "restarted Embedded app claiming its interrupted job", func() bool {
		job := readEmbeddedLessonIndex(t, ctx, observer)
		secondTag = job.holder
		return secondTag != "" && secondTag != firstTag && job.token > initial.token
	})
	// Removing the canceled attempt's invalid index can itself wait for the old
	// writer. Requiring a second CREATE phase before releasing it would deadlock
	// the correct recovery path; the protected new lease proves retry ownership.
	workerLessonRequest(t, ctx, client, restarted.base, http.MethodPost, "embedded-new", `{"title":"Restarted Embedded app"}`, http.StatusOK, "Restarted Embedded app")
	workerLessonRequest(t, ctx, client, oldest, http.MethodGet, "embedded-new", "", http.StatusOK, "Restarted Embedded app")
	if err := writer.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	workerLessonWait(t, ctx, restarted, "Embedded retry publishing its valid index", func() bool {
		job := readEmbeddedLessonIndex(t, ctx, observer)
		return job.state == "valid" && job.holder == "" && job.valid
	})
	final := readEmbeddedLessonIndex(t, ctx, observer)
	if final.id != initial.id || final.name != initial.name || final.token <= initial.token || final.attempts <= initial.attempts {
		t.Fatalf("Embedded restart failed to retry the same job with a new token: before=%+v after=%+v", initial, final)
	}
	if after := embeddedLessonIndexAuthority(t, ctx, observer); immutable != after {
		t.Fatalf("Embedded restart changed immutable migration authority:\nbefore %s\nafter %s", immutable, after)
	}
	var rows, omitted int
	if err := observer.QueryRow(ctx, `select count(*),count(*) filter(where category is null and indexed is null)
 from additive_notes.lesson_migration_notes`).Scan(&rows, &omitted); err != nil || rows != 6 || omitted != rows {
		t.Fatalf("Embedded migration changed retained rows or old-writer omissions: rows=%d omitted=%d (%v)", rows, omitted, err)
	}
	restarted.stop(t)
	requireEmbeddedLessonTagGone(t, ctx, observer, secondTag)
	workerLessonRequest(t, ctx, client, current, http.MethodGet, "embedded-new", "", http.StatusOK, "Restarted Embedded app")
}

func readEmbeddedLessonIndex(t *testing.T, ctx context.Context, observer *pgx.Conn) showcaseConcurrentIndex {
	t.Helper()
	var job showcaseConcurrentIndex
	var shape bool
	if err := observer.QueryRow(ctx, `select j.id,j.index_name,j.state,coalesce(l.holder,''),l.token,j.attempts,
 coalesce(i.indisvalid and i.indisready and i.indislive,false),
 j.table_name='lesson_migration_notes' and j.key_columns=array['indexed']::text[] and not j.is_unique
 and (select count(*) from additive_notes.tesl_schema_index where version=3)=1
 and (i.indexrelid is null or (i.indrelid='additive_notes.lesson_migration_notes'::regclass and not i.indisunique
 and i.indnkeyatts=1 and i.indnatts=1 and i.indexprs is null and i.indpred is null
 and i.indkey[0]=(select attnum from pg_catalog.pg_attribute where attrelid=i.indrelid and attname='indexed')))
 from additive_notes.tesl_schema_index j join additive_notes.tesl_schema_leases l on l.name='index:'||j.index_name
 left join pg_catalog.pg_index i on i.indexrelid=pg_catalog.to_regclass('additive_notes.'||pg_catalog.quote_ident(j.index_name))
 where j.version=3`).Scan(&job.id, &job.name, &job.state, &job.holder, &job.token, &job.attempts, &job.valid, &shape); err != nil || !shape {
		t.Fatalf("Embedded index job/catalog differs: %+v shape=%v (%v)", job, shape, err)
	}
	return job
}

func embeddedLessonIndexAuthority(t *testing.T, ctx context.Context, observer *pgx.Conn) string {
	t.Helper()
	var result string
	if err := observer.QueryRow(ctx, `select jsonb_build_object(
 'expansion',(select to_jsonb(e) from additive_notes.tesl_schema_expansions e where version=3),
 'objects',(select jsonb_agg(to_jsonb(o) order by ordinal) from additive_notes.tesl_schema_expansion_objects o where version=3),
 'lifecycle',(select jsonb_agg(to_jsonb(v) order by step,seq) from additive_notes.tesl_schema_versions v where version=3),
 'descriptor',(select jsonb_build_array(id,version,ordinal,table_name,index_name,key_columns,is_unique)
 from additive_notes.tesl_schema_index where version=3))::text`).Scan(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func requireEmbeddedLessonTagGone(t *testing.T, ctx context.Context, observer *pgx.Conn, tag string) {
	t.Helper()
	var backends int
	if err := observer.QueryRow(ctx, `select count(*) from pg_catalog.pg_stat_activity
 where datname=current_database() and (application_name=$1 or application_name in
 (select instance from additive_notes.tesl_schema_instances where version=3 and instance like 'tesl-exec:%'))`, tag).Scan(&backends); err != nil || backends != 0 {
		t.Fatalf("returned Embedded scope retained executor backends: tag=%s count=%d (%v)", tag, backends, err)
	}
}
