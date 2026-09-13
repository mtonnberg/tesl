open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, owner: String, title: String, count: Int }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: []
  fixtures: [oldNote]
  entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  if old.id == "reject" then
    Reject "source rejected"
  else
    Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: amount() })
fn amount() -> Int = 7
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", author: "writer", title: "hello" }
test "actual pure transformation helper" {
  case convert (oldNote()) of
    Row row -> expect row.owner == "writer"
    Reject reason -> expect False
}
|}
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let project ?(before=old) ?(after=fresh) f =
  let root=Filename.temp_file "tesl-transform-source-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let save p s = let file=Filename.concat root p in write file s; file in
    ignore (save "tesl.toml" ""); ignore (save "schema/notes/v1.tesl" before); ignore (save "schema/notes/v-current.tesl" after);
    let file=save "migrations/notes/v2.tesl" source in f root save file)
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let errors path s = (Compile.agent_context_result_source path s).diagnostics |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts path s = match errors path s with [] -> () | ds -> fail (describe ds)

module RH=Migration_row_history
module P=Migration_program
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  dbName: "unused"
  user: "unused"
  password: "secret-sentinel"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
|}
let load file =
 let abi=Result.get_ok (Migration_abi.current ()) in
 match Migration_inventory.load_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
 | Ok i -> i | Error e -> fail e.message
let seal root file=match Migration_seal.create ~project_root:root (load file) with
 | Ok s -> s | Error e -> fail e.message
let get = function Ok value -> value | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let capture root f =
 let file=Filename.concat root "app.tesl" in
 let source=Source_input.read file in
 let entry=match Parser.parse_module file source with Ok m -> m | Err e -> fail e.msg in
 P.with_source_history ~entry ~source (function Some h -> f h | None -> fail "missing source history")
let emit file = match Compile.compile_row_source_artifacts file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)
let native ?source_root ?(extra_tests=[]) ?(test="") artifacts =
 let root=Filename.temp_dir "tesl-row-native-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then
   write (Filename.concat root a.path) a.contents) artifacts;
  List.iter (fun (path,source) -> write (Filename.concat root path) source) extra_tests;
  let rec source_files path=if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then
   Array.to_list (Sys.readdir path) |> List.concat_map (fun name -> source_files (Filename.concat path name))
   else if Filename.check_suffix path ".tesl" then [path,In_channel.with_open_bin path In_channel.input_all] else [] in
  let hidden=Option.fold ~none:[] ~some:source_files source_root in
  List.iter (fun (path,_) -> Sys.remove path) hidden;
  Fun.protect ~finally:(fun () -> List.iter (fun (path,bytes) -> write path bytes) hidden) (fun () ->
  if test<>"" then write (Filename.concat root "internal/teslmodapp/migration_registration_test.go") test;
  let log=Filename.concat root "native.log" in
  let status=Sys.command (Printf.sprintf "cd %s && timeout 180s go test -p 1 -race -timeout=120s -count=1 ./... > %s 2>&1" (Filename.quote root) (Filename.quote log)) in
  if status<>0 then fail (In_channel.with_open_bin log In_channel.input_all)))
let native_test = {|package teslmodapp
import (
 "testing"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestCompiledRow(t *testing.T) {
 input := old.Note{Id:"kept", Author:"writer", Title:"hello"}
 if _, err := MainDatabaseCompiledRowTransform0.Run(input); err == nil { t.Fatal("unsealed callback ran") }
 history, ok := MainDatabase.CompiledMigrationHistory()
 if !ok { t.Fatal("missing actual source companion") }
 if _, err := history.ExpansionPlan(1); err == nil { t.Fatal("source metadata gained expansion authority") }
 if err := teslrt.PreflightApplicationDatabases(MainDatabase); err != nil { t.Fatal(err) }
 input.Id="reject"
 rejected, rejectErr := MainDatabaseCompiledRowTransform0.Run(input)
 if rejectErr != nil || rejected.Tag != teslrt.MigratedReject || rejected.RejectReason != "source rejected" { t.Fatal("Tesl Reject branch lost", rejected, rejectErr) }
 input.Id="kept"
 result, err := MainDatabaseCompiledRowTransform0.Run(input)
 if err != nil || result.Tag != teslrt.MigratedRow || result.RowValue.Id != "kept" || result.RowValue.Owner != "writer" || result.RowValue.Title != "hello" || result.RowValue.Count.String() != "7" {
  t.Fatalf("wrong row: %#v %v", result, err)
 }
}
|}

let replace a b = Str.global_replace (Str.regexp_string a) b
let sealed root path body =
 let header=get(Migration_header.create ~previous:(seal root(Filename.concat root "schema/notes/v1.tesl"))
  ~current:(seal root(Filename.concat root "schema/notes/v-current.tesl"))) in
 write path(Migration_header.encode header ^ body)
let cycle_fixture ?(before=old) ?(after=fresh) ?(source=source) ?(nominal=false) f=project ~before ~after(fun root save path ->
 let index=Str.search_forward(Str.regexp_string "fn convert")source 0 in
 let head=String.sub source 0 index and body=String.sub source index(String.length source-index) in
 let start=Str.search_forward(Str.regexp_string "import Tesl.Prelude")head 0 in
 let stop=Str.search_forward(Str.regexp_string "migration =")head 0 in
 let imports=String.sub head start(stop-start) in
 let left="module Schema.Notes.Migrate.Left exposing [convert, oldNote]\nimport Schema.Notes.Migrate.Right exposing [amount]\n" ^ imports ^
  replace "fn amount() -> Int = 7\n" "" body in
 let right={|module Schema.Notes.Migrate.Right exposing [amount]
import Tesl.Prelude exposing [Int]
import Schema.Notes.Migrate.Left exposing []
fn convert() -> Int = 5
fn amount() -> Int = convert() + 2
|} in
 let left_path=save "migrations/notes/left.tesl" left in
 let right_path=save "migrations/notes/right.tesl" right in
 let declaration=head |> replace "exposing [migration, oldNote]" "exposing [migration]"
  |> replace "import Tesl.Prelude" "import Schema.Notes.Migrate.Left exposing [convert, oldNote]\nimport Tesl.Prelude" in
 sealed root path declaration;
 let entry=save "app.tesl" app in
 if nominal then check bool "standalone cycle helper cannot borrow root Same" true (errors left_path left<>[])
 else (accepts left_path left;accepts right_path right);
 accepts entry app;
 f root entry)
let helper_cycle_native ()=cycle_fixture(fun root entry ->
 let artifacts=emit entry in
 check bool "cycle owner emitted once" true
  (List.exists(fun(a:Emit_go.artifact)->a.path="internal/teslmodschemanotesmigrateleft/module.go")artifacts);
 check bool "second cycle owner merged" false
  (List.exists(fun(a:Emit_go.artifact)->a.path="internal/teslmodschemanotesmigrateright/module.go")artifacts);
 native ~source_root:root ~test:native_test artifacts)
let exact_graph ()=cycle_fixture(fun root _ ->
 get(capture root(fun history ->
  let graph=get(P.source_lowering history) in
  let originals=List.map fst(P.source_modules history) in
  let entry=List.find(fun(m:Ast.module_form)->m.module_name="App")originals in
  let again=match Go_graph_lowering.lower ~entry(List.rev originals) with Ok value->value | Error message->fail message in
  check bool "deterministic under captured traversal permutation" true
   (Go_graph_lowering.modules graph=Go_graph_lowering.modules again);
  let row=List.hd(RH.bindings(List.assoc "App.Main" (P.row_histories history))) in
  let original=Option.get (RH.row row).function_binding in
  let emitted,fn=Option.get(Go_graph_lowering.function_binding graph ~owner:original.owner original.declaration) in
  check string "exact checked callback owner collapsed" "Schema.Notes.Migrate.Left" emitted.module_name;
  check string "callback collision gets owner-qualified emitted name" "Scc$Schema.Notes.Migrate.Left$convert" fn.name;
  check bool "original callback unchanged" true (original.declaration.name="convert");
  check bool "original expression correspondence" true
   (Go_graph_lowering.original_expr graph fn.body==original.declaration.body);
  let changed={original.declaration with body=Ast.EVar{name="forged";loc=original.declaration.loc}} in
  check bool "altered checked callback cannot select same-name export" true
   (Go_graph_lowering.function_binding graph ~owner:original.owner changed=None);
  let modules=Go_graph_lowering.modules graph in
  ignore(get(P.verify_source_history history modules));
  let forged=List.map(fun(m:Ast.module_form)->{m with decls=List.map(function
    | Ast.DFunc f when f.name=fn.name -> Ast.DFunc{f with body=changed.body}
    | d->d)m.decls})modules in
  check bool "emitted graph substitution refused" true
   (match P.verify_source_history history forged with Error errors->List.exists(fun(e:S.error)->e.code="MIG013")errors | Ok()->false))))

let nominal_cycle_native ()=
 let with_metadata schema = schema
  |> replace "exposing [Note]" "exposing [Note, Metadata]"
  |> replace "entity Note" {|import Tesl.Json exposing [stringCodec]
record Metadata { text: String, hidden: String }
codec Metadata {
 toJson { text -> "storedText" with_codec stringCodec }
 fromJson [ { text <- "storedText" with_codec stringCodec, hidden <- default "decoded" } ]
}
entity Note|} in
 let before=with_metadata old |> replace "title: String }" "title: String, metadata: Metadata, retired: String }" in
 let after=with_metadata fresh |> replace "count: Int }" "count: Int, metadata: Metadata }" in
 let source=source |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.Metadata Schema.Notes.VCurrent.Metadata]"
  |> replace "Rename author owner]" "Rename author owner, Legacy retired \"fallback\"]"
  |> replace "count: amount() }" "count: amount(), metadata: old.metadata }"
  |> replace "title: \"hello\" }" "title: \"hello\", metadata: Schema.Notes.V1.Metadata { text: \"nested\", hidden: \"original\" }, retired: \"stored\" }" in
 cycle_fixture ~before ~after ~source ~nominal:true (fun root entry ->
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry(Source_input.read entry) with
   | Compile.GoSuccess artifacts->artifacts | Compile.GoFailure ds->fail(describe ds) in
  let test={|package teslmodapp
import (
 "reflect"
 "testing"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestNominalHelperCycleForwardAndInverse(t *testing.T) {
 if err := teslrt.PreflightApplicationDatabases(MainDatabase); err != nil { t.Fatal(err) }
 before := old.Note{Id:"kept",Author:"writer",Title:"hello",Metadata:old.Metadata{Text:"nested",Hidden:"original"},Retired:"stored"}
 result, err := MainDatabaseCompiledRowTransform0.Run(before)
 if err != nil || result.Tag != teslrt.MigratedRow || result.RowValue.Count.String() != "7" || result.RowValue.Metadata.Hidden != "original" { t.Fatal("source-site transport lost",result,err) }
 previous, err := MainDatabaseCompiledRowWriteBack0.Reverse(result.RowValue)
 if err != nil || previous.Metadata != before.Metadata || previous.Retired != "fallback" { t.Fatal("inverse owner/certificate lost",previous,err) }
 if !reflect.DeepEqual(old.EncodeMetadataJSON(before.Metadata),fresh.EncodeMetadataJSON(result.RowValue.Metadata)) { t.Fatal("original codec owner changed") }
 if _,err := old.TeslEncodeRowNote(previous); err != nil { t.Fatal(err) }
 if _,err := fresh.TeslEncodeRowNote(result.RowValue); err != nil { t.Fatal(err) }
}
|} in native ~source_root:root ~test artifacts)

let unsupported_cycle_boundaries ()=project(fun root save path ->
 sealed root path source;
 let app_source=replace "import Tesl.Database" "import A exposing []\nimport Tesl.Database" app in
 let entry=save "app.tesl" app_source in
 let refused needle bytes =
  let matches ds=List.exists(fun(d:Compile.diagnostic)->d.code="V001" && Compile.string_contains d.message needle)ds in
  check bool ("agent-context retains " ^ needle) true(matches(errors entry bytes));
  match Compile.compile_row_source_artifacts entry bytes with
  | Compile.GoFailure ds -> check bool ("captured artifact retains " ^ needle) true(matches ds)
  | Compile.GoSuccess _ -> fail("captured artifact bypassed " ^ needle) in
 List.iter(fun body ->
  ignore(save "a.tesl" ("module A exposing [value]\nimport Tesl.Prelude exposing [Int]\nimport B exposing []\nfn helper() -> Int = 1\n" ^ body));
  ignore(save "b.tesl" "module B exposing []\nimport Tesl.Prelude exposing [Int]\nimport A exposing []\nfn helper() -> Int = 2\n");
  refused "shadow" app_source)
  ["fn value(helper: Int) -> Int = helper + 10\n";
   "fn value() -> Int =\n  let helper = 7\n  helper + 10\n";
   "fn value() -> Int =\n  case 7 of\n    helper -> helper + 10\n"];
 let codec name peer = Printf.sprintf {|module %s exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import %s exposing []
record Value { text: String }
codec Value {
  toJson { text -> "stored" with_codec stringCodec }
  fromJson [ { text <- "stored" with_codec stringCodec } ]
}
|} name peer in
 ignore(save "a.tesl" (codec "A" "B"));ignore(save "b.tesl" (codec "B" "A"));
 refused "declares codec" app_source;
 let app_cycle=replace "import Tesl.Database" "import B exposing []\nimport Tesl.Database" app in
 ignore(save "app.tesl" app_cycle);ignore(save "b.tesl" "module B exposing []\nimport App exposing []\n");
 refused "database" app_cycle)
let ()=run "captured SCC emission" ["ownership",[
 test_case "helper cycle callback collision native" `Quick helper_cycle_native;
 test_case "deterministic exact owner and expression mapping" `Quick exact_graph;
 test_case "nominal Same and inverse codec owner across helper cycle" `Quick nominal_cycle_native;
 test_case "captured source retains codec database and lexical-shadow cycle boundaries" `Quick unsupported_cycle_boundaries]]
