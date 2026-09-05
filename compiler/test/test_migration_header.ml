open Alcotest
module H = Migration_header
module S = Migration_seal

let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace before after = Str.global_replace (Str.regexp_string before) after
let root_source version = "module NotesSchema." ^ version ^ " exposing []\nimport NotesSchema." ^ version ^ ".Notes\n"
let child version extra = "module NotesSchema." ^ version ^ ".Notes exposing []\n" ^
  "import Tesl.Prelude exposing [String]\nimport Tesl.Maybe exposing [Maybe(..)]\n" ^
  "entity Note table \"notes\" primaryKey id { id: String, title: String" ^ extra ^ " }\n"
let body = {|module NotesSchema.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import NotesSchema.V1
import NotesSchema.VCurrent
migration = Migration {
  from: NotesSchema.V1
  to: NotesSchema.VCurrent
  same: []
  entities: { Notes.Note: Additive [] }
}
|}
let show errors = String.concat "\n" (List.map (fun (e : Migration_sparse.error) -> e.code ^ ": " ^ e.message) errors)
let get = function Ok value -> value | Error errors -> fail (show errors)
let seal root path =
  let inventory = match Migration_inventory.load ~compiler_abi:"recorded-compiler-A" ~root_file:path with
    | Ok value -> value | Error error -> fail error.message in
  match S.create ~project_root:root inventory with Ok seal -> seal | Error error -> fail error.message
let header root path = get (H.create ~previous:(seal root (path "schema/notes/v1.tesl"))
  ~current:(seal root (path "schema/notes/v-current.tesl")))
let with_project f =
  let root = Filename.temp_file "tesl-migration-header-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in write (path "tesl.toml") "";
    List.iter (fun version ->
      write (path ("schema/notes/" ^ String.lowercase_ascii version ^ ".tesl")) (root_source version);
      write (path ("schema/notes/" ^ String.lowercase_ascii version ^ "/notes.tesl")) (child version "")) ["V1"];
    write (path "schema/notes/v-current.tesl") (root_source "VCurrent");
    write (path "schema/notes/v-current/notes.tesl") (child "VCurrent" ", archivedAt: Maybe String");
    let file = path "migrations/notes/v2.tesl" in
    let source = H.encode (header root path) ^ body in
    write file source; f root path file source)
let diagnostics file source = Compile.check_source file source |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let describes ds = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let accepts file source = let ds = diagnostics file source in if ds <> [] then fail (describes ds)
let refuses code file source =
  let ds = diagnostics file source in
  if not (List.exists (fun (d : Compile.diagnostic) -> d.code = code) ds) then
    fail ("missing " ^ code ^ ":\n" ^ describes ds);
  ds
let checked root file source =
  let located = Option.get (get (H.read ~file source)) in
  get (H.verify ~project_root:root ~migration_module:"NotesSchema.Migrate.V2"
    ~previous:"NotesSchema.V1" ~current:"NotesSchema.VCurrent" located)

let complete_header () = with_project (fun root _ file source ->
  accepts file source;
  let verified = checked root file source in
  let old,fresh = H.seals verified in
  check string "recorded ABI retained without relabelling" "recorded-compiler-A" (S.compiler_abi old);
  check string "target recorded" "NotesSchema.VCurrent" (S.root_module fresh);
  get (H.verify_unchanged verified);
  match Compile.parse_module file source with
  | Parser.Err error -> fail error.msg
  | Parser.Ok m ->
    let declaration = Option.get (get (Migration_declaration.check ~compiler_abi:"fresh-source-comparison" ~source m)) in
    check bool "checked header retained on logical result" true (Option.is_some (Migration_declaration.source_seals declaration)))

let absent_header () = with_project (fun _ _ file _ ->
  check bool "plain source has no seal" true (get (H.read ~file body) = None);
  accepts file body;
  let m = match Compile.parse_module file body with Parser.Ok m -> m | Parser.Err e -> fail e.msg in
  let checked = Option.get (get (Migration_declaration.check ~compiler_abi:"test" ~source:body m)) in
  check bool "absence cannot masquerade as verified source" true (Migration_declaration.source_seals checked = None))

let private_edits () =
  List.iter (fun (revision,relative,code) -> with_project (fun _ path file source ->
    let dependency = path relative in
    write dependency (child revision "" ^ "# changed private source\n");
    let ds = refuses code file source in
    let d = List.find (fun (d : Compile.diagnostic) -> d.code = code) ds in
    check string "diagnostic belongs to migration" file d.file;
    check bool "private source location included" true
      (try ignore (Str.search_forward (Str.regexp_string dependency) d.message 0); true with Not_found -> false)))
    ["V1","schema/notes/v1/notes.tesl","MIG013";
     "VCurrent","schema/notes/v-current/notes.tesl","MIG001"]

let malformed_frozen () = with_project (fun _ path file source ->
  write (path "schema/notes/v1/notes.tesl") "module Broken exposing [";
  ignore (refuses "MIG013" file source))

let unsaved_header () = with_project (fun root path file old ->
  write (path "schema/notes/v-current/notes.tesl") (child "VCurrent" ", archivedAt: Maybe String, deletedAt: Maybe String");
  ignore (refuses "MIG001" file old);
  let fresh = get (H.replace ~file ~source:old (header root path)) in
  accepts file fresh;
  check string "checking unsaved header leaves saved file untouched" old (read file);
  ignore (refuses "MIG001" file old))

let malformed_metadata () = with_project (fun _ _ file source ->
  List.iter (fun broken -> ignore (refuses "MIG013" file broken))
    [replace "history:v1" "history:v2" source;
     replace "# tesl:migration-to\n" "" source;
     replace "# tesl:migration-history:end\n" "" source;
     replace "# tesl:migration-history:end\n" "# tesl:migration-history:end\n# tesl:migration-from\n" source;
     source |> replace "# tesl:migration-history:v1\n" "";
     "# tesl:snapshot-source orphan bad\n" ^ body];
  let prefix = String.sub source 0 (String.length source - String.length body) in
  ignore (refuses "MIG013" file (prefix ^ source)))

let wrong_edge () = with_project (fun _ _ file source ->
  ignore (refuses "MIG013" file (replace "from: NotesSchema.V1" "from: NotesSchema.VCurrent" source));
  ignore (refuses "MIG013" file (replace "tesl:snapshot-seal:v1 NotesSchema.V1 " "tesl:snapshot-seal:v1 OtherSchema.V1 " source)))

let preserve_source () = with_project (fun root path file source ->
  let prefix = "# License: åäö\r\n\r\n" in
  let suffix = "\n# user-owned helper\n" in
  let original = prefix ^ source ^ suffix in
  let result = get (H.replace ~file ~source:original (header root path)) in
  check string "replacement preserves surrounding source bytes" original result;
  accepts file result;
  let formatted = Formatter.format_source result in
  accepts file formatted;
  check bool "formatter retains readable metadata" true (Option.is_some (get (H.read ~file formatted)));
  accepts file (replace "\n" "\r\n" source))

let dependency_check () = with_project (fun _ path file source ->
  let helper = path "migrations/notes/verify.tesl" in
  let entry = "module NotesSchema.Migrate.Verify exposing []\nimport NotesSchema.Migrate.V2\n" in
  write helper entry; accepts helper entry;
  write (path "schema/notes/v1/notes.tesl") (child "V1" "" ^ "# modified\n");
  let ds = refuses "MIG013" helper entry in
  check bool "imported header diagnostic uses migration path" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "MIG013" && d.file = file) ds);
  check string "header source unchanged" source (read file))

let missing_sources () =
  List.iter (fun (relative,code) -> with_project (fun _ path file source ->
    Sys.remove (path relative); ignore (refuses code file source)))
    ["schema/notes/v1/notes.tesl","MIG013";"schema/notes/v-current/notes.tesl","MIG001"]

let frozen_target () = with_project (fun root path file source ->
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:2 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) -> write copy.target_path copy.contents) copies;
  let rewritten = match Migration_source.rewrite_version ~family:"NotesSchema" ~before:"VCurrent" ~after:"V2" source with
    | Ok value -> value | Error message -> fail message in
  ignore (refuses "MIG013" file rewritten);
  let completed = get (H.create ~previous:(seal root (path "schema/notes/v1.tesl"))
    ~current:(seal root (path "schema/notes/v2.tesl"))) in
  let finished = get (H.replace ~file ~source:rewritten completed) in
  accepts file finished;
  write (path "schema/notes/v2/notes.tesl") (child "V2" ", archivedAt: Maybe String" ^ "# edited frozen target\n");
  ignore (refuses "MIG013" file finished))

let unsaved_schema_and_header () = with_project (fun root path file source ->
  let fresh_child = child "VCurrent" ", archivedAt: Maybe String, deletedAt: Maybe String" in
  let dependency = path "schema/notes/v-current/notes.tesl" in
  let saved = read dependency in
  Source_input.with_overlays ~project_root:root [dependency,fresh_child] (fun () ->
    ignore (refuses "MIG001" file source);
    let refreshed = get (H.replace ~file ~source (header root path)) in
    accepts file refreshed;
    check string "schema buffer not saved by checking" saved (read dependency));
  accepts file source)

let direct_schema_buffers () =
  List.iter (fun (relative,code) -> with_project (fun _ path migration_file _ ->
    let file = path relative in let source = read file in
    accepts file source;
    let ds = refuses code file (source ^ "# unsaved source edit\n") in
    let own = List.filter (fun (d : Compile.diagnostic) -> d.code = code) ds in
    check int "one history diagnostic at direct schema entry" 1 (List.length own);
    check string "direct query diagnostic anchors to its source" file (List.hd own).file;
    check bool "recorded header is retained as related information" true
      (try ignore (Str.search_forward (Str.regexp_string migration_file) (List.hd own).message 0); true with Not_found -> false);
    check string "direct check does not save buffer" source (read file);
    accepts file source))
    ["schema/notes/v1.tesl","MIG013";"schema/notes/v1/notes.tesl","MIG013";
     "schema/notes/v-current.tesl","MIG001";"schema/notes/v-current/notes.tesl","MIG001"]

let direct_nested_view () = with_project (fun root path _ _ ->
  let file = path "schema/notes/v-current/notes.tesl" in
  let source = read file in
  Source_input.with_overlays ~project_root:(Filename.dirname root) [] (fun () ->
    ignore (refuses "MIG001" file (source ^ "# unsaved inside outer project view\n")));
  accepts file source)

let no_duplicate_dependency_diags () = with_project (fun _ path file source ->
  write (path "schema/notes/v-current/notes.tesl") (child "VCurrent" "" ^ "# changed\n");
  let ds = refuses "MIG001" file source in
  check int "schema dependencies do not duplicate migration's own check" 1
    (List.length (List.filter (fun (d : Compile.diagnostic) -> d.code = "MIG001") ds)))

let direct_broken_source () =
  List.iter (fun (relative,code) -> with_project (fun _ path _ _ ->
    let file = path relative in
    List.iter (fun broken ->
      let ds = refuses code file broken in
      check bool "parse failure also retained" true
        (List.exists (fun (d : Compile.diagnostic) -> d.code = "E000") ds);
      let snapshot = Compile.agent_context_result_source file broken in
      check bool "agent-context parse failure retains the same diagnostics" true
        (snapshot.diagnostics = Compile.check_source file broken);
      check bool "agent-context refuses malformed sealed source" false snapshot.ok;
      match Compile.compile_go_source file broken with
      | Compile.GoFailure diagnostics -> check bool "emitter shares parse diagnostics" true (diagnostics = snapshot.diagnostics)
      | Compile.GoSuccess _ -> fail "malformed sealed source emitted")
      ["module Broken exposing ["; "\"unterminated"];
    ignore (refuses code file (replace "NotesSchema" "OtherSchema" (read file)))))
    ["schema/notes/v1.tesl","MIG013";"schema/notes/v1/notes.tesl","MIG013";
     "schema/notes/v-current.tesl","MIG001";"schema/notes/v-current/notes.tesl","MIG001"]

let direct_symlinks () = with_project (fun _ path _ _ ->
  let file = path "schema/notes/v1.tesl" in
  let source = read file in
  write (path "replacement.tesl") source;
  Sys.remove file; Unix.symlink (path "replacement.tesl") file;
  ignore (refuses "MIG013" file source);
  Sys.remove file; write file source;
  let current = path "schema/notes/v-current/notes.tesl" in
  let source = read current in
  Unix.rename (path "schema/notes/v-current") (path "relocated");
  Unix.symlink (path "relocated") (path "schema/notes/v-current");
  ignore (refuses "MIG001" current source))

let project_alias_query () = with_project (fun root path _ _ ->
  let alias = root ^ "-alias" in
  Unix.symlink root alias;
  Fun.protect ~finally:(fun () -> Sys.remove alias) (fun () ->
    let file = Filename.concat alias "schema/notes/v-current/notes.tesl" in
    let source = read (path "schema/notes/v-current/notes.tesl") in
    accepts file source;
    ignore (refuses "MIG001" file (source ^ "# unsaved alias edit\n"))))

let misdirected_metadata () = with_project (fun _ path file source ->
  let prefix = String.sub source 0 (String.length source - String.length body) in
  let schema_file = path "schema/notes/v1.tesl" in
  let schema_source = read schema_file in
  List.iter (fun changed ->
    write file (changed ^ body);
    ignore (refuses "MIG013" schema_file schema_source))
    [replace "NotesSchema" "OtherSchema" prefix; replace "NotesSchema.V1" "NotesSchema.V4" prefix];
  write file source; accepts schema_file schema_source)

let with_app f = with_project (fun root path migration source ->
  let current = path "schema/notes/v-current/notes.tesl" in
  write current (replace "exposing []" "exposing [Note]" (read current));
  write migration (get (H.replace ~file:migration ~source (header root path)));
  let file = path "app.tesl" in
  let source = {|module App exposing [Db]
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
import NotesSchema.VCurrent.Notes exposing [Note]
database Db = Database { entities: [Note], backend: Memory }
|} in
  write file source; accepts file source;
  f root path file source)

let application_integrity () =
  List.iter (fun (relative,code) -> with_app (fun _ path file source ->
    let dependency = path relative in
    let saved = read dependency in
    List.iter (fun changed ->
      write dependency changed;
      let ds = refuses code file source in
      let matching = List.filter (fun (d : Compile.diagnostic) -> d.code = code) ds in
      check int "one integrity diagnostic per recorded change" 1 (List.length matching);
      let d = List.hd matching in
      check string "app query anchors integrity diagnostic" file d.file;
      check bool "changed dependency remains in message" true
        (try ignore (Str.search_forward (Str.regexp_string dependency) d.message 0); true with Not_found -> false);
      (match Compile.compile_go_file file with Compile.GoFailure _ -> ()
       | Compile.GoSuccess _ -> fail "changed recorded source emitted for app");
      write dependency saved; accepts file source)
      [saved ^ "# changed source\n"; replace "NotesSchema" "OtherSchema" saved; "module Broken exposing ["]))
    ["schema/notes/v1.tesl","MIG013";"schema/notes/v1/notes.tesl","MIG013";
     "schema/notes/v-current.tesl","MIG001";"schema/notes/v-current/notes.tesl","MIG001"]

let application_private_import () = with_app (fun root path file source ->
  let source = replace "import NotesSchema.VCurrent\n" "" source in
  write file source; accepts file source;
  let dependency = path "schema/notes/v-current/notes.tesl" in
  let saved = read dependency in
  Source_input.with_overlays ~project_root:root [dependency,saved ^ "# unsaved private source\n"] (fun () ->
    ignore (refuses "MIG001" file source));
  accepts file source;
  let root_file = path "schema/notes/v-current.tesl" in
  Sys.remove root_file;
  ignore (refuses "MIG001" file source);
  Unix.mkfifo root_file 0o600;
  ignore (refuses "MIG001" file source))

let () = run "Migration history headers" ["source diagnostics", List.map (fun (name,f) -> test_case name `Quick f)
  ["complete checked header",complete_header; "unsealed source remains explicit",absent_header;
   "current versus frozen private edits",private_edits; "malformed frozen source",malformed_frozen;
   "unsaved refreshed header wins",unsaved_header; "malformed and duplicate metadata",malformed_metadata;
   "header and declaration edges agree",wrong_edge; "source preservation and formatting",preserve_source;
   "transitively imported history diagnostics",dependency_check; "missing source classification",missing_sources;
   "next freeze replaces target seal",frozen_target; "unsaved schema plus refreshed header",unsaved_schema_and_header;
   "direct schema and private-module buffers",direct_schema_buffers; "direct query inside outer view",direct_nested_view;
   "no duplicate dependency diagnostics",no_duplicate_dependency_diags;
   "direct malformed source and changed module names",direct_broken_source;
   "recorded file/parent symlinks cannot hide changes",direct_symlinks;
   "canonical project alias queries",project_alias_query;
   "metadata cannot redirect a canonical history root",misdirected_metadata;
   "application imports enforce recorded source integrity",application_integrity;
   "private-only app imports and source views",application_private_import]]
