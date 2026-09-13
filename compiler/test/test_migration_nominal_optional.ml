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
let optional_schema ~adt name after =
 let base=if adt then adt_schema name after else lossless_input(schema name after) in
 let optional=if adt then "makeKey \"spare\"" else "Key { value: \"spare\", hidden: \"original\" }" in
 with_fields ~after base
 |>replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
 |>replace "spare: Key," "spare: Maybe Key, other: Maybe Key,"
 |>replace "alias: Key," "alias: Maybe Key, other: Maybe Key,"
 |>replace ("spare: " ^ optional ^ ",") "spare: makeOptional value, other: Nothing,"
 |>replace ("alias: " ^ optional ^ ",") "alias: makeOptional value, other: Nothing,"
 |>fun text->text ^ "\nfn makeOptional(value: String) -> Maybe Key =\n if value == \"\" then\n  Nothing\n" ^ (if adt then " else if value == \"null\" then\n  Something Absent\n" else "") ^ " else\n  Something (" ^ optional ^ ")\n"
let optional_body ~writeback = body ~writeback |>replace "alias: old.spare," "alias: old.spare, other: old.other,"
let optional_project f = project ~before:(optional_schema ~adt:false "V1" false)
 ~after:(optional_schema ~adt:false "VCurrent" true) f
let optional_test ~adt ~writeback =
 reverse_test
 |>replace "old.EncodeKeyJSON(previous.Spare)" "old.EncodeKeyJSON(previous.Spare.SomethingValue)"
 |>replace "fresh.EncodeKeyJSON(current.Alias)" "fresh.EncodeKeyJSON(current.Alias.SomethingValue)"
 |>replace "||!reflect.DeepEqual(old.EncodeKeyJSON(previous.Spare.SomethingValue),fresh.EncodeKeyJSON(current.Alias.SomethingValue))" ""
 |>replace "if previous.Retired!=\"fallback\"" (if writeback then "if previous.Retired!=current.Title" else "if previous.Retired!=\"fallback\"")
 |>replace "if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal(\"original storage codec rejected reverse\",err)}"
 {|oldCols,oldErr:=old.TeslEncodeRowNote(before)
  newCols,newErr:=fresh.TeslEncodeRowNote(converted)
  reverseCols,reverseErr:=old.TeslEncodeRowNote(previous)
  if _,err:=MainDatabaseCompiledRowWriteBack0.Encode(current);err!=nil{t.Fatal("checked reverse storage failed",err)}
  if oldErr!=nil||newErr!=nil||reverseErr!=nil{t.Fatal("storage encoding failed",oldErr,newErr,reverseErr)}
  // Physical schema order is logical id, spare/alias, other, retired/title... .
  if !reflect.DeepEqual(oldCols[1],newCols[1])||!reflect.DeepEqual(oldCols[1],reverseCols[1]){t.Fatal("optional stored JSONB changed",oldCols,newCols,reverseCols)}
  if value=="" {
   if before.Spare.Tag!=rt.MaybeNothing||converted.Alias.Tag!=rt.MaybeNothing||previous.Spare.Tag!=rt.MaybeNothing||oldCols[1]!=nil||newCols[1]!=nil||reverseCols[1]!=nil {t.Fatal("Nothing is not SQL NULL",before,converted,previous,oldCols,newCols,reverseCols)}
  }else{
   if before.Spare.Tag!=rt.MaybeSomething||converted.Alias.Tag!=rt.MaybeSomething||previous.Spare.Tag!=rt.MaybeSomething||oldCols[1]==nil||newCols[1]==nil {t.Fatal("Something collapsed to SQL NULL",before,converted,previous)}
   if !reflect.DeepEqual(old.EncodeKeyJSON(previous.Spare.SomethingValue),fresh.EncodeKeyJSON(current.Alias.SomethingValue)){t.Fatal("optional payload old codec changed")}
  }
  if converted.Other.Tag!=rt.MaybeNothing||previous.Other.Tag!=rt.MaybeNothing{t.Fatal("wrong same-typed field selected")}
 |}
 |>fun text->if adt then text else replace "// Physical schema order" "if value!=\"\"&&(converted.Alias.SomethingValue.Hidden!=\"original\"||previous.Spare.SomethingValue.Hidden!=\"original\"){t.Fatal(\"lossy codec reconstructed optional input\")}\n  // Physical schema order" text
let native_optional ~adt ~writeback () =
 project ~before:(optional_schema ~adt "V1" false) ~after:(optional_schema ~adt "VCurrent" true)(fun root save path->
  let source=optional_body ~writeback in
  accepts path source;seal_edge ~body:source root path;
  let entry=save "app.tesl" app in
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true entry app with
   |Compile.GoSuccess a->a|Compile.GoFailure ds->fail(describe ds) in
  native ~test:(optional_test ~adt ~writeback) root artifacts)
let exact_boundary () = optional_project(fun _ _ path->
 let source=optional_body ~writeback:false in
 accepts path source;
 refuses "MIG017" path(replace "alias: old.spare" "alias: old.other" source);
 refuses "MIG018" path(replace " Row (" " let old = oldNote()\n Row (" source);
 let imported=replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude" source in
 refuses "T001" path(replace " Row (" " let intermediate: Maybe Schema.Notes.VCurrent.Key = old.spare\n Row (" imported);
 refuses "T001" path(imported ^ "\nfn standalone(old: Schema.Notes.V1.Note) -> Maybe Schema.Notes.VCurrent.Key = old.spare\n");
 refuses "MIG024" path(replace "same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "same: []" source))
let codec_refusal () = optional_project(fun _ save path->
 let source=optional_body ~writeback:false in accepts path source;
 ignore(save "schema/notes/v-current.tesl" (optional_schema ~adt:false "VCurrent" true |>replace "storedKey" "changedKey"));
 refuses "MIG024" path source)
let shadowed_wrapper () = optional_project(fun _ save path->
 let source=optional_body ~writeback:false in
 accepts path source;
 let local=source ^ "\ntype Maybe a = | Forged item: a\n" in
 refuses "T001" path local;
 ignore(save "migrations/notes/wrappers.tesl" "module Schema.Notes.Migrate.Wrappers exposing [Maybe(..)]\ntype Maybe a = | Forged item: a\n");
 refuses "T001" path(replace "import Tesl.Prelude" "import Schema.Notes.Migrate.Wrappers exposing [Maybe]\nimport Tesl.Prelude" source);
 (* A prefixed builtin import denotes the actual same wrapper. *)
 let aliased=replace "import Tesl.Prelude" "import Tesl.Maybe exposing []\nimport Tesl.Prelude" source in
 accepts path aliased)
let source_graph_guard ()=optional_project(fun root save path->
 seal_edge ~body:(optional_body ~writeback:false) root path;
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
    match Parser.parse_module path (replace "alias: old.spare" "alias: old.other" (Source_input.read path)) with
    |Ok m->Migration_form.erase m|Err e->fail e.msg)lowered in
  (match Emit_go.compile_project ~row_storage:true ~row_source:captured_source ~entry:main altered with
   |Error _->()|Ok _->fail "changed original optional projection inherited transport");
  captured_source,lowered)) in
  match Emit_go.compile_project ~row_storage:true ~row_source:source ~entry:(List.hd lowered) lowered with
  | Error _->()|Ok _->fail "escaped checked source inherited nominal lowering")
let optional_only_same () =
 let primitive_key text=text
  |>replace "id: Key," "id: Int,"
  |>replace "id: Key { value: value, hidden: \"original\" }," "id: 7," in
 project ~before:(primitive_key(optional_schema ~adt:false "V1" false))
  ~after:(primitive_key(optional_schema ~adt:false "VCurrent" true))(fun _ _ path->
  let source=optional_body ~writeback:false in accepts path source;
  refuses "MIG024" path(replace "same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]" "same: []" source))
let optional_proof () =
 let proven ~after text=text
  |>replace "[Note, Key, makeNote]" "[Note, Key, makeNote, ValidOptional]"
  |>replace "entity Note" "fact ValidOptional (value: Maybe Key)\nestablish optionalProof(value: Maybe Key) -> Fact (ValidOptional value) = ValidOptional value\nentity Note"
  |>replace (if after then "alias: Maybe Key," else "spare: Maybe Key,")
     (if after then "alias: Maybe Key ::: ValidOptional alias," else "spare: Maybe Key ::: ValidOptional spare,")
  |>replace "fn makeNote(value: String) -> Note = Note" "fn makeNote(value: String) -> Note =\n let optional = makeOptional value\n let proof = optionalProof optional\n Note"
  |>replace (if after then "alias: makeOptional value," else "spare: makeOptional value,")
     (if after then "alias: optional ::: proof," else "spare: optional ::: proof,") in
 project ~before:(proven ~after:false(optional_schema ~adt:false "V1" false))
  ~after:(proven ~after:true(optional_schema ~adt:false "VCurrent" true))(fun _ _ path->
  let source=optional_body ~writeback:false |>replace "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]"
    "[Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key, Same Schema.Notes.V1.ValidOptional Schema.Notes.VCurrent.ValidOptional]" in
  accepts path source;
  refuses "MIG024" path(replace ", Same Schema.Notes.V1.ValidOptional Schema.Notes.VCurrent.ValidOptional" "" source))

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
 let _=legacy in
 let make_schema name extra=optional_schema ~adt name extra in
 let body=optional_body ~writeback:false in
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
let native_application ?(legacy=true) ()=
 let output=Filename.temp_dir "tesl-nominal-apps-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_NOMINAL_PROGRAMS"=None then remove output)(fun()->
  List.iter(fun(kind,adt)->export_application ~legacy ~adt (Filename.concat output kind))["record",false;"adt",true];
  command (Filename.concat(Sys.getenv "TESL_REPO_ROOT")"runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_NOMINAL_LEGACY=%s TESL_ROW_NOMINAL_PROGRAMS=%s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowNominalOptionalLifecycle$' -count=1 -v" (if legacy then "1" else "0") (Filename.quote output)))

let ()=run "optional nominal migration copy" ["checked",[
 test_case "Maybe record Copy Rename retains hidden codec input and SQL NULL" `Quick(native_optional ~adt:false ~writeback:false);
 test_case "Maybe ADT Copy Rename retains payload and Nothing" `Quick(native_optional ~adt:true ~writeback:false);
 test_case "Maybe record WriteBack inverse is whole-field typed" `Quick(native_optional ~adt:false ~writeback:true);
 test_case "only the original successful field projection has authority" `Quick exact_boundary;
 test_case "changed optional codec refuses Same" `Quick codec_refusal;
 test_case "user Maybe shadows never become builtin transport" `Quick shadowed_wrapper;
 test_case "optional certificate revalidates exact graph and scoped capture" `Quick source_graph_guard;
 test_case "optional-only Same is required with primitive PK" `Quick optional_only_same;
 test_case "optional field proof needs exact predicate Same" `Quick optional_proof;
 test_case "actual optional record and ADT Worker and Contract lifecycle" `Quick (native_application ~legacy:true)]]
