open Alcotest
module D = Migration_declaration
module A = Migration_additive
module S = Migration_sparse

let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let replace before after = Str.global_replace (Str.regexp_string before) after
let prefix = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
|}
let schema extra = prefix ^ {|entity Note table "notes" primaryKey id {
  id: String
  title: String
|} ^ extra ^ "}\nentity Session table \"sessions\" primaryKey id { id: String }\n"
let preamble = {|module NotesSchema.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import Tesl.Prelude exposing [Int, String, Bool(..)]
import NotesSchema.V1
import NotesSchema.VCurrent
|}
let declaration ?(same="[]") ?(fixtures="") entities = preamble ^
  "migration = Migration {\n  from: NotesSchema.V1\n  to: NotesSchema.VCurrent\n  same: " ^ same ^
  "\n" ^ fixtures ^ "  entities: { " ^ entities ^ " }\n}\n"
let with_project ?(old=schema "") ?(fresh=schema "  archivedAt: Maybe String\n") f =
  let root = Filename.temp_file "tesl-migration-declaration-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" "");
    ignore (write "schema/notes/v1.tesl" (replace "NotesSchema.VCurrent" "NotesSchema.V1" old));
    ignore (write "schema/notes/v-current.tesl" fresh);
    let path = write "migrations/notes/v2.tesl" (declaration "Note: Additive []") in
    f root write path)
let diagnostics path source = Compile.check_source path source
let errors diagnostics = List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics
let describe diagnostics = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.code ^ ": " ^ d.message) diagnostics)
let accepts path source =
  let ds = errors (diagnostics path source) in if ds <> [] then fail (describe ds)
let refuses code path source =
  let ds = errors (diagnostics path source) in
  if not (List.exists (fun (d : Compile.diagnostic) -> d.code = code) ds) then
    fail ("missing " ^ code ^ " in:\n" ^ describe ds);
  ds
let parsed path source = match Compile.parse_module path source with
  | Parser.Ok m -> m | Parser.Err e -> fail e.msg
let checked path source =
  accepts path source;
  match D.check ~compiler_abi:"test-compiler-1" ~source (parsed path source) with
  | Ok (Some result) -> result
  | Ok None -> fail "declaration was not checked"
  | Error errors -> fail (String.concat "\n" (List.map (fun (e : S.error) -> e.message) errors))
let only = function [value] -> value | _ -> fail "expected one result"

let nullable () = with_project (fun _ _ path ->
  let source = declaration "Note: Additive []" in
  let result = checked path source in
  check int "adjacent target version" 2 (D.version result);
  check int "unrelated table absent and folded" 1 (S.unchanged_count (D.coverage result));
  check (list string) "row projection" ["nothing:archivedAt";"copy:id";"copy:title"]
    (List.map (function A.Existing {current;_} -> "copy:" ^ current.name
       | A.Empty_optional field -> "nothing:" ^ field.name
       | A.Constant (field,_) -> "constant:" ^ field.name)
      (only (A.entities (D.additive result))).values);
  accepts path (declaration ~fixtures:"  fixtures: []\n" "Note: Additive []"))

let defaults () = with_project ~fresh:(schema "  rank: Int\n  caption: String\n  active: Bool\n  ratio: Float\n") (fun _ _ path ->
  let source = declaration "Note: Additive [Default rank (-1606938044258990275541962092341162602522202993782792835301376), Default caption \"å🙂\", Default active True, Default ratio (-0.0)]" in
  let result = checked path source in
  let constants = (only (A.entities (D.additive result))).values |> List.filter_map (function
    | A.Constant (field,value) -> Some (field.name,value) | _ -> None) in
  check bool "large signed integer survives surface" true
    (List.assoc "rank" constants = Result.get_ok (Migration_canonical.integer "-1606938044258990275541962092341162602522202993782792835301376"));
  check bool "negative zero survives surface" true
    (List.assoc "ratio" constants = Result.get_ok (Migration_canonical.float (-0.)));
  ignore (refuses "MIG022" path (replace "Default rank (-1606938044258990275541962092341162602522202993782792835301376)" "Default rank True" source)))

let sparse () = with_project (fun _ _ path ->
  ignore (refuses "MIG002" path (declaration ""));
  ignore (refuses "MIG002" path (declaration "Note: Additive [], Session: Additive []"));
  ignore (refuses "MIG002" path (declaration "Absent: Additive []"));
  ignore (refuses "MIG002" path (declaration "Note: Additive [], NotesSchema.V1.Note: Additive []"));
  accepts path (declaration "NotesSchema.VCurrent.Note: Additive []");
  accepts path (declaration "NotesSchema.V1.Note: Additive []"))

let malformed_records () = with_project (fun _ _ path ->
  let source = declaration "Note: Additive []" in
  ignore (refuses "MIG020" path (preamble ^ "migration = 42\n"));
  ignore (refuses "MIG020" path (replace "exposing [migration]" "exposing []" preamble));
  List.iter (fun (before,after) -> ignore (refuses "MIG020" path (replace before after source))) [
    "  from: NotesSchema.V1\n", "";
    "  to: NotesSchema.VCurrent\n", "";
    "  same: []\n", "";
    "  entities: { Note: Additive [] }\n", "";
    "  same: []", "  same: [], same: []";
    "  same: []", "  same: [], typo: []";
    "migration = Migration", "other = Migration"];
  ignore (refuses "MIG002" path (replace "{ Note: Additive [] }" "[]" source));
  ignore (refuses "MIG020" path (source ^ "other = Migration {}\n"));
  ignore (refuses "MIG020" path (declaration ~fixtures:"  fixtures: [unknownFixture]\n" "Note: Additive []")))

let adjacent_versions () = with_project (fun _ write path ->
  let source = declaration "Note: Additive []" in
  List.iter (fun (before,after) -> ignore (refuses "MIG020" path (replace before after source))) [
    "from: NotesSchema.V1", "from: NotesSchema.VCurrent";
    "to: NotesSchema.VCurrent", "to: NotesSchema.V1";
    "from: NotesSchema.V1", "from: \"NotesSchema.V1\"";
    "from: NotesSchema.V1", "from: NotesSchema.V1.Note";
    "import NotesSchema.V1\n", "";
    "import NotesSchema.VCurrent\n", ""];
  let wrong = write "migrations/notes/wrong.tesl" source in
  ignore (refuses "MIG020" wrong source);
  ignore (write "schema/notes/v2.tesl" (replace "NotesSchema.VCurrent" "NotesSchema.V2" (schema "")));
  ignore (refuses "MIG020" path source))

let schema_errors () = with_project (fun _ write path ->
  ignore (write "schema/notes/v-current.tesl" (schema "  archivedAt: UnknownType\n"));
  let ds = refuses "MIG020" path (declaration "Note: Additive []") in
  check bool "invalid schema is not edited history evidence" false (List.exists (fun (d : Compile.diagnostic) -> d.code = "MIG013") ds))

let saved_buffer () = with_project (fun _ write path ->
  (* An unsaved migration buffer must not parse a different saved body. *)
  ignore (write "migrations/notes/v2.tesl" "module broken = @@@");
  accepts path (declaration "Note: Additive []");
  ignore (refuses "MIG002" path (declaration ""));
  accepts path (declaration "Note: Additive []"))

let retained_queries () = with_project (fun _ write path ->
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    let source = declaration "Note: Additive []" in
    accepts path source;
    ignore (write "schema/notes/v-current.tesl" (schema "  archivedAt: String\n"));
    ignore (refuses "MIG016" path source);
    accepts path (replace "Additive []" "Additive [Default archivedAt \"unknown\"]" source);
    ignore (write "schema/notes/v-current.tesl" (schema "  archivedAt: Maybe String\n"));
    accepts path source))

let invalid_rules () = with_project ~fresh:(schema "  rank: Int\n") (fun _ _ path ->
  List.iter (fun rules -> ignore (refuses "MIG022" path (declaration ("Note: Additive " ^ rules)))) [
    "True";"[Default missing 0]";"[Default id \"x\"]";"[Default rank (1 + 1)]";
    "[Default rank \"0\"]";"[Default \"rank\" 0]";"[Default rank]";"[Default rank 0 1]" ];
  ignore (refuses "MIG023" path (declaration "Note: Additive [Default rank 0, Default rank 1]"));
  ignore (refuses "MIG016" path (declaration "Note: Additive []")))

let additions_removals () =
  let old = schema "" ^ "entity Old table \"old_rows\" primaryKey id { id: String }\n" in
  let fresh = schema "" ^ "entity Fresh table \"fresh_rows\" primaryKey id { id: String }\n" in
  with_project ~old ~fresh (fun _ _ path ->
    let result = checked path (declaration "Old: Drop, Fresh: New") in
    check int "no adapter fabricated for new or dropped table" 0 (List.length (A.entities (D.additive result)));
    ignore (refuses "MIG002" path (declaration "Old: New, Fresh: Drop"));
    ignore (refuses "MIG002" path (declaration "Fresh: New")))

let escaped_vocabulary () = with_project (fun _ write path ->
  let source = declaration "Note: Additive []" in
  List.iter (fun expression ->
    ignore (refuses "MIG020" path (source ^ "fn escaped() -> Int = " ^ expression ^ "\n")))
    ["Additive []";"Default rank 1";"Same NotesSchema.V1.Note NotesSchema.VCurrent.Note";"New";"Drop";"Migration {}"];
  ignore (refuses "T001" path (source ^ "fn escaped() -> Int = migration\n"));
  ignore (refuses "T001" path (source ^ "fn escaped(value: Entity) -> Int = 0\n"));
  let app = write "app.tesl" (replace "NotesSchema.Migrate.V2" "App" source) in
  ignore (refuses "MIG020" app (replace "NotesSchema.Migrate.V2" "App" source)))

let local_names () = with_project (fun _ write _ ->
  let source = {|module LocalNames exposing [value]
import Tesl.Prelude exposing [Int]
record Migration { count: Int }
type Entity
  = New
  | Drop
value = Migration { count: 1 }
|} in
  let path = write "local-names.tesl" source in
  accepts path source;
  accepts path (replace "import Tesl.Prelude" "import Tesl.Migration exposing [Rule]\nimport Tesl.Prelude" source))

let parser_scope () = with_project (fun _ _ path ->
  ignore (parsed path (declaration "NotesSchema.VCurrent.Note: Additive []"));
  let source = declaration "Note: Additive []" ^ "value = { Unexpected: 1 }\n" in
  ignore (refuses "E000" path source);
  ignore (refuses "E000" path (declaration "Note: Additive [Default]" ^ "value = { Unexpected: 1 }\n")))

let contextual_field_names () =
  List.iter (fun name -> with_project ~fresh:(schema ("  " ^ name ^ ": Int\n")) (fun _ _ path ->
    let source = declaration ("Note: Additive [Default " ^ name ^ " 1]") in
    accepts path source;
    accepts path (Formatter.format_source source)))
    ["select";"insert";"update";"delete";"where";"order";"limit";"offset";
     "enqueue";"serve";"startWorkers";"exists";"with";"set";
     "email";"smtp";"test";"seed";"via";"for";"using";"main";"of";"ok";"fail"]

let source_formatting () = with_project ~fresh:(schema "  rank: Int\n") (fun _ _ path ->
  let source = declaration "NotesSchema.VCurrent.Note: Additive [Default rank (-7)]" in
  let expected = checked path source in
  let formatted = Formatter.format_source source in
  let actual = checked path formatted in
  check string "formatting is idempotent" formatted (Formatter.format_source formatted);
  let values result = (only (A.entities (D.additive result))).values |> List.filter_map (function
    | A.Constant (field,value) -> Some (field.name,value) | _ -> None) in
  check bool "formatting preserves adapter values" true (values expected = values actual))

let contextual_purity () = with_project ~fresh:(schema "  rank: Int\n") (fun _ write path ->
  let effectful_source = declaration "Note: Additive [Default rank (selectOne n from Note)]" in
  ignore (refuses "MIG022" path effectful_source);
  let schema_source = schema "  rank: Int\n" ^ "migration = Migration {}\n" |> replace
    "import Tesl.Float" "import Tesl.Migration exposing [Migration]\nimport Tesl.Float" in
  let schema_path = write "schema/notes/v-current.tesl" schema_source in
  ignore (refuses "V001" schema_path schema_source);
  match Migration_inventory.load ~compiler_abi:"test-compiler-1" ~root_file:schema_path with
  | Error error -> check bool "schema constants remain outside the frozen inventory" true
      (Compile.string_contains error.message "application constants")
  | Ok _ -> fail "schema gained permission to own a Migration declaration")

let imported_diagnostics () = with_project (fun _ write path ->
  let root_source = declaration "Note: Additive []" ^ "fn answer() -> Int = 42\n" |>
    replace "exposing [migration]" "exposing [migration, answer]" in
  ignore (write "migrations/notes/v2.tesl" root_source);
  let helper = {|module NotesSchema.Migrate.Helpers exposing [answer]
import Tesl.Prelude exposing [Int]
import NotesSchema.Migrate.V2
fn answer() -> Int = NotesSchema.Migrate.V2.answer()
|} in
  let helper_path = write "migrations/notes/helpers.tesl" helper in
  accepts helper_path helper;
  ignore (write "migrations/notes/v2.tesl" (replace "Note: Additive []" "" root_source));
  let ds = refuses "MIG002" helper_path helper in
  let contextual = List.filter (fun (d : Compile.diagnostic) -> d.code = "MIG002") ds in
  check int "one source-anchored dependency failure" 1 (List.length contextual);
  check string "diagnostic belongs to migration file" path (only contextual).file;
  check string "migration diagnostic source" "migration" (only contextual).source;
  check bool "paired entity locations survive public diagnostics" true
    (Compile.string_contains (only contextual).message "schema/notes/v1.tesl:");
  ignore (write "migrations/notes/v2.tesl" root_source);
  accepts helper_path helper;
  ignore (refuses "T001" helper_path (replace "V2.answer()" "V2.migration" helper)))

let literal_and_import_boundaries () = with_project ~fresh:(schema "  active: Bool\n") (fun _ write path ->
  let source = declaration "Note: Additive [Default active False]" in
  accepts path source;
  ignore (refuses "T001" path (replace "Entity(..)" "Entity" source));
  ignore (refuses "T001" path (replace "Rule(..)" "Rule" source));
  accepts path (replace "Bool(..)" "Bool" source);
  accepts path (replace "Entity(..), Rule(..)" "Additive, Default" source);
  accepts path (replace "import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]"
    "import Tesl.Migration" source);
  let lookalike = source ^ "type Flag\n  = False\n  | True\n" in
  ignore (refuses "MIG022" path lookalike);
  ignore (write "migrations/notes/flags.tesl" "module NotesSchema.Migrate.Flags exposing [Flag(..)]\ntype Flag\n  = False\n  | True\n");
  ignore (refuses "MIG022" path (replace "import NotesSchema.V1"
    "import NotesSchema.Migrate.Flags exposing [Flag(..)]\nimport NotesSchema.V1" source));
  accepts path (replace "import NotesSchema.V1" "import NotesSchema.Migrate.Flags\nimport NotesSchema.V1" source);
  ignore (refuses "VBOOL001" path (replace "Default active False" "Default active false" source));
  ignore (refuses "MIG022" path (replace "Default active False" "Default active \"False\"" source));
  ignore (refuses "MIG020" path (replace "import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]\n" "" source)))

let multi_namespace_same () =
  let payload = {|import Tesl.Json exposing [stringCodec]
record Payload { text: String }
codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
|} in
  let old = prefix ^ payload ^ {|entity Note table "notes" primaryKey id {
  id: String
  payload: Payload
}
|} in
  with_project ~old ~fresh:old (fun _ write path ->
    let source = declaration ~same:"[Same NotesSchema.V1.Payload NotesSchema.VCurrent.Payload]" "" in
    let result = checked path source in
    check int "one spelling explicitly checks record and codec" 2 (List.length (S.identities (D.coverage result)));
    ignore (refuses "MIG016" path (declaration ""));
    ignore (refuses "MIG024" path (declaration ~same:"[Same NotesSchema.V1.Payload NotesSchema.VCurrent.Payload, Same NotesSchema.V1.Payload NotesSchema.VCurrent.Payload]" ""));
    ignore (write "schema/notes/v-current.tesl" (replace "-> \"text\"" "-> \"body\"" old));
    ignore (refuses "MIG024" path source))

let backend_erasure () = with_project (fun root write path ->
  let source = declaration "Note: Additive []" ^ {|fn answer() -> Int = 42
test "pure functions beside migration declarations" {
  expect answer() == 42
}
|} in
  accepts path source;
  match Compile.compile_go_source path source with
  | Compile.GoFailure ds -> fail (describe ds)
  | Compile.GoSuccess artifacts ->
    let output = String.concat "\n" (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts) in
    check bool "no emitted migration value" false
      (try ignore (Str.search_forward (Str.regexp_string "var Migration ") output 0); true with Not_found -> false);
    List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
    let log = Filename.concat root "go-test.log" in
    let command = Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 -v ./... > %s 2>&1"
      (Filename.quote (Filename.concat root "out")) (Filename.quote log) in
    let status = Sys.command command in
    let output = In_channel.with_open_bin log In_channel.input_all in
    if status <> 0 then fail output;
    check bool "the pure test next to the contextual declaration actually ran" true
      (Compile.string_contains output "--- PASS:"))

let contextual_holes () = with_project ~fresh:(schema "  rank: Int\n") (fun _ write path ->
  List.iter (fun entry ->
    let source = declaration entry in
    let ds = refuses "MIG003" path source in
    check (list string) "placeholder has one focused error" ["MIG003"] (List.map (fun (d : Compile.diagnostic) -> d.code) ds);
    check bool "reason survives diagnostic" true (Compile.string_contains (List.hd ds).message "choose rank");
    check bool "agent-context refuses hole" false (Compile.agent_context_result_source path source).ok;
    ignore (refuses "MIG003" path (Formatter.format_source source));
    (match Compile.compile_go_source path source with
     | Compile.GoFailure ds -> check bool "backend retains blocking diagnostic" true
         (List.exists (fun (d : Compile.diagnostic) -> d.code="MIG003") ds)
     | Compile.GoSuccess _ -> fail "unresolved decision emitted runtime code"))
    ["Note: todo \"choose rank\"";"Note: Additive [Default rank (todo \"choose rank\")]"];
  let source = declaration "Note: todo \"choose rank\"" |> replace "exposing [migration]" "exposing [migration, answer]" in
  let source = source ^ "fn answer() -> Int = 42\n" in
  ignore (write "migrations/notes/v2.tesl" source);
  let importer = "module NotesSchema.Migrate.Caller exposing [value]\nimport Tesl.Prelude exposing [Int]\nimport NotesSchema.Migrate.V2 exposing [answer]\nfn value() -> Int = answer()\n" in
  let file = write "migrations/notes/caller.tesl" importer in
  ignore (refuses "MIG003" file importer))
let holes_do_not_escape () = with_project (fun _ write path ->
  ignore (refuses "T001" path (declaration "Note: Additive []" ^ "fn value() -> Int = todo \"missing\"\n"));
  let ordinary = "module Ordinary exposing [value]\nimport Tesl.Prelude exposing [Int, String]\nfn todo(reason: String) -> Int = 7\nfn value() -> Int = todo \"ordinary function\"\n" in
  let file = write "ordinary.tesl" ordinary in accepts file ordinary)

let () = run "Migration-Declarations" ["contextual source", [
  test_case "nullable adapter and folded unchanged table" `Quick nullable;
  test_case "exact source literals" `Quick defaults;
  test_case "sparse coverage and aliases" `Quick sparse;
  test_case "malformed records and required fields" `Quick malformed_records;
  test_case "adjacent schemas and canonical source" `Quick adjacent_versions;
  test_case "schema errors are not seal errors" `Quick schema_errors;
  test_case "unsaved migration source wins" `Quick saved_buffer;
  test_case "retained queries track schema dependencies" `Quick retained_queries;
  test_case "rule typing and duplicate defaults" `Quick invalid_rules;
  test_case "added and removed tables" `Quick additions_removals;
  test_case "contextual vocabulary cannot escape" `Quick escaped_vocabulary;
  test_case "unimported local names keep their meaning" `Quick local_names;
  test_case "entity keys do not widen ordinary record syntax" `Quick parser_scope;
  test_case "rules accept legal entity field names" `Quick contextual_field_names;
  test_case "formatting preserves contextual source" `Quick source_formatting;
  test_case "contextual field references do not permit effects or schema constants" `Quick contextual_purity;
  test_case "imported declarations retain diagnostics and have no runtime value" `Quick imported_diagnostics;
  test_case "literal and constructor import boundaries" `Quick literal_and_import_boundaries;
  test_case "Same checks record and same-named codec" `Quick multi_namespace_same;
  test_case "backend erases declaration only" `Quick backend_erasure;
  test_case "contextual decision holes block all compilation paths" `Quick contextual_holes;
  test_case "contextual holes do not change ordinary names" `Quick holes_do_not_escape;
]]
