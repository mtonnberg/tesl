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
		{"tesl_row_queue_conversion_failures", `
 job_id text not null, source_digest text not null,
 attempt_seq bigint not null check(attempt_seq>0),
 payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
 code text not null check(code in ('execution-budget','execution-trap','invalid-result')),
 primary key(job_id,source_digest,attempt_seq)`},
		{"tesl_row_queue_discards", `
 job_id text not null, source_digest text not null, attempt_seq bigint not null check(attempt_seq>0),
 payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'), reason text not null,
 primary key(job_id,source_digest)`},
	}
}

func pgRowQueueWorkTable(name string) bool {
	return name == "tesl_row_queue_conversion_receipts" || name == "tesl_row_queue_conversion_attempts" || name == "tesl_row_queue_restamps" || name == "tesl_row_queue_conversion_failures" || name == "tesl_row_queue_discards"
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
	sources := `(select source_digest as digest,source_document as document,nullif(parent_digest,'') as parent_digest,revision,from_version,policy,discard_reason from ` + ns + `tesl_row_queue_conversion_staging)`
	exactBinding := `exists(select 1 from ` + ns + `tesl_row_queue_conversion_staging c where c.source_digest=digest
  and c.database_uuid=expected and c.fence_ns=s.fence and c.queue=s.queue and c.job_type=s.job_type
  and c.from_version=s.from_version and c.to_version=s.to_version
  and binding=pg_catalog.jsonb_build_object('document',pg_catalog.encode(c.source_document,'hex'),
   'parent',nullif(c.parent_digest,''),'revision',c.revision,'family',s.family,'queue',c.queue,'job',c.job_type,
   'from',c.from_version,'to',c.to_version,'root',s.root_digest,'policy',c.policy,'discardReason',c.discard_reason,
   'old',pg_catalog.encode(c.old_contract,'hex'),'new',pg_catalog.encode(c.new_contract,'hex')))`
	failureEligible := `exists(select 1 from ` + ns + `tesl_row_queue_conversion_failures f
 where f.job_id=j.id and f.source_digest=source.parent_digest and f.attempt_seq<=j.claim_seq
 and f.payload_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex')
 and not exists(select 1 from ` + ns + `tesl_row_queue_conversion_receipts newer where newer.job_id=j.id and newer.attempt_seq>f.attempt_seq)
 and not exists(select 1 from ` + ns + `tesl_row_queue_conversion_failures newer where newer.job_id=j.id and newer.attempt_seq>f.attempt_seq))`
	superseded := `exists(select 1 from ` + ns + `tesl_row_queue_conversion_staging later
 where later.from_version=s.from_version and later.queue=s.queue and later.job_type=s.job_type
 and later.policy='unconverted' and later.revision>source.revision)`
	var result []pgMigrationControlFunction
	for _, fn := range pgQueueConversionCandidateFunctions(namespace) {
		if fn.name != "tesl_queue_conversion_next" && fn.name != "tesl_queue_conversion_begin" && fn.name != "tesl_queue_conversion_finish" {
			continue
		}
		originalGuard := pgQueueConversionScopeGuard(namespace)
		if !strings.Contains(fn.body, originalGuard) {
			panic("application queue conversion lost its closed scope guard")
		}
		operationGuard := guard
		if fn.name == "tesl_queue_conversion_next" || fn.name == "tesl_queue_conversion_finish" {
			// NEXT only selects/locks an ID; BEGIN must independently perform full
			// admission before minting an attempt. FINISH (including failure and
			// discard below) requires that private attempt's exact current xid,
			// sequence, source binding and original bytes. BEGIN retains the source
			// and target fences plus the state-row share lock until transaction end.
			// Reacquire/check those live domains here, but do not reconstruct the
			// complete immutable inventory a second/third time for the same job.
			operationGuard = strings.Replace(operationGuard,
				" perform "+ns+"tesl_queue_admit(s.to_version,s.queue);",
				" perform pg_catalog.pg_advisory_xact_lock_shared(s.fence,s.to_version);", 1)
		}
		fn.body = strings.Replace(fn.body, originalGuard, operationGuard, 1)
		fn.body = strings.ReplaceAll(fn.body, "s "+ns+"tesl_queue_conversion_scope%rowtype", "s record")
		fn.body = strings.ReplaceAll(fn.body, "source "+ns+"tesl_queue_conversion_sources%rowtype", "source record")
		fn.body = strings.ReplaceAll(fn.body, "from "+ns+"tesl_queue_conversion_sources c", "from "+sources+" c")
		fn.body = strings.ReplaceAll(fn.body, "tesl_queue_conversion_receipts", "tesl_row_queue_conversion_receipts")
		fn.body = strings.ReplaceAll(fn.body, "tesl_queue_conversion_attempts", "tesl_row_queue_conversion_attempts")
		fn.body = strings.ReplaceAll(fn.body, fn.name, "tesl_row_queue_conversion_"+strings.TrimPrefix(fn.name, "tesl_queue_conversion_"))
		fn.name = "tesl_row_queue_conversion_" + strings.TrimPrefix(fn.name, "tesl_queue_conversion_")
		if fn.name == "tesl_row_queue_conversion_next" || fn.name == "tesl_row_queue_conversion_begin" {
			bindingEnd := "raise exception 'tesl: installed queue conversion binding differs'; end if;"
			if !strings.Contains(fn.body, bindingEnd) {
				panic("missing queue binding guard")
			}
			fn.body = strings.Replace(fn.body, bindingEnd, bindingEnd+`
 if not `+exactBinding+` then raise exception 'tesl: remediation source policy differs'; end if;
 if `+superseded+` then return; end if;`, 1)
		}
		if fn.name == "tesl_row_queue_conversion_finish" {
			// Finish also gets a compiler binding; the isolated protocol keeps
			// its existing signature. Both routes fence the same exact attempt.
			fn.arguments += ", binding jsonb"
			prefix, _, found := strings.Cut(fn.body, " if kind is null")
			if !found {
				panic("application queue failure lost its exact finish guard")
			}
			prefix += " if not " + exactBinding + " then return false; end if;\n"
			result = append(result, pgMigrationControlFunction{"tesl_row_queue_conversion_fail",
				"expected uuid, digest text, job_id text, attempt_seq bigint, transaction_id text, original text, code text, binding jsonb", "boolean", "volatile", prefix + `
 if code is null or code not in ('execution-budget','execution-trap','invalid-result') then
  raise exception 'tesl: invalid queue execution failure code'; end if;
 insert into ` + ns + `tesl_row_queue_conversion_failures(job_id,source_digest,attempt_seq,payload_hash,code)
 values(j.id,digest,a.attempt_seq,pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(a.original,'UTF8')),'hex'),code);
 delete from ` + ns + `tesl_row_queue_conversion_attempts p where p.job_id=j.id;
 return true;
end`})
			result = append(result, pgMigrationControlFunction{"tesl_row_queue_conversion_discard",
				"expected uuid, digest text, job_id text, attempt_seq bigint, transaction_id text, original text, binding jsonb", "boolean", "volatile", prefix + `
 if binding->>'policy' is distinct from 'unconverted' or coalesce(binding->>'discardReason','')='' then return false; end if;
 insert into ` + ns + `tesl_row_queue_discards(job_id,source_digest,attempt_seq,payload_hash,reason)
 values(j.id,digest,a.attempt_seq,pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(a.original,'UTF8')),'hex'),binding->>'discardReason');
 delete from ` + ns + `tesl_row_queue_conversion_attempts p where p.job_id=j.id;
 delete from ` + ns + `tesl_jobs q where q.id=j.id;
 return true;
end`})
			fn.body = strings.Replace(fn.body, " if kind is null", " if not "+exactBinding+" or binding->>'policy'='unconverted' then return false; end if;\n if kind is null", 1)
		}
		if fn.name == "tesl_row_queue_conversion_next" {
			anchor := " and ((source.revision=0"
			if !strings.Contains(fn.body, anchor) {
				panic("application queue failure lost its selection guard")
			}
			fn.body = strings.Replace(fn.body, anchor, ` and not exists(select 1 from `+ns+`tesl_row_queue_conversion_failures failure
  where failure.job_id=j.id and failure.source_digest=digest and failure.attempt_seq<=j.claim_seq
   and failure.payload_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex'))
`+anchor, 1)
			fn.body = strings.Replace(fn.body, " and ((source.revision=0", " and (source.policy<>'execution-failed' or "+failureEligible+")\n and (((source.revision=0 or source.policy in ('execution-failed','unconverted'))", 1)
			fn.body = strings.Replace(fn.body, "j.status in ('pending','dead')", "(j.status in ('pending','dead') or (source.policy in ('execution-failed','unconverted') and j.status='quarantined'))", 1)
			fn.body = strings.Replace(fn.body, "source.revision>0 and j.status", "source.policy='rejected' and source.revision>0 and j.status", 1)
		}
		if fn.name == "tesl_row_queue_conversion_begin" {
			anchor := " if source.revision=0 then"
			if !strings.Contains(fn.body, anchor) {
				panic("application queue failure lost its begin guard")
			}
			fn.body = strings.Replace(fn.body, anchor, ` if exists(select 1 from `+ns+`tesl_row_queue_conversion_failures failure
  where failure.job_id=j.id and failure.source_digest=digest and failure.attempt_seq<=j.claim_seq
   and failure.payload_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex')) then
  return query select j.payload::text,''::text,j.claim_seq,''::text,'execution-failed'::text; return;
 end if;
`+anchor, 1)
			fn.body = strings.Replace(fn.body, " if not has_job then return; end if;", ` if not has_job then
 if exists(select 1 from `+ns+`tesl_row_queue_discards d where d.job_id=tesl_row_queue_conversion_begin.job_id and d.source_digest=digest) then
  return query select ''::text,''::text,0::bigint,''::text,'discarded'::text; end if;
 return; end if;`, 1)
			fn.body = strings.Replace(fn.body, anchor, " if source.policy='execution-failed' and not "+failureEligible+" then raise exception 'tesl: recovery requires exact latest execution failure'; end if;\n if source.revision=0 or source.policy in ('execution-failed','unconverted') then", 1)
			fn.body = strings.Replace(fn.body, "if j.status not in ('pending','dead')", "if j.status not in ('pending','dead') and not(source.policy in ('execution-failed','unconverted') and j.status='quarantined')", 1)
			fn.body = strings.Replace(fn.body, "resume:=j.status;", "resume:=case when j.status='quarantined' then coalesce((select r.resume_status from "+ns+"tesl_row_queue_conversion_receipts r where r.job_id=j.id order by r.attempt_seq desc limit 1),'dead') else j.status end;", 1)
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
	scopes, err := pgOpenRowQueueConversions(ctx, conn, namespace, roles, []string{digest})
	if err != nil {
		return pgQueueConversionDB{}, err
	}
	return scopes[0], nil
}

const pgRowQueueOpenBatchLimit = 32

// One bounded read-only snapshot checks shared installation/catalog/transition
// evidence once. Every lineage is still compared exactly. No database authority
// is cached across this snapshot: every job's protected operations re-admit under
// the actual source/target fences and check current attempt ownership.
func pgOpenRowQueueConversions(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, digests []string) ([]pgQueueConversionDB, error) {
	if len(digests) == 0 || len(digests) > pgRowQueueOpenBatchLimit {
		return nil, fmt.Errorf("queue open requires 1–32 checked sources")
	}
	lineages := make([][]*pgQueueConversionSource, 0, len(digests))
	for _, digest := range digests {
		lineage, err := pgQueueConversionCandidateLineage(digest)
		if err != nil {
			return nil, err
		}
		lineages = append(lineages, lineage)
	}
	root := lineages[0][len(lineages[0])-1]
	if root.fromVersion < 1 || root.toVersion != root.fromVersion+1 {
		return nil, fmt.Errorf("application queue dispatch requires an adjacent checked edge")
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return nil, err
	}
	if err := pgControlRoles(ctx, tx, roles, false); err != nil {
		return nil, err
	}
	var worker bool
	if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
		return nil, err
	}
	if !worker {
		return nil, fmt.Errorf("application queue dispatch requires exact Worker login")
	}
	state, err := pgInspectRowControl(ctx, tx, namespace, roles)
	if err != nil {
		return nil, err
	}
	if state.Current != root.toVersion {
		return nil, fmt.Errorf("application queue dispatch requires its published target")
	}
	ns := quoteIdentifier(namespace) + "."
	var document []byte
	var hash, abi, compatibility string
	if err := tx.QueryRow(ctx, "select t.contract,t.contract_hash,t.compiler_abi,t.stored_value_compatibility from "+ns+`tesl_row_queue_target_staging t
 join `+ns+`tesl_schema_versions v on v.version=t.version and v.step='expanded' and v.artefact_hash=t.contract_hash
 where t.version=$1 and t.database_uuid::text=$2 and t.fence_ns=$3`, root.toVersion, state.DatabaseUUID, state.FenceNamespace).Scan(&document, &hash, &abi, &compatibility); err != nil {
		return nil, err
	}
	plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(document), hash)
	if err != nil {
		return nil, err
	}
	for _, lineage := range lineages {
		candidate := lineage[len(lineage)-1]
		if candidate.fromVersion != root.fromVersion || candidate.toVersion != root.toVersion || plan.family != candidate.family || plan.namespace != namespace || pgRowEpochPreserving(plan) || !candidate.conversion.list(17) || candidate.conversion.children[14].value != plan.schemaSnapshotHash || candidate.conversion.children[16].value != plan.storageSnapshotHash {
			return nil, fmt.Errorf("application queue callback differs from the completed physical target")
		}
	}
	history := PgCompiledMigrationHistory{Family: plan.family, Namespace: namespace, SourceCompilerABI: abi, StoredValueCompatibility: compatibility}
	before, err := pgReadQueueCandidateInventory(ctx, tx, history, root.fromVersion)
	if err != nil {
		return nil, err
	}
	after, err := pgReadQueueCandidateInventory(ctx, tx, history, root.toVersion)
	if err != nil {
		return nil, err
	}
	if err := pgVerifyRowQueueTransition(ctx, tx, namespace, state, before.Version, after.Version); err != nil {
		return nil, err
	}
	scopes := make([]pgQueueConversionDB, 0, len(lineages))
	for _, lineage := range lineages {
		root := lineage[len(lineage)-1]
		for _, source := range lineage {
			var matches bool
			if err := tx.QueryRow(ctx, "select database_uuid::text=$1 and fence_ns=$2 and source_digest=$3 and source_document=$4 and parent_digest=$5 and old_contract=$6 and new_contract=$7 and policy=$12 and discard_reason=$13 from "+ns+"tesl_row_queue_conversion_staging where from_version=$8 and queue=$9 and job_type=$10 and revision=$11", state.DatabaseUUID, state.FenceNamespace, source.spec.digest, mustQueueConversionDocument(source), source.parentDigest, pgQueueConversionPayloadContract(source, false), pgQueueConversionPayloadContract(source, true), root.fromVersion, root.queue, root.job, source.repairRevision, source.policy, source.discardReason).Scan(&matches); err != nil {
				return nil, err
			}
			if !matches {
				return nil, fmt.Errorf("application repair lineage differs from its compiler-linked source")
			}
		}
		scopes = append(scopes, pgQueueConversionDB{namespace: namespace, identity: state.DatabaseUUID, rootDigest: root.spec.digest, application: true})
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return scopes, nil
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
	var scopes []pgQueueConversionDB
	for index, executable := range executables {
		if progress.Selected == limit {
			progress.NoEligible = false
			break
		}
		if index%pgRowQueueOpenBatchLimit == 0 {
			end := min(index+pgRowQueueOpenBatchLimit, len(executables))
			digests := make([]string, 0, end-index)
			for _, item := range executables[index:end] {
				digests = append(digests, item.queueConversionSource().spec.digest)
			}
			var err error
			scopes, err = pgOpenRowQueueConversions(ctx, conn, namespace, roles, digests)
			if err != nil {
				return progress, err
			}
		}
		offset := index % pgRowQueueOpenBatchLimit
		if len(scopes) == 0 || offset >= len(scopes) {
			return progress, fmt.Errorf("queue descriptor opening returned an incomplete batch")
		}
		scope := scopes[offset]
		remaining := limit - progress.Selected
		stages := len(executables) - index
		quantum := (remaining + stages - 1) / stages
		batch, err := pgRunQueueConversionCandidateBatch(ctx, conn, scope, executable, quantum)
		progress.Selected += batch.Selected
		progress.Converted += batch.Converted
		progress.Rejected += batch.Rejected
		progress.Invalid += batch.Invalid
		progress.Failed += batch.Failed
		progress.Discarded += batch.Discarded
		progress.Replayed += batch.Replayed
		progress.NoEligible = progress.NoEligible && batch.NoEligible
		if err != nil {
			return progress, err
		}
	}
	return progress, nil
}
