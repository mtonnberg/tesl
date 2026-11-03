(** Readable source-only description of a checked retained-row history.
    None of these fields is a database receipt or permission to prune a decoder. *)
module H = Migration_row_history
module R = Migration_retained_storage
module T = Migration_transform_rules
module K = Migration_contract
let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"
let optional f = function None -> "null" | Some x -> f x
let describe ~quote ~contracts history =
 let errors = ref [] in
 match R.plan history with
 | Error errors -> Error errors
 | Ok plan ->
 let column (c:R.column) = Printf.sprintf
  {|{"name":%s,"type":%s,"nullable":%b,"primaryKey":%b,"introducedVersion":%d}|}
  (quote c.name) (quote (Migration_storage.scalar_name c.scalar)) c.nullable c.primary_key c.introduced_version in
 let index (i:Migration_storage.index) = Printf.sprintf
  {|{"name":%s,"columns":%s,"unique":%b}|} (quote i.name) (array quote i.columns) i.unique in
 let table (e:R.entity) = Printf.sprintf
  {|{"entity":%s,"table":%s,"generation":%d,"columns":%s,"indexes":%s}|}
  (quote e.source.identity) (quote e.source.table.name) e.source.generation (array column e.columns) (array index e.indexes) in
 let physical (e:R.entity) name =
  (List.find (fun (f:R.field) -> f.logical.field.name=name) e.projection).physical.name in
 let transform (w:R.window) =
  let row=H.row w.binding in
  let field value =
   let target,source,kind,enforcement=match value with
    | T.Copy p -> p.current.name,Some p.previous.name,"copy",None
    | T.Renamed p -> p.current.name,Some p.previous.name,"rename",None
    | T.Retyped p -> p.current.name,Some p.previous.name,"retype",None
    | T.Revalidated p -> p.current.name,Some p.previous.name,"revalidate",Some "runtime-only"
    | T.Empty_optional f -> f.name,None,"empty-optional",None
    | T.Constant (f,_) -> f.name,None,"default",None
    | T.Computed f -> f.name,None,"computed",None in
   Printf.sprintf {|{"target":%s,"source":%s,"kind":%s,"sourceColumn":%s,"targetColumn":%s,"proofEnforcement":%s}|}
    (quote target) (optional quote source) (quote kind)
    (optional (fun name -> quote (physical w.before name)) source)
    (quote (physical w.after target)) (optional quote enforcement) in
  let reverse (v:Migration_transform.writeback_binding) = Printf.sprintf
   {|{"previous":%s,"current":%s,"function":%s}|}
   (quote v.mapping.previous.name) (quote v.mapping.current.name) (quote v.function_binding.identity) in
  let _,transform_hash=H.contract Migration_canonical.Migration (Migration_transform_link.semantic (H.link w.binding)) in
  Printf.sprintf {|{"entity":%s,"table":%s,"mode":%s,"transformContractHash":%s,"fromGeneration":%d,"toGeneration":%d,"requiresFinalGeneration":%d,"fields":%s,"writeBacks":%s,"legacyFields":%s}|}
   (quote row.mapping.identity) (quote w.after.source.table.name)
   (quote (match row.mapping.mode with T.Migrate -> "migrate" | T.Derived -> "derived"))
   (quote transform_hash)
   w.before.source.generation w.after.source.generation w.requires_final_generation
   (array field row.mapping.values) (array reverse row.writebacks)
   (array (fun (v:Migration_transform.legacy_binding) -> quote v.mapping.previous.name) row.legacies) in
 let schemas=H.versions history in
 let step (v:R.version) =
  let codec_changes=if v.version=1 then "[]" else
   let before=(List.find(fun (s:H.version)->s.version=v.version-1) schemas).schema in
   let after=(List.find(fun (s:H.version)->s.version=v.version) schemas).schema in
   match Migration_codec_changes.inspect ~before ~after with
   | Ok reports -> Migration_codec_changes.json ~quote reports
   | Error e -> errors:={Migration_sparse.code="MIG013";loc=e.loc;message=e.message;related=[]}::!errors; "[]" in
  let contract=List.find_opt(fun c -> K.version c=v.version) contracts in
  let schema=(List.find(fun (s:H.version)->s.version=v.version) schemas).schema in
  Printf.sprintf {|{"version":%d,"schemaSnapshotHash":%s,"requiresContractVersion":%s,"tables":%s,"transforms":%s,"codecChanges":%s,"contract":%s}|}
   v.version (quote (Migration_canonical.digest Migration_canonical.Snapshot (Migration_inventory.snapshot schema)))
   (optional string_of_int v.requires_contract_version) (array table v.entities)
   (array transform v.windows) codec_changes
   (optional (fun c -> Printf.sprintf {|{"sourceFile":%s,"sourceHash":%s,"operationCount":%d}|}
    (quote (K.source_file c)) (quote (K.source_digest c)) (List.length(K.operations c))) contract) in
 let json=array step (R.versions plan) in
 if !errors=[] then Ok json else Error(List.rev !errors)
