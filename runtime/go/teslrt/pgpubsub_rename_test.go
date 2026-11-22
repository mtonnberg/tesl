package teslrt

import (
	"strings"
	"testing"
)

// An outbox created by an older runtime used `channel_name`/`channel_key`; the bootstrap
// renames them once, guarded so a current table (or a re-run) is untouched. Verified against
// PostgreSQL by booting an app on a legacy-shaped table; this pins the statement shape.
func TestRenameLegacyOutboxColumnIsGuardedAndIdempotent(t *testing.T) {
	statement := renameLegacyOutboxColumn(`"app"."tesl_pubsub_outbox"`, "channel_name", "channel")
	for _, want := range []string{
		`attrelid = '"app"."tesl_pubsub_outbox"'::regclass and attname = 'channel_name'`,
		`not exists (select 1 from pg_attribute where attrelid = '"app"."tesl_pubsub_outbox"'::regclass and attname = 'channel'`,
		`alter table "app"."tesl_pubsub_outbox" rename column "channel_name" to "channel"`,
	} {
		if !strings.Contains(statement, want) {
			t.Fatalf("statement lacks %q:\n%s", want, statement)
		}
	}
}
