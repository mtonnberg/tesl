(** Durable stores (2026-09-02): a `queue`, `email`, `cache` or `sseChannel` declared on a
    Postgres-backed database is emitted through the `…On` constructors that bind it to that
    database (rows in `tesl_jobs` / `tesl_email_outbox` / `tesl_cache` / `tesl_pubsub_outbox`,
    shared by every instance), and every job type a durable queue carries gets a registered
    JSON codec. On a Memory-backed database the in-process constructors are kept. *)

open Alcotest

let with_source name src f =
  let dir = Filename.temp_dir "tesl-durable" "" in
  let path = Filename.concat dir (name ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let emitted_module name src =
  with_source name src (fun path ->
    match Compile.compile_go_file path with
    | Compile.GoFailure diagnostics ->
      failf "expected a clean Go emit, got:\n%s"
        (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.GoSuccess artifacts ->
      (match List.find_opt (fun (a : Emit_go.artifact) ->
         Filename.basename a.path = "module.go") artifacts with
       | Some artifact -> artifact.contents
       | None -> failf "no module.go artifact"))

let contains needle haystack =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

let program backend = Printf.sprintf {|module Durable exposing []
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Queue exposing [FromQueue, queueRead, queueWrite, pubsub, Queue, QueueRetryStrategy, Exponential]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Database exposing [Database, DatabaseBackend, Memory, Postgres, PostgresConfig, TcpConnection]
import Tesl.Cache exposing [Cache]
import Tesl.Email exposing [Email, SmtpConfig, emailCap, EmailBody(..)]
import Tesl.Maybe exposing [Maybe(..)]

record ReportJob {
  reportId: String
  pages: Int
}

record Tick {
  count: Int
}

codec Tick {
  toJson {
    count -> "count" with_codec intCodec
  }
  fromJson [
    {
      count <- "count" with_codec intCodec
    }
  ]
}

entity Report table "reports" primaryKey id {
  id: String
}

database Db = Database {
  schema: "durable"
  entities: [Report]
  backend: %s
}

worker buildReport(job: ReportJob ::: FromQueue (Id == jobId) job) requires [dbRead Note] =
  job

queue ReportQueue requires [dbRead Note] = Queue {
  database: Db
  jobs: [Job ReportJob buildReport Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 2
  }
}

cache TickCache = Cache {
  database: Db
  valueType: Tick
  defaultTtl: 60
}

email Mailer = Email {
  database: Db
  smtp: SmtpConfig {
    host: "localhost"
    port: 25
    username: "mailer"
    password: "secret"
    tls: false
  }
}

sseChannel Ticks = SseChannel {
  database: Db
  payload: Tick
}
|} backend

let postgres = {|Postgres (PostgresConfig {
    dbName: "durable"
    user: "durable"
    password: "durable"
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })|}

let test_postgres_backed_declarations_are_durable () =
  let out = emitted_module "Durable" (program postgres) in
  List.iter (fun needle ->
    if not (contains needle out) then failf "expected %s in the emitted module:\n%s" needle out)
    [ "teslrt.NewQueueOn(DbDatabase, \"ReportQueue\", 3, \"exponential\", 2)";
      "teslrt.RegisterJobCodec(ReportQueueQueue, \"ReportJob\"";
      "teslrt.NewCacheOn[Tick](DbDatabase, \"TickCache\", 60, teslCacheEncodeTickCache, teslCacheDecodeTickCache)";
      "teslrt.NewOutboxOn(DbDatabase, teslrt.SmtpSettings{";
      "teslrt.NewSseChannelOn(DbDatabase, \"Ticks\")" ];
  List.iter (fun needle ->
    if contains needle out then failf "did not expect %s in a Postgres-backed module:\n%s" needle out)
    [ "teslrt.NewQueue("; "teslrt.NewCache["; "teslrt.NewOutbox("; "teslrt.NewSseChannel(" ]

let test_memory_backed_declarations_stay_in_process () =
  let out = emitted_module "Durable" (program "Memory") in
  List.iter (fun needle ->
    if not (contains needle out) then failf "expected %s in the emitted module:\n%s" needle out)
    [ "teslrt.NewQueue(\"ReportQueue\", 3)"; "teslrt.NewCache[Tick](60)"; "teslrt.NewOutbox(";
      "teslrt.NewSseChannel(\"Ticks\")" ];
  if contains "RegisterJobCodec" out then
    failf "a Memory-backed queue needs no job codec:\n%s" out

let () =
  run "durable-stores"
    [
      ( "emission",
        [ test_case "Postgres-backed declarations bind to the database" `Quick
            test_postgres_backed_declarations_are_durable;
          test_case "Memory-backed declarations stay in process" `Quick
            test_memory_backed_declarations_stay_in_process ] );
    ]
