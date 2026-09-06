package migrationtest

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// INV-ADDITIVE-READ, INV-ADDITIVE-WRITE, INV-CATALOG-EVIDENCE; TR-BOOT-EXPAND, TR-READ, TR-WRITE.
// V8 adds a plain Bool index to the populated Todo table. This scenario uses
// only ordinary app binaries: a real open writer transaction blocks PostgreSQL's
// CREATE INDEX CONCURRENTLY, and a real process kill interrupts its worker.
func recoverShowcaseConcurrentIndex(t *testing.T, db *showcaseDatabase, binaries map[int]string,
	newRequest *workerLessonProcess, traffic *showcaseTraffic, client *http.Client, labels ...string) *workerLessonProcess {
	t.Helper()
	config := db.config.Copy()
	config.User = db.app
	connection, err := pgx.ConnectConfig(db.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close(context.Background()) }()
	writer, err := connection.Begin(db.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writer.Rollback(context.Background()) }()
	if _, err := writer.Exec(db.ctx, `insert into todo_app.todos(id,title,completed)
 values('index-blocker','An open old-writer transaction',false)`); err != nil {
		t.Fatal(err)
	}
	worker := db.workerNode(t, binaries[8], 8)
	var oldPID int
	var oldTag string
	workerLessonWait(t, db.ctx, worker, "real concurrent index waiting for the open writer", func() bool {
		err := db.observer.QueryRow(db.ctx, `select p.pid,a.application_name
 from pg_catalog.pg_stat_progress_create_index p join pg_catalog.pg_stat_activity a using(pid)
 where p.datid=(select oid from pg_catalog.pg_database where datname=current_database())
 and p.relid='todo_app.todos'::regclass and p.phase='waiting for writers before build'`).Scan(&oldPID, &oldTag)
		if errors.Is(err, pgx.ErrNoRows) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		return true
	})
	initial := readShowcaseConcurrentIndex(t, db)
	if initial.state != "building" || initial.holder != oldTag || initial.token < 1 || initial.attempts != 1 || initial.valid {
		t.Fatalf("CIC did not reach a protected unfinished physical index: %+v", initial)
	}
	immutable := showcaseIndexAuthority(t, db)
	requireShowcaseReady(t, db.ctx, client, newRequest)
	db.status(t, binaries[8], 8, 8)
	db.status(t, binaries[7], 7, 8)
	traffic.requireProgress(t, db.ctx, labels...)
	oldRequest := db.requestNode(t, binaries[1], "todo-v1-during-index")
	defer oldRequest.stop(t)
	requireShowcaseReady(t, db.ctx, client, oldRequest)
	row := showcaseTodo{ID: "during-index", Title: "A new request while the index builds"}
	requireShowcaseTodo(t, db.ctx, client, newRequest.base, http.MethodPost, row.ID, `{"title":"A new request while the index builds"}`, row)
	requireShowcaseTodo(t, db.ctx, client, oldRequest.base, http.MethodGet, row.ID, "", row)
	row.Title, row.Completed = "An oldest-binary update while the index builds", true
	requireShowcaseTodo(t, db.ctx, client, oldRequest.base, http.MethodPut, row.ID,
		`{"title":"An oldest-binary update while the index builds","completed":true}`, row)
	requireShowcaseTodo(t, db.ctx, client, newRequest.base, http.MethodGet, row.ID, "", row)

	worker.once.Do(func() {
		if err := worker.cmd.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		<-worker.done
		_ = worker.log.Close()
		if worker.waitErr == nil {
			t.Fatal("killed V8 index worker reported success")
		}
	})
	// Process exit does not prove that its autocommit PostgreSQL statement has
	// stopped. The successor must wait for that exact backend set to disappear;
	// PostgreSQL is also allowed to notice the closed client immediately.
	successor := db.workerNode(t, binaries[8], 8)
	var firstSeen time.Time
	var successorTag string
	workerLessonWait(t, db.ctx, successor, "replacement index worker completing an independent poll", func() bool {
		var seen time.Time
		var tag string
		err := db.observer.QueryRow(db.ctx, `select instance,last_seen from todo_app.tesl_schema_instances
 where version=8 and instance<>$1 and instance like 'tesl-exec:%' order by last_seen desc limit 1`, oldTag).Scan(&tag, &seen)
		if errors.Is(err, pgx.ErrNoRows) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		if successorTag == "" {
			successorTag, firstSeen = tag, seen
			return false
		}
		return tag == successorTag && seen.After(firstSeen)
	})
	var oldBackendAlive bool
	var token int64
	if err := db.observer.QueryRow(db.ctx, `select exists(select 1 from pg_catalog.pg_stat_activity
 where pid=$1 and datname=current_database() and application_name=$2),l.token
 from todo_app.tesl_schema_leases l where l.name=$3`, oldPID, oldTag, "index:"+initial.name).Scan(&oldBackendAlive, &token); err != nil {
		t.Fatal(err)
	}
	if oldBackendAlive && token != initial.token {
		t.Fatalf("successor changed token while the old autocommit backend still existed: old=%d new=%d", initial.token, token)
	}
	traffic.requireProgress(t, db.ctx, labels...)
	requireShowcaseTodo(t, db.ctx, client, newRequest.base, http.MethodGet, row.ID, "", row)
	requireShowcaseTodo(t, db.ctx, client, oldRequest.base, http.MethodGet, row.ID, "", row)
	if err := writer.Rollback(db.ctx); err != nil {
		t.Fatal(err)
	}
	workerLessonWait(t, db.ctx, successor, "recovered concurrent index becoming durably valid", func() bool {
		job := readShowcaseConcurrentIndex(t, db)
		return job.state == "valid" && job.holder == "" && job.valid
	})
	final := readShowcaseConcurrentIndex(t, db)
	if final.id != initial.id || final.name != initial.name || final.token <= initial.token || final.attempts < initial.attempts {
		t.Fatalf("recovery changed job identity or did not advance its fencing token: before=%+v after=%+v", initial, final)
	}
	var survivors int
	if err := db.observer.QueryRow(db.ctx, `select count(*) from pg_catalog.pg_stat_activity
 where datname=current_database() and application_name=$1`, oldTag).Scan(&survivors); err != nil || survivors != 0 {
		t.Fatalf("index replacement completed before old backend disappearance: %d (%v)", survivors, err)
	}
	if after := showcaseIndexAuthority(t, db); immutable != after {
		t.Fatalf("CIC recovery changed immutable expansion authority:\nbefore %s\nafter %s", immutable, after)
	}
	if _, _, err := showcaseRequest(db.ctx, client, newRequest.base, http.MethodDelete, "/api/todos/"+row.ID, "", http.StatusOK); err != nil {
		t.Fatal(err)
	}
	if _, _, err := showcaseRequest(db.ctx, client, oldRequest.base, http.MethodGet, "/api/todos/"+row.ID, "", http.StatusNotFound); err != nil {
		t.Fatal(err)
	}
	traffic.requireProgress(t, db.ctx, labels...)
	return successor
}

type showcaseConcurrentIndex struct {
	id, name, state, holder string
	token, attempts         int64
	valid                   bool
}

func readShowcaseConcurrentIndex(t *testing.T, db *showcaseDatabase) showcaseConcurrentIndex {
	t.Helper()
	var job showcaseConcurrentIndex
	var shape bool
	if err := db.observer.QueryRow(db.ctx, `select j.id,j.index_name,j.state,coalesce(l.holder,''),l.token,j.attempts,
 coalesce(i.indisvalid and i.indisready and i.indislive,false),
 j.table_name='todos' and j.key_columns=array['completed']::text[] and not j.is_unique
 and (select count(*) from todo_app.tesl_schema_index where version=8)=1
 and (i.indexrelid is null or (i.indrelid='todo_app.todos'::regclass and not i.indisunique
 and i.indnkeyatts=1 and i.indnatts=1 and i.indexprs is null and i.indpred is null
 and i.indkey[0]=(select attnum from pg_catalog.pg_attribute where attrelid=i.indrelid and attname='completed')))
 from todo_app.tesl_schema_index j join todo_app.tesl_schema_leases l on l.name='index:'||j.index_name
 left join pg_catalog.pg_index i on i.indexrelid=pg_catalog.to_regclass('todo_app.'||pg_catalog.quote_ident(j.index_name))
 where j.version=8`).Scan(&job.id, &job.name, &job.state, &job.holder, &job.token, &job.attempts, &job.valid, &shape); err != nil || !shape {
		t.Fatalf("V8 did not retain the exact plain completed index job/catalog: %+v shape=%v (%v)", job, shape, err)
	}
	return job
}

func showcaseIndexAuthority(t *testing.T, db *showcaseDatabase) string {
	t.Helper()
	var snapshot string
	if err := db.observer.QueryRow(db.ctx, `select jsonb_build_object(
 'expansion',(select to_jsonb(e) from todo_app.tesl_schema_expansions e where version=8),
 'objects',(select jsonb_agg(to_jsonb(o) order by ordinal) from todo_app.tesl_schema_expansion_objects o where version=8),
 'lifecycle',(select jsonb_agg(to_jsonb(v) order by step,seq) from todo_app.tesl_schema_versions v where version=8),
 'descriptor',(select jsonb_build_array(id,version,ordinal,table_name,index_name,key_columns,is_unique)
 from todo_app.tesl_schema_index where version=8))::text`).Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}
