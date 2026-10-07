package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

func pgRowQueueWorkTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_row_queue_conversion_receipts", `
 job_id text not null, source_digest text not null,
 kind text not null check(kind in ('converted','migration-rejected','payload-invalid')),
 original text not null, payload jsonb, reason text not null,
 resume_status text not null check(resume_status in ('pending','dead')),
 attempt_seq bigint not null check(attempt_seq>0),
 primary key(job_id,source_digest),
 check((kind='converted' and payload is not null) or (kind<>'converted' and payload is null))`},
		{"tesl_row_queue_conversion_attempts", `
 job_id text primary key, source_digest text not null,
 attempt_seq bigint not null, transaction_id xid8 not null,
 original text not null, reason text not null,
 resume_status text not null check(resume_status in ('pending','dead'))`},
	}
}

func pgRowQueueWorkTable(name string) bool {
	return name == "tesl_row_queue_conversion_receipts" || name == "tesl_row_queue_conversion_attempts" || name == "tesl_row_queue_restamps"
}

// Reuse the tested selection/attempt/publication machinery, replacing only its
// isolated scope with the actual application installation and completed edge.
// No candidate scope or source table is created in the application database.
func pgRowQueueConversionFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	guard := `
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then
  raise exception 'tesl: application queue conversion requires read committed'; end if;
 select m.database_uuid as identity, d.oid as database_oid, d.datname as database_name,
  r.family,c.queue,c.job_type,c.from_version,c.to_version,st.min_version as floor,c.source_digest as root_digest,m.fence_ns as fence
 into s from ` + ns + `tesl_schema_meta m
 join ` + ns + `tesl_schema_state st on st.id=m.id
 join ` + ns + `tesl_row_versions r on r.version=1
 join ` + ns + `tesl_row_queue_conversion_staging c on c.revision=0 and c.source_digest=binding->>'root'
 join ` + ns + `tesl_row_queue_target_staging t on t.version=c.to_version and t.database_uuid=m.database_uuid and t.fence_ns=m.fence_ns
 join ` + ns + `tesl_row_physical p on p.version=t.version and p.contract=t.contract and p.contract_hash=t.contract_hash
  and p.compiler_abi=t.compiler_abi and p.stored_value_compatibility=t.stored_value_compatibility and not p.epoch_preserving
 join ` + ns + `tesl_schema_versions v on v.version=t.version and v.step='expanded' and v.artefact_hash=p.contract_hash
  and v.snapshot_hash=p.contract_hash and v.source_abi=p.compiler_abi and v.stored_value_compatibility=p.stored_value_compatibility
 join pg_catalog.pg_database d on d.datname=pg_catalog.current_database()
 where m.id=1 and m.format_version=5 and m.database_uuid=expected and c.database_uuid=m.database_uuid and c.fence_ns=m.fence_ns
   and c.from_version=c.to_version-1 and c.to_version>=2 and st.current=c.to_version;
 if not found then raise exception 'tesl: application queue conversion has no exact completed expansion'; end if;
 -- Hold both real version fence domains required for mutation: source
 -- retirement cannot race this transaction, and target admission is rechecked.
 perform pg_catalog.pg_advisory_xact_lock_shared(s.fence,s.from_version);
 perform ` + ns + `tesl_queue_admit(s.to_version,s.queue);
 select min_version into s.floor from ` + ns + `tesl_schema_state where id=1 for share;
`
	sources := `(select source_digest as digest,source_document as document,nullif(parent_digest,'') as parent_digest,revision,from_version from ` + ns + `tesl_row_queue_conversion_staging)`
	var result []pgMigrationControlFunction
	for _, fn := range pgQueueConversionCandidateFunctions(namespace) {
		if fn.name != "tesl_queue_conversion_next" && fn.name != "tesl_queue_conversion_begin" && fn.name != "tesl_queue_conversion_finish" {
			continue
		}
		originalGuard := pgQueueConversionScopeGuard(namespace)
		if !strings.Contains(fn.body, originalGuard) {
			panic("application queue conversion lost its closed scope guard")
		}
		fn.body = strings.Replace(fn.body, originalGuard, guard, 1)
		fn.body = strings.ReplaceAll(fn.body, "s "+ns+"tesl_queue_conversion_scope%rowtype", "s record")
		fn.body = strings.ReplaceAll(fn.body, "source "+ns+"tesl_queue_conversion_sources%rowtype", "source record")
		fn.body = strings.ReplaceAll(fn.body, "from "+ns+"tesl_queue_conversion_sources c", "from "+sources+" c")
		fn.body = strings.ReplaceAll(fn.body, "tesl_queue_conversion_receipts", "tesl_row_queue_conversion_receipts")
		fn.body = strings.ReplaceAll(fn.body, "tesl_queue_conversion_attempts", "tesl_row_queue_conversion_attempts")
		fn.body = strings.ReplaceAll(fn.body, fn.name, "tesl_row_queue_conversion_"+strings.TrimPrefix(fn.name, "tesl_queue_conversion_"))
		fn.name = "tesl_row_queue_conversion_" + strings.TrimPrefix(fn.name, "tesl_queue_conversion_")
		if fn.name == "tesl_row_queue_conversion_finish" {
			// Finish also gets a compiler binding; the isolated protocol keeps
			// its existing signature. Both routes fence the same exact attempt.
			fn.arguments += ", binding jsonb"
		}
		result = append(result, fn)
	}
	result = append(result, pgMigrationControlFunction{"tesl_row_queue_dispatch_sources", "", "TABLE(source_digest text)", "stable", `
begin
 -- Receipt sequence is durable least-recently-served evidence, not a work
 -- cursor or finality claim. Backward index lookup avoids scanning old history.
 return query select c.source_digest from ` + ns + `tesl_row_queue_conversion_staging c
 cross join ` + ns + `tesl_schema_state st
 left join lateral (select r.attempt_seq from ` + ns + `tesl_row_queue_conversion_receipts r
  where r.source_digest=c.source_digest order by r.attempt_seq desc limit 1) served on true
 where st.id=1 and c.to_version=st.current and c.from_version>=st.min_version
 order by coalesce(served.attempt_seq,0),c.queue collate "C",c.job_type collate "C",c.revision;
end`})
	return result
}

// A checked Worker handle grants only one published application edge. The
// caller must still use the exact linked typed adapter for each job transaction.
func pgOpenRowQueueConversion(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, digest string) (pgQueueConversionDB, error) {
	lineage, err := pgQueueConversionCandidateLineage(digest)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	root := lineage[len(lineage)-1]
	if root.fromVersion < 1 || root.toVersion != root.fromVersion+1 {
		return pgQueueConversionDB{}, fmt.Errorf("application queue dispatch requires an adjacent checked edge")
	}
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
		return pgQueueConversionDB{}, fmt.Errorf("application queue dispatch requires exact Worker login")
	}
	state, err := pgInspectRowControl(ctx, tx, namespace, roles)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	if state.Current != root.toVersion {
		return pgQueueConversionDB{}, fmt.Errorf("application queue dispatch requires its published target")
	}
	ns := quoteIdentifier(namespace) + "."
	var document []byte
	var hash, abi, compatibility string
	if err := tx.QueryRow(ctx, "select t.contract,t.contract_hash,t.compiler_abi,t.stored_value_compatibility from "+ns+`tesl_row_queue_target_staging t
 join `+ns+`tesl_schema_versions v on v.version=t.version and v.step='expanded' and v.artefact_hash=t.contract_hash
 where t.version=$1 and t.database_uuid::text=$2 and t.fence_ns=$3`, root.toVersion, state.DatabaseUUID, state.FenceNamespace).Scan(&document, &hash, &abi, &compatibility); err != nil {
		return pgQueueConversionDB{}, err
	}
	plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(document), hash)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	if plan.family != root.family || plan.namespace != namespace || pgRowEpochPreserving(plan) || !root.conversion.list(17) || root.conversion.children[14].value != plan.schemaSnapshotHash || root.conversion.children[16].value != plan.storageSnapshotHash {
		return pgQueueConversionDB{}, fmt.Errorf("application queue callback differs from the completed physical target")
	}
	history := PgCompiledMigrationHistory{Family: plan.family, Namespace: namespace, SourceCompilerABI: abi, StoredValueCompatibility: compatibility}
	before, err := pgReadQueueCandidateInventory(ctx, tx, history, root.fromVersion)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	after, err := pgReadQueueCandidateInventory(ctx, tx, history, root.toVersion)
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	if err := pgVerifyRowQueueTransition(ctx, tx, namespace, state, before.Version, after.Version); err != nil {
		return pgQueueConversionDB{}, err
	}
	for _, source := range lineage {
		var matches bool
		if err := tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and source_digest=$3 and source_document=$4 and parent_digest=$5 and old_contract=$6 and new_contract=$7 from "+ns+"tesl_row_queue_conversion_staging where from_version=$8 and queue=$9 and job_type=$10 and revision=$11", state.DatabaseUUID, state.FenceNamespace, source.spec.digest, mustQueueConversionDocument(source), source.parentDigest, pgQueueConversionPayloadContract(source, false), pgQueueConversionPayloadContract(source, true), root.fromVersion, root.queue, root.job, source.repairRevision).Scan(&matches); err != nil {
			return pgQueueConversionDB{}, err
		}
		if !matches {
			return pgQueueConversionDB{}, fmt.Errorf("application repair lineage differs from its compiler-linked source")
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return pgQueueConversionDB{}, err
	}
	return pgQueueConversionDB{namespace: namespace, identity: state.DatabaseUUID, rootDigest: root.spec.digest, application: true}, nil
}

// One scheduling turn discovers staged code from the application database and
// resolves only compiler-bound typed executables. The budget bounds total job
// transactions across roots and repairs, not just work in an individual stage.
// The public schema-worker integration can use this without exposing adapter
// pointers or treating source metadata as executable authority.
func pgRunRowQueueConversionTurn(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, limit int) (pgQueueConversionBatch, error) {
	var progress pgQueueConversionBatch
	if limit < 1 || limit > pgQueueConversionBatchLimit {
		return progress, fmt.Errorf("application queue turn requires a budget between 1 and %d", pgQueueConversionBatchLimit)
	}
	if err := ctx.Err(); err != nil {
		return progress, err
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return progress, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return progress, err
	}
	if err := pgControlRoles(ctx, tx, roles, false); err != nil {
		return progress, err
	}
	var worker bool
	if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
		return progress, err
	}
	if !worker {
		return progress, fmt.Errorf("application queue turn requires exact Worker login")
	}
	if _, err := pgInspectRowControl(ctx, tx, namespace, roles); err != nil {
		return progress, err
	}
	ns := quoteIdentifier(namespace) + "."
	rows, err := tx.Query(ctx, "select source_digest from "+ns+"tesl_row_queue_dispatch_sources()")
	if err != nil {
		return progress, err
	}
	digests, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return progress, err
	}
	var executables []pgQueueConversionExecutable
	compiledQueueConversionExecutables.RLock()
	for _, digest := range digests {
		executable := compiledQueueConversionExecutables.byDigest[digest]
		if executable == nil {
			compiledQueueConversionExecutables.RUnlock()
			return progress, fmt.Errorf("application queue callback %s is not linked as checked executable code", digest)
		}
		executables = append(executables, executable)
	}
	compiledQueueConversionExecutables.RUnlock()
	if err := tx.Commit(ctx); err != nil {
		return progress, err
	}
	progress.NoEligible = true
	for index, executable := range executables {
		if progress.Selected == limit {
			progress.NoEligible = false
			break
		}
		scope, err := pgOpenRowQueueConversion(ctx, conn, namespace, roles, executable.queueConversionSource().spec.digest)
		if err != nil {
			return progress, err
		}
		remaining := limit - progress.Selected
		stages := len(executables) - index
		quantum := (remaining + stages - 1) / stages
		batch, err := pgRunQueueConversionCandidateBatch(ctx, conn, scope, executable, quantum)
		progress.Selected += batch.Selected
		progress.Converted += batch.Converted
		progress.Rejected += batch.Rejected
		progress.Invalid += batch.Invalid
		progress.Replayed += batch.Replayed
		progress.NoEligible = progress.NoEligible && batch.NoEligible
		if err != nil {
			return progress, err
		}
	}
	return progress, nil
}
