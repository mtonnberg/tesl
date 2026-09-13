module C = Migration_canonical
module P = Migration_program
module R = Migration_retained_storage
module H = Migration_row_history
let version_node = Migration_retained_storage_canonical.version_node
let to_json ~quote source =
 let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]" in
 let program=P.source_program source in
 let database (database:P.database) =
  let history=List.assoc database.identity (P.row_histories source) in
  match R.plan history with
  | Error errors -> Error errors
  | Ok plan ->
   let version v =
    let contract,hash=H.contract C.Migration (version_node ~family:database.family ~namespace:database.namespace plan v) in
    Printf.sprintf {|{"contract":%s,"hash":%s}|} (quote contract) (quote hash) in
   Ok (Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s}|}
    (quote database.identity) (quote database.family) (quote database.namespace) database.current_version
    (array version (R.versions plan))) in
 let databases=List.map database (P.databases program) in
 let errors=List.concat_map (function Error errors -> errors | Ok _ -> []) databases in
 if errors<>[] then Error errors else
 Ok (Printf.sprintf {|{"version":1,"kind":"compiled-retained-physical-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (P.compiler_abi program)) (quote (P.stored_value_compatibility program))
  (array Fun.id (List.filter_map (function Ok value -> Some value | Error _ -> None) databases)))
