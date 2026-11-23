module C = Migration_canonical
module P = Migration_program
module R = Migration_retained_storage
module H = Migration_row_history
let version_node = Migration_retained_storage_canonical.version_node
let to_json ~quote source =
 let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]" in
 let program=P.source_program source in
 P.unresumed program;
 let database (database:P.database) =
  let history=List.assoc database.identity (P.row_histories source) in
  (* The plan judgment stays in every build; resumed builds plan their later
     revisions from the checkpointed state. *)
  match R.plan history with
  | Error errors -> Error errors
  | Ok _ ->
   let nodes=Migration_canonical_nodes.create ~quote in
   let versions=array (Migration_records.physical_json ~quote ~contract:(Migration_canonical_nodes.reference nodes)) (P.records source database.identity).physical in
   Ok (Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s,"canonicalNodes":%s}|}
    (quote database.identity) (quote database.family) (quote database.namespace) database.current_version
    versions (Migration_canonical_nodes.to_json nodes)) in
 let databases=List.map database (P.databases program) in
 let errors=List.concat_map (function Error errors -> errors | Ok _ -> []) databases in
 if errors<>[] then Error errors else
 Ok (Printf.sprintf {|{"version":1,"kind":"compiled-retained-physical-history","contractEncoding":"tesl-canonical-nodes-v1","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (P.compiler_abi program)) (quote (P.stored_value_compatibility program))
  (array Fun.id (List.filter_map (function Ok value -> Some value | Error _ -> None) databases)))
