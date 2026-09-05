open Alcotest
module G = Migration_generate
module M = Migration_manifest
module S = Migration_source_syntax
module D = Migration_declaration
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let contains text pattern = Compile.string_contains text pattern
let get = function Ok x -> x | Error errors -> fail (String.concat "\n" (List.map (fun (e : G.error) -> e.path ^ ": " ^ e.message) errors))
let syntax_result = function Ok x -> x | Error (e : S.error) -> fail e.message
let refuses = function Error (_::_) -> () | _ -> fail "unsafe refresh accepted"
let codes ds = List.filter_map (fun (d : Compile.diagnostic) -> if d.severity="error" then Some d.code else None) ds |> List.sort String.compare
let accepts file source = let context = Compile.agent_context_result_source file source in if not context.ok then fail context.json
let inspect file source = ignore (Compile.agent_context_result_source file source)
let child = {|module NotesSchema.VCurrent.Notes exposing [Note]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { id: String, title: String }
|}
let root_source = "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Notes\n"
let start root version = G.start ~compiler_abi:"fixture-ABI" ~project_root:root ~family:"NotesSchema" ~version ~documents:[]
let refresh ?(abi="fixture-ABI") ?(version=2) ?(documents=[]) root =
  G.refresh ~compiler_abi:abi ~project_root:root ~family:"NotesSchema" ~version ~documents
let materialize manifest =
  (match M.verify_disk manifest with Ok () -> () | Error _ -> fail "stale fixture manifest");
  List.iter (fun (e : M.edit) -> write e.path e.after; inspect e.path e.after) (M.edits manifest)
let with_project ?(source=child) f =
  let root = Filename.temp_file "tesl-migration-refresh-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    write (path "schema/notes/v-current.tesl") root_source;
    write (path "schema/notes/v-current/notes.tesl") source;
    accepts (path "schema/notes/v-current.tesl") root_source;
    materialize (get (start root 1)).manifest;
    f root path)
let edit path relative source = let file = path relative in write file source; inspect file source
let change path source = edit path "schema/notes/v-current/notes.tesl" source
let migration path = path "migrations/notes/v2.tesl"
let preview_source path (p : G.refresh_preview) =
  match List.find_opt (fun (e : M.edit) -> e.path=migration path) (M.edits p.manifest) with
  | Some e -> e.after | None -> read (migration path)
let form file source =
  let view = syntax_result (S.read ~file ~source) in
  let syntax = match D.read_syntax (S.module_ view) with
    | Ok (Some syntax) -> syntax | _ -> fail "fixture syntax" in view,syntax
let entries file source = let _,syntax = form file source in
  match syntax.entities with Ast.ERecord {fields;_} -> fields | _ -> fail "fixture entities"
let set_entry file source key body = let v,syntax = form file source in
  let value = List.assoc key (match syntax.entities with Ast.ERecord {fields;_} -> fields | _ -> assert false) in
  syntax_result (S.replace v [syntax_result (S.range v value),body])
let same_count file source = let _,syntax = form file source in
  match syntax.same with Ast.EList {elems;_} -> List.length elems | _ -> fail "fixture Same"
let same_omitted file source = let v,syntax = form file source in
  syntax_result (S.replace v [syntax_result (S.collection_range v syntax.same),"[]"])
let assert_codes expected (p : G.refresh_preview) =
  if List.sort String.compare expected <> codes p.diagnostics then
    List.iter (fun (d : Compile.diagnostic) -> Printf.printf "%s: %s\n%!" d.code d.message) p.diagnostics;
  check (list string) "full proposed-view diagnostics" (List.sort String.compare expected) (codes p.diagnostics)
let noop () = with_project (fun root path ->
  let source = read (migration path) in
  let p = get (refresh root) in assert_codes [] p;
  check int "no edits when unchanged" 0 (List.length (M.edits p.manifest));
  check string "saved source unchanged" source (read (migration path));
  check string "stable manifest identity" (M.digest p.manifest) (M.digest (get (refresh root)).manifest))
let optional () = with_project (fun root path ->
  let app = "module App exposing []\nimport NotesSchema.VCurrent\nimport NotesSchema.Migrate.V2\n" in
  edit path "app.tesl" app;
  let suffix = "\n# User helper and regression.\nfn answer() -> Int = 42\ntest \"answer\" { expect answer() == 42 }\n" in
  let source = replace "import Tesl.Migration" "import Tesl.Prelude exposing [Int]\nimport Tesl.Migration" (read (migration path)) ^ suffix in
  edit path "migrations/notes/v2.tesl" source;
  change path (replace "title: String }" "title: String, archivedAt: Maybe String }" child);
  let p = get (refresh root) in assert_codes [] p;
  check int "only current migration changes" 1 (List.length (M.edits p.manifest));
  check string "preview has no source writes" source (read (migration path));
  let output = preview_source path p in
  check bool "private additive entry" true (contains output "\"Notes.Note\": Additive []");
  check bool "helper and test unchanged" true (String.ends_with ~suffix output);
  materialize p.manifest;
  accepts (migration path) output; accepts (path "app.tesl") app;
  check string "app stays byte identical" app (read (path "app.tesl"));
  materialize (get (start root 2)).manifest;
  accepts (path "migrations/notes/v3.tesl") (read (path "migrations/notes/v3.tesl")))
let holes_and_manual_default () = with_project (fun root path ->
  change path (replace "title: String }" "title: String, count: Int }" child);
  let p = get (refresh root) in assert_codes ["MIG003"] p;
  let source = preview_source path p in
  check bool "decision names new field" true (contains source "count");
  check bool "decision lists old row inputs" true (contains source "old row fields: id, title");
  materialize p.manifest;
  check bool "agent-context refuses generated hole" false (Compile.agent_context_result_source (migration path) source).ok;
  (match Compile.compile_go_source (migration path) source with
   | Compile.GoFailure ds -> check (list string) "no code emitted for placeholder" ["MIG003"] (codes ds)
   | Compile.GoSuccess _ -> fail "placeholder reached backend");
  check int "unresolved refresh is byte-idempotent" 0 (List.length (M.edits (get (refresh root)).manifest));
  let source = set_entry (migration path) source "Notes.Note" "Additive [Default count 0]" in
  edit path "migrations/notes/v2.tesl" source; accepts (migration path) source;
  let p = get (refresh root) in assert_codes [] p;
  check string "handwritten default remains exact" source (preview_source path p);
  check int "handwritten default is not regenerated" 0 (List.length (M.edits p.manifest)))
let new_drop () = with_project (fun root path ->
  change path (replace "entity Note table \"notes\"" "entity Tag table \"tags\"" child |> replace "exposing [Note]" "exposing [Tag]");
  let p = get (refresh root) in assert_codes [] p;
  let output = preview_source path p in
  check bool "removed entity classified" true (contains output "\"Notes.Note\": Drop");
  check bool "added entity classified" true (contains output "\"Notes.Tag\": New");
  materialize p.manifest; accepts (migration path) output)
let reverted () = with_project (fun root path ->
  change path (replace "title: String }" "title: String, archivedAt: Maybe String }" child);
  materialize (get (refresh root)).manifest;
  let source = replace "  entities:" "  # Keep this note.\n  entities:" (read (migration path)) in
  edit path "migrations/notes/v2.tesl" source;
  change path child;
  let p = get (refresh root) in assert_codes [] p;
  let source = preview_source path p in
  check int "obsolete generated entry disappears" 0 (List.length (entries (migration path) source));
  check bool "comment beside removed entry remains" true (contains source "# Keep this note."))
let obsolete_user () = with_project (fun root path ->
  change path (replace "title: String }" "title: String, count: Int }" child);
  materialize (get (refresh root)).manifest;
  let source = set_entry (migration path) (read (migration path)) "Notes.Note" "Additive [Default count 9]" in
  edit path "migrations/notes/v2.tesl" source;
  change path child;
  let p = get (refresh root) in assert_codes ["MIG002"] p;
  check bool "obsolete handwritten rule stays in source" true (contains (preview_source path p) "Additive [Default count 9]"))
let payload = {|module NotesSchema.VCurrent.Notes exposing [Note, Payload]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Payload { text: String }
codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, payload: Payload }
|}
let codec_change () = with_project ~source:payload (fun root path ->
  check int "single surface claim covers record and codec" 1 (same_count (migration path) (read (migration path)));
  change path (replace "-> \"text\"" "-> \"body\"" payload);
  let p = get (refresh root) in assert_codes ["MIG003"] p;
  check int "codec change invalidates whole generated claim" 0 (same_count (migration path) (preview_source path p));
  check bool "affected stored occurrence needs a decision" true (contains (preview_source path p) "payload"))
let omitted_same () = with_project ~source:payload (fun root path ->
  edit path "migrations/notes/v2.tesl" (same_omitted (migration path) (read (migration path)));
  let p = get (refresh root) in assert_codes ["MIG003"] p;
  check int "deliberate omission is never auto-filled" 0 (same_count (migration path) (preview_source path p));
  check bool "revalidation decision explains missing identity" true (contains (preview_source path p) "has no Same"))
let stale_user_same () = with_project ~source:payload (fun root path ->
  let source = read (migration path) in
  let source = replace "# @tesl-gen same:" "# user @tesl-gen same:" source in
  edit path "migrations/notes/v2.tesl" source;
  change path (replace "-> \"text\"" "-> \"body\"" payload);
  let p = get (refresh root) in assert_codes ["MIG024"] p;
  let output = preview_source path p in
  check int "stale handwritten claim remains" 1 (same_count (migration path) output);
  check int "invalid identity cannot inform generated adapters" 0 (List.length (entries (migration path) output)))
let two_holes () =
  let source = child ^ "entity Session table \"sessions\" primaryKey id { id: String, title: String }\n" in
  with_project ~source (fun root path ->
    change path (replace "title: String }" "title: String, count: Int }" source);
    let p = get (refresh root) in assert_codes ["MIG003";"MIG003"] p;
    let errors = List.filter (fun (d : Compile.diagnostic) -> d.code="MIG003") p.diagnostics in
    check bool "each hole has a distinct source location" true ((List.hd errors).start_line <> (List.hd (List.tl errors)).start_line))
let frozen_drift () = with_project (fun root path ->
  edit path "schema/notes/v1/notes.tesl" (read (path "schema/notes/v1/notes.tesl") ^ "# changed frozen bytes\n");
  let original = read (migration path) in
  refuses (refresh root);
  check string "refusal leaves target header untouched" original (read (migration path)))
let selected_and_abi () = with_project (fun root _ ->
  refuses (refresh ~version:3 root);
  refuses (refresh ~abi:"different-ABI" root))
let corrupt_history () = with_project (fun root path ->
  let source = read (migration path) in
  List.iter (fun replacement ->
    edit path "migrations/notes/v2.tesl" replacement;
    refuses (refresh root))
    [replace "# tesl:migration-from" "# corrupt" source;
     replace "to: NotesSchema.VCurrent" "to: NotesSchema.V1" source;
     String.sub source (String.index source 'm') (String.length source - String.index source 'm')];
  edit path "migrations/notes/v2.tesl" source;
  materialize (get (start root 2)).manifest;
  edit path "schema/notes/v1/notes.tesl" (read (path "schema/notes/v1/notes.tesl") ^ "# old history drift\n");
  refuses (refresh ~version:3 root))
let unsaved () = with_project (fun root path ->
  let file = path "schema/notes/v-current/notes.tesl" in
  let bytes = replace "title: String }" "title: String, archivedAt: Maybe String }" child in
  let documents = [{M.path=file;version=8}] in
  let manifest = match Source_input.with_overlays ~project_root:root [file,bytes] (fun () ->
    inspect file bytes;
    let p = get (refresh ~documents root) in assert_codes [] p;
    check string "saved schema remains unchanged" child (read file);
    (match M.verify_source p.manifest ~documents with Ok () -> () | Error _ -> fail "fresh overlay failed");
    p.manifest) with m -> m in
  (match M.verify_source manifest ~documents with Error _ -> () | Ok () -> fail "stale source view accepted");
  (match M.verify_disk manifest with Ok () -> () | Error _ -> fail "saved preimage should remain valid");
  edit path "schema/notes/v-current/notes.tesl" (child ^ "# concurrent saved edit\n");
  (match M.verify_disk manifest with Error _ -> () | Ok () -> fail "concurrent disk edit accepted"))
let aliases () = with_project (fun root path ->
  change path (replace "title: String }" "title: String, archivedAt: Maybe String }" child);
  materialize (get (refresh root)).manifest;
  let source = read (migration path) |> replace "\"Notes.Note\": Additive" "Note: Additive" in
  edit path "migrations/notes/v2.tesl" source;
  change path child;
  let p = get (refresh root) in assert_codes ["MIG002"] p;
  check bool "edited key invalidates generator ownership" true (contains (preview_source path p) "Note: Additive []"))
let duplicate_aliases () = with_project (fun root path ->
  change path (replace "title: String }" "title: String, archivedAt: Maybe String }" child);
  let source = read (migration path) |> replace "entities: {}" "entities: { Note: Additive [], Notes.Note: Additive [] }" in
  edit path "migrations/notes/v2.tesl" source;
  refuses (refresh root))
let () = run "Migration refresh previews" ["checked source merge",List.map (fun (name,f) -> test_case name `Quick f)
  ["unchanged preview is deterministic and empty",noop;"optional private field preserves app and helpers",optional;
   "missing value blocks compilation and manual default survives",holes_and_manual_default;
   "new and removed entities",new_drop;"reverting schema removes generated entry",reverted;
   "obsolete handwritten entry remains diagnosed",obsolete_user;"changed same-named codec invalidates claim",codec_change;
   "deliberate Same omission requests revalidation",omitted_same;"stale user Same cannot inform adapters",stale_user_same;
   "multiple decisions get separate noncascading diagnostics",two_holes;"frozen drift never reseals history",frozen_drift;
   "stale revision selection and different ABI refuse",selected_and_abi;"malformed and completed history refuse",corrupt_history;
   "unsaved schema and independent disk guards",unsaved;"edited entity key protects original entry",aliases;
   "duplicate entity aliases refuse merging",duplicate_aliases]]
