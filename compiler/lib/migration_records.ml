(* Per-revision history records: the values every compiled history artifact
   publishes for one completed revision, independent of the Go names chosen for
   it.

   A complete build publishes, for every schema version, its schema and storage
   contracts and its entity generations; for every transforming binding, its
   field mapping and transform contract; the retained physical contract of every
   version; every reviewed Contract; and every queue version. Computing these
   from V1 needs the whole checked history. Once a revision is completed and
   sealed, its records never change, so Start stores them in that revision's
   checkpoint (Migration_checkpoint) and later builds splice them instead of
   re-deriving the prefix.

   [of_history] is the only producer: a full build renders the records it
   computes from its complete fold, and a resumed build renders stored records
   for the checkpointed prefix plus records computed for the later revisions,
   through the same renderers. A full-history build recomputes every stored
   record and refuses a difference.

   Only bindings without reverse writes, legacy writes and nominal conversions
   are recorded (the same subset checkpoints carry); [of_history] returns None
   otherwise and builds then fold from V1. *)
module C = Migration_canonical
module RH = Migration_row_history
module S = Migration_storage
module I = Migration_inventory
module R = Migration_transform_rules
module T = Migration_transform
module L = Migration_transform_link
module RS = Migration_retained_storage
module K = Migration_retained_storage_canonical

type column = {field:string;column:string;scalar:string;nullable:bool;primary_key:bool}
type entity = {identity:string;entity_name:string;table:string;generation:int;
  type_contract:string;type_hash:string;columns:column list}
type version = {version:int;schema_contract:string;schema_hash:string;
  storage_contract:string;storage_hash:string;entities:entity list}
type field = {target:string;kind:string;source:string option;constant:string option}
type transform = {migration_version:int;previous:entity;current:entity;mode:string;row_change:bool;
  from_schema:string;to_schema:string;from_storage:string;to_storage:string;fields:field list;
  transform_contract:string;transform_hash:string;
  (* The entity the checked mapping targets (migration-aware access). *)
  access_entity:string;
  (* The checked row callback of a Migrate binding: owning module and function. *)
  callback:(string * string) option}
type fixture = {fixture_owner:string;fixture_name:string;fixture_identity:string;optional:bool}
type fixture_row = {fixtures:fixture list;row_callback:(string * string * string) option;fixture_row_change:bool}
(* The fixtures of one transforming migration, rows in checked order. *)
type fixture_transform = {root:string;fixture_version:int;rows:fixture_row list}
type physical = {physical_version:int;physical_contract:string;physical_hash:string}
type contract = {contract_version:int;encoded:string;digest:string;settled:string;settled_hash:string}
type queue_payload = {job:string;contract:string;contract_hash:string}
type queue_contract = {queue:string;payloads:queue_payload list}
type queue_version = {version:int;storage_snapshot_hash:string;schema_snapshot_hash:string;
  source_seal_inventory:string;contracts:queue_contract list}
type t = {versions:version list;transforms:transform list;fixture_transforms:fixture_transform list;
  physical:physical list;contracts:contract list;queue_versions:queue_version list}

let empty = {versions=[];transforms=[];fixture_transforms=[];physical=[];contracts=[];queue_versions=[]}
let append a b = {versions=a.versions @ b.versions;transforms=a.transforms @ b.transforms;
  fixture_transforms=a.fixture_transforms @ b.fixture_transforms;physical=a.physical @ b.physical;
  contracts=a.contracts @ b.contracts;queue_versions=a.queue_versions @ b.queue_versions}
let concat ts = {versions=List.concat_map (fun t -> t.versions) ts;transforms=List.concat_map (fun t -> t.transforms) ts;
  fixture_transforms=List.concat_map (fun t -> t.fixture_transforms) ts;physical=List.concat_map (fun t -> t.physical) ts;
  contracts=List.concat_map (fun t -> t.contracts) ts;queue_versions=List.concat_map (fun t -> t.queue_versions) ts}

let column (c:S.column) = {field=c.field.name;column=c.name;scalar=S.scalar_name c.scalar;nullable=c.nullable;primary_key=c.primary_key}
let entity (e:RH.entity) =
  let type_contract,type_hash=RH.contract C.Contract e.type_contract in
  {identity=e.identity;entity_name=e.table.entity.entity_name;table=e.table.name;generation=e.generation;
   type_contract;type_hash;columns=List.map column e.table.columns}
let version (v:RH.version) =
  let schema_contract,schema_hash=RH.contract C.Snapshot (I.snapshot v.schema) in
  let storage_contract,storage_hash=RH.contract C.Migration (S.node v.storage) in
  {version=v.version;schema_contract;schema_hash;storage_contract;storage_hash;entities=List.map entity v.entities}

let field mapping =
  match mapping with
  | R.Copy {previous;current} -> {target=current.name;kind="copy";source=Some previous.name;constant=None}
  | R.Renamed {previous;current} -> {target=current.name;kind="rename";source=Some previous.name;constant=None}
  | R.Empty_optional current -> {target=current.name;kind="empty-optional";source=None;constant=None}
  | R.Constant (current,value) -> {target=current.name;kind="default";source=None;constant=Some (RH.hex (C.encode value))}
  | R.Retyped {previous;current} -> {target=current.name;kind="retype";source=Some previous.name;constant=None}
  | R.Revalidated {previous;current;_} -> {target=current.name;kind="revalidate";source=Some previous.name;constant=None}
  | R.Computed current -> {target=current.name;kind="computed";source=None;constant=None}

(* A binding is recorded only when its emission needs nothing beyond these
   values: no reverse or legacy writes and no nominal conversion certificate. *)
let recordable b =
  let row=RH.row b in
  let checked=L.checked_transform (RH.link b) in
  row.writebacks=[] && row.legacies=[] && T.nominal_mappings checked row=[] &&
  Migration_proof_context.nominal_transports (T.proof_context checked)=[]

(* Whether the records of [low..high] may be stored in a checkpoint: a later
   build emits a stored binding from these values alone, so it must need
   nothing else. *)
let storable ~low ~high rows =
  RH.retirements rows=[] &&
  List.for_all (fun b -> let v=RH.migration_version b in v<low || v>high || recordable b) (RH.bindings rows)

let transform rows b =
  let row=RH.row b in
  let version=RH.migration_version b in
  let find n=List.find (fun (v:RH.version) -> v.version=n) (RH.versions rows) in
  let from=find (version-1) and target=find version in
  let contract,hash=RH.contract C.Migration (L.semantic (RH.link b)) in
  {migration_version=version;previous=entity (RH.previous b);current=entity (RH.current b);
   mode=(match row.mapping.mode with R.Migrate -> "migrate" | R.Derived -> "derived");row_change=row.row_change;
   from_schema=C.digest C.Snapshot (I.snapshot from.schema);to_schema=C.digest C.Snapshot (I.snapshot target.schema);
   from_storage=S.digest from.storage;to_storage=S.digest target.storage;
   fields=List.map field row.mapping.values;
   transform_contract=contract;transform_hash=hash;access_entity=row.mapping.current.entity_name;
   callback=Option.map (fun (f:T.function_binding) -> f.owner.module_name,f.declaration.name) row.function_binding}

let fixture_transform version checked =
  let reference (f:T.function_binding) = f.owner.module_name,f.declaration.name,f.identity in
  {root=(T.root checked).module_name;fixture_version=version;
   rows=List.map (fun (row:T.row) ->
     {fixtures=List.map (fun (f:T.function_binding) ->
        {fixture_owner=f.owner.module_name;fixture_name=f.declaration.name;fixture_identity=f.identity;
         optional=T.fixture_optional checked row f}) row.fixtures;
      row_callback=Option.map reference row.function_binding;fixture_row_change=row.row_change}) (T.rows checked)}

let physical ~family ~namespace plan (v:RS.version) =
  let contract,hash=RH.contract C.Migration (K.version_node ~family ~namespace plan v) in
  {physical_version=v.version;physical_contract=contract;physical_hash=hash}

(* What the Contract prerequisite reads from a checked Contract
   (Migration_contract.view). *)
type contract_view = {view_version:int;view_family:string;view_namespace:string;
  view_window:RS.version;view_settled:RS.version}

(* Records of a checked history for versions/bindings/contracts within
   [low..high]; [queue_versions] are supplied by the caller (Migration_program
   owns their derivation). *)
let of_history ~family ~namespace ~low ~high ~rows ~plan ~contracts ~queue_versions =
  let within v = v>=low && v<=high in
  let bindings=List.filter (fun b -> within (RH.migration_version b)) (RH.bindings rows) in
  let checked=List.fold_left (fun found b ->
    let checked=L.checked_transform (RH.link b) in
    if List.exists (fun (_,old) -> T.root old=T.root checked) found then found
    else found @ [RH.migration_version b,checked]) [] bindings in
  {versions=List.filter (fun (v:RH.version) -> within v.version) (RH.versions rows) |> List.map version;
   transforms=List.map (transform rows) bindings;
   fixture_transforms=List.filter_map (fun (version,checked) ->
     if List.exists (fun (row:T.row) -> row.fixtures<>[]) (T.rows checked) then Some (fixture_transform version checked) else None) checked;
   physical=List.filter (fun (v:RS.version) -> within v.version) (RS.versions plan) |> List.map (physical ~family ~namespace plan);
   contracts=List.filter (fun c -> within c.contract_version) contracts;
   queue_versions=List.filter (fun (q:queue_version) -> within q.version) queue_versions}

exception Storage_invalid of Migration_sparse.error list
(* Queue versions of [schemas]: each version's queue payload contracts and the
   completeness of the queue inventory its recorded source seals assert. *)
module D = Migration_declaration
module H = Migration_history_sources
let payload_contract node =
 let canonical = Migration_canonical.(encode (document Contract (Seq [Bytes "queue-payload-v1";node]))) in
 Migration_row_history.hex canonical,Migration_hash.digest canonical
let queue_versions schemas edges =
 List.map (fun (schema:H.schema) ->
  let inventory=H.inventory schema in
  let seals=List.concat_map (fun edge -> match D.source_seals edge with
    | None -> [] | Some header ->
      let before,after=Migration_header.seals header in
      List.filter_map (fun (version,seal) -> if version=schema.version then Some seal else None)
        [D.version edge-1,before;D.version edge,after]) edges in
  let source_seal_inventory = match seals with
   | [] -> "unrecorded"
   | _ when List.for_all Migration_seal.queue_inventory_complete seals -> "complete"
   | _ -> "unknown" in
  let contracts=List.map (fun (q:Migration_inventory.queue_contract) ->
    {queue=Migration_queue.wire_identity inventory q.queue_name;
     payloads=List.map (fun (p:Migration_inventory.queue_payload) ->
       let contract,contract_hash=payload_contract p.payload_contract in
       {job=Migration_queue.wire_identity inventory p.payload_name;contract;contract_hash}) q.payloads})
      (Migration_inventory.queue_contracts inventory) in
  {version=schema.version;source_seal_inventory;contracts;
   storage_snapshot_hash=Migration_storage.digest ((match Migration_storage.describe inventory with Ok storage -> storage | Error errors -> raise (Storage_invalid errors)));
   schema_snapshot_hash=Migration_canonical.digest Migration_canonical.Snapshot (Migration_inventory.snapshot inventory)}) schemas

(* Canonical encoding (Migration_canonical) for checkpoint storage. Published
   contracts are lowercase hexadecimal of canonical bytes; a checkpoint stores
   the bytes themselves, half the size, and decoding restores the exact text. *)
let unhex text =
  let length = String.length text in
  if length mod 2 <> 0 then invalid_arg "odd hexadecimal contract";
  let digit c = match c with
    | '0'..'9' -> Char.code c - 48 | 'a'..'f' -> Char.code c - 87
    | _ -> invalid_arg "contract is not lowercase hexadecimal" in
  let out = Bytes.create (length / 2) in
  for i = 0 to length / 2 - 1 do
    Bytes.unsafe_set out i (Char.unsafe_chr (digit (String.unsafe_get text (2*i)) * 16 + digit (String.unsafe_get text (2*i+1))))
  done;
  Bytes.unsafe_to_string out
let atom s = C.Bytes s
let raw s = C.Bytes (unhex s)
let int n = atom (string_of_int n)
let bool b = atom (if b then "1" else "0")
let opt f = function None -> C.Seq [] | Some x -> C.Seq [f x]
let list f xs = C.Seq (List.map f xs)
let encode_column c = C.Seq [atom c.field;atom c.column;atom c.scalar;bool c.nullable;bool c.primary_key]
let encode_entity e = C.Seq [atom e.identity;atom e.entity_name;atom e.table;int e.generation;
  raw e.type_contract;atom e.type_hash;list encode_column e.columns]
let encode_version (v:version) = C.Seq [int v.version;raw v.schema_contract;atom v.schema_hash;
  raw v.storage_contract;atom v.storage_hash;list encode_entity v.entities]
let encode_field f = C.Seq [atom f.target;atom f.kind;opt atom f.source;opt atom f.constant]
let encode_transform x = C.Seq [int x.migration_version;encode_entity x.previous;encode_entity x.current;
  atom x.mode;bool x.row_change;atom x.from_schema;atom x.to_schema;atom x.from_storage;atom x.to_storage;
  list encode_field x.fields;raw x.transform_contract;atom x.transform_hash;atom x.access_entity;
  opt (fun (owner,name) -> C.Seq [atom owner;atom name]) x.callback]
let encode_fixture f = C.Seq [atom f.fixture_owner;atom f.fixture_name;atom f.fixture_identity;bool f.optional]
let encode_fixture_row r = C.Seq [list encode_fixture r.fixtures;
  opt (fun (owner,name,identity) -> C.Seq [atom owner;atom name;atom identity]) r.row_callback;bool r.fixture_row_change]
let encode_fixture_transform x = C.Seq [atom x.root;int x.fixture_version;list encode_fixture_row x.rows]
let encode_physical p = C.Seq [int p.physical_version;raw p.physical_contract;atom p.physical_hash]
let encode_contract c = C.Seq [int c.contract_version;raw c.encoded;atom c.digest;raw c.settled;atom c.settled_hash]
let encode_queue_version (q:queue_version) = C.Seq [int q.version;atom q.storage_snapshot_hash;atom q.schema_snapshot_hash;
  atom q.source_seal_inventory;list (fun c -> C.Seq [atom c.queue;
    list (fun p -> C.Seq [atom p.job;atom p.contract;atom p.contract_hash]) c.payloads]) q.contracts]
let encode t = C.Seq [atom "tesl-history-records-v1";list encode_version t.versions;list encode_transform t.transforms;
  list encode_fixture_transform t.fixture_transforms;list encode_physical t.physical;list encode_contract t.contracts;
  list encode_queue_version t.queue_versions]

let decode node =
  let fail () = invalid_arg "malformed history records" in
  let str = function C.Bytes s -> s | C.Seq _ -> fail () in
  let hex n = RH.hex (str n) in
  let num n = match int_of_string_opt (str n) with Some n -> n | None -> fail () in
  let flag n = match str n with "1" -> true | "0" -> false | _ -> fail () in
  let items f = function C.Seq xs -> List.map f xs | C.Bytes _ -> fail () in
  let option f = function C.Seq [] -> None | C.Seq [x] -> Some (f x) | _ -> fail () in
  let column = function
    | C.Seq [field;column;scalar;nullable;primary_key] ->
      {field=str field;column=str column;scalar=str scalar;nullable=flag nullable;primary_key=flag primary_key}
    | _ -> fail () in
  let entity = function
    | C.Seq [identity;entity_name;table;generation;type_contract;type_hash;columns] ->
      {identity=str identity;entity_name=str entity_name;table=str table;generation=num generation;
       type_contract=hex type_contract;type_hash=str type_hash;columns=items column columns}
    | _ -> fail () in
  let version = function
    | C.Seq [version;schema_contract;schema_hash;storage_contract;storage_hash;entities] ->
      ({version=num version;schema_contract=hex schema_contract;schema_hash=str schema_hash;
        storage_contract=hex storage_contract;storage_hash=str storage_hash;entities=items entity entities}:version)
    | _ -> fail () in
  let field = function
    | C.Seq [target;kind;source;constant] -> {target=str target;kind=str kind;source=option str source;constant=option str constant}
    | _ -> fail () in
  let pair = function C.Seq [a;b] -> str a,str b | _ -> fail () in
  let triple = function C.Seq [a;b;c] -> str a,str b,str c | _ -> fail () in
  let transform = function
    | C.Seq [mv;previous;current;mode;row_change;from_schema;to_schema;from_storage;to_storage;fields;contract;hash;access;callback] ->
      {migration_version=num mv;previous=entity previous;current=entity current;mode=str mode;row_change=flag row_change;
       from_schema=str from_schema;to_schema=str to_schema;from_storage=str from_storage;to_storage=str to_storage;
       fields=items field fields;transform_contract=hex contract;transform_hash=str hash;access_entity=str access;
       callback=option pair callback}
    | _ -> fail () in
  let fixture = function
    | C.Seq [owner;name;identity;optional] ->
      {fixture_owner=str owner;fixture_name=str name;fixture_identity=str identity;optional=flag optional}
    | _ -> fail () in
  let fixture_row = function
    | C.Seq [fixtures;callback;row_change] ->
      {fixtures=items fixture fixtures;row_callback=option triple callback;fixture_row_change=flag row_change}
    | _ -> fail () in
  let fixture_transform = function
    | C.Seq [root;version;rows] -> {root=str root;fixture_version=num version;rows=items fixture_row rows} | _ -> fail () in
  let physical = function
    | C.Seq [v;c;h] -> {physical_version=num v;physical_contract=hex c;physical_hash=str h} | _ -> fail () in
  let contract = function
    | C.Seq [v;e;d;s;h] -> {contract_version=num v;encoded=hex e;digest=str d;settled=hex s;settled_hash=str h}
    | _ -> fail () in
  let payload = function
    | C.Seq [job;contract;hash] -> {job=str job;contract=str contract;contract_hash=str hash} | _ -> fail () in
  let queue_contract = function
    | C.Seq [queue;payloads] -> {queue=str queue;payloads=items payload payloads} | _ -> fail () in
  let queue_version = function
    | C.Seq [v;storage;schema;seal;contracts] ->
      ({version=num v;storage_snapshot_hash=str storage;schema_snapshot_hash=str schema;
        source_seal_inventory=str seal;contracts=items queue_contract contracts}:queue_version)
    | _ -> fail () in
  match node with
  | C.Seq [C.Bytes "tesl-history-records-v1";versions;transforms;fixtures;physicals;contracts;queues] ->
    {versions=items version versions;transforms=items transform transforms;fixture_transforms=items fixture_transform fixtures;
     physical=items physical physicals;contracts=items contract contracts;queue_versions=items queue_version queues}
  | _ -> fail ()

(* JSON renderers shared by every artifact emitter, so a record renders
   identically whether it was computed in this build or read from a
   checkpoint. *)
let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"
let column_json ~quote c =
  Printf.sprintf {|{"field":%s,"name":%s,"type":%s,"nullable":%b,"primaryKey":%b}|}
    (quote c.field) (quote c.column) (quote c.scalar) c.nullable c.primary_key
let version_json ~quote ~go_type (v:version) =
  let entity e =
    let package,name=go_type v.version e in
    Printf.sprintf {|{"entity":%s,"table":%s,"generation":%d,"typeContract":%s,"typeContractHash":%s,"columns":%s,"goTypePackage":%s,"goTypeName":%s}|}
      (quote e.identity) (quote e.table) e.generation (quote e.type_contract) (quote e.type_hash)
      (array (column_json ~quote) e.columns) (quote package) (quote name) in
  Printf.sprintf {|{"version":%d,"schemaContract":%s,"schemaSnapshotHash":%s,"storageContract":%s,"storageSnapshotHash":%s,"entities":%s}|}
    v.version (quote v.schema_contract) (quote v.schema_hash) (quote v.storage_contract) (quote v.storage_hash) (array entity v.entities)
let field_json ~quote f =
  let nullable=Option.fold ~none:"null" ~some:quote in
  let enforcement=if f.kind="revalidate" then ",\"proofEnforcement\":\"runtime-only\"" else "" in
  Printf.sprintf {|{"target":%s,"kind":%s,"source":%s,"constant":%s%s}|}
    (quote f.target) (quote f.kind) (nullable f.source) (nullable f.constant) enforcement
(* [extra] carries the projection and write fields the caller derives from its
   emitted adapters and live flags. *)
let transform_json ~quote ~extra x =
  let fields=List.sort compare (List.map (fun f -> f.target,field_json ~quote f) x.fields) in
  Printf.sprintf {|{"migrationVersion":%d,"entity":%s,"table":%s,"mode":%s,"previousGeneration":%d,"targetGeneration":%d,"fromSchemaSnapshot":%s,"toSchemaSnapshot":%s,"fromStorageSnapshot":%s,"toStorageSnapshot":%s,"fromTypeContractHash":%s,"toTypeContractHash":%s,"sourceSchemaColumns":%s,"targetSchemaColumns":%s,"fieldMapping":%s,"transformContractFormat":"tesl-row-transform-v1","transformContract":%s,"transformContractHash":%s%s}|}
    x.migration_version (quote x.current.identity) (quote x.current.table) (quote x.mode) x.previous.generation x.current.generation
    (quote x.from_schema) (quote x.to_schema) (quote x.from_storage) (quote x.to_storage)
    (quote x.previous.type_hash) (quote x.current.type_hash) (array (column_json ~quote) x.previous.columns)
    (array (column_json ~quote) x.current.columns) (array snd fields)
    (quote x.transform_contract) (quote x.transform_hash) extra
let physical_json ~quote p = Printf.sprintf {|{"contract":%s,"hash":%s}|} (quote p.physical_contract) (quote p.physical_hash)
let contract_json ~quote c =
  Printf.sprintf {|{"contract":%s,"hash":%s,"settled":%s,"settledHash":%s}|}
    (quote c.encoded) (quote c.digest) (quote c.settled) (quote c.settled_hash)
let queue_version_json ~quote (v:queue_version) =
  let payload p=Printf.sprintf {|{"job":%s,"contractFormat":"tesl-queue-payload-v1","contract":%s,"contractHash":%s}|}
    (quote p.job) (quote p.contract) (quote p.contract_hash) in
  let contract q=Printf.sprintf {|{"queue":%s,"payloads":%s}|} (quote q.queue) (array payload q.payloads) in
  Printf.sprintf {|{"version":%d,"storageSnapshotHash":%s,"schemaSnapshotHash":%s,"checkedInventory":"complete","sourceSealInventory":%s,"contracts":%s}|}
    v.version (quote v.storage_snapshot_hash) (quote v.schema_snapshot_hash) (quote v.source_seal_inventory) (array contract v.contracts)

(* Fields the Go row companion lowers for a Derived mapping. *)
type derived = Copy_from of string | Empty_optional | Constant of string * string
let derived f =
  match f.kind,f.source,f.constant with
  | ("copy"|"rename"),Some source,None -> Some (Copy_from source)
  | "empty-optional",None,None -> Some Empty_optional
  | "default",None,Some hex ->
    let bytes=String.init (String.length hex/2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (2*i) 2))) in
    (match C.parse bytes with
     | C.Seq [C.Bytes kind;C.Bytes value] -> Some (Constant (kind,value))
     | _ -> None | exception Invalid_argument _ -> None)
  | _ -> None

(* Application fields a transforming binding exposes to migration-aware access. *)
let access_fields x = List.filter_map (fun f -> match f.kind with
  | "copy" | "rename" | "revalidate" -> Some f.target | _ -> None) x.fields

(* A transforming revision that relies on its predecessor's settled shape needs
   that predecessor's exact checked Contract. Checked for versions in
   [low..high]:
   a resumed build checks its later revisions, and Start checks each revision
   before storing its records. *)
type prerequisite = Missing of string | Plan_errors of Migration_sparse.error list
let prerequisites ~family ~namespace ~low ?(high=max_int) plan contracts =
  RS.versions plan |> List.filter (fun (v:RS.version) -> v.version>=low && v.version<=high) |> List.concat_map (fun (version:RS.version) ->
    match version.requires_contract_version with
    | None -> []
    | Some required ->
      let candidates=List.filter (fun c->c.view_version=required) contracts in
      let missing ()=[Missing (Printf.sprintf "V%d migration-aware queries require the exact checked Contract V%d source for their settled predecessor; generate and retain that Contract before starting the next revision" version.version required)] in
      (* Source approval and runtime completion are independent judgments.
         This binds the immutable source Contract; deployment must still prove
         its protected completion before publishing the next window. *)
      match candidates,List.find_opt (fun (v:RS.version)->v.version=required) (RS.versions plan) with
      | [contract],Some previous when required=version.version-1 && contract.view_family=family && contract.view_namespace=namespace ->
        (match RS.settled_version plan ~version:required with
         | Error errors -> [Plan_errors errors]
         | Ok settled ->
           let window_node=K.version_node ~family ~namespace plan in
           let settled_node=K.settled_node ~family ~namespace plan in
           if window_node contract.view_window=window_node previous && settled_node contract.view_settled=settled_node settled then []
           else missing ())
      | _ -> missing ())
