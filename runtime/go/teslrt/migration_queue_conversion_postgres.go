package teslrt

// This is an unpublished, isolated PostgreSQL execution candidate. It owns a
// fresh namespace and one checked queue transition, not a format-5 application
// database. No production installer or queue opener selects this protocol.
// Keeping the executor real (roles, transactions, jobs and receipts) lets its
// database invariants be tested before application-history integration.
import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgQueueConversionDB struct {
	namespace, identity, rootDigest string
	application                     bool
}

func (s pgQueueConversionDB) function(name string) string {
	prefix := "tesl_queue_conversion_"
	if s.application {
		prefix = "tesl_row_queue_conversion_"
	}
	return quoteIdentifier(s.namespace) + "." + quoteIdentifier(prefix+name)
}

type pgQueueConversionStored struct {
	Kind     string
	Replayed bool
}

// NoEligible describes one SKIP LOCKED scan, not migration finality. Busy,
// live-claimed, malformed or rejected jobs can still prevent retirement.
type pgQueueConversionBatch struct {
	Selected, Converted, Rejected, Invalid, Replayed int
	Failed, Discarded                                int
	NoEligible                                       bool
}

const pgQueueConversionBatchLimit = 256

type pgQueueConversionExecutable interface {
	queueConversionSource() *pgQueueConversionSource
	Convert(int, []byte) (QueueConversionResult, error)
	Repair(QueueConversionResult) (QueueConversionResult, error)
}

func pgQueueConversionCandidateRollback(tx pgx.Tx) {
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	_ = tx.Rollback(ctx)
}

func (c *CompiledQueueConversion[Old, Current]) queueConversionSource() *pgQueueConversionSource {
	if c == nil {
		return nil
	}
	return c.source
}

func pgQueueConversionCandidateTables(namespace string) []pgMigrationControlTable {
	ns := quoteIdentifier(namespace) + "."
	jobs := ""
	for _, table := range pgQueueCandidateTables(namespace) {
		if table.name == "tesl_jobs" {
			jobs = table.columns
		}
	}
	return []pgMigrationControlTable{
		{"tesl_queue_conversion_scope", `
 id smallint primary key check(id=1), identity uuid not null,
 database_oid oid not null, database_name text not null,
 family text not null, queue text not null, job_type text not null,
 from_version integer not null, to_version integer not null,
 floor integer not null, root_digest text not null,
 check(from_version>=1 and to_version=from_version+1 and to_version<=2147483646),
 check(floor in (from_version,to_version))`},
		{"tesl_queue_payloads", `
 version integer not null, queue text not null, job_type text not null,
 contract bytea not null, contract_hash text not null,
 primary key(version,queue,job_type),
 check(pg_catalog.encode(pg_catalog.sha256(contract),'hex')=contract_hash)`},
		{"tesl_queue_conversion_sources", `
 digest text primary key, document bytea not null, parent_digest text references ` + ns + `tesl_queue_conversion_sources(digest),
 revision integer not null check(revision>=0),
 from_version integer not null check(from_version between 1 and 2147483646),
 unique(from_version,revision),
 check(pg_catalog.encode(pg_catalog.sha256(document),'hex')=digest),
 check((revision=0 and parent_digest is null) or (revision>0 and parent_digest is not null))`},
		{"tesl_jobs", jobs},
		{"tesl_queue_conversion_receipts", `
 job_id text not null, source_digest text not null references ` + ns + `tesl_queue_conversion_sources(digest),
 kind text not null check(kind in ('converted','migration-rejected','payload-invalid')),
 original text not null, payload jsonb, reason text not null,
 resume_status text not null check(resume_status in ('pending','dead')),
 attempt_seq bigint not null check(attempt_seq>0),
 primary key(job_id,source_digest),
 check((kind='converted' and payload is not null) or (kind<>'converted' and payload is null))`},
		{"tesl_queue_conversion_attempts", `
 job_id text primary key references ` + ns + `tesl_jobs(id) on delete cascade,
 source_digest text not null references ` + ns + `tesl_queue_conversion_sources(digest),
 attempt_seq bigint not null, transaction_id xid8 not null,
 original text not null, reason text not null,
 resume_status text not null check(resume_status in ('pending','dead'))`},
	}
}

func pgQueueConversionScopeGuard(namespace string) string {
	ns := quoteIdentifier(namespace) + "."
	return `
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then
  raise exception 'tesl: queue conversion requires read committed'; end if;
 select * into s from ` + ns + `tesl_queue_conversion_scope where id=1 for share;
 if not found or expected is null or s.identity<>expected or s.database_name<>pg_catalog.current_database()
  or s.database_oid<>(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database()) then
  raise exception 'tesl: queue conversion database identity differs'; end if;
`
}

func pgQueueConversionCandidateFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	guard := pgQueueConversionScopeGuard(namespace)
	bindingGuard := `
 if source.document is distinct from pg_catalog.decode(binding->>'document','hex')
  or source.parent_digest is distinct from (binding->>'parent') or source.revision::text is distinct from (binding->>'revision')
  or s.family is distinct from (binding->>'family') or s.queue is distinct from (binding->>'queue')
  or s.job_type is distinct from (binding->>'job') or s.from_version::text is distinct from (binding->>'from')
  or s.to_version::text is distinct from (binding->>'to') or s.root_digest is distinct from (binding->>'root')
  or not exists(select 1 from ` + ns + `tesl_queue_payloads p where p.version=s.from_version and p.queue=s.queue and p.job_type=s.job_type and p.contract=pg_catalog.decode(binding->>'old','hex'))
  or not exists(select 1 from ` + ns + `tesl_queue_payloads p where p.version=s.to_version and p.queue=s.queue and p.job_type=s.job_type and p.contract=pg_catalog.decode(binding->>'new','hex')) then
  raise exception 'tesl: installed queue conversion binding differs'; end if;
`
	functions := []pgMigrationControlFunction{
		{"tesl_queue_conversion_snapshot", "", "jsonb", "stable", `
begin
 return pg_catalog.jsonb_build_object(
  'scope',(select pg_catalog.to_jsonb(s) from ` + ns + `tesl_queue_conversion_scope s where id=1),
  'below_floor',exists(select 1 from ` + ns + `tesl_jobs j cross join ` + ns + `tesl_queue_conversion_scope s where s.id=1 and j.schema_version<s.floor),
  'sources',(select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('digest',digest,'document',pg_catalog.encode(document,'hex'),'parent',coalesce(parent_digest,''),'revision',revision) order by revision),'[]'::jsonb) from ` + ns + `tesl_queue_conversion_sources where from_version=(select from_version from ` + ns + `tesl_queue_conversion_scope where id=1)),
  'payloads',(select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('version',version,'queue',queue,'job',job_type,'contract',pg_catalog.encode(contract,'hex'),'hash',contract_hash) order by version),'[]'::jsonb) from ` + ns + `tesl_queue_payloads where version between (select from_version from ` + ns + `tesl_queue_conversion_scope where id=1) and (select to_version from ` + ns + `tesl_queue_conversion_scope where id=1)));
end`},
		{"tesl_queue_conversion_next", "expected uuid, digest text, binding jsonb, after_sequence bigint", "TABLE(job_id text, work_seq bigint)", "volatile", `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
 source ` + ns + `tesl_queue_conversion_sources%rowtype;
begin` + guard + `
 select * into source from ` + ns + `tesl_queue_conversion_sources c where c.digest=tesl_queue_conversion_next.digest;
 if not found then raise exception 'tesl: conversion source is not installed'; end if;
 ` + bindingGuard + `
 if after_sequence is null or after_sequence<0 then raise exception 'tesl: invalid conversion work cursor'; end if;
 if s.floor>s.from_version then return; end if;
 -- Due times govern handlers, not migration: delayed and retry-scheduled work
 -- must also be converted. Receipts, not an in-memory cursor, prevent retries.
 return query select j.id,j.seq from ` + ns + `tesl_jobs j
 where j.queue=s.queue and j.job_type=s.job_type and j.schema_version=s.from_version and j.seq>after_sequence
 and not exists(select 1 from ` + ns + `tesl_queue_conversion_receipts done where done.job_id=j.id and done.source_digest=digest)
 and ((source.revision=0 and (j.status in ('pending','dead')
   or (j.status in ('processing','dead_processing') and j.lease_until<=pg_catalog.clock_timestamp()
       and j.claim_xid<>pg_catalog.pg_current_xact_id())))
  or (source.revision>0 and j.status='quarantined' and j.dead_reason='migration-rejected'
   and exists(select 1 from ` + ns + `tesl_queue_conversion_receipts prior
    where prior.job_id=j.id and prior.source_digest=source.parent_digest and prior.kind='migration-rejected'
     and prior.original=j.payload::text and prior.attempt_seq<=j.claim_seq
     and not exists(select 1 from ` + ns + `tesl_queue_conversion_receipts newer where newer.job_id=j.id and newer.attempt_seq>prior.attempt_seq))))
 order by j.seq limit 1 for update of j skip locked;
end`},
		{"tesl_queue_conversion_enqueue", "expected uuid, v integer, job_id text, body jsonb, wanted text, due text", "void", "volatile", `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
begin` + guard + `
 if v is null or v not in (s.from_version,s.to_version) or v<s.floor or job_id is null or job_id=''
  or body is null or wanted is null or wanted not in ('pending','dead') or due is null then
  raise exception 'tesl: invalid queue conversion enqueue'; end if;
 if exists(select 1 from ` + ns + `tesl_queue_conversion_receipts r where r.job_id=tesl_queue_conversion_enqueue.job_id) then
  raise exception 'tesl: completed job identity cannot be reused'; end if;
 insert into ` + ns + `tesl_jobs(id,queue,job_type,payload,schema_version,status,dead_reason,next_attempt_at)
 values(job_id,s.queue,s.job_type,body,v,wanted,case when wanted='dead' then 'attempts-exhausted' end,due::timestamptz);
end`},
		{"tesl_queue_conversion_begin", "expected uuid, digest text, job_id text, binding jsonb", "TABLE(original text, reason text, attempt_seq bigint, transaction_id text, outcome text)", "volatile", `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
 source ` + ns + `tesl_queue_conversion_sources%rowtype; j ` + ns + `tesl_jobs%rowtype;
 prior ` + ns + `tesl_queue_conversion_receipts%rowtype; resume text; old_reason text:=''; has_job boolean;
begin` + guard + `
 select * into source from ` + ns + `tesl_queue_conversion_sources c where c.digest=tesl_queue_conversion_begin.digest;
 if not found then raise exception 'tesl: conversion source is not installed'; end if;
 ` + bindingGuard + `
 select * into j from ` + ns + `tesl_jobs q where q.id=job_id for update skip locked;
 has_job:=found;
 -- Completion deletes the job, not its immutable conversion history. Also
 -- permit receipt replay while a current handler owns the row lock.
 select * into prior from ` + ns + `tesl_queue_conversion_receipts r where r.job_id=tesl_queue_conversion_begin.job_id and r.source_digest=digest;
 if found then
  return query select prior.original,prior.reason,prior.attempt_seq,''::text,prior.kind; return;
 end if;
 if not has_job then return; end if;
 if j.queue<>s.queue or j.job_type<>s.job_type or j.schema_version<>s.from_version or j.schema_version<s.floor then
  raise exception 'tesl: conversion job has another source identity'; end if;
 if source.revision=0 then
  -- Read the clock after acquiring the job lock. An active claimant retains
  -- its transaction-local completion right even after wall-clock expiry.
  if j.status in ('processing','dead_processing') and j.lease_until<=pg_catalog.clock_timestamp()
   and j.claim_xid<>pg_catalog.pg_current_xact_id() then
   update ` + ns + `tesl_jobs q set
    status=case when q.status='dead_processing' then 'dead' else 'pending' end,
    locked_at=null,locked_by=null,claim_token=null,claimed_by_version=null,claim_xid=null,lease_until=null
   where q.id=j.id returning q.* into j;
  end if;
  if j.status not in ('pending','dead') then raise exception 'tesl: conversion requires an unclaimed source job'; end if;
  resume:=j.status;
 else
  select * into prior from ` + ns + `tesl_queue_conversion_receipts r where r.job_id=j.id and r.source_digest=source.parent_digest;
  if not found or prior.kind<>'migration-rejected' or j.status<>'quarantined' or j.dead_reason<>'migration-rejected'
   or prior.original<>j.payload::text or prior.attempt_seq>j.claim_seq
   or exists(select 1 from ` + ns + `tesl_queue_conversion_receipts newer where newer.job_id=j.id and newer.attempt_seq>prior.attempt_seq) then
   raise exception 'tesl: repair requires its exact durable predecessor rejection'; end if;
  resume:=prior.resume_status; old_reason:=prior.reason;
 end if;
 update ` + ns + `tesl_jobs q set claim_seq=q.claim_seq+1 where q.id=j.id returning q.claim_seq into j.claim_seq;
 insert into ` + ns + `tesl_queue_conversion_attempts(job_id,source_digest,attempt_seq,transaction_id,original,reason,resume_status)
 values(j.id,digest,j.claim_seq,pg_catalog.pg_current_xact_id(),j.payload::text,old_reason,resume)
 on conflict on constraint tesl_queue_conversion_attempts_pkey do update set
  source_digest=excluded.source_digest,attempt_seq=excluded.attempt_seq,transaction_id=excluded.transaction_id,
  original=excluded.original,reason=excluded.reason,resume_status=excluded.resume_status;
 return query select j.payload::text,old_reason,j.claim_seq,pg_catalog.pg_current_xact_id()::text,''::text;
end`},
		{"tesl_queue_conversion_finish", "expected uuid, digest text, job_id text, attempt_seq bigint, transaction_id text, original text, kind text, body jsonb, reason text", "boolean", "volatile", `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
 a ` + ns + `tesl_queue_conversion_attempts%rowtype; j ` + ns + `tesl_jobs%rowtype;
begin` + guard + `
 if transaction_id is distinct from pg_catalog.pg_current_xact_id()::text then return false; end if;
 select * into j from ` + ns + `tesl_jobs q where q.id=job_id for update;
 if not found then return false; end if;
 select * into a from ` + ns + `tesl_queue_conversion_attempts p where p.job_id=j.id;
 if not found or a.source_digest is distinct from digest or a.attempt_seq is distinct from attempt_seq
  or a.transaction_id<>pg_catalog.pg_current_xact_id() or a.original is distinct from original
  or j.claim_seq<>a.attempt_seq or j.schema_version<>s.from_version or j.schema_version<s.floor
  or j.queue<>s.queue or j.job_type<>s.job_type or j.payload::text<>a.original
  or j.status not in ('pending','dead','quarantined') then return false; end if;
 if kind is null or kind not in ('converted','migration-rejected','payload-invalid') or reason is null
  or (kind='converted')<>(body is not null) then raise exception 'tesl: invalid conversion outcome'; end if;
 insert into ` + ns + `tesl_queue_conversion_receipts(job_id,source_digest,kind,original,payload,reason,resume_status,attempt_seq)
 values(j.id,digest,kind,original,body,reason,a.resume_status,a.attempt_seq);
 update ` + ns + `tesl_jobs q set
  payload=case when kind='converted' then body else q.payload end,
  schema_version=case when kind='converted' then s.to_version else q.schema_version end,
  status=case when kind='converted' then a.resume_status else 'quarantined' end,
  dead_reason=case when kind<>'converted' then kind when a.resume_status='dead' then 'attempts-exhausted' end,
  dead_detail=case when kind='migration-rejected' then pg_catalog.left(reason,256) end
 where q.id=j.id;
 delete from ` + ns + `tesl_queue_conversion_attempts p where p.job_id=j.id;
 return true;
end`},
		{"tesl_queue_conversion_retire", "expected uuid", "boolean", "volatile", `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: retirement requires read committed'; end if;
 select * into s from ` + ns + `tesl_queue_conversion_scope where id=1 for update;
 if not found or expected is null or s.identity<>expected or s.database_name<>pg_catalog.current_database()
  or s.database_oid<>(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database()) then
  raise exception 'tesl: queue conversion database identity differs'; end if;
 if exists(select 1 from ` + ns + `tesl_jobs where schema_version<s.to_version) then return false; end if;
 update ` + ns + `tesl_queue_conversion_scope set floor=s.to_version where id=1;
 return true;
end`},
	}
	// Exercise the same claim, renewal, retry, quarantine and completion SQL as
	// the application runtime. Only admission is candidate-specific. Keep the
	// candidate enqueue's no-ID-reuse rule rather than installing another writer.
	for _, fn := range pgQueueOperationFunctions(namespace) {
		if fn.name == "tesl_queue_enqueue" {
			continue
		}
		if fn.name == "tesl_queue_admit" {
			fn.body = `
declare s ` + ns + `tesl_queue_conversion_scope%rowtype;
 source ` + ns + `tesl_queue_conversion_sources%rowtype;
 expected uuid:=nullif(pg_catalog.current_setting('tesl.queue_conversion_identity',true),'')::uuid;
 binding jsonb:=nullif(pg_catalog.current_setting('tesl.queue_conversion_binding',true),'')::jsonb;
begin` + guard + `
 select * into source from ` + ns + `tesl_queue_conversion_sources where digest=s.root_digest;
 if not found then raise exception 'tesl: queue conversion baseline is missing'; end if;
 ` + bindingGuard + `
 if v is null or v not in (s.from_version,s.to_version) or v<s.floor or q is distinct from s.queue then
  raise exception 'tesl: queue version or identity is not admitted'; end if;
 return s.floor;
end`
		}
		functions = append(functions, fn)
	}
	return functions
}

func pgQueueConversionPayloadContract(source *pgQueueConversionSource, target bool) []byte {
	i := 7
	if target {
		i++
	}
	return []byte(pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"),
		pgRowList(pgRowAtom("queue-payload-v1"), source.conversion.children[i]))))
}

func pgQueueConversionCandidateBinding(source *pgQueueConversionSource) ([]byte, error) {
	compiledQueueConversionSources.RLock()
	root := source
	for root != nil && root.parentDigest != "" {
		root = compiledQueueConversionSources.byDigest[root.parentDigest]
	}
	compiledQueueConversionSources.RUnlock()
	if root == nil {
		return nil, fmt.Errorf("missing compiled queue conversion predecessor")
	}
	var parent any
	if source.parentDigest != "" {
		parent = source.parentDigest
	}
	return json.Marshal(map[string]any{"document": source.spec.document, "parent": parent, "revision": source.repairRevision,
		"family": source.family, "queue": source.queue, "job": source.job, "from": source.fromVersion, "to": source.toVersion,
		"policy": source.policy, "discardReason": source.discardReason,
		"root": root.spec.digest, "old": hex.EncodeToString(pgQueueConversionPayloadContract(source, false)),
		"new": hex.EncodeToString(pgQueueConversionPayloadContract(source, true))})
}

// Candidate-only connection context for the shared queue operations. The
// production pool opener continues to require its application history binding.
func pgQueueConversionCandidateQueueContext(ctx context.Context, tx pgx.Tx, scope pgQueueConversionDB) (string, error) {
	compiledQueueConversionSources.RLock()
	root := compiledQueueConversionSources.byDigest[scope.rootDigest]
	compiledQueueConversionSources.RUnlock()
	if root == nil || root.parentDigest != "" {
		return "", fmt.Errorf("queue candidate has no linked original conversion")
	}
	binding, err := pgQueueConversionCandidateBinding(root)
	if err != nil {
		return "", err
	}
	_, err = tx.Exec(ctx, "select pg_catalog.set_config('tesl.queue_conversion_identity',$1,true), pg_catalog.set_config('tesl.queue_conversion_binding',$2,true)", scope.identity, string(binding))
	return root.queue, err
}

func pgQueueConversionCandidateLineage(finalDigest string) ([]*pgQueueConversionSource, error) {
	compiledQueueConversionSources.RLock()
	defer compiledQueueConversionSources.RUnlock()
	var lineage []*pgQueueConversionSource
	for source := compiledQueueConversionSources.byDigest[finalDigest]; source != nil; source = compiledQueueConversionSources.byDigest[source.parentDigest] {
		lineage = append(lineage, source)
		if len(lineage) > 129 {
			return nil, fmt.Errorf("queue conversion candidate exceeds 128 repair revisions")
		}
	}
	if len(lineage) == 0 || lineage[len(lineage)-1].repairRevision != 0 || len(lineage) != lineage[0].repairRevision+1 {
		return nil, fmt.Errorf("queue conversion candidate requires a complete linked lineage")
	}
	return lineage, nil
}

// Install only into a fresh isolated namespace. Payload contracts and every
// callback identity come from the actual linked compiler descriptors. This is
// deliberately not an upgrade or an installer for application format 5.
func pgInstallQueueConversionCandidate(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, finalDigest string) (pgQueueConversionDB, error) {
	var scope pgQueueConversionDB
	lineage, err := pgQueueConversionCandidateLineage(finalDigest)
	if err != nil {
		return scope, err
	}
	root := lineage[len(lineage)-1]
	if namespace == "" || len(namespace) > 63 || strings.IndexByte(namespace, 0) >= 0 {
		return scope, fmt.Errorf("invalid queue conversion namespace")
	}
	if roles.Request == "" {
		return scope, fmt.Errorf("queue conversion candidate requires an isolated request role")
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return scope, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return scope, err
	}
	ns := quoteIdentifier(namespace) + "."
	if _, err := tx.Exec(ctx, "create schema "+quoteIdentifier(namespace)+" authorization "+quoteIdentifier(roles.Owner)); err != nil {
		return scope, err
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return scope, err
	}
	for _, table := range pgQueueConversionCandidateTables(namespace) {
		if _, err := tx.Exec(ctx, "create table "+ns+quoteIdentifier(table.name)+" ("+table.columns+")"); err != nil {
			return scope, err
		}
	}
	for _, statement := range []string{
		"create index tesl_queue_conversion_work on " + ns + "tesl_jobs(queue,job_type,schema_version,seq)",
		"create index tesl_queue_conversion_latest on " + ns + "tesl_queue_conversion_receipts(job_id,attempt_seq)",
	} {
		if _, err := tx.Exec(ctx, statement); err != nil {
			return scope, err
		}
	}
	for _, objects := range []string{"tables", "sequences"} {
		if _, err := tx.Exec(ctx, "revoke all on all "+objects+" in schema "+quoteIdentifier(namespace)+" from public,"+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)); err != nil {
			return scope, err
		}
	}
	for i, version := range []int{root.fromVersion, root.toVersion} {
		contract := pgQueueConversionPayloadContract(root, i == 1)
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_payloads values($1,$2,$3,$4,pg_catalog.encode(pg_catalog.sha256($4),'hex'))", version, root.queue, root.job, contract); err != nil {
			return scope, err
		}
	}
	for i := len(lineage) - 1; i >= 0; i-- {
		source := lineage[i]
		if _, err := pgReadQueueConversionSource(source.spec); err != nil {
			return scope, err
		}
		doc, err := hex.DecodeString(source.spec.document)
		if err != nil {
			return scope, err
		}
		var parent any
		if source.parentDigest != "" {
			parent = source.parentDigest
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_conversion_sources(digest,document,parent_digest,revision,from_version) values($1,$2,$3,$4,$5)", source.spec.digest, doc, parent, source.repairRevision, source.fromVersion); err != nil {
			return scope, err
		}
	}
	scope = pgQueueConversionDB{namespace: namespace, rootDigest: root.spec.digest}
	if err := tx.QueryRow(ctx, "insert into "+ns+`tesl_queue_conversion_scope
 select 1,pg_catalog.gen_random_uuid(),oid,datname,$1,$2,$3,$4,$5,$4,$6 from pg_catalog.pg_database where datname=pg_catalog.current_database()
 returning identity::text`, root.family, root.queue, root.job, root.fromVersion, root.toVersion, root.spec.digest).Scan(&scope.identity); err != nil {
		return pgQueueConversionDB{}, err
	}
	for _, fn := range pgQueueConversionCandidateFunctions(namespace) {
		if _, err := tx.Exec(ctx, pgControlFunctionSQL(namespace, roles.Owner, fn)); err != nil {
			return pgQueueConversionDB{}, err
		}
		name := ns + quoteIdentifier(fn.name) + "(" + pgControlArgumentTypes(fn) + ")"
		if _, err := tx.Exec(ctx, "revoke all on function "+name+" from public,"+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)); err != nil {
			return pgQueueConversionDB{}, err
		}
		functionRoles := pgQueueConversionFunctionRoles(roles, fn)
		for _, role := range pgControlFunctionRoles(functionRoles, fn) {
			if _, err := tx.Exec(ctx, "grant execute on function "+name+" to "+quoteIdentifier(role)); err != nil {
				return pgQueueConversionDB{}, err
			}
		}
		if err := pgControlFunctionCatalog(ctx, tx, namespace, functionRoles, fn); err != nil {
			return pgQueueConversionDB{}, err
		}
	}
	if _, err := tx.Exec(ctx, "revoke all on schema "+quoteIdentifier(namespace)+" from public; grant usage on schema "+quoteIdentifier(namespace)+" to "+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)); err != nil {
		return pgQueueConversionDB{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return pgQueueConversionDB{}, err
	}
	return scope, nil
}

func pgQueueConversionFunctionRoles(roles PgMigrationControlRoles, fn pgMigrationControlFunction) PgMigrationControlRoles {
	if fn.name == "tesl_queue_conversion_enqueue" {
		return PgMigrationControlRoles{Owner: roles.Owner, Worker: roles.Request}
	}
	if strings.HasPrefix(fn.name, "tesl_queue_conversion_") {
		roles.Request = ""
	}
	return roles
}

// Advance the isolated execution protocol to an adjacent checked transition
// only after the previous source is retired. Keep all payload contracts, source
// descriptors and job receipts: an upgrade never reuses revision slots from a
// different edge or replaces the installation identity.
func pgUpgradeQueueConversionCandidate(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, identity, digest string) (pgQueueConversionDB, error) {
	var scope pgQueueConversionDB
	lineage, err := pgQueueConversionCandidateLineage(digest)
	if err != nil {
		return scope, err
	}
	if len(lineage) != 1 {
		return scope, fmt.Errorf("queue upgrade installs the new root; register repairs separately")
	}
	root := lineage[0]
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return scope, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return scope, err
	}
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return scope, err
	}
	if exists, err := pgControlNamespace(ctx, tx, namespace, roles.Owner, roles.Worker); err != nil {
		return scope, err
	} else if !exists {
		return scope, fmt.Errorf("queue upgrade namespace is missing")
	}
	if err := pgQueueConversionCandidateCatalog(ctx, tx, namespace, roles); err != nil {
		return scope, err
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return scope, err
	}
	ns := quoteIdentifier(namespace) + "."
	var from, to, floor int
	var family, queue, job, previousDigest string
	if err := tx.QueryRow(ctx, "select from_version,to_version,floor,family,queue,job_type,root_digest from "+ns+`tesl_queue_conversion_scope
 where id=1 and identity=$1 and database_name=pg_catalog.current_database()
 and database_oid=(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database()) for update`, identity).Scan(&from, &to, &floor, &family, &queue, &job, &previousDigest); err != nil {
		return scope, err
	}
	if family != root.family || queue != root.queue || job != root.job {
		return scope, fmt.Errorf("queue upgrade changed its retained owner")
	}
	if from == root.fromVersion && to == root.toVersion && previousDigest == digest {
		var same bool
		if err := tx.QueryRow(ctx, "select document=$1 and revision=0 and from_version=$2 and parent_digest is null from "+ns+"tesl_queue_conversion_sources where digest=$3", mustQueueConversionDocument(root), root.fromVersion, digest).Scan(&same); err != nil {
			return scope, err
		}
		if !same {
			return scope, fmt.Errorf("immutable queue upgrade replay differs")
		}
	} else {
		if root.fromVersion != to || floor != to {
			return scope, fmt.Errorf("queue upgrade requires adjacent, retired predecessor")
		}
		var old []byte
		if err := tx.QueryRow(ctx, "select contract from "+ns+"tesl_queue_payloads where version=$1 and queue=$2 and job_type=$3", to, queue, job).Scan(&old); err != nil {
			return scope, err
		}
		if !bytes.Equal(old, pgQueueConversionPayloadContract(root, false)) {
			return scope, fmt.Errorf("queue upgrade historical decoder differs from retained target payload")
		}
		var prior []byte
		if err := tx.QueryRow(ctx, "select document from "+ns+"tesl_queue_conversion_sources where digest=$1 and revision=0 and from_version=$2", previousDigest, from).Scan(&prior); err != nil {
			return scope, err
		}
		r := &pgMigrationWireReader{}
		n := pgRowDocument(r, hex.EncodeToString(prior), previousDigest, "migration")
		if r.err != nil || !n.list(17) || !root.conversion.list(17) || n.children[14].value != root.conversion.children[13].value || n.children[16].value != root.conversion.children[15].value || !pgRowCanonicalEqual(n.children[2], root.conversion.children[2]) {
			return scope, fmt.Errorf("queue upgrade full historical schema/storage binding differs")
		}
		var stale bool
		if err := tx.QueryRow(ctx, "select exists(select 1 from "+ns+"tesl_jobs where schema_version<$1)", to).Scan(&stale); err != nil {
			return scope, err
		}
		if stale {
			return scope, fmt.Errorf("queue upgrade has jobs below its retired source")
		}
		target := pgQueueConversionPayloadContract(root, true)
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_payloads(version,queue,job_type,contract,contract_hash) values($1,$2,$3,$4,pg_catalog.encode(pg_catalog.sha256($4),'hex'))", root.toVersion, queue, job, target); err != nil {
			return scope, err
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_conversion_sources(digest,document,parent_digest,revision,from_version) values($1,$2,null,0,$3)", digest, mustQueueConversionDocument(root), root.fromVersion); err != nil {
			return scope, err
		}
		if _, err := tx.Exec(ctx, "update "+ns+"tesl_queue_conversion_scope set from_version=$1,to_version=$2,root_digest=$3 where id=1", root.fromVersion, root.toVersion, digest); err != nil {
			return scope, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return scope, err
	}
	return pgQueueConversionDB{namespace: namespace, identity: identity, rootDigest: digest}, nil
}

// A later deployment appends checked repairs under the short-lived installer
// identity. Existing source rows are compared byte-for-byte, never rewritten.
func pgRegisterQueueRepairCandidate(ctx context.Context, conn *pgx.Conn, scope pgQueueConversionDB, roles PgMigrationControlRoles, digest string) error {
	lineage, err := pgQueueConversionCandidateLineage(digest)
	if err != nil {
		return err
	}
	root := lineage[len(lineage)-1]
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return err
	}
	if exists, err := pgControlNamespace(ctx, tx, scope.namespace, roles.Owner, roles.Worker); err != nil {
		return err
	} else if !exists {
		return fmt.Errorf("queue repair candidate namespace is missing")
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	ns := quoteIdentifier(scope.namespace) + "."
	var family, queue, job, baseline string
	var from, to, floor int
	err = tx.QueryRow(ctx, "select family,queue,job_type,from_version,to_version,floor,root_digest from "+ns+`tesl_queue_conversion_scope
 where id=1 and identity=$1 and database_name=pg_catalog.current_database()
 and database_oid=(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database()) for update`, scope.identity).
		Scan(&family, &queue, &job, &from, &to, &floor, &baseline)
	if err != nil {
		return err
	}
	if family != root.family || queue != root.queue || job != root.job || from != root.fromVersion || to != root.toVersion || baseline != root.spec.digest {
		return fmt.Errorf("queue repair differs from installed transition")
	}
	for i, version := range []int{from, to} {
		var contract []byte
		if err := tx.QueryRow(ctx, "select contract from "+ns+"tesl_queue_payloads where version=$1 and queue=$2 and job_type=$3", version, queue, job).Scan(&contract); err != nil {
			return err
		}
		if !bytes.Equal(contract, pgQueueConversionPayloadContract(root, i == 1)) {
			return fmt.Errorf("queue repair payload contract differs from installed source")
		}
	}
	for i := len(lineage) - 1; i >= 0; i-- {
		source := lineage[i]
		if _, err := pgReadQueueConversionSource(source.spec); err != nil {
			return err
		}
		document, err := hex.DecodeString(source.spec.document)
		if err != nil {
			return err
		}
		var existing, parent string
		var installed []byte
		err = tx.QueryRow(ctx, "select digest,document,coalesce(parent_digest,'') from "+ns+"tesl_queue_conversion_sources where revision=$1 and from_version=$2", source.repairRevision, root.fromVersion).Scan(&existing, &installed, &parent)
		if err == nil {
			if existing != source.spec.digest || !bytes.Equal(installed, document) || parent != source.parentDigest {
				return fmt.Errorf("immutable installed queue repair history differs")
			}
			continue
		}
		if err != pgx.ErrNoRows {
			return err
		}
		if source.repairRevision == 0 || floor != from {
			return fmt.Errorf("queue repair cannot replace its baseline or revive a retired source")
		}
		var count, maximum int
		if err := tx.QueryRow(ctx, "select count(*),coalesce(max(revision),-1) from "+ns+"tesl_queue_conversion_sources where from_version=$1", root.fromVersion).Scan(&count, &maximum); err != nil {
			return err
		}
		if count != source.repairRevision || maximum+1 != source.repairRevision {
			return fmt.Errorf("queue repair installed prefix is incomplete")
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_queue_conversion_sources(digest,document,parent_digest,revision,from_version) values($1,$2,$3,$4,$5)", source.spec.digest, document, source.parentDigest, source.repairRevision, source.fromVersion); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// One job and its immutable receipt commit together. A lost connection rolls
// back the row lock, attempt and outcome. Application callback faults can instead
// commit a separate diagnostic, never a conversion/rejection receipt or payload
// change. Replays consult durable evidence before invoking the callback.
// Caller-owned transactions permit deterministic rollback/ownership tests.
func pgApplyQueueConversionCandidateTx(ctx context.Context, tx pgx.Tx, scope pgQueueConversionDB, conversion pgQueueConversionExecutable, jobID string) (pgQueueConversionStored, error) {
	var stored pgQueueConversionStored
	if conversion == nil {
		return stored, fmt.Errorf("queue conversion executable is missing")
	}
	source := conversion.queueConversionSource()
	if source == nil || scope.namespace == "" || scope.identity == "" {
		return stored, fmt.Errorf("queue conversion database binding is missing")
	}
	if !scope.application && (source.policy == "execution-failed" || source.policy == "unconverted") {
		return stored, fmt.Errorf("operational remediation requires the checked application history")
	}
	var original, reason, transaction, outcome string
	var sequence int64
	binding, err := pgQueueConversionCandidateBinding(source)
	if err != nil {
		return stored, err
	}
	err = tx.QueryRow(ctx, "select * from "+scope.function("begin")+"($1,$2,$3,$4::jsonb)", scope.identity, source.spec.digest, jobID, string(binding)).
		Scan(&original, &reason, &sequence, &transaction, &outcome)
	if err == pgx.ErrNoRows {
		return pgQueueConversionStored{Kind: "unavailable"}, nil
	}
	if err != nil {
		return stored, err
	}
	if outcome != "" {
		return pgQueueConversionStored{Kind: outcome, Replayed: true}, nil
	}
	if scope.application && source.policy == "unconverted" {
		var discarded bool
		err := tx.QueryRow(ctx, "select "+scope.function("discard")+"($1,$2,$3,$4,$5,$6,$7::jsonb)", scope.identity, source.spec.digest, jobID, sequence, transaction, original, string(binding)).Scan(&discarded)
		if err != nil {
			return stored, err
		}
		if !discarded {
			return stored, fmt.Errorf("queue discard lost exact attempt ownership")
		}
		return pgQueueConversionStored{Kind: "discarded"}, nil
	}
	var result QueueConversionResult
	if source.parentDigest == "" {
		stopExecution := BeginMigrationExecution(ctx)
		defer stopExecution()
		result, err = conversion.Convert(source.fromVersion, []byte(original))
	} else {
		compiledQueueConversionSources.RLock()
		parent := compiledQueueConversionSources.byDigest[source.parentDigest]
		compiledQueueConversionSources.RUnlock()
		stopExecution := BeginMigrationExecution(ctx)
		defer stopExecution()
		kind := "migration-rejected"
		if source.policy == "execution-failed" {
			kind = "execution-failed"
		}
		result, err = conversion.Repair(QueueConversionResult{kind: kind, original: original, reason: reason, source: parent})
	}
	if err != nil {
		if scope.application && ctx.Err() == nil {
			if code := pgQueueExecutionFailureCode(err); code != "" {
				var recorded bool
				err = tx.QueryRow(ctx, "select "+scope.function("fail")+"($1,$2,$3,$4,$5,$6,$7,$8::jsonb)",
					scope.identity, source.spec.digest, jobID, sequence, transaction, original, code, string(binding)).Scan(&recorded)
				if err != nil {
					return stored, err
				}
				if !recorded {
					return stored, fmt.Errorf("queue failure observation lost attempt ownership")
				}
				return pgQueueConversionStored{Kind: "execution-failed"}, nil
			}
		}
		return stored, err
	}
	if result.SourceDigest() != source.spec.digest || result.Original() != original {
		return stored, fmt.Errorf("conversion outcome lost its database source binding")
	}
	var payload any
	if result.Kind() == "converted" {
		payload = result.Payload()
	}
	var applied bool
	args := []any{scope.identity, source.spec.digest, jobID, sequence, transaction, original, result.Kind(), payload, result.Reason()}
	parameters := "$1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9"
	if scope.application {
		args = append(args, string(binding))
		parameters += ",$10::jsonb"
	}
	err = tx.QueryRow(ctx, "select "+scope.function("finish")+"("+parameters+")", args...).Scan(&applied)
	if err != nil {
		return stored, err
	}
	if !applied {
		return stored, fmt.Errorf("queue conversion attempt lost ownership")
	}
	return pgQueueConversionStored{Kind: result.Kind()}, nil
}

func pgApplyQueueConversionCandidate(ctx context.Context, conn *pgx.Conn, scope pgQueueConversionDB, conversion pgQueueConversionExecutable, jobID string) (pgQueueConversionStored, error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return pgQueueConversionStored{}, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	result, err := pgApplyQueueConversionCandidateTx(ctx, tx, scope, conversion, jobID)
	if err != nil {
		return pgQueueConversionStored{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return pgQueueConversionStored{}, err
	}
	return result, nil
}

func pgSelectQueueConversionCandidateTx(ctx context.Context, tx pgx.Tx, scope pgQueueConversionDB, source *pgQueueConversionSource, after int64) (string, int64, error) {
	if source == nil || scope.namespace == "" || scope.identity == "" {
		return "", 0, fmt.Errorf("queue conversion database binding is missing")
	}
	binding, err := pgQueueConversionCandidateBinding(source)
	if err != nil {
		return "", 0, err
	}
	var id string
	var sequence int64
	err = tx.QueryRow(ctx, "select * from "+scope.function("next")+"($1,$2,$3::jsonb,$4)",
		scope.identity, source.spec.digest, string(binding), after).Scan(&id, &sequence)
	return id, sequence, err
}

// A bounded dispatch turn for one checked conversion/repair. Every selected job
// commits separately; interruption preserves earlier receipts and leaves the
// current job retryable. The next turn starts at zero and consults the database,
// so jobs skipped under contention or arriving later cannot fall behind a saved
// high-water mark. The within-turn cursor only bounds repeated scanning.
func pgRunQueueConversionCandidateBatch(ctx context.Context, conn *pgx.Conn, scope pgQueueConversionDB, conversion pgQueueConversionExecutable, limit int) (pgQueueConversionBatch, error) {
	var progress pgQueueConversionBatch
	if conversion == nil || conversion.queueConversionSource() == nil || limit < 1 || limit > pgQueueConversionBatchLimit {
		return progress, fmt.Errorf("queue conversion batch requires a linked executable and a limit between 1 and %d", pgQueueConversionBatchLimit)
	}
	var after int64
	for progress.Selected < limit {
		// pgx may close a connection when BEGIN is attempted with an already
		// canceled context. Do not start a transaction for a canceled turn.
		if err := ctx.Err(); err != nil {
			return progress, err
		}
		selected, sequence, result, err := func() (bool, int64, pgQueueConversionStored, error) {
			tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
			if err != nil {
				return false, 0, pgQueueConversionStored{}, err
			}
			defer pgQueueConversionCandidateRollback(tx)
			id, sequence, err := pgSelectQueueConversionCandidateTx(ctx, tx, scope, conversion.queueConversionSource(), after)
			if err == pgx.ErrNoRows {
				return false, 0, pgQueueConversionStored{}, nil
			}
			if err != nil {
				return false, 0, pgQueueConversionStored{}, err
			}
			result, err := pgApplyQueueConversionCandidateTx(ctx, tx, scope, conversion, id)
			if err != nil {
				return false, 0, pgQueueConversionStored{}, fmt.Errorf("queue conversion job %s: %w", id, err)
			}
			if result.Kind != "converted" && result.Kind != "migration-rejected" && result.Kind != "payload-invalid" && !(scope.application && (result.Kind == "execution-failed" || result.Kind == "discarded")) {
				return false, 0, pgQueueConversionStored{}, fmt.Errorf("selected queue conversion job %s lost its locked source", id)
			}
			if err := tx.Commit(ctx); err != nil {
				return false, 0, pgQueueConversionStored{}, err
			}
			return true, sequence, result, nil
		}()
		if err != nil {
			return progress, err
		}
		if !selected {
			progress.NoEligible = true
			return progress, nil
		}
		after = sequence
		progress.Selected++
		if result.Replayed {
			progress.Replayed++
			continue
		}
		switch result.Kind {
		case "converted":
			progress.Converted++
		case "migration-rejected":
			progress.Rejected++
		case "payload-invalid":
			progress.Invalid++
		case "execution-failed":
			progress.Failed++
		case "discarded":
			progress.Discarded++
		}
	}
	return progress, nil
}
