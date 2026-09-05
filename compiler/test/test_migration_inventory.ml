open Migration_ir
open Migration_canonical
open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-semantic-inventory-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok result -> result | Error error -> fail error.message
let load ?(abi="test-compiler-1") path = get (Migration_inventory.load ~compiler_abi:abi ~root_file:path)
let hash inventory = digest Snapshot (Migration_inventory.snapshot inventory)
let same inventory ns name = digest Same (get (Migration_inventory.closure inventory [ns, name]))
let replace before after = Str.global_replace (Str.regexp_string before) after
let expect_error message = function
  | Ok _ -> fail ("unexpected successful inventory: " ^ message)
  | Error error -> check bool (message ^ ": " ^ error.message) true
      (try ignore (Str.search_forward (Str.regexp_string message) error.message 0); true with Not_found -> false)

let prefix name = "module " ^ name ^ " exposing []\n"
let imports = "import Tesl.Prelude exposing [Int, String]\nimport Tesl.Maybe exposing [Maybe(..)]\n"
let notes = {|module NotesSchema.VCurrent.Notes exposing [Note, Positive, accept]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fact Positive (n: Int)
fn threshold() -> Int = 0
establish accept(n: Int) -> Maybe (value: Int ::: Positive value) =
  if n > threshold() then
    Something (n ::: Positive n)
  else
    Nothing
fn unused() -> Int = 90
entity Note table "notes" primaryKey id {
  id: String
  amount: Int ::: Positive amount
}
|}
let fixture write =
  ignore (write "schema/notes/v-current/notes.tesl" notes);
  write "schema/notes/v-current.tesl"
    (prefix "NotesSchema.VCurrent" ^ "import NotesSchema.VCurrent.Notes exposing []\n")

let complete_private_inventory () = with_project (fun _root write ->
  let path = fixture write in let inventory = load path in
  check (list string) "private module is owned despite empty exposing lists"
    ["NotesSchema.VCurrent"; "NotesSchema.VCurrent.Notes"] (Migration_inventory.module_names inventory);
  let original = same inventory Type "NotesSchema.VCurrent.Notes.Note" in
  let fact = same inventory Predicate "NotesSchema.VCurrent.Notes.Positive" in
  ignore (write "schema/notes/v-current/notes.tesl" (replace "= 0" "= 1" notes));
  let changed = load path in
  check bool "private validator dependency changes stored proof meaning" true
    (original <> same changed Type "NotesSchema.VCurrent.Notes.Note");
  check bool "fact closure follows its producer and private helper" true
    (fact <> same changed Predicate "NotesSchema.VCurrent.Notes.Positive");
  ignore (write "schema/notes/v-current/notes.tesl" (replace "= 90" "= 91" notes));
  let unrelated = load path in
  check bool "snapshot contains all declarations, even unreachable private helpers" true (hash inventory <> hash unrelated);
  check string "per-type closure excludes unrelated helpers" original
    (same unrelated Type "NotesSchema.VCurrent.Notes.Note"))

let frozen_and_source_invariance () = with_project (fun root write ->
  let path = fixture write in let original = load path in
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:8 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  let frozen = load (Filename.concat root "schema/notes/v8.tesl") in
  check string "complete frozen closure has the same snapshot" (hash original) (hash frozen);
  check string "Same roles alpha-rename only the schema revision"
    (same original Type "NotesSchema.VCurrent.Notes.Note") (same frozen Type "NotesSchema.V8.Notes.Note");
  ignore (write "schema/notes/v-current/notes.tesl" ("# comment\n" ^ replace "(n: Int)" "(input: Int)"
    (replace "n >" "input >" (replace "Something (n ::: Positive n)" "Something (input ::: Positive input)" notes))));
  check string "layout, comments and binders preserve meaning" (hash original) (hash (load path)))

let additional_fact_owner () = with_project (fun _root write ->
  let path = fixture write in let before = load path in
  let owner = {|establish additional(n: Int) -> Maybe (value: Int ::: Positive value) =
  if n > 10 then
    Something (n ::: Positive n)
  else
    Nothing
|} in
  ignore (write "schema/notes/v-current/notes.tesl" (notes ^ owner));
  let after = load path in
  check bool "an unexported additional fact producer must enter the closure" true
    (same before Type "NotesSchema.VCurrent.Notes.Note" <> same after Type "NotesSchema.VCurrent.Notes.Note"))

let private_codec () = with_project (fun _root write ->
  let source = prefix "NotesSchema.VCurrent" ^ imports ^ {|import Tesl.Json exposing [stringCodec]
record Payload { text: String }
codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
|} in
  let path = write "schema/notes/v-current.tesl" source in let original = load path in
  ignore (write "schema/notes/v-current.tesl" (replace "\"text\"" "\"body\"" source));
  check bool "a private codec is a reverse dependency of its type" true
    (same original Type "NotesSchema.VCurrent.Payload" <> same (load path) Type "NotesSchema.VCurrent.Payload"))

let import_graph () = with_project (fun _root write ->
  let root = prefix "NotesSchema.VCurrent" in
  let a = "import NotesSchema.VCurrent.A exposing []\n" in
  let b = "import NotesSchema.VCurrent.B exposing []\n" in
  let shared = "import NotesSchema.VCurrent.Shared exposing [answer]\n" in
  ignore (write "schema/notes/v-current/a.tesl" (prefix "NotesSchema.VCurrent.A" ^ imports ^ shared ^ "fn a() -> Int = answer()\n"));
  ignore (write "schema/notes/v-current/b.tesl" (prefix "NotesSchema.VCurrent.B" ^ imports ^ shared ^ "fn b() -> Int = answer()\n"));
  ignore (write "schema/notes/v-current/shared.tesl" ("module NotesSchema.VCurrent.Shared exposing [answer]\n" ^ imports ^ a ^ "fn answer() -> Int = 42\n"));
  let path = write "schema/notes/v-current.tesl" (root ^ a ^ b) in
  let original = load path in
  check int "diamond and cycle visit each owned module once" 4 (List.length (Migration_inventory.module_names original));
  ignore (write "schema/notes/v-current.tesl" (root ^ b ^ a));
  check string "import order cannot change a snapshot" (hash original) (hash (load path));
  ignore (write "schema/notes/v-current/a.tesl" (prefix "NotesSchema.VCurrent.A" ^ imports ^
    "import NotesSchema.VCurrent.Shared\nfn a() -> Int = NotesSchema.VCurrent.Shared.answer()\n"));
  check string "qualified and exposed references resolve to one declaration" (hash original) (hash (load path)))

let same_named_owners () = with_project (fun _root write ->
  List.iter (fun child -> ignore (write ("schema/notes/v-current/" ^ String.lowercase_ascii child ^ ".tesl")
    ("module NotesSchema.VCurrent." ^ child ^ " exposing [Count]\n" ^ imports ^ "type Count = Int\n"))) ["A"; "B"];
  let source owner = prefix "NotesSchema.VCurrent" ^ imports ^
    "import NotesSchema.VCurrent.A\nimport NotesSchema.VCurrent.B\n" ^
    "record Holder { count: NotesSchema.VCurrent." ^ owner ^ ".Count }\n" in
  let path = write "schema/notes/v-current.tesl" (source "A") in let before = load path in
  ignore (write "schema/notes/v-current.tesl" (source "B"));
  check bool "same-shaped same-named newtypes retain declaring identity" true
    (same before Type "NotesSchema.VCurrent.Holder" <> same (load path) Type "NotesSchema.VCurrent.Holder"))

let execution_abi () = with_project (fun _root write ->
  let path = fixture write in
  let before = load ~abi:"compiler A" path and after = load ~abi:"compiler B" path in
  check bool "cross-compiler snapshots do not silently compare equal" true (hash before <> hash after);
  check bool "Same includes execution semantics, not merely recompiled source" true
    (same before Type "NotesSchema.VCurrent.Notes.Note" <> same after Type "NotesSchema.VCurrent.Notes.Note");
  expect_error "ABI identity is required" (Migration_inventory.load ~compiler_abi:" \n" ~root_file:path);
  let empty = write "schema/notes/v-current.tesl" (prefix "NotesSchema.VCurrent") in
  check bool "even an empty schema retains the ABI" true
    (hash (load ~abi:"A" empty) <> hash (load ~abi:"B" empty)))

let no_invalid_inventory () = with_project (fun _root write ->
  let path = fixture write in
  let refused label source =
    ignore (write "schema/notes/v-current/notes.tesl" source);
    match Migration_inventory.load ~compiler_abi:"A" ~root_file:path with
    | Error _ -> () | Ok _ -> fail ("inventory accepted " ^ label) in
  refused "unproven entity construction" (notes ^ "fn invalid() -> Note = Note { id: \"x\", amount: -1 }\n");
  refused "ill-typed helper" (notes ^ "fn invalid() -> Int = \"wrong\"\n");
  refused "an effect in a private helper" (notes ^ "handler get invalid() -> Int = 1\n");
  refused "connection declaration" (notes ^ "database Bad = Database { entities: [Note], backend: Memory }\n");
  refused "schema escape" (notes ^ "import Application\n");
  refused "wrong module header" (replace "NotesSchema.VCurrent.Notes" "NotesSchema.VCurrent.Other" notes);
  refused "a missing private dependency" (notes ^ "import NotesSchema.VCurrent.Missing exposing []\n");
  ignore (write "schema/notes/v-current/notes.tesl" notes);
  let inventory = load path in
  expect_error "missing semantic definition" (Migration_inventory.closure inventory [Type, "NotesSchema.VCurrent.Missing"]);
  expect_error "unbound schema revision" (Migration_inventory.closure inventory [Type, "NotesSchema.V7.Notes.Note"]))

let changed_import_interface () = with_project (fun _root write ->
  let child ty value = "module NotesSchema.VCurrent.Child exposing [answer]\n" ^ imports ^
    "fn answer() -> " ^ ty ^ " = " ^ value ^ "\n" in
  ignore (write "schema/notes/v-current/child.tesl" (child "Int" "42"));
  let path = write "schema/notes/v-current.tesl" (prefix "NotesSchema.VCurrent" ^ imports ^
    "import NotesSchema.VCurrent.Child exposing [answer]\nfn value() -> Int = answer()\n") in
  ignore (load path);
  ignore (write "schema/notes/v-current/child.tesl" (child "String" "\"changed\""));
  match Migration_inventory.load ~compiler_abi:"A" ~root_file:path with
  | Error _ -> ()
  | Ok _ -> fail "a cached old interface admitted a newly ill-typed schema")

let storage_ownership () = with_project (fun _root write ->
  let child name = prefix ("NotesSchema.VCurrent." ^ name) ^ imports ^
    "entity Hidden table \"shared\" primaryKey id { id: String }\n" in
  List.iter (fun name -> ignore (write ("schema/notes/v-current/" ^ String.lowercase_ascii name ^ ".tesl") (child name))) ["A"; "B"];
  let path = write "schema/notes/v-current.tesl" (prefix "NotesSchema.VCurrent" ^
    "import NotesSchema.VCurrent.A exposing []\nimport NotesSchema.VCurrent.B exposing []\n") in
  expect_error "same physical table" (Migration_inventory.load ~compiler_abi:"A" ~root_file:path))

let builtin_scope () = with_project (fun _root write ->
  let path = write "schema/notes/v-current.tesl" (prefix "NotesSchema.VCurrent" ^ imports ^
    "import Tesl.String exposing [String.length]\nimport Tesl.Int exposing [IsNonNegative]\n" ^
    "record Counter { value: Int ::: IsNonNegative value }\n") in
  ignore (load path))

let () = run "migration-inventory" ["checked inventory", [
  test_case "complete private dependency inventory" `Quick complete_private_inventory;
  test_case "source and frozen-copy invariance" `Quick frozen_and_source_invariance;
  test_case "additional private fact producer" `Quick additional_fact_owner;
  test_case "private codec reverse dependency" `Quick private_codec;
  test_case "diamond, cycle and qualified resolution" `Quick import_graph;
  test_case "same-named nominal owners" `Quick same_named_owners;
  test_case "recorded compiler execution identity" `Quick execution_abi;
  test_case "refuse invalid or incomplete source" `Quick no_invalid_inventory;
  test_case "fresh imported interfaces on repeated loads" `Quick changed_import_interface;
  test_case "whole-schema physical ownership" `Quick storage_ownership;
  test_case "builtin predicate resolves through explicit exposure" `Quick builtin_scope;
]]
