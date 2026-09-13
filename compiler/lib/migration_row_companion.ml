let quote s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

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
 let entity database version (e:RH.entity) =
  let contract,hash=RH.contract C.Contract e.type_contract in
  let package,name=go_type database version e in
  Printf.sprintf {|{"entity":%s,"table":%s,"generation":%d,"typeContract":%s,"typeContractHash":%s,"columns":%s,"goTypePackage":%s,"goTypeName":%s}|}
   (quote e.identity) (quote e.table.name) e.generation (quote contract) (quote hash)
   (array (column ~quote) e.table.columns) (quote package) (quote name) in
 let version database (v:RH.version) =
  let schema,hash=RH.contract C.Snapshot (I.snapshot v.schema) in
  let storage,storage_hash=RH.contract C.Migration (S.node v.storage) in
  Printf.sprintf {|{"version":%d,"schemaContract":%s,"schemaSnapshotHash":%s,"storageContract":%s,"storageSnapshotHash":%s,"entities":%s}|}
   v.version (quote schema) (quote hash) (quote storage) (quote storage_hash) (array (entity database v.version) v.entities) in
 let error (e:Migration_sparse.error)=Printf.sprintf {|{"code":%s,"message":%s}|} (quote e.code) (quote e.message) in
 let origin (o:P.origin)=match o.steps with
 | Ok steps -> Printf.sprintf {|{"initialVersion":%d,"steps":%s,"errors":[]}|} o.initial_version
   (array (Migration_expansion.step_to_json ~include_catalog:false ~quote) steps)
 | Error errors -> Printf.sprintf {|{"initialVersion":%d,"steps":null,"errors":%s}|} o.initial_version (array error errors) in
 let database (d:P.database)=
  let rows=List.assoc d.identity (P.row_histories source) in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s,"origins":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) d.current_version
   (array (version d.identity) (RH.versions rows)) (array origin d.origins) in
 Printf.sprintf {|{"version":4,"kind":"compiled-migration-source-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (P.compiler_abi p)) (quote (P.stored_value_compatibility p)) (array database (P.databases p))
let rows_json ?projection ~quote source =
 let p=P.source_program source in
 let field mapping =
  let target,kind,source,constant=match mapping with
  | R.Copy {previous;current} -> current,"copy",Some previous.name,None
  | R.Renamed {previous;current} -> current,"rename",Some previous.name,None
  | R.Empty_optional current -> current,"empty-optional",None,None
  | R.Constant (current,value) -> current,"default",None,Some (RH.hex (C.encode value))
  | R.Retyped {previous;current} -> current,"retype",Some previous.name,None
  | R.Computed current -> current,"computed",None,None in
  let nullable=Option.fold ~none:"null" ~some:quote in
  target.name,Printf.sprintf {|{"target":%s,"kind":%s,"source":%s,"constant":%s}|}
   (quote target.name) (quote kind) (nullable source) (nullable constant) in
 let has_legacies=List.exists (fun (_,h) -> List.exists (fun b -> (RH.row b).legacies<>[]) (RH.bindings h)) (P.row_histories source) in
 let has_writebacks=List.exists (fun (_,h) -> List.exists (fun b -> (RH.row b).writebacks<>[]) (RH.bindings h)) (P.row_histories source) in
 if (has_writebacks || has_legacies) && projection=None then invalid_arg "WriteBack artifacts require checked typed row storage adapters";
 let transform database history b =
  let previous=RH.previous b and current=RH.current b in
  let version=RH.migration_version b in
  let from=List.find (fun (v:RH.version) -> v.version=version-1) (RH.versions history) in
  let target=List.find (fun (v:RH.version) -> v.version=version) (RH.versions history) in
  let link=RH.link b in
  let contract,hash=RH.contract C.Migration (L.semantic link) in
  let mode=match (RH.row b).mapping.mode with R.Migrate -> "migrate" | R.Derived -> "derived" in
  let ordered=match projection with None -> "" | Some project ->
   Printf.sprintf {|,"sourceProjection":%s,"targetProjection":%s|}
    (array quote (project database (version-1) previous)) (array quote (project database version current)) in
  let ordered=ordered ^ if not (has_writebacks || has_legacies) then "" else
   ",\"writeBacks\":" ^ array (fun (w:Migration_transform.writeback_binding) ->
     Printf.sprintf {|{"previous":%s,"current":%s}|} (quote w.mapping.previous.name) (quote w.mapping.current.name)) (RH.row b).writebacks in
  let ordered=ordered ^ if not has_legacies then "" else
    ",\"legacyWrites\":" ^ array (fun (w:Migration_transform.legacy_binding) -> quote w.mapping.previous.name) (RH.row b).legacies in
  Printf.sprintf {|{"migrationVersion":%d,"entity":%s,"table":%s,"mode":%s,"previousGeneration":%d,"targetGeneration":%d,"fromSchemaSnapshot":%s,"toSchemaSnapshot":%s,"fromStorageSnapshot":%s,"toStorageSnapshot":%s,"fromTypeContractHash":%s,"toTypeContractHash":%s,"sourceSchemaColumns":%s,"targetSchemaColumns":%s,"fieldMapping":%s,"transformContractFormat":"tesl-row-transform-v1","transformContract":%s,"transformContractHash":%s%s}|}
   version (quote current.identity) (quote current.table.name) (quote mode) previous.generation current.generation
   (quote (schema_hash from)) (quote (schema_hash target)) (quote (S.digest from.storage)) (quote (S.digest target.storage))
   (quote (type_hash previous)) (quote (type_hash current)) (array (column ~quote) previous.table.columns)
   (array (column ~quote) current.table.columns)
   (array snd (List.sort compare (List.map field (RH.row b).mapping.values))) (quote contract) (quote hash) ordered in
 let database (d:P.database)=
  let history=List.assoc d.identity (P.row_histories source) in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"transforms":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) d.current_version (array (transform d.identity history) (RH.bindings history)) in
 Printf.sprintf {|{"version":%d,"kind":"compiled-row-transform-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (if has_legacies then 4 else if has_writebacks then 3 else if Option.is_some projection then 2 else 1) (quote (P.compiler_abi p)) (quote (P.stored_value_compatibility p)) (array database (P.databases p))
