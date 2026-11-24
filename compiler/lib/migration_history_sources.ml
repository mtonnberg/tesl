(* [loaded] is forced at discovery unless the schema is covered by a trusted
   seal of a later completed migration (Migration_trust): then the same compiler
   already checked exactly these bytes, and only callers that need the
   inventory pay for loading it. *)
type schema = {
  version : int;
  root_file : string;
  loaded : Migration_inventory.t Lazy.t;
}
let inventory schema = Lazy.force schema.loaded

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
  contracts : migration_source list;
  contract_directory : (string * (int * string) list) option;
  source_inputs : (string * string) list;
  revision_directories : (string * (int * string) list) list;
  import_resolutions : (string * string * string) list;
  (* Every module discovery read, with its parse facts. *)
  modules : (string * Migration_module_facts.t) list;
  (* The verified summary of the frozen history this discovery used, if any. *)
  summary : Migration_history_summary.t option;
}

let current history = history.current
let frozen history = history.frozen
let completed_migrations history = history.completed_migrations
let current_migration history = history.current_migration
let contracts history = history.contracts
let source_inputs history = history.source_inputs
let modules history = history.modules
let summary history = history.summary

exception Invalid of error
let reject ?(kind=Invalid_layout) path message =
  raise (Invalid {kind; loc=Location.dummy_loc path; message})

let require_regular path =
  match Source_input.kind path with
  | Unix.S_REG when Source_input.realpath path = path -> ()
  | _ -> reject path "schema history inputs must be canonical regular files"

let rec require_parent directory =
  match Source_input.kind directory with
  | Unix.S_DIR when Source_input.realpath directory = directory -> ()
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
  match Source_input.kind directory with
  | Unix.S_DIR when Source_input.realpath directory = directory ->
    Source_input.readdir directory |> Array.to_list |> List.filter_map (fun name ->
      let path = Filename.concat directory name in
      Option.map (fun version -> require_regular path; version, path) (file_version path name))
    |> List.sort compare
  | _ -> reject directory "schema history directory is not canonical"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) when optional ->
    require_parent (Filename.dirname directory); []

let contract_file_version path name =
  let suffix = "-contract.tesl" in
  let lower = String.lowercase_ascii name in
  if not (Filename.check_suffix lower suffix && String.starts_with ~prefix:"v" lower) then None
  else
    let revision=String.sub name 0 (String.length name-String.length suffix) in
    let digits=String.sub revision 1 (String.length revision-1) in
    if digits="" || not (String.for_all (fun c -> c>='0' && c<='9') digits) then None
    else if name<>lower then reject path "contract files must use canonical lowercase v<n>-contract.tesl spelling"
    else file_version path (revision ^ ".tesl")
let scan_contracts directory =
  match Source_input.kind directory with
  | Unix.S_DIR when Source_input.realpath directory=directory ->
    Source_input.readdir directory |> Array.to_list |> List.filter_map(fun name ->
      let path=Filename.concat directory name in
      Option.map(fun version -> require_regular path;version,path) (contract_file_version path name)) |> List.sort compare
  | _ -> reject directory "contract history directory is not canonical"
  | exception Unix.Unix_error(Unix.ENOENT,_,_) -> require_parent(Filename.dirname directory);[]

let protect anchor f =
  try Ok (f ()) with
  | Invalid error -> Error error
  | Failure message | Invalid_argument message | Sys_error message ->
    Error {kind=Invalid_source; loc=Location.dummy_loc anchor; message}
  | Unix.Unix_error (error, operation, path) ->
    Error {kind=(if error = Unix.ENOENT then Missing_source else Invalid_source); loc=Location.dummy_loc path;
      message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}

let check_inputs history =
  (* Inputs a summary still verified in this view covers are unchanged. *)
  let covered = match Option.bind history.summary Migration_history_summary.current with
    | Some s -> Migration_history_summary.covers s
    | None -> fun _ -> None in
  Option.iter (fun (directory,entries) -> if scan_contracts directory<>entries then
    reject ~kind:Changed_source directory "contract directory changed during discovery") history.contract_directory;
  List.iter (fun (path, digest) -> if covered path <> Some digest then begin
    require_regular path;
    if Migration_hash.digest (Source_input.read path) <> digest then
      reject ~kind:Changed_source path "schema history source changed after it was read" end) history.source_inputs;
  List.iter (fun (source, name, expected) ->
    if (covered source = None || covered expected = None) &&
       Validation_common.resolve_local_import_path source name <> expected then
      reject ~kind:Changed_source source ("schema history import resolution changed: " ^ name)) history.import_resolutions;
  List.iter (fun (directory, entries) ->
    if scan ~optional:true directory <> entries then
      reject ~kind:Changed_source directory "schema history directory changed during discovery") history.revision_directories

(* Within one compilation scope, while disk answers are memoized, every
   observation [check_inputs] makes gets the answer it got before under the
   same source view and disk epoch: a history checked there holds again. A
   final guard observes disk anew (Migration_manifest, Source_input.disk_changed). *)
let checked_views : (t * Source_input.view_token) list ref = ref []
let () = Source_input.on_scope_exit (fun () -> checked_views := [])
let verify_unchanged history = protect history.current.root_file (fun () ->
  let memoizing = Source_input.memoizing () in
  if not (memoizing && List.exists (fun (h,token) -> h == history && Source_input.same_view token) !checked_views) then begin
    check_inputs history;
    if memoizing then checked_views := (history,Source_input.view_token ()) :: List.filteri (fun i _ -> i < 31) !checked_views
  end)

(* What [inspect] needs to rebuild its result for another stored-value label
   or without migrations, without discovering again (see [inspect] below). *)
type core = { full : t; specs : (int * string * string * bool) list;
  schema_inputs : (string * string) list; schema_imports : (string * string * string) list;
  loader : string -> string option -> string -> string -> Migration_inventory.t }

let inspect_with ~capture ~stored_value_compatibility ~include_migrations ~compiler_abi ~project_root ~family =
  protect project_root (fun () ->
    if not (Migration_source.valid_family family) then
      reject project_root "invalid schema family";
    let root = Source_input.realpath project_root in
    let module_path name = match Validation_common.schema_module_relative_path name with
      | Some path -> Filename.concat root path
      | None -> reject root ("invalid history module " ^ name) in
    let current_path = module_path (family ^ ".VCurrent") in
    let schema_dir = Filename.dirname current_path in
    let migration_dir = Filename.dirname (module_path (family ^ ".Migrate.V2")) in
    let snapshots = scan ~optional:false schema_dir in
    let migration_files = scan ~optional:true migration_dir in
    let contract_files = if include_migrations then scan_contracts migration_dir else [] in
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
    (* The newest checkpoint's summary of the frozen history, when its digest
       still holds in this view with this revision current: the frozen modules
       it covers are taken from it instead of being read, parsed, and their
       imports resolved again (Migration_history_summary). *)
    let summary = match Migration_history_summary.find ~project_root:root ~family with
      | Some s when Migration_history_summary.through s < current_version -> Some s
      | _ -> None in
    let summary_digest path = match summary with Some s -> Migration_history_summary.covers s path | None -> None in
    let summarized path = match summary with Some s -> Migration_history_summary.facts s path | None -> None in
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
        match summary_digest path, summarized path with
        | Some digest, Some facts ->
          if facts.Migration_module_facts.module_name <> name then reject path ("history module must declare " ^ name);
          let entry = Migration_closure.Recorded facts, lazy (Source_input.read path) in
          Hashtbl.add sources path digest;
          Hashtbl.add parsed name entry;
          entry
        | _ ->
        require_regular path;
        let contents = Source_input.read path in
        (* Recorded parse facts of a frozen module's bytes stand for its parse
           (Migration_module_facts); other modules are parsed. *)
        let m = match Migration_closure.source_facts ~file:path contents with
          | Ok m -> m
          | Error error -> raise (Invalid {kind=Invalid_source; loc=error.loc; message=error.msg}) in
        if (Migration_closure.parsed_facts m).module_name <> name then reject path ("history module must declare " ^ name);
        Hashtbl.add sources path (Migration_hash.digest contents);
        Hashtbl.add parsed name (m, Lazy.from_val contents);
        m, Lazy.from_val contents in
    let imports m = (Migration_closure.parsed_facts m).Migration_module_facts.imports in
    let check_import source imported =
      let expected = module_path imported in
      (* Between summarized modules the summary's digest fixes resolution. *)
      if summary_digest source = None || summary_digest expected = None then begin
        let resolved = Validation_common.resolve_local_import_path source imported in
        if resolved <> expected then reject resolved
          ("history import must resolve to its canonical module path: " ^ expected)
      end;
      import_resolutions := (source, imported, expected) :: !import_resolutions in
    let schema_modules = Hashtbl.create 32 in
    let rec visit_schema prefix name =
      if not (Hashtbl.mem schema_modules name) then begin
        Hashtbl.add schema_modules name ();
        let m, _ = read_module name in
        let source_file = module_path name in
        List.iter (fun imported ->
          if String.starts_with ~prefix:"Tesl." imported then ()
          else if Migration_schema.within prefix imported then begin
            check_import source_file imported;
            visit_schema prefix imported
          end else reject ~kind:Invalid_source source_file
            ("schema import escapes its revision: " ^ imported)) (imports m)
      end in
    let specs = ref [] in
    let load_inventory compiler_abi stored_value_compatibility expected path =
      match Migration_inventory.load_with_compatibility ~stored_value_compatibility ~compiler_abi ~root_file:path with
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
        inventory in
    let load_schema ?(defer=false) version revision path =
      let expected = family ^ "." ^ revision in
      visit_schema expected expected;
      specs := (version,expected,path,defer) :: !specs;
      let load () = load_inventory compiler_abi stored_value_compatibility expected path in
      let loaded = if capture<>None then lazy (invalid_arg "history core schemas are rebuilt before use")
        else if defer then lazy (try load () with Invalid error -> failwith error.message)
        else Lazy.from_val (load ()) in
      {version; root_file=path; loaded} in
    let compiler = lazy (Migration_trust.current_compiler ()) in
    let covered version =
      (* V<n> is covered by the previous-schema seal of completed V<n+1>. *)
      not (Migration_trust.full_history ()) && version+1 < current_version &&
      let file = module_path (Printf.sprintf "%s.Migrate.V%d" family (version+1)) in
      (try Migration_trust.edge ~project_root:root ~compiler:(Lazy.force compiler) ~file ~source:(Source_input.read file) <> None
       with Sys_error _ | Unix.Unix_error _ -> false) in
    (* Coverage first: the covering migration's verified checkpoint supplies
       the parse facts of the schema's modules. *)
    let frozen = List.map (fun (version, path) ->
      let defer = covered version in
      load_schema ~defer version ("V" ^ string_of_int version) path) snapshots in
    let current = load_schema current_version "VCurrent" current_path in
    let schema_inputs = Hashtbl.to_seq sources |> List.of_seq |> List.sort compare in
    let schema_imports = List.sort_uniq compare !import_resolutions in
    let migration_modules = Hashtbl.create 16 in
    let rec visit_migration name =
      if not (Hashtbl.mem migration_modules name) then begin
        Hashtbl.add migration_modules name ();
        let m, _ = read_module name in
        let source_file = module_path name in
        (* Recorded facts belong to a frozen closure whose bytes passed this
           check when the revision was frozen. *)
        (match m with
         | Migration_closure.Recorded _ -> ()
         | Migration_closure.Parsed m -> match Migration_schema.check_databases m with
           | error :: _ -> raise (Invalid {kind=Invalid_source; loc=error.loc; message=error.message})
           | [] -> ());
        List.iter (fun imported ->
          if String.starts_with ~prefix:"Tesl." imported then ()
          else begin
            check_import source_file imported;
            if Migration_schema.migration_family imported = Some family then
              visit_migration imported
            else if not (Hashtbl.mem schema_modules imported) then
              reject ~kind:Invalid_source source_file
                ("migration imports a schema module outside the discovered ownership closures: " ^ imported)
          end) (imports m)
      end in
    let read_migration version path =
      let name = Printf.sprintf "%s.Migrate.V%d" family version in
      visit_migration name;
      let _, contents = read_module name in
      let contents = Lazy.force contents in
      {version; path; contents; source_digest=Option.value (summary_digest path) ~default:(Migration_hash.digest contents)} in
    let migrations = if include_migrations then List.map (fun (version, path) -> read_migration version path) migration_files else [] in
    let find version = List.find_opt (fun (source : migration_source) -> source.version = version) migrations in
    let completed_migrations = if not include_migrations then [] else List.filter_map (fun (schema : schema) ->
      if schema.version = 1 then None
      else match find schema.version with
        | Some source -> Some source
        | None -> let path = module_path (Printf.sprintf "%s.Migrate.V%d" family schema.version) in
          reject ~kind:Missing_source path (Printf.sprintf "missing completed migration V%d" schema.version)) frozen in
    let contracts=List.map(fun (version,path) ->
      if version<2 || version>current_version || find version=None then reject path "contract requires its exact existing migration";
      let name=Printf.sprintf "%s.Migrate.V%dContract" family version in
      visit_migration name;
      let _,contents=read_module name in
      let contents=Lazy.force contents in
      {version;path;contents;source_digest=Option.value (summary_digest path) ~default:(Migration_hash.digest contents)}) contract_files in
    let source_inputs = Hashtbl.to_seq sources |> List.of_seq |> List.sort compare in
    let history = {current; frozen; completed_migrations; current_migration=find current_version; contracts;
      contract_directory=(if include_migrations then Some(migration_dir,contract_files) else None); source_inputs;
      import_resolutions=List.sort_uniq compare !import_resolutions;
      revision_directories=[schema_dir, snapshots; migration_dir, migration_files];
      modules=Hashtbl.fold (fun name (m,_) acc -> (module_path name,Migration_closure.parsed_facts m) :: acc) parsed [] |> List.sort compare;
      summary} in
    check_inputs history;
    Option.iter (fun capture -> capture := Some {full=history;specs=List.rev !specs;schema_inputs;schema_imports;
      loader=load_inventory}) capture;
    history)


type history_cache_key = string option * bool * string * string * string * (string * string) list
type history_cache = { entries : (history_cache_key, t) Hashtbl.t; mutable weight : int;
  verified : (history_cache_key, Source_input.view_token) Hashtbl.t }
type core_entry = { core : core; reads : Source_input.observation list; views : (string * string option * bool, t) Hashtbl.t;
  loads : (string * string option * string, Migration_inventory.t) Hashtbl.t;
  mutable verified_views : Source_input.view_token list }
type core_key = string * string * (string * string) list * bool
let cores : (core_key, core_entry) Hashtbl.t = Hashtbl.create 4
let active_cache : history_cache option ref = ref None
let with_cache f = match !active_cache with
 | Some _ -> f ()
 | None ->
   active_cache := Some {entries=Hashtbl.create 8;weight=0;verified=Hashtbl.create 8};
   Fun.protect ~finally:(fun () -> active_cache := None; Hashtbl.reset cores) f
let stdlib_inputs () =
 try Some (List.map (fun (name,_) ->
   match Validation_common.lifted_stdlib_source_path name with
   | None -> raise Not_found
   | Some path -> path,Source_input.read path) Validation_common.lifted_stdlib_sources)
 with Not_found | Sys_error _ | Unix.Unix_error _ -> None
(* A discovery that took frozen modules from a history summary did not record
   reading them: in another view it holds only while a summary verifies there
   and its walk read every one of them with the bytes discovery recorded. *)
let summarized_unchanged history = match history.summary with
  | None -> true
  | Some s -> match Migration_history_summary.current s with
    | None -> false
    | Some s -> List.for_all (fun (path,digest) ->
        match Migration_history_summary.facts s path with
        | None -> true
        | Some _ -> Migration_history_summary.covers s path = Some digest) history.source_inputs
let inspect_uncached ~stored_value_compatibility ~include_migrations ~compiler_abi ~project_root ~family = inspect_with ~capture:None ~stored_value_compatibility ~include_migrations ~compiler_abi ~project_root ~family
(* One discovery serves every caller of a command: the core is discovered once
   with migrations, and each (stored-value label, migrations) view of it is
   rebuilt from the same reads. A view's inventories are loaded from the core's
   loader and shared between callers asking for the same label. Any failure
   falls back to the ordinary discovery of exactly the requested view, which
   reports its precise error. *)
let view_of entry ~compiler_abi ~stored_value_compatibility ~include_migrations =
  match Hashtbl.find_opt entry.views (compiler_abi,stored_value_compatibility,include_migrations) with
  | Some t -> Ok t
  | None ->
    protect entry.core.full.current.root_file (fun () ->
      let load expected path =
        let key = compiler_abi,stored_value_compatibility,path in
        match Hashtbl.find_opt entry.loads key with
        | Some inventory -> inventory
        | None ->
          let inventory = entry.core.loader compiler_abi stored_value_compatibility expected path in
          Hashtbl.replace entry.loads key inventory; inventory in
      let schema (version,expected,path,defer) =
        let load () = load expected path in
        {version;root_file=path;loaded=if defer then lazy (try load () with Invalid error -> failwith error.message)
          else Lazy.from_val (load ())} in
      let schemas = List.map schema entry.core.specs in
      let frozen,current = match List.rev schemas with
        | current :: frozen -> List.rev frozen,current
        | [] -> invalid_arg "history core has no current schema" in
      let full = entry.core.full in
      let t = if include_migrations then {full with frozen;current}
        else {full with frozen;current;completed_migrations=[];current_migration=None;contracts=[];
          contract_directory=None;source_inputs=entry.core.schema_inputs;import_resolutions=entry.core.schema_imports} in
      (* Bounded: a scope that asks under many labels keeps at most 16 views. *)
      if Hashtbl.length entry.views >= 16 then (Hashtbl.reset entry.views; Hashtbl.reset entry.loads);
      Hashtbl.replace entry.views (compiler_abi,stored_value_compatibility,include_migrations) t;
      t)
let inspect ~stored_value_compatibility ~include_migrations ~compiler_abi ~project_root ~family =
 let compute () = inspect_uncached ~stored_value_compatibility ~include_migrations ~compiler_abi ~project_root ~family in
 let key = match !active_cache with
  | None -> None
  | Some _ ->
    (try Option.map (fun stdlib -> Source_input.realpath project_root,family,stdlib,Migration_trust.full_history ())
       (stdlib_inputs ())
     with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ -> None) in
 match !active_cache,key with
 | Some _,Some ((_,_,stdlib,_) as key) ->
   (* A hit still scans revision/Contract directories, rechecks canonical regular
      files and exact source digests, and resolves every captured import. Changed
      inputs trigger fresh discovery, not a stale result or cached diagnostic. *)
   (* Every declaration of a history looks up the same entry; re-reading every
      source on every hit made one command quadratic in history length. A hit
      already verified under this very source view (same overlay and pinned
      resources) is reused without re-reading; any other view re-verifies.
      A disk edit made while one command runs is caught by that command's final
      source guards (capture validation, preview verification) before it emits
      or reports success. The table lives only inside the compilation scope. *)
   let cached = Option.bind (Hashtbl.find_opt cores key) (fun entry ->
     match entry.verified_views with
     | tokens when List.exists Source_input.same_view tokens -> Some entry
     | token :: _ when Source_input.same_reads token entry.reads && summarized_unchanged entry.core.full ->
       entry.verified_views <- Source_input.view_token () :: entry.verified_views; Some entry
     | _ ->
       match verify_unchanged entry.core.full with
       | Ok () when stdlib_inputs () = Some stdlib ->
         entry.verified_views <- Source_input.view_token () :: entry.verified_views; Some entry
       | _ -> Hashtbl.remove cores key; None) in
   let entry = match cached with
     | Some entry -> Some entry
     | None ->
       let capture = ref None in
       let discovered,reads = Source_input.recording (fun () -> Source_input.with_path_memo @@ fun () ->
         inspect_with ~capture:(Some capture) ~stored_value_compatibility ~include_migrations:true ~compiler_abi ~project_root ~family) in
       (match discovered, !capture with
        | Ok _,Some core when stdlib_inputs () = Some stdlib ->
          if Hashtbl.length cores >= 4 then Hashtbl.reset cores;
          let entry = {core;reads;views=Hashtbl.create 4;loads=Hashtbl.create 16;verified_views=[Source_input.view_token ()]} in
          Hashtbl.replace cores key entry; Some entry
        | _ -> None) in
   (match Option.map (fun entry -> view_of entry ~compiler_abi ~stored_value_compatibility ~include_migrations) entry with
    | Some (Ok t) -> Ok t
    | Some (Error _) | None -> compute ())
 | _ -> compute ()

let discover_with_compatibility = inspect ~include_migrations:true
let discover = discover_with_compatibility ~stored_value_compatibility:None

(** Declaration diagnostics use the supplied migration AST (including an unsaved
    editor buffer). They need the complete checked schema chain, not another parse
    of the migration's saved bytes. Keep this result narrower than history: it
    grants no authority about migration sources, seals, or their frozen closures. *)
let adjacent_pair_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root ~family ~previous ~current =
  match inspect ~stored_value_compatibility ~include_migrations:false ~compiler_abi ~project_root ~family with
  | Error error -> Error error
  | Ok history ->
    (* Discovery requires each root to declare its revision's name, so a
       schema is found by name without loading every inventory; the two found
       are loaded and their roots compared below. *)
    let name_of (schema : schema) =
      if schema == history.current then family ^ ".VCurrent" else family ^ ".V" ^ string_of_int schema.version in
    let root schema = Migration_inventory.root_module (inventory schema) in
    let find name = List.find_opt (fun schema -> name_of schema = name && root schema = name)
      (history.frozen @ [history.current]) in
    match find previous, find current with
    | Some before, Some after when before.version + 1 = after.version &&
        previous <> family ^ ".VCurrent" -> Ok (before,after)
    | _ -> Error {kind=Invalid_layout;loc=Location.dummy_loc history.current.root_file;
        message="Migration must bridge a frozen schema and its immediately following revision in the same saved schema history"}

let adjacent_pair = adjacent_pair_with_compatibility ~stored_value_compatibility:None
