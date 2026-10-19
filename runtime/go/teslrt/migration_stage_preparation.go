package teslrt

// Preparation records remain pending and immutable, including during a guarded
// declaration window. Guard activation is recorded separately; neither record
// claims enforced uniqueness or authorizes a UNIQUE index build.
import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgStagePreparation struct {
	id, entity, field, table, column, scalar, index, descriptor string
	nullable                                                    bool
}

func pgStageStorageShape(n pgRowCanonical) bool {
	return n.list(3) && n.children[0].isAtom("postgres-storage-v1") ||
		n.list(4) && n.children[0].isAtom("postgres-storage-v2") && !n.children[3].atom
}

func pgParseStagePreparations(n pgRowCanonical) ([]pgStagePreparation, error) {
	if n.atom {
		return nil, fmt.Errorf("stage inventory must be a sequence")
	}
	var stages []pgStagePreparation
	last := ""
	indexes := map[string]bool{}
	for _, entry := range n.children {
		if !entry.list(10) || !entry.children[0].isAtom("staged-unique-preparation-v1") {
			return nil, fmt.Errorf("unsupported stage preparation descriptor")
		}
		for _, i := range []int{1, 3, 4, 5, 6, 7, 9} {
			if !entry.children[i].atom {
				return nil, fmt.Errorf("stage descriptor atom required")
			}
		}
		c := entry.children
		stage := pgStagePreparation{id: c[1].value, entity: c[3].value, field: c[4].value,
			table: c[5].value, column: c[6].value, scalar: c[7].value, nullable: pgRowBool(c[8], true),
			index: c[9].value, descriptor: pgRowEncode(entry)}
		semantic := c[2]
		equality := "default-btree"
		if stage.scalar == "text" {
			equality = "default-text-btree-libc-c-posix-v1"
		}
		if !semantic.list(8) || !semantic.children[0].isAtom("staged-unique-key-v1") ||
			!semantic.children[1].atom || !semantic.children[2].isAtom(stage.table) || !semantic.children[3].isAtom(stage.field) ||
			!semantic.children[5].isAtom(equality) || !semantic.children[6].isAtom("nulls-distinct") || !semantic.children[7].isAtom("immediate") {
			return nil, fmt.Errorf("stage equality or semantic identity differs")
		}
		document := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("snapshot"), semantic)
		if stage.id <= last || !pgMigrationDigest(stage.id) || fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(document)))) != stage.id ||
			!pgQueueIdentity(stage.entity) || !pgRowName(stage.field) || !pgMigrationIdentifier(stage.table) || !pgMigrationIdentifier(stage.column) ||
			!pgMigrationIdentifier(stage.index) || indexes[stage.index] || !slices.Contains([]string{"bool", "int4", "int8", "text"}, stage.scalar) ||
			(!pgRowBool(c[8], true) && !pgRowBool(c[8], false)) {
			return nil, fmt.Errorf("invalid stage identity, physical domain or canonical order")
		}
		last, indexes[stage.index] = stage.id, true
		stages = append(stages, stage)
	}
	return stages, nil
}

func pgStagesFromStorage(storage pgRowCanonical) ([]pgStagePreparation, error) {
	if !pgStageStorageShape(storage) {
		return nil, fmt.Errorf("unsupported staged source storage format")
	}
	if storage.list(3) {
		return nil, nil
	}
	stages, err := pgParseStagePreparations(storage.children[3])
	if err == nil && len(stages) == 0 {
		return nil, fmt.Errorf("stage storage v2 requires a nonempty stage inventory")
	}
	return stages, err
}

func pgVerifyStagePhysical(plan *pgRowPhysicalPlan) error {
	for _, stage := range plan.stages {
		entity := plan.entity(stage.entity)
		if entity == nil || entity.table != stage.table || entity.field(stage.field) != stage.column {
			return fmt.Errorf("stage physical projection differs")
		}
		column := entity.column(stage.column)
		if column == nil || column.catalog.Type != stage.scalar || column.catalog.Nullable != stage.nullable || column.catalog.PrimaryKey {
			return fmt.Errorf("stage physical carrier differs")
		}
		if !slices.ContainsFunc(entity.indexes, func(index PgMigrationCatalogIndex) bool {
			return index.Name == stage.index && !index.Unique && slices.Equal(index.Columns, []string{stage.column})
		}) {
			return fmt.Errorf("stage lacks exact preparatory nonunique index")
		}
	}
	return nil
}

func pgVerifyStageLineage(previous, plan *pgRowPhysicalPlan) error {
	for _, s := range plan.stageCancellations {
		if previous == nil || !slices.Contains(previous.stages, s) || !slices.Contains(plan.stages, s) || slices.ContainsFunc(previous.stageGuards, func(g pgStageGuard) bool { return g.preparation == s }) || slices.ContainsFunc(previous.stageReliance, func(g pgStageGuard) bool { return g.preparation == s }) {
			return fmt.Errorf("cancellation requires an exact pending, unguarded predecessor")
		}
	}
	if previous != nil && len(previous.stageGuards) != 0 && (plan.stageRelianceVersion != previous.version || !slices.Equal(plan.stageReliance, previous.stageGuards)) {
		return fmt.Errorf("guarded promotion successor requires its exact enforced-stage prerequisite")
	}
	for _, guard := range plan.stageGuards {
		if previous == nil || !slices.Contains(previous.stages, guard.preparation) || !slices.Contains(plan.stages, guard.preparation) {
			return fmt.Errorf("guarded promotion lacks its exact pending predecessor")
		}
		for _, entity := range plan.entities {
			if slices.ContainsFunc(entity.indexes, func(i PgMigrationCatalogIndex) bool { return i.Name == guard.target }) {
				return fmt.Errorf("guarded promotion must not create or require its unique target")
			}
		}
	}
	if len(plan.stages) > 0 && (plan.version < 2 || !pgRowEpochPreserving(plan) || plan.requiresContractVersion > 0) {
		return fmt.Errorf("stage preparation requires an additive existing-table revision after original V1")
	}
	if previous == nil {
		return nil
	}
	for _, old := range previous.stages {
		if !slices.Contains(plan.stages, old) && !slices.Contains(previous.stageCancellations, old) {
			return fmt.Errorf("pending preparation cannot disappear or change; guarded windows retain it")
		}
	}
	for _, stage := range plan.stages {
		if slices.ContainsFunc(plan.stageReliance, func(g pgStageGuard) bool { return g.preparation == stage }) {
			continue
		}
		if slices.Contains(previous.stages, stage) {
			continue
		}
		entity := previous.entity(stage.entity)
		if entity == nil || entity.column(stage.column) == nil || slices.ContainsFunc(entity.indexes, func(i PgMigrationCatalogIndex) bool { return i.Name == stage.index }) {
			return fmt.Errorf("new stage requires its own new nonunique index on an existing table/key")
		}
	}
	return nil
}

// Every current-toolchain original-V1 installation includes this explicitly
// versioned extension, even before a stage exists. A pre-extension development
// catalog is rejected by exact catalog observation; it is never silently adopted.
func pgStageControlTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_schema_stage_protocol", `id smallint primary key check(id=1), format integer not null check(format=2)`},
		{"tesl_schema_stages", `
 stage_id text primary key,
 descriptor bytea not null,
 descriptor_hash text not null,
 introduced_version integer not null check(introduced_version>=2),
 physical_hash text not null,
 source_abi text not null,
 source_snapshot text not null,
 table_name text not null,
 index_name text not null unique,
 job_id text not null unique,
 state text not null check(state in ('pending','promoting','blocked_duplicates','enforced','cancelled')),
 check(pg_catalog.encode(pg_catalog.sha256(descriptor),'hex')=descriptor_hash)`},
	}
}

func pgStageControlFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		// Return only immediate children, after validating the ENTIRE framed
		// tree. Atom contents are opaque bytes: embedded/nested descriptors
		// cannot become members of the physical plan's final stage-list node.
		{"tesl_stage_canonical_children", "doc bytea", "bytea[]", "immutable", `
declare size integer; pos integer:=0; start_pos integer; count_bytes integer; digit integer; kind integer;
 depth integer:=1; pending integer[]:=array[1]; nodes integer:=0; child_start integer:=-1;
 result bytea[]:=array[]::bytea[];
begin
 size:=pg_catalog.octet_length(doc);
 if doc is null or size<3 or size>67108864 then raise exception 'tesl: canonical stage tree size exceeds budget'; end if;
 doc:=doc||''::bytea;
 if pg_catalog.get_byte(doc,0)<>108 then raise exception 'tesl: canonical stage sequence required'; end if;
 loop
  if pos>=size or depth>513 then raise exception 'tesl: canonical stage tree is truncated or too deep'; end if;
  nodes:=nodes+1;
  if nodes>1000000 then raise exception 'tesl: canonical stage tree node budget exceeded'; end if;
  if depth=2 then child_start:=pos; end if;
  pending[depth]:=pending[depth]-1;
  kind:=pg_catalog.get_byte(doc,pos);pos:=pos+1;
  if kind not in (108,115) then raise exception 'tesl: invalid canonical stage node tag'; end if;
  start_pos:=pos;count_bytes:=0;
  while pos<size loop
   digit:=pg_catalog.get_byte(doc,pos);exit when digit=58;
   if digit<48 or digit>57 or pos-start_pos>=8 or (pos>start_pos and pg_catalog.get_byte(doc,start_pos)=48) then
    raise exception 'tesl: noncanonical stage node length'; end if;
   count_bytes:=count_bytes*10+digit-48;pos:=pos+1;
  end loop;
  if pos=start_pos or pos>=size then raise exception 'tesl: truncated canonical stage length'; end if;
  pos:=pos+1;
  if kind=115 then
   if count_bytes>size-pos then raise exception 'tesl: truncated canonical stage atom'; end if;
   pos:=pos+count_bytes;
  elsif count_bytes>0 then
   if count_bytes>1000000-nodes or count_bytes>(size-pos)/3 then raise exception 'tesl: oversized canonical stage list'; end if;
   depth:=depth+1;
   if depth>513 then raise exception 'tesl: canonical stage tree depth exceeded'; end if;
   pending[depth]:=count_bytes;
  end if;
  while depth>1 and pending[depth]=0 loop depth:=depth-1; end loop;
  if child_start>=0 and depth<=2 then
   result:=pg_catalog.array_append(result,pg_catalog.substring(doc,child_start+1,pos-child_start));child_start:=-1;
  end if;
  exit when depth=1 and pending[1]=0;
 end loop;
 if pos<>size then raise exception 'tesl: trailing canonical stage bytes'; end if;
 return result;
end`},
		{"tesl_register_stage_preparation",
			"stage text, doc bytea, snapshot text, v integer, job text, physical text, tbl text, idx text", "void", "volatile", `
declare p ` + ns + `tesl_row_physical%rowtype; recorded ` + ns + `tesl_schema_stages%rowtype;
 linked ` + ns + `tesl_schema_index%rowtype; envelope bytea[]; body bytea[]; stages bytea[]; descriptor_fields bytea[];
begin
 if stage is null or stage !~ '^[0-9a-f]{64}$' or doc is null or snapshot is null or snapshot !~ '^[0-9a-f]{64}$' or
 v is null or v<2 or job is null or physical is null or tbl is null or idx is null or
  not exists(select 1 from ` + ns + `tesl_schema_stage_protocol where id=1 and format=2) or
 not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1) then
 raise exception 'tesl: invalid stage preparation identity'; end if;
 select * into p from ` + ns + `tesl_row_physical where version=v and contract_hash=physical and epoch_preserving for share;
 if not found then raise exception 'tesl: stage preparation lacks its protected physical plan'; end if;
 select j.* into linked from ` + ns + `tesl_schema_index j
 join ` + ns + `tesl_schema_expansion_objects o on o.version=j.version and o.ordinal=j.ordinal and o.operation_hash=j.id
 join ` + ns + `tesl_schema_expansions x on x.version=j.version and x.artefact_hash=p.contract_hash and x.source_abi=p.compiler_abi
 where j.id=job and j.version=v and j.table_name=tbl and j.index_name=idx and not j.is_unique
 and j.id=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('tesl-migration-object-v1','UTF8')||pg_catalog.decode(p.contract_hash,'hex')||pg_catalog.int4send(j.ordinal)),'hex')
 for share of j;
 if not found then
 raise exception 'tesl: stage preparation lacks exact registered nonunique job'; end if;
 if pg_catalog.convert_to(physical,'UTF8')<>pg_catalog.convert_to(p.contract_hash,'UTF8') or
 pg_catalog.convert_to(job,'UTF8')<>pg_catalog.convert_to(linked.id,'UTF8') then
 raise exception 'tesl: stage preparation job/physical identity bytes differ'; end if;
 -- Retain the header's lexical checks, but do not use its six-atom
 -- projection as authorization for any descriptor below that header.
 if (` + ns + `tesl_row_physical_source_header(p.contract)->>'schema') is distinct from snapshot then
 raise exception 'tesl: stage preparation source snapshot differs from protected physical source'; end if;
 envelope:=` + ns + `tesl_stage_canonical_children(p.contract);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or
 envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s9:migration','UTF8') then
 raise exception 'tesl: stage preparation requires a canonical migration document'; end if;
 body:=` + ns + `tesl_stage_canonical_children(envelope[4]);
 if pg_catalog.cardinality(body)<>9 or body[1]<>pg_catalog.convert_to('s33:tesl-retained-physical-version-v8','UTF8') or
 body[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8')) or
 body[5]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(snapshot,'UTF8')) or body[8]<>pg_catalog.convert_to('l0:','UTF8') then
 raise exception 'tesl: stage preparation requires its exact additive v8 physical source'; end if;
 stages:=` + ns + `tesl_stage_canonical_children(body[9]);
 if pg_catalog.array_position(stages,doc) is null then
 raise exception 'tesl: stage descriptor is not a direct member of protected physical source'; end if;
 descriptor_fields:=` + ns + `tesl_stage_canonical_children(doc);
 if pg_catalog.cardinality(descriptor_fields)<>10 or descriptor_fields[1]<>pg_catalog.convert_to('s28:staged-unique-preparation-v1','UTF8') then
 raise exception 'tesl: unsupported protected stage descriptor'; end if;
 if descriptor_fields[2]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(stage,'UTF8')) or
 descriptor_fields[6]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(tbl,'UTF8')) or
 descriptor_fields[10]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(idx,'UTF8')) or
 descriptor_fields[6]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(linked.table_name,'UTF8')) or
 descriptor_fields[10]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(linked.index_name,'UTF8')) or
 pg_catalog.array_ndims(linked.key_columns) is distinct from 1 or pg_catalog.array_lower(linked.key_columns,1) is distinct from 1 or
 pg_catalog.cardinality(linked.key_columns)<>1 or linked.key_columns[1] is null or
 descriptor_fields[7]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(linked.key_columns[1],'UTF8')) then
 raise exception 'tesl: protected stage identity/table/index/key differs from registered job'; end if;
 insert into ` + ns + `tesl_schema_stages values(stage,doc,pg_catalog.encode(pg_catalog.sha256(doc),'hex'),v,p.contract_hash,p.compiler_abi,snapshot,linked.table_name,linked.index_name,linked.id,'pending') on conflict(stage_id) do nothing;
 select * into recorded from ` + ns + `tesl_schema_stages where stage_id=stage;
 if recorded.descriptor is distinct from doc or recorded.introduced_version is distinct from v or recorded.physical_hash is distinct from physical or
 recorded.source_abi is distinct from p.compiler_abi or recorded.source_snapshot is distinct from snapshot or recorded.table_name is distinct from tbl or recorded.index_name is distinct from idx or recorded.job_id is distinct from job or recorded.state<>'pending' then
 raise exception 'tesl: immutable stage preparation differs'; end if;
end`}}
}

func pgRegisterStagePreparation(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, index pgRowConcurrentIndex, ordinal int) error {
	if err := pgVerifyStageTextDefault(ctx, tx, b.target.stages); err != nil {
		return err
	}
	for _, stage := range b.target.stages {
		if stage.index != index.index.Name {
			continue
		}
		_, err := tx.Exec(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_register_stage_preparation"}.Sanitize()+"($1,$2,$3,$4,$5,$6,$7,$8)",
			stage.id, []byte(stage.descriptor), b.target.schemaSnapshotHash, b.target.version, pgMigrationObjectHash(b.target.hash, ordinal), b.target.hash, stage.table, stage.index)
		return err
	}
	return nil
}

func pgVerifyStageRecords(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, forward *pgRowForwardManifest, jobs []pgMigrationIndexJob) error {
	if b.target != nil {
		if err := pgVerifyStageTextDefault(ctx, tx, b.target.stages); err != nil {
			return err
		}
	}
	var format int
	if err := tx.QueryRow(ctx, "select format from "+pgx.Identifier{b.history.Namespace, "tesl_schema_stage_protocol"}.Sanitize()+" where id=1").Scan(&format); err != nil {
		return err
	}
	if format != 2 {
		return fmt.Errorf("unsupported stage control extension")
	}
	type expectation struct {
		stage                        pgStagePreparation
		version                      int
		physical, abi, snapshot, job string
	}
	expected := map[string]expectation{}
	for manifest := forward; manifest != nil; manifest = manifest.previous {
		if err := pgVerifyStageTextDefault(ctx, tx, manifest.plan.stages); err != nil {
			return err
		}
		for ordinal, operation := range manifest.operations {
			if operation.index == nil {
				continue
			}
			job := pgMigrationObjectHash(manifest.plan.hash, ordinal)
			if !slices.ContainsFunc(jobs, func(j pgMigrationIndexJob) bool { return j.ID == job }) {
				continue
			}
			for _, stage := range manifest.plan.stages {
				if stage.index != operation.index.index.Name {
					continue
				}
				if _, exists := expected[stage.id]; exists {
					return fmt.Errorf("stage registered more than once")
				}
				expected[stage.id] = expectation{stage, manifest.plan.version, manifest.plan.hash, manifest.creatorABI, manifest.plan.schemaSnapshotHash, job}
			}
		}
	}
	authorities, err := pgStageIndexAuthorities(ctx, tx, b.history.Namespace)
	if err != nil {
		return err
	}
	states := map[string]string{}
	for _, a := range authorities {
		states[a.guard.preparation.id] = a.state
	}
	cancellations, err := pgStageCancellationAuthorities(ctx, tx, b.history.Namespace)
	if err != nil {
		return err
	}
	for _, c := range cancellations {
		states[c.stage.id] = "cancelled"
	}
	rows, err := tx.Query(ctx, "select stage_id,descriptor,descriptor_hash,introduced_version,physical_hash,source_abi,source_snapshot,table_name,index_name,job_id,state from "+pgx.Identifier{b.history.Namespace, "tesl_schema_stages"}.Sanitize())
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, digest, physical, abi, snapshot, table, index, job, state string
		var descriptor []byte
		var version int
		if err := rows.Scan(&id, &descriptor, &digest, &version, &physical, &abi, &snapshot, &table, &index, &job, &state); err != nil {
			return err
		}
		want, ok := expected[id]
		wantState := states[id]
		if wantState == "" {
			wantState = "pending"
		}
		if !ok || string(descriptor) != want.stage.descriptor || digest != fmt.Sprintf("%x", sha256.Sum256(descriptor)) || version != want.version || physical != want.physical || abi != want.abi || snapshot != want.snapshot || table != want.stage.table || index != want.stage.index || job != want.job || state != wantState {
			return fmt.Errorf("protected stage differs from complete immutable source/index intent")
		}
		delete(expected, id)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(expected) != 0 {
		return fmt.Errorf("registered stage index lacks its protected pending record")
	}
	if _, err := tx.Exec(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_stage_guards_ready"}.Sanitize()+"(current) from "+pgx.Identifier{b.history.Namespace, "tesl_schema_state"}.Sanitize()+" where id=1"); err != nil {
		return err
	}
	return nil
}

// Full source and physical descriptors are compared byte-for-byte. No supplied
// digest or index name substitutes for this compiler-linked inventory.
func pgStageSourceMatches(plan *pgRowPhysicalPlan, storage pgRowCanonical) error {
	stages, err := pgStagesFromStorage(storage)
	if err != nil {
		return err
	}
	for _, guard := range plan.stageGuards {
		if err := pgCheckGuardSource(plan, storage, guard); err != nil {
			return err
		}
		stages = append(stages, guard.preparation)
	}
	for _, guard := range plan.stageReliance {
		if err := pgCheckGuardSource(plan, storage, guard); err != nil {
			return err
		}
		stages = append(stages, guard.preparation)
	}
	for _, s := range plan.stageCancellations {
		if err := pgCheckGuardSource(plan, storage, pgStageGuard{preparation: s}); err != nil {
			return err
		}
		stages = append(stages, s)
	}
	slices.SortFunc(stages, func(a, b pgStagePreparation) int { return strings.Compare(a.id, b.id) })
	if !slices.Equal(stages, plan.stages) {
		return fmt.Errorf("stage physical inventory differs from complete compiled source")
	}
	return nil
}

// Used by source checking to decode the semantic entity identity without trusting
// an index name. The stored identity is a canonical byte string, not SQL.
func pgStageEntityIdentity(stage pgStagePreparation, semantic pgRowCanonical, family string) bool {
	identity, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(semantic.children[1].value)))
	ref := pgRowTypeReference(family, stage.entity)
	return err == nil && identity.list(2) && identity.children[0].isAtom("stored-entity-location") && pgRowCanonicalEqual(identity.children[1], ref.children[2])
}

func pgCheckStageSource(r *pgMigrationWireReader, schema, storage pgRowCanonical, family, abi, compatibility string) {
	if r.err != nil {
		return
	}
	stages, err := pgStagesFromStorage(storage)
	if err != nil {
		r.fail(err.Error())
		return
	}
	_, definitions := pgRowClosure(r, schema, abi, compatibility)
	declared := map[string]bool{}
	for _, definition := range definitions {
		if !definition.list(6) || !definition.children[0].isAtom("entity") || definition.children[5].atom {
			continue
		}
		for _, index := range definition.children[5].children {
			if index.list(6) && index.children[0].isAtom("staging-unique-index-v1") && index.children[1].list(1) {
				declared[pgRowEncode(definition.children[1])+":"+index.children[1].children[0].value] = true
			}
		}
	}
	for _, stage := range stages {
		entry, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(stage.descriptor)))
		if err != nil {
			r.fail(err.Error())
			return
		}
		semantic := entry.children[2]
		ref := pgRowTypeReference(family, stage.entity)
		key := pgRowEncode(ref) + ":" + stage.field
		body, ok := definitions[pgRowEncode(ref)]
		if !ok || !body.list(6) || !declared[key] || !pgStageEntityIdentity(stage, semantic, family) {
			r.fail("stage is not declared by its exact source entity")
			return
		}
		delete(declared, key)
		stored := semantic.children[4]
		if !stored.list(3) || !stored.children[2].list(3) || !stored.children[2].children[0].isAtom("stored-field") {
			r.fail("stage lacks complete typed field contract")
			return
		}
		fieldContract := stored.children[2].children[1]
		if stage.scalar == "text" && (!fieldContract.list(5) || !pgStageBuiltinText(fieldContract.children[2], stage.nullable)) {
			r.fail("stage TEXT requires exact builtin String or Maybe String source identity")
			return
		}
		var normalize func(pgRowCanonical) pgRowCanonical
		normalize = func(node pgRowCanonical) pgRowCanonical {
			if node.list(2) && node.children[0].isAtom("local") {
				i, err := strconv.Atoi(node.children[1].value)
				if err != nil || i < 0 || i >= len(body.children[4].children) {
					r.fail("stage field subject differs")
					return node
				}
				return pgRowList(pgRowAtom("field-subject"), body.children[4].children[i].children[1])
			}
			if node.atom {
				return node
			}
			children := make([]pgRowCanonical, len(node.children))
			for i, child := range node.children {
				children[i] = normalize(child)
			}
			return pgRowList(children...)
		}
		found := false
		for _, field := range body.children[4].children {
			if field.list(5) && field.children[1].isAtom(stage.field) && pgRowCanonicalEqual(normalize(field), fieldContract) {
				found = true
			}
		}
		if !found {
			r.fail("stage typed field differs from sealed schema")
			return
		}
		compatibleStoredValue := stored.children[0].isAtom("stored-value-semantics") && stored.children[1].isAtom(compatibility)
		sameCompiler := stored.children[0].isAtom("compiler-semantics") && stored.children[1].isAtom(abi)
		if !compatibleStoredValue && !sameCompiler {
			r.fail("stage field semantics identity differs")
			return
		}
		closure := stored.children[2].children[2]
		if !closure.list(3) || !closure.children[0].isAtom("closure") || closure.children[1].atom || closure.children[2].atom {
			r.fail("stage dependency closure is malformed")
			return
		}
		dependencies := map[string]bool{}
		last := ""
		for _, dependency := range closure.children[2].children {
			encoded := pgRowEncode(dependency)
			if !dependency.list(2) || encoded <= last {
				r.fail("stage dependency definitions are not canonical")
				return
			}
			last = encoded
			key := pgRowEncode(dependency.children[0])
			original, exists := definitions[key]
			if !exists || dependencies[key] || !pgRowCanonicalEqual(original, dependency.children[1]) {
				r.fail("stage dependency differs from sealed schema")
				return
			}
			dependencies[key] = true
		}
		last = ""
		for _, root := range closure.children[1].children {
			key := pgRowEncode(root)
			if key <= last {
				r.fail("stage dependency roots are not canonical")
				return
			}
			last = key
		}
		if err := pgStageDependencyClosure(fieldContract, closure, definitions, dependencies); err != nil {
			r.fail(err.Error())
			return
		}
	}
	if len(declared) != 0 {
		r.fail("source storage omitted a declared stage")
	}
}

// Mirror the compiler's finite dependency traversal over the complete sealed
// schema, including private predicate producers and codec reverse edges. A
// same-shaped field with a caller-trimmed helper closure is not the same stage.
func pgStageDependencyClosure(field, closure pgRowCanonical, definitions map[string]pgRowCanonical, provided map[string]bool) error {
	refs := func(root pgRowCanonical) map[string]pgRowCanonical {
		result := map[string]pgRowCanonical{}
		var visit func(pgRowCanonical)
		visit = func(n pgRowCanonical) {
			if n.list(3) && n.children[0].isAtom("reference") {
				result[pgRowEncode(n)] = n
				return
			}
			for _, child := range n.children {
				visit(child)
			}
		}
		visit(root)
		return result
	}
	roots := refs(field)
	if len(roots) != len(closure.children[1].children) {
		return fmt.Errorf("stage field dependency roots are incomplete")
	}
	for _, root := range closure.children[1].children {
		if _, ok := roots[pgRowEncode(root)]; !ok {
			return fmt.Errorf("stage field dependency root differs")
		}
	}
	aliases := map[string]string{}
	owners := map[string][]string{}
	for key, body := range definitions {
		aliases[key] = key
		if body.atom || len(body.children) < 2 {
			continue
		}
		ref := body.children[1]
		if !ref.list(3) {
			continue
		}
		switch body.children[0].value {
		case "newtype", "record-declaration", "entity":
			alias := pgRowList(ref.children[0], pgRowAtom("value"), ref.children[2])
			aliases[pgRowEncode(alias)] = key
		case "adt":
			if body.list(4) {
				for _, variant := range body.children[3].children {
					if variant.list(3) {
						aliases[pgRowEncode(variant.children[1])] = key
					}
				}
			}
		case "function":
			if len(body.children) > 2 && (body.children[2].isAtom("check") || body.children[2].isAtom("establish")) {
				for dependency, ref := range refs(body) {
					if ref.children[1].isAtom("predicate") {
						owners[dependency] = append(owners[dependency], key)
					}
				}
			}
		case "codec":
			if len(body.children) > 2 {
				target := pgRowEncode(body.children[2])
				owners[target] = append(owners[target], key)
			}
		}
	}
	reached := map[string]bool{}
	var visit func(string, pgRowCanonical) error
	visit = func(key string, ref pgRowCanonical) error {
		primitive := ref.list(3) && ref.children[2].list(2) && ref.children[2].children[0].isAtom("primitive")
		if !primitive {
			owner, ok := aliases[key]
			if !ok {
				return fmt.Errorf("stage dependency has no source definition")
			}
			if !reached[owner] {
				reached[owner] = true
				for key, ref := range refs(definitions[owner]) {
					if err := visit(key, ref); err != nil {
						return err
					}
				}
			}
		}
		for _, owner := range owners[key] {
			if reached[owner] {
				continue
			}
			body := definitions[owner]
			if err := visit(owner, body.children[1]); err != nil {
				return err
			}
		}
		return nil
	}
	for key, ref := range roots {
		if err := visit(key, ref); err != nil {
			return err
		}
	}
	if len(reached) != len(provided) {
		return fmt.Errorf("stage dependency closure omits private source definitions")
	}
	for key := range reached {
		if !provided[key] {
			return fmt.Errorf("stage dependency closure differs from complete source reachability")
		}
	}
	return nil
}
