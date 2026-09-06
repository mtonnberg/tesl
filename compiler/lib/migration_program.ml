open Ast
module A = Migration_abi
module D = Migration_declaration
module E = Migration_expansion
module H = Migration_history_sources
module M = Migration_manifest
module S = Migration_sparse
module T = Migration_selection
type origin = {initial_version:int;steps:(E.step list,S.error list) result}
type database = {identity:string;family:string;namespace:string;current_version:int;origins:origin list}
type t = {abi:A.t;databases:database list;inputs:(string * string) list}
let databases t = t.databases
let compiler_abi t = A.id t.abi
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
       (match String.split_on_char '.' root,Migration_form.application backend with
        | [family;"VCurrent"],("Postgres",[config]) when Migration_source.valid_family family && prefix=family ^ ".Migrate" ->
          let namespace = match List.assoc_opt "namespace" (Desugar.config_record_fields config) with
           | Some (ELit {lit=LString name;_}) when name<>"" && String.length name<=63 &&
               String.is_valid_utf_8 name && not (String.contains name '\000') -> name
           | _ -> reject ~code:"MIG016" d.loc "versioned PostgreSQL builds require a static namespace fitting 63 UTF-8 bytes" in
          Some (m.module_name ^ "." ^ d.name,family,namespace,d.loc)
        | _ -> None)
     | _ -> None)
  | _ -> None) m.decls) modules |> List.sort_uniq compare
let verify_bindings expected modules = protect "<migration build>" (fun () ->
 Option.iter (fun t ->
  let paths = List.map fst t.inputs @ List.map fst (A.source_inputs t.abi) in
  List.iter (fun (m:module_form) ->
   if not (List.mem (Source_input.canonical_path m.source_file) paths) then
    reject ~code:"MIG013" (Location.dummy_loc m.source_file)
     "compilation selected an import outside its captured source history") modules) expected;
 let actual = candidates modules |> List.map (fun (identity,family,namespace,_) -> identity,family,namespace) |> List.sort compare in
 let expected = Option.fold ~none:[] ~some:(fun t -> List.map (fun d -> d.identity,d.family,d.namespace) t.databases) expected |> List.sort compare in
 if actual<>expected then reject ~code:"MIG013" (Location.dummy_loc "<migration build>")
  "database history bindings changed during compilation; rebuild from one source snapshot")
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
  abi (A.with_snapshot context (fun () ->
   (* Capture every connection before interpreting any history or emitting Go.
      Imported application modules and implicit historical dependencies all belong
      to these guards; no credentials are copied into the artifact. *)
   let targets = List.map (fun (identity,family,namespace,loc) ->
    let root = target (T.infer_project_root ~entry_file ~database:(Some identity)) in
    let selected = target (T.resolve ~compiler_abi:(A.id context) ~project_root:root ~entry_file
      ~database:(Some identity) ~documents:[]) in
    identity,family,namespace,loc,root,selected) selected in
   let guards = List.map (fun (_,_,_,_,_,selected) -> T.source_guard selected) targets in
   let inputs = List.concat_map (fun source_guard -> guard (M.source_files source_guard)) guards |> List.sort_uniq compare in
   let result = Source_input.with_pinned_files inputs (fun () ->
   let databases = List.map (fun (identity,family,namespace,loc,root,selected) ->
    let h = history (H.discover ~compiler_abi:(A.id context) ~project_root:root ~family) in
    List.iter (fun (file,digest) ->
     if Option.map Migration_hash.digest (List.assoc_opt file inputs) <> Some digest then
      reject ~code:"MIG013" (Location.dummy_loc file) "history selected a source outside its captured compilation snapshot")
      (H.source_inputs h);
    let schemas = H.frozen h @ [H.current h] in
    let sources = H.completed_migrations h @ Option.to_list (H.current_migration h) in
    if List.length sources+1<>List.length schemas then reject ~code:"MIG001" loc "a versioned build requires complete migration history from V1";
    let edges = List.mapi (fun index (s:H.migration_source) ->
     let edge = match checked (D.check ~compiler_abi:(A.id context) ~source:s.contents (parse s.path s.contents)) with
      | Some edge -> edge | None -> reject loc "migration declaration missing from compiled history" in
     if D.version edge<>index+2 then reject loc "compiled migration history must start at V1 and remain consecutive";
     if D.source_seals edge=None then reject ~code:"MIG013" loc "compiled migration history requires recorded schema source seals";
     edge) sources in
    let inventories = List.map (fun (s:H.schema) -> s.inventory) schemas in
    let first = checked (E.generate ~initial_version:1 ~schemas:inventories ~edges) in
    let origins = {initial_version=1;steps=Ok first} :: List.init (List.length schemas-1) (fun index ->
     let initial_version=index+2 in
     {initial_version;steps=E.generate ~initial_version ~schemas:inventories ~edges}) in
    history (H.verify_unchanged h);
    {identity;family;namespace;current_version=(T.selection selected).current_version;origins}) targets in
   f (Some {abi=context;databases;inputs})) in
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
 Printf.sprintf {|{"version":2,"kind":"compiled-migration-history","compilerAbi":%s,"databases":%s}|}
  (quote (compiler_abi t)) (array database t.databases)
