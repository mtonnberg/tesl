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
  write(Filename.concat output "internal/teslmodapp/nominal_inverse_test.go")test;
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

let lossless_input schema = schema
 |> replace "record Key { value: String }" "record Key { value: String, hidden: String }"
 |> replace "{ value <- \"storedKey\" with_codec stringCodec }" "{ value <- \"storedKey\" with_codec stringCodec, hidden <- default \"decoded\" }"
 |> replace "Key { value: value }" "Key { value: value, hidden: \"original\" }"
let with_fields ~after schema = schema
 |> replace "id: Key, title:" (if after then "id: Key, alias: Key, title:" else "id: Key, spare: Key, retired: String, title:")
 |> replace "id: Key { value: value, hidden: \"original\" }, title:"
    (if after then "id: Key { value: value, hidden: \"original\" }, alias: Key { value: \"spare\", hidden: \"original\" }, title:" else "id: Key { value: value, hidden: \"original\" }, spare: Key { value: \"spare\", hidden: \"original\" }, retired: \"keep\", title:")
 |> replace "id: makeKey value, title:"
    (if after then "id: makeKey value, alias: makeKey \"spare\", title:" else "id: makeKey value, spare: makeKey \"spare\", retired: \"keep\", title:")
let body ~writeback = source
 |> replace "import Tesl.Migration" "import Tesl.Prelude exposing [String]\nimport Tesl.Migration"
 |> replace "Entity(..), Same(..)" "Entity(..), Rule(..), Same(..)"
 |> replace "Migrate convert []" (if writeback then "Migrate convert [Rename spare alias, WriteBack retired count backward]" else "Migrate convert [Rename spare alias, Legacy retired \"fallback\"]")
 |> replace "id: old.id, title:" "id: old.id, alias: old.spare, title:"
 |> fun text -> if writeback then text ^ "\nfn backward(row: Schema.Notes.VCurrent.Note) -> String = row.title\n" else text
let reverse_test = {|package teslmodapp
import (
 "reflect"
 "testing"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 migration "tesl.generated/teslmodapp/internal/teslmodschemanotesmigratev2"
)
func TestBothNominalDirectionsPreserveInput(t *testing.T) {
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err!=nil{t.Fatal(err)}
 for _, value:=range []string{"", "null", "å/日本語"} {
  before:=old.MakeNote(value)
  converted:=migration.TeslCompiledRowCallback(before).RowValue
  current:=fresh.MakeNote(value)
  if !reflect.DeepEqual(converted.Id,current.Id)||!reflect.DeepEqual(converted.Alias,current.Alias){t.Fatal("forward exact projections changed",converted,current)}
  previous,err:=MainDatabaseCompiledRowWriteBack0.Reverse(current)
  if err!=nil{t.Fatal(err)}
  if !reflect.DeepEqual(previous.Id,before.Id)||!reflect.DeepEqual(previous.Spare,before.Spare){t.Fatal("inverse changed original codec inputs",previous,before)}
  if !reflect.DeepEqual(old.EncodeKeyJSON(previous.Id),fresh.EncodeKeyJSON(current.Id))||!reflect.DeepEqual(old.EncodeKeyJSON(previous.Spare),fresh.EncodeKeyJSON(current.Alias)){t.Fatal("nominal reverse changed SQL JSONB value")}
  if previous.Retired!="fallback"{t.Fatal("legacy callback changed",previous)}
  if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal("original storage codec rejected reverse",err)}
 }
}
|}
let reverse_native ?(nested=false) ~adt ~writeback () =
 let schema=if adt then adt_schema else fun name extra->lossless_input(schema name extra) in
 let enrich text=if not nested then text else text
  |> replace "[Note, Key, makeNote]" "[Note, Key, Inner, makeNote]"
  |> replace "[String, Int]" "[String, Int, List]"
  |> replace "[stringCodec]" "[stringCodec, listCodec]"
  |> replace "record Key { value: String, hidden: String }" "record Inner { text: String }\ncodec Inner {\n toJson { text -> \"text\" with_codec stringCodec }\n fromJson [ { text <- \"text\" with_codec stringCodec } ]\n}\nrecord Key { value: List Inner, hidden: String }"
  |> replace "storedKey\" with_codec stringCodec" "storedKey\" with_codec listCodec"
  |> replace "value: value, hidden:" "value: [Inner { text: value }], hidden:"
  |> replace "value: \"spare\", hidden:" "value: [Inner { text: \"spare\" }], hidden:" in
 let before=enrich(with_fields ~after:false(schema "V1" false))
 and after=enrich(with_fields ~after:true(schema "VCurrent" true)) in
 project ~before ~after(fun root save path ->
  let body=body ~writeback in
  let body=if not nested then body else replace "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]"
    "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key, Same Schema.Notes.V1.Inner Schema.Notes.VCurrent.Inner]" body in
  if nested then refuses "MIG024" path (replace ", Same Schema.Notes.V1.Inner Schema.Notes.VCurrent.Inner" "" body);
  accepts path body;seal_edge ~body root path;
  let entry=save "app.tesl" app in
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry app with
   | Compile.GoSuccess values->values | Compile.GoFailure ds->fail(describe ds) in
  let text=String.concat "\n" (List.map(fun(a:Emit_go.artifact)->a.contents)artifacts) in
  check bool "compiler-private inverse emitted in original owner" true (Compile.string_contains text "func TeslCompiledNominalInverse");
  let test=if writeback then replace "previous.Retired!=\"fallback\"" "previous.Retired!=current.Title" reverse_test else reverse_test in
  let test=if not nested then test else replace "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}"
    "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}\n  current.Id.Value=nil; current.Alias.Value=[]fresh.Inner{}\n  restored,err:=MainDatabaseCompiledRowWriteBack0.Reverse(current)\n  if err!=nil||restored.Id.Value!=nil||restored.Spare.Value==nil||len(restored.Spare.Value)!=0{t.Fatal(\"inverse collapsed nil and empty lists\",restored,err)}" test in
  native ~test root artifacts)
let rename_refusals () =
 let before=with_fields ~after:false(lossless_input(schema "V1" false))
 and after=with_fields ~after:true(lossless_input(schema "VCurrent" true)) in
 project ~before ~after(fun _ _ path ->
  let source=body ~writeback:false in
  accepts path source;
  refuses "MIG017" path(replace "alias: old.spare" "alias: old.id" source);
  refuses "T001" path(replace " Row (" " let intermediate: Schema.Notes.VCurrent.Key = old.spare\n Row (" source);
  refuses "MIG018" path(replace " Row (" " let old = oldNote()\n Row (" source))
let () = run "nominal Copy Rename reverse composition" ["checked",[
 test_case "lossy record inputs survive Legacy inverse and Rename" `Quick(reverse_native ~adt:false ~writeback:false);
 test_case "nullary and payload ADT survive Legacy inverse" `Quick(reverse_native ~adt:true ~writeback:false);
 test_case "lossy record inputs survive WriteBack inverse" `Quick(reverse_native ~adt:false ~writeback:true);
 test_case "nested Same inverse preserves nil versus empty lists" `Quick(reverse_native ~nested:true ~adt:false ~writeback:false);
 test_case "nominal Rename preserves exact source-site boundary" `Quick rename_refusals]]
