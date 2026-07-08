(* App-main body type-checking (roadmap app_main_body_typechecking).

   `main() -> App` bodies were historically NOT type-checked at all
   (checker.ml `is_app_main` skipped the whole body because the tail
   `App { … }` record references declarations by name).  The fix checks the
   let-chain above the App tail exactly like ordinary ELet inference while
   the tail stays structurally validated.

   These fixtures pin the three fail-open classes that compiled clean before
   the fix, plus the sound variants (no false positives, decl-name references
   from main lets still resolve, statement forms chained as `let _ =` still
   check their payloads). *)

let parse src = Parser.parse_module "<test>" src

let contains haystack needle =
  let n = String.length haystack and m = String.length needle in
  let found = ref false in
  for i = 0 to n - m do
    if String.sub haystack i m = needle then found := true
  done;
  !found

let errors_of src =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
      (Compile.check_module src m)

let assert_error src substr =
  let errs = errors_of src in
  if not (List.exists (fun (d : Compile.diagnostic) -> contains d.message substr) errs)
  then
    Alcotest.failf "expected an error containing %S but got:\n%s" substr
      (if errs = [] then "(no errors)"
       else String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) errs))

let assert_clean src =
  let errs = errors_of src in
  if errs <> [] then
    Alcotest.failf "expected no errors but got:\n%s"
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) errs))

(* Minimal App skeleton: a fn to call, a memory DB, an empty server. *)
let app_preamble = {|#lang tesl
module Foo exposing [greet]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit, List]
import Tesl.Telemetry exposing [initTelemetry]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]

fn greet(name: String) -> String requires [] =
  "hello ${name}"

database D = Database {
  entities: []
  backend: Memory
}

api A {
}

server Srv for A {
}

|}

let app_tail = {|  App {
    database: D
    api: Srv
    port: 8097
  }
|}

(* ── The three fail-open classes, as main lets ──────────────────────────── *)

let t_unknown_telemetry_keyword_rejected () =
  assert_error
    (app_preamble
     ^ {|main() -> App requires [] =
  let _ = initTelemetry bogus "x"
|}
     ^ app_tail)
    "unknown initTelemetry keyword: bogus"

let t_wrong_typed_call_rejected () =
  assert_error
    (app_preamble
     ^ {|main() -> App requires [] =
  let wrong = greet 42
|}
     ^ app_tail)
    "cannot unify"

let t_unbound_name_rejected () =
  assert_error
    (app_preamble
     ^ {|main() -> App requires [] =
  let ghost = doesNotExist "y"
|}
     ^ app_tail)
    "unknown name: doesNotExist"

(* Keyword-named user binding in value position: the emitter would emit a
   valueless Racket keyword; the checker rejects it in typed positions. *)
let t_keyword_shadow_value_rejected () =
  assert_error
    (app_preamble
     ^ {|fn f() -> Unit requires [] =
  let metrics = True
  initTelemetry service "x" endpoint "in-memory" console metrics
|})
    "is an initTelemetry keyword"

(* ── Sound variants: no false positives ─────────────────────────────────── *)

let t_sound_main_accepted () =
  assert_clean
    (app_preamble
     ^ {|main() -> App requires [] =
  let _ = initTelemetry service "svc" endpoint "in-memory" console False metrics True metricsInterval 30000
  let msg = greet "pro"
|}
     ^ app_tail)

(* Later lets must see earlier bindings (env threading through the chain). *)
let t_let_chain_threading () =
  assert_clean
    (app_preamble
     ^ {|main() -> App requires [] =
  let name = "pro"
  let msg = greet name
|}
     ^ app_tail)

let t_let_chain_threading_bad_type () =
  assert_error
    (app_preamble
     ^ {|main() -> App requires [] =
  let name = 42
  let msg = greet name
|}
     ^ app_tail)
    "cannot unify"

(* Statement forms chain as `let _ = <stmt>`; the payload must be checked.
   enqueue's record payload with a wrong-typed and an unknown field. *)
let queue_preamble = {|#lang tesl
module Foo exposing [notifWorker]

import Tesl.Prelude exposing [Bool(..), Int, String, Unit, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Queue exposing [queueRead, queueWrite, Queue, QueueRetryStrategy, Job, FromQueue, Exponential]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]

record Note {
  msg: String
}

database D = Database {
  entities: []
  backend: Memory
}

worker notifWorker(job: Note ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  job

queue NQ requires [queueRead, queueWrite] = Queue {
  database: D
  jobs: [Job Note notifWorker Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 3
    backoff: Exponential
    initialDelay: 30
  }
}

api A {
}

server Srv for A {
}

|}

let queue_tail = {|  App {
    database: D
    api: Srv
    port: 8095
    queues: [NQ]
  }
|}

let t_main_enqueue_statement_ok () =
  assert_clean
    (queue_preamble
     ^ {|main() -> App requires [queueWrite] =
  enqueue Note { msg: "hi" }
|}
     ^ queue_tail)

let t_main_enqueue_bad_payload_rejected () =
  assert_error
    (queue_preamble
     ^ {|main() -> App requires [queueWrite] =
  enqueue Note { msg: 42 }
|}
     ^ queue_tail)
    "cannot unify"

let () =
  Alcotest.run "app-main body type-checking"
    [ ( "fail-open classes now rejected",
        [ Alcotest.test_case "unknown initTelemetry keyword" `Quick
            t_unknown_telemetry_keyword_rejected;
          Alcotest.test_case "wrong-typed call" `Quick t_wrong_typed_call_rejected;
          Alcotest.test_case "unbound name" `Quick t_unbound_name_rejected;
          Alcotest.test_case "keyword-named binding as initTelemetry value" `Quick
            t_keyword_shadow_value_rejected;
        ] );
      ( "sound variants stay accepted",
        [ Alcotest.test_case "canonical main" `Quick t_sound_main_accepted;
          Alcotest.test_case "let-chain env threading" `Quick t_let_chain_threading;
          Alcotest.test_case "let-chain threading catches bad type" `Quick
            t_let_chain_threading_bad_type;
          Alcotest.test_case "enqueue statement in main" `Quick
            t_main_enqueue_statement_ok;
          Alcotest.test_case "enqueue bad payload in main rejected" `Quick
            t_main_enqueue_bad_payload_rejected;
        ] );
    ]
