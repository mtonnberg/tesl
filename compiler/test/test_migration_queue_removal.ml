open Alcotest
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let read p = In_channel.with_open_bin p In_channel.input_all
let rec remove p = if Sys.is_directory p then (Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let replace a b = Str.global_replace(Str.regexp_string a)b
let describe ds = String.concat "\n" (List.map(fun(d:Compile.diagnostic)->d.code ^ ": " ^ d.message)ds)
let schema removed = {|module Schema.Todo.VCurrent exposing [Notify, Keep, Survivors, Note|} ^ (if removed then "" else ", Notifications") ^ {|]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Notify { text: String }
record Keep { text: String }
codec Notify { toJson { text -> "text" with_codec stringCodec } fromJson [ { text <- "text" with_codec stringCodec } ] }
codec Keep { toJson { text -> "text" with_codec stringCodec } fromJson [ { text <- "text" with_codec stringCodec } ] }
queueSchema Survivors { jobs: [Keep] }
entity Note table "notes" primaryKey id { id: String, title: String }
|} ^ (if removed then "" else "queueSchema Notifications { jobs: [Notify] }\n")
let app removed = {|module TodoApp exposing []
import Schema.Todo.VCurrent
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.Queue exposing [Queue, FromQueue, queueRead, queueWrite]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
database D = Database { schema: Schema.Todo.VCurrent, migrations: Schema.Todo.Migrate,
 backend: Postgres (PostgresConfig { namespace: "todo", dbName: env "Q_DB", user: env "Q_USER", password: "",
 connection: TcpConnection { host: env "Q_HOST", port: envInt "Q_PORT" 5432 },
 migrations: MigrationConfig { topology: Worker, controlOwner: env "Q_OWNER", requestRole: env "Q_REQUEST", workerRole: env "Q_WORKER", ddlConnection: env "Q_DDL" } }) }
queue Retained requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Survivors,
 jobs: [Job Schema.Todo.VCurrent.Keep keep Nothing] }
worker keep(job: Schema.Todo.VCurrent.Keep ::: FromQueue (Id == jobId) job) requires [queueRead] = job
fn keptPayload(text: String) -> Schema.Todo.VCurrent.Keep = Schema.Todo.VCurrent.Keep { text: text }
fn removedPayload(text: String) -> Schema.Todo.VCurrent.Notify = Schema.Todo.VCurrent.Notify { text: text }
|} ^ (if removed then "" else {|queue Removed requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,
 jobs: [Job Schema.Todo.VCurrent.Notify notify Nothing] }
worker notify(job: Schema.Todo.VCurrent.Notify ::: FromQueue (Id == jobId) job) requires [queueRead] = job
|}) ^ {|handler get healthy() -> String = "ok"
api Routes { get "/" -> String }
server Web for Routes { healthy }
main() -> App requires [queueRead, queueWrite, envRead] = App { database: D, queues: [Retained|} ^ (if removed then "" else ", Removed") ^ "], api: Web }\n"
let with_project run =
 let root=Filename.temp_dir "tesl-queue-removal-source-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_QUEUE_REMOVAL_KEEP_FAILURES"<>Some "1" && Sys.file_exists root then remove root)(fun()->
 write(Filename.concat root "tesl.toml") "";
 let current=Filename.concat root "schema/todo/v-current.tesl" and entry=Filename.concat root "todo-app.tesl" in
 write current(schema false);write entry(app false);
 run root current entry)
let freeze root = match Migration_source.freeze_closure ~project_root:root ~family:"Schema.Todo" ~version:1 with
 | Error e->fail e | Ok copies->List.iter(fun(c:Migration_source.frozen_copy)->write c.target_path c.contents)copies
let edge ?(version=2) ?(entities="{}") root current jobs =
 let abi=Result.get_ok(Migration_abi.current()) in
 let load path=match Migration_inventory.load_with_compatibility ~compiler_abi:(Migration_abi.id abi) ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi)) ~root_file:path with Ok x->x|Error e->fail e.message in
 let seal p=match Migration_seal.create ~project_root:root (load p) with Ok x->x|Error e->fail e.message in
 let header=match Migration_header.create ~previous:(seal(Filename.concat root (Printf.sprintf "schema/todo/v%d.tesl" (version-1)))) ~current:(seal current) with Ok h->h|Error es->fail((List.hd es).Migration_sparse.message) in
 let source=Migration_header.encode header ^ Printf.sprintf {|module Schema.Todo.Migrate.V%d exposing [migration]
import Tesl.Migration exposing [Migration, RemoveEmpty, Entity(..), Rule(..)]
import Schema.Todo.V%d
import Schema.Todo.VCurrent
migration = Migration { from: Schema.Todo.V%d, to: Schema.Todo.VCurrent, same: [], entities: %s, jobs: %s }
|} version (version-1) (version-1) entities jobs in
 let file=Filename.concat root (Printf.sprintf "migrations/todo/v%d.tesl" version) in write file source;file,source
let archive root version =
 let abi=Result.get_ok(Migration_abi.current()) in
 let preview=match Migration_generate.start_with_compatibility
   ~compiler_abi:(Migration_abi.id abi) ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
   ~project_root:root ~family:"Schema.Todo" ~version ~documents:[] with
  | Ok p->p | Error es->fail(String.concat "\n"(List.map(fun(e:Migration_generate.error)->e.message)es)) in
 let checked=function Ok()->()|Error es->fail(String.concat "\n"(List.map(fun(e:Migration_manifest.error)->e.message)es)) in
 checked(Migration_manifest.verify_source preview.manifest ~documents:[]);
 checked(Migration_manifest.verify_disk preview.manifest);
 List.iter(fun(e:Migration_manifest.edit)->write e.path e.after)(Migration_manifest.edits preview.manifest)
let chain_schema version =
 let source=schema(version>=3) in
 if version=1 then source else begin
 let source=source
  |> replace "import Tesl.Json" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Json"
  |> replace "title: String }" (if version>=4 then "title: String, detail: Maybe String, tag: Maybe String }" else "title: String, detail: Maybe String }")
  |> replace "Notify, Keep," "Notify, Keep, Early,"
  |> replace "jobs: [Keep]" "jobs: [Early, Keep]" in
 let source=source ^ {|record Early { text: String }
codec Early { toJson { text -> "text" with_codec stringCodec } fromJson [ { text <- "text" with_codec stringCodec } ] }
|} in
 if version<4 then source else
 (source |> replace "Keep, Early," "Keep, Early, Later," |> replace "jobs: [Early, Keep]" "jobs: [Early, Keep, Later]") ^ {|record Later { text: String }
codec Later { toJson { text -> "text" with_codec stringCodec } fromJson [ { text <- "text" with_codec stringCodec } ] }
|}
 end
let chain_app version removed =
 let source=app removed in
 let job="Job Schema.Todo.VCurrent.Keep keep Nothing" in
 let early="Job Schema.Todo.VCurrent.Early early Nothing" and later="Job Schema.Todo.VCurrent.Later later Nothing" in
 let source=if version<2 then source else (source |> replace job (job ^ ", " ^ early)) ^ {|worker early(job: Schema.Todo.VCurrent.Early ::: FromQueue (Id == jobId) job) requires [queueRead] = job
|} in
 if version<4 then source else (source |> replace early (early ^ ", " ^ later)) ^ {|worker later(job: Schema.Todo.VCurrent.Later ::: FromQueue (Id == jobId) job) requires [queueRead] = job
|}
let diagnostics path source=(Compile.agent_context_result_source path source).diagnostics |> List.filter(fun(d:Compile.diagnostic)->d.severity="error")
let source_decision () = with_project(fun root current entry->
 freeze root;write current(schema true);write entry(app true);
 let decision jobs expected = let file,source=edge root current jobs in let ds=diagnostics file source in
  if expected then (if ds<>[] then fail(describe ds)) else
  check bool (describe ds) true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028")ds) in
 decision "{}" false;
 decision "{ Survivors: RemoveEmpty }" false;
 decision "{ Notifications: RemoveEmpty, Survivors: RemoveEmpty }" false;
 decision "{ Notifications: RemoveEmpty }" true;
 let ds=diagnostics entry(app true) in if ds<>[] then fail(describe ds);
 let stale=diagnostics entry(app false) in check bool "old application binding refused" true (stale<>[]);
 write current(schema true |> replace "codec Keep { toJson { text -> \"text\" with_codec stringCodec } fromJson [ { text <- \"text\" with_codec stringCodec } ] }"
   "codec Keep { toJson { text -> \"body\" with_codec stringCodec } fromJson [ { text <- \"body\" with_codec stringCodec } ] }");
 decision "{ Notifications: RemoveEmpty }" false)
let compiled_history chain = with_project(fun root current entry ->
 let retained=Sys.getenv_opt "TESL_QUEUE_REMOVAL_OUTPUT" in
 let out=match retained with None->Filename.temp_dir "tesl-queue-removal-native-" "" | Some directory->
  let path=Filename.concat directory (if chain then "chain" else "adjacent") in mkdir path;path in
 Fun.protect ~finally:(fun()->if retained=None then remove out)(fun()->
 let repo=Sys.getenv "TESL_REPO_ROOT" in
 let emit version removed =
  let program=if chain then chain_app version removed else app removed in write entry program;
  let files=match Compile.compile_go_source ~path:entry entry program with Compile.GoSuccess files->files|Compile.GoFailure ds->fail(describe ds) in
  let target=Filename.concat out(Printf.sprintf "v%d" version) in
  List.iter(fun(a:Emit_go.artifact)->write(Filename.concat target a.path)a.contents)files;
  write(Filename.concat target "internal/teslmodtodoapp/queue_removal_test.go")(read(Filename.concat repo "compiler/test/fixtures/queue-removal/application_test.go"));
  if chain then write(Filename.concat target "internal/teslmodtodoapp/queue_removal_chain_test.go")(read(Filename.concat repo "compiler/test/fixtures/queue-removal/chain_test.go"));
  if not removed then write(Filename.concat target "internal/teslmodtodoapp/old_producer_test.go") {|package teslmodtodoapp
import("os";"testing";rt "tesl.generated/teslmodtodoapp/internal/teslrt")
func TestOldRemovalProducer(t *testing.T) {
 if os.Getenv("REMOVAL_OLD_PRODUCER")!="1" {t.Skip("child only")}
 if err:=rt.PreflightApplicationDatabases(DDatabase);err!=nil {t.Fatal(err)}
 rt.WithDatabase(DDatabase,func(){rt.Enqueue(RemovedQueue,removedPayload("old binary"))})
}
|};
  let log=Filename.concat target "build.log" in
  let command=Printf.sprintf "cd %s && go build -race -tags tesl_migration_test -o app ./cmd/app && go test -race -tags tesl_migration_test -c -o application.test ./internal/teslmodtodoapp"(Filename.quote target) in
  if Sys.command(command ^ " > " ^ Filename.quote log ^ " 2>&1")<>0 then fail(read log);
  target in
 let v1=emit 1 false in freeze root;
 let versions=if chain then begin
   write current(chain_schema 2);ignore(edge ~entities:"{ Note: Additive [] }" root current "{}");
   let v2=emit 2 false in archive root 2;
   write current(chain_schema 3);write entry(chain_app 3 true);ignore(edge ~version:3 root current "{ Notifications: RemoveEmpty }");
   let v3=emit 3 true in archive root 3;
   write current(chain_schema 4);ignore(edge ~version:4 ~entities:"{ Note: Additive [] }" root current "{}");
   [v1;v2;v3;emit 4 true]
  end else begin
   write current(schema true);ignore(edge root current "{ Notifications: RemoveEmpty }");[v1;emit 2 true]
  end in
 remove root;
 let log=Filename.concat out "postgres.log" in
 let environment=List.mapi(fun i path->Printf.sprintf "QUEUE_REMOVAL_V%d=%s" (i+1)(Filename.quote path))versions |> String.concat " " in
 let latest=List.hd(List.rev versions) in
 let filter=Option.value(Sys.getenv_opt "TESL_QUEUE_REMOVAL_TEST_FILTER")
  ~default:(if chain then "^TestQueueRemovalChain" else "^TestQueueRemoval") in
 let command=Printf.sprintf "%s timeout 600s %s -test.timeout=580s -test.run %s -test.failfast -test.v"
  environment (Filename.quote(Filename.concat latest "application.test"))
  (Filename.quote filter) in
 if Sys.command(command ^ " > " ^ Filename.quote log ^ " 2>&1")<>0 then fail(read log)))
let source_transform_prefix () = with_project(fun root current entry ->
 freeze root;
 write current(schema false |> replace "title: String" "headline: String");
 ignore(edge ~entities:"{ Note: Derived [Rename title headline] }" root current "{}");
 archive root 2;
 write current(schema true |> replace "title: String" "headline: String");write entry(app true);
 ignore(edge ~version:3 root current "{ Notifications: RemoveEmpty }");
 match Compile.compile_go_source ~path:entry entry(app true) with
 | Compile.GoSuccess _ -> fail "transforming prefix admitted by RemoveEmpty"
 | Compile.GoFailure ds -> check bool (describe ds) true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028" && Compile.string_contains d.message "additive-only prefix and suffix")ds))
let source_resurrection () = with_project(fun root current entry ->
 freeze root;
 write current(chain_schema 2);write entry(chain_app 2 false);
 ignore(edge ~entities:"{ Note: Additive [] }" root current "{}");archive root 2;
 write current(chain_schema 3);write entry(chain_app 3 true);
 ignore(edge ~version:3 root current "{ Notifications: RemoveEmpty }");archive root 3;
 let source=(chain_schema 4 |> replace "Survivors, Note]" "Survivors, Note, Notifications]") ^
  "queueSchema Notifications { jobs: [Notify] }\n" in
 write current source;let program=chain_app 4 false in write entry program;
 ignore(edge ~version:4 ~entities:"{ Note: Additive [] }" root current "{}");
 match Compile.compile_go_source ~path:entry entry program with
 | Compile.GoSuccess _ -> fail "removed queue identity was reintroduced as an additive successor"
 | Compile.GoFailure ds -> check bool (describe ds) true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028" && Compile.string_contains d.message "cannot reintroduce")ds))
let reviewed_source_scope () = with_project(fun root current entry ->
 freeze root;write current(schema true);let program=app true in write entry program;
 let file,source=edge root current "{ Notifications: RemoveEmpty }" in
 let parse path source=match Parser.parse_module path source with Ok m->m|Err e->fail e.msg in
 let abi=Result.get_ok(Migration_abi.current()) in
 let checked=match Migration_declaration.check ~compiler_abi:(Migration_abi.id abi)
   ~stored_value_compatibility:(Migration_abi.stored_value_compatibility abi) ~source (parse file source) with
  | Ok(Some d)->d | Ok None->fail "reviewed removal was not recognized" | Error es->fail(String.concat "\n"(List.map(fun(e:Migration_sparse.error)->e.message)es)) in
 check (option string) "positive reviewed decision names the previous queue" (Some "Notifications") (Migration_declaration.queue_removal checked);
 let before,after=Migration_sparse.inventories(Migration_declaration.coverage checked) in
 let names inventory=Migration_inventory.queue_contracts inventory |> List.map(fun q->Migration_queue.wire_identity inventory q.Migration_inventory.queue_name) in
 check (list string) "closed previous membership" ["Notifications";"Survivors"] (names before);
 check (list string) "closed target membership" ["Survivors"] (names after);
 let capture run=Migration_program.with_source_history ~entry:(parse entry program) ~source:program (function
  | None->fail "missing reviewed application history" | Some history->run history) in
 let lowered=ref false in
 (match capture(fun history->match Migration_program.source_lowering history with Ok _->lowered:=true | Error _->fail "positive checked invocation lost its source scope") with
  | Ok()->() | Error es->fail(String.concat "\n"(List.map(fun(e:Migration_sparse.error)->e.message)es)));
 check bool "positive source scope invoked" true !lowered;
 List.iter(fun path->let original=read path in
  Fun.protect ~finally:(fun()->write path original)(fun()->
   let invoked=ref false in
   let result=capture(fun history->
    (match Migration_program.source_lowering history with Ok _->()|Error _->fail "fixture failed before mutation");
    invoked:=true;
    write path (replace "text -> \"text\"" "text -> \"changed\"" original)) in
   check bool "mutation happened after positive source invocation" true !invoked;
   check bool ("changed source cannot escape guarded capture: " ^ path) true (Result.is_error result)))
  [Filename.concat root "schema/todo/v1.tesl";current])
let native () = compiled_history false
let native_chain () = compiled_history true
let ()=run "reviewed empty queue removal" ["source",[
 test_case "explicit whole membership only" `Quick source_decision;
 test_case "transforming prefix remains explicitly refused" `Quick source_transform_prefix;
 test_case "later additive identity resurrection refused" `Quick source_resurrection;
 test_case "reviewed invocation and exact before/after mutation guards" `Quick reviewed_source_scope];
 "compiled PostgreSQL",[
 test_case "public V1/V2 removal and lifecycle" `Slow native;
 test_case "additive V2, removal V3, additive V4" `Slow native_chain]]
