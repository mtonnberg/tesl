open Alcotest
open Migration_inventory
module S = Migration_sparse
module A = Migration_additive

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-migration-additive-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok value -> value | Error (error : Migration_ir.error) -> fail error.message
let load path = get (load ~compiler_abi:"test-compiler-1" ~root_file:path)
let replace before after = Str.global_replace (Str.regexp_string before) after
let checked = function Ok value -> value | Error errors -> fail
  (String.concat "\n" (List.map (fun (e : S.error) -> e.code ^ ": " ^ e.message) errors))
let refused code = function
  | Ok _ -> fail ("accepted invalid " ^ code ^ " case")
  | Error errors -> check bool code true (List.exists (fun (e : S.error) -> e.code = code) errors); errors
let loc = Location.make_loc "migration.tesl" 14 8 14 30
let entry kind entity : S.entry = {entity;kind;loc}
let default ?(entity="Note") field value : A.default = {entity;field;value;loc}
let identities before after = get (same_candidates ~before ~after) |> List.map (fun evidence ->
  let old, fresh = same_declarations evidence in
  ({S.previous=(old.namespace,old.qualified_name);current=(fresh.namespace,fresh.qualified_name);loc} : S.identity))
let coverage ?(entries=[entry S.Additive "Note"]) before after =
  checked (S.check ~before ~after ~identities:(identities before after) ~entries ~loc)
let prefix = {|module NotesSchema.VCurrent exposing []
import Tesl.Prelude exposing [Int, Bool(..), String]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
|}
let table ?(extra="") () = {|entity Note table "notes" primaryKey id {
  id: String
  value: Int
  label: String
|} ^ extra ^ "}\nentity Session table \"sessions\" primaryKey id { id: String }\n"
let source = prefix ^ table ()
let fixture root write original edited =
  let path = write "schema/notes/v-current.tesl" original in
  ignore (load path);
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  let before = load (Filename.concat root "schema/notes/v1.tesl") in
  ignore (write "schema/notes/v-current.tesl" edited);
  before, load path, path
let plans coverage defaults = A.entities (checked (A.check coverage ~defaults))
let only = function [value] -> value | _ -> fail "expected one affected entity"
let value_name = function
  | A.Existing {current;_} -> "copy:" ^ current.name
  | A.Empty_optional field -> "nothing:" ^ field.name
  | A.Constant (field,_) -> "constant:" ^ field.name
let value_names entity = List.map value_name entity.A.values

let nullable_columns () = with_project (fun root write ->
  let before, after, _ = fixture root write source
    (prefix ^ table ~extra:"  secondary: Maybe String\n  rank: Maybe Int\n" ()) in
  let covered = coverage before after in
  let plan = only (plans covered []) in
  check (list string) "one value source for every target field"
    ["copy:id";"copy:label";"nothing:rank";"nothing:secondary";"copy:value"] (value_names plan);
  check int "unaffected table folded" 1 (S.unchanged_count covered);
  check bool "no index work inferred from columns" false plan.indexes_changed;
  List.iter (function
    | A.Existing {previous;current} ->
      check bool "copy preserves exactly equal contract" true (previous.contract = current.contract);
      check string "old projection uses frozen owner" "NotesSchema.V1.Note" previous.entity
    | _ -> ()) plan.values)

let scalar_defaults () = with_project (fun root write ->
  let edited = prefix ^ table ~extra:"  count: Int\n  ratio: Float\n  active: Bool\n  caption: String\n" () in
  let before, after, _ = fixture root write source edited in
  let covered = coverage before after in
  let large = "-1606938044258990275541962092341162602522202993782792835301376" in
  let defaults = [default "count" (A.Integer large);default "ratio" (A.Floating (-0.));
    default "active" (A.Boolean true);default "caption" (A.Text "å🙂 ' \\") ] in
  let plan = only (plans covered defaults) in
  let constants = List.filter_map (function A.Constant (field,value) -> Some (field.name,value) | _ -> None) plan.values in
  check bool "arbitrary precision integer retained" true
    (List.assoc "count" constants = Result.get_ok (Migration_canonical.integer large));
  check bool "negative zero bits retained" true
    (List.assoc "ratio" constants = Result.get_ok (Migration_canonical.float (-0.)));
  check bool "boolean canonical representation shared" true
    (List.assoc "active" constants = Migration_canonical.bool true);
  check bool "unicode, quotes and backslash preserved" true
    (List.assoc "caption" constants = Migration_canonical.string "å🙂 ' \\");
  check (list string) "rule order does not change projection"
    (value_names plan) (value_names (only (plans covered (List.rev defaults)))))

let exact_literal_types () = with_project (fun root write ->
  let before, after, _ = fixture root write source
    (prefix ^ table ~extra:"  count: Int\n  ratio: Float\n  active: Bool\n  caption: String\n" ()) in
  let covered = coverage before after in
  let correct = [default "count" (A.Integer "1");default "ratio" (A.Floating 1.);
    default "active" (A.Boolean false);default "caption" (A.Text "text")] in
  List.iter (fun (candidate : A.default) ->
    List.iter (fun (replacement : A.default) ->
      if candidate.field <> replacement.field then begin
        let defaults = List.map (fun (d : A.default) -> if d.field = candidate.field
          then {d with value=replacement.value} else d) correct in
        let errors = refused "MIG022" (A.check covered ~defaults) in
        check bool "literal mismatch points at rule" true (List.exists (fun (e : S.error) -> e.loc = loc) errors)
      end) correct) correct)

let invalid_literals () = with_project (fun root write ->
  let before, after, _ = fixture root write source
    (prefix ^ table ~extra:"  count: Int\n  ratio: Float\n" ()) in
  let covered = coverage before after in
  List.iter (fun value -> ignore (refused "MIG022" (A.check covered
    ~defaults:[default "count" (A.Integer value);default "ratio" (A.Floating 1.)])))
    ["";"-";"1+2";"0; DROP TABLE notes";"1.5";" 1";"+1"];
  List.iter (fun value -> ignore (refused "MIG022" (A.check covered
    ~defaults:[default "count" (A.Integer "1");default "ratio" (A.Floating value)])))
    [infinity;neg_infinity;nan];
  let constant value = only (plans covered [default "count" (A.Integer value);default "ratio" (A.Floating 1.)])
    |> fun p -> List.find_map (function A.Constant (field,node) when field.name = "count" -> Some node | _ -> None) p.values in
  check bool "integer textual normal forms share one value" true (constant "00001" = constant "1");
  check bool "negative zero integer normal form" true (constant "-000" = constant "0"))

let missing_or_misplaced_default () = with_project (fun root write ->
  let before, after, _ = fixture root write source (prefix ^ table ~extra:"  count: Int\n  optional: Maybe Int\n" ()) in
  let covered = coverage before after in
  ignore (refused "MIG016" (A.check covered ~defaults:[]));
  List.iter (fun extra -> ignore (refused "MIG022" (A.check covered
    ~defaults:[default "count" (A.Integer "1");extra]))) [
    default "value" (A.Integer "1");default "optional" (A.Integer "1");default "absent" (A.Integer "1");
    default ~entity:"Session" "count" (A.Integer "1");default ~entity:"Missing" "count" (A.Integer "1");
    default ~entity:"NotesSchema.V1.Note" "count" (A.Integer "1")];
  ignore (refused "MIG023" (A.check covered ~defaults:[default "count" (A.Integer "1");default "count" (A.Integer "2")])) )

let proof_and_nominal_defaults () = with_project (fun root write ->
  let definitions = {|fact Positive (n: Int)
fact SafeOptional (n: Maybe Int)
type Identifier = String
|} in
  let before, after, _ = fixture root write source
    (prefix ^ definitions ^ table ~extra:"  count: Int ::: Positive count\n  opt: Maybe Int ::: SafeOptional opt\n  key: Identifier\n" ()) in
  let covered = coverage before after in
  ignore (refused "MIG016" (A.check covered ~defaults:[]));
  let errors = refused "MIG022" (A.check covered ~defaults:[default "count" (A.Integer "1");
    default "opt" (A.Integer "1");default "key" (A.Text "x")]) in
  check int "neither proof is invented and no newtype is erased" 3 (List.length errors))

let existing_contract_changes () = with_project (fun root write ->
  let before, _, path = fixture root write source (prefix ^ table ~extra:"  extra: Maybe String\n" ()) in
  List.iter (fun edited ->
    ignore (write "schema/notes/v-current.tesl" edited);
    let after = load path in
    let covered = coverage before after in
    ignore (refused "MIG016" (A.check covered ~defaults:[]))) [
    replace "value: Int" "value: String" source;
    replace "value: Int" "value: Maybe Int" source;
    replace "label: String" "label: String @db(text)" source;
    replace "  label: String\n" "" source;
    replace "table \"notes\"" "table \"renamed\"" source;
    replace "primaryKey id {\n  id" "primaryKey label {\n  id" source])

let proof_removal () = with_project (fun root write ->
  let original = prefix ^ "fact Positive (n: Int)\n" ^ replace "value: Int" "value: Int ::: Positive value" (table ()) in
  let edited = prefix ^ "fact Positive (n: Int)\n" ^ table () in
  let before, after, _ = fixture root write original edited in
  (* The missing predicate is no longer a common dependency. Sparse coverage
     alone therefore cannot certify this as an additive row adapter. *)
  let covered = coverage before after in
  ignore (refused "MIG016" (A.check covered ~defaults:[])))

let index_obligations () = with_project (fun root write ->
  let before, _, path = fixture root write source (prefix ^ table ~extra:"  index [value]\n" ()) in
  List.iter (fun index ->
    ignore (write "schema/notes/v-current.tesl" (prefix ^ table ~extra:("  " ^ index ^ "\n") ()));
    let after = load path in let plan = only (plans (coverage before after) []) in
    check bool "index work survives unchanged row adapters" true plan.indexes_changed;
    check (list string) "index-only change has only old value projections"
      ["copy:id";"copy:label";"copy:value"] (value_names plan))
    ["index [value]";"unique index [value]";"index [label, value] as \"lookup_note\""])

let optional_semantic_types () = with_project (fun root write ->
  let definitions = {|import Tesl.Json exposing [stringCodec]
fact ValidText (text: String)
check validText(text: String) -> text: String ::: ValidText text =
  ok text ::: ValidText text
record Payload { text: String ::: ValidText text }
codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec via validText } ]
}
|} in
  let before, after, _ = fixture root write source
    (prefix ^ definitions ^ table ~extra:"  payload: Maybe Payload\n" ()) in
  let plan = only (plans (coverage before after) []) in
  check bool "Nothing does not fabricate the nested record's proof" true
    (List.mem "nothing:payload" (value_names plan)))

let ownership_and_kind () = with_project (fun root write ->
  let before, after, _ = fixture root write source
    (prefix ^ table ~extra:"  count: Int\n" () ^ "entity Tag table \"tags\" primaryKey id { id: String }\n") in
  let covered = coverage ~entries:[entry S.Transform "Note";entry S.New "Tag"] before after in
  check int "non-additive entries are left for their own elaborator" 0 (List.length (plans covered []));
  ignore (refused "MIG022" (A.check covered ~defaults:[default "count" (A.Integer "1")])) )

let nominal_optional () = with_project (fun root write ->
  let definition = "type Optional a\n  = Absent\n  | Present value: a\n" in
  let before, after, _ = fixture root write source
    (prefix ^ definition ^ table ~extra:"  optional: Optional Int\n" ()) in
  let covered = coverage before after in
  ignore (refused "MIG016" (A.check covered ~defaults:[]));
  ignore (refused "MIG022" (A.check covered ~defaults:[default "optional" (A.Integer "1")])))

let current_application_construction () = with_project (fun root write ->
  let expose = replace "exposing []" "exposing [Note]" in
  let source = expose source in
  let edited = expose (prefix ^ table ~extra:"  archivedAt: Maybe String\n" ()) in
  let before, after, _ = fixture root write source edited in
  ignore (only (plans (coverage before after) []));
  let application = {|module App exposing [makeNote]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.VCurrent exposing [Note]
fn makeNote(id: String) -> Note = Note { id: id, value: 5, label: "label" }
|} in
  let app_path = write "app.tesl" application in
  let diagnostics text =
    (* Simulate distinct compiler requests over different dependency snapshots. *)
    Query_cache.clear ();
    Compile.check_source app_path text |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  ignore (write "schema/notes/v-current.tesl" source);
  let original_errors = diagnostics application in
  if original_errors <> [] then fail (Compile.diagnostics_to_json original_errors);
  ignore (write "schema/notes/v-current.tesl" edited);
  let errors = diagnostics application in
  check int "an additive migration does not fill an incomplete current literal" 1 (List.length errors);
  let error = List.hd errors in
  check string "ordinary construction diagnostic" "T001" error.code;
  check string "the precise new field is required" "record `Note` is missing required field `archivedAt`" error.message;
  let repaired = replace "label: \"label\" }" "label: \"label\", archivedAt: Nothing }" application ^ {|
test "explicit current optional field runs" {
  let note = makeNote "first"
  expect note.id == "first"
  expect note.archivedAt == Nothing
}
|} in
  ignore (write "app.tesl" repaired);
  check int "an explicit Nothing restores a complete current row" 0 (List.length (diagnostics repaired));
  let artifacts = match Compile.compile_go_file app_path with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure errors -> fail (Compile.diagnostics_to_json errors) in
  List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
  let log = Filename.concat root "go-test.log" in
  let command = Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 -v ./... > %s 2>&1"
    (Filename.quote (Filename.concat root "out")) (Filename.quote log) in
  let status = Sys.command command in
  let output = In_channel.with_open_bin log In_channel.input_all in
  if status <> 0 then fail output;
  check bool "the generated constructor test actually ran" true
    (Compile.string_contains output "--- PASS:"))

let large_schema () = with_project (fun root write ->
  let tables = List.init 300 (fun i -> Printf.sprintf
    "entity E%d table \"table_%d\" primaryKey id { id: String, value: Int }\n" i i) |> String.concat "" in
  let original = prefix ^ tables in
  let edited = replace "entity E42 table \"table_42\" primaryKey id { id: String, value: Int }"
    "entity E42 table \"table_42\" primaryKey id { id: String, value: Int, added: Maybe String }" original in
  let before, after, _ = fixture root write original edited in
  let covered = coverage ~entries:[entry S.Additive "E42"] before after in
  let plan = only (plans covered []) in
  check string "only edited entity receives adapters" "E42" plan.identity;
  check (list string) "precise new value source" ["nothing:added";"copy:id";"copy:value"] (value_names plan);
  check int "299 tables remain folded" 299 (S.unchanged_count covered))

let () = Alcotest.run "migration-additive" ["logical row adapters", [
  test_case "new nullable fields have exact value sources" `Quick nullable_columns;
  test_case "primitive defaults retain exact canonical values" `Quick scalar_defaults;
  test_case "all cross-type literal mismatches refuse" `Quick exact_literal_types;
  test_case "integer grammar and finite float boundary" `Quick invalid_literals;
  test_case "missing misplaced and duplicate defaults" `Quick missing_or_misplaced_default;
  test_case "defaults cannot invent proofs or erase nominal types" `Quick proof_and_nominal_defaults;
  test_case "existing fields storage table and PK must stay equal" `Quick existing_contract_changes;
  test_case "proof removal cannot masquerade as additive" `Quick proof_removal;
  test_case "index obligations remain visible" `Quick index_obligations;
  test_case "new optional JSONB needs no fabricated nested evidence" `Quick optional_semantic_types;
  test_case "rule ownership and other migration kinds" `Quick ownership_and_kind;
  test_case "structural Maybe lookalikes have no implicit default" `Quick nominal_optional;
  test_case "migration adapters do not fill current application literals" `Quick current_application_construction;
  test_case "one changed entity among 300" `Quick large_schema;
]]
