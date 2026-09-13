(** Pure target discovery/guards shared by build and source-generation drivers. *)
open Ast
module M = Migration_manifest
module H = Migration_history_sources
type selection = {
  entry_file : string;
  database_file : string;
  database_name : string;
  family : string;
  schema_root : string;
  previous_version : int option;
  current_version : int;
  migration_directory : string;
}
type candidate = { database_name : string; database_file : string }
type error = { loc : Location.loc; message : string; candidates : candidate list }
type t = { selected : selection; compiler_abi : string; stored_value_compatibility : string option; root : string; guard : M.t }
let selection t = t.selected
let source_guard t = t.guard
exception Invalid of error list
let reject ?(candidates=[]) loc message = raise (Invalid [{loc;message;candidates}])
let file_error path message = reject (Location.dummy_loc path) message
let manifest = function Ok x -> x | Error errors -> raise (Invalid (List.map (fun (e : M.error) ->
  {loc=Location.dummy_loc e.path;message=e.message;candidates=[]}) errors))
let history = function Ok x -> x | Error (e : H.error) -> reject e.loc e.message
let protect file f = try Ok (f ()) with
  | Invalid errors -> Error errors
  | Sys_error message | Failure message | Invalid_argument message -> Error [{loc=Location.dummy_loc file;message;candidates=[]}]
  | Unix.Unix_error (error,operation,path) -> Error [{loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;candidates=[]}]
let require_path root file =
  let prefix = if Filename.dirname root = root then root else root ^ Filename.dir_sep in
  if Filename.is_relative file || not (String.starts_with ~prefix file) ||
     Source_input.canonical_path file <> file then
    file_error file "target sources must use canonical paths inside the selected project";
  if Source_input.kind file <> Unix.S_REG then file_error file "target source must be a regular file"
let graph root entry =
  let seen = Hashtbl.create 16 in
  let rec visit ?expected file =
    if not (Hashtbl.mem seen file) then begin
      require_path root file;
      let source = Source_input.read file in
      let m = match Parser.parse_module file source with Ok m -> m | Err e -> reject e.loc e.msg in
      Hashtbl.add seen file (m,Migration_hash.digest source);
      List.iter (fun (i : import_decl) -> if not (String.starts_with ~prefix:"Tesl." i.module_name) then
        visit ~expected:i.module_name (Validation_common.resolve_local_import_path file i.module_name)) m.imports
    end;
    Option.iter (fun name ->
      let m,_ = Hashtbl.find seen file in
      if m.module_name <> name then file_error file ("target import " ^ name ^ " resolves to a module declaring " ^ m.module_name)) expected in
  visit entry;
  Hashtbl.to_seq seen |> List.of_seq |> List.sort (fun (a,_) (b,_) -> String.compare a b)
let select entry_file database sources =
  let modules = List.map (fun (_, (m,_)) -> m) sources in
  let found = List.concat_map (fun (m : module_form) -> List.filter_map (function
    | DDatabase d -> Some (m,d,{database_name=m.module_name ^ "." ^ d.name;database_file=m.source_file})
    | _ -> None) m.decls) modules |> List.sort (fun (_,_,a) (_,_,b) ->
      compare (a.database_name,a.database_file) (b.database_name,b.database_file)) in
  let candidates = List.map (fun (_,_,c) -> c) found in
  let matches = match database with None -> found | Some name ->
    List.filter (fun (_,(d : database_form),c) -> name=d.name || name=c.database_name) found in
  let m,d,candidate = match matches with
    | [selected] -> selected
    | [] -> reject ~candidates (Location.dummy_loc entry_file)
        (match database with None -> "no database declaration is reachable from this entry; select the application's entry file"
         | Some name -> "no reachable database matches " ^ name)
    | _ -> reject ~candidates (Location.dummy_loc entry_file)
        "database selection is ambiguous; select one module-qualified database explicitly" in
  (match Migration_schema.check_ownership modules with
   | [] -> () | errors -> raise (Invalid (List.map (fun (e : Validation_common.validation_error) -> {loc=e.loc;message=e.message;candidates=[]}) errors)));
  let binding = match Migration_schema.resolve_binding ~modules m d with
    | Ok (Some binding) -> binding
    | Ok None -> reject d.loc "this database requires an explicit schema ownership declaration before migration generation"
    | Error errors -> raise (Invalid (List.map (fun (e : Validation_common.validation_error) -> {loc=e.loc;message=e.message;candidates=[]}) errors)) in
  m,binding,candidate
let root_source (m : module_form) (binding : Migration_schema.binding) =
  Validation_common.resolve_local_import_path m.source_file binding.schema_root
let expected_root root (binding : Migration_schema.binding) =
  Filename.concat root (Option.get (Validation_common.schema_module_relative_path binding.schema_root))
let require_root root m binding =
  let actual = root_source m binding in
  let expected = expected_root root binding in
  if actual <> expected then file_error actual
    ("the database imports " ^ actual ^ "; migration history for the selected project must be rooted at " ^ expected)
let infer_project_root ~entry_file ~database = protect entry_file (fun () ->
  let rec filesystem_root path =
    let parent = Filename.dirname path in if path=parent then path else filesystem_root parent in
  let sources = graph (filesystem_root entry_file) entry_file in
  let m,binding,_ = select entry_file database sources in
  let root = root_source m binding |> Filename.dirname |> Filename.dirname |> Filename.dirname in
  require_root root m binding;
  List.iter (fun (file,_) -> require_path root file) sources;
  root)
let resolve_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~entry_file ~database ~documents = protect entry_file (fun () ->
  (* Validate the project and capture selection inputs before interpreting them.
     All subsequently discovered dependencies retain their separately read hashes. *)
  let initial = manifest (M.create ~project_root:root ~reads:[entry_file] ~directories:[] ~imports:[] ~documents ~writes:[]) in
  let sources = graph root entry_file in
  let m,binding,candidate = select entry_file database sources in
  require_root root m binding;
  let family = match Validation_common.schema_module_parts binding.schema_root with
    | Some (family, "VCurrent", []) -> family | _ -> assert false in
  let h = history (H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~family) in
  let current = H.current h in
  let selected = {entry_file;database_file=candidate.database_file;database_name=candidate.database_name;
    family;schema_root=binding.schema_root;previous_version=(if current.version=1 then None else Some (current.version-1));
    current_version=current.version;migration_directory=Filename.dirname (Filename.concat root
      (Option.get (Validation_common.schema_module_relative_path (family ^ ".Migrate.V2"))))} in
  let reads = List.map fst sources @ List.map fst (H.source_inputs h) |> List.sort_uniq String.compare in
  let imports = List.concat_map (fun file ->
    let m = match List.assoc_opt file sources with
      | Some (m,_) -> m
      | None -> (match Parser.parse_module file (Source_input.read file) with Ok m -> m | Err e -> reject e.loc e.msg) in
    List.filter_map (fun (i : import_decl) ->
      if String.starts_with ~prefix:"Tesl." i.module_name then None else Some (file,i.module_name)) m.imports) reads in
  let complete = manifest (M.create ~project_root:root ~reads ~imports ~documents
    ~directories:[selected.migration_directory;Filename.dirname current.root_file] ~writes:[]) in
  List.iter (fun (file,(_,hash)) ->
    require_path root file;
    if Migration_hash.digest (Source_input.read file) <> hash then
      file_error file "target source changed during database selection") sources;
  history (H.verify_unchanged h);
  let guard = manifest (M.combine initial complete ~documents) in
  {selected;compiler_abi;stored_value_compatibility;root;guard})

let resolve = resolve_with_compatibility ~stored_value_compatibility:None
let project_root t = t.root
let compiler_abi t = t.compiler_abi
let stored_value_compatibility t = t.stored_value_compatibility
let verify t ~documents = protect t.selected.entry_file (fun () ->
  manifest (M.verify_source t.guard ~documents);
  manifest (M.verify_disk t.guard))
