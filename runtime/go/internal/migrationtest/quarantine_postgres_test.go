package migrationtest

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// INV-QUARANTINE, INV-FINAL, INV-FLOOR, INV-HISTORY; TR-BACKFILL, TR-RETIRE, TR-QUARANTINE-REFRESH, TR-INVALIDATE, TR-ROW-DELETE.
// The fixture's pure transform accepts nonnegative totals and derives their text
// representation. This pins transaction/re-read ordering, not Tesl code emission.
func TestPostgresAbortQuarantineRechecksCurrentRow(t *testing.T) {
	for _, change := range []string{"unchanged", "now-accepted", "different-rejection", "deleted"} {
		t.Run(change, func(t *testing.T) {
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			f.exec(t, "create table "+f.schema+".repair_notes(id int primary key,total int not null,label text,_tesl_v smallint not null)")
			f.exec(t, "insert into "+f.schema+".repair_notes values (1,0,null,3),(2,-1,null,3)")
			f.exec(t, "insert into "+f.schema+".tesl_schema_entities(entity,generation,target_generation) values ('Note',3,4)")
			batch, app := f.other(t), f.other(t)
			f.exec(t, "begin")
			f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
			var accepted int
			if err := batch.QueryRow(f.ctx, "update "+f.schema+".repair_notes set label=total::text,_tesl_v=4 where _tesl_v<4 and total>=0 returning id").Scan(&accepted); err != nil || accepted != 1 {
				t.Fatalf("accepted batch: id=%d %v", accepted, err)
			}
			var rejected int
			if err := f.conn.QueryRow(f.ctx, "select total from "+f.schema+".repair_notes where id=2").Scan(&rejected); err != nil || rejected != -1 {
				t.Fatalf("initial rejection: total=%d %v", rejected, err)
			}
			if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_advance_floor(7,8,'retirement',1,'tesl-1','fixture')"); err == nil || !strings.Contains(err.Error(), "not final") {
				t.Fatalf("unfinished rows did not stop retirement: %v", err)
			}
			f.exec(t, "rollback")
			// A previous pass's entry may be stale too. Refresh must replace or
			// remove it using current data, even when the row was deleted.
			f.exec(t, "insert into "+f.schema+".tesl_schema_quarantine(entity,pk,target_generation,attempt,reason) values ('Note','[2]',4,1,'outdated reason')")
			f.execOn(t, app, "begin")
			f.execOn(t, app, "select pg_advisory_xact_lock_shared($1,7)", f.fence)
			f.execOn(t, app, "select "+f.schema+".tesl_admit(7)")
			switch change {
			case "now-accepted":
				f.execOn(t, app, "update "+f.schema+".repair_notes set total=5 where id=2")
			case "different-rejection":
				f.execOn(t, app, "update "+f.schema+".repair_notes set total=-9 where id=2")
			case "deleted":
				f.execOn(t, app, "delete from "+f.schema+".repair_notes where id=2")
			}
			f.execOn(t, app, "commit")
			// The rejection transaction locks/re-reads the row before evaluating
			// it. It must not use `rejected`, captured before the rollback above.
			f.exec(t, "begin")
			var current int
			err := f.conn.QueryRow(f.ctx, "select total from "+f.schema+".repair_notes where id=2 for update").Scan(&current)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				t.Fatal(err)
			}
			if errors.Is(err, pgx.ErrNoRows) || current >= 0 {
				f.exec(t, "delete from "+f.schema+".tesl_schema_quarantine where entity='Note' and pk='[2]' and target_generation=4")
			} else {
				f.exec(t, "insert into "+f.schema+".tesl_schema_quarantine(entity,pk,target_generation,attempt,reason) values ('Note','[2]',4,1,$1) on conflict(entity,pk,target_generation,attempt) do update set reason=excluded.reason", fmt.Sprintf("negative total %d", current))
			}
			f.exec(t, "commit")
			var floor, generation, retired, quarantined int
			var label, reason string
			if err := f.conn.QueryRow(f.ctx, "select min_version,(select count(*) from "+f.schema+".tesl_schema_versions where step='retired') from "+f.schema+".tesl_schema_state where id=1").Scan(&floor, &retired); err != nil || floor != 7 || retired != 0 {
				t.Fatalf("aborted retirement changed history: floor=%d retired=%d %v", floor, retired, err)
			}
			if err := f.conn.QueryRow(f.ctx, "select _tesl_v,label from "+f.schema+".repair_notes where id=1").Scan(&generation, &label); err != nil || generation != 4 || label != "0" {
				t.Fatalf("committed accepted batch lost: generation=%d label=%q %v", generation, label, err)
			}
			if err := f.conn.QueryRow(f.ctx, "select count(*),coalesce(max(reason),'') from "+f.schema+".tesl_schema_quarantine").Scan(&quarantined, &reason); err != nil {
				t.Fatal(err)
			}
			wantReason := map[string]string{"unchanged": "negative total -1", "different-rejection": "negative total -9"}[change]
			wantCount := 0
			if wantReason != "" {
				wantCount = 1
			}
			if quarantined != wantCount || reason != wantReason {
				t.Fatalf("stale quarantine after %s: count=%d reason=%q", change, quarantined, reason)
			}
		})
	}
}
