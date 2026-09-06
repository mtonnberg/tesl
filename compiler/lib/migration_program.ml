open Ast
module A = Migration_abi
module D = Migration_declaration
module E = Migration_expansion
module H = Migration_history_sources
module M = Migration_manifest
module S = Migration_sparse
module T = Migration_selection
type origin = {initial_version:int;steps:(E.step list,S.error list) result}
type queue_payload = {job:string;contract:string;contract_hash:string}
type queue_contract = {queue:string;payloads:queue_payload list}
type queue_version = {version:int;storage_snapshot_hash:string;schema_snapshot_hash:string;
 source_seal_inventory:string;contracts:queue_contract list}
type queue_binding = {application_queue:string;database_identity:string;family:string;queue_identity:string;
 current_version:int;jobs:(string * string * string) list}
type database = {identity:string;family:string;namespace:string;current_version:int;origins:origin list;
 queue_versions:queue_version list}
type t = {abi:A.t;databases:database list;inputs:(string * string) list;
 queue_bindings:queue_binding list;inventories:(string * Migration_inventory.t) list}
let databases t = t.databases
let queue_bindings t = t.queue_bindings
let queue_codec_records t =
 List.concat_map (fun (_,inventory) -> Migration_inventory.queue_contracts inventory |>
  List.concat_map (fun (q:Migration_inventory.queue_contract) -> q.payloads |> List.concat_map (fun payload ->
    Migration_inventory.queue_payload_codec_records inventory payload |> List.filter_map (fun declaration ->
     if declaration.Migration_inventory.declaration_kind=Migration_inventory.Record then Some declaration.qualified_name else None)))) t.inventories
 |> List.sort_uniq compare
let compiler_abi t = A.id t.abi
let stored_value_compatibility t = A.stored_value_compatibility t.abi
exception Invalid of S.error list
let reject ?(code="MIG020") loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error es -> raise (Invalid es)
let target = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e:T.error) ->
  {S.code="MIG020";loc=e.loc;message=e.message;related=[]}) es))
let abi = function Ok x -> x | Error (e:A.error) -> reject ~code:"MIG013" (Location.dummy_loc e.path) e.message
let history = function Ok x -> x | Error (e:H.error) -> reject e.loc e.message
let guard = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e:M.error) ->
  {S.code="MIG013";loc=Location.dummy_loc e.path;message=e.message;related=[]}) es))
let protect file f = try Ok (f ()) with
 | Invalid es -> Error es
 | Sys_error message | Invalid_argument message | Failure message ->
   Error [{S.code="MIG020";loc=Location.dummy_loc file;message;related=[]}]
 | Unix.Unix_error (error,operation,path) ->
   Error [{S.code="MIG020";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let parse file source = match Parser.parse_module file source with
 | Ok m -> m | Err e -> reject e.loc e.msg
let candidates (modules:module_form list) =
 List.concat_map (fun (m:module_form) -> List.filter_map (function
  | DDatabase d ->
    let fields = Option.fold ~none:[] ~some:Desugar.config_record_fields d.config_expr in
    (match List.assoc_opt "schema" fields,List.assoc_opt "migrations" fields,List.assoc_opt "backend" fields with
     | Some (EConstructor {name=root;args=[];_}),Some (EConstructor {name=prefix;args=[];_}),Some backend ->
       (match Validation_common.schema_module_parts root,Migration_form.application backend with
        | Some (family,"VCurrent",[]),("Postgres",[config]) when Migration_source.valid_family family && prefix=family ^ ".Migrate" ->
          let namespace = match List.assoc_opt "namespace" (Desugar.config_record_fields config) with
           | Some (ELit {lit=LString name;_}) when name<>"" && String.length name<=63 &&
               String.is_valid_utf_8 name && not (String.contains name '\000') -> name
           | _ -> reject ~code:"MIG016" d.loc "versioned PostgreSQL builds require a static namespace fitting 63 UTF-8 bytes" in
          Some (m.module_name ^ "." ^ d.name,family,namespace,d.loc)
        | _ -> None)
     | _ -> None)
  | _ -> None) m.decls) modules |> List.sort_uniq compare
let payload_contract node =
 let canonical = Migration_canonical.(encode (document Contract (Seq [Bytes "queue-payload-v1";node]))) in
 let digits="0123456789abcdef" in
 let hex=String.init (String.length canonical*2) (fun i -> let byte=Char.code canonical.[i/2] in digits.[if i mod 2=0 then byte lsr 4 else byte land 15]) in
 hex,Migration_hash.digest canonical
let queue_versions schemas edges =
 List.map (fun (schema:H.schema) ->
  let inventory=schema.inventory in
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
   storage_snapshot_hash=Migration_storage.digest (checked (Migration_storage.describe inventory));
   schema_snapshot_hash=Migration_canonical.digest Migration_canonical.Snapshot (Migration_inventory.snapshot inventory)}) schemas
let capture_queue_bindings modules databases inventories =
 List.concat_map (fun database ->
  let inventory=List.assoc database.identity inventories in
  let owner,name= match List.rev (String.split_on_char '.' database.identity) with
   | name::owner -> String.concat "." (List.rev owner),name | _ -> assert false in
  let m=List.find (fun (m:module_form) -> m.module_name=owner) modules in
  let declaration=List.find_map (function DDatabase d when d.name=name -> Some d | _ -> None) m.decls |> Option.get in
  ignore (checked (match Migration_queue.application_bindings ~modules ~database_module:m ~database:declaration inventory with
   | [] -> Ok () | es -> Error es));
  List.concat_map (fun (m:module_form) -> List.filter_map (function
   | DQueue q ->
     let fields=Option.fold ~none:[] ~some:Desugar.config_record_fields q.config_expr in
     let resolve kind field=Option.bind (List.assoc_opt field fields) Migration_queue.constructor
       |> fun ref -> Option.bind ref (Migration_queue.visible_reference modules m kind) in
     if resolve (function DDatabase d -> Some d.name | _ -> None) "database" <> Some database.identity then None else
     let name=resolve (function DQueueSchema q -> Some q.name | _ -> None) "schema" |> Option.get in
     let queue_identity=Migration_queue.wire_identity inventory name in
     let contract=List.find (fun q -> q.queue=queue_identity) (List.hd (List.rev database.queue_versions)).contracts in
     let jobs=List.assoc "jobs" fields |> Desugar.job_entries |> List.map (fun (spelling,_,_) ->
       let name=Migration_queue.visible_reference modules m (function DRecord r -> Some r.name | _ -> None) spelling |> Option.get in
       let job=Migration_queue.wire_identity inventory name in
       let payload=List.find (fun p -> p.job=job) contract.payloads in spelling,job,payload.contract_hash) in
     Some {application_queue=m.module_name ^ "." ^ q.name;database_identity=database.identity;family=database.family;
       queue_identity;current_version=database.current_version;jobs=List.sort compare jobs}
   | _ -> None) m.decls) modules) databases |> List.sort compare
let verify_bindings expected modules = protect "<migration build>" (fun () ->
 Option.iter (fun t ->
  let paths = List.map fst t.inputs @ List.map fst (A.source_inputs t.abi) in
  List.iter (fun (m:module_form) ->
   if not (List.mem (Source_input.canonical_path m.source_file) paths) then
    reject ~code:"MIG013" (Location.dummy_loc m.source_file)
     "compilation selected an import outside its captured source history") modules) expected;
 let actual = candidates modules |> List.map (fun (identity,family,namespace,_) -> identity,family,namespace) |> List.sort compare in
 let expected_connections = Option.fold ~none:[] ~some:(fun t -> List.map (fun d -> d.identity,d.family,d.namespace) t.databases) expected |> List.sort compare in
 if actual<>expected_connections then reject ~code:"MIG013" (Location.dummy_loc "<migration build>")
  "database history bindings changed during compilation; rebuild from one source snapshot";
 Option.iter (fun t -> if capture_queue_bindings modules t.databases t.inventories <> t.queue_bindings then
  reject ~code:"MIG013" (Location.dummy_loc "<migration build>") "queue history bindings changed during compilation") expected)
let with_history ~entry ~source f = protect entry.source_file (fun () ->
 let entry_file = Source_input.canonical_path entry.source_file in
 let graph = Frontend_check.build_local_import_graph ~entry entry_file in
 let modules = Hashtbl.to_seq_keys graph |> List.of_seq |> List.sort String.compare |> List.filter_map (fun file ->
   if file=entry_file then Some entry else Frontend_check.parse_module_file file) in
 let selected = candidates modules in
 if selected=[] then f None else
 let rec filesystem_root file = let parent=Filename.dirname file in if parent=file then file else filesystem_root parent in
 let input_root = Option.value (Source_input.project_root ()) ~default:(filesystem_root entry_file) in
 Source_input.with_overlays ~project_root:input_root [entry_file,source] (fun () ->
  let context = abi (A.current ()) in
  let stored_value_compatibility = A.stored_value_compatibility context in
  abi (A.with_snapshot context (fun () ->
   (* Capture every connection before interpreting any history or emitting Go.
      Imported application modules and implicit historical dependencies all belong
      to these guards; no credentials are copied into the artifact. *)
   let targets = List.map (fun (identity,family,namespace,loc) ->
    let root = target (T.infer_project_root ~entry_file ~database:(Some identity)) in
    let selected = target (T.resolve_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
      ~compiler_abi:(A.id context) ~project_root:root ~entry_file
      ~database:(Some identity) ~documents:[]) in
    identity,family,namespace,loc,root,selected) selected in
   let guards = List.map (fun (_,_,_,_,_,selected) -> T.source_guard selected) targets in
   let inputs = List.concat_map (fun source_guard -> guard (M.source_files source_guard)) guards |> List.sort_uniq compare in
   let result = Source_input.with_pinned_files inputs (fun () ->
   let inventories = ref [] in
   let databases = List.map (fun (identity,family,namespace,loc,root,selected) ->
    let h = history (H.discover_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
      ~compiler_abi:(A.id context) ~project_root:root ~family) in
    List.iter (fun (file,digest) ->
     if Option.map Migration_hash.digest (List.assoc_opt file inputs) <> Some digest then
      reject ~code:"MIG013" (Location.dummy_loc file) "history selected a source outside its captured compilation snapshot")
      (H.source_inputs h);
    let schemas = H.frozen h @ [H.current h] in
    let sources = H.completed_migrations h @ Option.to_list (H.current_migration h) in
    if List.length sources+1<>List.length schemas then reject ~code:"MIG001" loc "a versioned build requires complete migration history from V1";
    let edges = List.mapi (fun index (s:H.migration_source) ->
     let edge = match checked (D.check ~stored_value_compatibility ~compiler_abi:(A.id context) ~source:s.contents (parse s.path s.contents)) with
      | Some edge -> edge | None -> reject loc "migration declaration missing from compiled history" in
     if D.version edge<>index+2 then reject loc "compiled migration history must start at V1 and remain consecutive";
     if D.source_seals edge=None then reject ~code:"MIG013" loc "compiled migration history requires recorded schema source seals";
     edge) sources in
    inventories := (identity,(H.current h).inventory) :: !inventories;
    let queue_versions=queue_versions schemas edges in
    let inventories = List.map (fun (s:H.schema) -> s.inventory) schemas in
    let first = checked (E.generate ~initial_version:1 ~schemas:inventories ~edges) in
    let origins = {initial_version=1;steps=Ok first} :: List.init (List.length schemas-1) (fun index ->
     let initial_version=index+2 in
     {initial_version;steps=E.generate ~initial_version ~schemas:inventories ~edges}) in
    history (H.verify_unchanged h);
    {identity;family;namespace;current_version=(T.selection selected).current_version;origins;queue_versions}) targets in
   let inventories= !inventories in
   let queue_bindings=capture_queue_bindings modules databases inventories in
   f (Some {abi=context;databases;inputs;queue_bindings;inventories})) in
   List.iter (fun source_guard -> guard (M.verify_source source_guard ~documents:[]);guard (M.verify_disk source_guard)) guards;
   result))))

let to_json ~quote t =
 let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]" in
 let error (e:S.error) = Printf.sprintf {|{"code":%s,"message":%s}|} (quote e.code) (quote e.message) in
 let origin o = match o.steps with
  | Ok steps -> Printf.sprintf {|{"initialVersion":%d,"steps":%s,"errors":[]}|}
     o.initial_version (array (E.step_to_json ~include_catalog:false ~quote) steps)
  | Error es -> Printf.sprintf {|{"initialVersion":%d,"steps":null,"errors":%s}|} o.initial_version (array error es) in
 let database d = Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"origins":%s}|}
  (quote d.identity) (quote d.family) (quote d.namespace) d.current_version (array origin d.origins) in
 Printf.sprintf {|{"version":3,"kind":"compiled-migration-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (compiler_abi t)) (quote (stored_value_compatibility t)) (array database t.databases)

(** Companion wire keeps the strict expansion envelope bridge-compatible. No
    field here asserts that an installed baseline was inventoried or adopted. *)
let queues_to_json ~quote t =
 let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]" in
 let payload p=Printf.sprintf {|{"job":%s,"contractFormat":"tesl-queue-payload-v1","contract":%s,"contractHash":%s}|}
  (quote p.job) (quote p.contract) (quote p.contract_hash) in
 let contract q=Printf.sprintf {|{"queue":%s,"payloads":%s}|} (quote q.queue) (array payload q.payloads) in
 let version v=Printf.sprintf {|{"version":%d,"storageSnapshotHash":%s,"schemaSnapshotHash":%s,"checkedInventory":"complete","sourceSealInventory":%s,"contracts":%s}|}
  v.version (quote v.storage_snapshot_hash) (quote v.schema_snapshot_hash) (quote v.source_seal_inventory) (array contract v.contracts) in
 let database d=
  let origin o=Printf.sprintf {|{"initialVersion":%d,"versions":%s}|} o.initial_version
   (array string_of_int (List.init (d.current_version-o.initial_version+1) (fun i -> o.initial_version+i))) in
  Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s,"origins":%s}|}
   (quote d.identity) (quote d.family) (quote d.namespace) d.current_version (array version d.queue_versions) (array origin d.origins) in
 Printf.sprintf {|{"version":1,"kind":"compiled-queue-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (compiler_abi t)) (quote (stored_value_compatibility t)) (array database t.databases)
