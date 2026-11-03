package teslrt

import "github.com/jackc/pgx/v5"

// Candidate format 4 is UNPUBLISHED. No production installer, opener or CLI
// selects it until the closed queue function catalog and claim protocol land.
const pgQueueCandidateFormat = 4

func pgQueueCandidateTables(namespace string) []pgMigrationControlTable {
	ns := pgx.Identifier{namespace}.Sanitize() + "."
	return []pgMigrationControlTable{
		{"tesl_queue_baseline", `
 id smallint primary key check (id=1),
 inventory_authority text not null check (inventory_authority in ('complete','unknown')),
 established_by text not null check (established_by in ('fresh-install','format-upgrade')),
 initial_version integer not null check (initial_version between 1 and 2147483646),
 inventory_hash text check (inventory_hash ~ '^[0-9a-f]{64}$'),
 recorded_at timestamptz not null default pg_catalog.clock_timestamp(),
 check ((inventory_authority='complete' and established_by='fresh-install' and inventory_hash is not null)
     or (inventory_authority='unknown' and established_by='format-upgrade' and inventory_hash is null))`},
		{"tesl_queue_versions", `
 version integer primary key check (version between 1 and 2147483646),
 storage_snapshot_hash text not null check (storage_snapshot_hash ~ '^[0-9a-f]{64}$'),
 schema_snapshot_hash text not null check (schema_snapshot_hash ~ '^[0-9a-f]{64}$'),
 inventory_hash text not null check (inventory_hash ~ '^[0-9a-f]{64}$'),
 source_seal_inventory text not null check (source_seal_inventory in ('complete','unknown','unrecorded')),
 compiler_abi text not null check (compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 stored_value_compatibility text not null check (stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'),
 contract_count integer not null check (contract_count>=0),
 payload_count integer not null check (payload_count>=0),
 registered_at timestamptz not null default pg_catalog.clock_timestamp()`},
		{"tesl_queue_contracts", `
 version integer not null references ` + ns + `tesl_queue_versions(version),
 queue text not null check (pg_catalog.length(queue)>0),
 payload_count integer not null check (payload_count>0),
 primary key(version,queue)`},
		{"tesl_queue_payloads", `
 version integer not null,
 queue text not null,
 job_type text not null check (pg_catalog.length(job_type)>0),
 contract_format text not null check (contract_format='tesl-queue-payload-v1'),
 contract bytea not null,
 contract_hash text not null check (contract_hash ~ '^[0-9a-f]{64}$'),
 primary key(version,queue,job_type),
 unique(version,job_type),
 foreign key(version,queue) references ` + ns + `tesl_queue_contracts(version,queue),
 check (pg_catalog.encode(pg_catalog.sha256(contract),'hex')=contract_hash)`},
		{"tesl_jobs", `
 id text primary key,
 queue text not null,
 job_type text not null,
 payload jsonb not null,
 schema_version integer not null check (schema_version between 1 and 2147483646),
 status text not null check (status in ('pending','processing','dead','dead_processing','quarantined')),
 attempts integer not null default 0 check (attempts>=0),
 next_attempt_at timestamptz not null default pg_catalog.clock_timestamp(),
 seq bigint generated always as identity unique,
 locked_at timestamptz,
 locked_by text,
 claim_token text,
 claim_seq bigint not null default 0 check (claim_seq>=0),
 claimed_by_version integer check (claimed_by_version between 1 and 2147483646),
 claim_xid xid8,
 lease_until timestamptz,
 dead_reason text,
 dead_detail text check (pg_catalog.octet_length(dead_detail)<=2048),
 created_at timestamptz not null default pg_catalog.clock_timestamp(),
 foreign key(schema_version,queue,job_type) references ` + ns + `tesl_queue_payloads(version,queue,job_type),
 check ((status in ('processing','dead_processing') and locked_at is not null and locked_by is not null
   and claim_token is not null and claim_seq>0 and claimed_by_version is not null and claim_xid is not null and lease_until is not null)
 or (status not in ('processing','dead_processing') and locked_at is null and locked_by is null
   and claim_token is null and claimed_by_version is null and claim_xid is null and lease_until is null)),
 check ((status in ('dead','dead_processing') and dead_reason is not null and dead_reason='attempts-exhausted')
 or (status='quarantined' and dead_reason is not null and dead_reason in ('payload-invalid','migration-rejected','legacy-unresolved'))
 or (status in ('pending','processing') and dead_reason is null))`},
	}
}

func pgQueueCandidateIndexes(namespace string) []string {
	table := pgx.Identifier{namespace, "tesl_jobs"}.Sanitize()
	return []string{
		"create index tesl_jobs_claim_idx on " + table + " (queue,status,next_attempt_at,seq)",
		"create index tesl_jobs_version_idx on " + table + " (schema_version,status,claimed_by_version,lease_until)",
	}
}
