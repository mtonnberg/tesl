-- [normative-template] the control schema, created once at the first bootstrap (or by --schema adopt), never by a version.
-- The lease table does not exist yet, so the guard is a database-scoped advisory lock in Tesl's fixed bootstrap
-- namespace with key2 = 0 (reserved: no version is 0), taken BEFORE the first CREATE. This is the ONE fixed-namespace
-- lock: it only serialises bootstraps, so sharing it across schema families in one database is harmless. Every fence
-- below uses the database's own :fence_ns instead.
-- This bootstrap runs under a short-lived installer identity with temporary tesl_control membership. Before
-- request/worker grants are applied, ownership of the namespace, global fence registry, every tesl_schema_* table and
-- every transition function is transferred to tesl_control; membership is then revoked. tesl_schema receives
-- USAGE/CREATE on the namespace and owns each generated entity object, but no long-lived login is a tesl_control member.
begin;
select pg_advisory_xact_lock(32341, 0);
create schema if not exists notes_app;            -- a genuinely empty database has no namespace yet (today's bootstrap
                                                  -- creates it too, postgres.go:228); the empty-database test must NOT
                                                  -- pre-create it in fixture setup
-- HARNESS STEP assign_and_assert_namespace_owner: notes_app → tesl_control; grant tesl_schema USAGE, CREATE;
--   a pre-existing namespace under any other owner is drift and is refused rather than adopted
create table if not exists public.tesl_fence_namespaces (
  fence_ns int generated always as identity primary key check (fence_ns between 1 and 2147483646),
  database_uuid uuid not null unique);             -- database-wide allocation; random 31-bit truncation can collide
-- HARNESS STEP assert_registry_owner_and_shape: the existing registry must have this exact catalog shape, be owned by
-- tesl_control and grant no write privilege to PUBLIC or long-lived login roles; `IF NOT EXISTS` never adopts an
-- attacker-created lookalike.
create table if not exists notes_app.tesl_schema_meta (        -- the CONTROL SCHEMA's own version — see below
  id smallint primary key check (id = 1), format_version int not null,
  database_uuid uuid not null unique,      -- the ONE stable identity of this logical database: minted at bootstrap or
                                           -- adopt, preserved across control-schema upgrades and physical restores,
                                           -- carried in every status report, activation plan, audit row and prune
                                           -- artefact. A clone promoted to an independent environment must run
                                           -- `app --schema reidentify` (new uuid, audited); prune rejects two target
                                           -- reports with one uuid and different deployment identities unless the
                                           -- inventory declares them replicas of one logical database.
  -- three protocol facts, deliberately separate:
  max_observed_protocol    int not null,   -- informational, monotonic: the highest protocol any binary reported;
                                           -- takes part in NO admission or retirement decision
  retirement_protocol_floor int not null,  -- the protocol proven safe to RETIRE against (advanced only by activation)
  fence_ns                 int not null,   -- key1 of every fence lock of THIS logical database: allocated uniquely from
                                           -- public.tesl_fence_namespaces at bootstrap and read before the first fence.
                                           -- Advisory locks are per PostgreSQL database, not per schema; truncating a UUID
                                           -- or hashing a name cannot prove isolation because collisions remain possible
  fence_domain             text not null); -- identifies the lock-key algorithm ('tesl-1' = pg_advisory_*(fence_ns, version),
                                           -- never hashtext); retirement requires every admitted
                                           -- version to share it — an integer ordering alone cannot say "compatible".
                                           -- It is immutable for this design; activation may raise protocol coverage but
                                           -- cannot rewrite historical lock identity.
create table if not exists notes_app.tesl_schema_activation_plans (       -- what a pending ceremony is AUTHORISED to do
  nonce text primary key, database_id text not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null, from_protocol int not null, to_protocol int not null,
  fence_domain text not null,                 -- immutable; changing the lock algorithm/domain is an offline protocol redesign
  old_role_generation text not null, new_role_generation text not null,
  expected_grants jsonb not null,
  plan_hash text not null,                 -- binds database_uuid, cluster system identifier, database name, schema
                                           -- target, role generations, protocols, immutable fence domain, expiry and grants,
                                           -- so a script generated for one database cannot be applied to another
  status text not null check (status in ('pending','consumed','expired','failed')),
  verified_at timestamptz, consumed_at timestamptz,
  failure_code text, failure_detail text); -- 'failed' is TERMINAL for a mismatch (a new plan is needed) and
                                           -- RETRYABLE only for 'old-backend-still-present'; the code says which
create table if not exists notes_app.tesl_schema_stages (      -- staged unique indexes (a multi-version obligation)
  stage_id text primary key,               -- stable semantic identity: entity + typed key columns + collation + null rule
  entity text not null, key_columns jsonb not null, declaration_hash text not null,
  created_version int not null, last_carried_version int not null,
  state text not null check (state in ('pending','promoting','enforced','blocked_duplicates','cancelled')),
  target_index text, duplicate_keys jsonb, last_error text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists notes_app.tesl_schema_queue_restamps ( -- queue restamp/migration progress for ONE retirement
  plan_hash text primary key, from_versions int[] not null, to_version int not null,  -- plan: the retirement-plan hash
  cursor text, rows_done bigint not null default 0,
  state text not null check (state in ('running','complete','failed')), last_error text,
  started_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists notes_app.tesl_schema_backfill_jobs ( -- application-level fills (generated workers), NOT the
  job_id text primary key, entity text not null,                  -- migration engine's per-entity generation cursor
  from_version int not null, to_version int not null, worker_hash text not null,
  cursor jsonb, rows_done bigint not null default 0,
  state text not null check (state in ('running','paused','provisional','final','failed','cancelled')),
  throttle jsonb, last_error text, created_at timestamptz not null default now(), completed_at timestamptz);
create table if not exists notes_app.tesl_schema_protocol_activations (   -- append-only audit of the ceremony
  seq bigserial primary key, activated_at timestamptz not null default now(),
  from_protocol int not null, to_protocol int not null, fence_domain text not null,
  old_role_generation text not null, new_role_generation text not null,
  operator text not null, evidence_kind text not null check (evidence_kind in ('role-termination','platform-barrier')),
  evidence_ref text not null, nonce text not null unique);
create table if not exists notes_app.tesl_schema_barriers (
  barrier_id uuid primary key, operation text not null,
  state text not null check (state in ('prepared','revoked','kept','restored')),
  database_oid oid not null, original_datacl aclitem[], target_logins jsonb not null,
  prepared_at timestamptz not null default now(), restored_at timestamptz,
  operator text not null);                     -- exact crash-recovery source for CONNECT ACL restoration
create table if not exists notes_app.tesl_schema_state (       -- ONE row: the database's admission state
  id            smallint primary key check (id = 1),
  min_version   int not null,                                  -- oldest admitted schema version
  current       int not null,                                  -- highest expanded version
  installing_version int,                                      -- crash-stable target while current = 0
  compat_floor  int not null default 0);                       -- highest version whose predecessor's compatibility
                                                               -- objects are being/have been dropped: admitted
                                                               -- binaries at or below it run SETTLED plans for
                                                               -- that window; set BEFORE the first drop; monotonic
create table if not exists notes_app.tesl_schema_versions (    -- append-only lifecycle rows
  version int not null,
  step text not null check (step in ('expanded', 'retired', 'contracting', 'contracted', 'repair')),  -- COMPLETE enum
  seq smallint not null default 0,                             -- repair amendments are numbered
  snapshot_hash text,                                          -- the schema module's hash (expanded rows only)
  artefact_hash text not null,                                 -- expanded: migration hash; contracted: contract hash;
                                                               -- repair: repair hash; retired: the RETIREMENT PLAN hash
                                                               -- (versions retired, entities/generations finalised, jobs
                                                               -- restamped, executor command) — additive versions have no
                                                               -- contract artefact, so this is what a retirement is accountable to
  applied_at timestamptz not null default now(),
  protocol_level int not null, fence_domain text not null,     -- of the binary that PERFORMED this step (for 'expanded' the
  epoch_preserving boolean,                                    -- non-NULL on expanded rows; immutable admission input
                                                               -- expander, whose values retirement compatibility is judged on;
                                                               -- for 'retired'/'contracted' the executor, for audit)
  executed_by text,                                            -- instance id of the executor (audit)
  check ((step = 'expanded') = (epoch_preserving is not null)),
  primary key (version, step, seq));
create table if not exists notes_app.tesl_schema_entities (    -- per-entity generation + backfill state
  entity text primary key, generation smallint not null, target_generation smallint not null,
  last_pk jsonb,                                               -- the primary key as a JSON array of column values,
                                                               -- compared by the emitted typed keyset predicate, never as text
  rows_done bigint not null default 0, final_at timestamptz);
  -- ONE job per entity is an invariant, not a hope: an entity's generations advance strictly one at a
  -- time (invariant 2), the next version's expand cannot start a new row-function migration for an
  -- entity whose previous one is not final (boot gate row "two generations behind"), and contract
  -- touches no cursor. last_pk/rows_done here are the AGGREGATE of the shards below.
create table if not exists notes_app.tesl_schema_adoption (
  entity text primary key,
  expected_catalog_hash text not null,
  state text not null check (state in ('pending','marker-added','verified')),
  updated_at timestamptz not null default now());               -- resumable per-table adopt; cleared after final record
create table if not exists notes_app.tesl_schema_backfill_shards (   -- parallel work units of ONE entity's job
  entity text not null, shard smallint not null, target_generation smallint not null,
  lo_pk jsonb, hi_pk jsonb,                                   -- [lo, hi) primary-key range from pg_stats histogram bounds
  last_pk jsonb, rows_done bigint not null default 0,
  state text not null check (state in ('pending','running','provisional','final')),
  holder text, updated_at timestamptz not null default now(),
  primary key (entity, shard, target_generation));           -- the entity stays the unit of FINALITY; a shard is work
create table if not exists notes_app.tesl_schema_leases (
  name text primary key, holder text, token bigint not null default 0, expires_at timestamptz,
  holder_instance text);                                       -- every connection of that executor carries
                                                               -- application_name = 'tesl-exec:<holder_instance>'; the successor
                                                               -- reasons about the SET of such backends in pg_stat_activity:
                                                               -- none → dead, take over now; some + expired → terminate all,
                                                               -- wait until none, take over; some + live → wait
create table if not exists notes_app.tesl_schema_instances (   -- heartbeats: observability, never a guard
  instance text primary key, version int not null, protocol_level int not null, last_seen timestamptz not null,
  compat_floor_seen int not null default 0);   -- the plan mode this instance has switched to; contract's grace wait reads it
create table if not exists notes_app.tesl_schema_index (name text primary key, state text not null, attempts int not null default 0, error text);
create table if not exists notes_app.tesl_schema_quarantine (
  entity text, pk jsonb, target_generation smallint, attempt int,  -- V8's failures and V9's are different rows
  reason text, seen_at timestamptz, primary key (entity, pk, target_generation, attempt));
-- Worker observability and progress writes are explicit. None of these grants
-- permits direct lifecycle/floor, protocol-activation or barrier writes.
grant select on notes_app.tesl_schema_meta, notes_app.tesl_schema_state,
  notes_app.tesl_schema_versions, notes_app.tesl_schema_instances to tesl_schema;
grant select, insert, update, delete on notes_app.tesl_schema_entities,
  notes_app.tesl_schema_backfill_shards, notes_app.tesl_schema_leases,
  notes_app.tesl_schema_index, notes_app.tesl_schema_quarantine,
  notes_app.tesl_schema_queue_restamps, notes_app.tesl_schema_backfill_jobs,
  notes_app.tesl_schema_stages to tesl_schema;
create or replace function notes_app.tesl_admit(v int) returns int language plpgsql stable security definer
set search_path = pg_catalog, notes_app, pg_temp as $$
declare m int; f int;
begin
  select min_version, compat_floor into m, f from notes_app.tesl_schema_state where id = 1;  -- the one lookup
  if not found then raise exception 'tesl: schema admission singleton is missing'; end if;
  if m > v then raise exception 'tesl: schema version % is retired (min_version %)', v, m; end if;
  return f;      -- the ONE admission API: raises if retired, otherwise returns compat_floor, so every fenced
end $$;          -- write and every admitted read learns the plan mode without an extra statement
alter function notes_app.tesl_admit(int) owner to tesl_control;
revoke execute on function notes_app.tesl_admit(int) from public;
grant execute on function notes_app.tesl_admit(int) to tesl_app, tesl_schema;

create or replace function notes_app.tesl_heartbeat(v int, proto int, seen_floor int) returns void
language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare instance_id text := current_setting('application_name', true);
begin
  perform notes_app.tesl_admit(v);
  if instance_id is null or instance_id !~ '^tesl-(app|exec):' then
    raise exception 'tesl: application_name must carry a registered tesl instance id'; end if;
  insert into notes_app.tesl_schema_instances(instance, version, protocol_level, last_seen, compat_floor_seen)
    values (instance_id, v, proto, clock_timestamp(), seen_floor)
  on conflict (instance) do update
    set version = excluded.version, protocol_level = excluded.protocol_level,
        last_seen = excluded.last_seen,
        compat_floor_seen = greatest(tesl_schema_instances.compat_floor_seen, excluded.compat_floor_seen);
  update notes_app.tesl_schema_meta
     set max_observed_protocol = greatest(max_observed_protocol, proto) where id = 1;
end $$;
alter function notes_app.tesl_heartbeat(int, int, int) owner to tesl_control;
revoke execute on function notes_app.tesl_heartbeat(int, int, int) from public;
grant execute on function notes_app.tesl_heartbeat(int, int, int) to tesl_app, tesl_schema;

-- The lifecycle is a state machine, and the database enforces its edges (re-review, 2026-09-04: a recorder that
-- validated only 'expanded' would have accepted a 'contracted' without expansion, a repair gap, or a 'retired' written
-- outside tesl_advance_floor). Design: one PRIVATE core that owns the insert — it never leaves the transaction aborted
-- on a duplicate (a raw INSERT would: a unique violation aborts the whole transaction) and refuses a duplicate with a
-- different hash (immutable history) — and one PUBLIC function per transition that validates that transition's
-- preconditions and calls the core. The core's EXECUTE is revoked from everyone; the public functions are SECURITY
-- DEFINER and owned by `tesl_control`, a NOLOGIN role that owns the control schema's functions, so neither tesl_schema
-- nor tesl_app can write a lifecycle row except through a validated edge. 'retired' has no public function at all:
-- only tesl_advance_floor (also owned by tesl_control) reaches the core for it.
create or replace function notes_app.tesl_lifecycle_core__(
    v int, s text, q int, snap text, art text, proto int, dom text, ep boolean, who text) returns void
language plpgsql as $$
declare r notes_app.tesl_schema_versions%rowtype;
begin
  if v is null or v < 1 or v >= 2147483647 then
    raise exception 'tesl: schema version % is outside [1, 2147483646]', v; end if;
  if s = 'expanded' and (snap is null or snap = '') then
    raise exception 'tesl: expanded snapshot hash is missing'; end if;
  if proto is null or proto < 0 or dom is null or dom = '' then
    raise exception 'tesl: lifecycle protocol identity is missing or invalid'; end if;
  if art is null or art = '' then raise exception 'tesl: lifecycle artefact hash is missing'; end if;
  if q < 0 or q > 32767 then raise exception 'tesl: lifecycle seq % out of range', q; end if;   -- column is smallint
  insert into notes_app.tesl_schema_versions
      (version, step, seq, snapshot_hash, artefact_hash, protocol_level, fence_domain, epoch_preserving, executed_by)
    values (v, s, q::smallint, snap, art, proto, dom, ep, who)
    on conflict (version, step, seq) do nothing;                       -- a duplicate is not an error yet …
  select * into r from notes_app.tesl_schema_versions where version = v and step = s and seq = q;
  if r.artefact_hash is distinct from art or r.snapshot_hash is distinct from snap
     or r.protocol_level is distinct from proto or r.fence_domain is distinct from dom
     or r.epoch_preserving is distinct from ep then  -- duplicate differs
    raise exception 'tesl: immutable history: (%, %, %) is already recorded with a different hash', v, s, q;
  end if;                                                              -- equal hashes: idempotent retry, continue
end $$;
revoke execute on function notes_app.tesl_lifecycle_core__(int, text, int, text, text, int, text, boolean, text) from public;
alter function notes_app.tesl_lifecycle_core__(int, text, int, text, text, int, text, boolean, text) owner to tesl_control;

create or replace function notes_app.tesl_record_expanded(v int, snap text, art text, proto int, dom text, ep boolean, who text)
returns void language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare c int; installing int;
begin
  select current, installing_version into c, installing from tesl_schema_state where id = 1 for update;
  if not found then raise exception 'tesl: schema state singleton is missing'; end if;
  if c = 0 and installing is distinct from v then
    raise exception 'tesl: initial install target is V%, not V%', installing, v; end if;
  if ep is null then raise exception 'tesl: V% has no epoch-preserving classification', v; end if;
  if c <> 0 and c <> v - 1 and c <> v then
    raise exception 'tesl: cannot record V% expanded while current = % (deploy versions in order)', v, c;
  end if;
  if exists (select 1 from tesl_schema_versions where version = v and step = 'retired') then
    raise exception 'tesl: V% is already retired', v;
  end if;
  perform tesl_lifecycle_core__(v, 'expanded', 0, snap, art, proto, dom, ep, who);
  if c = 0 then
    -- A direct-current install has no compatibility window. Its migration hash is also the defined initial-install hash.
    perform tesl_lifecycle_core__(v, 'contracting', 0, null, art, proto, dom, null, who);
    perform tesl_lifecycle_core__(v, 'contracted', 0, null, art, proto, dom, null, who);
  end if;
  update tesl_schema_state                                             -- row and singleton in ONE statement's transaction
     set current = v, min_version = case when min_version = 0 then v else min_version end,
         installing_version = null,
         compat_floor = case when c = 0 then greatest(compat_floor, v) else compat_floor end
   where id = 1 and current < v;                                       -- idempotent on a retry that already moved it
  update tesl_schema_meta set max_observed_protocol = greatest(max_observed_protocol, proto) where id = 1;
end $$;
alter function notes_app.tesl_record_expanded(int, text, text, int, text, boolean, text) owner to tesl_control;
revoke execute on function notes_app.tesl_record_expanded(int, text, text, int, text, boolean, text) from public;
grant execute on function notes_app.tesl_record_expanded(int, text, text, int, text, boolean, text) to tesl_schema;

create or replace function notes_app.tesl_record_contracted(v int, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare started notes_app.tesl_schema_versions%rowtype;
begin
  if not exists (select 1 from tesl_schema_versions where version = v and step = 'expanded') then
    raise exception 'tesl: V% was never expanded', v; end if;
  if exists (select 1 from tesl_schema_versions where version = v - 1 and step = 'expanded')
     and not exists (select 1 from tesl_schema_versions where version = v - 1 and step = 'retired') then
    raise exception 'tesl: V% cannot be contracted before V% is retired', v, v - 1; end if;
  if (select compat_floor from tesl_schema_state where id = 1) < v then
    raise exception 'tesl: compat_floor must reach V% before its contract is recorded', v; end if;
  select * into started from tesl_schema_versions where version = v and step = 'contracting' and seq = 0;
  if not found then
    raise exception 'tesl: V% never began contracting', v; end if;
  if started.artefact_hash is distinct from art or started.protocol_level is distinct from proto
     or started.fence_domain is distinct from dom then
    raise exception 'tesl: V% contract identity differs from its contracting row', v; end if;
  perform tesl_lifecycle_core__(v, 'contracted', 0, null, art, proto, dom, null, who);
end $$;
alter function notes_app.tesl_record_contracted(int, text, int, text, text) owner to tesl_control;
revoke execute on function notes_app.tesl_record_contracted(int, text, int, text, text) from public;
grant execute on function notes_app.tesl_record_contracted(int, text, int, text, text) to tesl_schema;

create or replace function notes_app.tesl_record_repair(v int, q int, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare last_seq int;
begin
  if not exists (select 1 from tesl_schema_versions where version = v and step = 'expanded') then
    raise exception 'tesl: V% was never expanded', v; end if;
  select coalesce(max(seq), 0) into last_seq from tesl_schema_versions where version = v and step = 'repair';
  if q <> last_seq + 1 and not exists (select 1 from tesl_schema_versions where version = v and step = 'repair' and seq = q) then
    raise exception 'tesl: repair % of V% would leave a gap (last recorded %)', q, v, last_seq; end if;
  perform tesl_lifecycle_core__(v, 'repair', q, null, art, proto, dom, null, who);
end $$;
alter function notes_app.tesl_record_repair(int, int, text, int, text, text) owner to tesl_control;
revoke execute on function notes_app.tesl_record_repair(int, int, text, int, text, text) from public;
grant execute on function notes_app.tesl_record_repair(int, int, text, int, text, text) to tesl_schema;
-- Every illegal edge is a negative acceptance test: contracted before expanded, contracted before the predecessor's
-- retirement, contracted before compat_floor, a repair gap, a repair of an unexpanded version, expanded out of order,
-- expanded after retired, and a direct call to the core or a direct INSERT as tesl_schema (privilege refusal).

create or replace function notes_app.tesl_begin_contract(v int, art text, proto int, dom text, who text)
returns void language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare st notes_app.tesl_schema_state%rowtype;
begin
  select * into st from notes_app.tesl_schema_state where id = 1 for update;
  if st.current < v or not exists (select 1 from notes_app.tesl_schema_versions where version = v and step = 'expanded') then
    raise exception 'tesl: V% is not expanded', v; end if;
  if st.min_version < v then raise exception 'tesl: predecessor of V% is still admitted', v; end if;
  perform notes_app.tesl_lifecycle_core__(v, 'contracting', 0, null, art, proto, dom, null, who);
  update notes_app.tesl_schema_state set compat_floor = greatest(compat_floor, v) where id = 1;
end $$;
alter function notes_app.tesl_begin_contract(int, text, int, text, text) owner to tesl_control;
revoke execute on function notes_app.tesl_begin_contract(int, text, int, text, text) from public;
grant execute on function notes_app.tesl_begin_contract(int, text, int, text, text) to tesl_schema;

-- tesl_advance_floor is the ONLY writer of min_version (the `tesl_advance_floor` transition of the prose). Every
-- caller — destructive contract, additive slot retirement, close-epoch, apply-offline, any future recovery — calls it;
-- no template and no generated code may `update … set min_version`. It verifies, inside the caller's transaction,
-- with server-side truth where one exists:
create or replace function notes_app.tesl_advance_floor(
    expected int, next int, plan_hash text, proto int, dom text, who text) returns void
language plpgsql security definer set search_path = pg_catalog, notes_app, pg_temp as $$
declare m notes_app.tesl_schema_meta%rowtype; st notes_app.tesl_schema_state%rowtype; r record; v int; n int;
begin
  select * into m from notes_app.tesl_schema_meta where id = 1;
  if m.fence_domain <> dom then
    raise exception 'tesl: executor fence domain % differs from the database''s %', dom, m.fence_domain;
  end if;
  -- (0) the range itself, before any other work: strictly increasing, not beyond what is expanded, exactly one
  --     'expanded' row per version in it (contiguous, no gaps — a missing row must not be silently skipped and then
  --     given a synthetic 'retired' row), none of them already retired, and `expected` is the current floor
  select * into st from notes_app.tesl_schema_state where id = 1 for update;
  if next <= expected then raise exception 'tesl: floor range % -> % is not increasing', expected, next; end if;
  if next > st.current then raise exception 'tesl: cannot retire up to V% while only V% is expanded', next - 1, st.current; end if;
  if st.min_version <> expected then raise exception 'tesl: min_version is %, not %', st.min_version, expected; end if;
  select count(*) into n from notes_app.tesl_schema_versions
   where step = 'expanded' and version between expected and next - 1;
  if n <> next - expected then
    raise exception 'tesl: % of % versions in [%, %] have an expanded row; history is not contiguous', n, next - expected, expected, next - 1;
  end if;
  if exists (select 1 from notes_app.tesl_schema_versions where step = 'retired' and version between expected and next - 1) then
    raise exception 'tesl: a version in [%, %] is already retired', expected, next - 1;
  end if;
  -- (1) the retirement protocol is active for every version being retired, and each was expanded in THIS fence
  --     domain — a version expanded under another lock-key algorithm cannot be excluded by this one
  for r in select version, protocol_level, fence_domain from notes_app.tesl_schema_versions
            where step = 'expanded' and version between expected and next - 1 loop
    if r.protocol_level > m.retirement_protocol_floor or r.fence_domain <> dom then
      raise exception 'tesl: V% was expanded at protocol % in domain %; retirement is activated only up to protocol % in %',
        r.version, r.protocol_level, r.fence_domain, m.retirement_protocol_floor, m.fence_domain;
    end if;
  end loop;
  -- (2) this transaction holds every retired version's fence key EXCLUSIVELY — read from pg_locks, not asserted
  for v in expected .. next - 1 loop
    if not exists (select 1 from pg_locks
                    where locktype = 'advisory' and pid = pg_backend_pid() and granted
                      and classid = m.fence_ns::oid and objid = v::oid and objsubid = 2 and mode = 'ExclusiveLock') then
      raise exception 'tesl: fence key for V% is not held exclusively by this transaction', v;
    end if;
  end loop;
  -- (3) final-generation condition: no entity still owes rows to a migration (the harness sets generation =
  --     target_generation only after its own `count(*) where _tesl_v < g` postcondition held under the fence)
  select count(*) into n from notes_app.tesl_schema_entities where generation < target_generation;
  if n > 0 then raise exception 'tesl: % entities are not final; the final pass must complete first', n; end if;
  -- (4) queue postcondition: no non-quarantined job row below the new floor
  if exists (select 1 from notes_app.tesl_jobs where schema_version < next and status <> 'quarantined') then
    raise exception 'tesl: job rows below V% remain; restamp/migrate them first', next;
  end if;
  -- (5) compare-and-set on the expected floor
  update notes_app.tesl_schema_state set min_version = next where id = 1 and min_version = expected;
  if not found then raise exception 'tesl: min_version is not % (concurrent retirement?)', expected; end if;
  -- (6) one 'retired' lifecycle row per retired version, through the same recorder, same transaction
  for v in expected .. next - 1 loop
    perform notes_app.tesl_lifecycle_core__(v, 'retired', 0, null, plan_hash, proto, dom, null, who);   -- the ONLY path to 'retired'
  end loop;
end $$;
alter function notes_app.tesl_advance_floor(int, int, text, int, text, text) owner to tesl_control;
revoke execute on function notes_app.tesl_advance_floor(int, int, text, int, text, text) from public;
grant execute on function notes_app.tesl_advance_floor(int, int, text, int, text, text) to tesl_schema;
-- HARNESS STEP assign_and_assert_control_owners: public.tesl_fence_namespaces and every tesl_schema_* relation →
--   tesl_control; exact existing ownership/ACLs are verified before any seed write
-- bootstrap seed, still inside the transaction that took the bootstrap lock and created the tables above:
with u as (
  select gen_random_uuid() as database_uuid
   where not exists (select 1 from notes_app.tesl_schema_meta where id = 1)),
allocated as (
  insert into public.tesl_fence_namespaces (database_uuid)
    select database_uuid from u returning database_uuid, fence_ns)
insert into notes_app.tesl_schema_meta (id, format_version, database_uuid, max_observed_protocol, retirement_protocol_floor, fence_ns, fence_domain)
  select 1, :format_version, database_uuid, :max_observed_protocol, :retirement_protocol_floor, fence_ns, :fence_domain
    from allocated
  on conflict (id) do nothing;                    -- the UUID is minted by the database, never by a client
-- Fresh bootstrap binds both protocol values to the current level. Adoption binds max_observed_protocol to the current
-- binary but retirement_protocol_floor to the proven pre-fence level until activate-protocol completes.
insert into notes_app.tesl_schema_state (id, min_version, current, installing_version, compat_floor) values (1, 0, 0, null, 0)
  on conflict do nothing;                         -- current = 0: NOTHING is expanded yet. min_version = 0: NO floor yet —
                                                  -- `tesl_admit` passes every version until the initial expansion below
                                                  -- sets both to :v in one statement. Seeding min_version = :v (the first
                                                  -- draft) would have let a V9 seeder refuse a V8 that then won the lease.
insert into notes_app.tesl_schema_leases (name) values ('boot'), ('backfill') on conflict do nothing;
commit;
