module S = Migration_sparse
module D = Migration_declaration
module P = Migration_storage
module H = Migration_history_sources
module M = Migration_manifest
module A = Migration_abi
module T = Migration_target
open Migration_canonical

type default = Migration_expansion.default = Null | Constant of node
type operation = Migration_expansion.operation =
 | Create_table of P.table
 | Add_column of {table:string;column:P.column;default:default}
 | Build_index of {table:string;index:P.index;window_risk:string option}
 | Retain_table of string
 | Retain_index of {table:string;index:P.index;window_risk:string option}
type catalog_column = Migration_expansion.catalog_column = {column:P.column;default:default}
type catalog_table = Migration_expansion.catalog_table = {name:string;columns:catalog_column list;indexes:P.index list}
type step = Migration_expansion.step = {version:int;snapshot_hash:string;operations:operation list;epoch_preserving:bool;
             catalog:catalog_table list}
type t = {selection:T.selection;namespace:string;initial_version:int;steps:step list;digest:string;abi:A.t;guard:M.t}
let selection p = p.selection
let steps p = p.steps
let digest p = p.digest
let compiler_abi p = A.id p.abi
exception Invalid of S.error list
let reject ?(code="MIG016") loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error es -> raise (Invalid es)
let target = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e : T.error) ->
 {S.code="MIG020";loc=e.loc;message=e.message;related=List.map (fun (c : T.candidate) -> Location.dummy_loc c.database_file,c.database_name) e.candidates}) es))
let abi = function Ok x -> x | Error (e : A.error) -> reject ~code:"MIG013" (Location.dummy_loc e.path) e.message
let history = function Ok x -> x | Error (e : H.error) -> reject ~code:"MIG020" e.loc e.message
let guard = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e : M.error) ->
 {S.code="MIG013";loc=Location.dummy_loc e.path;message=e.message;related=[]}) es))
let protect file f = try Ok (f ()) with
 | Invalid es -> Error es
 | Sys_error message | Invalid_argument message | Failure message -> Error [{S.code="MIG020";loc=Location.dummy_loc file;message;related=[]}]
 | Unix.Unix_error (error,operation,path) -> Error [{S.code="MIG020";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let parsed file source = match Parser.parse_module file source with
 | Ok m -> m | Err e -> reject ~code:"MIG020" e.loc e.msg
let verify p ~documents = protect p.selection.entry_file (fun () ->
 abi (A.verify p.abi); guard (M.verify_source p.guard ~documents); guard (M.verify_disk p.guard))
let generate ~project_root ~entry_file ~database ~initial_version ~documents = protect entry_file (fun () ->
 if initial_version<1 || initial_version>2147483646 then
  reject ~code:"MIG020" (Location.dummy_loc entry_file) "initial installation version must be between 1 and 2147483646";
 let context = abi (A.current ()) in
 let stored_value_compatibility = A.stored_value_compatibility context in
 let result = abi (A.with_snapshot context (fun () ->
  let selected = target (T.resolve_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
    ~compiler_abi:(A.id context) ~project_root ~entry_file ~database ~documents) in
  let selection = T.selection selected in
  let owner = parsed selection.database_file (Source_input.read selection.database_file) in
  let connection = List.find_map (function Ast.DDatabase d when owner.module_name ^ "." ^ d.name=selection.database_name -> Some d | _ -> None) owner.decls in
  let connection = Option.get connection in
  let fields = match connection.config_expr with None -> [] | Some e -> Desugar.config_record_fields e in
  let namespace = match List.assoc_opt "backend" fields with
   | Some e -> (match Migration_form.application e with
     | "Postgres",[config] -> (match List.assoc_opt "namespace" (Desugar.config_record_fields config) with
       | Some (Ast.ELit {lit=Ast.LString name;_}) when name<>"" && String.length name<=63 &&
           String.is_valid_utf_8 name && not (String.contains name '\000') -> name
       | _ -> reject connection.loc "physical planning requires a static PostgreSQL namespace fitting 63 UTF-8 bytes")
     | _ -> reject connection.loc "PostgreSQL physical planning requires an explicit Postgres backend on the selected database")
   | None -> reject connection.loc "PostgreSQL physical planning requires an explicit Postgres backend on the selected database" in
  (* Frontend checking alone does not prove that every stored codec can be
     emitted. Check the complete application through the actual Go backend. *)
  (match Compile.compile_go_source entry_file (Source_input.read entry_file) with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure ds -> raise (Invalid (List.filter_map (fun (d : Compile.diagnostic) ->
     if d.severity<>"error" then None else Some {S.code=d.code;
       loc={Location.file=d.file;start={line=d.start_line;col=d.start_col};stop={line=d.end_line;col=d.end_col}};
       message=d.message;related=[]}) ds)));
  let h = history (H.discover_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
    ~compiler_abi:(A.id context) ~project_root ~family:selection.family) in
  let schemas = H.frozen h @ [H.current h] in
  if initial_version>List.length schemas then reject ~code:"MIG020" connection.loc
    "initial installation version exceeds the current source revision";
  let sources = H.completed_migrations h @ Option.to_list (H.current_migration h) in
  if List.length sources+1<>List.length schemas then reject ~code:"MIG001" connection.loc "complete source history is required before planning";
  let edges = List.mapi (fun index (s : H.migration_source) ->
    let edge = match checked (D.check ~stored_value_compatibility ~compiler_abi:(A.id context) ~source:s.contents (parsed s.path s.contents)) with
      | Some x -> x | None -> reject ~code:"MIG020" (Location.dummy_loc s.path) "migration declaration missing" in
    if D.version edge<>index+2 then reject ~code:"MIG020" (Location.dummy_loc s.path) "source history must start at V1 and remain consecutive";
    if D.source_seals edge=None then reject ~code:"MIG013" (Location.dummy_loc s.path) "physical planning requires the recorded schema source seals";
    edge) sources in
  let steps = checked (Migration_expansion.generate ~initial_version
    ~schemas:(List.map (fun (s : H.schema) -> s.inventory) schemas) ~edges) in
  history (H.verify_unchanged h);
  let digest = Migration_canonical.digest Migration (Seq [Bytes "postgres-expansion-plan-v1";Bytes (A.id context);
    Bytes selection.family;Bytes selection.database_name;Bytes namespace;Bytes (string_of_int initial_version);
    Seq (List.map Migration_expansion.step_node steps)]) in
  {selection;namespace;initial_version;steps;digest;abi=context;guard=T.source_guard selected})) in
 checked (verify result ~documents); result)

let quote = Compile.json_encode_string
let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"
let to_json p =
 let step = Migration_expansion.step_to_json ~quote in
 Printf.sprintf {|{"version":1,"kind":"migration-plan-preview","ok":true,"executable":false,"compilerAbi":%s,"planHash":%s,"database":%s,"namespace":%s,"family":%s,"initialVersion":%d,"steps":%s}|}
  (quote (compiler_abi p)) (quote p.digest) (quote p.selection.database_name) (quote p.namespace) (quote p.selection.family) p.initial_version (array step p.steps)
let errors_to_json errors =
 let error (e : S.error) = Printf.sprintf {|{"code":%s,"file":%s,"line":%d,"col":%d,"message":%s}|}
  (quote e.code) (quote e.loc.file) e.loc.start.line e.loc.start.col (quote e.message) in
 {|{"version":1,"kind":"migration-plan-preview","ok":false,"executable":false,"errors":|} ^ array error errors ^ "}"
