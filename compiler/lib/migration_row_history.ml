module I = Migration_inventory
module S = Migration_sparse
module D = Migration_declaration
module P = Migration_storage
module T = Migration_transform
module R = Migration_transform_rules
module L = Migration_transform_link
module C = Migration_canonical

type entity = {identity:string;generation:int;table:P.table;type_contract:C.node}
type version = {version:int;schema:I.t;storage:P.t;entities:entity list}
type binding = {version:int;previous:entity;current:entity;link:L.t;row:T.row}
type retirement = {version:int;previous:entity}
type t = {retirements:retirement list;versions:version list;bindings:binding list;links:L.t list;edges:D.t list}
let retirements t = t.retirements
let versions t = t.versions
let bindings t = t.bindings
let declarations t = t.edges
let migration_version (b:binding) = b.version
let previous (b:binding) = b.previous
let current b = b.current
let link b = b.link
let row b = b.row
let hex text =
  let digits="0123456789abcdef" in
  String.init (String.length text*2) (fun i ->
    let byte=Char.code text.[i/2] in digits.[if i mod 2=0 then byte lsr 4 else byte land 15])
let contract domain node =
  let encoded=C.encode (C.document domain node) in hex encoded,Migration_hash.digest encoded
exception Invalid of S.error list
let reject ?(code="MIG016") loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok value -> value | Error errors -> raise (Invalid errors)
let ir = function Ok value -> value | Error (error:Migration_ir.error) -> reject ~code:"MIG013" error.loc error.message
let loc=Location.dummy_loc "<migration-row-history>"
let protect run = try Ok (run ()) with Invalid errors -> Error errors
let next_generation generation = protect (fun () ->
  if generation<1 || generation>=32767 then reject loc "row generation must advance within PostgreSQL positive smallint bounds";
  generation+1)
let same_inventory a b = I.root_module a=I.root_module b && I.compiler_abi a=I.compiler_abi b && I.snapshot a=I.snapshot b
let relative inventory name =
  let prefix=I.root_module inventory ^ "." in
  if not (String.starts_with ~prefix name) then reject loc "entity is outside its checked source snapshot";
  String.sub name (String.length prefix) (String.length name-String.length prefix)
let revalidate t = protect (fun () ->
  List.iter (fun link -> ignore (ir (L.revalidate link))) t.links;
  List.iter(fun edge -> List.iter(fun conversion -> ignore(checked(Migration_queue_transform.with_checked conversion Fun.id)))
    (D.queue_transforms edge))t.edges)
let captured_sources t =
  (List.concat_map (fun link -> T.captured_sources (L.checked_transform link)) t.links @
   List.concat_map(fun edge->List.concat_map Migration_queue_transform.source_texts(D.queue_transforms edge))t.edges)
  |> List.sort_uniq (fun (a,source_a) (b,source_b) -> compare (a.Ast.source_file,source_a) (b.Ast.source_file,source_b))
let validate_adapter_modes t = protect (fun () ->
  List.iter (fun binding -> match binding.row.function_binding with
    | Some _ when binding.row.mapping.mode=R.Migrate -> ()
    | None when binding.row.mapping.mode=R.Derived -> ()
    | _ -> reject binding.current.table.entity.entity_loc
        "row adapter mode differs from its exact checked source binding") t.bindings)
let check_internal ~queue_expansion ~schemas ~edges = protect (fun () ->
  if schemas=[] || List.length edges+1<>List.length schemas then
    reject ~code:"MIG001" loc "row generations require complete source history from V1";
  let first=List.hd schemas in
  let family inventory = match Validation_common.schema_module_parts (I.root_module inventory) with
    | Some (family,_,[]) -> family | _ -> reject loc "row history requires an exact schema root" in
  let family=family first in
  List.iteri (fun i schema ->
    match Validation_common.schema_module_parts (I.root_module schema) with
    | Some (owner,revision,[]) when owner=family &&
        (revision="V" ^ string_of_int (i+1) || revision="VCurrent" && i=List.length schemas-1) -> ()
    | _ -> reject ~code:"MIG001" loc "row history schemas must be a consecutive V1 family ending in its exact target") schemas;
  let rec adjacent expected schemas edges = match schemas,edges with
    | [_],[] -> ()
    | before::(after::_ as rest),edge::later ->
      let old,fresh=S.inventories (D.coverage edge) in
      if D.version edge<>expected || not (same_inventory old before && same_inventory fresh after) then
        reject ~code:"MIG013" loc "row generations require the exact inventories judged by every adjacent declaration";
      adjacent (expected+1) rest later
    | _ -> reject ~code:"MIG001" loc "incomplete row generation history" in
  adjacent 2 schemas edges;
   (match I.check_stage_history schemas with
    | Ok () -> () | Error error -> reject ~code:"MIG030" error.loc error.message);
   let has_stages=List.exists(fun schema->I.staged_indexes schema<>[]) schemas in
   List.iter (fun (stage:I.staged_index) -> reject ~code:"MIG030" stage.stage_loc
     "stage preparation on original V1 is not implemented; introduce the preparatory index on an existing table in a later additive revision") (I.staged_indexes first);
   let rec stage_pairs = function
    | before::(after::_ as rest) ->
      let old_storage=checked(P.describe before) and fresh_storage=checked(P.describe after) in
      let descriptors storage=match P.stage_nodes storage with C.Seq nodes -> nodes | _ -> assert false in
      List.iter (fun node -> match node with
       | C.Seq [_;C.Bytes id;_;_;_;C.Bytes table;C.Bytes column;_;_;C.Bytes index] ->
         (match List.find_opt (function C.Seq (_::C.Bytes old::_) -> old=id | _ -> false) (descriptors old_storage) with
          | Some old when old=node -> ()
          | Some _ -> reject ~code:"MIG030" loc "carried stage must preserve its exact preparatory physical descriptor"
          | None -> match List.find_opt (fun (t:P.table) -> t.name=table) (P.tables old_storage) with
            | Some old when List.exists (fun (c:P.column) -> c.name=column) old.columns &&
                not(List.exists (fun (i:P.index) -> i.name=index) old.indexes) -> ()
            | _ -> reject ~code:"MIG030" loc "stage preparation requires a new nonunique index on an existing table/key")
       | _ -> assert false) (descriptors fresh_storage);
      stage_pairs rest
    | _ -> () in
   if has_stages then stage_pairs schemas;
   if queue_expansion then begin
      List.iter (fun edge ->
        if D.queue_transforms edge<>[] && S.entries(D.coverage edge)<>[] then
          reject ~code:"MIG028" loc (Printf.sprintf
            "V%d changes row entities (%s) and queue payloads (%s) together. Split these into ordered revisions: first the row change with its reviewed Contract, then the queue-payload change with unchanged entities. Run `tesl migrate generate app.tesl --manifest-json` for each revision and generate the row Contract with `tesl migrate contract --version %d app.tesl --manifest-json`. Deploy the latest binary: `app --schema install --worker ROLE --request ROLE` as Installer, then `app --schema catch-up` as Worker; intermediate application images are not required."
            (D.version edge) (String.concat ", " (List.map fst (S.entries(D.coverage edge))))
            (String.concat ", " (List.map (fun conversion -> let queue,job=Migration_queue_transform.queue_job conversion in queue ^ "." ^ job) (D.queue_transforms edge))) (D.version edge))) edges;
     let membership inventory=I.queue_contracts inventory |> List.map(fun q ->
       Migration_queue.wire_identity inventory q.I.queue_name,
       List.map(fun p->Migration_queue.wire_identity inventory p.I.payload_name)q.payloads |> List.sort compare) |> List.sort compare in
      if List.exists(fun schema->membership(List.hd schemas)<>membership schema)schemas then
        reject ~code:"MIG028" loc "queue conversion rollout retains exact queue/job membership; additions or removals require a separate supported edge"
   end;
   if not queue_expansion && List.exists(fun edge -> D.queue_transforms edge<>[])edges then
    reject ~code:"MIG028" loc "checked queue conversions require protected transformation and repair execution before physical planning";
  let generations=Hashtbl.create 16 and relation_owners=Hashtbl.create 16 in
  let describe version schema =
    let storage=checked (P.describe schema) in
    let entities=P.tables storage |> List.map (fun (table:P.table) ->
      let identity=relative schema table.entity.entity_name in
      if List.exists (fun (column:P.column) -> column.name="_tesl_v") table.columns then
        reject table.entity.entity_loc "the permanent row generation marker `_tesl_v` is reserved; a user column cannot claim its physical name";
      (match Hashtbl.find_opt relation_owners table.name with
       | Some owner when owner<>identity -> reject table.entity.entity_loc "row history cannot reuse a retained table for another entity"
       | _ -> Hashtbl.replace relation_owners table.name identity);
      let generation=match Hashtbl.find_opt generations identity with
        | Some value -> value
        | None -> Hashtbl.add generations identity 1;1 in
      let type_contract=ir (I.closure schema [Migration_ir.Type,table.entity.entity_name]) in
      {identity;generation;table;type_contract}) |> List.sort (fun a b -> compare a.identity b.identity) in
    {version;schema;storage;entities} in
  if List.exists (fun (f:I.field_shape) -> f.db_column<>None) (I.field_shapes first) then
    reject ~code:"MIG027" loc "baseline fields cannot claim compiler-owned Retype columns";
  let baseline=describe 1 first in
  let versions=ref [baseline] and bindings=ref [] and links=ref [] and retirements=ref [] in
  let previous=ref baseline in
  List.iter2 (fun schema edge ->
    let mapping=S.entities (D.coverage edge) in
    let removed=List.filter_map (function S.Removed entity -> Some entity | _ -> None) mapping in
    if removed<>[] then begin
      if List.length removed<>1 || List.exists (fun (_,kind) -> kind<>S.Drop) (S.entries (D.coverage edge)) then
        reject loc "table Drop requires exactly one removed entity and unchanged surviving entities";
      if I.stored_entities schema=[] then reject loc "table Drop cannot remove the last entity";
      (* Compare full payload closures, not just job names or SQL carriers. Keep
         every historical descriptor: Contract restamps these unchanged jobs. *)
      let queues inventory = I.queue_contracts inventory |> List.map (fun q ->
        relative inventory q.I.queue_name,
        List.map (fun p -> relative inventory p.I.payload_name,p.payload_contract)
          q.payloads |> List.sort compare) |> List.sort compare in
      if List.exists (fun inventory -> queues inventory<>queues first) schemas then
        reject loc "table Drop requires unchanged historical queue membership and full payload/proof/codec contracts";
      List.iter (fun (entity:I.stored_entity) ->
        let identity=relative (!previous).schema entity.entity_name in
        let old=List.find (fun (e:entity) -> e.identity=identity) (!previous).entities in
        if List.exists (fun (b:binding) -> b.current.identity=identity) !bindings then
          reject entity.entity_loc "table Drop of a previously transformed entity is not supported";
        let born=List.find (fun (v:version) -> List.exists (fun (e:entity) -> e.identity=identity) v.entities) (List.rev !versions) in
        let initial=List.find (fun (e:entity) -> e.identity=identity) born.entities in
        if List.exists (fun (v:version) -> List.exists (fun (e:entity) -> e.identity=identity &&
          List.exists (fun index -> not (List.mem index initial.table.indexes)) e.table.indexes) v.entities) !versions then
          reject entity.entity_loc "table Drop with retained concurrent index jobs requires a checked terminal index lifecycle";
        retirements:={version=D.version edge;previous=old}::!retirements) removed
    end;
    List.iter (function
      | S.Removed _ -> ()
      | S.Added entity ->
        let identity=relative schema entity.entity_name in
        if Hashtbl.mem generations identity then reject entity.entity_loc "row history cannot restart a retained entity generation";
        if Hashtbl.mem relation_owners entity.table_name then reject entity.entity_loc "row history cannot reuse a retained table name"
      | S.Paired pair ->
        if pair.previous.table_name<>pair.current.table_name || pair.previous.primary_key<>pair.current.primary_key then
          reject pair.current.entity_loc "row generations cannot rename tables or primary keys") mapping;
    let checked_link=Option.map (fun transform -> ir (L.link transform)) (D.transforms edge) in
    let rows=Option.fold ~none:[] ~some:(fun link -> T.rows (L.checked_transform link)) checked_link in
    List.iter (fun (identity,kind) -> match kind with
      | S.Reset -> reject loc "row generation metadata does not yet support reset lifecycle operations"
      | S.Drop -> ()
      | S.Transform ->
        let candidates=List.filter (fun (row:T.row) -> row.mapping.identity=identity) rows in
        (match candidates with
         | [_] -> () | _ -> reject loc "every generation advance requires exactly one checked linked entity transformation");
        let current=match Hashtbl.find_opt generations identity with
          | Some generation -> generation
          | None -> reject loc "generation advance references an entity absent from the previous snapshot" in
        Hashtbl.replace generations identity (checked (next_generation current))
      | S.Additive | S.New -> ()) (S.entries (D.coverage edge));
    List.iter (fun (row:T.row) ->
      if List.assoc_opt row.mapping.identity (S.entries (D.coverage edge))<>Some S.Transform then
        reject loc "linked callback has no exact transforming history entry") rows;
    List.iter (fun (field:I.field_shape) -> match field.db_column with
      | None -> ()
      | Some column ->
        let identity=relative schema field.stored_field.entity in
        let old=List.find_opt (fun (e:entity) -> e.identity=identity) (!previous).entities in
        let retained=Option.fold ~none:false ~some:(fun (e:entity) -> List.exists (fun (c:P.column) ->
          c.field.name=field.stored_field.name && c.name=column) e.table.columns) old in
        let introduced=List.exists (fun (row:T.row) -> row.mapping.identity=identity &&
          List.exists (function Migration_transform_rules.Retyped p -> p.current.name=field.stored_field.name | _ -> false) row.mapping.values) rows in
        if not (retained || introduced) then reject ~code:"MIG027" field.stored_field.loc
          "compiler-owned storage annotations require their exact introducing Retype edge") (I.field_shapes schema);
    let next=describe (D.version edge) schema in
    Option.iter (fun link ->
      links:=link::!links;
      List.iter (fun (row:T.row) ->
        let find version = match List.find_opt (fun entity -> entity.identity=row.mapping.identity) version.entities with
          | Some entity -> entity | None -> reject loc "linked callback entity is absent from its adjacent source inventory" in
        let old=find !previous and fresh=find next in
        if fresh.generation<>old.generation+1 then reject loc "linked row callback does not advance exactly one entity generation";
        bindings:={version=next.version;previous=old;current=fresh;link;row}::!bindings) rows) checked_link;
    versions:=next::!versions;previous:=next) (List.tl schemas) edges;
  let result={retirements=List.rev !retirements;versions=List.rev !versions;bindings=List.sort (fun (a:binding) (b:binding) -> compare (a.version,a.current.identity) (b.version,b.current.identity)) !bindings;links=List.rev !links;edges} in
   if has_stages &&
      (result.retirements<>[] || result.bindings<>[] || List.exists(fun edge->D.queue_transforms edge<>[])edges) then
     reject ~code:"MIG030" loc "stage preparation currently requires an additive history; combining stages with transformations, queue conversion or Drop is not implemented";
   ignore (checked (revalidate result));result)

let check = check_internal ~queue_expansion:false
let check_queue_expansion = check_internal ~queue_expansion:true
