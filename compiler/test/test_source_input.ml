open Alcotest
module V = Source_input
module H = Migration_history_sources
module I = Migration_inventory

let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let write path contents = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out contents)
let read path = In_channel.with_open_bin path In_channel.input_all
let rec disk path =
  let info = Unix.lstat path in
  let own = path, info.Unix.st_ino, info.Unix.st_mtime,
    (if info.Unix.st_kind = Unix.S_DIR then "<directory>" else read path) in
  own :: (if info.Unix.st_kind = Unix.S_DIR then
    Sys.readdir path |> Array.to_list |> List.sort compare |> List.concat_map (fun name -> disk (Filename.concat path name))
    else [])
let with_project f =
  let root = Filename.temp_file "tesl-source-view-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    write (Filename.concat root "tesl.toml") "";
    f root (Filename.concat root))
let overlay root files f =
  let before = disk root in
  Fun.protect ~finally:(fun () -> check bool "source view made no filesystem changes" true (disk root = before))
    (fun () -> V.with_overlays ~project_root:root files f)
let invalid f =
  match f () with
  | _ -> fail "expected source-view refusal"
  | exception Invalid_argument _ -> ()
let ds path = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let describe ds = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.file ^ ": " ^ d.code ^ ": " ^ d.message) ds)
let accepts path = let errors = ds path in if errors <> [] then fail (describe errors)
let rejects path = let errors = ds path in if errors = [] then fail "unexpected successful source check"; errors
let header name = "module " ^ name ^ " exposing []\n"
let replace before after = Str.global_replace (Str.regexp_string before) after
let schema_root revision = header ("NotesSchema." ^ revision) ^ "import NotesSchema." ^ revision ^ ".Notes\n"
let child revision extra = header ("NotesSchema." ^ revision ^ ".Notes") ^
  "import Tesl.Prelude exposing [String]\nimport Tesl.Maybe exposing [Maybe(..)]\n" ^
  "entity Note table \"notes\" primaryKey id { id: String, title: String" ^ extra ^ " }\n"
let migration = {|module NotesSchema.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import NotesSchema.V1
import NotesSchema.VCurrent
migration = Migration {
  from: NotesSchema.V1
  to: NotesSchema.VCurrent
  same: []
  entities: { NotesSchema.VCurrent.Notes.Note: Additive [] }
}
|}
let load path = match I.load ~compiler_abi:"test-source-view-1" ~root_file:path with
  | Ok inventory -> inventory | Error error -> fail error.message
let history root = match H.discover ~compiler_abi:"test-source-view-1" ~project_root:root ~family:"NotesSchema" with
  | Ok history -> history | Error error -> fail error.message
let saved_schema path =
  write (path "schema/notes/v-current.tesl") (schema_root "VCurrent");
  write (path "schema/notes/v-current/notes.tesl") (child "VCurrent" "")

let bytes () = with_project (fun root path ->
  let file = path "entry.tesl" in write file "saved\r\n";
  let contents = "# åäö\r\nmodule Preview exposing []\r\n\000" in
  overlay root [file, contents] (fun () ->
    check string "all source bytes retained" contents (V.read file);
    check string "text reads share the buffer" contents (V.read_text file);
    check string "disk still saved" "saved\r\n" (read file);
    check bool "regular input" true (V.kind file = Unix.S_REG));
  check string "scope restored saved input" "saved\r\n" (V.read file))

let virtual_tree () = with_project (fun root path ->
  let a = path "new/deep/a.tesl" and b = path "new/b.tesl" in
  overlay root [b, header "B"; a, header "A"] (fun () ->
    check bool "new file visible" true (V.exists a);
    check bool "virtual parent visible" true (V.is_directory (path "new/deep"));
    check (array string) "merged sorted directory" [|"b.tesl";"deep"|] (V.readdir (path "new"));
    check string "canonical virtual path" a (V.realpath (path "new/deep/../deep/a.tesl"));
    check string "alias reads same buffer" (header "A") (V.read (path "new/./deep/a.tesl"));
    check (list string) "project discovery includes proposals" [b;a] (Compile.collect_tesl_files root);
    accepts a);
  check bool "no parent created" false (Sys.file_exists (path "new"));
  check bool "view gone" false (V.exists a))

let nested () = with_project (fun root path ->
  let a = path "a.tesl" and b = path "b.tesl" in write a "disk";
  overlay root [a,"outer"] (fun () ->
    overlay root [a,"inner"; b,"new"] (fun () ->
      check string "inner overrides outer" "inner" (V.read a);
      check string "inner new source" "new" (V.read b));
    check string "outer restored" "outer" (V.read a);
    check bool "inner creation removed" false (V.exists b);
    (try overlay root [a,"broken"] (fun () -> raise Exit) with Exit -> ());
    check string "exception restores outer" "outer" (V.read a);
    invalid (fun () -> V.with_overlays ~project_root:root [a,"1";a,"2"] (fun () -> fail "invalid view entered"));
    check string "invalid scope preserves outer" "outer" (V.read a)));
  with_project (fun root path -> with_project (fun other _ ->
    overlay root [path "a.tesl","outer"] (fun () ->
      invalid (fun () -> V.with_overlays ~project_root:other [] (fun () -> ())))))

let bad_paths () = with_project (fun root path ->
  List.iter (fun file -> invalid (fun () -> V.with_overlays ~project_root:root [file,""] (fun () -> ())))
    ["relative.tesl"; root ^ "-neighbor/out.tesl"; path "../outside.tesl";
     path "x/../y.tesl"; path "./a.tesl"; path "tesl.toml"; path "a.tesl\000"];
  let directory = path "directory.tesl" in mkdir directory;
  invalid (fun () -> V.with_overlays ~project_root:root [directory,""] (fun () -> ()));
  let regular = path "regular.tesl" in write regular "";
  invalid (fun () -> V.with_overlays ~project_root:root [regular ^ "/child.tesl",""] (fun () -> ()));
  List.iter (fun files -> invalid (fun () -> V.with_overlays ~project_root:root files (fun () -> ())))
    [[path "a.tesl",""; path "a.tesl/child.tesl",""];
     [path "a.tesl/child.tesl",""; path "a.tesl",""]];
  overlay root [path "a.tesl",""] (fun () ->
    invalid (fun () -> V.with_overlays ~project_root:root [path "a.tesl/child.tesl",""] (fun () -> ()))))

let special_paths () = with_project (fun root path ->
  write (path "target.tesl") "";
  Unix.symlink (path "target.tesl") (path "alias.tesl");
  mkdir (path "real"); Unix.symlink (path "real") (path "alias");
  Unix.mkfifo (path "fifo.tesl") 0o600;
  List.iter (fun file -> invalid (fun () -> V.with_overlays ~project_root:root [path file,""] (fun () -> ())))
    ["alias.tesl";"alias/new.tesl";"fifo.tesl"])

let filesystem_semantics () = with_project (fun root path ->
  let file = path "target.tesl" and alias = path "alias.tesl" in
  write file "saved"; Unix.symlink file alias;
  V.with_overlays ~project_root:root [file,"buffer"] (fun () ->
    check string "existing alias resolves buffer" "buffer" (V.read alias);
    check bool "lstat retains symlink identity" true (V.kind alias = Unix.S_LNK);
    check bool "missing directory retains Sys_error channel" true
      (try ignore (V.readdir (path "missing")); false with Sys_error _ -> true)));
  with_project (fun root path ->
    saved_schema path;
    Unix.symlink (path "schema/notes/v-current.tesl") (path "schema/notes/v1.tesl");
    V.with_overlays ~project_root:root [path "schema/notes/v-current.tesl",schema_root "VCurrent"] (fun () ->
      match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
      | Error message -> check bool "freeze still rejects alias to a buffer" true
          (try ignore (Str.search_forward (Str.regexp_string "not a regular file") message 0); true with Not_found -> false)
      | Ok _ -> fail "freeze accepted symlink to overlaid source"))

let replaced_parent () = with_project (fun root path ->
  mkdir (path "dir"); mkdir (path "target");
  V.with_overlays ~project_root:root [path "dir/new.tesl","buffer"] (fun () ->
    Unix.rmdir (path "dir"); Unix.symlink (path "target") (path "dir");
    invalid (fun () -> V.read (path "dir/new.tesl"))));
  with_project (fun root path ->
    let file = path "a.tesl" in write file "disk"; write (path "target.tesl") "target";
    V.with_overlays ~project_root:root [file,"buffer"] (fun () ->
      Sys.remove file; Unix.symlink (path "target.tesl") file;
      invalid (fun () -> V.read file)))

let signatures () = with_project (fun root path ->
  let dep = path "dependency.tesl" and entry = path "entry.tesl" in
  let good = {|module Dependency exposing [value]
import Tesl.Prelude exposing [Int]
fn value() -> Int = 42
|} in
  let bad = {|module Dependency exposing [value]
import Tesl.Prelude exposing [String]
fn value() -> String = "42"
|} in
  write dep good; write entry {|module Entry exposing []
import Tesl.Prelude exposing [Int]
import Dependency exposing [value]
fn use() -> Int = value()
|};
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    accepts entry;
    overlay root [dep,bad] (fun () ->
      ignore (rejects entry);
      overlay root [dep,good] (fun () -> accepts entry);
      ignore (rejects entry));
    accepts entry;
    overlay root [dep,replace "42" "\"bad\"" good] (fun () ->
      let errors = rejects entry in
      check bool "private body error uses dependency path" true
        (List.exists (fun (d : Compile.diagnostic) -> d.file = dep) errors));
    accepts entry))

let malformed () = with_project (fun root path ->
  let dep = path "dependency.tesl" and entry = path "entry.tesl" in
  write dep (header "Dependency"); write entry (header "Entry" ^ "import Dependency\n");
  List.iter (fun source -> overlay root [dep,source] (fun () ->
    check bool "parse failure owned by unsaved dependency" true
      (List.exists (fun (d : Compile.diagnostic) -> d.file = dep) (rejects entry))))
    ["module Dependency exposing ["; "module Dependency exposing []\n#\n\"unterminated"];
  accepts entry)

let checked_inventory () = with_project (fun root path ->
  saved_schema path;
  let file = path "schema/notes/v-current.tesl" and dep = path "schema/notes/v-current/notes.tesl" in
  let saved = load file in
  overlay root [dep,child "VCurrent" ", archivedAt: Maybe String"] (fun () ->
    let fresh = load file in
    check bool "private stored field participates" true (I.snapshot saved <> I.snapshot fresh);
    check string "dependency guard uses buffer bytes" (Migration_hash.digest (V.read dep))
      (List.assoc dep (I.source_inputs fresh));
    check int "all private fields retained" 3 (List.length (I.stored_fields fresh)));
  check bool "saved inventory restored" true (I.snapshot saved = I.snapshot (load file));
  List.iter (fun extra -> overlay root [dep,child "VCurrent" "" ^ extra] (fun () ->
    match I.load ~compiler_abi:"test-source-view-1" ~root_file:file with
    | Ok _ -> fail "invalid private declaration escaped inventory"
    | Error _ -> ()))
    ["fn hidden() -> String = 42\n"; "handler get hidden() -> String = \"bad\"\n"])

let imported_proofs () = with_project (fun root path ->
  let lib = {|module Lib exposing [Msg, checkSafeTitle]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact SafeTitle (s: String)
check checkSafeTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s > 0 then
    ok s ::: SafeTitle s
  else
    fail 400 "empty"
record Msg { title: String }
|} in
  let app = {|module App exposing []
import Tesl.Prelude exposing [String]
import Lib exposing [Msg, checkSafeTitle]
fn make(raw: String) -> Msg = Msg { title: raw }
|} in
  let entry = path "app.tesl" and dependency = path "lib.tesl" in
  write entry app; write dependency lib;
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    accepts entry;
    overlay root [dependency, replace "title: String }" "title: String ::: SafeTitle title }" lib] (fun () ->
      let errors = rejects entry in
      check bool "new imported proof requirement enforced" true
        (List.exists (fun (d : Compile.diagnostic) ->
          try ignore (Str.search_forward (Str.regexp_string "proof") d.message 0); true with Not_found -> false) errors);
      overlay root [entry, replace "Msg { title: raw }" "\n  let title = check checkSafeTitle raw\n  Msg { title: title }" app]
        (fun () -> accepts entry));
    accepts entry))

let private_fact_closure () = with_project (fun root path ->
  let dep = path "schema/notes/v-current/notes.tesl" and file = path "schema/notes/v-current.tesl" in
  let source = {|module NotesSchema.VCurrent.Notes exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fact Positive (n: Int)
fn threshold() -> Int = 0
establish accept(n: Int) -> Maybe (value: Int ::: Positive value) =
  if n > threshold() then
    Something (n ::: Positive n)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, amount: Int ::: Positive amount }
|} in
  write file (schema_root "VCurrent"); write dep source;
  let saved = load file in
  overlay root [dep,replace "= 0" "= 1" source] (fun () ->
    let fresh = load file in
    check bool "private producer/helper changed invariant identity" true
      (Result.is_error (I.verify_same ~before:saved ~after:fresh
        ~previous:(Migration_ir.Predicate,"NotesSchema.VCurrent.Notes.Positive")
        ~current:(Migration_ir.Predicate,"NotesSchema.VCurrent.Notes.Positive"))));
  overlay root [dep,source ^ "fn invalid() -> Note = Note { id: \"x\", amount: -1 }\n"] (fun () ->
    match I.load ~compiler_abi:"test-source-view-1" ~root_file:file with
    | Ok _ -> fail "unproved entity construction accepted from buffer"
    | Error error -> check bool ("proof refusal: " ^ error.message) true
        (try ignore (Str.search_forward (Str.regexp_string "proof") error.message 0); true with Not_found -> false)))

let imported_effects () = with_project (fun root path ->
  let lib = {|module Lib exposing [readValue]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env]
import Tesl.Maybe exposing [Maybe(..)]
fn hidden(key: String) -> String requires [] = "saved"
fn readValue(key: String) -> String requires [] = hidden key
|} in
  let app = {|module App exposing []
import Tesl.Prelude exposing [String]
import Lib exposing [readValue]
fn run(key: String) -> String requires [] = readValue key
|} in
  let entry = path "app.tesl" and dep = path "lib.tesl" in
  write entry app; write dep lib; accepts entry;
  let effect_body = "case env key of\n    Something value -> value\n    Nothing -> \"\"" in
  overlay root [dep,replace "\"saved\"" effect_body lib] (fun () ->
    let errors = rejects entry in
    check bool "transitive capability requirement cannot use saved body" true
      (List.exists (fun (d : Compile.diagnostic) ->
        try ignore (Str.search_forward (Str.regexp_string "envRead") d.message 0); true with Not_found -> false) errors));
  accepts entry)

let virtual_cycles () = with_project (fun root path ->
  let source name imports body = header ("NotesSchema.VCurrent" ^ name) ^
    String.concat "" (List.map (fun name -> "import NotesSchema.VCurrent." ^ name ^ "\n") imports) ^ body in
  let inputs = [path "schema/notes/v-current.tesl",source "" ["A";"B"] "";
    path "schema/notes/v-current/a.tesl",source ".A" ["Shared"] "";
    path "schema/notes/v-current/b.tesl",source ".B" ["Shared"] "";
    path "schema/notes/v-current/shared.tesl",source ".Shared" ["A"]
      "import Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"] in
  overlay root inputs (fun () ->
    let inventory = load (path "schema/notes/v-current.tesl") in
    check int "cycle and diamond modules visited once" 4 (List.length (I.module_names inventory));
    check int "private table included once" 1 (List.length (I.stored_entities inventory));
    accepts (path "schema/notes/v-current.tesl")))

let stale_view_guards () = with_project (fun root path ->
  saved_schema path;
  let saved = history root in
  let changed files = overlay root files (fun () ->
    match H.verify_unchanged saved with
    | Error error -> check bool "guard identifies changed input view" true (error.kind = H.Changed_source)
    | Ok () -> fail "stale source-view guard passed") in
  changed [path "schema/notes/v-current/notes.tesl",child "VCurrent" ", archivedAt: Maybe String"];
  changed [path "schema/notes/v1.tesl",schema_root "V1"];
  changed [path "schema/notes/notes-schema.-v-current.-notes.tesl",child "VCurrent" ""];
  check bool "saved guards restored" true (H.verify_unchanged saved = Ok ()))

let virtual_history () = with_project (fun root path ->
  saved_schema path;
  let inputs = [
    path "schema/notes/v1.tesl", schema_root "V1";
    path "schema/notes/v1/notes.tesl", child "V1" "";
    path "schema/notes/v-current/notes.tesl", child "VCurrent" ", archivedAt: Maybe String";
    path "migrations/notes/v2.tesl", migration] in
  let preview = overlay root inputs (fun () ->
    let history = history root in
    check int "proposed frozen version visible" 2 (H.current history).version;
    check int "all source inputs guarded" 5 (List.length (H.source_inputs history));
    check bool "view guards hold" true (H.verify_unchanged history = Ok ());
    accepts (path "migrations/notes/v2.tesl");
    history) in
  check bool "preview is not saved-history evidence" true (Result.is_error (H.verify_unchanged preview));
  check int "disk still has initial version" 1 (H.current (history root)).version)

let shadow_and_numbering () = with_project (fun root path ->
  saved_schema path;
  let root_file = path "schema/notes/v-current.tesl" in
  overlay root [path "schema/notes/notes-schema.-v-current.-notes.tesl", child "VCurrent" ""] (fun () ->
    check bool "flat alias has ordinary resolver precedence" true
      (Validation_common.resolve_local_import_path root_file "NotesSchema.VCurrent.Notes" <> path "schema/notes/v-current/notes.tesl");
    check bool "history refuses noncanonical import" true
      (Result.is_error (H.discover ~compiler_abi:"test" ~project_root:root ~family:"NotesSchema")));
  overlay root [path "schema/notes/v01.tesl",header "Invalid"] (fun () ->
    match H.discover ~compiler_abi:"test" ~project_root:root ~family:"NotesSchema" with
    | Error error -> check bool "bad proposed version refuses" true (error.kind = H.Invalid_layout)
    | Ok _ -> fail "noncanonical virtual version ignored"))

let freeze_preview () = with_project (fun root path ->
  saved_schema path;
  overlay root [path "schema/notes/v-current/notes.tesl", child "VCurrent" ", archivedAt: Maybe String"] (fun () ->
    let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
      | Ok copies -> copies | Error message -> fail message in
    check int "complete freeze proposal" 2 (List.length copies);
    let proposed = List.map (fun (c : Migration_source.frozen_copy) -> c.target_path,c.contents) copies in
    overlay root proposed (fun () ->
      let before = load (path "schema/notes/v-current.tesl") and after = load (path "schema/notes/v1.tesl") in
      check bool "frozen preview has identical canonical semantics" true (I.snapshot before = I.snapshot after);
      match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
      | Ok copies -> check int "already present virtual copies retained" 0 (List.length copies)
      | Error message -> fail message)))

let differential () = with_project (fun root path -> with_project (fun saved saved_path ->
  let inputs = ["schema/notes/v-current.tesl",schema_root "VCurrent";
    "schema/notes/v-current/notes.tesl",child "VCurrent" ", archivedAt: Maybe String"] in
  List.iter (fun (file,source) -> write (saved_path file) source) inputs;
  let actual = history saved in
  overlay root (List.map (fun (file,source) -> path file,source) inputs) (fun () ->
    let preview = history root in
    check bool "fully virtual project matches saved compiler judgment" true
      (I.snapshot (H.current actual).inventory = I.snapshot (H.current preview).inventory);
    check (list string) "identical input byte hashes" (List.map snd (H.source_inputs actual))
      (List.map snd (H.source_inputs preview)))) )

let () = run "Read-only source views" ["regressions", List.map (fun (name,f) -> test_case name `Quick f)
  ["raw source bytes and saved fallback",bytes; "new files and directories",virtual_tree;
   "nested and exceptional restoration",nested; "invalid and conflicting paths",bad_paths;
   "symlinks and special files",special_paths; "filesystem read semantics",filesystem_semantics;
   "parent/source replacement",replaced_parent;
   "dependency signatures and retained query caches",signatures; "unsaved syntax errors",malformed;
   "complete private inventory checking",checked_inventory; "imported proof requirements",imported_proofs;
   "private fact producers and proof refusal",private_fact_closure; "imported transitive effects",imported_effects;
   "virtual cycles and diamonds",virtual_cycles; "stale input-view guards",stale_view_guards;
   "virtual history and migration checking",virtual_history;
   "import shadows and invalid revisions",shadow_and_numbering; "checked freeze proposal",freeze_preview;
   "saved versus fully virtual differential",differential]]
