open Alcotest
module C = Migration_command
module P = Migration_preview
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let save path source = write path source; ignore (Compile.agent_context_result_source path source)
let schema = "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
|}
let with_project f =
  let root = Filename.temp_file "tesl migration 'å$' " ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    save (path "schema/notes/v-current.tesl") schema;
    save (path "app.tesl") app;
    f root path)
let contains needle response = Compile.string_contains response.C.stdout needle
let successful args =
  let response = C.run args in
  check int response.stdout 0 response.exit_code;
  check string "JSON only on stdout" "" response.stderr;
  check bool "typed versioned source envelope" true (contains "\"kind\":\"migration-source-preview\"" response);
  check bool "preview succeeded" true (contains "\"ok\":true" response);
  response
let refused args =
  let response = C.run args in
  check int response.stdout 1 response.exit_code;
  check bool "failure does not expose an applicable proposal" true (contains "\"manifest\":null" response);
  response
let args path = ["generate";path "app.tesl";"--manifest-json"]
let snapshot root =
  let rec collect dir = Sys.readdir dir |> Array.to_list |> List.sort String.compare |> List.concat_map (fun name ->
    let file = Filename.concat dir name in
    if (Unix.lstat file).Unix.st_kind=Unix.S_DIR then (file,None)::collect file else [file,Some (read file)]) in
  collect root
let start root path =
  let p = match P.generate ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~new_revision:false ~documents:[] with
    | Ok p -> p | Error _ -> fail "fixture initial preview" in
  List.iter (fun (e : M.edit) -> save e.path e.after) (M.edits (P.manifest p))
let initial () = with_project (fun root path ->
  let before = snapshot root in
  let response = successful (args path) in
  check bool "actual ABI is reported" true (contains "tesl-source-abi-v1:" response);
  check bool "complete app compiles" true (contains "\"compilable\":true" response);
  check bool "initial source freeze" true (contains "\"revisionAfter\":2" response);
  check bool "tree byte-identical" true (before=snapshot root);
  check string "repeatable preview" response.stdout (successful (args path)).stdout)
let lifecycle () = with_project (fun root path ->
  start root path;
  let before = snapshot root in
  let r = successful (args path) in
  check bool "default refresh" true (contains "\"operation\":\"refresh\"" r);
  check bool "no redundant writes" true (contains "\"edits\":[]" r);
  let r = successful (args path @ ["--new-revision"]) in
  check bool "explicit freeze next" true (contains "\"revisionAfter\":3" r);
  check bool "preview never mutates history" true (before=snapshot root))
let decision () = with_project (fun root path ->
  start root path;
  save (path "schema/notes/v-current.tesl") (replace "id: String }" "id: String, title: String }" schema);
  let r = successful (args path) in
  check bool "decision in full app diagnostics" true (contains "MIG003" r);
  check bool "preview success does not mean compiles" true (contains "\"compilable\":false" r);
  ignore (refused (args path @ ["--new-revision"])))
let ambiguity () = with_project (fun _root path ->
  save (path "schema/audit/v-current.tesl") (replace "NotesSchema" "AuditSchema" schema);
  save (path "app.tesl") (replace "import NotesSchema.VCurrent" "import AuditSchema.VCurrent\nimport NotesSchema.VCurrent" app ^
    "database Audit = Database { schema: AuditSchema.VCurrent, migrations: AuditSchema.Migrate, backend: Memory }\n");
  let r = refused (args path) in
  List.iter (fun name -> check bool "candidate retained" true (contains name r)) ["App.Main";"App.Audit"];
  let r = successful (args path @ ["--database";"App.Audit"]) in
  check bool "qualified selection retained" true (contains "\"family\":\"AuditSchema\"" r))
let nested_root () = with_project (fun _root path ->
  save (path "nested/schema/notes/v-current.tesl") schema;
  save (path "nested/app.tesl") app;
  let r = successful ["generate";path "nested/app.tesl";"--manifest-json"] in
  check bool "history follows selected root" true (contains (path "nested/migrations/notes/v2.tesl") r);
  ignore (refused ["generate";path "nested/app.tesl";"--manifest-json";"--project-root";path ""]))
let overlays () = with_project (fun root path ->
  let contents = path "buffer.txt" in
  write contents (replace "database Main" "database Unsaved" app);
  let before = snapshot root in
  let r = successful (args path @ ["--project-root";root;"--overlay";path "app.tesl";"8";contents]) in
  check bool "unsaved app selects database" true (contains "App.Unsaved" r);
  check bool "version guard is exposed" true (contains "\"version\":8" r);
  check bool "all saved sources retained" true (before=snapshot root);
  let again = successful (args path) in
  check bool "source scope restored" false (contains "App.Unsaved" again))
let virtual_entry () = with_project (fun root path ->
  let contents = path "buffer.txt" in write contents app;
  let file = path "new/app.tesl" in
  let r = successful ["generate";file;"--manifest-json";"--project-root";root;"--overlay";file;"-1";contents] in
  check bool "new app can preview enclosing schema" true (contains "App.Main" r);
  check bool "new directory is never saved" false (Sys.file_exists (path "new")))
let bad_overlays () = with_project (fun root path ->
  let contents = path "buffer.txt" in write contents app;
  let base = args path @ ["--project-root";root] in
  List.iter (fun suffix -> ignore (refused (base @ suffix)))
    [["--overlay";path "app.tesl";"2147483648";contents];
     ["--overlay";path "app.tesl";"x";contents];
     ["--overlay";path "app.tesl";"1";contents;"--overlay";path "app.tesl";"2";contents];
     ["--overlay";path "../outside.tesl";"1";contents];
     ["--overlay";path "not-tesl.txt";"1";contents]];
  ignore (refused (args path @ ["--overlay";path "app.tesl";"1";contents]));
  Unix.mkfifo (path "pipe") 0o600;
  ignore (refused (base @ ["--overlay";path "app.tesl";"1";path "pipe"])))
let paths () = with_project (fun _root path ->
  ignore (successful ["generate";path "./app.tesl";"--manifest-json"]);
  mkdir (path "child");
  ignore (successful ["generate";path "child/../app.tesl";"--manifest-json"]);
  Unix.symlink (path "child") (path "alias");
  ignore (refused ["generate";path "alias/../app.tesl";"--manifest-json"]);
  Unix.symlink (path "app.tesl") (path "alias.tesl");
  ignore (refused ["generate";path "alias.tesl";"--manifest-json"]);
  Unix.mkfifo (path "pipe.tesl") 0o600;
  ignore (refused ["generate";path "pipe.tesl";"--manifest-json"]))
let parse_errors () = with_project (fun root path ->
  let before = snapshot root in
  List.iter (fun xs -> ignore (refused xs))
    [[];["start"];["repair";path "app.tesl";"--manifest-json"];
     ["generate"];["generate";"--manifest-json"];["generate";path "app.tesl"];
     args path @ ["--manifest-json"];args path @ ["--database"];args path @ ["--new-revision";"--new-revision"];
     args path @ ["--database";"Main";"--database";"Main"];args path @ ["other.tesl"];
     args path @ ["--suggest-online"];args path @ ["--project-root";"--manifest-json"];
     args path @ ["--initial-version";"1"]];
  check bool "argument errors have no effects" true (before=snapshot root))
let cli_process () = with_project (fun root path ->
  let executable = Unix.realpath "../bin/main.exe" in
  let before = snapshot root in
  let code,output = Process_runner.run ~timeout:30 ~cwd:root executable
    ["migrate";"generate";"./app.tesl";"--manifest-json"] in
  check int output 0 code;
  check bool "real compiler dispatch" true (Compile.string_contains output "\"compilable\":true");
  check bool "real process is read-only" true (before=snapshot root);
  let code,output = Process_runner.run ~timeout:30 ~cwd:root executable
    ["migrate";"generate";path "app.tesl";"--manifest-json";"--database";"Missing"] in
  check int output 1 code;
  check bool "real process error protocol" true (Compile.string_contains output "\"manifest\":null"))
let help () =
  let r = C.run ["--help"] in check int "help succeeds" 0 r.exit_code;
  check bool "scope is stated" true (contains "without writing files or connecting" r)
let () = run "Migration command transport" ["preview and application",List.map (fun (name,f) -> test_case name `Quick f)
  ["actual source ABI and no filesystem effects",initial;"refresh and explicit next revision",lifecycle;
   "application decisions are not hidden",decision;"qualified database selection",ambiguity;
   "nested project selects actual schema",nested_root;"unsaved buffers and versions",overlays;
   "virtual application entry",virtual_entry;"malformed overlays refuse",bad_overlays;
   "path normalization preserves alias refusal",paths;"strict command options",parse_errors;
   "real process argv and error status",cli_process;"help describes current scope",help]]
