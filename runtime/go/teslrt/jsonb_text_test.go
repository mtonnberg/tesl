package teslrt

import "testing"

// Each expected string is what PostgreSQL (17) answers for `$1::jsonb::text`, captured from a
// live server; the canonical form was also compared with PostgreSQL over a few hundred
// generated documents.
func TestJsonbTextMatchesPostgres(t *testing.T) {
	cases := []struct{ in, want string }{
		{`{"kind":"started","worktreePath":"/w","branch":"b","container":"c","agent":"claude","repoRoot":"/r"}`,
			`{"kind": "started", "agent": "claude", "branch": "b", "repoRoot": "/r", "container": "c", "worktreePath": "/w"}`},
		{`{"n":1.50e1,"z":-0.0,"s":"a\/bé\t"}`, `{"n": 15.0, "s": "a/bé\t", "z": 0.0}`},
		{`{"a":1,"a":2}`, `{"a": 2}`},
		{`[1,  2 ,3]`, `[1, 2, 3]`},
		{` { } `, `{}`},
		{`1e2`, `100`},
		{`1e-2`, `0.01`},
		{`12.345e-1`, `1.2345`},
		{`-1.5e-3`, `-0.0015`},
		{`0.10`, `0.10`},
		{`"\u0001\u001f"`, `"\u0001\u001f"`},
		{`"😀"`, `"😀"`},
		{`null`, `null`},
	}
	for _, c := range cases {
		if got := JsonbText(c.in); got != c.want {
			t.Errorf("JsonbText(%s) = %s, want %s", c.in, got, c.want)
		}
	}
}

// PostgreSQL refuses these writes, so the memory store does too.
func TestJsonbTextRejectsWhatPostgresRejects(t *testing.T) {
	for _, in := range []string{`{`, `nope`, `[1,]`, `"\u0000"`, `{"a":1} x`, ``} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("JsonbText(%q) accepted text PostgreSQL rejects", in)
				}
			}()
			JsonbText(in)
		}()
	}
}

type jsonbRow struct {
	ID   string
	Body string
}

// A normalized table stores PostgreSQL's form on every write path, and an insert still
// answers the row it was given.
func TestNormalizedTableStoresPostgresForm(t *testing.T) {
	table := NewTableNormalized(func(row jsonbRow) jsonbRow {
		row.Body = JsonbText(row.Body)
		return row
	})
	same := func(a, b jsonbRow) bool { return a.ID == b.ID }
	inserted := TableInsert(table, "Doc", jsonbRow{"a", `{"b":1,"a":2}`}, same)
	if inserted.Body != `{"b":1,"a":2}` {
		t.Fatalf("insert answered %q, want its argument", inserted.Body)
	}
	read := func(id string) string {
		got := TableSelectOne(table, func(row jsonbRow) bool { return row.ID == id })
		return got.SomethingValue.Body
	}
	if got := read("a"); got != `{"a": 2, "b": 1}` {
		t.Fatalf("stored %q", got)
	}
	TableInsertMany(table, "Doc", []jsonbRow{{"m", `[1,2]`}}, same)
	if got := read("m"); got != `[1, 2]` {
		t.Fatalf("insertMany stored %q", got)
	}
	TableUpdate(table, func(row jsonbRow) bool { return row.ID == "a" },
		func(row jsonbRow) jsonbRow { row.Body = `{"z":true}`; return row })
	if got := read("a"); got != `{"z": true}` {
		t.Fatalf("update stored %q", got)
	}
	returned := TableUpdateReturnOne(table, func(row jsonbRow) bool { return row.ID == "a" },
		func(row jsonbRow) jsonbRow { row.Body = `{"y":1.0}`; return row })
	if returned.Body != `{"y": 1.0}` {
		t.Fatalf("updateAndReturnOne answered %q, want the stored form", returned.Body)
	}
	TableUpsert(table, "Doc", jsonbRow{"u", `{"k" : 1}`}, same,
		func(existing, incoming jsonbRow) jsonbRow { return incoming }, same)
	if got := read("u"); got != `{"k": 1}` {
		t.Fatalf("upsert stored %q", got)
	}
}
