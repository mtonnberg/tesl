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
let body ~writeback =
 let text=source
  |> replace "import Tesl.Migration" "import Tesl.Prelude exposing [String]\nimport Tesl.Migration"
  |> replace "Entity(..), Same(..)" "Entity(..), Rule(..), Same(..)"
  |> replace "fixtures: [oldNote]" "fixtures: []"
  |> replace "Migrate convert []" (if writeback then "Derived [Rename spare alias, Default count 7, LegacyWith retired backward]" else "Derived [Rename spare alias, Default count 7, Legacy retired \"fallback\"]") in
 let text=String.sub text 0 (Str.search_forward(Str.regexp_string "fn convert") text 0) in
 let text=replace "exposing [migration, oldNote]" "exposing [migration]" text in
 if writeback then text ^ "\nfn backward(row: Schema.Notes.VCurrent.Note) -> String = row.title\n" else text
let reverse_test = {|package teslmodapp
import (
 "reflect"
 "testing"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
)
func TestBothNominalDirectionsPreserveInput(t *testing.T) {
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err!=nil{t.Fatal(err)}
 for _, value:=range []string{"", "null", "å/日本語"} {
  before:=old.MakeNote(value)
  forward,err:=MainDatabaseCompiledRowTransform0.Run(before)
  if err!=nil{t.Fatal(err)}
  converted:=forward.RowValue
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
  check bool "compiler-private inverse emitted in original owner" true (Compile.string_contains text "func TeslCompiledNominalMapping");
  let test=if writeback then replace "previous.Retired!=\"fallback\"" "previous.Retired!=current.Title" reverse_test else reverse_test in
  let test=if not nested then test else replace "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}"
    "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}\n  current.Id.Value=nil; current.Alias.Value=[]fresh.Inner{}\n  restored,err:=MainDatabaseCompiledRowWriteBack0.Reverse(current)\n  if err!=nil||restored.Id.Value!=nil||restored.Spare.Value==nil||len(restored.Spare.Value)!=0{t.Fatal(\"inverse collapsed nil and empty lists\",restored,err)}" test in
  native ~test root artifacts)
let optional_native () =
 let optional text = text
  |> replace "import Tesl.Json" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Json"
  |> replace "spare: Key" "spare: Maybe Key"
  |> replace "alias: Key" "alias: Maybe Key"
  |> replace "spare: Maybe Key { value: \"spare\", hidden: \"original\" }" "spare: Something (Key { value: \"spare\", hidden: \"original\" })"
  |> replace "alias: Maybe Key { value: \"spare\", hidden: \"original\" }" "alias: Something (Key { value: \"spare\", hidden: \"original\" })" in
 let before=optional(with_fields ~after:false(lossless_input(schema "V1" false)))
 and after=optional(with_fields ~after:true(lossless_input(schema "VCurrent" true))) in
 project ~before ~after(fun root save path ->
  let body=body ~writeback:false in
  accepts path body;seal_edge ~body root path;
  let entry=save "app.tesl" app in
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry app with
   | Compile.GoSuccess values->values | Compile.GoFailure ds->fail(describe ds) in
  let test=reverse_test
   |>replace "old.EncodeKeyJSON(previous.Spare)" "old.EncodeKeyJSON(previous.Spare.SomethingValue)"
   |>replace "fresh.EncodeKeyJSON(current.Alias)" "fresh.EncodeKeyJSON(current.Alias.SomethingValue)"
   |>replace "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}" {|if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal("original storage codec rejected reverse",err)}
  before.Spare=rt.Maybe[old.Key]{Tag:rt.MaybeNothing}
  absent,err:=MainDatabaseCompiledRowTransform0.Run(before)
  if err!=nil||absent.RowValue.Alias.Tag!=rt.MaybeNothing{t.Fatal("Derived changed SQL NULL",absent,err)}
  back,err:=MainDatabaseCompiledRowWriteBack0.Reverse(absent.RowValue)
  if err!=nil||back.Spare.Tag!=rt.MaybeNothing{t.Fatal("inverse changed SQL NULL",back,err)}
  columns,err:=old.TeslEncodeRowNote(back)
  if err!=nil||columns[1]!=nil{t.Fatal("Nothing became JSON null",columns,err)}|} in
  native ~test root artifacts)
let direct_list_mapping () =
 let lists text=text
  |>replace "[String, Int]" "[String, Int, List]"
  |>replace "spare: Key," "spare: List Key @db(jsonb),"
  |>replace "alias: Key," "alias: List Key @db(jsonb),"
  |>replace "spare: Key { value: \"spare\", hidden: \"original\" }" "spare: [Key { value: \"spare\", hidden: \"original\" }]"
  |>replace "alias: Key { value: \"spare\", hidden: \"original\" }" "alias: [Key { value: \"spare\", hidden: \"original\" }]"
  |>replace ", retired: String" "" |>replace ", retired: \"keep\"" "" in
 let before=lists(with_fields ~after:false(lossless_input(schema "V1" false)))
 and after=lists(with_fields ~after:true(lossless_input(schema "VCurrent" true))) in
 project ~before ~after(fun root save path ->
  let body=body ~writeback:false |>replace ", Legacy retired \"fallback\"" "" in
  accepts path body;seal_edge ~body root path;
  let entry=save "app.tesl" app in
  let text=Source_input.read path in
  let ast=match Parser.parse_module path text with Ok ast->ast | Err error->fail error.msg in
  let abi=Result.get_ok(Migration_abi.current()) in
  let transform=match Migration_declaration.check ~compiler_abi:(Migration_abi.id abi) ~source:text ast with
   | Ok(Some d)->Option.get(Migration_declaration.transforms d)
   | _->fail "direct List mapping source did not check" in
  let row=List.hd(Migration_transform.rows transform) in
  check int "structural mapping judgment includes List field" 2
   (List.length(Migration_transform.nominal_mappings transform row));
  List.iter(fun storage -> match Compile.compile_row_source_artifacts ~storage entry app with
   | Compile.GoSuccess _->fail "direct List gained unsupported captured storage authority"
   | Compile.GoFailure ds->check bool "actual complete-history carrier refusal" true
      (List.exists(fun(d:Compile.diagnostic)->d.code="MIG016" &&
        Compile.string_contains d.message "applied field carrier is not a supported owned ADT")ds)) [false;true])
let checked _root path body =
 let ast=match Parser.parse_module path body with Ok ast->ast | Err error->fail error.msg in
 let abi=Result.get_ok(Migration_abi.current()) in
 match Migration_declaration.check ~compiler_abi:(Migration_abi.id abi) ~source:body ast with
 | Ok(Some d)->Option.get(Migration_declaration.transforms d)
 | Ok None->fail "missing checked mapping"
 | Error errors->fail(String.concat "\n"(List.map(fun(e:Migration_sparse.error)->e.message)errors))
let certificate_boundary () =
 let before=with_fields ~after:false(lossless_input(schema "V1" false))
 and after=with_fields ~after:true(lossless_input(schema "VCurrent" true)) in
 project ~before ~after(fun root _ path ->
  let body=body ~writeback:false in
  accepts path body; write path body;
  let t=checked root path body in
  let row=List.hd(Migration_transform.rows t) in
  check bool "Derived has no source callback" true(row.function_binding=None);
  check int "Derived has no source-site certificates" 0
   (List.length(Migration_proof_context.nominal_transports(Migration_transform.proof_context t)));
  let cs=Migration_transform.nominal_mappings t row in
  check int "exact Copy and Rename certificates" 2(List.length cs);
  let pairs=List.map(fun c->let a,b=Migration_transform.nominal_mapping_fields c in a.name,b.name)cs in
  check (list(pair string string)) "field-specific pairs" ["id","id";"spare","alias"] (List.sort compare pairs);
  let fabricated={row with fixtures=[]} in
  check int "copied row is not checked identity" 0(List.length(Migration_transform.nominal_mappings t fabricated));
  let again=checked root path body in
  let other=Migration_transform.nominal_mappings again(List.hd(Migration_transform.rows again)) in
  check bool "independent check does not share certificate identity" false
   (Migration_transform.same_nominal_mapping(List.hd cs)(List.hd other));
  let helper=body ^ "\nfn ordinary(old: Schema.Notes.V1.Key) -> Schema.Notes.VCurrent.Key = old\n" in
  refuses "T001" path helper;
  refuses "MIG024" path(replace "same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "same: []" body);
  write(Filename.concat root "schema/notes/v-current.tesl")(after ^ "\n");
  check bool "escaped certificate revalidates source bytes" true
   (try Migration_transform.revalidate_nominal_mapping(List.hd cs);false with Invalid_argument _->true))
let mapping_owner_and_helper () =
 let before=with_fields ~after:false(lossless_input(schema "V1" false)) ^ "\nentity Other table \"others\" primaryKey id { id: Key, label: String }\n"
 and after=with_fields ~after:true(lossless_input(schema "VCurrent" true)) ^ "\nentity Other table \"others\" primaryKey id { id: Key, caption: String, count: Int }\n" in
 project ~before ~after(fun root save path ->
  let helper=save "migrations/notes/helper.tesl" "module Schema.Notes.Migrate.Helper exposing []\nimport Tesl.Prelude exposing [String]\nfn preserve(value: String) -> String = value\n" in
  let body=body ~writeback:false
   |>replace "import Tesl.Prelude" "import Schema.Notes.Migrate.Helper exposing []\nimport Tesl.Prelude"
   |>replace "Legacy retired \"fallback\"] }" "Legacy retired \"fallback\"], Other: Derived [Rename label caption, Default count 7] }" in
  write path body;accepts path body;
  let t=checked root path body in
  let rows=Migration_transform.rows t in
  check int "two independent entities" 2(List.length rows);
  List.iter(fun row ->
   let certificates=Migration_transform.nominal_mappings t row in
   check bool "mapping certificate belongs to exact entity" true(List.for_all(fun c ->
    let a,b=Migration_transform.nominal_mapping_fields c in
    a.entity=row.mapping.previous.entity_name && b.entity=row.mapping.current.entity_name)certificates);
   List.iter(fun other -> if other!=row then
    check bool "other row certificate is never selected" false
      (List.exists(fun c->List.exists(Migration_transform.same_nominal_mapping c)
        (Migration_transform.nominal_mappings t other))certificates))rows)rows;
  let token=List.hd(Migration_transform.nominal_mappings t(List.hd rows)) in
  write helper(Source_input.read helper ^ "\n# changed helper bytes\n");
  check bool "complete helper closure revalidation" true
   (try Migration_transform.revalidate_nominal_mapping token;false with Invalid_argument _->true))
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
 let body=source |> replace "Entity(..), Same(..)" "Entity(..), Rule(..), Same(..)"
  |> replace "fixtures: [oldNote]" "fixtures: []"
  |> replace "exposing [migration, oldNote]" "exposing [migration]"
  |> replace "Migrate convert []" (if legacy then "Derived [Default count 7, Legacy retired \"fallback\"]" else "Derived [Default count 7]") in
 let body=String.sub body 0 (Str.search_forward(Str.regexp_string "fn convert")body 0) in
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

let () = run "Derived nominal mapping certificates" ["checked",[
 test_case "lossy record Derived and Legacy inverse preserve inputs" `Quick(reverse_native ~adt:false ~writeback:false);
 test_case "nullary and payload ADT Derived and Legacy inverse" `Quick(reverse_native ~adt:true ~writeback:false);
 test_case "lossy record Derived and LegacyWith inverse" `Quick(reverse_native ~adt:false ~writeback:true);
 test_case "nested Same Derived preserves nil versus empty lists" `Quick(reverse_native ~nested:true ~adt:false ~writeback:false);
 test_case "opaque exact mapping and ordinary typing boundaries" `Quick certificate_boundary;
 test_case "actual record and ADT Derived worker/Contract with inverse" `Quick(native_application ~legacy:true);
 test_case "optional record mapping preserves Something and SQL NULL" `Quick optional_native;
 test_case "entity mapping ownership and helper closure drift" `Quick mapping_owner_and_helper;
 test_case "direct List mapping is distinct from SQL carrier support" `Quick direct_list_mapping]]
