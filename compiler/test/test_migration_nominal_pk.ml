open Alcotest
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let rec remove p = match(Unix.lstat p).Unix.st_kind with
 | Unix.S_DIR -> Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p
 | _ -> Sys.remove p
let schema name extra = Printf.sprintf {|module Schema.Notes.%s exposing [Note, Key, makeNote]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
record Key { value: String }
codec Key {
 toJson { value -> "storedKey" with_codec stringCodec }
 fromJson [ { value <- "storedKey" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: Key, title: String%s }
fn makeNote(value: String) -> Note = Note { id: Key { value: value }, title: value%s }
|} name (if extra then ", count: Int" else "") (if extra then ", count: 7" else "")
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Migration exposing [Migration, Entity(..), Same(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]
 fixtures: [oldNote]
 entities: { Note: Migrate convert [] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: old.id, title: old.title, count: 7 })
fn oldNote() -> Schema.Notes.V1.Note = Schema.Notes.V1.makeNote "fixture"
|}
let project ?(before=schema "V1" false) ?(after=schema "VCurrent" true) f =
 let root=Filename.temp_dir "tesl-nominal-pk-" "" in
 Fun.protect ~finally:(fun()->remove root)(fun()->
  let save path text=let path=Filename.concat root path in write path text;path in
  ignore(save "tesl.toml" "");
  ignore(save "schema/notes/v1.tesl" before);
  ignore(save "schema/notes/v-current.tesl" after);
  let path=save "migrations/notes/v2.tesl" source in f root save path)
let diagnostics path source=(Compile.agent_context_result_source path source).diagnostics
 |>List.filter(fun(d:Compile.diagnostic)->d.severity="error")
let describe ds=String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.code ^ ": " ^ d.message)ds)
let accepts path source=let ds=diagnostics path source in if ds<>[] then fail(describe ds)
let refuses code path source=let ds=diagnostics path source in
 check bool ("expected " ^ code ^ "\n" ^ describe ds) true(List.exists(fun(d:Compile.diagnostic)->d.code=code)ds)
let exact ()=project(fun _ _ path->accepts path source)
let ordinary ()=project(fun _ save _->
 let helper={|module Schema.Notes.Migrate.Ordinary exposing [copy]
import Schema.Notes.V1
import Schema.Notes.VCurrent
fn copy(old: Schema.Notes.V1.Note) -> Schema.Notes.VCurrent.Key = old.id
|} in
 let path=save "migrations/notes/ordinary.tesl" helper in refuses "T001" path helper)
let projection ()=project(fun _ _ path->
 refuses "MIG018" path (replace "id: old.id" "id: Schema.Notes.VCurrent.Key { value: old.id.value }" source);
 refuses "MIG018" path (replace "id: old.id" "id: (oldNote()).id" source))
let missing_same ()=project(fun _ _ path->
 refuses "MIG024" path(replace "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "[]" source))

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
  password: "unused"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
|}
let seal root file =
 let abi=Result.get_ok(Migration_abi.current()) in
 let inventory=match Migration_inventory.load_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
  ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
  | Ok value->value | Error e->fail e.message in
 match Migration_seal.create ~project_root:root inventory with
 | Ok value->value | Error e->fail e.message
let seal_edge ?(body=source) root path =
 let before=Filename.concat root "schema/notes/v1.tesl"
 and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
 | Ok value->value | Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_sparse.error)->e.message)errors)) in
 write path(Migration_header.encode header ^ body)

let adt_schema name extra = Printf.sprintf {|module Schema.Notes.%s exposing [Note, Key(..), makeNote]
import Tesl.Prelude exposing [String, Int]
type Key =
 | Named value: String
 | Absent
codec Key { adtJson }
entity Note table "notes" primaryKey id { id: Key, title: String%s }
fn makeKey(value: String) -> Key =
 if value == "" then
  Absent
 else
  Named { value: value }
fn makeNote(value: String) -> Note = Note { id: makeKey value, title: value%s }
|} name (if extra then ", count: Int" else "") (if extra then ", count: 7" else "")
let native_test = {|package teslmodschemanotesmigratev2
import (
 "reflect"
 "testing"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
)
func TestNominalKeyPreservesCodecInput(t *testing.T) {
 for _, value := range []string{"", "null", "\"quote\"", "å/日本語"} {
  before := old.MakeNote(value)
  result := convert(before)
  after := result.RowValue
  oldColumns, oldErr := old.TeslEncodeRowNote(before)
  newColumns, newErr := fresh.TeslEncodeRowNote(after)
  if oldErr != nil || newErr != nil || !reflect.DeepEqual(oldColumns[0], newColumns[0]) {
   t.Fatalf("stored primary key changed: %#v -> %#v (%v, %v)", oldColumns, newColumns, oldErr, newErr)
  }
  if !reflect.DeepEqual(old.EncodeKeyJSON(before.Id), fresh.EncodeKeyJSON(after.Id)) {
   t.Fatalf("key codec changed: %#v -> %#v", before.Id, after.Id)
  }
 }
}
|}
let native ?(test=native_test) root artifacts =
 let output=Filename.temp_dir "tesl-nominal-native-" "" in
 Fun.protect ~finally:(fun()->remove output)(fun()->
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json") then
   write(Filename.concat output a.path)a.contents)artifacts;
  write(Filename.concat output "internal/teslmodschemanotesmigratev2/nominal_key_test.go")test;
  let rec sources path=match(Unix.lstat path).Unix.st_kind with
   | Unix.S_DIR->Array.to_list(Sys.readdir path)|>List.concat_map(fun p->sources(Filename.concat path p))
   | _ when Filename.check_suffix path ".tesl"->[path,Source_input.read path]
   | _->[] in
  let files=sources root in
  List.iter(fun(path,_)->Sys.remove path)files;
  Fun.protect ~finally:(fun()->List.iter(fun(path,source)->write path source)files)(fun()->
   let log=Filename.concat output "native.log" in
   let status=Sys.command(Printf.sprintf "cd %s && go test -p 1 -race ./... > %s 2>&1" (Filename.quote output)(Filename.quote log)) in
   if status<>0 then fail(Source_input.read log)))
let emit_adt ()=project ~before:(adt_schema "V1" false) ~after:(adt_schema "VCurrent" true)(fun root save path->
 accepts path source;seal_edge root path;
 let entry=save "app.tesl" app in
 let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry app with
 | Compile.GoSuccess artifacts->artifacts | Compile.GoFailure ds->fail(describe ds) in
 native root artifacts)

let emit_record ()=project(fun root save path->
 seal_edge root path;
 let entry=save "app.tesl" app in
 let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry app with
 | Compile.GoSuccess artifacts->artifacts | Compile.GoFailure ds->fail(describe ds) in
 let emitted=String.concat "\n"(List.map(fun(a:Emit_go.artifact)->a.contents)artifacts) in
 check bool "typed structural helper emitted" true (Compile.string_contains emitted "func teslNominalKey");
 check bool "key payload is copied structurally" true (Compile.string_contains emitted "teslResult.Value = teslValue.Value");
 native root artifacts;
 match Sys.getenv_opt "TESL_NOMINAL_EXPORT" with
 | None -> ()
 | Some dir -> List.iter(fun(a:Emit_go.artifact)->write(Filename.concat dir a.path)a.contents)artifacts)


let codec_drift ()=project ~after:(replace "storedKey" "differentKey" (schema "VCurrent" true))
 (fun _ _ path->refuses "MIG024" path source)
let wrong_field ()=
 let add s=s |> replace "id: Key, title:" "id: Key, spare: Key, title:"
  |> replace "id: Key { value: value }, title:" "id: Key { value: value }, spare: Key { value: value }, title:" in
 project ~before:(add(schema "V1" false)) ~after:(add(schema "VCurrent" true))(fun _ _ path->
  refuses "MIG018" path (source |> replace "id: old.id, title:" "id: old.spare, spare: old.spare, title:"))
let unproven_intermediate ()=project(fun _ _ path->
 let forged=source |> replace " Row (Schema.Notes.VCurrent.Note" " let copied: Schema.Notes.VCurrent.Key = old.id\n Row (Schema.Notes.VCurrent.Note" in
 refuses "T001" path forged)
let source_graph_guard ()=project(fun root save path->
 seal_edge root path;
 let app_path=save "app.tesl" app in
 let entry=match Parser.parse_module app_path app with Ok m->m|Err e->fail e.msg in
 let get=function Ok value->value|Error errors->fail(String.concat "\n"(List.map(fun(e:Migration_sparse.error)->e.message)errors)) in
 let source, lowered = get(Migration_program.with_source_history ~entry ~source:app (function None->fail "missing history"|Some captured_source->
  let originals=Migration_program.source_modules captured_source |>List.map fst in
  let lowered=List.map(fun m->match Migration_schema.lower_module ~modules:originals m with
    Ok m->Migration_form.erase m|Error _->fail "lowering")originals in
  let main=List.find(fun(m:Ast.module_form)->m.module_name="App")lowered in
  (match Emit_go.compile_project ~row_storage:true ~row_source:captured_source ~entry:main lowered with
   | Ok _->()|Error errors->fail(String.concat "\n"(List.map(fun(e:Emit_go.emit_error)->e.message)errors)));
  let altered=List.map(fun(m:Ast.module_form)->if m.module_name<>"Schema.Notes.Migrate.V2" then m else
    match Parser.parse_module path (replace "id: old.id" "id: (oldNote()).id" (Source_input.read path)) with
    |Ok m->Migration_form.erase m|Err e->fail e.msg)lowered in
  (match Emit_go.compile_project ~row_storage:true ~row_source:captured_source ~entry:main altered with
   |Error _->()|Ok _->fail "changed original PK projection inherited transport");
  captured_source,lowered)) in
  match Emit_go.compile_project ~row_storage:true ~row_source:source ~entry:(List.hd lowered) lowered with
  | Error _->()|Ok _->fail "escaped checked source inherited nominal lowering")
let current_codec_edited ()=project(fun root save path->
 seal_edge root path;
 let app_path=save "app.tesl" app in
 ignore(save "schema/notes/v-current.tesl" (replace "storedKey" "differentKey" (schema "VCurrent" true)));
 match Compile.compile_row_source_artifacts ~storage:true app_path app with
 | Compile.GoFailure _->()|Compile.GoSuccess _->fail "sealed nominal codec drift accepted")


let lossy_codec ()=
 let lossy s=s |> replace "record Key { value: String }" "record Key { value: String, hidden: String }"
  |> replace "{ value <- \"storedKey\" with_codec stringCodec }" "{ value <- \"storedKey\" with_codec stringCodec, hidden <- default \"decoded\" }"
  |> replace "Key { value: value }" "Key { value: value, hidden: \"original\" }" in
 project ~before:(lossy(schema "V1" false)) ~after:(lossy(schema "VCurrent" true))(fun root save path->
 accepts path source;seal_edge root path;
 let file=save "app.tesl" app in
 let artifacts=match Compile.compile_row_source_artifacts ~storage:true file app with
 | Compile.GoSuccess artifacts->artifacts | Compile.GoFailure ds->fail(describe ds) in
 let test=replace "after := result.RowValue" "after := result.RowValue\n  if after.Id.Hidden != before.Id.Hidden || after.Id.Hidden != \"original\" { t.Fatal(\"transport roundtripped a lossy codec\", before.Id, after.Id) }" native_test in
 native ~test root artifacts)
let shadowed_parameter ()=project(fun _ _ path->
 refuses "MIG018" path (replace " Row (Schema.Notes.VCurrent.Note" " let old = oldNote()\n Row (Schema.Notes.VCurrent.Note" source))

let nominal_proof ()=
 let proven schema=schema |>replace "[Note, Key, makeNote]" "[Note, Key, makeNote, ValidKey]"
  |>replace "entity Note" "fact ValidKey (value: Key)\nestablish keyProof(value: Key) -> Fact (ValidKey value) = ValidKey value\nentity Note"
  |>replace "id: Key, title:" "id: Key ::: ValidKey id, title:"
  |>replace "fn makeNote(value: String) -> Note = Note { id: Key { value: value }," "fn makeNote(value: String) -> Note =\n let key = Key { value: value }\n let proof = keyProof key\n Note { id: key ::: proof," in
 let body=replace "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key, Same Schema.Notes.V1.ValidKey Schema.Notes.VCurrent.ValidKey]" source in
 project ~before:(proven(schema "V1" false)) ~after:(proven(schema "VCurrent" true))(fun _ _ path->
  accepts path body;
  refuses "MIG024" path source)

let intermediate_target ()=project(fun _ _ path->
 let literal="Schema.Notes.VCurrent.Note { id: old.id, title: old.title, count: 7 }" in
 refuses "T001" path (replace (" Row (" ^ literal ^ ")") (" let discarded = " ^ literal ^ "\n Row (" ^ literal ^ ")") source))
let non_primary_copy ()=
 let add s=s |> replace "id: Key, title:" "id: Key, spare: Key, title:"
  |> replace "id: Key { value: value }, title:" "id: Key { value: value }, spare: Key { value: value }, title:" in
 project ~before:(add(schema "V1" false)) ~after:(add(schema "VCurrent" true))(fun _ _ path->
 let copied=source |>replace "id: old.id, title:" "id: old.id, spare: old.spare, title:" in
 accepts path copied;
 refuses "MIG018" path (replace "spare: old.spare" "spare: old.id" copied);
 refuses "MIG018" path (replace "spare: old.spare" "spare: Schema.Notes.VCurrent.Key { value: old.spare.value }" copied))
let nested_nominal_list ()=
 let nested schema=schema |>replace "[Note, Key, makeNote]" "[Note, Key, Inner, makeNote]"
  |>replace "[String, Int]" "[String, Int, List]" |>replace "[stringCodec]" "[stringCodec, listCodec]"
  |>replace "record Key { value: String }" "record Inner { text: String }\ncodec Inner {\n toJson { text -> \"text\" with_codec stringCodec }\n fromJson [ { text <- \"text\" with_codec stringCodec } ]\n}\nrecord Key { value: List Inner }"
  |>replace "storedKey\" with_codec stringCodec" "storedKey\" with_codec listCodec"
  |>replace "Key { value: value }" "Key { value: [Inner { text: value }] }" in
 let body=replace "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key, Same Schema.Notes.V1.Inner Schema.Notes.VCurrent.Inner]" source in
 project ~before:(nested(schema "V1" false)) ~after:(nested(schema "VCurrent" true))(fun root save path->
 accepts path body; refuses "MIG024" path source;seal_edge ~body root path;
 let file=save "app.tesl" app in
 let artifacts=match Compile.compile_row_source_artifacts ~storage:true file app with
 | Compile.GoSuccess artifacts->artifacts | Compile.GoFailure ds->fail(describe ds) in
 native root artifacts)
let key_app = {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.App exposing [App]
import Tesl.Env exposing [envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent exposing [Note, makeNote]
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
api NotesApi {
 get "/health" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 post "/three" -> String
 post "/null" -> String
 put "/all" -> String
 put "/current" -> String
}
handler get health() -> String = "ready"
handler get all() -> List Note requires [dbRead Note] = select note from Note
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "created"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "created"
handler post addThree() -> String requires [dbWrite Note] =
 let rows = [makeNote "three"]
 let _ = insertMany rows in Note
 "created"
handler post addNull() -> String requires [dbWrite Note] =
 let rows = [makeNote ""]
 let _ = insertMany rows in Note
 "created"
handler put editAll() -> String requires [dbWrite Note] =
 update note in Note
  set note.title = "edited"
 "edited"
handler put editCurrent() -> String requires [dbWrite Note] =
 update note in Note
  set note.title = "current"
 "current"
server NotesServer for NotesApi { health, all, addOne, addTwo, addThree, addNull, editAll, editCurrent }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}


let command directory log text =
 let status=Sys.command(Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory)text(Filename.quote log)) in
 if status<>0 then fail(text ^ "\n" ^ Source_input.read log)
let install_contract root path =
 let get=function Ok value->value|Error errors->fail(String.concat "\n"(List.map(fun(e:Migration_sparse.error)->e.message)errors)) in
 let abi=Result.get_ok(Migration_abi.current()) in
 let text=Source_input.read path in
 let ast=match Parser.parse_module path text with Ok m->m|Err e->fail e.msg in
 let declaration=match get(Migration_declaration.check ~compiler_abi:(Migration_abi.id abi) ~source:text ast)with Some d->d|None->fail "no declaration" in
 let before,after=Migration_sparse.inventories(Migration_declaration.coverage declaration) in
 let rows=get(Migration_row_history.check ~schemas:[before;after] ~edges:[declaration]) in
 let plan=get(Migration_retained_storage.plan rows) in
 let text=get(Migration_contract.source ~plan ~version:2) in
 let file=Filename.concat root "migrations/notes/v2-contract.tesl" in
 write file text;accepts file text
let export_application ?(legacy=false) ~adt destination =
 let make_schema name extra=
  let text=(if adt then adt_schema else schema) name extra in
  if legacy && not extra then text |> replace "id: Key, title:" "id: Key, retired: String, title:"
   |> replace "title: value" "retired: \"keep\", title: value" else text in
 let body=if legacy then source |> replace "Entity(..), Same(..)" "Entity(..), Rule(..), Same(..)"
   |> replace "Migrate convert []" "Migrate convert [Legacy retired \"fallback\"]" else source in
 project ~before:(make_schema "V1" false) ~after:(make_schema "VCurrent" true)(fun root save path->
 seal_edge ~body root path;let edge=Source_input.read path in
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let file=save "app.tesl" key_app in
 let build version=
  accepts file key_app;
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true ~physical:true file key_app with
   |Compile.GoSuccess artifacts->artifacts|Compile.GoFailure ds->fail(describe ds) in
  let output=Filename.concat destination version in
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then write(Filename.concat output a.path)a.contents)artifacts;
  let repo=Sys.getenv "TESL_REPO_ROOT" in
  let driver=Source_input.read(Filename.concat repo "compiler/test/fixtures/row-access/main.go") |>replace " \"encoding/json\"" "" in
  let driver=String.split_on_char '\n' driver |>List.filter(fun line->not(Compile.string_contains line "TestAccessEffects"))|>String.concat "\n" in
  let driver=replace "handled, code := rt.RunSchemaCommand" "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V2\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" driver in
  write(Filename.concat output "cmd/access-test/main.go")driver;
  command output (Filename.concat output "build.log") "timeout 150s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test";
  command output (Filename.concat output "lint.log") "golangci-lint run --build-tags tesl_migration_test --timeout 3m ./internal/teslmod* ./cmd/access-test" in
 remove path;remove before;write after(make_schema "VCurrent" false);build "v1";
 write before(make_schema "V1" false);write after(make_schema "VCurrent" true);write path edge;
 install_contract root path;build "v2";
 (* Runtime tests receive only immutable independently built binaries. *)
 List.iter(fun version->let dir=Filename.concat destination version in
  Array.iter(fun name->if name<>"app" && name<>"build.log" && name<>"lint.log" then remove(Filename.concat dir name))(Sys.readdir dir))["v1";"v2"])
let native_application ?(legacy=false) ()=
 let output=Filename.temp_dir "tesl-nominal-apps-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_NOMINAL_PROGRAMS"=None then remove output)(fun()->
  List.iter(fun(kind,adt)->export_application ~legacy ~adt (Filename.concat output kind))["record",false;"adt",true];
  command (Filename.concat(Sys.getenv "TESL_REPO_ROOT")"runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_NOMINAL_LEGACY=%s TESL_ROW_NOMINAL_PROGRAMS=%s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowNominalPrimaryKeyLifecycle$' -count=1 -v" (if legacy then "1" else "0") (Filename.quote output)))

let ()=run "exact nominal migration primary keys" ["source",[
 test_case "checked exact record projection" `Quick exact;
 test_case "ordinary nominal helper stays distinct" `Quick ordinary;
 test_case "reconstruction or another receiver does not gain identity" `Quick projection;
 test_case "complete Same evidence is required" `Quick missing_same;
 test_case "checked application emits structural key bridge" `Quick emit_record;
 test_case "checked ADT key bridge preserves codec input" `Quick emit_adt;
 test_case "Same rejects changed storage codec" `Quick codec_drift;
 test_case "another same-typed field cannot become PK" `Quick wrong_field;
 test_case "intermediate copy gains no nominal authority" `Quick unproven_intermediate;
 test_case "exact graph and live capture bound lowering" `Quick source_graph_guard;
 test_case "sealed codec drift refuses publication" `Quick current_codec_edited;
 test_case "lossy codec never roundtrips the copied value" `Quick lossy_codec;
 test_case "shadowed row binder receives no transport" `Quick shadowed_parameter;
 test_case "actual nominal primary-key Worker and Contract lifecycle" `Quick (native_application ~legacy:false);
 test_case "nominal key proof requires its exact Same predicate" `Quick nominal_proof;
 test_case "intermediate entity construction has no nominal grant" `Quick intermediate_target;
 test_case "non-primary nominal copy requires exact checked projection" `Quick non_primary_copy;
 test_case "nested nominal list needs complete Same closure" `Quick nested_nominal_list;
 test_case "actual nominal PK Legacy reverse Worker and Contract" `Quick (native_application ~legacy:true)]]
