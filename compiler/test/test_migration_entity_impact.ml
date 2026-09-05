open Migration_inventory
open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-entity-impact-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok result -> result | Error (e : Migration_ir.error) -> fail e.message
let load ?(abi="test-compiler-1") path = get (load ~compiler_abi:abi ~root_file:path)
let replace before after = Str.global_replace (Str.regexp_string before) after
let prefix = "module NotesSchema.VCurrent exposing []\n"
let imports = {|import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec]
|}
let entity = {|entity Note table "notes" primaryKey id {
  id: String
  externalId: String
  title: String
  index [title] as "notes_title_idx"
}
|}
let source = prefix ^ imports ^ entity
let describe = function
  | Added_entity e -> "added " ^ e.entity_name
  | Removed_entity e -> "removed " ^ e.entity_name
  | Changed_entity e ->
    (if e.definition_changed then "definition " else "dependency ") ^ e.current.entity_name
let changes before after = get (entity_changes ~before ~after) |> List.map describe |> List.sort String.compare
let put write text = write "schema/notes/v-current.tesl" text |> load
let freeze root version =
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  load (Filename.concat root (Printf.sprintf "schema/notes/v%d.tesl" version))

let mapping_only_changes () = with_project (fun _ write ->
  let before = put write source in
  List.iter (fun (label, fresh) ->
    let after = put write fresh in
    check int (label ^ " leaves individual field contracts unchanged") 0
      (List.length (get (field_changes ~before ~after)));
    check (list string) (label ^ " must prevent omission from a sparse migration")
      ["definition NotesSchema.VCurrent.Note"] (changes before after)) [
    "table rename", replace "table \"notes\"" "table \"notes_archive\"" source;
    "primary key change", replace "primaryKey id" "primaryKey externalId" source;
    "index uniqueness", replace "  index [title]" "  unique index [title]" source;
    "index field set", replace "index [title]" "index [externalId, title]" source;
    "physical index name", replace "notes_title_idx" "notes_title_v2_idx" source;
    "removed index", replace "  index [title] as \"notes_title_idx\"\n" "" source;
    "added index", replace "  index [title]" "  index [externalId]\n  index [title]" source;
  ])

let field_changes_reach_entity () = with_project (fun _ write ->
  let before = put write source in
  List.iter (fun (label, fresh) ->
    let after = put write fresh in
    check bool (label ^ " is visible at field level") true
      (get (field_changes ~before ~after) <> []);
    check (list string) label ["definition NotesSchema.VCurrent.Note"] (changes before after)) [
    "nullable addition", replace "  title: String" "  extra: Maybe String\n  title: String" source;
    "removal", replace "  externalId: String\n" "" source;
    "retype", replace "  externalId: String" "  externalId: Int" source;
    "storage override", replace "  externalId: String" "  externalId: String @db(text)" source;
  ])

let additions_and_removals () = with_project (fun _ write ->
  let before = put write source in
  let extra = {|entity Tag table "tags" primaryKey id { id: String, label: String }
|} in
  let with_extra = put write (source ^ extra) in
  check (list string) "unchanged Note is folded out" ["added NotesSchema.VCurrent.Tag"] (changes before with_extra);
  let only_extra = put write (prefix ^ imports ^ extra) in
  check (list string) "explicit old/new names, never inferred table pairing"
    ["added NotesSchema.VCurrent.Tag"; "removed NotesSchema.VCurrent.Note"] (changes before only_extra);
  let empty = put write (prefix ^ imports) in
  check (list string) "all removals survive an empty target schema"
    ["removed NotesSchema.VCurrent.Note"; "removed NotesSchema.VCurrent.Tag"] (changes with_extra empty);
  check (list string) "all additions survive an empty source schema"
    ["added NotesSchema.VCurrent.Note"; "added NotesSchema.VCurrent.Tag"] (changes empty with_extra))

let stored_metadata () = with_project (fun root write ->
  let inventory = put write source in
  match stored_entities inventory with
  | [e] ->
    check string "fully qualified owner" "NotesSchema.VCurrent.Note" e.entity_name;
    check string "physical table" "notes" e.table_name;
    check string "primary key" "id" e.primary_key;
    check string "diagnostic location" (Filename.concat root "schema/notes/v-current.tesl") e.entity_loc.file
  | _ -> fail "missing or duplicated entity metadata")

let dependency_sources = {|type State
  = Pending
  | Done
codec State { adtJson }
record Payload { text: String, state: State }
codec Payload {
  toJson {
    text -> "body" with_codec stringCodec
    state -> "state" with_codec State
  }
  fromJson [
    { text <- "body" with_codec stringCodec, state <- "state" with_codec State }
    { text <- "title" with_codec stringCodec, state <- "state" with_codec State }
  ]
}
fact Positive (n: Int)
fn threshold() -> Int = 0
establish accept(n: Int) -> Maybe (v: Int ::: Positive v) =
  if n > threshold() then
    Something (n ::: Positive n)
  else
    Nothing
|}
let dependent_entities = {|entity Message table "messages" primaryKey id { id: String, payload: Payload }
entity Backup table "backups" primaryKey id { id: String, payload: Maybe Payload @db(jsonb) }
entity Counter table "counters" primaryKey id { id: String, amount: Int ::: Positive amount }
|}
let transitive_dependencies () = with_project (fun _ write ->
  let initial = source ^ dependency_sources ^ dependent_entities in
  let before = put write initial in
  List.iter (fun (label, fresh, expected) ->
    let after = put write fresh in
    check (list string) label (List.map (fun n -> "dependency NotesSchema.VCurrent." ^ n) expected)
      (changes before after)) [
    "nested codec encoding", replace "text -> \"body\"" "text -> \"content\"" initial, ["Backup"; "Message"];
    "nested legacy decoder", replace "text <- \"title\"" "text <- \"legacy\"" initial, ["Backup"; "Message"];
    "nested ADT representation", replace "  = Pending" "  = Queued" initial, ["Backup"; "Message"];
    "private proof producer dependency", replace "threshold() -> Int = 0" "threshold() -> Int = 1" initial, ["Counter"];
  ])

let unrelated_declarations () = with_project (fun _ write ->
  let initial = source ^ dependency_sources ^ "fn unused() -> Int = 42\n" in
  let before = put write initial in
  let after = put write (replace "text <- \"title\"" "text <- \"legacy\"" initial
    |> replace "unused() -> Int = 42" "unused() -> Int = 43") in
  check bool "complete snapshots record all declarations" true (snapshot before <> snapshot after);
  check (list string) "unreferenced codecs and helpers do not invent entity changes" [] (changes before after))

let private_membership_and_identity () = with_project (fun root write ->
  let child name table = "module NotesSchema.VCurrent." ^ name ^ " exposing []\n" ^ imports ^
    replace "\"notes\"" ("\"" ^ table ^ "\"") (replace "notes_title_idx" (table ^ "_title_idx") entity) in
  ignore (write "schema/notes/v-current/a.tesl" (child "A" "notes_a"));
  ignore (write "schema/notes/v-current/b.tesl" (child "B" "notes_b"));
  let root_source = prefix ^ "import NotesSchema.VCurrent.A exposing []\nimport NotesSchema.VCurrent.B exposing []\n" in
  let before = put write root_source in
  check (list string) "same short names in distinct private modules remain distinct"
    ["NotesSchema.VCurrent.A.Note"; "NotesSchema.VCurrent.B.Note"]
    (stored_entities before |> List.map (fun e -> e.entity_name) |> List.sort String.compare);
  ignore (write "schema/notes/v-current/b.tesl" (replace "primaryKey id" "primaryKey externalId" (child "B" "notes_b")));
  let after = put write root_source in
  check (list string) "only the changed private owner appears" ["definition NotesSchema.VCurrent.B.Note"] (changes before after);
  let b = List.find (fun e -> e.entity_name = "NotesSchema.VCurrent.B.Note") (stored_entities after) in
  check string "private entity location" (Filename.concat root "schema/notes/v-current/b.tesl") b.entity_loc.file;
  ignore (write "schema/notes/v-current/c.tesl" (replace ".B exposing" ".C exposing" (child "B" "notes_b")));
  let moved = put write (replace ".B exposing" ".C exposing" root_source) in
  check (list string) "a module move with identical physical storage requires a decision"
    ["added NotesSchema.VCurrent.C.Note"; "removed NotesSchema.VCurrent.B.Note"] (changes before moved))

let frozen_identity () = with_project (fun root write ->
  let live = put write (source ^ dependency_sources ^ dependent_entities) in
  let before = freeze root 3 in
  check (list string) "freezing all declarations preserves every entity" [] (changes before live);
  let after = put write ("# Unicode layout comment λ\n" ^ source ^ dependency_sources ^ dependent_entities
    |> replace "\n" "\r\n") in
  check (list string) "source-only differences preserve every entity" [] (changes before after);
  let changed = put write (replace "text <- \"title\"" "text <- \"legacy\""
    (source ^ dependency_sources ^ dependent_entities)) in
  check (list string) "private JSONB meaning changes still surface across a freeze"
    ["dependency NotesSchema.VCurrent.Backup"; "dependency NotesSchema.VCurrent.Message"] (changes before changed))

let comparison_boundaries () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl" source in
  let before = load path in
  let foreign_abi = load ~abi:"different-compiler" path in
  check bool "entity comparison rejects different ABIs" true (Result.is_error (entity_changes ~before ~after:foreign_abi));
  let foreign = write "schema/other/v-current.tesl" (replace "NotesSchema" "OtherSchema" source) |> load in
  check bool "entity comparison rejects different families" true (Result.is_error (entity_changes ~before ~after:foreign));
  let empty = write "schema/notes/v-current.tesl" prefix in
  check bool "an empty table set cannot hide different compiler semantics" true
    (Result.is_error (entity_changes ~before:(load ~abi:"A" empty) ~after:(load ~abi:"B" empty))))

let large_sparse_schema () = with_project (fun _ write ->
  let entities = List.init 300 (fun i -> Printf.sprintf
    "entity E%d table \"table_%d\" primaryKey id { id: String, payload: Maybe Payload }\n" i i)
    |> String.concat "" in
  let initial = prefix ^ imports ^ dependency_sources ^ entities in
  let before = put write initial in
  let after = put write (replace "text <- \"title\"" "text <- \"legacy\"" initial) in
  let expected = List.init 300 (fun i -> Printf.sprintf "dependency NotesSchema.VCurrent.E%d" i) |> List.sort String.compare in
  check (list string) "each affected private table appears exactly once" expected (changes before after);
  let one = put write (replace "table \"table_125\"" "table \"table_125_new\"" initial) in
  check (list string) "299 unaffected tables stay folded out" ["definition NotesSchema.VCurrent.E125"] (changes before one))

let () = run "migration-entity-impact" ["sparse schema comparison", [
  test_case "table, primary key and index changes with identical fields" `Quick mapping_only_changes;
  test_case "field changes cannot disappear at entity level" `Quick field_changes_reach_entity;
  test_case "new, removed and empty table sets" `Quick additions_and_removals;
  test_case "checked physical metadata and source location" `Quick stored_metadata;
  test_case "precise transitive record, ADT, codec and proof impact" `Quick transitive_dependencies;
  test_case "unreferenced semantic changes stay out of the sparse record" `Quick unrelated_declarations;
  test_case "private membership, identical short names and module moves" `Quick private_membership_and_identity;
  test_case "frozen identity and source invariance" `Quick frozen_identity;
  test_case "ABI and family boundaries, including empty schemas" `Quick comparison_boundaries;
  test_case "one and 300 affected entities in a large sparse schema" `Quick large_sparse_schema;
]]
