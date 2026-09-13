open Alcotest
module T = Migration_target
module M = Migration_manifest
module G = Migration_generate
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let inspect file source = ignore (Compile.agent_context_result_source file source)
let save path relative source = let file = path relative in write file source; inspect file source
let get = function Ok x -> x | Error errors -> fail (String.concat "\n" (List.map (fun (e : T.error) -> e.message) errors))
let refused = function Error (_::_ as errors) -> errors | _ -> fail "invalid target accepted"
let refuse result = ignore (refused result)
let schema family = "module " ^ family ^ ".VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\n" ^
  "entity Note table \"notes\" primaryKey id { id: String }\n"
let database name family = "database " ^ name ^ " = Database {\n  schema: " ^ family ^ ".VCurrent\n  migrations: " ^ family ^
  ".Migrate\n  backend: Memory\n}\n"
let app = "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\n" ^ database "Main" "NotesSchema"
let with_project f =
  let root = Filename.temp_file "tesl-migration-target-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    save path "schema/notes/v-current.tesl" (schema "NotesSchema");
    save path "app.tesl" app;
    f root path)
let resolve ?database ?(entry="app.tesl") ?(documents=[]) root =
  T.resolve ~compiler_abi:"fixture-ABI" ~project_root:root ~entry_file:(Filename.concat root entry) ~database ~documents
let apply_fixture manifest =
  (match M.verify_disk manifest with Ok () -> () | Error _ -> fail "stale test materialization");
  List.iter (fun (e : M.edit) -> write e.path e.after; inspect e.path e.after) (M.edits manifest)
let single () = with_project (fun root path ->
  let target = get (resolve root) in let selected = T.selection target in
  check string "canonical entry" (path "app.tesl") selected.entry_file;
  check string "qualified connection owner" "App.Main" selected.database_name;
  check string "schema family" "NotesSchema" selected.family;
  check string "stable current root" "NotesSchema.VCurrent" selected.schema_root;
  check (option int) "new family has no predecessor" None selected.previous_version;
  check int "new family current version" 1 selected.current_version;
  check string "canonical migration directory" (path "migrations/notes") selected.migration_directory;
  let p = get (T.start target ~documents:[]) in
  check int "root freeze and next migration" 2 (List.length (M.edits p.manifest));
  check bool "read-only preview" false (Sys.file_exists (path "migrations"));
  check string "connection is not rewritten" app (read (path "app.tesl"));
  let body = M.to_json p.manifest in
  check bool "application selection belongs to final guards" true (Compile.string_contains body (path "app.tesl"));
  apply_fixture p.manifest;
  let selected = T.selection (get (resolve root)) in
  check (option int) "predecessor after freeze" (Some 1) selected.previous_version;
  check int "current advances" 2 selected.current_version)
let imported_owner () = with_project (fun root path ->
  save path "connection.tesl" (replace "module App" "module Connection" app);
  save path "app.tesl" "module App exposing []\nimport Connection\n";
  let target = get (resolve root) in
  check string "imported owner, not entry module" "Connection.Main" (T.selection target).database_name;
  check string "owning source" (path "connection.tesl") (T.selection target).database_file;
  ignore (get (resolve ~database:"Main" root));
  ignore (get (resolve ~database:"Connection.Main" root));
  refuse (resolve ~database:"App.Main" root))
let ambiguity () = with_project (fun root path ->
  save path "schema/audit/v-current.tesl" (schema "AuditSchema");
  save path "other.tesl" ("module Other exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport AuditSchema.VCurrent\n" ^ database "Main" "AuditSchema");
  save path "app.tesl" (replace "import Tesl.Database" "import Other\nimport Tesl.Database" app);
  let errors = refused (resolve root) in
  check int "all candidates are reported" 2 (List.length (List.hd errors).candidates);
  refuse (resolve ~database:"Main" root);
  check string "explicit first target" "NotesSchema" (T.selection (get (resolve ~database:"App.Main" root))).family;
  let other = get (resolve ~database:"Other.Main" root) in
  check string "explicit second target" "AuditSchema" (T.selection other).family;
  let p = get (T.start other ~documents:[]) in
  check bool "only selected schema is frozen" true
    (List.for_all (fun (e : M.edit) -> not (Compile.string_contains e.path "/notes/")) (M.edits p.manifest)))
let unknown_and_no_owner () = with_project (fun root _ ->
  refuse (resolve ~database:"Missing" root);
  refuse (resolve ~entry:"schema/notes/v-current.tesl" root))
let two_owners () = with_project (fun root path ->
  save path "app.tesl" (app ^ database "Second" "NotesSchema");
  refuse (resolve root); refuse (resolve ~database:"Main" root))
let legacy () = with_project (fun root path ->
  let legacy = "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent exposing [Note]\ndatabase Main = Database { entities: [Note], backend: Memory }\n" in
  save path "app.tesl" legacy;
  let errors = refused (resolve root) in
  check bool "legacy ownership needs an explicit upgrade" true (Compile.string_contains (List.hd errors).message "ownership"))
let invalid_binding () = with_project (fun root path ->
  List.iter (fun source -> save path "app.tesl" source; refuse (resolve root))
    [replace "migrations: NotesSchema.Migrate" "migrations: OtherSchema.Migrate" app;
     replace "schema: NotesSchema.VCurrent" "schema: \"NotesSchema.VCurrent\"" app;
     replace "import NotesSchema.VCurrent\n" "" app])
let rebind_after_selection () = with_project (fun root path ->
  save path "schema/audit/v-current.tesl" (schema "AuditSchema");
  let target = get (resolve root) in
  save path "app.tesl" (replace "NotesSchema" "AuditSchema" app);
  refuse (T.start target ~documents:[]);
  check bool "stale selection creates no migration directory" false (Sys.file_exists (path "migrations")))
let rebind_after_preview () = with_project (fun root path ->
  let p = get (T.start (get (resolve root)) ~documents:[]) in
  save path "app.tesl" (replace "database Main" "database Renamed" app);
  (match M.verify_source p.manifest ~documents:[] with Error _ -> () | Ok () -> fail "application source was not guarded");
  (match M.verify_disk p.manifest with Error _ -> () | Ok () -> fail "saved connection source was not guarded"))
let imported_owner_guard () = with_project (fun root path ->
  save path "connection.tesl" (replace "module App" "module Connection" app);
  save path "app.tesl" "module App exposing []\nimport Connection\n";
  let target = get (resolve root) in
  save path "connection.tesl" (replace "module App" "module Connection" app ^ "# changed connection owner\n");
  refuse (T.start target ~documents:[]))
let source_overlay () = with_project (fun root path ->
  let file = path "app.tesl" in
  let buffer = replace "database Main" "database Unsaved" app in
  let documents = [{M.path=file;version=7}] in
  let target,manifest = Source_input.with_overlays ~project_root:root [file,buffer] (fun () ->
    inspect file buffer;
    let target = get (resolve ~documents root) in
    check string "target follows unsaved app" "App.Unsaved" (T.selection target).database_name;
    let p = get (T.start target ~documents) in
    check string "disk is untouched" app (read file);
    check bool "preview does not silently save app" false (List.exists (fun (e : M.edit) -> e.path=file) (M.edits p.manifest));
    refuse (T.start target ~documents:[{M.path=file;version=8}]);
    target,p.manifest) in
  refuse (T.start target ~documents);
  (match M.verify_disk manifest with Ok () -> () | Error _ -> fail "disk snapshot remains unchanged"))
let virtual_entry () = with_project (fun root path ->
  let file = path "unsaved.tesl" in
  let documents = [{M.path=file;version=1}] in
  Source_input.with_overlays ~project_root:root [file,replace "module App" "module Unsaved" app] (fun () ->
    let target = get (resolve ~entry:"unsaved.tesl" ~documents root) in
    let p = get (T.start target ~documents) in
    check bool "virtual application is not materialized" false (Sys.file_exists file);
    check bool "new source input still has a disk-absence guard" true
      (Compile.string_contains (M.to_json p.manifest) ("\"path\":\"" ^ file ^ "\""))))
let refresh_selected () = with_project (fun root path ->
  apply_fixture (get (T.start (get (resolve root)) ~documents:[])).manifest;
  let old_selection = get (resolve root) in
  let changed = schema "NotesSchema" |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude"
    |> replace "{ id: String }" "{ id: String, extra: Maybe String }" in
  save path "schema/notes/v-current.tesl" changed;
  refuse (T.refresh old_selection ~documents:[]);
  let p = get (T.refresh (get (resolve root)) ~documents:[]) in
  check int "current version retained by refresh" 2 p.current_version;
  check bool "checked additive refresh" false (List.exists (fun (d : Compile.diagnostic) -> d.severity="error") p.diagnostics);
  save path "app.tesl" (app ^ "# connection changed while preview open\n");
  (match M.verify_disk p.manifest with Error _ -> () | Ok () -> fail "refresh lost selection guard"))
let stale_history () = with_project (fun root _ ->
  let old = get (resolve root) in
  apply_fixture (get (T.start old ~documents:[])).manifest;
  refuse (T.start old ~documents:[]))
let paths () = with_project (fun root path ->
  refuse (resolve ~entry:"missing.tesl" root);
  Unix.symlink (path "app.tesl") (path "alias.tesl"); refuse (resolve ~entry:"alias.tesl" root);
  Unix.mkfifo (path "pipe.tesl") 0o600; refuse (resolve ~entry:"pipe.tesl" root);
  save path "app.tesl" (replace "import Tesl.Database" "import Missing\nimport Tesl.Database" app); refuse (resolve root))
let malformed_dependency () = with_project (fun root path ->
  save path "helper.tesl" "module broken = @@@";
  save path "app.tesl" (replace "import Tesl.Database" "import Helper\nimport Tesl.Database" app);
  let errors = refused (resolve root) in
  check string "parse error points at dependency" (path "helper.tesl") (List.hd errors).loc.file)
let mismatched_module () = with_project (fun root path ->
  save path "connection.tesl" (replace "module App" "module Different" app);
  save path "app.tesl" "module App exposing []\nimport Connection\n";
  let errors = refused (resolve root) in
  check string "mismatched import points at wrong declaration" (path "connection.tesl") (List.hd errors).loc.file;
  check bool "cannot infer a different module's owner" true
    (Compile.string_contains (List.hd errors).message "declaring Different"))
let diamond_and_cycle () = with_project (fun root path ->
  save path "connection.tesl" (replace "module App" "module Connection" app);
  save path "left.tesl" "module Left exposing []\nimport Connection\nimport Right\n";
  save path "right.tesl" "module Right exposing []\nimport Connection\nimport Left\n";
  save path "app.tesl" "module App exposing []\nimport Left\nimport Right\n";
  let target = get (resolve root) in
  check string "shared owner is visited exactly once" "Connection.Main" (T.selection target).database_name;
  ignore (get (T.start target ~documents:[])))
let shadowed_import () = with_project (fun root path ->
  let owner = replace "module App" "module Connection" app in
  save path "Connection.tesl" owner;
  save path "app.tesl" "module App exposing []\nimport Connection\n";
  mkdir (path "elsewhere");
  Unix.symlink (path "elsewhere/connection.tesl") (path "connection.tesl");
  let target = get (resolve root) in
  (* Only an unguarded descendant becomes present; the root's entry names and
     previously selected owner bytes remain identical. Import resolution changes. *)
  save path "elsewhere/connection.tesl" owner;
  refuse (T.start target ~documents:[]))
let nested_schema_selection () = with_project (fun root path ->
  save path "nested/schema/notes/v-current.tesl" (schema "NotesSchema");
  save path "nested/app.tesl" app;
  let errors = refused (resolve ~entry:"nested/app.tesl" root) in
  check string "reports actual nested schema" (path "nested/schema/notes/v-current.tesl") (List.hd errors).loc.file;
  check bool "neither project is mutated" false (Sys.file_exists (path "migrations"));
  let inferred = get (T.infer_project_root ~entry_file:(path "nested/app.tesl") ~database:None) in
  check string "infer actual selected schema root" (path "nested") inferred;
  let target = get (T.resolve ~compiler_abi:"fixture-ABI" ~project_root:inferred
    ~entry_file:(path "nested/app.tesl") ~database:None ~documents:[]) in
  let p = get (T.start target ~documents:[]) in
  check bool "only actual project receives proposed files" true
    (List.for_all (fun (e : M.edit) -> String.starts_with ~prefix:(path "nested/") e.path) (M.edits p.manifest)))
let inferred_owner () = with_project (fun root path ->
  save path "connection.tesl" (replace "module App" "module Connection" app);
  save path "app.tesl" "module App exposing []\nimport Connection\n";
  check string "schema reached through connection module" root
    (get (T.infer_project_root ~entry_file:(path "app.tesl") ~database:(Some "Connection.Main")));
  refuse (T.infer_project_root ~entry_file:(path "app.tesl") ~database:(Some "Missing"));
  Unix.symlink (path "app.tesl") (path "alias.tesl");
  refuse (T.infer_project_root ~entry_file:(path "alias.tesl") ~database:None);
  Unix.mkfifo (path "pipe.tesl") 0o600;
  refuse (T.infer_project_root ~entry_file:(path "pipe.tesl") ~database:None))
let flat_schema_refuses () = with_project (fun root path ->
  save path "NotesSchema.VCurrent.tesl" (schema "NotesSchema");
  (* Flat imports have precedence, but migration ownership requires its canonical layout. *)
  refuse (resolve root);
  refuse (T.infer_project_root ~entry_file:(path "app.tesl") ~database:None))
let () = run "Migration application targets" ["explicit guarded selection",List.map (fun (name,f) -> test_case name `Quick f)
  ["single target owns complete start preview",single;"imported connection owner and names",imported_owner;
   "ambiguous names require qualified selection",ambiguity;"unknown name and schema-only entry refuse",unknown_and_no_owner;
   "duplicate ownership cannot be hidden by explicit selection",two_owners;"legacy entities need ownership upgrade",legacy;
   "invalid contextual binding refuses",invalid_binding;"database rebind invalidates selection",rebind_after_selection;
   "database edits invalidate completed preview",rebind_after_preview;"imported owner bytes remain guarded",imported_owner_guard;
   "unsaved selection and document versions",source_overlay;"new editor-only application entry",virtual_entry;
   "refresh retains application selection guards",refresh_selected;"another start invalidates old version selection",stale_history;
   "missing, symlink and FIFO paths refuse",paths;"broken dependency retains source location",malformed_dependency;
   "import name must match its declaration",mismatched_module;"diamond and cyclic imports do not duplicate owners",diamond_and_cycle;
   "changed import resolution invalidates selected owner",shadowed_import;
   "nested schema cannot select a different history",nested_schema_selection;
   "infer through connection owner and refuse special paths",inferred_owner;
   "flat shadow schema is not a canonical history",flat_schema_refuses]]
