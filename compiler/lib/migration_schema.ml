(** Schema-content checks apply to every schema module, including editor buffers,
    and follow database ownership rather than exports.
    Connection configuration and application effects never enter a frozen closure.
    The explicit module-reference form is consumed here contextually. During the
    legacy Database.entities transition, a named entity imported from a schema
    family selects that same boundary. Ordinary application modules are unaffected. *)
open Ast
open Validation_common

let schema_prefix name =
  match schema_module_relative_path name, String.split_on_char '.' name with
  | Some path, family :: revision :: _ when String.starts_with ~prefix:"schema/" path ->
    Some (family ^ "." ^ revision)
  | _ -> None

let within prefix name = name = prefix || String.starts_with ~prefix:(prefix ^ ".") name

let migration_family name =
  match schema_module_relative_path name, String.split_on_char '.' name with
  | Some path, family :: "Migrate" :: _ when String.starts_with ~prefix:"migrations/" path -> Some family
  | _ -> None

let read_module path =
  try match Parser.parse_module path (In_channel.with_open_text path In_channel.input_all) with
    | Ok m -> Some m | Err _ -> None
  with Sys_error _ -> None

let check_contents ?(migration = false) (m : module_form) =
  let forbidden loc what = make_error loc
    (Printf.sprintf "%s modules cannot contain %s; keep connection configuration, application operations and tests outside the frozen import closure"
       (if migration then "migration" else "schema") what) in
  let func_caps = build_func_capability_map m.decls in
  List.concat_map (function
    | DType _ | DRecord _ | DFact _ | DCodec _ -> []
    | DEntity e -> if migration then [forbidden e.loc "entity declarations (declare them in the schema)"] else []
    | DFunc fd ->
      (match fd.kind with
       | FnKind | CheckKind | EstablishKind ->
         let needed = collect_needed_capabilities ~func_caps
           ~param_caps:(build_param_capability_map fd)
           ~bound:(List.map (fun (b : binding) -> b.name) fd.params) fd.body in
         if fd.capabilities = [] && needed = [] then []
         else [forbidden fd.loc "capabilities or effectful functions"]
       | HandlerKind | WorkerKind | DeadWorkerKind | MainKind | AuthKind ->
         [forbidden fd.loc "handlers, workers, main or auth functions"])
    | DDatabase d -> [forbidden d.loc "database declarations"]
    | DCapability c -> [forbidden c.loc "capability declarations"]
    | DConst c ->
      if migration then
        let needed = collect_needed_capabilities ~func_caps ~param_caps:[] ~bound:[] c.value in
        if needed = [] then [] else [forbidden c.loc "effectful constants"]
      else [forbidden c.loc "application constants (use pure schema helper functions)"]
    | (DQueue _ | DChannel _ | DWorkers _ | DCache _ | DAgent _ | DEmail _
      | DCapture _ | DApi _ | DServer _ | DTest _ | DApiTest _ | DLoadTest _) as d ->
      [forbidden (top_decl_loc d) "application declarations or tests"]
  ) m.decls

let check_closure ?root_module ~source_file root =
  match schema_prefix root with
  | None -> []
  | Some prefix ->
    let visited = Hashtbl.create 16 in
    let rec visit source name =
      let path = resolve_local_import_path source name in
      let key = canonical_import_path path in
      if Hashtbl.mem visited key then []
      else begin
        Hashtbl.add visited key ();
        let parsed = match root_module with
          | Some m when m.module_name = name -> Some m
          | _ -> read_module path in
        match parsed with
        | None -> [] (* Ordinary import checking reports missing or invalid source. *)
        | Some m ->
          let header_errors = if m.module_name = name then [] else
            [make_error (Location.dummy_loc path) (Printf.sprintf
               "schema module `%s` resolves to a file declaring `%s`" name m.module_name)] in
          header_errors @ check_contents m @ List.concat_map (fun (imp : import_decl) ->
            if String.starts_with ~prefix:"Tesl." imp.module_name then []
            else if within prefix imp.module_name then visit m.source_file imp.module_name
            else [make_error imp.loc (Printf.sprintf
              "schema module `%s` may import only `%s` and its children or Tesl.*; `%s` is outside the schema closure"
              name prefix imp.module_name)]) m.imports
      end
    in visit source_file root

let check_databases (m : module_form) =
  match migration_family m.module_name with
  | Some family ->
    check_contents ~migration:true m @ List.filter_map (fun (imp : import_decl) ->
      let owned = match schema_prefix imp.module_name, migration_family imp.module_name with
        | Some prefix, _ -> within family prefix
        | _, Some imported_family -> imported_family = family
        | _ -> false in
      if owned || String.starts_with ~prefix:"Tesl." imp.module_name then None
      else Some (make_error imp.loc (Printf.sprintf
        "migration module `%s` may import only its `%s` schema/migration family or Tesl.*; `%s` is outside frozen ownership"
        m.module_name family imp.module_name))) m.imports
  | None -> if schema_prefix m.module_name <> None then
    check_closure ~root_module:m ~source_file:m.source_file m.module_name
  else
  let roots = List.concat_map (function
    | DDatabase d ->
      let fields = match d.config_expr with Some e -> Desugar.config_record_fields e | None -> [] in
      (match List.assoc_opt "schema" fields with
       | Some (EConstructor { name; args = []; _ }) -> [name]
       | _ ->
         let entities = (Desugar.desugar_database_config d).entities in
         List.filter_map (fun (imp : import_decl) ->
           if schema_prefix imp.module_name = None then None
           else match read_module (resolve_local_import_path m.source_file imp.module_name) with
             | Some imported when List.exists (function
                 | DEntity e -> List.mem e.name entities || List.mem (imp.module_name ^ "." ^ e.name) entities
                 | _ -> false) imported.decls -> Some imp.module_name
             | _ -> None) m.imports)
    | _ -> []) m.decls |> List.sort_uniq String.compare in
  List.concat_map (check_closure ~source_file:m.source_file) roots

(** Ownership is a project property, independent of which entrypoint imports a
    database declaration or which individual entities it exposes. During source
    migration from Database.entities, selecting any entity from a versioned family
    already selects that family's ownership boundary. Use the parsed project graph,
    including the entry's overlay, rather than reopening its source from disk. *)
let check_ownership (modules : module_form list) =
  let owners = Hashtbl.create 8 in
  List.concat_map (fun (m : module_form) ->
    List.concat_map (function
      | DDatabase original ->
        let fields = match original.config_expr with
          | Some e -> Desugar.config_record_fields e | None -> [] in
        let roots = match List.assoc_opt "schema" fields with
          | Some (EConstructor {name; args=[]; _}) ->
            (match schema_prefix name with Some root -> [root] | None -> [])
          | _ ->
            let d = Desugar.desugar_database_config original in
            List.concat_map (resolve_project_entity modules m) d.entities
            |> List.filter_map schema_prefix in
        let roots = List.sort_uniq String.compare roots in
        let frozen = List.filter (fun root -> not (String.ends_with ~suffix:".VCurrent" root)) roots in
        let error message = make_error ~topic:Error_codes.TDatabase original.loc message in
        let owner = m.module_name ^ "." ^ original.name in
        if frozen <> [] then
          [error (Printf.sprintf "database `%s` cannot bind historical schema `%s`; frozen entities are migration input records, and application connections must select VCurrent"
                    owner (String.concat ", " frozen))]
        else if List.length roots > 1 then
          [error (Printf.sprintf "database `%s` cannot combine schema families `%s`; each database owns exactly one schema family"
                    owner (String.concat ", " roots))]
        else List.filter_map (fun root ->
          match Hashtbl.find_opt owners root with
          | None -> Hashtbl.add owners root owner; None
          | Some previous when previous = owner -> None
          | Some previous -> Some (error (Printf.sprintf
              "schema family `%s` belongs to two databases (`%s` and `%s`); keep one application connection owner for the whole schema import closure"
              root previous owner))) roots
      | _ -> []) m.decls) modules
