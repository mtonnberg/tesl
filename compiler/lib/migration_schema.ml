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

type binding = {
  database : database_form;
  schema_root : string;
  migration_prefix : string;
  members : (string * entity_form) list;
}

(** Contextual module references have no expression type. This resolver consumes
    the original folded database configuration and returns an ownership projection;
    it never changes what declarations the application can use in expressions.
    Supplying a parsed graph lets editor overlays take precedence over disk. *)
let resolve_binding ?(modules = []) (m : module_form) (d : database_form) =
  let fields = match d.config_expr with
    | Some e -> Desugar.config_record_fields e | None -> [] in
  match List.assoc_opt "schema" fields with
  | Some (EConstructor { name = root; args = []; loc }) ->
    let error message = Error [make_error loc message] in
    (match String.split_on_char '.' root, schema_prefix root with
     | [family; "VCurrent"], Some prefix when prefix = root ->
       let expected_migrations = family ^ ".Migrate" in
       let migrations = match List.assoc_opt "migrations" fields with
         | Some (EConstructor { name; args = []; _ }) -> Some name | _ -> None in
       if List.mem_assoc "entities" fields then
         error "a schema module owns its complete entity closure; remove `entities:` from this database"
       else if migrations <> Some expected_migrations then
         error (Printf.sprintf "schema `%s` requires `migrations: %s`" root expected_migrations)
       else if not (List.exists (fun (i : import_decl) -> i.module_name = root) m.imports) then
         error (Printf.sprintf "schema module `%s` must be imported directly by the database's application module" root)
       else
         let visited = Hashtbl.create 8 in
         let members = ref [] and errors = ref [] in
         let rec visit source name =
           if not (Hashtbl.mem visited name) then begin
             Hashtbl.add visited name ();
             let path = resolve_local_import_path source name in
             let parsed = match List.find_opt (fun (candidate : module_form) ->
               canonical_import_path candidate.source_file = canonical_import_path path) modules with
               | Some candidate -> Some candidate
               | None -> read_module path in
             match parsed with
             | None -> errors := make_error loc (Printf.sprintf "cannot read schema module `%s`" name) :: !errors
             | Some schema when schema.module_name <> name ->
               errors := make_error loc (Printf.sprintf "schema module `%s` resolves to a file declaring `%s`" name schema.module_name) :: !errors
             | Some schema ->
               errors := List.rev_append (check_contents schema) !errors;
               List.iter (function DEntity e -> members := (name ^ "." ^ e.name, e) :: !members | _ -> ()) schema.decls;
               List.iter (fun (i : import_decl) ->
                 if String.starts_with ~prefix:"Tesl." i.module_name then ()
                 else if within root i.module_name then visit schema.source_file i.module_name
                 else errors := make_error i.loc (Printf.sprintf "schema module `%s` imports `%s` outside its ownership closure" name i.module_name) :: !errors) schema.imports
           end
         in
         visit m.source_file root;
         let members = List.sort (fun (left, _) (right, _) -> String.compare left right) !members in
         (* Storage validation sees the whole ownership projection, not only the
            declarations an application chose to expose. This also detects index
            names shared by entities in different private modules. *)
         errors := List.rev_append (Validation_structural.check_entity_structure
           (List.map (fun (name, entity) -> DEntity { entity with name }) members)) !errors;
         let tables = Hashtbl.create 8 in
         List.iter (fun (name, (e : entity_form)) ->
           match Hashtbl.find_opt tables e.table with
           | Some previous -> errors := make_error e.loc (Printf.sprintf "schema entities `%s` and `%s` name the same physical table `%s`" previous name e.table) :: !errors
           | None -> Hashtbl.add tables e.table name) members;
         if !errors <> [] then Error (List.rev !errors)
         else Ok (Some { database = d; schema_root = root; migration_prefix = expected_migrations; members })
     | _ -> error "`Database.schema` must name an imported `FamilySchema.VCurrent` root, not a frozen version or child module")
  | _ -> Ok None

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
          let storage_errors = match root_module with
            | Some current when current.source_file = m.source_file -> [] (* Already checked by the local validation pass. *)
            | _ -> Validation_structural.check_entity_structure m.decls in
          header_errors @ check_contents m @ storage_errors @ List.concat_map (fun (imp : import_decl) ->
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
       | Some (EConstructor { args = []; _ }) -> [] (* The contextual resolver checks the complete closure below. *)
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
  @ List.concat_map (function
      | DDatabase d -> (match resolve_binding m d with Error errors -> errors | Ok _ -> [])
      | _ -> []) m.decls

(** Only the backend receives this projection. Source checking keeps the original
    import/export visibility and folded config, so private membership grants no
    ordinary term or type names. Run before SCC lowering and rename these entity
    references along with their declarations. *)
let lower_module ?(modules = []) (m : module_form) =
  let errors = ref [] in
  let decls = List.map (function
    | DDatabase d as original -> (match resolve_binding ~modules m d with
        | Ok (Some binding) ->
          let d = Desugar.desugar_database_config d in
          DDatabase { d with entities = List.map fst binding.members }
        | Ok None -> original
        | Error es -> errors := List.rev_append es !errors; original)
    | other -> other) m.decls in
  if !errors = [] then Ok { m with decls } else Error (List.rev !errors)

let database_entities (m : module_form) =
  List.filter_map (function
    | DDatabase d ->
      let names = match resolve_binding m d with
        | Ok (Some binding) ->
          List.concat_map (fun (qualified, (e : entity_form)) ->
            qualified :: List.filter_map (fun (i : import_decl) ->
              if i.module_name ^ "." ^ e.name <> qualified then None
              else match i.names with
                | ImportExposing names when List.mem e.name names -> Some e.name
                | _ -> None) m.imports) binding.members
        | _ -> (Desugar.desugar_database_config d).entities in
      Some (d.name, names)
    | _ -> None) m.decls

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
