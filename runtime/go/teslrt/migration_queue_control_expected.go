package teslrt

import (
	"context"
	"fmt"
	"reflect"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Deliberately independent from the CREATE TABLE descriptors. Production control
// inspection never selects this unpublished candidate descriptor.
func pgExpectedQueueCandidate(e *pgCatalogExpectations, owner, name string) (*pgCatalogTable, error) {
	var cols []pgControlExpectedColumn
	var cons []pgControlExpectedConstraint
	col := func(n, t string, required bool, def string) {
		cols = append(cols, pgControlExpectedColumn{n, t, required, def, false})
	}
	constraint := func(kind, expr string, keys ...string) {
		cons = append(cons, pgControlExpectedConstraint{kind, expr, keys})
	}
	primary := func(keys ...string) { constraint("p", "", keys...) }
	unique := func(keys ...string) { constraint("u", "", keys...) }
	check := func(expr string, keys ...string) { constraint("c", expr, keys...) }
	bounded := func(n string) { check("(("+n+" >= 1) AND ("+n+" <= 2147483646))", n) }
	hash := func(n string) { check("("+n+" ~ '^[0-9a-f]{64}$'::text)", n) }
	switch name {
	case "tesl_queue_baseline":
		col("id", "int2", true, "")
		col("inventory_authority", "text", true, "")
		col("established_by", "text", true, "")
		col("initial_version", "int4", true, "")
		col("inventory_hash", "text", false, "")
		col("recorded_at", "timestamptz", true, "clock_timestamp()")
		primary("id")
		check("(id = 1)", "id")
		bounded("initial_version")
		hash("inventory_hash")
		check("(inventory_authority = ANY (ARRAY['complete'::text, 'unknown'::text]))", "inventory_authority")
		check("(established_by = ANY (ARRAY['fresh-install'::text, 'format-upgrade'::text]))", "established_by")
		check("(((inventory_authority = 'complete'::text) AND (established_by = 'fresh-install'::text) AND (inventory_hash IS NOT NULL)) OR ((inventory_authority = 'unknown'::text) AND (established_by = 'format-upgrade'::text) AND (inventory_hash IS NULL)))", "inventory_authority", "established_by", "inventory_hash")
	case "tesl_queue_versions":
		col("version", "int4", true, "")
		col("storage_snapshot_hash", "text", true, "")
		col("schema_snapshot_hash", "text", true, "")
		col("inventory_hash", "text", true, "")
		col("source_seal_inventory", "text", true, "")
		col("compiler_abi", "text", true, "")
		col("stored_value_compatibility", "text", true, "")
		col("contract_count", "int4", true, "")
		col("payload_count", "int4", true, "")
		col("registered_at", "timestamptz", true, "clock_timestamp()")
		primary("version")
		bounded("version")
		hash("storage_snapshot_hash")
		hash("schema_snapshot_hash")
		hash("inventory_hash")
		check("(source_seal_inventory = ANY (ARRAY['complete'::text, 'unknown'::text, 'unrecorded'::text]))", "source_seal_inventory")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
		check("(stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'::text)", "stored_value_compatibility")
		check("(contract_count >= 0)", "contract_count")
		check("(payload_count >= 0)", "payload_count")
	case "tesl_queue_contracts":
		col("version", "int4", true, "")
		col("queue", "text", true, "")
		col("payload_count", "int4", true, "")
		primary("version", "queue")
		check("(length(queue) > 0)", "queue")
		check("(payload_count > 0)", "payload_count")
		constraint("f", "", "version")
	case "tesl_queue_payloads":
		col("version", "int4", true, "")
		col("queue", "text", true, "")
		col("job_type", "text", true, "")
		col("contract_format", "text", true, "")
		col("contract", "bytea", true, "")
		col("contract_hash", "text", true, "")
		primary("version", "queue", "job_type")
		unique("version", "job_type")
		constraint("f", "", "version", "queue")
		check("(length(job_type) > 0)", "job_type")
		check("(contract_format = 'tesl-queue-payload-v1'::text)", "contract_format")
		hash("contract_hash")
		check("(encode(sha256(contract), 'hex'::text) = contract_hash)", "contract", "contract_hash")
	case "tesl_jobs":
		col("id", "text", true, "")
		col("queue", "text", true, "")
		col("job_type", "text", true, "")
		col("payload", "jsonb", true, "")
		col("schema_version", "int4", true, "")
		col("status", "text", true, "")
		col("attempts", "int4", true, "0")
		col("next_attempt_at", "timestamptz", true, "clock_timestamp()")
		col("seq", "int8", true, "")
		cols[len(cols)-1].identity = true
		col("locked_at", "timestamptz", false, "")
		col("locked_by", "text", false, "")
		col("claim_token", "text", false, "")
		col("claim_seq", "int8", true, "0")
		col("claimed_by_version", "int4", false, "")
		col("claim_xid", "xid8", false, "")
		col("lease_until", "timestamptz", false, "")
		col("dead_reason", "text", false, "")
		col("dead_detail", "text", false, "")
		col("created_at", "timestamptz", true, "clock_timestamp()")
		primary("id")
		unique("seq")
		bounded("schema_version")
		bounded("claimed_by_version")
		constraint("f", "", "schema_version", "queue", "job_type")
		check("(status = ANY (ARRAY['pending'::text, 'processing'::text, 'dead'::text, 'dead_processing'::text, 'quarantined'::text]))", "status")
		check("(attempts >= 0)", "attempts")
		check("(claim_seq >= 0)", "claim_seq")
		check("(octet_length(dead_detail) <= 2048)", "dead_detail")
		check("(((status = ANY (ARRAY['processing'::text, 'dead_processing'::text])) AND (locked_at IS NOT NULL) AND (locked_by IS NOT NULL) AND (claim_token IS NOT NULL) AND (claim_seq > 0) AND (claimed_by_version IS NOT NULL) AND (claim_xid IS NOT NULL) AND (lease_until IS NOT NULL)) OR ((status <> ALL (ARRAY['processing'::text, 'dead_processing'::text])) AND (locked_at IS NULL) AND (locked_by IS NULL) AND (claim_token IS NULL) AND (claimed_by_version IS NULL) AND (claim_xid IS NULL) AND (lease_until IS NULL)))", "status", "locked_at", "locked_by", "claim_token", "claim_seq", "claimed_by_version", "claim_xid", "lease_until")
		check("(((status = ANY (ARRAY['dead'::text, 'dead_processing'::text])) AND (dead_reason IS NOT NULL) AND (dead_reason = 'attempts-exhausted'::text)) OR ((status = 'quarantined'::text) AND (dead_reason IS NOT NULL) AND (dead_reason = ANY (ARRAY['payload-invalid'::text, 'migration-rejected'::text, 'legacy-unresolved'::text]))) OR ((status = ANY (ARRAY['pending'::text, 'processing'::text])) AND (dead_reason IS NULL)))", "status", "dead_reason")
	default:
		return nil, fmt.Errorf("unknown candidate queue table %q", name)
	}
	table, err := pgBuildExpectedControlTable(e, owner, name, cols, cons)
	if err != nil {
		return nil, err
	}
	if name == "tesl_jobs" {
		for _, def := range []struct {
			name string
			keys []string
		}{{"tesl_jobs_claim_idx", []string{"queue", "status", "next_attempt_at", "seq"}}, {"tesl_jobs_version_idx", []string{"schema_version", "status", "claimed_by_version", "lease_until"}}} {
			idx, err := e.index(def.name, table, def.keys, false, false, false)
			if err != nil {
				return nil, err
			}
			table.Indexes = append(table.Indexes, idx)
		}
	}
	return table, nil
}

// The general catalog DTO intentionally does not describe FK targets. Candidate
// queues therefore check complete FK identities AND all four built-in RI triggers
// independently, before ignoring their server-assigned names in table comparison.
type pgQueueCandidateFK struct {
	Table      string
	Keys       []string
	Target     string
	TargetKeys []string
}

var pgQueueCandidateFKs = []pgQueueCandidateFK{
	{"tesl_queue_contracts", []string{"version"}, "tesl_queue_versions", []string{"version"}},
	{"tesl_queue_payloads", []string{"version", "queue"}, "tesl_queue_contracts", []string{"version", "queue"}},
	{"tesl_jobs", []string{"schema_version", "queue", "job_type"}, "tesl_queue_payloads", []string{"version", "queue", "job_type"}},
}

func pgQueueCandidateCatalog(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
	meta, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return err
	}
	names := []string{"tesl_jobs_seq_seq"}
	for _, spec := range pgMigrationControlTables {
		names = append(names, spec.name)
	}
	for _, spec := range pgQueueCandidateTables(namespace) {
		names = append(names, spec.name)
	}
	var extra bool
	err = tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_roles r on r.oid=c.relowner where n.nspname=$1 and c.relkind not in ('i','I') and ((r.rolname=$2 and not(c.relname=any($3::text[]))) or ((pg_catalog.left(c.relname,12)='tesl_schema_' or pg_catalog.left(c.relname,11)='tesl_queue_' or c.relname='tesl_jobs') and not(c.relname=any($3::text[])))))`, namespace, roles.Owner, names).Scan(&extra)
	if err != nil {
		return err
	}
	if extra {
		return fmt.Errorf("unrecorded protected relation in candidate format 4")
	}
	if err := pgQueueCandidateForeignKeys(ctx, tx, namespace); err != nil {
		return err
	}
	for _, spec := range pgQueueCandidateTables(namespace) {
		expected, err := pgExpectedQueueCandidate(meta, roles.Owner, spec.name)
		if err != nil {
			return err
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, spec.name)
		if err != nil {
			return err
		}
		if actual == nil {
			return fmt.Errorf("candidate queue table %s is missing", spec.name)
		}
		actual.Triggers = []string{} // Complete trigger identity checked immediately above.
		if !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return fmt.Errorf("candidate queue table %s differs from unpublished format 4", spec.name)
		}
		if spec.name == "tesl_jobs" {
			var indexNames []string
			rows, err := tx.Query(ctx, `select ix.relname from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_class ix on ix.oid=i.indexrelid where n.nspname=$1 and c.relname=$2 and not exists(select 1 from pg_catalog.pg_constraint k where k.conindid=i.indexrelid and k.conrelid=c.oid) order by ix.relname`, namespace, spec.name)
			if err != nil {
				return err
			}
			indexNames, err = pgx.CollectRows(rows, pgx.RowTo[string])
			if err != nil {
				return err
			}
			if !reflect.DeepEqual(indexNames, []string{"tesl_jobs_claim_idx", "tesl_jobs_version_idx"}) {
				return fmt.Errorf("candidate queue index names differ")
			}
		}
		if err := pgQueueCandidateACL(ctx, tx, namespace, spec.name, roles); err != nil {
			return err
		}
		seqs, err := pgReadControlSequences(ctx, tx, namespace, spec.name, roles.Worker)
		if err != nil {
			return err
		}
		want := []pgControlSequence{}
		if spec.name == "tesl_jobs" {
			var typ uint32
			if err := tx.QueryRow(ctx, "select 'pg_catalog.int8'::pg_catalog.regtype::oid").Scan(&typ); err != nil {
				return err
			}
			want = append(want, pgControlSequence{Column: "seq", Owner: roles.Owner, Type: typ, Start: 1, Increment: 1, Min: 1, Max: 9223372036854775807, Cache: 1})
		}
		if !reflect.DeepEqual(seqs, want) {
			return fmt.Errorf("candidate queue sequence definition, owner or ACL differs")
		}
	}
	return nil
}

func pgQueueCandidateACL(ctx context.Context, tx pgx.Tx, namespace, name string, roles PgMigrationControlRoles) error {
	readers := []string{roles.Worker}
	if roles.Request != "" {
		readers = append(readers, roles.Request)
	}
	if name == "tesl_jobs" {
		readers = []string{}
	}
	var unsafe bool
	err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a where a.grantee<>c.relowner and (a.is_grantable or a.privilege_type<>'SELECT' or not exists(select 1 from pg_catalog.pg_roles r where r.oid=a.grantee and r.rolname=any($3::text[])))) or exists(select 1 from pg_catalog.pg_attribute col cross join lateral pg_catalog.aclexplode(col.attacl) a where col.attrelid=c.oid and a.grantee<>c.relowner) or exists(select 1 from pg_catalog.pg_roles r where r.rolname=any($3::text[]) and not pg_catalog.has_table_privilege(r.oid,c.oid,'SELECT')) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relname=$2`, namespace, name, readers).Scan(&unsafe)
	if err != nil {
		return err
	}
	if unsafe {
		return fmt.Errorf("candidate queue table %s has different protected grants", name)
	}
	if name == "tesl_jobs" {
		err = tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class t join pg_catalog.pg_namespace n on n.oid=t.relnamespace join pg_catalog.pg_depend d on d.refobjid=t.oid and d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass and d.classid='pg_catalog.pg_class'::pg_catalog.regclass and d.deptype in ('a','i') join pg_catalog.pg_class s on s.oid=d.objid join pg_catalog.pg_namespace sn on sn.oid=s.relnamespace where n.nspname=$1 and t.relname=$2 and s.relkind='S' and (sn.nspname<>$1 or s.relname<>'tesl_jobs_seq_seq' or exists(select 1 from pg_catalog.aclexplode(coalesce(s.relacl,pg_catalog.acldefault('S',s.relowner))) a where a.grantee<>s.relowner)))`, namespace, name).Scan(&unsafe)
		if err != nil {
			return err
		}
		if unsafe {
			return fmt.Errorf("candidate queue identity sequence namespace, name or grants differ")
		}
	}
	return nil
}

func pgQueueCandidateForeignKeys(ctx context.Context, tx pgx.Tx, ns string) error {
	tables := []string{}
	for _, s := range pgQueueCandidateTables(ns) {
		tables = append(tables, s.name)
	}
	rows, err := tx.Query(ctx, `select c.relname, array(select a.attname::text from unnest(k.conkey) with ordinality x(n,o) join pg_catalog.pg_attribute a on a.attrelid=c.oid and a.attnum=x.n order by x.o),tc.relname,array(select a.attname::text from unnest(k.confkey) with ordinality x(n,o) join pg_catalog.pg_attribute a on a.attrelid=tc.oid and a.attnum=x.n order by x.o), tn.nspname=$1 and k.confmatchtype='s' and k.confupdtype='a' and k.confdeltype='a' and not k.condeferrable and not k.condeferred and k.convalidated and coalesce((pg_catalog.to_jsonb(k)->>'conenforced')::boolean,true) and k.conparentid=0 and k.conislocal and k.coninhcount=0 from pg_catalog.pg_constraint k join pg_catalog.pg_class c on c.oid=k.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_class tc on tc.oid=k.confrelid join pg_catalog.pg_namespace tn on tn.oid=tc.relnamespace where n.nspname=$1 and c.relname=any($2::text[]) and k.contype='f'`, ns, tables)
	if err != nil {
		return err
	}
	found := []string{}
	for rows.Next() {
		var fk pgQueueCandidateFK
		var valid bool
		if err := rows.Scan(&fk.Table, &fk.Keys, &fk.Target, &fk.TargetKeys, &valid); err != nil {
			rows.Close()
			return err
		}
		if !valid {
			rows.Close()
			return fmt.Errorf("candidate queue foreign key semantics differ")
		}
		found = append(found, fmt.Sprint(fk))
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	want := []string{}
	for _, fk := range pgQueueCandidateFKs {
		want = append(want, fmt.Sprint(fk))
	}
	slices.Sort(found)
	slices.Sort(want)
	if !reflect.DeepEqual(found, want) {
		return fmt.Errorf("candidate queue foreign key targets differ")
	}
	rows, err = tx.Query(ctx, `select c.relname,cc.relname,tc.relname,p.proname,t.tgtype,t.tgisinternal and t.tgenabled='O' and not t.tgdeferrable and not t.tginitdeferred and t.tgnargs=0 and pg_catalog.octet_length(t.tgargs)=0 and t.tgqual is null and t.tgoldtable is null and t.tgnewtable is null and t.tgparentid=0 and pn.nspname='pg_catalog' and cn.nspname=$1 and tn.nspname=$1 and t.tgconstrrelid=case when c.oid=k.conrelid then k.confrelid else k.conrelid end from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace left join pg_catalog.pg_constraint k on k.oid=t.tgconstraint left join pg_catalog.pg_class cc on cc.oid=k.conrelid left join pg_catalog.pg_namespace cn on cn.oid=cc.relnamespace left join pg_catalog.pg_class tc on tc.oid=k.confrelid left join pg_catalog.pg_namespace tn on tn.oid=tc.relnamespace join pg_catalog.pg_proc p on p.oid=t.tgfoid join pg_catalog.pg_namespace pn on pn.oid=p.pronamespace where n.nspname=$1 and c.relname=any($2::text[])`, ns, tables)
	if err != nil {
		return err
	}
	found = []string{}
	for rows.Next() {
		var table, source, target, fn string
		var typ int
		var valid bool
		if err := rows.Scan(&table, &source, &target, &fn, &typ, &valid); err != nil {
			rows.Close()
			return fmt.Errorf("candidate queue has an unexpected trigger: %w", err)
		}
		if !valid {
			rows.Close()
			return fmt.Errorf("candidate queue referential trigger differs or is disabled")
		}
		found = append(found, strings.Join([]string{table, source, target, fn, fmt.Sprint(typ)}, "|"))
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	want = []string{}
	for _, fk := range pgQueueCandidateFKs {
		for _, tr := range []struct {
			table, fn string
			typ       int
		}{{fk.Table, "RI_FKey_check_ins", 5}, {fk.Table, "RI_FKey_check_upd", 17}, {fk.Target, "RI_FKey_noaction_del", 9}, {fk.Target, "RI_FKey_noaction_upd", 17}} {
			want = append(want, strings.Join([]string{tr.table, fk.Table, fk.Target, tr.fn, fmt.Sprint(tr.typ)}, "|"))
		}
	}
	slices.Sort(found)
	slices.Sort(want)
	if !reflect.DeepEqual(found, want) {
		return fmt.Errorf("candidate queue referential trigger set differs")
	}
	return nil
}
