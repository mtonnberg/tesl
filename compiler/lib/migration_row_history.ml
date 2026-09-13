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
type t = {versions:version list;bindings:binding list;links:L.t list;edges:D.t list}
let versions t = t.versions
let bindings t = t.bindings
let declarations t = t.edges
let migration_version (b:binding) = b.version
let previous b = b.previous
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
let revalidate t = protect (fun () -> List.iter (fun link -> ignore (ir (L.revalidate link))) t.links)
let captured_sources t =
  List.concat_map (fun link -> T.captured_sources (L.checked_transform link)) t.links
  |> List.sort_uniq (fun (a,source_a) (b,source_b) -> compare (a.Ast.source_file,source_a) (b.Ast.source_file,source_b))
let validate_adapter_modes t = protect (fun () ->
  List.iter (fun binding -> match binding.row.function_binding with
    | Some _ when binding.row.mapping.mode=R.Migrate -> ()
    | None when binding.row.mapping.mode=R.Derived -> ()
    | _ -> reject binding.current.table.entity.entity_loc
        "row adapter mode differs from its exact checked source binding") t.bindings)
let check ~schemas ~edges = protect (fun () ->
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
  let versions=ref [baseline] and bindings=ref [] and links=ref [] in
  let previous=ref baseline in
  List.iter2 (fun schema edge ->
    let mapping=S.entities (D.coverage edge) in
    List.iter (function
      | S.Removed entity -> reject entity.entity_loc "row generation metadata does not yet support dropped or reintroduced entity lifecycles"
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
      | S.Reset | S.Drop -> reject loc "row generation metadata does not yet support reset/drop lifecycle operations"
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
  let result={versions=List.rev !versions;bindings=List.sort (fun a b -> compare (a.version,a.current.identity) (b.version,b.current.identity)) !bindings;links=List.rev !links;edges} in
  ignore (checked (revalidate result));result)
