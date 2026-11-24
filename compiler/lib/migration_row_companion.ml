(* JSON string literal. Runs of bytes needing no escape are copied whole: the
   generated histories are megabytes of hexadecimal contracts. *)
let quote s =
  let length = String.length s in
  let plain c = c <> '"' && c <> '\\' && Char.code c >= 0x20 in
  if String.for_all plain s then "\"" ^ s ^ "\"" else begin
  let buf = Buffer.create (length + 16) in
  Buffer.add_char buf '"';
  let start = ref 0 in
  for i = 0 to length - 1 do
    let c = String.unsafe_get s i in
    if not (plain c) then begin
      Buffer.add_substring buf s !start (i - !start);
      start := i + 1;
      match c with
      | '"'  -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    end
  done;
  Buffer.add_substring buf s !start (length - !start);
  Buffer.add_char buf '"';
  Buffer.contents buf
  end

module P = Migration_program
module RH = Migration_row_history
module C = Migration_canonical
module I = Migration_inventory
module S = Migration_storage
module R = Migration_transform_rules
module L = Migration_transform_link
let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]"
let column ~quote (c:S.column) =
 Printf.sprintf {|{"field":%s,"name":%s,"type":%s,"nullable":%b,"primaryKey":%b}|}
  (quote c.field.name) (quote c.name) (quote (S.scalar_name c.scalar)) c.nullable c.primary_key
let schema_hash v=C.digest C.Snapshot (I.snapshot v.RH.schema)
let type_hash e=snd (RH.contract C.Contract e.RH.type_contract)
let base_json ~quote ~go_type source =
 let p=P.source_program source in
 P.unresumed p;
 let has_retirements=List.exists (fun (_,h) -> RH.retirements h<>[]) (P.row_histories source) in
 let error (e:Migration_sparse.error)=Printf.sprintf {|{"code":%s,"message":%s}|} (quote e.code) (quote e.message) in
 let origin (o:P.origin)=match o.steps with
 | Ok steps -> Printf.sprintf {|{"initialVersion":%d,"steps":%s,"errors":[]}|} o.initial_version
   (array (Migration_expansion.step_to_json ~include_catalog:false ~quote) steps)
 | Error errors -> Printf.sprintf {|{"initialVersion":%d,"steps":null,"errors":%s}|} o.initial_version (array error errors) in
 let database (d:P.database)=
  let rows=List.assoc d.identity (P.row_histories source) in
  let retirements=if not has_retirements then "" else
   ",\"retirements\":" ^ array (fun (r:RH.retirement) ->
    let schema n=List.find (fun (v:RH.version) -> v.version=n) (RH.versions rows) in
    Printf.sprintf {|{"migrationVersion":%d,"entity":%s,"fromSchemaSnapshot":%s,"toSchemaSnapshot":%s}|}
     r.version (quote r.previous.identity) (quote (schema_hash (schema (r.version-1))))
     (quote (schema_hash (schema r.version)))) (RH.retirements rows) in
  let nodes=Migration_canonical_nodes.create ~quote in
  let versions=Emit_fragment.render_entries ~document:"source" ~database:d.identity ~revision:(fun (v:Migration_records.version) -> v.version) nodes
    (Migration_records.version_json ~quote ~contract:(Migration_canonical_nodes.reference nodes) ~go_type:(go_type d.identity)) (P.records source d.identity).versions in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s,"origins":%s%s,"canonicalNodes":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) d.current_version
   versions (array origin d.origins) retirements (Migration_canonical_nodes.to_json nodes) in
 Printf.sprintf {|{"version":%d,"kind":"compiled-migration-source-history","contractEncoding":"tesl-canonical-nodes-v1","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (if has_retirements then 5 else 4) (quote (P.compiler_abi p)) (quote (P.stored_value_compatibility p)) (array database (P.databases p))
(* Current codecs describe checked stored rows after an earlier transformation.
   They are not migration callbacks and carry no Same/conversion authority. The
   Each entity needs its own zero-window projection; another table's active
   transformation must not erase that current typed access. *)
let current_codecs history =
 match List.rev (RH.versions history) with
 | [] -> []
 | current::_ -> current.entities |> List.filter (fun (entity:RH.entity)->entity.generation>1 &&
     not(List.exists(fun binding->RH.migration_version binding=current.version &&
       (RH.current binding).identity=entity.identity)(RH.bindings history)))
   |> List.sort (fun (a:RH.entity) b->String.compare a.identity b.identity)
   |> List.map (fun entity->current,entity)

let rows_json ?projection ~quote source =
 let p=P.source_program source in
 P.unresumed p;
 let has_current=Option.is_some projection && List.exists (fun (_,history)->current_codecs history<>[]) (P.row_histories source) in
 let has_legacies=List.exists (fun (_,h) -> List.exists (fun b -> (RH.row b).legacies<>[]) (RH.bindings h)) (P.row_histories source) in
 let has_writebacks=List.exists (fun (_,h) -> List.exists (fun b -> (RH.row b).writebacks<>[]) (RH.bindings h)) (P.row_histories source) in
 if (has_writebacks || has_legacies) && projection=None then invalid_arg "WriteBack artifacts require checked typed row storage adapters";
 let transform nodes database history (x:Migration_records.transform) =
  let live=List.find_opt (fun b -> RH.migration_version b=x.migration_version &&
    (RH.current b).identity=x.current.identity) (RH.bindings history) in
  let row=Option.map RH.row live in
  let writebacks=Option.fold ~none:[] ~some:(fun (row:Migration_transform.row) -> row.writebacks) row in
  let legacies=Option.fold ~none:[] ~some:(fun (row:Migration_transform.row) -> row.legacies) row in
  let version=x.migration_version in
  let ordered=match projection with None -> "" | Some project ->
   Printf.sprintf {|,"sourceProjection":%s,"targetProjection":%s|}
    (array quote (project database (version-1) x.previous)) (array quote (project database version x.current)) in
  let ordered=ordered ^ if not (has_current || has_writebacks || has_legacies) then "" else
   ",\"writeBacks\":" ^ array (fun (w:Migration_transform.writeback_binding) ->
     Printf.sprintf {|{"previous":%s,"current":%s}|} (quote w.mapping.previous.name) (quote w.mapping.current.name)) writebacks in
  let ordered=ordered ^ if not (has_current || has_legacies) then "" else
    ",\"legacyWrites\":" ^ array (fun (w:Migration_transform.legacy_binding) -> quote w.mapping.previous.name) legacies in
  Migration_records.transform_json ~quote ~contract:(Migration_canonical_nodes.reference nodes) ~extra:ordered x in
 let database (d:P.database)=
  let history=List.assoc d.identity (P.row_histories source) in
  let current=if not has_current then "" else
   let project=Option.get projection in
   ",\"currentCodecs\":" ^ array (fun ((version:RH.version),(entity:RH.entity))->
    Printf.sprintf {|{"schemaVersion":%d,"entity":%s,"generation":%d,"schemaSnapshot":%s,"storageSnapshot":%s,"typeContractHash":%s,"projection":%s}|}
     version.version (quote entity.identity) entity.generation (quote (schema_hash version))
     (quote (S.digest version.storage)) (quote (type_hash entity))
     (array quote (project d.identity version.version (Migration_records.entity entity)))) (current_codecs history) in
  let nodes=Migration_canonical_nodes.create ~quote in
  (* Stored entries omit the reverse-write fields, which every entry carries
     once any binding or current codec needs them; a stored binding has none. *)
  let suffix=(if has_current || has_writebacks || has_legacies then ",\"writeBacks\":[]" else "") ^
    (if has_current || has_legacies then ",\"legacyWrites\":[]" else "") in
  let shape entry=String.sub entry 0 (String.length entry-1) ^ suffix ^ "}" in
  let unshape entry=if String.ends_with ~suffix:(suffix ^ "}") entry then
    Some (String.sub entry 0 (String.length entry-String.length suffix-1) ^ "}") else None in
  let transforms=Emit_fragment.render_entries ~shape ~unshape ~document:"rows" ~database:d.identity ~revision:(fun (x:Migration_records.transform) -> x.migration_version) nodes
    (transform nodes d.identity history) (P.records source d.identity).transforms in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"transforms":%s%s,"canonicalNodes":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) d.current_version
   transforms current (Migration_canonical_nodes.to_json nodes) in
 Printf.sprintf {|{"version":%d,"kind":"compiled-row-transform-history","contractEncoding":"tesl-canonical-nodes-v1","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (if has_current then 5 else if has_legacies then 4 else if has_writebacks then 3 else if Option.is_some projection then 2 else 1) (quote (P.compiler_abi p)) (quote (P.stored_value_compatibility p)) (array database (P.databases p))
