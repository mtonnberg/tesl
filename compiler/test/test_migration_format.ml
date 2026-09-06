open Alcotest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path);Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path) else Sys.remove path
let read path = In_channel.with_open_bin path In_channel.input_all
let write path source = mkdir (Filename.dirname path);Out_channel.with_open_bin path (fun out -> output_string out source)
let with_project f =
 let root = Filename.temp_file "tesl-migration-format-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (Filename.concat root))
let messy = "module Demo exposing []\n\nfn value()->Int=42\n\n"
let marker = "# tesl:frozen-migration:v1 NotesSchema.Migrate.V2\n"
let locked path source = Migration_format_guard.reason ~file:path ~source<>None
let frozen_paths () = with_project (fun _ path ->
 List.iter (fun name -> check bool name true (locked (path name) messy))
  ["schema/notes/v1.tesl";"schema/notes/v2147483646/private.tesl";"schema/notes/v2/helpers/deep.tesl"];
 List.iter (fun name -> check bool name false (locked (path name) messy))
  ["schema/notes/v-current.tesl";"schema/notes/v-current/private.tesl";"application/v2.tesl";
   "schema/notes/v0.tesl";"schema/notes/v01.tesl";"schema/notes/v2147483647.tesl"])
let completed_paths () = with_project (fun _ path ->
 let root = path "migrations/notes/v2.tesl" and helper = path "migrations/notes/v2/private.tesl" in
 write root messy;write helper messy;
 check bool "current migration remains editable" false (locked helper messy);
 write (path "schema/notes/v2.tesl") messy;
 check bool "completed root" true (locked root messy);
 check bool "completed helper" true (locked helper messy);
 check bool "later current root" false (locked (path "migrations/notes/v3.tesl") messy))
let recorded_marker () = with_project (fun _ path ->
 let root = path "migrations/notes/v2.tesl" in
 let source = marker ^ messy in
 write root source;
 check bool "closure protects root without sibling snapshot" true (locked root source);
 check bool "closure protects private helper" true (locked (path "migrations/notes/v2/private.tesl") messy);
 write root messy;
 check bool "unsaved completed root" true (locked root source))
let overlays () = with_project (fun root path ->
 let migration = path "migrations/notes/v2.tesl" and helper = path "migrations/notes/v2/private.tesl" in
 write migration messy;write helper messy;
 Source_input.with_overlays ~project_root:root [path "schema/notes/v2.tesl",messy] (fun () ->
  check bool "unsaved snapshot protects helper" true (locked helper messy));
 Source_input.with_overlays ~project_root:root [migration,marker ^ messy] (fun () ->
  check bool "unsaved completed root protects helper" true (locked helper messy));
 check bool "overlay does not leak" false (locked helper messy))
let marker_scope () = with_project (fun _ path ->
 let root = path "migrations/notes/v2.tesl" in
 write root (messy ^ marker);
 check bool "ordinary body comment is not closure metadata" false (locked root (messy ^ marker));
 check bool "malformed leading metadata remains protected" true (locked root (marker ^ messy)))
let files () = with_project (fun _ path ->
 let frozen = path "schema/notes/v1.tesl" and current = path "schema/notes/v-current.tesl" in
 write frozen messy;write current messy;
 (match Formatter.format_file frozen with Error message -> check bool "named refusal" true (String.starts_with ~prefix:"MIG013:" message) | Ok () -> fail "frozen bytes changed");
 check string "preserved frozen bytes" messy (read frozen);
 check bool "style checks exempt frozen source" true (Formatter.format_check frozen=Ok true);
 check bool "current source formatted" true (Formatter.format_file current=Ok ());
 check string "current formatting result" (Formatter.format_source messy) (read current))
let logical_paths () = with_project (fun _ path ->
 let temporary = path "temporary.tesl" in write temporary messy;
 let logical = path "schema/notes/v1.tesl" in
 (match Formatter.format_file ~logical_path:logical temporary with Error _ -> () | Ok () -> fail "temporary path hid ownership");
 check string "temporary bytes preserved" messy (read temporary);
 check bool "logical format check" true (Formatter.format_check ~logical_path:logical temporary=Ok true))
let aliases () = with_project (fun _ path ->
 let frozen = path "schema/notes/v1.tesl" and ordinary = path "ordinary.tesl" in
 write frozen messy;write ordinary messy;
 Unix.symlink frozen (path "alias.tesl");
 check bool "resolved ownership" true (locked (path "alias.tesl") messy);
 Sys.remove frozen;Unix.symlink ordinary frozen;
 check bool "redirected frozen spelling" true (locked frozen messy);
 (match Formatter.format_file frozen with Error _ -> () | Ok () -> fail "redirected frozen source formatted");
 check string "external target preserved" messy (read ordinary))
let queries () = with_project (fun _ path ->
 let file = path "schema/notes/v-current.tesl" in write file messy;
 let query logical = Compiler_query.run ~filename:file ~logical_path:logical "--format-json" [] in
 let current = query file and frozen = query (path "schema/notes/v1.tesl") in
 check int "read-only query status" 0 frozen.exit_code;
 check bool "frozen query preserves exact text" true (Compile.string_contains frozen.json (Compile.json_encode_string messy));
 check bool "frozen query reports reason" true (Compile.string_contains frozen.json "\"readOnly\":true");
 check bool "current query formats" true (Compile.string_contains current.json (Compile.json_encode_string (Formatter.format_source messy)));
 check string "query never writes source" messy (read file))
let () = run "Migration formatting ownership" ["preserved bytes",List.map (fun (name,f) -> test_case name `Quick f)
 ["canonical frozen and current paths",frozen_paths;"completed root and helpers",completed_paths;
  "recorded and unsaved closure marker",recorded_marker;"sibling document overlays",overlays;"actual metadata grammar",marker_scope;
  "formatter write and style check",files;"temporary logical path",logical_paths;
  "symlink ownership spellings",aliases;"read-only query protocol",queries]]
