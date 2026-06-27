(** Antagonistic regression tests for Critical Review 67: structural
    validation of custom declaration blocks.

    Previously, the following blocks were accepted with structurally invalid
    syntax and silently compiled to broken Racket (or emitted code that would
    fail at runtime):

    - queue:    missing `database`, empty `jobs` list
    - channel:  missing `database`
    - workers:  referencing an undefined queue; empty handler bindings;
                referencing a function that is not a `worker`
    - database: referencing entity types that are not declared
    - api-test: referencing an undefined server; empty description string
    - test:     empty description string

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
  should_fail "missing a `database` clause\\|missing.*database" {|
#lang tesl
module R67Qu01 exposing []
queue R67Qu01 { jobs: [MyJob] }
|}

let test_R67_QU02_queue_empty_jobs_rejected () =
  should_fail "no job types\\|jobs.*required\\|at least one" {|
#lang tesl
module R67Qu02 exposing []
database R67Qu02Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Qu02 { database: R67Qu02Db jobs: [] }
|}

let test_R67_QU03_queue_no_jobs_clause_rejected () =
  should_fail "no job types\\|jobs.*required\\|at least one" {|
#lang tesl
module R67Qu03 exposing []
database R67Qu03Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Qu03 { database: R67Qu03Db }
|}

let test_R67_QU04_queue_with_database_and_jobs_accepted () =
  should_pass {|
#lang tesl
module R67Qu04 exposing []
database R67Qu04Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Qu04 { database: R67Qu04Db jobs: [JobA, JobB] }
|}

let test_R67_QU05_queue_with_retry_config_accepted () =
  should_pass {|
#lang tesl
module R67Qu05 exposing []
database R67Qu05Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Qu05 {
  database: R67Qu05Db
  jobs: [Job1]
  retry { maxAttempts: 3 backoff: "exponential" initialDelay: 1000 }
}
|}

(* ── R67_CH — Channel structure ──────────────────────────────────────────── *)

let test_R67_CH01_channel_missing_database_rejected () =
  should_fail "missing a `database` clause\\|missing.*database" {|
#lang tesl
module R67Ch01 exposing []
type Ev = EvA msg: String
channel R67Ch01 { payload: Ev }
|}

let test_R67_CH02_channel_empty_database_rejected () =
  should_fail "missing a `database` clause\\|missing.*database" {|
#lang tesl
module R67Ch02 exposing []
import Tesl.Prelude exposing [String]
type Ev = EvB msg: String
channel R67Ch02 { database: "" payload: Ev }
|}

let test_R67_CH03_channel_with_database_accepted () =
  should_pass {|
#lang tesl
module R67Ch03 exposing []
import Tesl.Prelude exposing [String]
database R67Ch03Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
type EvC = EvCA msg: String
channel R67Ch03 { database: R67Ch03Db payload: EvC }
|}

let test_R67_CH04_channel_with_key_params_accepted () =
  should_pass {|
#lang tesl
module R67Ch04 exposing []
import Tesl.Prelude exposing [String]
database R67Ch04Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
type EvD = EvDA msg: String
channel R67Ch04(userId: String) { database: R67Ch04Db payload: EvD }
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
database R67Wk02Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk02Q { database: R67Wk02Db jobs: [MyJob] }
workers R67Wk02 for R67Wk02Q { }
|}

let test_R67_WK03_workers_undefined_handler_rejected () =
  should_fail "not declared as a.*worker\\|unknown.*worker\\|not a `worker`" {|
#lang tesl
module R67Wk03 exposing []
import Tesl.Prelude exposing [String]
database R67Wk03Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk03Q { database: R67Wk03Db jobs: [MyJob] }
workers R67Wk03 for R67Wk03Q { MyJob = undefinedWorkerFn }
|}

let test_R67_WK04_workers_with_valid_worker_accepted () =
  should_pass {|
#lang tesl
module R67Wk04 exposing []
import Tesl.Prelude exposing [String]
database R67Wk04Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk04Q { database: R67Wk04Db jobs: [MyJob] }
record MyJob { msg: String }
worker processMyJob(job: MyJob) -> String requires [] = job.msg
workers R67Wk04 for R67Wk04Q { MyJob = processMyJob }
|}

let test_R67_WK05_workers_fn_instead_of_worker_rejected () =
  should_fail "not declared as a.*worker\\|not a `worker`" {|
#lang tesl
module R67Wk05 exposing []
import Tesl.Prelude exposing [String]
database R67Wk05Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk05Q { database: R67Wk05Db jobs: [MyJob] }
record MyJob { msg: String }
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
database R67Wk07Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk07Q { database: R67Wk07Db jobs: [DeadJob] }
record DeadJob { msg: String }
deadWorker handleDeadDeadJob(job: DeadJob) -> String requires [] = job.msg
deadWorkers R67Wk07 for R67Wk07Q { DeadJob = handleDeadDeadJob }
|}

let test_R67_WK08_workers_multiple_job_types_accepted () =
  (* workers block with multiple job type → handler bindings *)
  should_pass {|
#lang tesl
module R67Wk08 exposing []
import Tesl.Prelude exposing [String, Int]
database R67Wk08Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk08Q { database: R67Wk08Db jobs: [JobA, JobB] }
record JobA { name: String }
record JobB { count: Int }
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
database R67Wk09Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
queue R67Wk09Q { database: R67Wk09Db jobs: [MyJob] }
record MyJob { msg: String }
handler httpHandler() -> String requires [] = "response"
workers R67Wk09 for R67Wk09Q { MyJob = httpHandler }
|}

(* ── R67_DB — Database entity references ────────────────────────────────── *)

let test_R67_DB01_database_undefined_entity_rejected () =
  should_fail "unknown entity\\|references unknown entity" {|
#lang tesl
module R67Db01 exposing []
database R67Db01 {
  backend: postgres
  schema: "s"
  entities: [GhostEntity]
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
|}

let test_R67_DB02_database_multiple_undefined_entities_rejected () =
  should_fail "unknown entity\\|references unknown entity" {|
#lang tesl
module R67Db02 exposing []
database R67Db02 {
  backend: postgres
  schema: "s"
  entities: [GhostA, GhostB]
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
|}

let test_R67_DB03_database_with_declared_entity_accepted () =
  should_pass {|
#lang tesl
module R67Db03 exposing []
import Tesl.Prelude exposing [String, Int]
entity R67Item table "items" primaryKey id {
  id: Int
  name: String
}
database R67Db03 {
  backend: postgres
  schema: "s"
  entities: [R67Item]
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
|}

let test_R67_DB04_database_empty_entities_accepted () =
  (* Empty entities list is valid — the database just has no registered entities *)
  should_pass {|
#lang tesl
module R67Db04 exposing []
database R67Db04 {
  backend: postgres
  schema: "s"
  entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
|}

let test_R67_DB05_database_mix_known_and_undefined_entity_rejected () =
  (* One valid, one invalid entity reference — the invalid one must be caught *)
  should_fail "unknown entity\\|references unknown entity" {|
#lang tesl
module R67Db05 exposing []
import Tesl.Prelude exposing [Int, String]
entity ValidEntity table "valid" primaryKey id { id: Int name: String }
database R67Db05 {
  backend: postgres schema: "s"
  entities: [ValidEntity, GhostEntity]
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
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
entity Product table "products" primaryKey id {
  id: Int
  name: String
  price: Int
}
database R67Db06 {
  backend: postgres schema: "shop"
  entities: [Product]
  postgres { database: "shop" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
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
database R67Ok01Db {
  backend: postgres schema: "myapp" entities: []
  postgres { database: "myapp" user: "app" password: "" host: "localhost" port: 5432 socket: "" }
}
record NotifyJob { userId: String message: String }
queue NotifyQueue {
  database: R67Ok01Db
  jobs: [NotifyJob]
  retry { maxAttempts: 3 backoff: "exponential" initialDelay: 1000 }
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
import Tesl.Json exposing [stringCodec]
database R67Ok02Db {
  backend: postgres schema: "s" entities: []
  postgres { database: "d" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
}
type Event = EventA msg: String
channel EventChannel(userId: String) { database: R67Ok02Db payload: Event }
|}

let test_R67_OK03_database_with_entities_accepted () =
  should_pass {|
#lang tesl
module R67Ok03 exposing []
import Tesl.Prelude exposing [String, Int]
entity User table "users" primaryKey id { id: Int name: String }
entity Post table "posts" primaryKey id { id: Int title: String authorId: Int }
database R67Ok03Db {
  backend: postgres schema: "app" entities: [User, Post]
  postgres { database: "app" user: "u" password: "" host: "localhost" port: 5432 socket: "" }
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
  should_fail "missing its `:`\\|must be written" {|
#lang tesl
module R67Cf01 exposing []
import Tesl.Prelude exposing [String]
database Db {
  backend postgres
  schema: "app"
  postgres {}
}
|}

let test_R67_CF02_unknown_field_rejected () =
  should_fail "unknown field" {|
#lang tesl
module R67Cf02 exposing []
import Tesl.Prelude exposing [String]
database Db {
  backend: postgres
  schema: "app"
  tsl: True
  postgres {}
}
|}

let test_R67_CF03_unknown_nested_field_rejected () =
  should_fail "unknown field `hostt`\\|unknown field" {|
#lang tesl
module R67Cf03 exposing []
import Tesl.Prelude exposing [String]
database Db {
  backend: postgres
  schema: "app"
  postgres {
    hostt: env("H")
  }
}
|}

let test_R67_CF04_colon_form_accepted () =
  should_pass {|
#lang tesl
module R67Cf04 exposing []
import Tesl.Prelude exposing [String]
database Db {
  backend: postgres
  schema: "app"
  entities: []
  postgres {
    dbName: env("DB")
    host: env("H")
    port: envInt("PORT", 5432)
  }
}
|}

let test_R67_CF05_missing_required_field_rejected () =
  (* A postgres database without `schema` / `postgres` is flagged. *)
  should_fail "missing required field" {|
#lang tesl
module R67Cf05 exposing []
import Tesl.Prelude exposing [String]
database Db {
  backend: postgres
}
|}

let test_R67_CF06_memory_backend_needs_no_schema () =
  (* A non-postgres (in-memory) backend needs neither schema nor postgres. *)
  should_pass {|
#lang tesl
module R67Cf06 exposing []
import Tesl.Prelude exposing [String]
entity Item table "items" primaryKey id { id: String }
database Db {
  backend: memory
  entities: [Item]
}
|}

let test_R67_CF07_channel_missing_payload_rejected () =
  should_fail "missing required field `payload`" {|
#lang tesl
module R67Cf07 exposing []
import Tesl.Prelude exposing [String]
entity Item table "items" primaryKey id { id: String }
database Db { backend: postgres  schema: "s"  postgres {} }
channel Ch {
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

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review67-Block-Validation" [
    "queue-structure", [
      test_case "R67_QU01 queue missing database rejected" `Quick test_R67_QU01_queue_missing_database_rejected;
      test_case "R67_QU02 queue empty jobs list rejected" `Quick test_R67_QU02_queue_empty_jobs_rejected;
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
      test_case "R67_DB01 database undefined entity rejected" `Quick test_R67_DB01_database_undefined_entity_rejected;
      test_case "R67_DB02 database multiple undefined entities rejected" `Quick test_R67_DB02_database_multiple_undefined_entities_rejected;
      test_case "R67_DB03 database with declared entity accepted" `Quick test_R67_DB03_database_with_declared_entity_accepted;
      test_case "R67_DB04 database empty entities accepted" `Quick test_R67_DB04_database_empty_entities_accepted;
      test_case "R67_DB05 mix known and undefined entity rejected" `Quick test_R67_DB05_database_mix_known_and_undefined_entity_rejected;
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
  ]
