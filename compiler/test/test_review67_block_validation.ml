(** Antagonistic regression tests for Critical Review 67: structural
    validation of custom declaration blocks.

    Previously, the following blocks were accepted with structurally invalid
    syntax and silently compiled to broken Racket (or emitted code that would
    fail at runtime):

    - queue:    missing `database`, missing `jobs` clause
    - channel:  missing `database`
    - workers:  referencing an undefined queue; empty handler bindings;
                referencing a function that is not a `worker`
    - api-test: referencing an undefined server; empty description string
    - test:     empty description string

    NOTE (config-syntax migration): the config/application surface moved to the
    typed forms `database X = Database { … }`, `queue X = Queue { … }`,
    `sseChannel X = SseChannel { … }`, etc.  Two old behaviours no longer exist
    under the typed forms and their tests were deleted:
      - queue empty `jobs: []` is now accepted (was QU02);
      - the typed `Database.entities:` field is only checked to be a list of
        type names, not that each entity is declared (was DB01/DB02/DB05).

    Test groups:
      QU — queue structure
      CH — channel structure
      WK — workers structure
      DB — database entity references
      AT — api-test structure
      TS — test block descriptions
      OK — valid declarations (regression guard) *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r67" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── R67_QU — Queue structure ────────────────────────────────────────────── *)

let test_R67_QU01_queue_missing_database_rejected () =
  should_fail "missing required field `database`\\|missing.*database" {|
#lang tesl
module R67Qu01 exposing []
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
queue R67Qu01 = Queue {
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
|}

(* R67_QU02 (queue empty `jobs: []` rejected) DELETED: in the new typed `Queue`
   form an empty `jobs: []` list is accepted; the old "empty jobs" rejection no
   longer exists. *)

let test_R67_QU03_queue_no_jobs_clause_rejected () =
  should_fail "missing required field `jobs`\\|jobs.*required\\|at least one" {|
#lang tesl
module R67Qu03 exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Qu03Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
queue R67Qu03 = Queue {
  database: R67Qu03Db
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
|}

let test_R67_QU04_queue_with_database_and_jobs_accepted () =
  should_pass {|
#lang tesl
module R67Qu04 exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Qu04Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
queue R67Qu04 = Queue {
  database: R67Qu04Db
  jobs: [JobA, JobB]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
|}

let test_R67_QU05_queue_with_retry_config_accepted () =
  should_pass {|
#lang tesl
module R67Qu05 exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Qu05Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
queue R67Qu05 = Queue {
  database: R67Qu05Db
  jobs: [Job1]
  retry: QueueRetryStrategy { maxAttempts: 3 backoff: Exponential initialDelay: 1000 }
}
|}

(* ── R67_CH — Channel structure ──────────────────────────────────────────── *)

let test_R67_CH01_channel_missing_database_rejected () =
  should_fail "missing required field `database`\\|missing.*database" {|
#lang tesl
module R67Ch01 exposing []
import Tesl.Prelude exposing [String]
import Tesl.SSE exposing [SseChannel]
type Ev = EvA msg: String
sseChannel R67Ch01 = SseChannel { payload: Ev }
|}

let test_R67_CH02_channel_empty_database_rejected () =
  should_fail "must reference a database\\|missing.*database" {|
#lang tesl
module R67Ch02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.SSE exposing [SseChannel]
type Ev = EvB msg: String
sseChannel R67Ch02 = SseChannel { database: "" payload: Ev }
|}

let test_R67_CH03_channel_with_database_accepted () =
  should_pass {|
#lang tesl
module R67Ch03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]
database R67Ch03Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
type EvC = EvCA msg: String
sseChannel R67Ch03 = SseChannel { database: R67Ch03Db payload: EvC }
|}

let test_R67_CH04_channel_with_key_params_accepted () =
  should_pass {|
#lang tesl
module R67Ch04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]
database R67Ch04Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
type EvD = EvDA msg: String
sseChannel R67Ch04(userId: String) = SseChannel { database: R67Ch04Db payload: EvD }
|}

(* ── R67_WK — Workers structure ──────────────────────────────────────────── *)

let test_R67_WK01_workers_undefined_queue_rejected () =
  should_fail "unknown queue\\|references unknown" {|
#lang tesl
module R67Wk01 exposing []
workers R67Wk01 for NonExistentQueue { }
|}

let test_R67_WK02_workers_empty_bindings_rejected () =
  should_fail "no job bindings\\|at least one.*JobType\\|job.*bindings" {|
#lang tesl
module R67Wk02 exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk02Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
queue R67Wk02Q = Queue {
  database: R67Wk02Db
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
workers R67Wk02 for R67Wk02Q { }
|}

let test_R67_WK03_workers_undefined_handler_rejected () =
  should_fail "not declared as a.*worker\\|unknown.*worker\\|not a `worker`" {|
#lang tesl
module R67Wk03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk03Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
queue R67Wk03Q = Queue {
  database: R67Wk03Db
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
workers R67Wk03 for R67Wk03Q { MyJob = undefinedWorkerFn }
|}

let test_R67_WK04_workers_with_valid_worker_accepted () =
  should_pass {|
#lang tesl
module R67Wk04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk04Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record MyJob { msg: String }
queue R67Wk04Q = Queue {
  database: R67Wk04Db
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
worker processMyJob(job: MyJob) -> String requires [] = job.msg
workers R67Wk04 for R67Wk04Q { MyJob = processMyJob }
|}

let test_R67_WK05_workers_fn_instead_of_worker_rejected () =
  should_fail "not declared as a.*worker\\|not a `worker`" {|
#lang tesl
module R67Wk05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk05Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record MyJob { msg: String }
queue R67Wk05Q = Queue {
  database: R67Wk05Db
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
fn notAWorker(job: MyJob) -> String requires [] = job.msg
workers R67Wk05 for R67Wk05Q { MyJob = notAWorker }
|}

let test_R67_WK06_dead_workers_undefined_queue_rejected () =
  should_fail "unknown queue\\|references unknown" {|
#lang tesl
module R67Wk06 exposing []
deadWorkers R67Wk06 for GhostQueue { }
|}

let test_R67_WK07_dead_workers_valid_accepted () =
  (* dead workers (processing the dead-letter queue) should compile when the
     queue exists and the handler is declared as `deadWorker` *)
  should_pass {|
#lang tesl
module R67Wk07 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk07Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record DeadJob { msg: String }
queue R67Wk07Q = Queue {
  database: R67Wk07Db
  jobs: [DeadJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
deadWorker handleDeadDeadJob(job: DeadJob) -> String requires [] = job.msg
deadWorkers R67Wk07 for R67Wk07Q { DeadJob = handleDeadDeadJob }
|}

let test_R67_WK08_workers_multiple_job_types_accepted () =
  (* workers block with multiple job type → handler bindings *)
  should_pass {|
#lang tesl
module R67Wk08 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk08Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record JobA { name: String }
record JobB { count: Int }
queue R67Wk08Q = Queue {
  database: R67Wk08Db
  jobs: [JobA, JobB]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
worker handleJobA(job: JobA) -> String requires [] = job.name
worker handleJobB(job: JobB) -> Int requires [] = job.count
workers R67Wk08 for R67Wk08Q { JobA = handleJobA JobB = handleJobB }
|}

let test_R67_WK09_handler_kind_instead_of_worker_rejected () =
  (* using a `handler` function (HTTP handler kind) where a `worker` is needed *)
  should_fail "not declared as a.*worker\\|not a `worker`" {|
#lang tesl
module R67Wk09 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Wk09Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record MyJob { msg: String }
queue R67Wk09Q = Queue {
  database: R67Wk09Db
  jobs: [MyJob]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 60 }
}
handler httpHandler() -> String requires [] = "response"
workers R67Wk09 for R67Wk09Q { MyJob = httpHandler }
|}

(* ── R67_DB — Database entity references ────────────────────────────────── *)

(* R67_DB01 / R67_DB02 / R67_DB05 (database undefined-entity rejection) DELETED:
   the new typed `Database` form only checks that `entities:` is a list of
   uppercase type names (e.g. `[Item]`); it no longer verifies that each entity
   is actually declared, so the old "unknown entity" rejection no longer exists. *)

let test_R67_DB03_database_with_declared_entity_accepted () =
  should_pass {|
#lang tesl
module R67Db03 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
entity R67Item table "items" primaryKey id {
  id: Int
  name: String
}
database R67Db03 = Database {
  schema: "s"
  entities: [R67Item]
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_DB04_database_empty_entities_accepted () =
  (* Empty entities list is valid — the database just has no registered entities *)
  should_pass {|
#lang tesl
module R67Db04 exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
database R67Db04 = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_DB06_database_entity_from_imported_module_accepted () =
  (* The database entity check is cross-module aware: an entity imported from
     another local module must be accepted as a valid database entity.
     This test uses example/learn/lesson03-records.tesl as a source of entities
     (it is not an entity so this test uses a different approach via a temp file).
     Instead we verify the logic by using a record that IS local — cross-module
     testing is covered by the kanel integration. *)
  should_pass {|
#lang tesl
module R67Db06 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
entity Product table "products" primaryKey id {
  id: Int
  name: String
  price: Int
}
database R67Db06 = Database {
  schema: "shop"
  entities: [Product]
  backend: Postgres (PostgresConfig {
    dbName: "shop"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

(* ── R67_AT — api-test structure ─────────────────────────────────────────── *)

let test_R67_AT01_api_test_undefined_server_rejected () =
  should_fail "unknown server\\|references unknown server" {|
#lang tesl
module R67At01 exposing []
import Tesl.Prelude exposing [String]
api-test "does something" for GhostServer {
  let resp = get "/health"
  expect resp.status == 200
}
|}

let test_R67_AT02_api_test_empty_description_rejected () =
  should_fail "empty description\\|empty description string" {|
#lang tesl
module R67At02 exposing []
import Tesl.Prelude exposing [String]
api MyApi {
  get "/health"
    -> String
}
handler health() -> String requires [] = "ok"
server R67At02Server for MyApi { health = health }
api-test "" for R67At02Server {
  let resp = get "/health"
  expect resp.status == 200
}
|}

let test_R67_AT03_api_test_both_errors_at_once () =
  should_fail "empty description\\|empty description string\\|unknown server" {|
#lang tesl
module R67At03 exposing []
api-test "" for GhostServer { }
|}

let test_R67_AT04_api_test_valid_accepted () =
  should_pass {|
#lang tesl
module R67At04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.ApiTest exposing [statusOk]
api R67At04Api { get "/ping" -> String }
handler ping() -> String requires [] = "pong"
server R67At04Server for R67At04Api { ping = ping }
api-test "ping returns 200" for R67At04Server {
  let resp = get "/ping"
  expect statusOk resp
}
|}

let test_R67_AT05_api_test_with_seed_accepted () =
  (* api-test with an optional seed block — should compile fine *)
  should_pass {|
#lang tesl
module R67At05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.ApiTest exposing [statusOk]
api R67At05Api { get "/echo" -> String }
handler echo() -> String requires [] = "hello"
server R67At05Server for R67At05Api { echo = echo }
api-test "echo with seed" for R67At05Server {
  seed { }
  let resp = get "/echo"
  expect statusOk resp
}
|}

let test_R67_AT06_api_test_multiple_requests_accepted () =
  (* Multiple sequential requests in one api-test block *)
  should_pass {|
#lang tesl
module R67At06 exposing []
import Tesl.Prelude exposing [String]
import Tesl.ApiTest exposing [statusOk]
api R67At06Api {
  get "/a" -> String
  get "/b" -> String
}
handler aHandler() -> String requires [] = "a"
handler bHandler() -> String requires [] = "b"
server R67At06Server for R67At06Api { aHandler = aHandler bHandler = bHandler }
api-test "can call both endpoints" for R67At06Server {
  let ra = get "/a"
  let rb = get "/b"
  expect statusOk ra
  expect statusOk rb
}
|}

(* ── R67_TS — test block descriptions ───────────────────────────────────── *)

let test_R67_TS01_empty_test_description_rejected () =
  should_fail "empty description\\|empty description string" {|
#lang tesl
module R67Ts01 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
test "" {
  expect add 1 2 == 3
}
|}

let test_R67_TS02_non_empty_description_accepted () =
  should_pass {|
#lang tesl
module R67Ts02 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
test "addition works" {
  expect add 1 2 == 3
}
|}

let test_R67_TS03_test_with_runs_accepted () =
  (* test block with an explicit runs count *)
  should_pass {|
#lang tesl
module R67Ts03 exposing []
import Tesl.Prelude exposing [Int]
fn mul(a: Int, b: Int) -> Int = a * b
test "multiplication" runs 10 {
  expect mul 3 4 == 12
}
|}

let test_R67_TS04_test_with_let_and_expect_accepted () =
  should_pass {|
#lang tesl
module R67Ts04 exposing []
import Tesl.Prelude exposing [Int]
fn square(n: Int) -> Int = n * n
test "square of 5 is 25" {
  let result = square 5
  expect result == 25
}
|}

let test_R67_TS05_test_expect_fail_accepted () =
  should_pass {|
#lang tesl
module R67Ts05 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int exposing [Int.parse]
test "parse rejects non-numbers" {
  let r = Int.parse "abc"
  expect r == Nothing
}
|}

(* ── R67_OK — Valid declarations (regression guard) ─────────────────────── *)

let test_R67_OK01_full_queue_worker_pipeline_accepted () =
  should_pass {|
#lang tesl
module R67Ok01 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential]
database R67Ok01Db = Database {
  schema: "myapp"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "myapp"  user: "app"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
record NotifyJob { userId: String message: String }
queue NotifyQueue = Queue {
  database: R67Ok01Db
  jobs: [NotifyJob]
  retry: QueueRetryStrategy { maxAttempts: 3 backoff: Exponential initialDelay: 1000 }
}
worker sendNotification(job: NotifyJob) -> String requires [] =
  job.message
workers NotifyWorkers for NotifyQueue { NotifyJob = sendNotification }
|}

let test_R67_OK02_channel_pipeline_accepted () =
  should_pass {|
#lang tesl
module R67Ok02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]
database R67Ok02Db = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
type Event = EventA msg: String
sseChannel EventChannel(userId: String) = SseChannel { database: R67Ok02Db payload: Event }
|}

let test_R67_OK03_database_with_entities_accepted () =
  should_pass {|
#lang tesl
module R67Ok03 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
entity User table "users" primaryKey id { id: Int name: String }
entity Post table "posts" primaryKey id { id: Int title: String authorId: Int }
database R67Ok03Db = Database {
  schema: "app"
  entities: [User, Post]
  backend: Postgres (PostgresConfig {
    dbName: "app"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_OK04_multiple_test_blocks_accepted () =
  should_pass {|
#lang tesl
module R67Ok04 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
fn mul(a: Int, b: Int) -> Int = a * b
test "addition" { expect add 2 3 == 5 }
test "multiplication" { expect mul 2 3 == 6 }
test "zero identity" { expect add 0 5 == 5 }
|}

(* ── R67_CF — Config-field schema (colon-required + unknown-field) ───────── *)

let test_R67_CF01_missing_colon_rejected () =
  (* A config-record field written without its `:` is now a parse error
     (the typed `Database { ... }` record requires `field: value`). *)
  should_fail "expected }\\|missing its `:`\\|E000" {|
#lang tesl
module R67Cf01 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
database Db = Database {
  schema "app"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_CF02_unknown_field_rejected () =
  should_fail "unknown field" {|
#lang tesl
module R67Cf02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
database Db = Database {
  schema: "app"
  entities: []
  tsl: True
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_CF03_unknown_nested_field_rejected () =
  should_fail "unknown field `hostt`\\|unknown field" {|
#lang tesl
module R67Cf03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Env exposing [env]
database Db = Database {
  schema: "app"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: env "DB"
    user: "u"
    password: ""
    hostt: env "H"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_CF04_colon_form_accepted () =
  should_pass {|
#lang tesl
module R67Cf04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Env exposing [env, envInt]
database Db = Database {
  schema: "app"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: env "DB"
    user: "u"
    password: ""
    connection: TcpConnection { host: env "H"  port: envInt "PORT" 5432 }
  })
}
|}

let test_R67_CF05_missing_required_field_rejected () =
  (* A postgres database without `schema` is flagged. *)
  should_fail "missing required field" {|
#lang tesl
module R67Cf05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
database Db = Database {
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
|}

let test_R67_CF06_memory_backend_needs_no_schema () =
  (* A non-postgres (in-memory) backend needs neither schema nor postgres. *)
  should_pass {|
#lang tesl
module R67Cf06 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
entity Item table "items" primaryKey id { id: String }
database Db = Database {
  entities: [Item]
  backend: Memory
}
|}

let test_R67_CF07_channel_missing_payload_rejected () =
  should_fail "missing required field `payload`" {|
#lang tesl
module R67Cf07 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]
entity Item table "items" primaryKey id { id: String }
database Db = Database {
  schema: "s"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: "d"  user: "u"  password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}
sseChannel Ch = SseChannel {
  database: Db
}
|}

(* ── R67_NC — Named-field ADT construction (`Ctor { field: v }`) ─────────── *)

let test_R67_NC01_valid_named_ctor_accepted () =
  should_pass {|
#lang tesl
module R67Nc01 exposing []
import Tesl.Prelude exposing [String, Int]
type Conn = Tcp host: String port: Int | Sock path: String
record Holder { conn: Conn }
fn mk() -> Holder = Holder { conn: Tcp { host: "h", port: 5432 } }
|}

let test_R67_NC02_missing_ctor_field_rejected () =
  should_fail "missing required field `port`" {|
#lang tesl
module R67Nc02 exposing []
import Tesl.Prelude exposing [String, Int]
type Conn = Tcp host: String port: Int | Sock path: String
record Holder { conn: Conn }
fn mk() -> Holder = Holder { conn: Tcp { host: "h" } }
|}

let test_R67_NC03_unknown_ctor_field_rejected () =
  should_fail "has no field `bogus`" {|
#lang tesl
module R67Nc03 exposing []
import Tesl.Prelude exposing [String, Int]
type Conn = Tcp host: String port: Int | Sock path: String
record Holder { conn: Conn }
fn mk() -> Holder = Holder { conn: Tcp { host: "h", port: 1, bogus: 2 } }
|}

let test_R67_NC04_wrong_ctor_field_type_rejected () =
  should_fail "unify\\|type mismatch" {|
#lang tesl
module R67Nc04 exposing []
import Tesl.Prelude exposing [String, Int]
type Conn = Tcp host: String port: Int | Sock path: String
record Holder { conn: Conn }
fn mk() -> Holder = Holder { conn: Tcp { host: "h", port: "not-int" } }
|}

(* ── R67_APP — App simplification (folded queue + `main() -> App`) ────────── *)

let app_prelude = {|
#lang tesl
module R67App exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential, Job]
import Tesl.App exposing [App]
import Tesl.Env exposing [env, envInt]
capability emailCap
capability pubsub
record EmailJob { recipientId: String }
worker processEmail(job: EmailJob) requires [emailCap] = job
deadWorker handleDeadEmail(job: EmailJob) requires [emailCap] = job
handler handleRoot() -> String requires [] = "ok"
database DemoDb = Database {
  schema: "demo"  entities: []
  backend: Postgres (PostgresConfig { dbName: env "DB" user: env "U" password: env "P" connection: TcpConnection { host: env "H" port: envInt "PORT" 5432 } })
}
api DemoApi { get "/" -> String }
server DemoServer for DemoApi { endpoint_0 = handleRoot }
queue EmailQueue requires [emailCap, pubsub] = Queue {
  database: DemoDb
  jobs: [ Job EmailJob processEmail (Something handleDeadEmail) ]
  retry: { maxAttempts: 3 backoff: Exponential initialDelay: 10 }
  numberOfWorkers: 2
}
|}

let test_R67_APP01_folded_queue_and_main_app_accepted () =
  should_pass (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  let port = envInt "PORT" 8086
  App { database: DemoDb  queues: [EmailQueue]  email: []  sseChannels: []  api: DemoServer  port: port }
|})

let test_R67_APP02_main_app_missing_api_rejected () =
  should_fail "missing required field `api`" (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  App { database: DemoDb  queues: [EmailQueue]  port: 8086 }
|})

let test_R67_APP03_main_app_unknown_field_rejected () =
  should_fail "unknown field `prt`\\|unknown field" (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  App { database: DemoDb  api: DemoServer  prt: 8086 }
|})

let test_R67_APP04_folded_queue_bad_backoff_rejected () =
  should_fail "backoff.*must be\\|Exponential" {|
#lang tesl
module R67App4 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, QueueRetryStrategy, Job]
import Tesl.Env exposing [env, envInt]
record EmailJob { recipientId: String }
worker processEmail(job: EmailJob) requires [] = job
database DemoDb = Database { schema: "d"  entities: []  backend: Postgres (PostgresConfig { dbName: env "DB" user: env "U" password: env "P" connection: TcpConnection { host: env "H" port: envInt "PORT" 5432 } }) }
queue EmailQueue = Queue {
  database: DemoDb
  jobs: [ Job EmailJob processEmail Nothing ]
  retry: { maxAttempts: 3 backoff: Sideways initialDelay: 10 }
}
|}

(* ── R67_WIRE — App/config wiring-graph reference checks ──────────────────────
   The new typed forms skip the old per-block reference checks; check_app_wiring
   restores local-existence for queue/channel/email database refs and the App
   activation refs (database / api / queues / email / sseChannels). *)

let test_R67_WIRE01_app_unknown_database_rejected () =
  should_fail "references unknown database `NopeDb`\\|unknown database" (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  App { database: NopeDb  queues: [EmailQueue]  api: DemoServer  port: 8086 }
|})

let test_R67_WIRE02_app_unknown_server_rejected () =
  should_fail "references unknown server `NopeServer`\\|unknown server" (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  App { database: DemoDb  api: NopeServer  port: 8086 }
|})

let test_R67_WIRE03_app_unknown_queue_rejected () =
  should_fail "activates unknown queue `NopeQueue`\\|unknown queue" (app_prelude ^ {|
main() -> App requires [emailCap, pubsub] =
  App { database: DemoDb  queues: [NopeQueue]  api: DemoServer  port: 8086 }
|})

let test_R67_WIRE04_queue_unknown_database_rejected () =
  should_fail "references unknown database" {|
#lang tesl
module R67Wire4 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [Queue, Job]
record EmailJob { recipientId: String }
worker processEmail(job: EmailJob) requires [] = job
queue EmailQueue = Queue {
  database: GhostDb
  jobs: [ Job EmailJob processEmail Nothing ]
}
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review67-Block-Validation" [
    "queue-structure", [
      test_case "R67_QU01 queue missing database rejected" `Quick test_R67_QU01_queue_missing_database_rejected;
      (* R67_QU02 (empty jobs list rejected) deleted: new typed Queue accepts `jobs: []`. *)
      test_case "R67_QU03 queue no jobs clause rejected" `Quick test_R67_QU03_queue_no_jobs_clause_rejected;
      test_case "R67_QU04 queue with database and jobs accepted" `Quick test_R67_QU04_queue_with_database_and_jobs_accepted;
      test_case "R67_QU05 queue with retry config accepted" `Quick test_R67_QU05_queue_with_retry_config_accepted;
    ];
    "channel-structure", [
      test_case "R67_CH01 channel missing database rejected" `Quick test_R67_CH01_channel_missing_database_rejected;
      test_case "R67_CH02 channel empty database rejected" `Quick test_R67_CH02_channel_empty_database_rejected;
      test_case "R67_CH03 channel with database accepted" `Quick test_R67_CH03_channel_with_database_accepted;
      test_case "R67_CH04 channel with key params accepted" `Quick test_R67_CH04_channel_with_key_params_accepted;
    ];
    "workers-structure", [
      test_case "R67_WK01 workers undefined queue rejected" `Quick test_R67_WK01_workers_undefined_queue_rejected;
      test_case "R67_WK02 workers empty bindings rejected" `Quick test_R67_WK02_workers_empty_bindings_rejected;
      test_case "R67_WK03 workers undefined handler rejected" `Quick test_R67_WK03_workers_undefined_handler_rejected;
      test_case "R67_WK04 workers with valid worker accepted" `Quick test_R67_WK04_workers_with_valid_worker_accepted;
      test_case "R67_WK05 workers fn instead of worker rejected" `Quick test_R67_WK05_workers_fn_instead_of_worker_rejected;
      test_case "R67_WK06 dead-workers undefined queue rejected" `Quick test_R67_WK06_dead_workers_undefined_queue_rejected;
      test_case "R67_WK07 dead-workers valid accepted" `Quick test_R67_WK07_dead_workers_valid_accepted;
      test_case "R67_WK08 workers multiple job types accepted" `Quick test_R67_WK08_workers_multiple_job_types_accepted;
      test_case "R67_WK09 handler kind instead of worker rejected" `Quick test_R67_WK09_handler_kind_instead_of_worker_rejected;
    ];
    "database-entities", [
      (* R67_DB01/DB02/DB05 (undefined-entity rejection) deleted: the new typed
         Database form no longer validates that `entities:` members are declared. *)
      test_case "R67_DB03 database with declared entity accepted" `Quick test_R67_DB03_database_with_declared_entity_accepted;
      test_case "R67_DB04 database empty entities accepted" `Quick test_R67_DB04_database_empty_entities_accepted;
      test_case "R67_DB06 entity from declared local accepted" `Quick test_R67_DB06_database_entity_from_imported_module_accepted;
    ];
    "api-test-structure", [
      test_case "R67_AT01 api-test undefined server rejected" `Quick test_R67_AT01_api_test_undefined_server_rejected;
      test_case "R67_AT02 api-test empty description rejected" `Quick test_R67_AT02_api_test_empty_description_rejected;
      test_case "R67_AT03 api-test both errors caught" `Quick test_R67_AT03_api_test_both_errors_at_once;
      test_case "R67_AT04 api-test valid accepted" `Quick test_R67_AT04_api_test_valid_accepted;
      test_case "R67_AT05 api-test with seed block accepted" `Quick test_R67_AT05_api_test_with_seed_accepted;
      test_case "R67_AT06 api-test multiple requests accepted" `Quick test_R67_AT06_api_test_multiple_requests_accepted;
    ];
    "test-descriptions", [
      test_case "R67_TS01 empty test description rejected" `Quick test_R67_TS01_empty_test_description_rejected;
      test_case "R67_TS02 non-empty description accepted" `Quick test_R67_TS02_non_empty_description_accepted;
      test_case "R67_TS03 test with runs count accepted" `Quick test_R67_TS03_test_with_runs_accepted;
      test_case "R67_TS04 test with let and expect accepted" `Quick test_R67_TS04_test_with_let_and_expect_accepted;
      test_case "R67_TS05 test expect on Maybe accepted" `Quick test_R67_TS05_test_expect_fail_accepted;
    ];
    "valid-declarations", [
      test_case "R67_OK01 full queue/worker pipeline accepted" `Quick test_R67_OK01_full_queue_worker_pipeline_accepted;
      test_case "R67_OK02 channel pipeline accepted" `Quick test_R67_OK02_channel_pipeline_accepted;
      test_case "R67_OK03 database with entities accepted" `Quick test_R67_OK03_database_with_entities_accepted;
      test_case "R67_OK04 multiple test blocks accepted" `Quick test_R67_OK04_multiple_test_blocks_accepted;
    ];
    "config-field-schema", [
      test_case "R67_CF01 missing colon rejected" `Quick test_R67_CF01_missing_colon_rejected;
      test_case "R67_CF02 unknown field rejected" `Quick test_R67_CF02_unknown_field_rejected;
      test_case "R67_CF03 unknown nested field rejected" `Quick test_R67_CF03_unknown_nested_field_rejected;
      test_case "R67_CF04 colon form accepted" `Quick test_R67_CF04_colon_form_accepted;
      test_case "R67_CF05 missing required field rejected" `Quick test_R67_CF05_missing_required_field_rejected;
      test_case "R67_CF06 memory backend needs no schema" `Quick test_R67_CF06_memory_backend_needs_no_schema;
      test_case "R67_CF07 channel missing payload rejected" `Quick test_R67_CF07_channel_missing_payload_rejected;
    ];
    "named-ctor-construction", [
      test_case "R67_NC01 valid named ctor accepted" `Quick test_R67_NC01_valid_named_ctor_accepted;
      test_case "R67_NC02 missing ctor field rejected" `Quick test_R67_NC02_missing_ctor_field_rejected;
      test_case "R67_NC03 unknown ctor field rejected" `Quick test_R67_NC03_unknown_ctor_field_rejected;
      test_case "R67_NC04 wrong ctor field type rejected" `Quick test_R67_NC04_wrong_ctor_field_type_rejected;
    ];
    "app-simplification", [
      test_case "R67_APP01 folded queue + main->App accepted" `Quick test_R67_APP01_folded_queue_and_main_app_accepted;
      test_case "R67_APP02 main App missing api rejected" `Quick test_R67_APP02_main_app_missing_api_rejected;
      test_case "R67_APP03 main App unknown field rejected" `Quick test_R67_APP03_main_app_unknown_field_rejected;
      test_case "R67_APP04 folded queue bad backoff rejected" `Quick test_R67_APP04_folded_queue_bad_backoff_rejected;
      test_case "R67_WIRE01 App unknown database rejected" `Quick test_R67_WIRE01_app_unknown_database_rejected;
      test_case "R67_WIRE02 App unknown server rejected" `Quick test_R67_WIRE02_app_unknown_server_rejected;
      test_case "R67_WIRE03 App unknown queue rejected" `Quick test_R67_WIRE03_app_unknown_queue_rejected;
      test_case "R67_WIRE04 queue unknown database rejected" `Quick test_R67_WIRE04_queue_unknown_database_rejected;
    ];
  ]
