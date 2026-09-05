open Alcotest
module S = Migration_seal
module I = Migration_inventory

let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace before after = Str.global_replace (Str.regexp_string before) after
let source = {|module NotesSchema.VCurrent.Notes exposing []
import Tesl.Prelude exposing [String, Int]
fn privateValue() -> Int = 42
entity Note table "notes" primaryKey id { id: String, title: String }
|}
let with_project f =
  let root = Filename.temp_file "tesl-snapshot-seal-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    write (path "schema/notes/v-current.tesl") "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Notes\n";
    write (path "schema/notes/v-current/notes.tesl") source;
    f root path)
let get = function Ok value -> value | Error (error : S.error) -> fail error.message
let load ?(abi="compiler-A") path = match I.load ~compiler_abi:abi ~root_file:path with
  | Ok value -> value | Error error -> fail error.message
let seal root path = get (S.create ~project_root:root (load (path "schema/notes/v-current.tesl")))
let verifies root record =
  let sources = get (S.verify_sources ~project_root:root record) in
  get (S.verify_semantics ~compiler_abi:"compiler-A" sources)
let refuses kind = function
  | Ok _ -> fail "expected snapshot-seal refusal"
  | Error (error : S.error) -> check bool error.message true (kind = error.kind)
let rec files path =
  if Sys.is_directory path then
    Sys.readdir path |> Array.to_list |> List.sort compare |> List.concat_map (fun name -> files (Filename.concat path name))
  else [path,read path]

let roundtrip () = with_project (fun root path ->
  let before = files root in
  let record = seal root path in
  let encoded = S.encode record in
  check string "stable encoding" encoded (S.encode (get (S.decode encoded)));
  check string "CRLF metadata reads canonically" encoded
    (S.encode (get (S.decode (replace "\n" "\r\n" encoded))));
  check (list string) "complete private source set" ["NotesSchema.VCurrent";"NotesSchema.VCurrent.Notes"]
    (List.map fst (S.sources record));
  let verified = verifies root record in
  check string "semantic digest checked" (S.snapshot_digest record)
    (Migration_canonical.digest Snapshot (I.snapshot verified));
  check (list (pair string string)) "seal operations do not write" before (files root))

let abi_bytes () = with_project (fun root path ->
  List.iter (fun abi ->
    let inventory = load ~abi (path "schema/notes/v-current.tesl") in
    let record = get (S.create ~project_root:root inventory) in
    let decoded = get (S.decode (S.encode record)) in
    check string "ABI bytes are lossless" abi (S.compiler_abi decoded))
    ["compiler-A";"compiler/1.2+build-3";"compiler åäö\r\n\t\000"])

let malformed_records () = with_project (fun root path ->
  let record = seal root path in let encoded = S.encode record in
  List.iter (fun text -> refuses S.Invalid_record (S.decode text))
    ["";encoded ^ "# trailing\n";replace ":v1 " ":v2 " encoded;
     replace "compiler-A" "" "not a header";
     replace "636f6d70696c65722d41" "z" encoded;
     replace "636f6d70696c65722d41" "20" encoded;
     replace (S.snapshot_digest record) "bad" encoded;
     replace "NotesSchema.VCurrent " "NotesSchema.V2147483647 " encoded;
     replace "NotesSchema.VCurrent.Notes" "OtherSchema.VCurrent.Notes" encoded;
     replace "NotesSchema.VCurrent.Notes" "NotesSchema.VCurrent../Escape" encoded;
     replace "# tesl:snapshot-end\n" "" encoded];
  let lines = String.split_on_char '\n' encoded in
  let root_line = List.nth lines 1 and child_line = List.nth lines 2 in
  refuses S.Invalid_record (S.decode (replace (root_line ^ "\n") "" encoded));
  refuses S.Invalid_record (S.decode (replace (child_line ^ "\n") (child_line ^ "\n" ^ child_line ^ "\n") encoded));
  refuses S.Invalid_record (S.decode (replace (root_line ^ "\n" ^ child_line) (child_line ^ "\n" ^ root_line) encoded)))

let every_byte () = with_project (fun root path ->
  let record = seal root path in
  let file = path "schema/notes/v-current/notes.tesl" in
  List.iter (fun changed ->
    write file changed;
    refuses S.Changed_source (S.verify_sources ~project_root:root record))
    [replace "42" "43" source; "# a comment\n" ^ source;
     replace "\n" "\r\n" source; source ^ "\000"; "module Broken exposing ["];
  write file source; ignore (verifies root record))

let stale_inventory () = with_project (fun root path ->
  let inventory = load (path "schema/notes/v-current.tesl") in
  write (path "schema/notes/v-current/notes.tesl") (replace "42" "43" source);
  refuses S.Changed_source (S.create ~project_root:root inventory))

let omitted_source () = with_project (fun root path ->
  let record = seal root path in
  let child_line = "# tesl:snapshot-source NotesSchema.VCurrent.Notes " ^ List.assoc "NotesSchema.VCurrent.Notes" (S.sources record) ^ "\n" in
  let incomplete = get (S.decode (replace child_line "" (S.encode record))) in
  refuses S.Invalid_record (S.verify_sources ~project_root:root incomplete);
  let extra = "module NotesSchema.VCurrent.Unused exposing []\n" in
  write (path "schema/notes/v-current/unused.tesl") extra;
  ignore (verifies root record);
  let added = "# tesl:snapshot-source NotesSchema.VCurrent.Unused " ^ Migration_hash.digest extra ^ "\n" in
  let excessive = get (S.decode (replace "# tesl:snapshot-end" (added ^ "# tesl:snapshot-end") (S.encode record))) in
  refuses S.Invalid_record (S.verify_sources ~project_root:root excessive))

let changed_abi () = with_project (fun root path ->
  let record = seal root path in
  let checked = get (S.verify_sources ~project_root:root record) in
  refuses S.Abi_mismatch (S.verify_semantics ~compiler_abi:"compiler-B" checked);
  let b = load ~abi:"compiler-B" (path "schema/notes/v-current.tesl") in
  check bool "a new compiler has another semantic snapshot" true
    (S.snapshot_digest record <> Migration_canonical.digest Snapshot (I.snapshot b));
  ignore (S.verify_sources ~project_root:root record |> get);
  write (path "schema/notes/v-current/notes.tesl") (source ^ "# edited\n");
  refuses S.Changed_source (S.verify_semantics ~compiler_abi:"compiler-B" checked))

let semantic_mismatch () = with_project (fun root path ->
  let record = seal root path in
  let corrupt = get (S.decode (replace (S.snapshot_digest record) (String.make 64 '0') (S.encode record))) in
  let checked = get (S.verify_sources ~project_root:root corrupt) in
  refuses S.Semantic_mismatch (S.verify_semantics ~compiler_abi:"compiler-A" checked))

let metadata_is_not_validation () = with_project (fun root path ->
  let record = seal root path in
  let file = path "schema/notes/v-current/notes.tesl" in
  let old_digest = List.assoc "NotesSchema.VCurrent.Notes" (S.sources record) in
  List.iter (fun invalid_source ->
    write file invalid_source;
    let forged = get (S.decode (replace old_digest (Migration_hash.digest invalid_source) (S.encode record))) in
    let checked = get (S.verify_sources ~project_root:root forged) in
    refuses S.Invalid_schema (S.verify_semantics ~compiler_abi:"compiler-A" checked))
    [source ^ "fn broken() -> Int = \"bad\"\n";
     source ^ "handler get broken() -> Int = 1\n";
     source ^ "fact Positive (n: Int)\nfn fabricate(n: Int) -> Int ::: Positive n = n ::: Positive n\n"])

let exact_module_headers () = with_project (fun root path ->
  let record = seal root path in
  let encoded = S.encode record in
  let old_digest = List.assoc "NotesSchema.VCurrent.Notes" (S.sources record) in
  let bad = replace "NotesSchema.VCurrent.Notes" "NotesSchema.VCurrent.Other" source in
  write (path "schema/notes/v-current/notes.tesl") bad;
  let forged = get (S.decode (replace old_digest (Migration_hash.digest bad) encoded)) in
  refuses S.Invalid_schema (S.verify_sources ~project_root:root forged))

let repeated_virtual_changes () = with_project (fun root path ->
  let record = seal root path and file = path "schema/notes/v-current/notes.tesl" in
  let original = files root in
  let check_source_view source = Source_input.with_overlays ~project_root:root [file,source] in
  let checked = get (S.verify_sources ~project_root:root record) in
  List.iter (fun changed ->
    check_source_view changed (fun () ->
      refuses S.Changed_source (S.verify_sources ~project_root:root record);
      refuses S.Changed_source (S.verify_semantics ~compiler_abi:"compiler-A" checked));
    ignore (verifies root record)) [replace "42" "43" source; source ^ "# unsaved\n"];
  check (list (pair string string)) "failed unsaved checks do not write" original (files root))

let path_integrity () =
  List.iter (fun mode -> with_project (fun root path ->
    let record = seal root path in let file = path "schema/notes/v-current/notes.tesl" in
    Sys.remove file;
    (match mode with
     | "missing" -> ()
     | "fifo" -> Unix.mkfifo file 0o600
     | "directory" -> Unix.mkdir file 0o700
     | "symlink" -> write (path "elsewhere.tesl") source; Unix.symlink (path "elsewhere.tesl") file
     | _ -> assert false);
    refuses (if mode = "missing" then S.Missing_source else S.Invalid_layout)
      (S.verify_sources ~project_root:root record))) ["missing";"fifo";"directory";"symlink"]

let import_shadow () = with_project (fun root path ->
  let record = seal root path in
  write (path "schema/notes/notes-schema.-v-current.-notes.tesl") source;
  refuses S.Invalid_layout (S.verify_sources ~project_root:root record))

let frozen_preview () = with_project (fun root path ->
  let current = seal root path in
  let original = files root in
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
    | Ok copies -> copies | Error message -> fail message in
  let proposed = List.map (fun (copy : Migration_source.frozen_copy) -> copy.target_path,copy.contents) copies in
  let frozen = Source_input.with_overlays ~project_root:root proposed (fun () ->
    let inventory = load (path "schema/notes/v1.tesl") in
    let frozen = get (S.create ~project_root:root inventory) in
    check string "frozen semantics retain version alpha-renaming" (S.snapshot_digest current) (S.snapshot_digest frozen);
    ignore (verifies root frozen);
    frozen) in
  check (list (pair string string)) "seal preview never writes" original (files root);
  refuses S.Missing_source (S.verify_sources ~project_root:root frozen);
  List.iter (fun (file,source) -> write file source) proposed;
  ignore (verifies root frozen))

let input_change_after_verification () = with_project (fun root path ->
  let record = seal root path in
  let checked = get (S.verify_sources ~project_root:root record) in
  check int "source preconditions retained" 2 (List.length (S.source_inputs checked));
  write (path "schema/notes/v-current/notes.tesl") (replace "42" "43" source);
  refuses S.Changed_source (S.verify_semantics ~compiler_abi:"compiler-A" checked))

let () = run "Snapshot source seals" ["integrity",List.map (fun (name,f) -> test_case name `Quick f)
  ["complete deterministic roundtrip",roundtrip; "ABI byte encoding",abi_bytes;
   "strict metadata validation",malformed_records; "private edits and raw bytes",every_byte;
   "stale checked inventory",stale_inventory; "omitted and unowned sources",omitted_source;
   "source integrity across compiler ABIs",changed_abi; "semantic mismatch",semantic_mismatch;
   "metadata cannot replace type/proof checks",metadata_is_not_validation;
   "exact owned module headers",exact_module_headers; "repeated unsaved source changes",repeated_virtual_changes;
   "canonical regular input paths",path_integrity; "changed import resolution",import_shadow;
   "fully checked virtual freeze",frozen_preview; "stale source verification",input_change_after_verification]]
