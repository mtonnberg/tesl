type schema = {
  version : int;
  root_file : string;
  inventory : Migration_inventory.t;
}

type migration_source = {
  version : int;
  path : string;
  contents : string;
  source_digest : string;
}

type error_kind = Missing_source | Invalid_layout | Invalid_source | Changed_source
type error = { kind : error_kind; loc : Location.loc; message : string }
type t = {
  current : schema;
  frozen : schema list;
  completed_migrations : migration_source list;
  current_migration : migration_source option;
  source_inputs : (string * string) list;
  revision_directories : (string * (int * string) list) list;
  import_resolutions : (string * string * string) list;
}

let current history = history.current
let frozen history = history.frozen
let completed_migrations history = history.completed_migrations
let current_migration history = history.current_migration
let source_inputs history = history.source_inputs

exception Invalid of error
let reject ?(kind=Invalid_layout) path message =
  raise (Invalid {kind; loc=Location.dummy_loc path; message})

let require_regular path =
  match Unix.lstat path with
  | info when info.Unix.st_kind = Unix.S_REG && Unix.realpath path = path -> ()
  | _ -> reject path "schema history inputs must be canonical regular files"

let rec require_parent directory =
  match Unix.lstat directory with
  | info when info.Unix.st_kind = Unix.S_DIR && Unix.realpath directory = directory -> ()
  | _ -> reject directory "schema history directory is not canonical"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    require_parent (Filename.dirname directory)

(* Non-revision source files (for example migration tests) are not history roots.
   Digit-only spellings are recognized before validating their range, so V01 or
   an overflowing version cannot silently disappear from the history scan. *)
let file_version path name =
  let lower = String.lowercase_ascii name in
  if not (String.starts_with ~prefix:"v" lower && Filename.check_suffix lower ".tesl") then None
  else
    let digits = String.sub name 1 (String.length name - 6) in
    if digits = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') digits) then None
    else if name <> lower || not (Migration_source.valid_revision ("V" ^ digits)) then
      reject path "schema versions must be V1..V2147483646 without leading zeros"
    else Some (int_of_string digits)

let scan ~optional directory =
  match Unix.lstat directory with
  | info when info.Unix.st_kind = Unix.S_DIR && Unix.realpath directory = directory ->
    Sys.readdir directory |> Array.to_list |> List.filter_map (fun name ->
      let path = Filename.concat directory name in
      Option.map (fun version -> require_regular path; version, path) (file_version path name))
    |> List.sort compare
  | _ -> reject directory "schema history directory is not canonical"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) when optional ->
    require_parent (Filename.dirname directory); []

let protect anchor f =
  try Ok (f ()) with
  | Invalid error -> Error error
  | Failure message | Invalid_argument message | Sys_error message ->
    Error {kind=Invalid_source; loc=Location.dummy_loc anchor; message}
  | Unix.Unix_error (error, operation, path) ->
    Error {kind=(if error = Unix.ENOENT then Missing_source else Invalid_source); loc=Location.dummy_loc path;
      message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}

let check_inputs history =
  List.iter (fun (path, digest) ->
    require_regular path;
    if Migration_hash.digest (In_channel.with_open_bin path In_channel.input_all) <> digest then
      reject ~kind:Changed_source path "schema history source changed after it was read") history.source_inputs;
  List.iter (fun (source, name, expected) ->
    if Validation_common.resolve_local_import_path source name <> expected then
      reject ~kind:Changed_source source ("schema history import resolution changed: " ^ name)) history.import_resolutions;
  List.iter (fun (directory, entries) ->
    if scan ~optional:true directory <> entries then
      reject ~kind:Changed_source directory "schema history directory changed during discovery") history.revision_directories

let verify_unchanged history = protect history.current.root_file (fun () -> check_inputs history)

let discover ~compiler_abi ~project_root ~family =
  protect project_root (fun () ->
    if not (Migration_source.valid_family family) then
      reject project_root "invalid schema family";
    let root = Unix.realpath project_root in
    let module_path name = match Validation_common.schema_module_relative_path name with
      | Some path -> Filename.concat root path
      | None -> reject root ("invalid history module " ^ name) in
    let current_path = module_path (family ^ ".VCurrent") in
    let schema_dir = Filename.dirname current_path in
    let migration_dir = Filename.dirname (module_path (family ^ ".Migrate.V2")) in
    let snapshots = scan ~optional:false schema_dir in
    let migration_files = scan ~optional:true migration_dir in
    let current_version = match List.rev snapshots with
      | [] -> 1
      | (2147483646, path) :: _ -> reject path
          "VCurrent would use the reserved boot-fence version; no further schema revision can be allocated"
      | (version, _) :: _ -> version + 1 in
    let rec contiguous expected = function
      | [] -> ()
      | (version, path) :: rest ->
        if version <> expected then reject ~kind:Missing_source path
          (Printf.sprintf "missing frozen schema V%d; source history cannot be pruned without environment evidence" expected);
        contiguous (expected + 1) rest in
    contiguous 1 snapshots;
    List.iter (fun (version, path) ->
      if version < 2 || version > current_version then reject path
        (Printf.sprintf "migration V%d has no consecutive source/target schema pair" version)) migration_files;
    let sources = Hashtbl.create 32 in
    let parsed = Hashtbl.create 32 in
    let import_resolutions = ref [] in
    let read_module name =
      match Hashtbl.find_opt parsed name with
      | Some entry -> entry
      | None ->
        let path = module_path name in
        require_regular path;
        let contents = In_channel.with_open_bin path In_channel.input_all in
        let m = match Parser.parse_module path contents with
          | Ok m -> m
          | Err error -> raise (Invalid {kind=Invalid_source; loc=error.loc; message=error.msg}) in
        if m.module_name <> name then reject path ("history module must declare " ^ name);
        Hashtbl.add sources path (Migration_hash.digest contents);
        Hashtbl.add parsed name (m, contents);
        m, contents in
    let check_import source (imp : Ast.import_decl) =
      let expected = module_path imp.module_name in
      let resolved = Validation_common.resolve_local_import_path source imp.module_name in
      if resolved <> expected then reject resolved
        ("history import must resolve to its canonical module path: " ^ expected);
      import_resolutions := (source, imp.module_name, expected) :: !import_resolutions in
    let schema_modules = Hashtbl.create 32 in
    let rec visit_schema prefix name =
      if not (Hashtbl.mem schema_modules name) then begin
        Hashtbl.add schema_modules name ();
        let m, _ = read_module name in
        List.iter (fun (imp : Ast.import_decl) ->
          if String.starts_with ~prefix:"Tesl." imp.module_name then ()
          else if Migration_schema.within prefix imp.module_name then begin
            check_import m.source_file imp;
            visit_schema prefix imp.module_name
          end else reject ~kind:Invalid_source m.source_file
            ("schema import escapes its revision: " ^ imp.module_name)) m.imports
      end in
    let load_schema version revision path =
      let expected = family ^ "." ^ revision in
      visit_schema expected expected;
      match Migration_inventory.load ~compiler_abi ~root_file:path with
      | Error error -> raise (Invalid {kind=Invalid_source; loc=error.loc; message=error.message})
      | Ok inventory ->
        if Migration_inventory.root_module inventory <> expected then
          reject path ("history root must declare " ^ expected);
        let expected_paths = List.map module_path (Migration_inventory.module_names inventory)
          |> List.sort String.compare in
        let inputs = Migration_inventory.source_inputs inventory in
        if List.map fst inputs <> expected_paths then
          reject path "schema inventory resolved a noncanonical module path";
        List.iter (fun (source, digest) ->
          if Hashtbl.find_opt sources source <> Some digest then
            reject ~kind:Changed_source source "schema source changed during history discovery") inputs;
        {version; root_file=path; inventory} in
    let frozen = List.map (fun (version, path) -> load_schema version ("V" ^ string_of_int version) path) snapshots in
    let current = load_schema current_version "VCurrent" current_path in
    let migration_modules = Hashtbl.create 16 in
    let rec visit_migration name =
      if not (Hashtbl.mem migration_modules name) then begin
        Hashtbl.add migration_modules name ();
        let m, _ = read_module name in
        (match Migration_schema.check_databases m with
         | error :: _ -> raise (Invalid {kind=Invalid_source; loc=error.loc; message=error.message})
         | [] -> ());
        List.iter (fun (imp : Ast.import_decl) ->
          if String.starts_with ~prefix:"Tesl." imp.module_name then ()
          else begin
            check_import m.source_file imp;
            if Migration_schema.migration_family imp.module_name = Some family then
              visit_migration imp.module_name
            else if not (Hashtbl.mem schema_modules imp.module_name) then
              reject ~kind:Invalid_source m.source_file
                ("migration imports a schema module outside the discovered ownership closures: " ^ imp.module_name)
          end) m.imports
      end in
    let read_migration version path =
      let name = Printf.sprintf "%s.Migrate.V%d" family version in
      visit_migration name;
      let _, contents = read_module name in
      {version; path; contents; source_digest=Migration_hash.digest contents} in
    let migrations = List.map (fun (version, path) -> read_migration version path) migration_files in
    let find version = List.find_opt (fun (source : migration_source) -> source.version = version) migrations in
    let completed_migrations = List.filter_map (fun (schema : schema) ->
      if schema.version = 1 then None
      else match find schema.version with
        | Some source -> Some source
        | None -> let path = module_path (Printf.sprintf "%s.Migrate.V%d" family schema.version) in
          reject ~kind:Missing_source path (Printf.sprintf "missing completed migration V%d" schema.version)) frozen in
    let source_inputs = Hashtbl.to_seq sources |> List.of_seq |> List.sort compare in
    let history = {current; frozen; completed_migrations; current_migration=find current_version; source_inputs;
      import_resolutions=List.sort_uniq compare !import_resolutions;
      revision_directories=[schema_dir, snapshots; migration_dir, migration_files]} in
    check_inputs history;
    history)
