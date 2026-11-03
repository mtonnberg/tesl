//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These programs use the same original Tesl App and handlers in all versions.
// Only V3 adds the optional private type and its original owner-local codec.
func TestPgRowCurrentOptionalJSONBOrdinaryApp(t *testing.T) {
	programs := os.Getenv("TESL_ROW_CURRENT_JSONB_PROGRAMS")
	if programs == "" {
		t.Skip("original optional JSONB current-codec applications required")
	}
	for _, kind := range []string{"record", "adt"} {
		t.Run(kind, func(t *testing.T) {
			root := filepath.Join(programs, kind)
			f, request := pgNewWorkerTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			t.Cleanup(cancel)
			f.ctx, f.namespace = ctx, "notes"
			run := func(version string, args ...string) {
				t.Helper()
				out, err := pgRowAdditiveCommand(f, root, version, args...).CombinedOutput()
				if err != nil {
					t.Fatalf("%s %v: %v\n%s", version, args, err, out)
				}
			}
			call := func(base, method, path string, status int) string {
				t.Helper()
				return pgCallRowAccessApp(t, ctx, base, method, path, status)
			}
			run("v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
			pgRowAdditiveWorker(t, f, root, "v1")()
			v1 := pgRowAdditiveApp(t, f, root, "v1")
			call(v1, "POST", "/one", 200)
			stopV2 := pgRowAdditiveWorker(t, f, root, "v2")
			v2 := pgRowAdditiveApp(t, f, root, "v2")
			stopV2()
			run("v2", "--schema", "contract", "V2", "--json")
			call(v1, "GET", "/all", 503)
			pgRowAdditiveWorker(t, f, root, "v3")()
			v3 := pgRowAdditiveApp(t, f, root, "v3")
			call(v2, "POST", "/two", 200)
			call(v3, "POST", "/three", 200)
			call(v3, "POST", "/four", 200)
			expected := map[string]string{"three": `{"storedKey":"three/payload"}`, "four": `{"storedKey":"four/payload"}`}
			if kind == "adt" {
				expected = map[string]string{"three": `{"tag":"Named","fields":{"value":"three/payload"}}`, "four": `{"tag":"Absent"}`}
			}
			checkStorage := func() {
				t.Helper()
				var absent, actualGeneration int
				if err := request.QueryRow(ctx, `select count(*) from notes.notes where id in ('one','two') and payload is null`).Scan(&absent); err != nil || absent != 2 {
					t.Fatal("old row and retained V2 insert must remain SQL NULL", absent, err)
				}
				for id, document := range expected {
					var exact, sqlNull, jsonNull bool
					if err := request.QueryRow(ctx, `select payload=$2::jsonb,payload is null,payload='null'::jsonb,_tesl_v from notes.notes where id=$1`, id, document).Scan(&exact, &sqlNull, &jsonNull, &actualGeneration); err != nil || !exact || sqlNull || jsonNull || actualGeneration != 2 {
						t.Fatal("original current codec or generation differs", kind, id, exact, sqlNull, jsonNull, actualGeneration, err)
					}
				}
			}
			checkStorage()
			body := call(v3, "GET", "/all", 200)
			if !strings.Contains(body, "three/payload") || (kind == "adt" && !strings.Contains(body, `"tag":"Absent"`)) {
				t.Fatal("current typed reader lost original codec value", kind, body)
			}
			// Both unrelated current updates and a retained V2 write must preserve the
			// optional payloads. This exercises actual decode -> typed row -> encode.
			call(v3, "PUT", "/all", 200)
			checkStorage()
			var updated int
			if err := request.QueryRow(ctx, `select count(*) from notes.notes where id in ('three','four') and memo='all-edited'`).Scan(&updated); err != nil || updated != 2 {
				t.Fatal("current typed full writes did not update both JSONB rows", updated, err)
			}
			call(v2, "PUT", "/effects", 200)
			checkStorage()
			if err := request.QueryRow(ctx, `select count(*) from notes.notes where id in ('three','four') and memo='set-multi'`).Scan(&updated); err != nil || updated != 2 {
				t.Fatal("retained settled writer lost current JSONB additions", updated, err)
			}
		})
	}
}
