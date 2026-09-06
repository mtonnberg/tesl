open Ast
open Migration_ir

type checked_module = {
  form : module_form;
  typed_nodes : (expr * Type_system.ty) list;
  resolve : Migration_ir.resolver;
}

type t = { modules : checked_module list; sources : (string * string) list }

let names = function
  | DFunc f -> [Value, f.name]
  | DType (TypeNewtype t) -> [Type, t.name; Value, t.name]
  | DType (TypeAdt t) -> (Type, t.name) ::
      List.map (fun (v : adt_variant) -> Value, v.ctor) t.variants
  | DRecord r -> [Type, r.name; Value, r.name]
  | DEntity e -> [Type, e.name; Value, e.name]
  | DFact f -> [Predicate, f.name]
  | DQueueSchema q -> [Value, q.name]
  | DCodec c -> [Codec, c.name]
  | DConst c -> [Value, c.name]
  | DDatabase _ | DCapability _ | DQueue _ | DChannel _
  | DWorkers _ | DCache _ | DAgent _ | DEmail _ | DCapture _ | DApi _
  | DServer _ | DTest _ | DApiTest _ | DLoadTest _ -> []

let wants (import : import_decl) (owner : module_form) (ns, name) =
  match import.names with
  | ImportAll -> false
  | ImportExposing exposed ->
    List.mem name exposed ||
    ns = Value && List.exists (function
      | DType (TypeAdt t) -> List.mem (t.name ^ "(..)") exposed &&
          List.exists (fun (v : adt_variant) -> v.ctor = name) t.variants
      | _ -> false) owner.decls

(** Resolve existing compiler builtins by their owning module and name. There
    is no new per-primitive version registry or retained historical lowering:
    the complete inventory is bound to the caller's compiler ABI above. *)
let builtin (m : module_form) ns name =
  let exports = Type_system.tesl_module_exports in
  let homes = List.filter_map (fun (home, members) ->
    if List.mem name members then Some home else None) exports in
  let chosen = List.filter (fun home -> List.exists (fun (i : import_decl) ->
    i.module_name = home && (ns <> Predicate || match i.names with
      | ImportAll -> false | ImportExposing exposed -> List.mem name exposed)) m.imports) homes in
  let homes = if chosen = [] then homes else chosen in
  let homes = List.sort_uniq String.compare homes in
  let kind_ok = match ns with
    | Codec -> List.mem_assoc name Validation_common.builtin_codec_type
    | Predicate -> List.exists (fun (_, preds) -> List.mem name preds)
        Checker.tesl_module_predicate_exports
    | Type -> name <> "" && name.[0] >= 'A' && name.[0] <= 'Z'
    | Value -> Type_system.stdlib_capabilities_of name = [] in
  if not kind_ok then None
  else match homes with
    | [home] -> Some (Primitive (home ^ "." ^ name))
    | [] when List.mem name Type_system.always_available_stdlib_names ->
      Some (Primitive ("Tesl.Prelude." ^ name))
    | _ -> None

let protect loc f =
  try Ok (f ()) with
  | Invalid error -> Error error
  | Sys_error message | Failure message | Invalid_argument message -> Error {loc; message}
  | Unix.Unix_error (error, operation, path) ->
    Error {loc; message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}

let check captured =
  let loc = match captured with
    | (m, _) :: _ -> Location.dummy_loc m.source_file
    | [] -> Location.dummy_loc "<migration-checked-graph>" in
  protect loc (fun () ->
    if captured = [] then reject loc "a checked migration graph requires captured modules";
    let names_seen = Hashtbl.create 16 and paths_seen = Hashtbl.create 16 in
    List.iter (fun (m, source) ->
      (* Bound recursive reparsing/comparison before inspecting the capture.
         This public factory can receive an AST from an earlier checking pass. *)
      (match Frontend_check.module_complexity_diagnostics m with
       | error :: _ -> reject (Location.make_loc error.file error.start_line
           error.start_col error.end_line error.end_col) error.message
       | [] -> ());
      let path = Validation_common.canonical_import_path m.source_file in
      if path <> m.source_file then reject loc ("captured module path is not canonical: " ^ m.source_file);
      if Hashtbl.mem names_seen m.module_name || Hashtbl.mem paths_seen path then
        reject loc ("duplicate captured migration module: " ^ m.module_name);
      Hashtbl.add names_seen m.module_name m;
      Hashtbl.add paths_seen path source;
      (* Keep the supplied AST, including expression identity used by checked
         types and exact migration proof sites. Reparse only to verify the
         capture pairs those nodes with the claimed source bytes. *)
      match Parser.parse_module path source with
      | Ok parsed when parsed = m -> ()
      | Ok _ -> reject loc ("captured migration AST does not match source: " ^ path)
      | Err error -> reject error.loc error.msg) captured;
    let captured = List.sort (fun (a,_) (b,_) -> String.compare a.module_name b.module_name) captured in
    let forms = List.map fst captured in
    let sources = List.map (fun (m, source) -> m.source_file, source) captured |> List.sort compare in
    Source_input.with_pinned_files sources (fun () ->
      List.iter (fun m -> List.iter (fun (i : import_decl) ->
        if not (String.starts_with ~prefix:"Tesl." i.module_name) then
          match Hashtbl.find_opt names_seen i.module_name with
          | None -> reject i.loc ("uncaptured migration dependency: " ^ i.module_name)
          | Some owner ->
            let path = Validation_common.resolve_local_import_path m.source_file i.module_name
              |> Validation_common.canonical_import_path in
            if path <> owner.source_file then
              reject i.loc ("captured migration import resolves to another source: " ^ i.module_name)) m.imports) forms;
      (* Full public frontend validation and the typed-node pass see the same
         complete source view. The latter consumes the original captured AST,
         never one of the imported interface reparses. *)
      Query_cache.clear ();
      let globals = List.concat_map (fun m -> List.concat_map (fun d ->
        List.map (fun (ns,name) -> (ns,m.module_name ^ "." ^ name),
          Global (m.module_name ^ "." ^ name)) (names d)) m.decls) forms in
      let modules = List.map (fun (m, source) ->
        let diagnostics = Frontend_check.check_module ~skip_dep_body:(fun _ -> true) source m in
        (match List.find_opt (fun (d : Frontend_check.diagnostic) -> d.severity = "error") diagnostics with
         | Some error -> reject (Location.make_loc error.file error.start_line
             error.start_col error.end_line error.end_col) error.message
         | None -> ());
        let typed_nodes, errors = Checker.check_module_with_typed_nodes m in
        (match errors with error :: _ -> reject error.loc error.message | [] -> ());
        let local = List.concat_map (fun d -> List.map (fun (ns,name) ->
          (ns,name), Global (m.module_name ^ "." ^ name)) (names d)) m.decls in
        let imported = List.concat_map (fun (i : import_decl) ->
          match Hashtbl.find_opt names_seen i.module_name with
          | None -> []
          | Some owner -> List.concat_map (fun d -> List.filter_map (fun ((ns,name) as key) ->
              if wants i owner key then Some ((ns,name), Global (owner.module_name ^ "." ^ name))
              else None) (names d)) owner.decls) m.imports in
        let resolve ns name = match List.assoc_opt (ns,name) local with
          | Some _ as result -> result
          | None ->
            let candidates = List.filter_map (fun (key,symbol) ->
              if key = (ns,name) then Some symbol else None) imported |> List.sort_uniq compare in
            (match candidates with
             | [symbol] -> Some symbol
             | _ :: _ -> reject (Location.dummy_loc m.source_file) ("ambiguous semantic reference `" ^ name ^ "`")
             | [] -> match List.assoc_opt (ns,name) globals with
               | Some _ as result -> result
               | None -> builtin m ns name) in
        {form=m; typed_nodes; resolve}) captured in
      {modules; sources}))

let modules graph = List.map (fun m -> m.form) graph.modules
let source_texts graph = graph.sources
let resolve graph ~owner =
  match List.find_opt (fun m -> m.form.module_name = owner) graph.modules with
  | Some m -> m.resolve
  | None -> fun _ _ -> None

let lower ~scopes graph =
  let loc = Location.dummy_loc "<migration-checked-graph>" in
  protect loc (fun () ->
    List.concat_map (fun checked -> List.map (fun declaration ->
      match Migration_ir.define ~scopes ~resolve:checked.resolve
          ~typed_nodes:checked.typed_nodes checked.form declaration with
      | Ok definition -> definition
      | Error error -> raise (Invalid error)) checked.form.decls) graph.modules)
