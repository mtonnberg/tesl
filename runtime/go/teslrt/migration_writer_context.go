package teslrt

// A release is an admission identity, not an authenticated executable identity.
// Compiled callers supply their immutable version. A caller claiming an older,
// still-admitted release has that release's permissions. Retirement, rather than
// a caller-controlled setting, removes those permissions.
//
// Keep one replaceable record per backend, with an xid8 to distinguish successive
// transactions (including connection-pool reuse and transaction-ID wraparound).
// Rollback/savepoint rollback restores both the record and its transaction locks.
// No key values or uniqueness reservations are stored here.
func pgWriterContextTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{{"tesl_writer_context", `
 backend_pid integer primary key check(backend_pid>0),
 transaction_id xid8 not null,
 database_uuid uuid not null,
 version integer not null check(version between 1 and 2147483646)`}}
}

func pgWriterContextFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_admit_writer", "v integer", "integer", "volatile", `
declare m ` + ns + `tesl_schema_meta%rowtype;
 previous ` + ns + `tesl_writer_context%rowtype;
 xid xid8; admitted_floor integer;
begin
 if v is null or v<1 or v>2147483646 then raise exception 'tesl: invalid writer version'; end if;
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then
  raise exception 'tesl: writer context requires READ COMMITTED'; end if;
 select * into m from ` + ns + `tesl_schema_meta where id=1;
 if not found or m.format_version<>5 then raise exception 'tesl: writer context requires format5'; end if;
 xid:=pg_catalog.pg_current_xact_id();
 select * into previous from ` + ns + `tesl_writer_context where backend_pid=pg_catalog.pg_backend_pid();
 if found and previous.transaction_id=xid and
  (previous.version is distinct from v or previous.database_uuid is distinct from m.database_uuid) then
  raise exception 'tesl: writer identity cannot change within a transaction'; end if;
 -- This volatile function uses separate SPI statements: admission must obtain
 -- a fresh snapshot AFTER any wait for the retiring version's exclusive fence.
 perform pg_catalog.pg_advisory_xact_lock_shared(m.fence_ns,v);
 admitted_floor:=` + ns + `tesl_admit(v);
 if previous.transaction_id is distinct from xid then
  insert into ` + ns + `tesl_writer_context(backend_pid,transaction_id,database_uuid,version)
   values(pg_catalog.pg_backend_pid(),xid,m.database_uuid,v)
   on conflict(backend_pid) do update set transaction_id=excluded.transaction_id,
    database_uuid=excluded.database_uuid,version=excluded.version;
 end if;
 return admitted_floor;
end`},
		// Only owner-definer mutation guards consume this value. There is no
		// GUC, representation-generation marker, or caller-supplied version here.
		{"tesl_writer_version", "", "integer", "volatile", `
declare m ` + ns + `tesl_schema_meta%rowtype;
 writer ` + ns + `tesl_writer_context%rowtype;
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then
  raise exception 'tesl: writer context requires READ COMMITTED'; end if;
 select * into m from ` + ns + `tesl_schema_meta where id=1;
 if not found or m.format_version<>5 then raise exception 'tesl: writer context requires format5'; end if;
 select * into writer from ` + ns + `tesl_writer_context
  where backend_pid=pg_catalog.pg_backend_pid() and transaction_id=pg_catalog.pg_current_xact_id_if_assigned()
   and database_uuid=m.database_uuid;
 if not found then raise exception 'tesl: missing admitted writer transaction'; end if;
 if not exists(select 1 from pg_catalog.pg_locks l where l.locktype='advisory'
  and l.pid=pg_catalog.pg_backend_pid() and l.granted and l.classid=m.fence_ns::oid
  and l.objid=writer.version::oid and l.objsubid=2 and l.mode in ('ShareLock','ExclusiveLock')) then
  raise exception 'tesl: admitted writer fence is missing'; end if;
 perform ` + ns + `tesl_admit(writer.version);
 return writer.version;
end`},
	}
}
