package teslrt

// These definitions are part of the original reader, before any transforming
// version is deployed. Rows append lifecycle evidence; no future manifest can
// install a new protected function or change these definitions.
func pgRowLifecycleTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_schema_backfill_shards", `
 version integer not null check(version between 2 and 2147483646),
 entity text not null,
 target_generation smallint not null check(target_generation between 2 and 32767),
 shard smallint not null check(shard>=0),
 lo_pk jsonb,
 hi_pk jsonb,
 last_pk jsonb,
 rows_done bigint not null default 0 check(rows_done>=0),
 state text not null default 'pending' check(state in ('pending','running','provisional','final')),
 lease_name text not null unique,
 updated_at timestamptz not null default pg_catalog.clock_timestamp(),
 primary key(entity,target_generation,shard)`},
		{"tesl_row_finality", `
 entity text not null,
 generation smallint not null check(generation between 1 and 32767),
 version integer not null check(version between 1 and 2147483646),
 physical_hash text not null check(physical_hash ~ '^[0-9a-f]{64}$'),
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 finalized_at timestamptz not null default pg_catalog.clock_timestamp(),
 primary key(entity,generation)`},
		{"tesl_row_contracts", `
 version integer primary key check(version between 2 and 2147483646),
 predecessor_hash text not null,
 contract bytea not null,
 contract_hash text not null check(contract_hash ~ '^[0-9a-f]{64}$'),
 window_hash text not null check(window_hash ~ '^[0-9a-f]{64}$'),
 settled bytea not null,
 settled_hash text not null check(settled_hash ~ '^[0-9a-f]{64}$'),
 operation_count integer not null check(operation_count>=0),
 preparation_count integer not null check(preparation_count>=0 and preparation_count<=operation_count),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 check(pg_catalog.encode(pg_catalog.sha256(contract),'hex')=contract_hash),
 check(pg_catalog.encode(pg_catalog.sha256(settled),'hex')=settled_hash)`},
		{"tesl_row_contract_objects", `
 version integer not null check(version between 2 and 2147483646),
 ordinal integer not null check(ordinal>=0),
 operation_hash text not null check(operation_hash ~ '^[0-9a-f]{64}$'),
 committed_at timestamptz not null default pg_catalog.clock_timestamp(),
 primary key(version,ordinal)`},
	}
}

func pgRowBackfillFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_row_takeover_lease", "lease_id text", "jsonb", "volatile", `
declare locked ` + ns + `tesl_schema_leases%rowtype;
begin
 if lease_id is null or pg_catalog.current_setting('application_name') !~ '^tesl-exec:' then raise exception 'tesl: row takeover requires exact worker identity'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_backfill_shards where lease_name=lease_id and state<>'final') then raise exception 'tesl: row lease has no active shard'; end if;
 select * into locked from ` + ns + `tesl_schema_leases where name=lease_id for update skip locked;
 if not found then return pg_catalog.jsonb_build_object('busy',true); end if;
 return pg_catalog.jsonb_build_object('holder',locked.holder,'expired',coalesce(locked.expires_at<=pg_catalog.clock_timestamp(),true));
end`},

		{"tesl_register_row_shard", "v integer, ent text, gen smallint, part smallint, lo jsonb, hi jsonb, lease_id text", "void", "volatile", `
declare r ` + ns + `tesl_schema_backfill_shards%rowtype;
begin
 if v is null or ent is null or ent='' or gen is null or gen<2 or part is null or part<0 or
 lease_id is distinct from 'row:'||ent||':'||gen::text||':'||part::text then
 raise exception 'tesl: invalid row shard identity'; end if;
 perform ` + ns + `tesl_admit(v);
 if not exists(select 1 from ` + ns + `tesl_row_physical where version=v) or
 not exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='expanded') or
 exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step in ('retired','contracting','contracted')) then
 raise exception 'tesl: row shard requires an open expanded window'; end if;
 insert into ` + ns + `tesl_schema_backfill_shards(version,entity,target_generation,shard,lo_pk,hi_pk,lease_name)
 values(v,ent,gen,part,lo,hi,lease_id) on conflict(entity,target_generation,shard) do nothing;
 select * into r from ` + ns + `tesl_schema_backfill_shards where entity=ent and target_generation=gen and shard=part for update;
 if r.version is distinct from v or r.lo_pk is distinct from lo or r.hi_pk is distinct from hi or r.lease_name is distinct from lease_id then
 raise exception 'tesl: immutable row shard differs'; end if;
 insert into ` + ns + `tesl_schema_leases(name) values(lease_id) on conflict(name) do nothing;
end`},
		{"tesl_claim_row_shard", "lease_id text, who text, ttl_ms bigint", "bigint", "volatile", `
declare l ` + ns + `tesl_schema_leases%rowtype; v integer;
begin
 if who is null or who !~ '^tesl-exec:[a-zA-Z0-9_-]+$' or
 pg_catalog.current_setting('application_name') is distinct from who or ttl_ms is null or ttl_ms<1 or ttl_ms>600000 then
 raise exception 'tesl: invalid row lease holder'; end if;
 select version into v from ` + ns + `tesl_schema_backfill_shards where lease_name=lease_id and state<>'final';
 if not found then raise exception 'tesl: row lease has no active shard'; end if;
 perform ` + ns + `tesl_admit(v);
 select * into l from ` + ns + `tesl_schema_leases where name=lease_id for update;
 if not found then raise exception 'tesl: row lease missing'; end if;
 if l.holder is not null and (l.expires_at>pg_catalog.clock_timestamp() or exists
 (select 1 from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database() and application_name=l.holder)) then return 0; end if;
 if l.token=9223372036854775807 then raise exception 'tesl: row lease token exhausted'; end if;
 update ` + ns + `tesl_schema_leases set token=token+1,holder=who,expires_at=pg_catalog.clock_timestamp()+ttl_ms*interval '1 millisecond' where name=lease_id returning token into l.token;
 update ` + ns + `tesl_schema_backfill_shards set state='running',updated_at=pg_catalog.clock_timestamp() where lease_name=lease_id;
 return l.token;
end`},
		{"tesl_lock_row_lease", "lease_id text, lease_token bigint, who text", "void", "volatile", `
declare l ` + ns + `tesl_schema_leases%rowtype; v integer;
begin
 select version into v from ` + ns + `tesl_schema_backfill_shards where lease_name=lease_id and state<>'final';
 if not found then raise exception 'tesl: row lease has no active shard'; end if;
 perform ` + ns + `tesl_admit(v);
 select * into l from ` + ns + `tesl_schema_leases where name=lease_id for share;
 if not found or lease_token is null or lease_token<=0 or l.token is distinct from lease_token or
 l.holder is distinct from who or who is distinct from pg_catalog.current_setting('application_name') or
 l.expires_at<=pg_catalog.clock_timestamp() then raise exception 'tesl: row lease lost or expired'; end if;
end`},
		{"tesl_renew_row_shard", "lease_id text, lease_token bigint, who text, ttl_ms bigint", "void", "volatile", `
begin
 if ttl_ms is null or ttl_ms<1 or ttl_ms>600000 then raise exception 'tesl: invalid row lease duration'; end if;
 perform ` + ns + `tesl_lock_row_lease(lease_id,lease_token,who);
 update ` + ns + `tesl_schema_leases set expires_at=pg_catalog.clock_timestamp()+ttl_ms*interval '1 millisecond' where name=lease_id;
end`},
		{"tesl_record_row_progress", "lease_id text, lease_token bigint, who text, cursor_pk jsonb, changed bigint, exhausted boolean", "void", "volatile", `
begin
 if changed is null or changed<0 or exhausted is null then raise exception 'tesl: invalid row progress'; end if;
 perform ` + ns + `tesl_lock_row_lease(lease_id,lease_token,who);
 update ` + ns + `tesl_schema_backfill_shards set last_pk=cursor_pk,rows_done=rows_done+changed,
 state=case when exhausted then 'provisional' else 'running' end,updated_at=pg_catalog.clock_timestamp() where lease_name=lease_id;
end`},
		{"tesl_release_row_shard", "lease_id text, lease_token bigint, who text", "boolean", "volatile", `
begin
 if who is distinct from pg_catalog.current_setting('application_name') then raise exception 'tesl: row lease caller differs'; end if;
 update ` + ns + `tesl_schema_leases set holder=null,expires_at=null where name=lease_id and holder=who and token=lease_token;
 return found;
end`},
	}
}
