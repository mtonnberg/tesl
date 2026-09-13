open Alcotest
module S=Migration_sparse
let replace a b=Str.global_replace(Str.regexp_string a)b
let rec mkdir p=if not(Sys.file_exists p)then(mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s=mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let rec remove p=if(Unix.lstat p).Unix.st_kind=Unix.S_DIR then(Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p)else Sys.remove p
let read=Source_input.read
let describe ds=String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.code ^ ": " ^ d.message)ds)
let accepts path s=let ds=(Compile.agent_context_result_source path s).diagnostics |> List.filter(fun(d:Compile.diagnostic)->d.severity="error")in if ds<>[]then fail(describe ds)
let get=function Ok x->x|Error es->fail(String.concat "\n"(List.map(fun(e:S.error)->e.message)es))
let schema owner fields values=Printf.sprintf {|module %s exposing [Note, ValidTitle, tryTitle, newNote]
import Tesl.Prelude exposing [String, Int]
import Tesl.String exposing [String.length]
import Tesl.Maybe exposing [Maybe(..)]
fact ValidTitle(title: String)
establish tryTitle(value: String) -> Maybe (title: String ::: ValidTitle title) =
 if String.length value > 0 then
  Something (value ::: ValidTitle value)
 else
  Nothing
entity Note table "notes" primaryKey id {
 id: String
 title: String ::: ValidTitle title
 %s
}
fn newNote(id: String) -> Maybe Note =
 case tryTitle "same" of
  Nothing -> Nothing
  Something title -> Something (Note { id: id, title: title, %s })
|} owner fields values
let old=schema "Schema.Notes.V1" "author: String" "author: \"writer\""
let fresh=schema "Schema.Notes.VCurrent" "owner: String, count: Int" "owner: \"writer\", count: 7"
let source={|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: [Same Schema.Notes.V1.ValidTitle Schema.Notes.VCurrent.ValidTitle]
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Rename author owner] }
}
fn oldNote() -> Maybe Schema.Notes.V1.Note = Schema.Notes.V1.newNote "fixture"
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 if old.id == "reject" then
  Reject "delete must not evaluate this row callback"
 else
  Row (Schema.Notes.VCurrent.Note { id: old.id, title: old.title, owner: old.author, count: 7 })
|}
let app={|module App exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Telemetry exposing [telemetry, TelemetryConfig]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, MigrationTopology(..)]
import Schema.Notes.VCurrent exposing [Note, newNote]
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  poolSize: 1
  dbName: env "ROW_DATABASE"
  user: env "ROW_LOGIN"
  password: ""
  migrations: MigrationConfig {
   topology: Worker
   controlOwner: env "ROW_OWNER"
   requestRole: env "ROW_REQUEST"
   workerRole: env "ROW_WORKER"
   ddlConnection: env "ROW_DDL"
  }
  connection: TcpConnection { host: env "ROW_HOST", port: envInt "ROW_DB_PORT" 5432 }
 })
}
api NotesApi {
 get "/health" -> String
 post "/one" -> String
 post "/two" -> String
 post "/reject" -> String
 delete "/one" -> String
 delete "/reject" -> String
 post "/delete-count" -> Int
 post "/delete-effects" -> Int
 post "/delete-rollback" -> String
}
handler get health() -> String = "ready"
fn add(id: String) -> String requires [dbWrite Note] =
 case newNote id of
  Nothing -> fail 400 "title construction failed"
  Something row ->
   let rows = [row]
   let _ = insertMany rows in Note
   "created"
handler post addOne() -> String requires [dbWrite Note] = add "one"
handler post addTwo() -> String requires [dbWrite Note] = add "two"
handler post addReject() -> String requires [dbWrite Note] = add "reject"
handler delete removeOne() -> String requires [dbWrite Note] =
 delete note from Note where note.id == "one"
 "deleted"
handler delete removeReject() -> String requires [dbWrite Note] =
 delete note from Note where note.id == "reject"
 "deleted"
handler post removeCount() -> Int requires [dbWrite Note] =
 deleteAndReturnResult note from Note where note.title == "same"
fn marked(value: String) -> String =
 telemetry "delete-operand" { value = value }
 value
handler post removeEffects() -> Int requires [dbWrite Note] =
 deleteAndReturnResult note from Note where note.title == (marked "same")
handler post removeRollback() -> String requires [dbWrite Note] =
 transaction {
  delete note from Note where note.id == "one"
  fail 409 "delete rollback"
 }
server NotesServer for NotesApi { health, addOne, addTwo, addReject, removeOne, removeReject, removeCount, removeEffects, removeRollback }
main() -> App requires [dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093, telemetry: TelemetryConfig { service: "row-delete", endpoint: "in-memory", console: True } }
|}
let inventory file=let abi=Result.get_ok(Migration_abi.current())in
 match Migration_inventory.load_with_compatibility ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi)) ~compiler_abi:(Migration_abi.id abi) ~root_file:file with Ok x->x|Error e->fail e.message
let seal root file=match Migration_seal.create ~project_root:root(inventory file)with Ok x->x|Error e->fail e.message
let project ?(before=old) ?(after=fresh) ?(migration=source) f=
 let root=Filename.temp_dir "tesl-row-delete-source-" ""in
 Fun.protect ~finally:(fun()->remove root)(fun()->
  let save relative s=let p=Filename.concat root relative in write p s;p in
  ignore(save "tesl.toml" "");let previous=save "schema/notes/v1.tesl" before in let current=save "schema/notes/v-current.tesl" after in
  let header=get(Migration_header.create ~previous:(seal root previous) ~current:(seal root current))in
  let path=save "migrations/notes/v2.tesl" (Migration_header.encode header ^ migration)in
  let file=save "app.tesl" app in accepts file app;f root save path file)
let emit file text=Compile.compile_row_source_artifacts ~storage:true ~physical:true file text
let artifacts file text=match emit file text with GoSuccess a->a|GoFailure ds->fail(describe ds)
let rendered a=String.concat "\n"(List.map(fun(a:Emit_go.artifact)->a.contents)a)
let routes ()=project(fun _ _ _ file->
 let output=rendered(artifacts file app)in
 List.iter(fun needle->check bool needle true(Compile.string_contains output needle))["teslrt.DbRowDelete(";"teslrt.DbRowDeleteCount(";"teslrt.PgRowSQL(";"delete-operand"];
 let renamed=replace "note.title == \"same\"" "note.owner == \"writer\"" app in
 accepts file renamed;ignore(artifacts file renamed))
let refused file text=
 accepts file text;
 match emit file text with
 | GoSuccess _->fail "unchecked delete predicate emitted"
 | GoFailure ds->check bool (describe ds) true(List.exists(fun(d:Compile.diagnostic)->Compile.string_contains d.message "unchanged Copy or Rename")ds)
let computed_refuses ()=project(fun _ _ _ file->refused file(replace "note.title == \"same\"" "note.count == 7" app))
let retyped_refuses ()=
 let before=replace "author: String" "author: String, rank: Int" old |> replace "author: \"writer\"" "author: \"writer\", rank: 3" in
 let after=replace "owner: String, count: Int" "owner: String, count: Int, rank: String @column(\"rank__v2\")" fresh |> replace "owner: \"writer\", count: 7" "owner: \"writer\", count: 7, rank: \"three\"" in
 let migration=source |> replace "[Rename author owner]" "[Rename author owner, Retype rank, WriteBack rank rank previousRank]"
  |> replace "count: 7 })" "count: 7, rank: \"three\" })"
  |> fun s->s ^ "\nfn previousRank(current: Schema.Notes.VCurrent.Note) -> Int = 3\n" in
 let migration=replace "import Tesl.Maybe" "import Tesl.Prelude exposing [Int]\nimport Tesl.Maybe" migration in
 project ~before ~after ~migration(fun _ _ _ file->refused file(replace "note.title == \"same\"" "note.rank == \"three\"" app))
let install_contract root path=
 let abi=Result.get_ok(Migration_abi.current())in let text=read path in
 let ast=match Parser.parse_module path text with Ok x->x|Err e->fail e.msg in
 let declaration=match get(Migration_declaration.check ~compiler_abi:(Migration_abi.id abi) ~source:text ast)with Some d->d|None->fail "missing declaration" in
 let before,after=Migration_sparse.inventories(Migration_declaration.coverage declaration)in
 let rows=get(Migration_row_history.check ~schemas:[before;after] ~edges:[declaration])in
 let plan=get(Migration_retained_storage.plan rows)in
 let text=get(Migration_contract.source ~plan ~version:2)in
 let path=Filename.concat root "migrations/notes/v2-contract.tesl"in write path text;accepts path text
let command directory log text=
 let status=Sys.command(Printf.sprintf "cd %s && %s > %s 2>&1"(Filename.quote directory)text(Filename.quote log))in
 if status<>0 then fail(read log)
let export destination=
 let root=Filename.temp_dir "tesl-row-delete-original-" ""in
 Fun.protect ~finally:(fun()->remove root)(fun()->
 let save relative text=let path=Filename.concat root relative in write path text;path in
 ignore(save "tesl.toml" "");let file=save "app.tesl" app in
 let current=save "schema/notes/v-current.tesl"(replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old)in
 let build version=
  accepts file app;
  let output=Filename.concat destination version in
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then write(Filename.concat output a.path)a.contents)(artifacts file app);
  check bool "ordinary cmd/app emitted" true(Sys.file_exists(Filename.concat output "cmd/app/main.go"));
  command output (Filename.concat output "build.log") "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/app" in
 (* V1 is emitted and built before any V2 file, seal or Contract exists. *)
 build "v1";
 let previous=save "schema/notes/v1.tesl" old in
 write current fresh;
 let header=get(Migration_header.create ~previous:(seal root previous) ~current:(seal root current))in
 let path=save "migrations/notes/v2.tesl"(Migration_header.encode header ^ source)in
 install_contract root path;build "v2")
let native ()=
 let output=Filename.temp_dir "tesl-row-delete-programs-" ""in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_DELETE_TEST"=None then remove output)(fun()->export output;
  let repo=Option.get(Sys.getenv_opt "TESL_REPO_ROOT")in
  (* pgNewWorkerTest owns shared PostgreSQL discovery and the existing mandatory
     TESL_MIGRATION_TEST_REQUIRE_POSTGRES contract. Never invent a skip here. *)
  command(Filename.concat repo "runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_DELETE_PROGRAMS=%s timeout 210s go test -p 1 -race -tags tesl_migration_test ./teslrt -run '^TestPgRowDeleteOriginalApplications$' -count=1 -timeout=180s -v"(Filename.quote output)))
let ()=match Sys.getenv_opt "TESL_ROW_DELETE_EXPORT"with
 | Some destination->export destination
 | None->run "migration-aware delete" ["delete",[
  test_case "Copy and Rename delete/count preserve exact source owners" `Quick routes;
  test_case "computed delete predicate refuses" `Quick computed_refuses;
  test_case "retyped delete predicate refuses" `Quick retyped_refuses;
  test_case "actual unchanged V1/V2 App deletion" `Quick native]]
