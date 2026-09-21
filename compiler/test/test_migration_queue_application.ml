open Alcotest
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let read p = In_channel.with_open_bin p In_channel.input_all
let rec remove p = if Sys.is_directory p then (Array.iter (fun n -> remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let describe ds = String.concat "\n" (List.map(fun(d:Compile.diagnostic)->d.code^": "^d.message)ds)
let schema extra = {|module Schema.Todo.VCurrent exposing [Notify, Notifications, Note, makeNote]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
record Notify { text: String }
codec Notify { toJson { text -> "text" with_codec stringCodec } fromJson [ { text <- "text" with_codec stringCodec } ] }
queueSchema Notifications { jobs: [Notify] }
entity Note table "notes" primaryKey id { id: String, title: String|} ^ extra ^ " }\nfn makeNote() -> Note = Note { id: \"rollback\", title: \"atomic\"" ^ (if extra="" then "" else ", extra: 0") ^ " }\n"
let app = {|module TodoApp exposing []
import Schema.Todo.VCurrent exposing [Note, makeNote, Notify]
import Tesl.DB exposing [dbWrite]
import Tesl.Prelude exposing [Unit, String]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.Queue exposing [Queue, FromQueue, queueRead, queueWrite, QueueRetryStrategy, Fixed]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
database D = Database { schema: Schema.Todo.VCurrent, migrations: Schema.Todo.Migrate,
 backend: Postgres (PostgresConfig { namespace: "todo", dbName: env "Q_DB", user: env "Q_USER", password: "",
 connection: TcpConnection { host: env "Q_HOST", port: envInt "Q_PORT" 5432 },
 migrations: MigrationConfig { topology: Worker, controlOwner: env "Q_OWNER", requestRole: env "Q_REQUEST", workerRole: env "Q_WORKER", ddlConnection: env "Q_DDL" } }) }
queue Tasks requires [queueRead, dbWrite Note] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,
 jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing], retry: QueueRetryStrategy { maxAttempts: 2, backoff: Fixed, initialDelay: 60 } }
worker handle(job: Schema.Todo.VCurrent.Notify ::: FromQueue (Id == jobId) job) requires [queueRead, dbWrite Note] =
 let _ = addNote()
 job
fn payload(text: String) -> Schema.Todo.VCurrent.Notify = Schema.Todo.VCurrent.Notify { text: text }
fn addNote() -> String requires [dbWrite Note] =
 let rows = [makeNote()]
 let _ = insertMany rows in Note
 "created"
handler get healthy() -> String = "ok"
handler post send() -> String requires [queueWrite] =
 enqueue Notify { text: "http" }
 "queued"
api Routes { get "/" -> String, post "/send" -> String }
server Web for Routes { healthy, send }
main() -> App requires [queueRead, queueWrite, dbWrite Note, envRead] = App { database: D, queues: [Tasks], api: Web, port: envInt "Q_HTTP_PORT" 8080 }
|}
let integration () =
 let root=Filename.temp_dir "tesl-queue-app-source-" "" and out=Filename.temp_dir "tesl-queue-app-native-" "" in
 Fun.protect ~finally:(fun()->if Sys.file_exists root then remove root;remove out)(fun()->
 let repo=Sys.getenv "TESL_REPO_ROOT" in
 write(Filename.concat root "tesl.toml") "";
 let current=Filename.concat root "schema/todo/v-current.tesl" and entry=Filename.concat root "todo-app.tesl" in
 write current (schema "");write entry app;
 let emit version =
  let diagnostics=(Compile.agent_context_result_source entry app).diagnostics |> List.filter(fun(d:Compile.diagnostic)->d.severity="error") in
  if diagnostics<>[] then fail(describe diagnostics);
  let files=match Compile.compile_go_source ~path:entry entry app with Compile.GoSuccess x->x|Compile.GoFailure ds->fail(describe ds) in
  let target=Filename.concat out version in
  List.iter(fun(a:Emit_go.artifact)->write(Filename.concat target a.path)a.contents)files;
  write(Filename.concat target "internal/teslmodtodoapp/queue_application_test.go") (read(Filename.concat repo "compiler/test/fixtures/queue-application/application_test.go"));
  let log=Filename.concat target "build.log" in
  let command=Printf.sprintf "cd %s && go build -race -o app ./cmd/app && go test -race -c -o application.test ./internal/teslmodtodoapp" (Filename.quote target) in
  if Sys.command(command^" > "^Filename.quote log^" 2>&1")<>0 then fail(read log);
  target in
 let v1=emit "v1" in
 (match Migration_source.freeze_closure ~project_root:root ~family:"Schema.Todo" ~version:1 with Error e->fail e|Ok copies->List.iter(fun(c:Migration_source.frozen_copy)->write c.target_path c.contents)copies);
 write current (schema ", extra: Int");
 let abi=Result.get_ok(Migration_abi.current()) in
 let load path=match Migration_inventory.load_with_compatibility ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi)) ~compiler_abi:(Migration_abi.id abi) ~root_file:path with Ok x->x|Error e->fail e.message in
 let seal path=match Migration_seal.create ~project_root:root (load path) with Ok x->x|Error e->fail e.message in
 let header=match Migration_header.create ~previous:(seal(Filename.concat root "schema/todo/v1.tesl")) ~current:(seal current) with Ok x->x|Error es->fail(String.concat "\n" (List.map(fun(e:Migration_sparse.error)->e.message)es)) in
 write(Filename.concat root "migrations/todo/v2.tesl") (Migration_header.encode header ^ {|module Schema.Todo.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Todo.V1
import Schema.Todo.VCurrent
migration = Migration { from: Schema.Todo.V1, to: Schema.Todo.VCurrent, same: [], entities: { Note: Additive [Default extra 0] } }
|});
 let v2=emit "v2" in
 check string "application handlers unchanged across migration" app (read entry);
 remove root;
 let log=Filename.concat out "run.log" in
 let command=Printf.sprintf "cd %s && QUEUE_APP_V1=%s QUEUE_APP_V2=%s timeout 180s ./application.test -test.timeout=170s -test.run '^TestQueueApplication$' -test.v" (Filename.quote v1)(Filename.quote v1)(Filename.quote v2) in
 if Sys.command(command^" > "^Filename.quote log^" 2>&1")<>0 then fail(read log))
let ()=run "ordinary queue migration application" ["PostgreSQL",[test_case "public V1/V2 Worker deployment" `Quick integration]]
