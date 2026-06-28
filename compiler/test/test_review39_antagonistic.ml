(** Antagonistic regression tests for Critical Review 39.

    Focus: broaden coverage for under-tested user-facing surface area:
    doctests, custom property generators, built-in api/load tests,
    current proof-utility surface shape, and CLI ergonomics.
*)

open Alcotest

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let flag name =
  if Filename.basename tesl = "main.exe" then "--" ^ name else name

let check_subcmd = flag "check"

let contains text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > text_len then false
    else if String.sub text i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_tesl args =
  let quoted = Filename.quote tesl :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let compile_string ?(mode = check_subcmd) src =
  let tmp = Filename.temp_file "tesl-r39-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let args = if mode = "" then [tmp] else [mode; tmp] in
  let result = run_tesl args in
  (try Sys.remove tmp with _ -> ());
  result

let has_error out = contains out "error["

let should_pass src =
  let code, out = compile_string src in
  let ok = code = 0 && not (has_error out) in
  if not ok then
    Printf.eprintf "Unexpected failure output:
%s
" out;
  check bool "should compile without errors" true ok

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_project files f =
  let dir = Filename.temp_file "tesl-r39-proj" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  List.iter (fun (rel, content) ->
    let path = Filename.concat dir rel in
    let parent = Filename.dirname path in
    if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
    write_file path content
  ) files;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () -> f dir)

let run_main_in_project args files =
  with_temp_project files (fun dir ->
    run_tesl (args @ [Filename.concat dir "Main.tesl"]))

let check_cli_ok ~label ~args ~files ~needles =
  let code, out = run_main_in_project args files in
  let ok = code = 0 && List.for_all (contains out) needles in
  if not ok then
    Printf.eprintf "CLI command failed for %s:
%s
" label out;
  check bool label true ok

let doctest_basic_compiles () =
  should_pass {|#lang tesl
module Main exposing [double]
import Tesl.Prelude exposing [Int]

#> double 3
#= 6
fn double(n: Int) -> Int =
  n * 2
|}

let doctest_multiple_examples_compile () =
  should_pass {|#lang tesl
module Main exposing [clamp]
import Tesl.Prelude exposing [Int]

#> clamp 0 10 5
#= 5
#> clamp 0 10 -3
#= 0
#> clamp 0 10 99
#= 10
fn clamp(lo: Int, hi: Int, n: Int) -> Int =
  if n < lo then
    lo
  else
    if n > hi then
      hi
    else
      n
|}

let doctest_property_compiles () =
  should_pass {|#lang tesl
module Main exposing [double]
import Tesl.Prelude exposing [Int]

#> property "even" (n: Int) { (double n) % 2 == 0 }
fn double(n: Int) -> Int =
  n * 2
|}

let property_custom_generator_compiles () =
  should_pass {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]

fn gen(i: Int) -> Int =
  i

fn identity(n: Int) -> Int =
  n

test "custom generator" with 10 runs {
  property "identity" (n: Int via gen) { identity n == n }
}
|}

let property_where_clause_runs_compile () =
  should_pass {|#lang tesl
module Main exposing [clamp]
import Tesl.Prelude exposing [Int]

fn clamp(lo: Int, hi: Int, n: Int) -> Int =
  if n < lo then
    lo
  else
    if n > hi then
      hi
    else
      n

test "clamp properties" with 20 runs {
  property "result stays in range" (lo: Int, hi: Int where lo <= hi, n: Int) { clamp lo hi n >= lo && clamp lo hi n <= hi }
}
|}

let expect_fail_test_compiles () =
  should_pass {|#lang tesl
module Main exposing [checkAge]
import Tesl.Prelude exposing [Int]

fact ValidAge (n: Int)

check checkAge(n: Int) -> n: Int ::: ValidAge n =
  if n >= 0 && n <= 150 then
    ok n ::: ValidAge n
  else
    fail 400 "invalid age"

test "expectFail works for checks" {
  expectFail check checkAge -1
  expectFail check checkAge 151
}
|}

let doctest_and_test_block_coexist () =
  should_pass {|#lang tesl
module Main exposing [double]
import Tesl.Prelude exposing [Int]

#> double 4
#= 8
fn double(n: Int) -> Int =
  n * 2

test "double" {
  expect double 5 == 10
}
|}

let proof_decomposition_ignored_slots_compile () =
  should_pass {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int]

fact Positive (n: Int)

check pos(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n

fn demo(n: Int) -> Int =
  let checked = check pos n
  let (_ ::: proof) = checked
  let (raw ::: _) = checked
  raw
|}

let detach_forget_attach_round_trip_compiles () =
  should_pass {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int, attachFact, detachFact, forgetFact]

fact Positive (n: Int)

check pos(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n

fn needsPositive(n: Int ::: Positive n) -> Int =
  n

fn demo(n: Int) -> Int =
  let checked = check pos n
  let proof = detachFact checked
  let raw = forgetFact checked
  let again = attachFact raw proof
  needsPositive again
|}

let api_test_basic_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [statusOk, isNull]

record EchoRequest {
  message: String
}

codec EchoRequest {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      message <- "message" with_codec stringCodec
    }
  ]
}

handler echo(req: EchoRequest) -> EchoRequest =
  req

api Api {
  post "/echo"
    body req: EchoRequest
    -> EchoRequest
}

server Server for Api {
  echo = echo
}

api-test "raw JSON body and dynamic response fields" for Server {
  let echoResp = post "/echo" body { "message": "hello from api-test" }
  expect statusOk echoResp.status
  expect echoResp.body.message == "hello from api-test"
  expect isNull echoResp.body.missing
}
|}

let api_test_seeded_state_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.ApiTest exposing [statusOk]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

record EchoRequest {
  message: String
}

codec EchoRequest {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      message <- "message" with_codec stringCodec
    }
  ]
}

entity Note table "notes" primaryKey id {
  id: String
  title: String
}

database MainDatabase = Database {
  schema: "lesson32"
  entities: [Note]
  backend: Postgres (PostgresConfig {
    dbName: "lesson32"
    user: "lesson32"
    password: "lesson32"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

handler echo(req: EchoRequest) -> EchoRequest =
  req

handler getSeededNote() -> Note
  requires [dbRead] =
  let found = selectOne n from Note where n.id == "note-1"
  case found of
    Nothing ->
      fail 404 "note not found"
    Something n ->
      n

api Api {
  post "/echo"
    body req: EchoRequest
    -> EchoRequest
  get "/seeded-note"
    -> Note
}

server Server for Api {
  echo = echo
  getSeededNote = getSeededNote
}

api-test "seed prepares fresh in-memory state" for Server requires [dbRead, dbWrite] {
  seed {
    insert Note { id: "note-1", title: "Seeded from setup" }
  }

  let seeded = get "/seeded-note"
  expect statusOk seeded.status
  expect seeded.body.title == "Seeded from setup"
}
|}

let api_test_sse_collect_with_timeout_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [FromQueue, queueRead, queueWrite, pubsub, Queue, QueueRetryStrategy, Linear]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]
import Tesl.ApiTest exposing [
  statusOk,
  isNotEmpty,
  includesWhere,
  subscribe,
  collect,
  JobResult(..),
  processNextJob,
  pendingJobCount,
  expectJobOk,
]

database MainDatabase = Database {
  schema: "lesson33"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "demo"
    user: "demo"
    password: "demo"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

record NotifyJob {
  userId: String
  message: String
}

record SendNoticeRequest {
  userId: String
  message: String
}

codec SendNoticeRequest {
  toJson {
    userId  -> "userId" with_codec stringCodec
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      userId  <- "userId" with_codec stringCodec
      message <- "message" with_codec stringCodec
    }
  ]
}

type NoticeEvent
  = NoticeSent message: String

fn parseUserId(id: String) -> String =
  id

capture userIdCapture: String using stringCodec via parseUserId

queue MainQueue = Queue {
  database: MainDatabase
  jobs: [NotifyJob]
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Linear
    initialDelay: 1
  }
}

sseChannel MainEvents(userId: String) = SseChannel {
  database: MainDatabase
  payload: NoticeEvent
}

worker handleNotice(job: NotifyJob ::: FromQueue (Id == jobId) job)
  requires [queueRead, pubsub] =
  publish MainEvents(job.userId) NoticeSent { message: job.message }
  job

workers MainWorkers for MainQueue {
  NotifyJob = handleNotice
}

handler sendNotice(req: SendNoticeRequest) -> String
  requires [queueWrite] =
  enqueue NotifyJob { userId: req.userId, message: req.message }
  "queued"

api Api {
  post "/send"
    body req: SendNoticeRequest
    -> String
  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe MainEvents(userId)
}

server Server for Api {
  sendNotice = sendNotice
}

api-test "subscribe collect and process queue" for Server requires [queueRead, queueWrite, pubsub] {
  let stream = subscribe "/events/user-1"
  let resp = post "/send" body { "userId": "user-1", "message": "Hello from review39" }
  expect statusOk resp.status

  expect pendingJobCount MainQueue == 1

  let result = processNextJob MainQueue
  let job = expectJobOk result
  expect job.userId == "user-1"
  expect pendingJobCount MainQueue == 0

  let events = collect stream count 1 timeout 1500ms
  expect isNotEmpty events
  expect includesWhere { "tag": "NoticeSent", "fields": { "message": "Hello from review39" } } events
}
|}

let load_test_basic_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]

record Greeting {
  name: String
  message: String
}

codec Greeting {
  toJson {
    name    -> "name"    with_codec stringCodec
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      name    <- "name"    with_codec stringCodec
      message <- "message" with_codec stringCodec
    }
  ]
}

handler greet(g: Greeting) -> Greeting =
  Greeting { name: g.name, message: "Hello, ${g.name}!" }

api Api {
  post "/greet"
    body g: Greeting
    -> Greeting
}

server Server for Api {
  greet = greet
}

load-test "greet throughput" for Server
  rate 5rps
  duration 1s {
  post "/greet" body { "name": "bench", "message": "" }
  assert p99 < 500ms
  assert errorRate < 1
}
|}

let load_test_seed_and_baseline_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity Book table "books" primaryKey id {
  id: String
  title: String
  pages: Int
}

database MainDatabase = Database {
  schema: "lesson41"
  entities: [Book]
  backend: Postgres (PostgresConfig {
    dbName: "lesson41"
    user: "lesson41"
    password: "lesson41"
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

handler listBooks() -> List Book
  requires [dbRead] =
  select b from Book

api Api {
  get "/books"
    -> List Book
}

server Server for Api {
  listBooks = listBooks
}

load-test "list books with seeded data" for Server
  rate 3rps
  duration 1s
  baseline "base"
  requires [dbRead, dbWrite] {
  seed {
    insert Book { id: "book-1", title: "The Art of Tesl", pages: 320 }
    insert Book { id: "book-2", title: "Proofs in Practice", pages: 210 }
  }

  get "/books"

  assert p95 < 500ms
  assert regressionVsBaseline p95 < 1.2
}
|}

let load_test_throughput_assert_compiles () =
  should_pass {|#lang tesl
module Main exposing [Server]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]

record Greeting {
  name: String
  message: String
}

codec Greeting {
  toJson {
    name    -> "name"    with_codec stringCodec
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      name    <- "name"    with_codec stringCodec
      message <- "message" with_codec stringCodec
    }
  ]
}

handler greet(g: Greeting) -> Greeting =
  Greeting { name: g.name, message: "Hello" }

api Api {
  post "/greet"
    body g: Greeting
    -> Greeting
}

server Server for Api {
  greet = greet
}

load-test "greet throughput metric" for Server
  rate 5rps
  duration 1s {
  post "/greet" body { "name": "bench", "message": "" }
  assert throughput > 1rps
}
|}

let deps_lists_local_import () =
  check_cli_ok
    ~label:"deps lists local import"
    ~args:[flag "deps"]
    ~files:[
      ("Main.tesl", {|#lang tesl
module Main exposing []
import Local exposing [helper]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  helper()
|});
      ("Local.tesl", {|#lang tesl
module Local exposing [helper]
import Tesl.Prelude exposing [Int]
fn helper() -> Int =
  1
|});
    ]
    ~needles:["Local.tesl"]

let semantic_json_emits_module_name () =
  check_cli_ok
    ~label:"semantic json emits module name"
    ~args:[flag "semantic-json"]
    ~files:[
      ("Main.tesl", {|#lang tesl
module Main exposing [main]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  let value = 1
  value
|});
    ]
    ~needles:["module_name"; "Main"; "functions"]

let local_bindings_json_reports_binding () =
  check_cli_ok
    ~label:"local bindings json reports binding"
    ~args:[flag "local-bindings-json"]
    ~files:[
      ("Main.tesl", {|#lang tesl
module Main exposing [main]
import Tesl.Prelude exposing [Int]
fn main() -> Int =
  let value = 1
  value
|});
    ]
    ~needles:["name"; "value"; "type"; "Int"]

let mutate_strong_boundary_tests_succeeds () =
  check_cli_ok
    ~label:"mutation cli succeeds on strong boundary tests"
    ~args:[flag "mutate"]
    ~files:[
      ("Main.tesl", {|#lang tesl
module Main exposing [ValidAge, checkAge]
import Tesl.Prelude exposing [Int]

fact ValidAge (n: Int)

check checkAge(n: Int) -> n: Int ::: ValidAge n =
  if n >= 18 && n <= 120 then
    ok n ::: ValidAge n
  else
    fail 422 "age must be between 18 and 120"

test "checkAge: boundary values kill all mutants" {
  expect (check checkAge 18) == 18
  expect (check checkAge 65) == 65
  expect (check checkAge 120) == 120
  expectFail check checkAge 17
  expectFail check checkAge 121
}
|});
    ]
    ~needles:["Mutation score: 100%"; "7 killed"]

let () =
  run "review-39-antagonistic" [
    "doctests-and-test-blocks", [
      test_case "doctest basic compiles (R39_01)" `Quick doctest_basic_compiles;
      test_case "multiple doctest examples compile (R39_02)" `Quick doctest_multiple_examples_compile;
      test_case "doctest property compiles (R39_03)" `Quick doctest_property_compiles;
      test_case "custom property generator compiles (R39_04)" `Quick property_custom_generator_compiles;
      test_case "where clause with run count compiles (R39_05)" `Quick property_where_clause_runs_compile;
      test_case "expectFail test compiles (R39_06)" `Quick expect_fail_test_compiles;
      test_case "doctest and test block coexist (R39_07)" `Quick doctest_and_test_block_coexist;
    ];
    "proof-utility-surface", [
      test_case "proof decomposition with ignored slots compiles (R39_08)" `Quick proof_decomposition_ignored_slots_compile;
      test_case "detach forget attach round trip compiles (R39_11)" `Quick detach_forget_attach_round_trip_compiles;
    ];
    "api-and-load-tests", [
      test_case "api-test basic compiles (R39_12)" `Quick api_test_basic_compiles;
      test_case "api-test seeded state compiles (R39_13)" `Quick api_test_seeded_state_compiles;
      test_case "api-test sse collect with timeout compiles (R39_14)" `Quick api_test_sse_collect_with_timeout_compiles;
      test_case "load-test basic compiles (R39_15)" `Quick load_test_basic_compiles;
      test_case "load-test seed and baseline compile (R39_16)" `Quick load_test_seed_and_baseline_compiles;
      test_case "load-test throughput assert compiles (R39_17)" `Quick load_test_throughput_assert_compiles;
    ];
    "cli-ergonomics", [
      test_case "deps lists local import (R39_18)" `Quick deps_lists_local_import;
      test_case "semantic json emits module name (R39_19)" `Quick semantic_json_emits_module_name;
      test_case "local bindings json reports binding (R39_20)" `Quick local_bindings_json_reports_binding;
      test_case "mutation cli succeeds on strong boundary tests (R39_21)" `Quick mutate_strong_boundary_tests_succeeds;
    ];
  ]
