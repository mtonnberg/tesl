module A = Migration_abi
module T = Migration_target
module M = Migration_manifest
type operation = Start | Refresh
type error = {loc:Location.loc;message:string;candidates:T.candidate list}
type t = {operation:operation;selection:T.selection;revision_after:int;abi:A.t;
          manifest:M.t;diagnostics:Compile.diagnostic list}
let operation p = p.operation
let selection p = p.selection
let revision_after p = p.revision_after
let compiler_abi p = A.id p.abi
let manifest p = p.manifest
let diagnostics p = p.diagnostics
let compilable p = not (List.exists (fun (d : Compile.diagnostic) -> d.severity="error") p.diagnostics)
exception Invalid of error list
let abi = function Ok x -> x | Error (e : A.error) ->
  raise (Invalid [{loc=Location.dummy_loc e.path;message=e.message;candidates=[]}])
let target = function Ok x -> x | Error errors ->
  raise (Invalid (List.map (fun (e : T.error) -> {loc=e.loc;message=e.message;candidates=e.candidates}) errors))
let source_guard = function Ok x -> x | Error errors ->
  raise (Invalid (List.map (fun (e : M.error) -> {loc=Location.dummy_loc e.path;message=e.message;candidates=[]}) errors))
let protect file f = try Ok (f ()) with
  | Invalid errors -> Error errors
  | Sys_error message | Invalid_argument message | Failure message -> Error [{loc=Location.dummy_loc file;message;candidates=[]}]
  | Unix.Unix_error (error,operation,path) -> Error [{loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;candidates=[]}]
let verify p ~documents = protect p.selection.entry_file (fun () ->
  abi (A.verify p.abi);
  source_guard (M.verify_source p.manifest ~documents);
  source_guard (M.verify_disk p.manifest))
let generate ~project_root ~entry_file ~database ~new_revision ~documents = protect entry_file (fun () ->
  let context = abi (A.current ()) in
  let preview = abi (A.with_snapshot context (fun () ->
    let target_ = target (T.resolve ~compiler_abi:(A.id context) ~project_root ~entry_file ~database ~documents) in
    let selected = T.selection target_ in
    let operation,revision_after,manifest =
      if new_revision || selected.current_version=1 then
        let p = target (T.start target_ ~documents) in Start,p.current_version,p.manifest
      else
        let p = target (T.refresh target_ ~documents) in Refresh,p.current_version,p.manifest in
    let diagnostics = Source_input.with_overlays
      ~project_root:(Option.value (Source_input.project_root ()) ~default:project_root)
      (M.overlays manifest) (fun () -> Compile.check_source entry_file (Source_input.read entry_file)) in
    {operation;selection=selected;revision_after;abi=context;manifest;diagnostics})) in
  (match verify preview ~documents with Ok () -> () | Error errors -> raise (Invalid errors));
  preview)
let quote = Compile.json_encode_string
let option_int = function None -> "null" | Some n -> string_of_int n
let to_json p =
  let s = p.selection in
  Printf.sprintf {|{"version":1,"kind":"migration-source-preview","ok":true,"operation":%s,"compilerAbi":%s,"compilable":%b,"selection":{"entryFile":%s,"databaseFile":%s,"database":%s,"family":%s,"schemaRoot":%s,"previousVersion":%s,"revisionBefore":%d,"revisionAfter":%d},"diagnostics":%s,"manifest":%s}|}
    (quote (match p.operation with Start -> "start" | Refresh -> "refresh"))
    (quote (compiler_abi p)) (compilable p) (quote s.entry_file) (quote s.database_file)
    (quote s.database_name) (quote s.family) (quote s.schema_root) (option_int s.previous_version)
    s.current_version p.revision_after (Compile.diagnostics_to_json p.diagnostics) (M.to_json p.manifest)
let errors_to_json errors =
  let candidate (c : T.candidate) = Printf.sprintf {|{"database":%s,"file":%s}|} (quote c.database_name) (quote c.database_file) in
  let error (e : error) = Printf.sprintf {|{"file":%s,"line":%d,"col":%d,"message":%s,"candidates":[%s]}|}
    (quote e.loc.file) e.loc.start.line e.loc.start.col (quote e.message)
    (String.concat "," (List.map candidate e.candidates)) in
  {|{"version":1,"kind":"migration-source-preview","ok":false,"errors":[|} ^
    String.concat "," (List.map error errors) ^ {|],"manifest":null}|}
