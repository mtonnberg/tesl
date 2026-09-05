open Alcotest
module G = Migration_generate
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec files root = Sys.readdir root |> Array.to_list |> List.concat_map (fun name ->
  let path = Filename.concat root name in if Sys.is_directory path then files path else [path,read path]) |> List.sort compare
let checked file source =
  let result = Compile.agent_context_result_source file source in
  if not result.ok then fail result.json
let root_source = "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Notes\n"
let child_source = {|module NotesSchema.VCurrent.Notes exposing [Note, Payload]
import Tesl.Prelude exposing [String]
record Payload { value: String }
entity Note table "notes" primaryKey id { id: String, title: String }
|}
let with_project f =
  let root = Filename.temp_file "tesl-migration-generate-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    write (path "schema/notes/v-current.tesl") root_source;
    write (path "schema/notes/v-current/notes.tesl") child_source;
    checked (path "schema/notes/v-current.tesl") root_source;
    f root path)
let get = function Ok x -> x | Error errors -> fail (String.concat "\n" (List.map (fun (e : G.error) -> e.path ^ ": " ^ e.message) errors))
let start ?(abi="fixture-ABI") ?(documents=[]) root version =
  G.start ~compiler_abi:abi ~project_root:root ~family:"NotesSchema" ~version ~documents
let refuse result = match result with Error (_::_) -> () | _ -> fail "invalid history was generated"
let check_same_markers file source ~previous ~current =
  let view = match Migration_source_syntax.read ~file ~source with Ok v -> v | Error e -> fail e.message in
  let c = List.find_map (function Ast.DConst c when c.name = "migration" -> Some c | _ -> None)
    (Migration_source_syntax.module_ view).decls |> Option.get in
  match Migration_form.application c.value with
  | "Migration",[Ast.ERecord {fields;_}] -> (match List.assoc "same" fields with
    | Ast.EList {elems;_} -> List.iter (fun expression ->
      match Migration_form.application expression with
      | "Same",[Ast.EConstructor {name;_};_] ->
        let id = "same:" ^ String.sub name (String.length previous + 1) (String.length name - String.length previous - 1) in
        check bool "generator marker remains valid across freeze" true
          (Migration_provenance.ownership view ~previous ~current ~id expression = Migration_provenance.Generated)
      | _ -> fail "generated Same shape") elems
    | _ -> fail "generated Same list")
  | _ -> fail "generated declaration"
let apply_fixture (preview : G.preview) =
  (* Test materialization only; the production apply protocol remains separate. *)
  (match M.verify_disk preview.manifest with Ok () -> () | Error _ -> fail "stale test proposal");
  List.iter (fun (e : M.edit) -> write e.path e.after) (M.edits preview.manifest);
  List.iter (fun (e : M.edit) -> checked e.path e.after) (M.edits preview.manifest)
let first () = with_project (fun root path ->
  let original = files root in
  let preview = get (start root 1) in
  check int "freezes selected version" 1 preview.frozen_version;
  check int "new current version" 2 preview.current_version;
  check int "root, private child, migration" 3 (List.length (M.edits preview.manifest));
  check (list (pair string string)) "no source writes" original (files root);
  let again = get (start root 1) in
  check string "repeated preview is deterministic" (M.to_json preview.manifest) (M.to_json again.manifest);
  apply_fixture preview;
  check_same_markers (path "migrations/notes/v2.tesl") (read (path "migrations/notes/v2.tesl"))
    ~previous:"NotesSchema.V1" ~current:"NotesSchema.VCurrent";
  check string "live root unchanged" root_source (read (path "schema/notes/v-current.tesl"));
  check string "live private entity unchanged" child_source (read (path "schema/notes/v-current/notes.tesl"));
  refuse (start root 1))
let next_revision () = with_project (fun root path ->
  apply_fixture (get (start root 1));
  let old = read (path "migrations/notes/v2.tesl") in
  let preview = get (start root 2) in
  check int "next freeze includes previous migration edit" 4 (List.length (M.edits preview.manifest));
  check string "previous migration unchanged until apply" old (read (path "migrations/notes/v2.tesl"));
  apply_fixture preview;
  let finalized = read (path "migrations/notes/v2.tesl") in
  check_same_markers (path "migrations/notes/v2.tesl") finalized ~previous:"NotesSchema.V1" ~current:"NotesSchema.V2";
  check bool "completed source no longer imports current" false
    (try ignore (Str.search_forward (Str.regexp_string "import NotesSchema.VCurrent") finalized 0); true with Not_found -> false);
  apply_fixture (get (start root 3));
  check string "older migration remains byte identical" finalized (read (path "migrations/notes/v2.tesl")))
let user_helpers () = with_project (fun root path ->
  apply_fixture (get (start root 1));
  let file = path "migrations/notes/v2.tesl" in
  let helper = path "migrations/notes/v2-helpers.tesl" in
  let source = {|module NotesSchema.Migrate.V2Helpers exposing [identity]
import NotesSchema.VCurrent.Notes exposing [Note]
# NotesSchema.VCurrent is literal commentary, not a reference to rewrite.
fn identity(note: NotesSchema.VCurrent.Notes.Note) -> NotesSchema.VCurrent.Notes.Note = note
|} in
  write helper source; checked helper source;
  let original = read file in
  let extra = "\n# User regression remains unchanged.\ntest \"still here\" { expect 1 == 1 }\n" in
  let source = replace "import Tesl.Migration" "import NotesSchema.Migrate.V2Helpers\nimport Tesl.Migration" original ^ extra in
  write file source; checked file source;
  let preview = get (start root 2) in apply_fixture preview;
  let finalized = read file in
  check bool "user test preserved exactly" true (String.ends_with ~suffix:extra finalized);
  let helper_source = read helper in
  check string "only helper's code references change" {|module NotesSchema.Migrate.V2Helpers exposing [identity]
import NotesSchema.V2.Notes exposing [Note]
# NotesSchema.VCurrent is literal commentary, not a reference to rewrite.
fn identity(note: NotesSchema.V2.Notes.Note) -> NotesSchema.V2.Notes.Note = note
|} helper_source)
let current_drift () = with_project (fun root path ->
  apply_fixture (get (start root 1));
  let file = path "schema/notes/v-current/notes.tesl" in
  write file (read file ^ "# edited before freeze\n");
  let before = files root in refuse (start root 2);
  check (list (pair string string)) "refusal does not patch history" before (files root))
let frozen_drift () = with_project (fun root path ->
  apply_fixture (get (start root 1));
  let file = path "schema/notes/v1/notes.tesl" in
  write file (read file ^ "# corrupt frozen bytes\n");
  refuse (start root 2))
let abi_change () = with_project (fun root _ ->
  apply_fixture (get (start root 1));
  refuse (start ~abi:"different-ABI" root 2);
  ignore (get (start root 2)))
let missing_current () = with_project (fun root path ->
  apply_fixture (get (start root 1));
  Sys.remove (path "migrations/notes/v2.tesl");
  refuse (start root 2))
let unsaved_initial () = with_project (fun root path ->
  let file = path "schema/notes/v-current/notes.tesl" in
  let source = child_source ^ "\n# unsaved schema source\n" in
  let document = {M.path=file;version=11} in
  let preview = Source_input.with_overlays ~project_root:root [file,source] (fun () ->
    checked file source;
    get (start ~documents:[document] root 1)) in
  let target = path "schema/notes/v1/notes.tesl" in
  let edit = List.find (fun (e : M.edit) -> e.path = target) (M.edits preview.manifest) in
  check string "frozen copy is from checked buffer" (replace "NotesSchema.VCurrent" "NotesSchema.V1" source) edit.after;
  check string "disk remains separate" child_source (read file);
  (match M.verify_disk preview.manifest with Ok () -> () | Error _ -> fail "saved guard changed");
  (match M.verify_source preview.manifest ~documents:[document] with Error _ -> () | Ok () -> fail "lost buffer accepted"))
let existing_private_target () = with_project (fun root path ->
  let target = path "schema/notes/v1/notes.tesl" in
  write target (replace "NotesSchema.VCurrent" "NotesSchema.V1" child_source);
  let preview = get (start root 1) in
  check bool "equal preexisting child not overwritten" false (List.exists (fun (e : M.edit) -> e.path = target) (M.edits preview.manifest));
  write target (read target ^ "# concurrent target edit\n");
  match M.verify_disk preview.manifest with Error _ -> () | Ok () -> fail "unwritten target dependency was not guarded")
let invalid_schema () = with_project (fun root path ->
  let file = path "schema/notes/v-current/notes.tesl" in
  write file (child_source ^ "\nfn invalid() -> String = 1\n");
  refuse (start root 1);
  check bool "no frozen output" false (Sys.file_exists (path "schema/notes/v1.tesl")))
let stale_preview () = with_project (fun root path ->
  let preview = get (start root 1) in
  write (path "migrations/notes/v2.tesl") "user created this\n";
  match M.verify_disk preview.manifest with Error _ -> () | Ok () -> fail "concurrent history creation accepted")
let codec_and_type () = with_project (fun root path ->
  let file = path "schema/notes/v-current/notes.tesl" in
  let source = {|module NotesSchema.VCurrent.Notes exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Payload { text: String }
codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, payload: Payload }
|} in
  write file source; checked file source;
  apply_fixture (get (start root 1));
  let file = path "migrations/notes/v2.tesl" in
  let source = read file in
  let occurrences = Str.full_split (Str.regexp_string "Same NotesSchema.V1.Notes.Payload NotesSchema.VCurrent.Notes.Payload") source
    |> List.filter (function Str.Delim _ -> true | Str.Text _ -> false) in
  check int "record and codec share one surface claim" 1 (List.length occurrences);
  let m = match Parser.parse_module file source with Ok m -> m | Err e -> fail e.msg in
  match Migration_declaration.check ~compiler_abi:"fixture-ABI" ~source m with
  | Ok (Some d) -> check int "claim verifies both namespaces" 2
      (List.length (Migration_sparse.identities (Migration_declaration.coverage d)))
  | _ -> fail "generated declaration not checked")
let proved_schema () = with_project (fun root path ->
  let file = path "schema/notes/v-current/notes.tesl" in
  let source = {|module NotesSchema.VCurrent.Notes exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fact Positive (n: Int)
establish accept(n: Int) -> Maybe (value: Int ::: Positive value) =
  if n > 0 then
    Something (n ::: Positive n)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, amount: Int ::: Positive amount }
|} in
  write file source; checked file source;
  apply_fixture (get (start root 1));
  apply_fixture (get (start root 2));
  let broken = source ^ "fn fabricate(n: Int) -> Int ::: Positive n = n\n" in
  write file broken;
  let ds = Compile.check_source file broken in
  check bool "fixture includes a proof failure" true (List.exists (fun (d : Compile.diagnostic) ->
    d.severity = "error" && d.code <> "MIG001") ds);
  refuse (start root 3))
let shared_helper () = with_project (fun root path ->
  apply_fixture (get (start root 1)); apply_fixture (get (start root 2));
  let helper = path "migrations/notes/shared.tesl" in
  let source = {|module NotesSchema.Migrate.Shared exposing [identity]
import NotesSchema.VCurrent.Notes exposing [Note]
fn identity(note: NotesSchema.VCurrent.Notes.Note) -> NotesSchema.VCurrent.Notes.Note = note
|} in
  write helper source; checked helper source;
  List.iter (fun version ->
    let file = path ("migrations/notes/v" ^ string_of_int version ^ ".tesl") in
    let source = replace "import Tesl.Migration" "import NotesSchema.Migrate.Shared\nimport Tesl.Migration" (read file) in
    write file source; checked file source) [2;3];
  let before = files root in refuse (start root 3);
  check (list (pair string string)) "shared history is never rewritten" before (files root))
let () = run "Migration revision previews" ["checked generation", List.map (fun (name,f) -> test_case name `Quick f)
  ["complete first freeze and deterministic preview",first;"successive freezes finalize targets",next_revision;
   "user helpers, comments and tests survive",user_helpers;"current drift needs refresh",current_drift;
   "edited frozen source refuses",frozen_drift;"recorded target requires actual ABI",abi_change;
   "missing current migration refuses",missing_current;"unsaved private source is frozen",unsaved_initial;
   "preexisting equal private targets are guarded",existing_private_target;
   "unproven or ill-typed schema cannot generate",invalid_schema;"concurrent history creation",stale_preview;
   "same-named record and codec claims",codec_and_type;"private persisted facts stay checked",proved_schema;
   "shared completed migration helper refuses rewrite",shared_helper]]
