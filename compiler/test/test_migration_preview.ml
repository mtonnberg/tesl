open Alcotest
module P = Migration_preview
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write file source = mkdir (Filename.dirname file); Out_channel.with_open_bin file (fun out -> output_string out source)
let read file = In_channel.with_open_bin file In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let inspect file source = ignore (Compile.agent_context_result_source file source)
let save file source = write file source; inspect file source
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e : P.error) -> e.message) es))
let refuse = function Error (_::_ as errors) -> errors | _ -> fail "unsafe preview accepted"
let schema = "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
|}
let with_project f =
  let root = Filename.temp_file "tesl-migration-preview-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    save (path "schema/notes/v-current.tesl") schema;
    save (path "app.tesl") app;
    f root path)
let preview ?(new_revision=false) ?database ?(documents=[]) root =
  P.generate ~project_root:root ~entry_file:(Filename.concat root "app.tesl") ~database ~new_revision ~documents
let materialize p =
  get (P.verify p ~documents:[]);
  List.iter (fun (e : M.edit) -> write e.path e.after) (M.edits (P.manifest p));
  List.iter (fun (e : M.edit) -> inspect e.path e.after) (M.edits (P.manifest p))
let lifecycle () = with_project (fun root path ->
  let p = get (preview root) in
  check bool "initial generation starts a revision" true (P.operation p=P.Start);
  check int "initial target version" 2 (P.revision_after p);
  check bool "initial application compiles" true (P.compilable p);
  let actual = match Migration_abi.current () with Ok a -> Migration_abi.id a | Error _ -> fail "ABI" in
  check string "uses executing compiler identity" actual (P.compiler_abi p);
  check bool "preview creates no files" false (Sys.file_exists (path "migrations"));
  check string "entry remains unchanged" app (read (path "app.tesl"));
  materialize p;
  let refreshed = get (preview root) in
  check bool "default repeats refresh, not another freeze" true (P.operation refreshed=P.Refresh);
  check int "idempotent generation does not add edits" 0 (List.length (M.edits (P.manifest refreshed)));
  check int "refresh retains revision" 2 (P.revision_after refreshed);
  let next = get (preview ~new_revision:true root) in
  check bool "explicit next revision starts" true (P.operation next=P.Start);
  check int "next version" 3 (P.revision_after next);
  materialize next;
  check string "application stays byte identical" app (read (path "app.tesl")))
let additive () = with_project (fun root path ->
  materialize (get (preview root));
  let changed = schema |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude"
    |> replace "{ id: String }" "{ id: String, archivedAt: Maybe String }" in
  save (path "schema/notes/v-current.tesl") changed;
  let p = get (preview root) in
  check bool "complete application sees refreshed target seal" true (P.compilable p);
  check bool "actual additive source" true
    (List.exists (fun (e : M.edit) -> Compile.string_contains e.after "Additive []") (M.edits (P.manifest p)));
  materialize p;
  check bool "saved app passes same judgment" true (Compile.agent_context_result_source (path "app.tesl") app).ok)
let holes () = with_project (fun root path ->
  materialize (get (preview root));
  save (path "schema/notes/v-current.tesl") (replace "{ id: String }" "{ id: String, title: String }" schema);
  let p = get (preview root) in
  check bool "a valid preview can still require a decision" false (P.compilable p);
  let errors = List.filter (fun (d : Compile.diagnostic) -> d.severity="error") (P.diagnostics p) in
  check (list string) "implicit history hole reaches application diagnostics once" ["MIG003"] (List.map (fun (d : Compile.diagnostic) -> d.code) errors);
  check bool "preview marks incomplete application in JSON" true (Compile.string_contains (P.to_json p) "\"compilable\":false");
  materialize p;
  ignore (refuse (preview ~new_revision:true root)))
let application_errors () = with_project (fun root path ->
  let source = replace "import Tesl.Database" "import Tesl.Prelude exposing [Int]\nimport Tesl.Database" app ^ "fn broken() -> Int = \"no\"\n" in
  save (path "app.tesl") source;
  let p = get (preview root) in
  check bool "schema-only success cannot hide app errors" false (P.compilable p);
  check bool "complete application diagnostic retained" true
    (List.exists (fun (d : Compile.diagnostic) -> d.file=path "app.tesl" && d.code="T001") (P.diagnostics p));
  check string "generator does not rewrite handlers" source (read (path "app.tesl")))
let saved_guards () = with_project (fun root path ->
  let p = get (preview root) in
  save (path "app.tesl") (app ^ "# changed while preview open\n");
  ignore (refuse (P.verify p ~documents:[]));
  check bool "stale preview writes nothing" false (Sys.file_exists (path "migrations")))
let overlays () = with_project (fun root path ->
  let file = path "app.tesl" in let source = replace "database Main" "database Unsaved" app in
  let documents = [{M.path=file;version=4}] in
  Source_input.with_overlays ~project_root:root [file,source] (fun () ->
    inspect file source;
    let p = get (preview ~documents root) in
    check string "source view controls database selection" "App.Unsaved" (P.selection p).database_name;
    get (P.verify p ~documents);
    ignore (refuse (P.verify p ~documents:[{M.path=file;version=5}]));
    check string "editor source is not saved" app (read file)))
let ambiguity () = with_project (fun root path ->
  save (path "schema/audit/v-current.tesl") (replace "NotesSchema" "AuditSchema" schema);
  let source = app |> replace "import NotesSchema.VCurrent" "import AuditSchema.VCurrent\nimport NotesSchema.VCurrent"
    |> fun source -> source ^ "database Audit = Database { schema: AuditSchema.VCurrent, migrations: AuditSchema.Migrate, backend: Memory }\n" in
  save (path "app.tesl") source;
  let es = refuse (preview root) in
  check int "ambiguity retains selection candidates" 2 (List.length (List.hd es).candidates);
  check bool "error response includes candidates" true (Compile.string_contains (P.errors_to_json es) "App.Audit");
  let p = get (preview ~database:"Audit" root) in
  check string "selected family only" "AuditSchema" (P.selection p).family;
  check bool "complete application with another initial database" true (P.compilable p))
let immutable_history () = with_project (fun root path ->
  materialize (get (preview root)); materialize (get (preview ~new_revision:true root));
  let file = path "migrations/notes/v2.tesl" in save file (read file ^ "# historical edit\n");
  ignore (refuse (preview root)); ignore (refuse (preview ~new_revision:true root)))
let initial_invalid () = with_project (fun root path ->
  save (path "schema/notes/v-current.tesl") (replace "id: String" "id: Unknown" schema);
  let es = refuse (preview root) in
  check bool "no misleading manifest on failure" true (Compile.string_contains (P.errors_to_json es) "\"manifest\":null");
  check bool "failed generation creates nothing" false (Sys.file_exists (path "migrations")))
let broader_workspace_view () = with_project (fun root path ->
  let file = path "app.tesl" in
  let source = replace "database Main" "database Unsaved" app in
  Source_input.with_overlays ~project_root:(Filename.dirname root) [file,source] (fun () ->
    inspect file source;
    let p = get (preview root) in
    check string "workspace mirror may contain the selected project" "App.Unsaved" (P.selection p).database_name;
    check bool "complete proposed application still checks" true (P.compilable p);
    get (P.verify p ~documents:[])))
let () = run "Migration source previews" ["actual compiler and application",List.map (fun (name,f) -> test_case name `Quick f)
  ["idempotent lifecycle and explicit next revision",lifecycle;"additive refresh checks complete app",additive;
   "incomplete decisions remain visible",holes;"application errors are not schema-only success",application_errors;
   "saved application guards",saved_guards;"unsaved selection and document guards",overlays;
   "database selection ambiguity",ambiguity;"completed source stays immutable",immutable_history;"invalid schema yields no manifest",initial_invalid;"project inside a broader workspace source view",broader_workspace_view]]
