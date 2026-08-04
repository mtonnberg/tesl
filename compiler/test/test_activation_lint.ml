(** W094 — a `queue` or `sseChannel` declared but never activated.

    The `App { … }` record returned by `main` is what starts a queue's workers and
    a channel's delivery, and `check_app_wiring` requires every activation ref to
    name a declaration in the SAME module. So the module that declares a queue is
    the module that has to activate it, and this file has the whole answer — no
    cross-module question at all, unlike the index lints.

    Worth reporting because nothing else does: an unactivated queue still ACCEPTS
    work (`enqueue` writes the job row) and no worker ever drains it, so the
    failure is silent accumulation rather than an error.

    The half of this that needed care is the SILENCE. A module with no `main` is
    not evidence of a dead queue — `test` / `apiTest` blocks drive queues and
    channels through the test harness, and eight corpus test modules legitimately
    declare a queue, exercise it, and have no `main`. Warning there produced
    thirteen findings of which twelve were false. The guard is pinned below. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  out

let with_source src f =
  let dir = Filename.temp_dir "tesl-w094" "" in
  let path = Filename.concat dir "Act.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* Count diagnostic headers only, not the "explain: tesl help W094" trailer. *)
let count_w094 out =
  let re = Str.regexp "^warning\\[W094\\]" in
  String.split_on_char '\n' out
  |> List.filter (fun line ->
         try ignore (Str.search_forward re line 0); true with Not_found -> false)
  |> List.length

let lint src = with_source src (fun p -> run_cc [ "--lint"; p ])

let prelude = {|module Act exposing [EmailQueue]
import Tesl.Prelude exposing [Bool(..), String, Fact]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Queue exposing [queueRead, queueWrite, pubsub, Queue, Job, FromQueue]
import Tesl.SSE exposing [SseChannel]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

capability appService implies dbRead, dbWrite, queueWrite, pubsub

database MainDb = Database {
  schema: "app"
  entities: []
  backend: Memory
}

record SendEmail {
  to: String
}

type UserEvent
  = ProfileUpdated bio: String

queue EmailQueue requires [queueRead] = Queue {
  database: MainDb
  jobs: [Job SendEmail sendEmailWorker Nothing]
}

worker sendEmailWorker(job: SendEmail ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  job

sseChannel UserEvents(userId: String) = SseChannel {
  database: MainDb
  payload: UserEvent
}
|}

let main_with app_fields =
  Printf.sprintf {|
api AppApi {
  get "/" -> String
}

server AppServer for AppApi {
  endpoint_0 = root
}

handler root() -> String =
  "ok"

main() -> App requires [appService, queueRead] =
  App {
    database: MainDb
    api: AppServer
    port: 8086
%s
  }
|} app_fields

let expect label src ~w094 =
  let out = lint src in
  let got = count_w094 out in
  if got <> w094 then
    failf "%s: expected %d W094, got %d:\n%s" label w094 got out

(* ── Reports ──────────────────────────────────────────────────────────────── *)

let test_neither_activated () =
  let src = prelude ^ main_with "" in
  expect "an App activating neither the queue nor the channel" src ~w094:2;
  let out = lint src in
  if not (contains out "queue `EmailQueue` is declared but never activated") then
    failf "the queue should be named:\n%s" out;
  if not (contains out "sseChannel `UserEvents` is declared but never activated") then
    failf "the channel should be named:\n%s" out;
  (* The message must name the exact field to add, not just the problem. *)
  if not (contains out "queues: [EmailQueue]") then
    failf "the queue message should show the App field to add:\n%s" out;
  if not (contains out "sseChannels: [UserEvents]") then
    failf "the channel message should show the App field to add:\n%s" out

let test_queue_only_activated () =
  expect "queue listed, channel not"
    (prelude ^ main_with "    queues: [EmailQueue]") ~w094:1;
  let out = lint (prelude ^ main_with "    queues: [EmailQueue]") in
  if contains out "queue `EmailQueue`" then
    failf "an activated queue must not be reported:\n%s" out

let test_channel_only_activated () =
  expect "channel listed, queue not"
    (prelude ^ main_with "    sseChannels: [UserEvents]") ~w094:1;
  let out = lint (prelude ^ main_with "    sseChannels: [UserEvents]") in
  if contains out "sseChannel `UserEvents`" then
    failf "an activated channel must not be reported:\n%s" out

(* ── Silences ─────────────────────────────────────────────────────────────── *)

let test_both_activated () =
  expect "both listed"
    (prelude ^ main_with "    queues: [EmailQueue]\n    sseChannels: [UserEvents]")
    ~w094:0

let test_no_main_is_silent () =
  (* The guard that matters. A test module drives its queue through `test` /
     `apiTest` blocks, not through App activation, and is indistinguishable from a
     dead library module — so this says nothing rather than guessing. *)
  expect "a module with no main at all" prelude ~w094:0

let test_test_module_is_silent () =
  expect "a module whose queue is exercised only by a test block"
    (prelude ^ {|
test "enqueues a job" requires [dbRead, dbWrite] {
  expect 1 == 1
}
|}) ~w094:0

let test_nothing_declared_is_silent () =
  expect "a module declaring neither a queue nor a channel"
    {|module Act exposing []

import Tesl.Prelude exposing [String]

fn hello() -> String =
  "hi"
|} ~w094:0

(* ── The App record's two spellings ───────────────────────────────────────── *)

let test_app_applied_to_record_spelling () =
  (* `main`'s body is normally a let-chain, so the App record is the TAIL of a
     nested `ELet`, not the body itself.  Missing that would report an activation
     that is right there in the source. *)
  let src = prelude ^ {|
api AppApi {
  get "/" -> String
}

server AppServer for AppApi {
  endpoint_0 = root
}

handler root() -> String =
  "ok"

main() -> App requires [appService, queueRead] =
  let _ = 1
  App {
    database: MainDb
    api: AppServer
    port: 8086
    queues: [EmailQueue]
    sseChannels: [UserEvents]
  }
|} in
  expect "an App at the tail of main's let-chain" src ~w094:0

let () =
  run "W094 unactivated queue / sseChannel" [
    "reports", [
      test_case "neither activated"              `Quick test_neither_activated;
      test_case "queue activated, channel not"   `Quick test_queue_only_activated;
      test_case "channel activated, queue not"   `Quick test_channel_only_activated;
    ];
    "silences", [
      test_case "both activated"                 `Quick test_both_activated;
      test_case "no main at all"                 `Quick test_no_main_is_silent;
      test_case "test-only module"               `Quick test_test_module_is_silent;
      test_case "nothing declared"               `Quick test_nothing_declared_is_silent;
    ];
    "App shapes", [
      test_case "let-chain before the App record" `Quick test_app_applied_to_record_spelling;
    ];
  ]
