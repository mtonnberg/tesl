(** Direct schema queries see recorded source integrity even if the edited source
    no longer parses. Ownership comes from validated header paths, not from the
    edited module's spelling. The public compiler invokes this once at its entry;
    the inventory's base frontend never recursively checks its own seals. *)
module H = Migration_header
module E = Migration_sparse
exception Invalid of E.error list
let reject path message = raise (Invalid [{E.code="MIG013";loc=Location.dummy_loc path;message;related=[]}])
let get = function Ok value -> value | Error errors -> raise (Invalid errors)
let owned_scopes container file =
  let rec walk child directory result =
    let result = if Filename.basename directory = container && child <> "" then
      (Filename.dirname directory,Filename.basename child) :: result else result in
    let parent = Filename.dirname directory in
    if parent = directory then result else walk directory parent result in
  walk "" (Filename.dirname file) []
let scopes = owned_scopes "schema"

let check_schema_source ?(skip_headers=[]) ?(overlay=true) ?query_file ~file source =
  let query_file = Option.value query_file ~default:file in
  (* Retain an unfollowed spelling as well: replacing a recorded schema path
     with a symlink must not hide it by moving the query outside schema/. Only
     collapse '.', since collapsing '..' across a symlink changes its meaning. *)
  let absolute = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
  let rec literal path =
    let parent = Filename.dirname path in
    if parent = path then Some path else
    match Filename.basename path with
    | ".." -> None
    | "." -> literal parent
    | name -> Option.map (fun parent -> Filename.concat parent name) (literal parent) in
  let resolved = try Source_input.canonical_path file with Unix.Unix_error _ | Sys_error _ -> absolute in
  let candidates = List.sort_uniq compare (resolved :: Option.to_list (literal absolute)) in
  let scopes = List.concat_map (fun candidate -> List.map (fun (root,folder) ->
    let project_root = try Source_input.canonical_path root with Unix.Unix_error _ | Sys_error _ -> root in
    let suffix = String.sub candidate (String.length root) (String.length candidate - String.length root) in
    let suffix = if String.starts_with ~prefix:Filename.dir_sep suffix then
      String.sub suffix (String.length Filename.dir_sep) (String.length suffix - String.length Filename.dir_sep) else suffix in
    project_root,folder,Filename.concat project_root suffix) (scopes candidate)) candidates |> List.sort_uniq compare in
  List.concat_map (fun (project_root,folder,file) ->
    let directory = Filename.concat project_root (Filename.concat "migrations" folder) in
    try
      let entries = match Source_input.kind directory with
        | Unix.S_DIR when Source_input.realpath directory = directory -> Source_input.readdir directory
        | _ -> reject directory "migration history directory must be canonical"
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> [||] in
      let headers = entries |> Array.to_list |> List.sort compare |> List.filter_map (fun name ->
        let lower = String.lowercase_ascii name in
        if String.length lower < 7 || lower.[0] <> 'v' || not (Filename.check_suffix lower ".tesl") then None
        else
          let digits = String.sub lower 1 (String.length lower - 6) in
          if not (String.for_all (function '0'..'9' -> true | _ -> false) digits) then None
          else
            let path = Filename.concat directory name in
            if List.mem path skip_headers then None else begin
            if name <> lower || not (Migration_source.valid_revision ("V" ^ digits)) then
              reject path "migration roots must use canonical positive revision numbers";
            if Source_input.kind path <> Unix.S_REG || Source_input.realpath path <> path then
              reject path "migration history input must be a canonical regular file";
            match get (H.read ~file:path (Source_input.read path)) with
            | Some located ->
              let migration_module = H.module_name located in
              let expected = Filename.concat project_root
                (Option.get (Validation_common.schema_module_relative_path migration_module)) in
              if path <> expected then reject path "migration history header does not match its canonical module path";
              if H.mentions_file ~project_root ~file located then Some (migration_module,located) else None
            | None -> None end) in
      if headers = [] then [] else
        let overlay_root = Option.value (Source_input.project_root ()) ~default:project_root in
        let verify () =
          List.concat_map (fun (migration_module,located) ->
            let previous,current = H.roots located in
            match H.verify ~project_root ~migration_module ~previous ~current located with
            | Ok _ -> [] | Error errors -> errors) headers in
        let regular = try Source_input.kind file = Unix.S_REG && Source_input.realpath file = file with
          | Unix.Unix_error (Unix.ENOENT, _, _) -> true (* an unsaved created file *)
          | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> false in
        if overlay && regular then Source_input.with_overlays ~project_root:overlay_root [file,source] verify
        else verify ()
    with
    | Invalid errors -> errors
    | Sys_error message | Failure message | Invalid_argument message ->
      [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}]
    | Unix.Unix_error (error,operation,path) ->
      [{E.code="MIG013";loc=Location.dummy_loc path;
        message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error);related=[]}]) scopes
  |> List.map (fun (error : E.error) ->
    (* The compact agent-context schema carries positions in the queried file.
       Anchor its direct integrity failure there and retain the recorded header
       as related information, also useful to an editor opening the source. *)
    let related = if error.loc.file = query_file then error.related else
      (error.loc,"recorded history") :: error.related in
    {error with loc=Location.dummy_loc query_file;related})

(* Importers check each reachable revision once, including private-only imports.
   Derive ownership from paths so a changed module header cannot conceal a seal.
   Migration declarations in the graph already check their own actual buffer via
   the frontend callback; never re-read those headers from disk here. *)
let revision_roots file =
  List.filter_map (fun (root,folder) ->
    let directory = Filename.concat root (Filename.concat "schema" folder) in
    let relative = String.sub file (String.length directory + 1)
      (String.length file - String.length directory - 1) in
    let component = List.hd (String.split_on_char '/' relative) in
    let stem = if Filename.check_suffix component ".tesl" then Filename.chop_suffix component ".tesl" else component in
    if stem = "v-current" ||
       (String.length stem > 1 && stem.[0] = 'v' &&
        Migration_source.valid_revision ("V" ^ String.sub stem 1 (String.length stem - 1))) then
      Some (Filename.concat directory (stem ^ ".tesl")) else None) (scopes file)

let is_migration_root file =
  let stem = Filename.basename file in
  Filename.basename (Filename.dirname (Filename.dirname file)) = "migrations" &&
  Filename.check_suffix stem ".tesl" && String.length stem > 6 && stem.[0] = 'v' &&
  Migration_source.valid_revision ("V" ^ String.sub stem 1 (String.length stem - 6))

(* Private migration queries must see the root's recorded raw closure even
   when the edited helper is no longer parseable or declares a different name. *)
let check_closure_source ?(skip_roots=[]) ?(overlay=true) ?query_file ~file source =
  let query_file = Option.value query_file ~default:file in
  let absolute = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
  let resolved = try Source_input.canonical_path file with Unix.Unix_error _ | Sys_error _ -> absolute in
  let candidates = List.sort_uniq compare [absolute;resolved] in
  List.concat_map (fun file ->
    List.concat_map (fun (project_root,folder) ->
      let directory = Filename.concat project_root (Filename.concat "migrations" folder) in
      let verify () =
        let entries = match Source_input.kind directory with
          | Unix.S_DIR when Source_input.realpath directory=directory -> Source_input.readdir directory
          | _ -> reject directory "migration history directory must be canonical" in
        Array.to_list entries |> List.sort String.compare |> List.concat_map (fun name ->
          let root_file = Filename.concat directory name in
          if not (is_migration_root root_file) || List.mem root_file skip_roots then [] else begin
            if Source_input.kind root_file <> Unix.S_REG || Source_input.realpath root_file <> root_file then
              reject root_file "migration history root must be a canonical regular file";
            let root_source = Source_input.read root_file in
            match get (Migration_closure.read ~file:root_file root_source) with
            | None ->
              let frozen_schema = Filename.concat project_root (Filename.concat "schema" (Filename.concat folder name)) in
              if Source_input.exists frozen_schema then
                reject root_file "completed migration source is missing its frozen closure metadata";
              []
            | Some located when
                Option.map (Filename.concat project_root)
                  (Validation_common.schema_module_relative_path (Migration_closure.root located)) <> Some root_file ->
              reject root_file "frozen migration metadata does not match its canonical root path"
            | Some located ->
              (* Validate membership before trusting it to select a query. A
                 removed helper entry must not hide that helper from checking. *)
              (match Migration_closure.verify ~project_root ~root_file ~source:root_source located with
               | Ok () -> [] | Error errors -> errors) end) in
      try
        let regular = try Source_input.kind file=Unix.S_REG && Source_input.realpath file=file with
          | Unix.Unix_error (Unix.ENOENT,_,_) -> true
          | Unix.Unix_error _ | Sys_error _ -> false in
        if overlay && regular then
          Source_input.with_overlays ~project_root:(Option.value (Source_input.project_root ()) ~default:project_root) [file,source] verify
        else verify ()
      with
      | Invalid errors -> errors
      | Sys_error message | Failure message | Invalid_argument message ->
        [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}]
      | Unix.Unix_error (error,operation,path) ->
        [{E.code="MIG013";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
    ) (owned_scopes "migrations" file)) candidates
  |> List.map (fun (error : E.error) ->
    {error with loc=Location.dummy_loc query_file;
      related=(if error.loc.file=query_file then error.related else (error.loc,"recorded migration closure")::error.related)})
  |> List.sort_uniq compare

let check_source ?(skip_headers=[]) ?(overlay=true) ?query_file ~file source =
  check_schema_source ~skip_headers ~overlay ?query_file ~file source @
  check_closure_source ~skip_roots:(if is_migration_root file then skip_headers else []) ~overlay ?query_file ~file source

let check_module_source source (m : Ast.module_form) =
  let graph = Frontend_check.build_local_import_graph ~entry:m m.source_file in
  let files = Hashtbl.fold (fun path _ paths -> path :: paths) graph [] |> List.sort compare in
  let skip_headers = List.filter is_migration_root files in
  let entry_roots = revision_roots (Source_input.canonical_path m.source_file) in
  let roots = List.concat_map revision_roots files |> List.sort_uniq compare
    |> List.filter (fun root -> not (List.mem root entry_roots)) in
  let direct = check_source ~skip_headers ~file:m.source_file source in
  (* No synthetic root buffer: a private-only import must still reject a missing
     or non-regular recorded root. Seal verification checks kinds before reads. *)
  let imported = List.concat_map (fun file ->
    check_source ~skip_headers ~overlay:false ~query_file:m.source_file ~file "") roots in
  let migration_imports = List.filter (fun file -> file <> Source_input.canonical_path m.source_file && owned_scopes "migrations" file <> []) files in
  let closures = List.concat_map (fun file -> check_closure_source ~skip_roots:skip_headers
    ~overlay:false ~query_file:m.source_file ~file "") migration_imports in
  List.sort_uniq compare (direct @ imported @ closures)
