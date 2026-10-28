open Alcotest
open Migration_inventory

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-field-impact-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in
      mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source);
      path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok result -> result | Error (error : Migration_ir.error) -> fail error.message
let load ?(abi="test-compiler-1") path = get (Migration_inventory.load ~compiler_abi:abi ~root_file:path)
let replace before after = Str.global_replace (Str.regexp_string before) after
let prefix = "module NotesSchema.VCurrent exposing []\n"
let imports = {|import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.length]
import Tesl.Json exposing [stringCodec]
|}
let details = {|fact ValidText (text: String)
check validText(text: String) -> text: String ::: ValidText text =
  if String.length text > 0 then
    ok text ::: ValidText text
  else
    fail 422 "empty text"
record Details { text: String ::: ValidText text }
codec Details {
  toJson { text -> "body" with_codec stringCodec }
  fromJson [
    { text <- "body" with_codec stringCodec via validText }
    { text <- "title" with_codec stringCodec via validText }
  ]
}
type Change
  = Unchanged
  | Changed details: Details
type Wrapped = Details
|}
let source = prefix ^ imports ^ details ^ {|entity Note table "notes" primaryKey id {
  id: String
  details: Details @db(jsonb)
  backup: Maybe Details
  change: Change
  wrapped: Wrapped
  unrelated: Int
}
entity Archive table "archives" primaryKey id { id: String, value: Change }
record Unstored { text: String }
codec Unstored {
  toJson { text -> "response" with_codec stringCodec }
  fromJson [ { text <- "response" with_codec stringCodec } ]
}
|}
let location field = field.entity ^ "." ^ field.name
let describe = function
  | Added_field field -> "+ " ^ location field
  | Removed_field field -> "- " ^ location field
  | Changed_field change -> (if change.definition_changed then "field " else "dependency ") ^ location change.current
let changes before after = get (field_changes ~before ~after) |> List.map describe |> List.sort String.compare
let dependent names = List.map (fun name -> "dependency NotesSchema.VCurrent." ^ name) names |> List.sort String.compare
let all_details = ["Archive.value"; "Note.backup"; "Note.change"; "Note.details"; "Note.wrapped"]

let nested_mutations () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl" source in
  let before = load path in
  check int "only actual entity fields are storage locations" 8 (List.length (stored_fields before));
  List.iter (fun (label, changed) ->
    ignore (write "schema/notes/v-current.tesl" changed);
    check (list string) label (dependent all_details) (changes before (load path))) [
    "encoder key reaches every occurrence", replace "-> \"body\"" "-> \"wire\"" source;
    "legacy decoder key reaches every occurrence", replace "\"title\"" "\"legacy\"" source;
    "fallback removal reaches every occurrence",
      replace "    { text <- \"title\" with_codec stringCodec via validText }\n" "" source;
    "fallback order is behavior",
      replace "<- \"temporary\"" "<- \"title\"" (replace "<- \"title\"" "<- \"body\""
        (replace "<- \"body\"" "<- \"temporary\"" source));
    "private check body reaches the stored record", replace "> 0" "> 1" source;
    "nested record shape reaches every occurrence",
      replace "text" "content" source;
  ])

let occurrence_precision () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl" source in let before = load path in
  ignore (write "schema/notes/v-current.tesl" (replace "= Unchanged" "= Waiting" source));
  check (list string) "ADT mutation follows only fields containing that ADT"
    (dependent ["Archive.value"; "Note.change"]) (changes before (load path));
  ignore (write "schema/notes/v-current.tesl" (replace "\"response\"" "\"reply\"" source));
  check (list string) "a codec with no stored occurrence creates no migration location" [] (changes before (load path));
  ignore (write "schema/notes/v-current.tesl" (source ^ "fn unused() -> Int = 99\n"));
  check (list string) "unreachable pure helper does not touch fields" [] (changes before (load path)))

let field_contracts () = with_project (fun _ write ->
  let initial = prefix ^ imports ^ {|fact Below (value: Int, ceiling: Int)
entity Reading table "readings" primaryKey id {
  id: String
  value: Int ::: Below value ceiling
  ceiling: Int
  alternate: Int
}
|} in
  let path = write "schema/notes/v-current.tesl" initial in let before = load path in
  List.iter (fun (label, changed) ->
    ignore (write "schema/notes/v-current.tesl" changed);
    check (list string) label ["field NotesSchema.VCurrent.Reading.value"] (changes before (load path))) [
    "proof changes its sibling subject", replace "Below value ceiling" "Below value alternate" initial;
    "proof removal is visible", replace " ::: Below value ceiling" "" initial;
    "storage override changes field contract", replace "value ceiling\n" "value ceiling @db(bigint)\n" initial;
  ];
  ignore (write "schema/notes/v-current.tesl" (replace "  id: String\n" "  newField: Maybe String\n  id: String\n" initial));
  check (list string) "adding an earlier field does not shift existing proof identities"
    ["+ NotesSchema.VCurrent.Reading.newField"] (changes before (load path));
  ignore (write "schema/notes/v-current.tesl" (replace "  ceiling: Int\n  alternate: Int\n"
    "  alternate: Int\n  ceiling: Int\n" initial));
  check (list string) "declaration order does not rename proof subjects" [] (changes before (load path)))

let additions_and_removals () = with_project (fun _ write ->
  let initial = prefix ^ imports ^ "entity Note table \"notes\" primaryKey id { id: String, note: Maybe String }\n" in
  let path = write "schema/notes/v-current.tesl" initial in let before = load path in
  ignore (write "schema/notes/v-current.tesl" (replace "note: Maybe String" "note: String" initial));
  check (list string) "narrowing Maybe requires field work"
    ["field NotesSchema.VCurrent.Note.note"] (changes before (load path));
  ignore (write "schema/notes/v-current.tesl" (replace "note: Maybe String" "renamed: Maybe String" initial));
  check (list string) "a rename is a decision, not silently inferred"
    ["+ NotesSchema.VCurrent.Note.renamed"; "- NotesSchema.VCurrent.Note.note"] (changes before (load path));
  ignore (write "schema/notes/v-current.tesl" (initial ^ "entity Extra table \"extra\" primaryKey id { id: String }\n"));
  let after = load path in
  check (list string) "new entity includes every field" ["+ NotesSchema.VCurrent.Extra.id"] (changes before after);
  check (list string) "removed entity includes every field" ["- NotesSchema.VCurrent.Extra.id"] (changes after before))

let frozen_identity () = with_project (fun root write ->
  let path = write "schema/notes/v-current.tesl" source in let before = load path in
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:8 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  let frozen = load (Filename.concat root "schema/notes/v8.tesl") in
  check (list string) "a frozen copy has identical field contracts" [] (changes frozen before);
  ignore (write "schema/notes/v-current.tesl" ("# new comments\n" ^ replace "(text: String) -> text:" "(input: String) -> input:"
    (replace "String.length text" "String.length input"
      (replace "ok text ::: ValidText text" "ok input ::: ValidText input"
        (replace "-> text: String ::: ValidText text" "-> text: String ::: ValidText input" source)))));
  check (list string) "source presentation and check parameter names do not change fields" [] (changes frozen (load path)))

let nominal_owners () = with_project (fun _ write ->
  let child name = "module NotesSchema.VCurrent." ^ name ^ " exposing [Details]\n" ^ imports ^
    replace "ValidText" (name ^ "ValidText") details in
  ignore (write "schema/notes/v-current/a.tesl" (child "A"));
  ignore (write "schema/notes/v-current/b.tesl" (child "B"));
  let current = prefix ^ imports ^ {|import NotesSchema.VCurrent.A
import NotesSchema.VCurrent.B
entity Note table "notes" primaryKey id {
  id: String
  left: NotesSchema.VCurrent.A.Details
  right: NotesSchema.VCurrent.B.Details
}
|} in
  let path = write "schema/notes/v-current.tesl" current in let before = load path in
  ignore (write "schema/notes/v-current/a.tesl" (replace "\"title\"" "\"old\"" (child "A")));
  check (list string) "same-named private codecs stay with their nominal owner"
    (dependent ["Note.left"]) (changes before (load path));
  ignore (write "schema/notes/v-current/a.tesl" (child "A"));
  ignore (write "schema/notes/v-current.tesl" (replace "left: NotesSchema.VCurrent.A.Details"
    "left: NotesSchema.VCurrent.B.Details" current));
  check (list string) "same-shaped same-named types are not aliases"
    ["field NotesSchema.VCurrent.Note.left"] (changes before (load path)))

let comparison_boundaries () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl" source in
  let before = load ~abi:"A" path and after = load ~abi:"B" path in
  let refused label before after = match field_changes ~before ~after with
    | Error _ -> () | Ok _ -> fail label in
  refused "a new compiler must not silently certify old stored values" before after;
  let another = write "schema/other/v-current.tesl" (replace "NotesSchema" "OtherSchema" source) in
  refused "different database families cannot share field identity" before (load ~abi:"A" another);
  let empty = write "schema/notes/v-current.tesl" prefix in
  refused "empty schemas also retain ABI evidence" (load ~abi:"A" empty) (load ~abi:"B" empty))

let private_transitive_occurrences () = with_project (fun root write ->
  ignore (write "schema/notes/v-current/shared.tesl"
    ("module NotesSchema.VCurrent.Shared exposing [Details]\n" ^ imports ^ details));
  let child = {|module NotesSchema.VCurrent.Notes exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe]
import NotesSchema.VCurrent.Shared exposing [Details]
entity Hidden table "hidden" primaryKey id { id: String, payload: Maybe Details }
|} in
  ignore (write "schema/notes/v-current/notes.tesl" child);
  let path = write "schema/notes/v-current.tesl"
    (prefix ^ "import NotesSchema.VCurrent.Notes exposing []\n") in
  let before = load path in
  let names = stored_fields before |> List.map location |> List.sort String.compare in
  check (list string) "private entities are not lost at export boundaries"
    ["NotesSchema.VCurrent.Notes.Hidden.id"; "NotesSchema.VCurrent.Notes.Hidden.payload"] names;
  List.iter (fun field -> check string "diagnostic points to the stored field declaration"
    (Filename.concat root "schema/notes/v-current/notes.tesl") field.loc.file)
    (stored_fields before);
  ignore (write "schema/notes/v-current/shared.tesl"
    ("module NotesSchema.VCurrent.Shared exposing [Details]\n" ^ imports ^ replace "> 0" "> 1" details));
  check (list string) "private transitive record codec/proof closure reaches its containing entity"
    (dependent ["Notes.Hidden.payload"]) (changes before (load path)))

let large_shared_type () = with_project (fun _ write ->
  let entities = List.init 300 (fun i -> Printf.sprintf
    "entity E%d table \"table_%d\" primaryKey id { id: String, payload: Maybe Details }\n" i i)
    |> String.concat "" in
  let initial = prefix ^ imports ^ details ^ entities in
  let path = write "schema/notes/v-current.tesl" initial in let before = load path in
  ignore (write "schema/notes/v-current.tesl" (replace "\"title\"" "\"legacy\"" initial));
  let expected = List.init 300 (fun i -> Printf.sprintf "E%d.payload" i) |> dependent in
  check (list string) "every private entity sharing the codec appears exactly once"
    expected (changes before (load path)))

let () = run "migration-field-impact" ["stored occurrences", [
  test_case "record and codec closure mutations" `Quick nested_mutations;
  test_case "precise affected occurrences" `Quick occurrence_precision;
  test_case "field types, proofs and storage annotations" `Quick field_contracts;
  test_case "additions, removals and explicit rename decisions" `Quick additions_and_removals;
  test_case "frozen identity and source invariance" `Quick frozen_identity;
  test_case "private same-named codec ownership" `Quick nominal_owners;
  test_case "ABI and family comparison boundaries" `Quick comparison_boundaries;
  test_case "private transitive stored occurrences and locations" `Quick private_transitive_occurrences;
  test_case "shared codec across 300 private entities" `Quick large_shared_type;
]]
