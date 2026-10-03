package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"

	"github.com/jackc/pgx/v5"
)

// Independent read-only expectations, not a replay of live SQL or a stored
// catalog fingerprint. The jobs descriptor is shared with the queue protocol.
func pgExpectedQueueConversionTable(e *pgCatalogExpectations, owner, name string) (*pgCatalogTable, error) {
	if name == "tesl_jobs" {
		table, err := pgExpectedQueueCandidate(e, owner, name)
		if err != nil {
			return nil, err
		}
		table.Indexes = slices.DeleteFunc(table.Indexes, func(i pgCatalogIndex) bool { return !i.ConstraintOwned })
		idx, err := e.index("tesl_queue_conversion_work", table, []string{"queue", "job_type", "schema_version", "seq"}, false, false, false)
		if err != nil {
			return nil, err
		}
		table.Indexes = append(table.Indexes, idx)
		return table, nil
	}
	var cols []pgControlExpectedColumn
	var cons []pgControlExpectedConstraint
	col := func(n, typ string, required bool) {
		cols = append(cols, pgControlExpectedColumn{n, typ, required, "", false})
	}
	constraint := func(kind, expression string, keys ...string) {
		cons = append(cons, pgControlExpectedConstraint{kind, expression, keys})
	}
	check := func(expression string, keys ...string) { constraint("c", expression, keys...) }
	switch name {
	case "tesl_queue_conversion_scope":
		col("id", "int2", true)
		col("identity", "uuid", true)
		col("database_oid", "oid", true)
		for _, n := range []string{"database_name", "family", "queue", "job_type"} {
			col(n, "text", true)
		}
		for _, n := range []string{"from_version", "to_version", "floor"} {
			col(n, "int4", true)
		}
		col("root_digest", "text", true)
		constraint("p", "", "id")
		check("(id = 1)", "id")
		check("((from_version >= 1) AND (to_version = (from_version + 1)) AND (to_version <= 2147483646))", "from_version", "to_version")
		check("((floor = from_version) OR (floor = to_version))", "floor", "from_version", "to_version")
	case "tesl_queue_payloads":
		col("version", "int4", true)
		col("queue", "text", true)
		col("job_type", "text", true)
		col("contract", "bytea", true)
		col("contract_hash", "text", true)
		constraint("p", "", "version", "queue", "job_type")
		check("(encode(sha256(contract), 'hex'::text) = contract_hash)", "contract", "contract_hash")
	case "tesl_queue_conversion_sources":
		col("digest", "text", true)
		col("document", "bytea", true)
		col("parent_digest", "text", false)
		col("revision", "int4", true)
		constraint("p", "", "digest")
		constraint("u", "", "revision")
		constraint("f", "", "parent_digest")
		check("(revision >= 0)", "revision")
		check("(encode(sha256(document), 'hex'::text) = digest)", "document", "digest")
		check("(((revision = 0) AND (parent_digest IS NULL)) OR ((revision > 0) AND (parent_digest IS NOT NULL)))", "revision", "parent_digest")
	case "tesl_queue_conversion_receipts":
		for _, n := range []string{"job_id", "source_digest", "kind", "original"} {
			col(n, "text", true)
		}
		col("payload", "jsonb", false)
		col("reason", "text", true)
		col("resume_status", "text", true)
		col("attempt_seq", "int8", true)
		constraint("p", "", "job_id", "source_digest")
		constraint("f", "", "source_digest")
		check("(kind = ANY (ARRAY['converted'::text, 'migration-rejected'::text, 'payload-invalid'::text]))", "kind")
		check("(resume_status = ANY (ARRAY['pending'::text, 'dead'::text]))", "resume_status")
		check("(attempt_seq > 0)", "attempt_seq")
		check("(((kind = 'converted'::text) AND (payload IS NOT NULL)) OR ((kind <> 'converted'::text) AND (payload IS NULL)))", "kind", "payload")
	case "tesl_queue_conversion_attempts":
		col("job_id", "text", true)
		col("source_digest", "text", true)
		col("attempt_seq", "int8", true)
		col("transaction_id", "xid8", true)
		for _, n := range []string{"original", "reason", "resume_status"} {
			col(n, "text", true)
		}
		constraint("p", "", "job_id")
		constraint("f", "", "job_id")
		constraint("f", "", "source_digest")
		check("(resume_status = ANY (ARRAY['pending'::text, 'dead'::text]))", "resume_status")
	default:
		return nil, fmt.Errorf("unknown queue conversion table %q", name)
	}
	table, err := pgBuildExpectedControlTable(e, owner, name, cols, cons)
	if err != nil {
		return nil, err
	}
	if name == "tesl_queue_conversion_receipts" {
		idx, err := e.index("tesl_queue_conversion_latest", table, []string{"job_id", "attempt_seq"}, false, false, false)
		if err != nil {
			return nil, err
		}
		table.Indexes = append(table.Indexes, idx)
	}
	return table, nil
}

func pgQueueConversionCandidateCatalog(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
	meta, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return err
	}
	names := []string{"tesl_queue_conversion_scope", "tesl_queue_payloads", "tesl_queue_conversion_sources", "tesl_jobs", "tesl_queue_conversion_receipts", "tesl_queue_conversion_attempts"}
	expectedRelations := append(slices.Clone(names), "tesl_jobs_seq_seq")
	rows, err := tx.Query(ctx, `select c.relname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relkind not in ('i','I') order by c.relname`, namespace)
	if err != nil {
		return err
	}
	actualRelations, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	slices.Sort(expectedRelations)
	if !slices.Equal(actualRelations, expectedRelations) {
		return fmt.Errorf("queue conversion protected relation set differs")
	}
	fks := []pgQueueCandidateFK{
		{"tesl_jobs", []string{"schema_version", "queue", "job_type"}, "tesl_queue_payloads", []string{"version", "queue", "job_type"}},
		{"tesl_queue_conversion_sources", []string{"parent_digest"}, "tesl_queue_conversion_sources", []string{"digest"}},
		{"tesl_queue_conversion_receipts", []string{"source_digest"}, "tesl_queue_conversion_sources", []string{"digest"}},
		{"tesl_queue_conversion_attempts", []string{"source_digest"}, "tesl_queue_conversion_sources", []string{"digest"}},
		{"tesl_queue_conversion_attempts", []string{"job_id"}, "tesl_jobs", []string{"id"}},
	}
	if err := pgQueueForeignKeyCatalog(ctx, tx, namespace, names, fks, []string{"tesl_queue_conversion_attempts.tesl_jobs"}); err != nil {
		return err
	}
	for _, name := range names {
		expected, err := pgExpectedQueueConversionTable(meta, roles.Owner, name)
		if err != nil {
			return err
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, name)
		if err != nil {
			return err
		}
		if actual == nil {
			return fmt.Errorf("queue conversion table %s is missing", name)
		}
		actual.Triggers = []string{} // Exact RI trigger semantics verified above.
		actual.TriggerDefinitions = nil
		if !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return fmt.Errorf("queue conversion table %s differs from its closed descriptor", name)
		}
		if err := pgQueueTableACL(ctx, tx, namespace, name, []string{}); err != nil {
			return err
		}
		sequences, err := pgReadControlSequences(ctx, tx, namespace, name, roles.Worker)
		if err != nil {
			return err
		}
		want := []pgControlSequence{}
		if name == "tesl_jobs" {
			var typ uint32
			if err := tx.QueryRow(ctx, "select 'pg_catalog.int8'::pg_catalog.regtype::oid").Scan(&typ); err != nil {
				return err
			}
			want = append(want, pgControlSequence{Column: "seq", Owner: roles.Owner, Type: typ, Start: 1, Increment: 1, Min: 1, Max: 9223372036854775807, Cache: 1})
		}
		if !reflect.DeepEqual(sequences, want) {
			return fmt.Errorf("queue conversion sequence differs")
		}
	}
	var namedKey bool
	if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_constraint k join pg_catalog.pg_class c on c.oid=k.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relname='tesl_queue_conversion_attempts' and k.conname='tesl_queue_conversion_attempts_pkey' and k.contype='p')`, namespace).Scan(&namedKey); err != nil {
		return err
	}
	if !namedKey {
		return fmt.Errorf("queue conversion attempt key was renamed")
	}
	wantFunctions := []string{}
	for _, fn := range pgQueueConversionCandidateFunctions(namespace) {
		if err := pgControlFunctionCatalog(ctx, tx, namespace, pgQueueConversionFunctionRoles(roles, fn), fn); err != nil {
			return err
		}
		wantFunctions = append(wantFunctions, fn.name+"("+pgControlArgumentTypes(fn)+")")
	}
	rows, err = tx.Query(ctx, `select p.proname||'('||replace(pg_catalog.oidvectortypes(p.proargtypes),', ',',')||')' from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname=$1`, namespace)
	if err != nil {
		return err
	}
	actualFunctions, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	slices.Sort(wantFunctions)
	slices.Sort(actualFunctions)
	if !slices.Equal(wantFunctions, actualFunctions) {
		return fmt.Errorf("queue conversion function set differs")
	}
	return nil
}

// Reconstruct an execution handle using only Worker authority and catalog/data
// reads. The exact installed repair head must be linked in this binary. No
// installer-returned handle, TEMP privilege or source files are required.
func pgOpenQueueConversionCandidate(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, digest string) (pgQueueConversionDB, error) {
	lineage, err := pgQueueConversionCandidateLineage(digest)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	root := lineage[len(lineage)-1]
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return pgQueueConversionDB{}, err
	}
	if err := pgControlRoles(ctx, tx, roles, false); err != nil {
		return pgQueueConversionDB{}, err
	}
	var worker bool
	if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
		return pgQueueConversionDB{}, err
	}
	if !worker {
		return pgQueueConversionDB{}, fmt.Errorf("queue conversion opener requires its Worker login")
	}
	if exists, err := pgControlNamespace(ctx, tx, namespace, roles.Owner, roles.Worker); err != nil {
		return pgQueueConversionDB{}, err
	} else if !exists {
		return pgQueueConversionDB{}, fmt.Errorf("queue conversion namespace is missing")
	}
	var namespaceUnsafe bool
	err = tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.aclexplode(coalesce(n.nspacl,pg_catalog.acldefault('n',n.nspowner))) a
 where a.grantee<>n.nspowner and (a.privilege_type<>'USAGE' or a.is_grantable or a.grantee not in (select oid from pg_catalog.pg_roles where rolname=any($2::text[]))))
 or exists(select 1 from pg_catalog.pg_roles r where r.rolname=any($2::text[]) and not pg_catalog.has_schema_privilege(r.oid,n.oid,'USAGE'))
 from pg_catalog.pg_namespace n where n.nspname=$1`, namespace, []string{roles.Worker, roles.Request}).Scan(&namespaceUnsafe)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	if namespaceUnsafe {
		return pgQueueConversionDB{}, fmt.Errorf("queue conversion namespace grants differ")
	}
	if err := pgQueueConversionCandidateCatalog(ctx, tx, namespace, roles); err != nil {
		return pgQueueConversionDB{}, err
	}
	var snapshot struct {
		BelowFloor bool `json:"below_floor"`
		Scope      struct {
			Identity, Family, Queue string
			DatabaseOID             uint32 `json:"database_oid,string"`
			DatabaseName            string `json:"database_name"`
			Job                     string `json:"job_type"`
			From                    int    `json:"from_version"`
			To                      int    `json:"to_version"`
			Floor                   int
			Root                    string `json:"root_digest"`
		}
		Sources []struct {
			Digest, Document, Parent string
			Revision                 int
		}
		Payloads []struct {
			Version                    int
			Queue, Job, Contract, Hash string
		}
	}
	var encoded []byte
	if err := tx.QueryRow(ctx, "select "+quoteIdentifier(namespace)+".tesl_queue_conversion_snapshot()").Scan(&encoded); err != nil {
		return pgQueueConversionDB{}, err
	}
	if err := json.Unmarshal(encoded, &snapshot); err != nil {
		return pgQueueConversionDB{}, err
	}
	s := snapshot.Scope
	var oid uint32
	var database string
	if err := tx.QueryRow(ctx, "select oid,datname from pg_catalog.pg_database where datname=pg_catalog.current_database()").Scan(&oid, &database); err != nil {
		return pgQueueConversionDB{}, err
	}
	if s.Identity == "" || s.DatabaseOID != oid || s.DatabaseName != database || s.Family != root.family || s.Queue != root.queue || s.Job != root.job || s.From != root.fromVersion || s.To != root.toVersion || s.Root != root.spec.digest || (s.Floor != s.From && s.Floor != s.To) || snapshot.BelowFloor {
		return pgQueueConversionDB{}, fmt.Errorf("queue conversion installation differs from compiled transition")
	}
	if len(snapshot.Sources) != len(lineage) || len(snapshot.Payloads) != 2 {
		return pgQueueConversionDB{}, fmt.Errorf("queue conversion installed source set differs")
	}
	for i, actual := range snapshot.Sources {
		expected := lineage[len(lineage)-1-i]
		if actual.Revision != i || actual.Digest != expected.spec.digest || actual.Document != expected.spec.document || actual.Parent != expected.parentDigest {
			return pgQueueConversionDB{}, fmt.Errorf("queue conversion installed repair history differs")
		}
	}
	for i, actual := range snapshot.Payloads {
		expected := pgQueueConversionPayloadContract(root, i == 1)
		if actual.Version != root.fromVersion+i || actual.Queue != root.queue || actual.Job != root.job || actual.Contract != hex.EncodeToString(expected) || actual.Hash != fmt.Sprintf("%x", sha256.Sum256(expected)) {
			return pgQueueConversionDB{}, fmt.Errorf("queue conversion installed payload contract differs")
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return pgQueueConversionDB{}, err
	}
	return pgQueueConversionDB{namespace: namespace, identity: s.Identity, rootDigest: root.spec.digest}, nil
}
