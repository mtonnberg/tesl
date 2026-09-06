open Alcotest

let replace a b = Str.global_replace (Str.regexp_string a) b
let imports = {|import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migrated(..)]
|}
let program body = "module Probe exposing []\n" ^ imports ^ body ^ "\n"
let describe ds = String.concat "\n" (List.map (fun (d : Compile.diagnostic) ->
  Printf.sprintf "%s:%d: %s: %s" d.file (d.start_line + 1) d.code d.message) ds)
let errors source =
  (Compile.agent_context_result_source "probe.tesl" source).diagnostics
  |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let accepts source = match errors source with [] -> () | ds -> fail (describe ds)
let refuses expected source =
  let ds = errors source in
  if not (List.exists (fun (d : Compile.diagnostic) -> Compile.string_contains d.message expected) ds)
  then failf "expected %S, got:\n%s\n%s" expected (describe ds) source

let typed () =
  accepts (program {|fn wrap(value: a) -> Migrated a = Row value
fn reject() -> Migrated Int = Reject "invalid"
fn rejectedString() -> Migrated String = Reject "invalid"
fn separate() -> String =
  let integer: Migrated Int = wrap 7
  let text: Migrated String = wrap "separate"
  case text of
    Row value -> value
    Reject reason -> reason
record Envelope { result: Migrated Int }
|});
  List.iter (fun body -> refuses "cannot unify" (program body))
    ["fn wrong() -> Migrated String = Row 7";
     "fn wrong() -> Migrated Int = Reject 7";
     "fn wrong(value: Migrated Int) -> String =\n  case value of\n    Row row -> row\n    Reject reason -> reason";
     "fn wrong(value: Migrated Int) -> Int =\n  case value of\n    Row row -> row\n    Reject reason -> reason"];
  accepts (program {|record Old { id: String }
record New { id: String }
fn good(value: New) -> Migrated New = Row value
|});
  refuses "cannot unify" (program {|record Old { id: String }
record New { id: String }
fn wrong(value: Old) -> Migrated New = Row value
|})

let exhaustive () =
  let header = "fn inspect(value: Migrated Int) -> Int =\n  case value of\n" in
  accepts (program (header ^ "    Row row -> row\n    Reject reason -> 0"));
  refuses "Reject" (program (header ^ "    Row row -> row"));
  refuses "Row" (program (header ^ "    Reject reason -> 0"));
  accepts (program {|fn nested(value: Migrated (Migrated Int)) -> Int =
  case value of
    Row (Row row) -> row
    Row (Reject reason) -> 1
    Reject reason -> 2
|});
  refuses "non-exhaustive" (program {|fn nested(value: Migrated (Migrated Int)) -> Int =
  case value of
    Row (Row row) -> row
    Reject reason -> 2
|})

let gated () =
  let body = "fn value() -> Migrated Int = Row 7\n" in
  List.iter (fun import -> accepts (replace "import Tesl.Migration exposing [Migrated(..)]" import (program body)))
    ["import Tesl.Migration"; "import Tesl.Migration exposing [Migrated, Row]"];
  refuses "requires `import Tesl.Migration`"
    (replace "Migrated(..)" "Migrated" (program body));
  refuses "does not export" (replace "Tesl.Migration" "Tesl.Database" (program body));
  refuses "requires `import Tesl.Migration`"
    (replace "import Tesl.Migration exposing [Migrated(..)]\n" "" (program "fn value() -> Int =\n  let row = Row 7\n  7"));
  (* A type-only import does not grant its pattern constructors either. *)
  refuses "requires `import Tesl.Migration`" (program {|fn value(row: Migrated Int) -> Int =
  case row of
    Row value -> value
    Reject reason -> 0
|} |> replace "Migrated(..)" "Migrated")

let contextual_boundary () =
  List.iter (fun expression ->
    refuses "contextual migration syntax" (program
      ("fn escaped() -> Int = " ^ expression) |> replace "Migrated(..)" "Migrated(..), Entity(..), Rule(..), Same(..), Migration"))
    ["New"; "Additive []"; "Default field 7"; "Migration {}"];
  List.iter (fun name ->
    check bool (name ^ " stays ordinary") false (List.mem name Migration_form.names);
    check bool (name ^ " is not config-only") false (Stdlib_config_names.is_rejected_in_type_position name))
    Migration_form.runtime_names;
  accepts {|module Probe exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Migration exposing [Rule]
type Migrated
  = Row Int
  | Reject String
fn value() -> Migrated = Row 7
|}

let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun o -> output_string o source)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-migrated-result-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root (fun relative source ->
    let file = Filename.concat root relative in write file source; file))

let old_schema = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, authorId: String, title: String }
|}
let new_schema = {|module Schema.Notes.VCurrent exposing [Note, NonEmpty, titleProof]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish titleProof(value: String) -> Maybe (Fact (NonEmpty value)) =
  if value != "" then
    Something (NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, ownerId: String, title: String ::: NonEmpty title }
|}
let converter = {|module Schema.Notes.Migrate.Converter exposing [convert]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  let title = old.title
  case Schema.Notes.VCurrent.titleProof title of
    Nothing -> Reject "empty title"
    Something proof -> Row (Schema.Notes.VCurrent.Note { id: old.id, ownerId: old.authorId, title: title ::: proof })
|}
let entry = {|module Schema.Notes.Migrate.Probe exposing [inspect, plain, nested]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Notes.Migrate.Converter
import Schema.Notes.V1
import Schema.Notes.VCurrent
fn inspect(title: String) -> String =
  let old = Schema.Notes.V1.Note { id: "retained", authorId: "author", title: title }
  case Schema.Notes.Migrate.Converter.convert old of
    Row value -> value.id ++ ":" ++ value.ownerId ++ ":" ++ value.title
    Reject reason -> "rejected:" ++ reason
fn wrap(value: a) -> Migrated a = Row value
fn plain() -> Migrated Int = wrap 17
fn nested() -> Migrated (Migrated String) = wrap (wrap "nested")
test "pure row result across schema modules" {
  expect inspect "hello" == "retained:author:hello"
  expect inspect "" == "rejected:empty title"
  expect inspect "å🙂" == "retained:author:å🙂"
}
|}

let install_fixture write =
  ignore (write "tesl.toml" "");
  ignore (write "schema/notes/v1.tesl" old_schema);
  ignore (write "schema/notes/v-current.tesl" new_schema);
  ignore (write "migrations/notes/converter.tesl" converter);
  write "migrations/notes/probe.tesl" entry

let proof_and_owner () = with_project (fun _ write ->
  ignore (install_fixture write);
  let path = write "migrations/notes/converter.tesl" converter in
  let ds = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity="error") in
  if ds <> [] then fail (describe ds);
  List.iter (fun (expected, source) ->
    ignore (write "migrations/notes/converter.tesl" source);
    let ds = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity="error") in
    if not (List.exists (fun (d : Compile.diagnostic) -> Compile.string_contains d.message expected) ds)
    then fail ("row result did not preserve the expected boundary:\n" ^ describe ds))
    [ "does not statically satisfy declared proof", replace "title: title ::: proof" "title: old.title" converter;
      "cannot unify Schema.Notes.V1.Note with Schema.Notes.VCurrent.Note",
        replace "Row (Schema.Notes.VCurrent.Note { id: old.id, ownerId: old.authorId, title: title ::: proof })" "Row old" converter])

let native all_imports = with_project (fun root write ->
  if Sys.command "go version >/dev/null 2>&1" <> 0 then skip ();
  let path = install_fixture write in
  if all_imports then begin
    ignore (write "migrations/notes/converter.tesl" (replace "import Tesl.Migration exposing [Migrated(..)]" "import Tesl.Migration" converter));
    ignore (write "migrations/notes/probe.tesl" (replace "import Tesl.Migration exposing [Migrated(..)]" "import Tesl.Migration" entry))
  end;
  let artifacts = match Compile.compile_go_file path with
    | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
  ignore (write "out/internal/teslmodschemanotesmigrateprobe/result_native_test.go" {|package teslmodschemanotesmigrateprobe
import (
 "testing"
 "tesl.generated/teslmodschemanotesmigrateprobe/internal/teslrt"
)
func TestActualMigratedResult(t *testing.T) {
 for input,want:=range map[string]string{"hello":"retained:author:hello", "":"rejected:empty title", "å🙂":"retained:author:å🙂"} {
  if got:=Inspect(input);got!=want {t.Fatalf("%q: %q != %q",input,got,want)}
 }
 row:=Plain();if row.Tag!=teslrt.MigratedRow || row.RowValue.String()!="17" {t.Fatal(row)}
 nested:=Nested();if nested.Tag!=teslrt.MigratedRow || nested.RowValue.Tag!=teslrt.MigratedRow || nested.RowValue.RowValue!="nested" {t.Fatal(nested)}
 var absent teslrt.Migrated[string]
 if absent.Tag!=teslrt.MigratedReject {t.Fatal("zero fabricated a row")}
}
|});
  (* Only generated Go and its embedded runtime remain available to execution. *)
  List.iter (fun name -> remove (Filename.concat root name)) ["schema"; "migrations"; "tesl.toml"];
  let command = Printf.sprintf "cd %s && GOMAXPROCS=2 go test -race -p 1 -count=1 -timeout=60s ./... 2>&1"
      (Filename.quote (Filename.concat root "out")) in
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with Unix.WEXITED 0 -> () | _ -> fail output)

let () = run "Migration result type" ["typed boundary", [
  test_case "precise generic and nominal payloads" `Quick typed;
  test_case "both branches and nested matches are exhaustive" `Quick exhaustive;
  test_case "constructors use ordinary import gates" `Quick gated;
  test_case "declaration vocabulary remains contextual" `Quick contextual_boundary;
  test_case "proof and entity owner cannot be manufactured" `Quick proof_and_owner;
  test_case "actual Go result across modules with proofs" `Quick (fun () -> native false);
  test_case "ImportAll emits the same runtime result" `Quick (fun () -> native true);
]]
