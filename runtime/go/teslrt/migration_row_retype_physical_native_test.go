package teslrt

import (
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPgRowRetypePhysicalActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_RETYPE_PHYSICAL_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated full apps required")
	}
	adt := os.Getenv("TESL_ROW_RETYPE_PHYSICAL_KIND") == "adt"
	oldValue, newValue, extraValue := "metadata->>'oldText'", "metadata__v2->>'newText'", "metadata__v2->>'detail'"
	oldKey, newKey, extraKey := "oldText", "newText", "detail"
	if adt {
		oldValue, newValue, extraValue = "metadata->'fields'->>'text'", "metadata__v2->'fields'->>'text'", "metadata__v2->'fields'->>'extra'"
		oldKey, newKey, extraKey = "text", "text", "extra"
	}
	valuesSQL := "select " + oldValue + "," + newValue + "," + extraValue + " from notes.notes where id="
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	run("v1", "install")
	run("v1", "worker")
	start := func(version string, timeout int) string {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := listener.Addr().String()
		_, port, _ := net.SplitHostPort(address)
		if err := listener.Close(); err != nil {
			t.Fatal(err)
		}
		cmd := pgForwardNativeCommand(f, root, version, "serve")
		cmd.Env = append(cmd.Env, "ROW_PORT="+port, "TESL_PG_POOL_LEASE_TIMEOUT_MS="+strconv.Itoa(timeout))
		var output pgRowAppOutput
		cmd.Stdout = &output
		cmd.Stderr = &output
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait(); close(done) }()
		t.Cleanup(func() {
			_ = cmd.Process.Signal(os.Interrupt)
			select {
			case <-done:
			case <-time.After(20 * time.Second):
				_ = cmd.Process.Kill()
				<-done
			}
		})
		url := "http://" + address
		client := &http.Client{Timeout: time.Second}
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			response, err := client.Get(url + "/health")
			if err == nil {
				_ = response.Body.Close()
				if response.StatusCode == 200 {
					return url
				}
			}
			select {
			case err := <-done:
				t.Fatalf("actual %s Main failed: %v\n%s", version, err, output.String())
			default:
			}
			time.Sleep(25 * time.Millisecond)
		}
		t.Fatalf("actual %s Main did not serve: %s", version, output.String())
		return ""
	}
	call := func(base, method, path string, status int) string {
		req, _ := http.NewRequestWithContext(f.ctx, method, base+path, nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = resp.Body.Close() }()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != status {
			t.Fatalf("%s %s: expected %d got %d %s", method, path, status, resp.StatusCode, body)
		}
		return string(body)
	}
	v1 := start("v1", 10000)
	// Expand an empty window, then let the authentic retained V1 app supply
	// old rows. The failing update must still be the first materialization.
	// A separate Contract trace proves durable backfill of preexisting rows.
	run("v2", "worker")
	call(v1, "POST", "/one", 200)
	call(v1, "POST", "/two", 200)
	v2 := start("v2", 10000)
	call(v2, "PUT", "/conflict", 500)
	var processing, oldRows int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 0 {
		t.Fatal("failed first bulk write committed ABI latch", processing, err)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where _tesl_v=1 and title in ('one','two')").Scan(&oldRows); err != nil || oldRows != 2 {
		t.Fatal("second SQL write failure retained partial first write", oldRows, err)
	}
	if body := call(v2, "GET", "/one", 200); !strings.Contains(body, "one") {
		t.Fatal(body)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"count":7`) || !strings.Contains(body, `"owner":"writer"`) {
		t.Fatal("actual lazy callback", body)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"`+newKey+`":"one"`) || !strings.Contains(body, `"`+extraKey+`":"migrated"`) || (!adt && strings.Contains(body, `"oldText"`)) {
		t.Fatal("lazy read bypassed new JSONB codec", body)
	}
	call(v2, "POST", "/three", 200)
	if adt {
		if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"tag":"Details"`) || strings.Contains(body, `"tag":"Named"`) {
			t.Fatal("new handler omitted ADT conversion", body)
		}
		if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"tag":"Named"`) || strings.Contains(body, `"tag":"Details"`) {
			t.Fatal("old handler cannot decode reverse ADT", body)
		}
	}
	var oldText, newText, detail string
	if err := request.QueryRow(f.ctx, valuesSQL+"'three'").Scan(&oldText, &newText, &detail); err != nil || oldText != "three" || newText != oldText || detail != "made" {
		t.Fatal("insert must encode old and new independently", oldText, newText, detail, err)
	}
	if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"`+oldKey+`":"three"`) || (!adt && strings.Contains(body, `"newText"`)) {
		t.Fatal("old handler cannot decode new insert", body)
	}
	var marker, count int
	var author, owner, title string
	if err := request.QueryRow(f.ctx, "select _tesl_v,count,author,owner from notes.notes where id='three'").Scan(&marker, &count, &author, &owner); err != nil || marker != 2 || count != 9 || author != "writer" || owner != author {
		t.Fatal("actual handler insert", marker, count, author, owner, err)
	}
	call(v2, "PUT", "/all", 200)
	var rows int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where memo='all-edited' and _tesl_v=2").Scan(&rows); err != nil || rows != 3 {
		t.Fatal("multi-row update", rows, err)
	}
	if err := request.QueryRow(f.ctx, valuesSQL+"'one'").Scan(&oldText, &newText, &detail); err != nil || oldText != "one" || newText != oldText || detail != "migrated" {
		t.Fatal("whole-row update must encode both JSONB layouts", oldText, newText, detail, err)
	}
	call(v1, "PUT", "/one", 200)
	if err := request.QueryRow(f.ctx, "select _tesl_v,title from notes.notes where id='one'").Scan(&marker, &title); err != nil || marker != 1 || title != "edited" {
		t.Fatal("late old handler invalidation", marker, title, err)
	}
	if body := call(v2, "GET", "/one", 200); !strings.Contains(body, "edited") {
		t.Fatal("old write not visible", body)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"`+newKey+`":"edited-metadata"`) || !strings.Contains(body, `"`+extraKey+`":"migrated"`) {
		t.Fatal("late old JSONB writer was not remigrated", body)
	}
	call(v2, "PUT", "/one", 200)
	if err := request.QueryRow(f.ctx, valuesSQL+"'one'").Scan(&oldText, &newText, &detail); err != nil || oldText != "edited-metadata" || newText != oldText || detail != "made" {
		t.Fatal("updated whole-row reverse callback/codec", oldText, newText, detail, err)
	}
	if err := request.QueryRow(f.ctx, "select _tesl_v,count,title from notes.notes where id='one'").Scan(&marker, &count, &title); err != nil || marker != 2 || count != 7 || title != "edited" {
		t.Fatal("handler locked RMW", marker, count, title, err)
	}
	bounded := start("v2", 400)
	locked, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := locked.Exec(f.ctx, "select id from notes.notes where id='one' for update"); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	call(bounded, "PUT", "/one", 503)
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatal("typed migration query ignored lease timeout", elapsed)
	}
	if err := locked.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	call(v2, "PUT", "/one", 200)
	before := call(v2, "GET", "/all", 200)
	call(v2, "PUT", "/conflict", 500)
	after := call(v2, "GET", "/all", 200)
	if before != after {
		t.Fatal("SQL unique violation failed to roll back complete update", before, after)
	}
	if adt {
		call(v1, "POST", "/absent", 200)
		if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"tag":"Missing"`) || strings.Contains(body, `"tag":"Absent"`) {
			t.Fatal("lazy nullary ADT migration", body)
		}
		call(v2, "POST", "/missing", 200)
		var oldTag, newTag string
		if err := request.QueryRow(f.ctx, "select metadata->>'tag',metadata__v2->>'tag' from notes.notes where id='missing'").Scan(&oldTag, &newTag); err != nil || oldTag != "Absent" || newTag != "Missing" {
			t.Fatal("reverse nullary ADT codec", oldTag, newTag, err)
		}
		call(v2, "PUT", "/all", 200)
		if err := request.QueryRow(f.ctx, "select metadata->>'tag',metadata__v2->>'tag' from notes.notes where id='absent'").Scan(&oldTag, &newTag); err != nil || oldTag != "Absent" || newTag != "Missing" {
			t.Fatal("materialized nullary ADT codec", oldTag, newTag, err)
		}
		if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"tag":"Absent"`) || strings.Contains(body, `"tag":"Missing"`) {
			t.Fatal("old handler cannot decode reverse nullary ADT", body)
		}
	}
	call(v2, "PUT", "/one", 200)
	// A rejected source row aborts the complete update, including rows decoded
	// before it. The actual Tesl callback supplies Reject; no native substitution.
	call(v1, "POST", "/reject", 200)
	call(v2, "PUT", "/all", 500)
	if err := request.QueryRow(f.ctx, "select memo from notes.notes where id='one'").Scan(&title); err != nil || title != "one-edited" {
		t.Fatal("Reject did not roll back all rows", title, err)
	}
	t.Log("actual V1/V2 Main + unchanged HTTP handlers: lazy read, insert, multi-row update, late old write and Reject rollback passed")
}
