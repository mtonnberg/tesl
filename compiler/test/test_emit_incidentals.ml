(** Emit/checker incidentals from the 2026-07 multi-module matrix batch.

    Five independent bugs fixed together; each case here pins one:

    1. `publish Chan key Notice { … }` with a RECORD payload emitted the
       positional `(Notice v)` — record constructors are keyword-only, so
       EVERY publish of a record-typed sseChannel payload arity-trapped at
       runtime (same-module and cross-module).  Fixed: the EPublish payload
       arm routes record literals through the same `TypeName { … }`
       keyword-ctor arm as everywhere else (emit_racket.ml).  ADT-variant
       payloads keep the positional emit.

    2. `--generate-ts` for a module with an SSE endpoint referenced undefined
       `Unit` / `UnitSchema` names — the whole generated client failed tsc
       (issue #11 was fixed on the Elm side only).  Fixed: Unit maps to
       `void` / a defined tolerant schema (emit_ts.ml).

    3. EmailBody as a DATA type: (a) fn returns trapped at runtime (no
       registered predicate — tesl/email.rkt now registers one); (b) an
       exhaustive 3-arm case was flagged V001 non-exhaustive (EmailBody
       variants now seeded in validation_common.builtin_ctor_info and the
       checker's stdlib_ctors_for_type); (c) EmailBody in ENDPOINT body/
       return positions is now a CHECK-time rejection (no JSON codec) while
       fn params/returns and record fields stay legal.

    4. Partial application in ARGUMENT position (`applyTwice (addN 3) 1`)
       emitted a direct under-applied call — arity trap — while the same
       expression let-bound eta-expanded fine.  Fixed: emit_expr_simple's
       generic application fallback delegates under-application to
       emit_expr's curried-lambda arm.

    5. Newtype record-field codecs: `field -> "k" with_codec stringCodec` on
       a newtype-typed field failed ENCODE (prim encoders now unwrap
       newtype-value — dsl/types.rkt), and `with_codec UserId` failed DECODE
       ("no decoder succeeded" — the emitter now decodes the newtype's base
       prim and applies the constructor; the prim-codec spelling wraps the
       decoded base the same way, restoring §11.6 transparency in BOTH
       directions for BOTH spellings). *)

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

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let assert_contains ~what needle hay =
  if not (contains needle hay) then
    failf "%s: expected output to contain %S\n--- output ---\n%s" what needle hay

let assert_not_contains ~what needle hay =
  if contains needle hay then
    failf "%s: output must NOT contain %S\n--- output ---\n%s" what needle hay

let with_files files f =
  let dir = Filename.temp_dir "tesl-incidental" "" in
  let paths = List.map (fun (name, src) ->
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p
  ) files in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f paths)

let check_ok what path =
  let code, out = run_cc ["--check"; path] in
  if code <> 0 then failf "check of %s must pass:\n%s" what out

let check_fails what path =
  let code, out = run_cc ["--check"; path] in
  if code = 0 then failf "check of %s must FAIL, but passed" what;
  out

let emit_ok what path =
  let code, out = run_cc [path] in
  if code <> 0 then failf "emit of %s failed:\n%s" what out;
  out

(* ── 1. publish with a RECORD payload ───────────────────────────────────── *)

let notice_record = {|record Notice {
  message: String
}

codec Notice {
  toJson {
    message -> "message" with_codec stringCodec
  }
  fromJson [
    {
      message <- "message" with_codec stringCodec
    }
  ]
}
|}

let publish_module ~import_lib ~local_notice = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.SSE exposing [SseChannel]
|} ^ (if import_lib then "import Lib exposing [Notice]\n" else "")
   ^ {|
database MainDb = Database {
  schema: "emit_incidentals"
  entities: []
  backend: Memory
}
|} ^ (if local_notice then notice_record else "") ^ {|
fn parseUserId(id: String) -> String =
  id

capturer userIdCapture: String using stringCodec via parseUserId

sseChannel Notices(userId: String) = SseChannel {
  database: MainDb
  payload: Notice
}

handler sendNotice(msg: String) -> String
  requires [pubsub] =
  publish Notices("u1") Notice { message: msg }
  "ok"

api MainApi {
  post "/send"
    body msg: String
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe Notices(userId)
}

server MainServer for MainApi {
  sendNotice = sendNotice
}
|}

let publish_record_payload_same_module () =
  with_files
    [ ("main.tesl", "#lang tesl\n" ^ publish_module ~import_lib:false ~local_notice:true) ]
    (function
     | [main_p] ->
       check_ok "publish record payload (same-module)" main_p;
       let out = emit_ok "publish record payload (same-module)" main_p in
       (* keyword record ctor, not the positional arity-trap *)
       assert_contains ~what:"same-module publish payload"
         "(publish-event! Notices (format \"~a\" \"u1\") (Notice #:message" out;
       assert_not_contains ~what:"same-module publish payload"
         "(Notice (raw-value" out
     | _ -> assert false)

let publish_record_payload_cross_module () =
  let lib = "#lang tesl\nmodule Lib exposing [Notice]\nimport Tesl.Prelude exposing [String]\nimport Tesl.Json exposing [stringCodec]\n\n" ^ notice_record in
  with_files
    [ ("lib.tesl", lib);
      ("main.tesl", "#lang tesl\n" ^ publish_module ~import_lib:true ~local_notice:false) ]
    (function
     | [_lib_p; main_p] ->
       check_ok "publish record payload (cross-module)" main_p;
       let out = emit_ok "publish record payload (cross-module)" main_p in
       assert_contains ~what:"cross-module publish payload"
         "(Notice #:message" out
     | _ -> assert false)

let publish_adt_payload_stays_positional () =
  let src = {|#lang tesl
module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.SSE exposing [SseChannel]

database MainDb = Database {
  schema: "emit_incidentals_adt"
  entities: []
  backend: Memory
}

type ItemEvent
  = ItemCreated name: String

fn parseUserId(id: String) -> String =
  id

capturer userIdCapture: String using stringCodec via parseUserId

sseChannel ItemEvents(userId: String) = SseChannel {
  database: MainDb
  payload: ItemEvent
}

handler createItem(name: String) -> String
  requires [pubsub] =
  publish ItemEvents("u1") ItemCreated { name: name }
  "ok"

api MainApi {
  post "/items"
    body name: String
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe ItemEvents(userId)
}

server MainServer for MainApi {
  createItem = createItem
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      check_ok "publish ADT payload" main_p;
      let out = emit_ok "publish ADT payload" main_p in
      (* ADT variant ctors are positional lambdas — the record keyword arm
         must NOT hijack them. *)
      assert_contains ~what:"ADT publish payload" "(ItemCreated " out;
      assert_not_contains ~what:"ADT publish payload" "(ItemCreated #:name" out
    | _ -> assert false)

(* ── 2. --generate-ts: SSE endpoint and Unit ────────────────────────────── *)

let ts_sse_unit_defined () =
  let src = {|#lang tesl
module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.SSE exposing [SseChannel]

database MainDb = Database {
  schema: "emit_incidentals_ts"
  entities: []
  backend: Memory
}

type ItemEvent
  = ItemCreated name: String

fn parseUserId(id: String) -> String =
  id

capturer userIdCapture: String using stringCodec via parseUserId

sseChannel ItemEvents(userId: String) = SseChannel {
  database: MainDb
  payload: ItemEvent
}

handler ping() -> String =
  "pong"

api MainApi {
  get "/ping"
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe ItemEvents(userId)
}

server MainServer for MainApi {
  ping = ping
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let code, out = run_cc ["--generate-ts"; main_p] in
      if code <> 0 then failf "--generate-ts must succeed:\n%s" out;
      (* the #11 class, TS side: every referenced name must be defined *)
      assert_not_contains ~what:"generated TS" "UnitSchema" out;
      assert_not_contains ~what:"generated TS" "Promise<Unit>" out;
      assert_contains ~what:"generated TS" "Promise<void>" out
    | _ -> assert false)

(* ── 3. EmailBody as a data type ────────────────────────────────────────── *)

let emailbody_exhaustive_case_accepted () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

fn bodyKind(b: EmailBody) -> String =
  case b of
    TextBody t -> "text"
    HtmlBody h -> "html"
    RichBody t h -> "rich"
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      (* pre-fix: V001 "non-exhaustive case: nested constructor/literal
         patterns leave uncovered values" despite all 3 arms *)
      check_ok "exhaustive EmailBody case" main_p;
      let out = emit_ok "exhaustive EmailBody case" main_p in
      (* tagged-LIST pattern lowering, not the adt-value struct guard that
         can never match an EmailBody value *)
      assert_contains ~what:"EmailBody pattern guard" "(car " out;
      assert_contains ~what:"EmailBody pattern guard" "'TextBody" out
    | _ -> assert false)

let emailbody_missing_arm_rejected () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

fn bodyKind(b: EmailBody) -> String =
  case b of
    TextBody t -> "text"
    HtmlBody h -> "html"
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "EmailBody case missing RichBody" main_p in
      assert_contains ~what:"missing-arm diagnostic" "RichBody" out;
      assert_contains ~what:"missing-arm diagnostic" "non-exhaustive" out
    | _ -> assert false)

let emailbody_endpoint_positions_rejected () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String, Unit]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

handler echoBody(b: EmailBody) -> EmailBody =
  b

handler giveBody() -> EmailBody =
  TextBody "hi"

api A {
  post "/body"
    body b: EmailBody
    -> EmailBody

  get "/body"
    -> EmailBody
}

server S for A {
  echoBody = echoBody
  giveBody = giveBody
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "EmailBody endpoint types" main_p in
      assert_contains ~what:"endpoint rejection" "cannot cross the HTTP boundary" out
    | _ -> assert false)

(* Item 10 (review 2026-07-09): the name-level endpoint rejection missed
   NESTED exposure — a wire-positioned record whose field (transitively)
   carries EmailBody passed check and serialized garbage at runtime.  Three
   surfaces: endpoint return of a wrapping record (path chain named), an
   sseChannel payload, and a queue job record. *)
let emailbody_nested_record_endpoint_rejected () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

record Wrapped {
  note: String
  payload: EmailBody
}

record Outer {
  inner: Wrapped
}

handler wrapped() -> Wrapped =
  Wrapped { note: "n", payload: TextBody "hello" }

handler outer() -> Outer =
  Outer { inner: Wrapped { note: "n", payload: TextBody "hello" } }

api A {
  get "/wrapped"
    -> Wrapped
  get "/outer"
    -> Outer
}

server S for A {
  wrapped = wrapped
  outer = outer
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "nested EmailBody endpoint types" main_p in
      assert_contains ~what:"nested rejection" "cannot cross the HTTP boundary" out;
      (* the offending path is named, record + field, chained when deep *)
      assert_contains ~what:"nested rejection path" "`Wrapped.payload`" out;
      assert_contains ~what:"deep rejection path" "`Outer.inner`" out
    | _ -> assert false)

let emailbody_sse_payload_rejected () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

entity E table "wire_es" primaryKey id {
  id: String
}

database D = Database {
  entities: [E]
  backend: Memory
}

record Note {
  body: EmailBody
}

sseChannel Nested(userId: String) = SseChannel {
  database: D
  payload: Note
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "EmailBody sse payload" main_p in
      assert_contains ~what:"sse payload rejection" "cannot cross the HTTP boundary" out;
      assert_contains ~what:"sse payload rejection path" "`Note.body`" out
    | _ -> assert false)

let emailbody_job_record_rejected () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]
import Tesl.Queue exposing [FromQueue, queueRead, Queue, Job, QueueRetryStrategy, Fixed]
import Tesl.Maybe exposing [Maybe(..)]

entity E table "wire_qes" primaryKey id {
  id: String
}

database D = Database {
  entities: [E]
  backend: Memory
}

record MailJob {
  to: String
  body: EmailBody
}

queue MailQueue requires [queueRead] = Queue {
  database: D
  jobs: [Job MailJob handleMail Nothing]
  retry: QueueRetryStrategy {
    maxAttempts: 2
    backoff: Fixed
    initialDelay: 1
  }
}

worker handleMail(job: MailJob ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  job
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "EmailBody job record" main_p in
      assert_contains ~what:"job record rejection" "cannot cross the HTTP boundary" out;
      assert_contains ~what:"job record rejection path" "`MailJob.body`" out
    | _ -> assert false)

let emailbody_data_positions_stay_legal () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

record Draft {
  to: String
  body: EmailBody
}

fn mkBody(name: String) -> EmailBody =
  RichBody "hi ${name}" "<b>hi ${name}</b>"

fn wrap(b: EmailBody) -> Draft =
  Draft { to: "a@example.com", body: b }
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      (* fn param/return and record field must STAY legal — EmailBody is a
         real data type; only the HTTP boundary rejects it. *)
      check_ok "EmailBody in data positions" main_p;
      ignore (emit_ok "EmailBody in data positions" main_p)
    | _ -> assert false)

(* ── 4. partial application in argument position ────────────────────────── *)

let partial_application_argument_position () =
  let src = {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit]

fn addN(a: Int, b: Int) -> Int =
  a + b

fn applyTwice(f: Int -> Int, n: Int) -> Int =
  f (f n)

test "partial application in argument position" {
  expect applyTwice (addN 3) 1 == 7
}

test "named partial application" {
  let addTen = addN 10
  expect addTen 5 == 15
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      check_ok "partial application" main_p;
      let out = emit_ok "partial application" main_p in
      (* argument position must eta-expand exactly like the let-bound path *)
      assert_contains ~what:"arg-position partial application"
        "(applyTwice (lambda (tesl-p-" out;
      assert_not_contains ~what:"arg-position partial application"
        "(applyTwice (addN 3) 1)" out
    | _ -> assert false)

(* ── 5. newtype record-field codec, both spellings ──────────────────────── *)

let newtype_codec_module ~id_codec = Printf.sprintf {|#lang tesl
module Main exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec]

type UserId = String

record User {
  id: UserId
  name: String
}

codec User {
  toJson {
    id -> "id" with_codec %s
    name -> "name" with_codec stringCodec
  }
  fromJson [
    {
      id <- "id" with_codec %s
      name <- "name" with_codec stringCodec
    }
  ]
}
|} id_codec id_codec

let newtype_field_prim_codec_spelling () =
  with_files [ ("main.tesl", newtype_codec_module ~id_codec:"stringCodec") ]
    (function
     | [main_p] ->
       check_ok "newtype field, stringCodec spelling" main_p;
       let out = emit_ok "newtype field, stringCodec spelling" main_p in
       (* decode wraps the decoded base prim in the newtype constructor *)
       assert_contains ~what:"decode wrap"
         "(define _f_id (UserId (tesl-decode-prim-field _j \"id\" tesl-decode-prim-string)))" out;
       (* the non-newtype sibling field is untouched *)
       assert_contains ~what:"plain field decode"
         "(define _f_name (tesl-decode-prim-field _j \"name\" tesl-decode-prim-string))" out;
       (* encode keeps the historical prim call — unwrap lives in the runtime
          prim encoder (tesl-prim-encode-base, dsl/types.rkt) *)
       assert_contains ~what:"encode call"
         "(tesl-encode-prim-string (raw-value (hash-ref _fields 'id)))" out
     | _ -> assert false)

let newtype_field_newtype_codec_spelling () =
  with_files [ ("main.tesl", newtype_codec_module ~id_codec:"UserId") ]
    (function
     | [main_p] ->
       check_ok "newtype field, with_codec UserId spelling" main_p;
       let out = emit_ok "newtype field, with_codec UserId spelling" main_p in
       (* pre-fix: `(tesl-codec-decode-field _j "id" 'UserId)` — no registry
          decoder exists for a newtype, so every decode failed *)
       assert_contains ~what:"decode wrap"
         "(define _f_id (UserId (tesl-decode-prim-field _j \"id\" tesl-decode-prim-string)))" out;
       assert_not_contains ~what:"decode wrap"
         "(tesl-codec-decode-field _j \"id\" 'UserId)" out
     | _ -> assert false)

(* ── 6. imported-module test submodules (silent-pass class) ─────────────────
   `raco test main.rkt` instantiates only main's `test` submodule, so a failing
   test/api-test/load-test block in an imported module passed silently.  The
   emitter now requires each DIRECT local import's test submodule inside the
   importing module's own test submodule — gated on the dep declaring a
   test-ish decl directly OR TRANSITIVELY (exactly the condition under which
   the dep's emitted .rkt has a test submodule; a dep with a fully testless
   closure emits none, so an unconditional require would fail to resolve) and
   suppressed under --test-name single-block selection.  The sandwich case
   (testless middle module) is pinned in section 7
   (transitive_dep_tests_compose). *)

let dep_with_test = {|#lang tesl
module Lib exposing [add]

import Tesl.Prelude exposing [Int]

fn add(a: Int, b: Int) -> Int =
  a + b

test "lib unit" {
  expect add 1 1 == 2
}
|}

let dep_without_test = {|#lang tesl
module Lib exposing [add]

import Tesl.Prelude exposing [Int]

fn add(a: Int, b: Int) -> Int =
  a + b
|}

let main_importing_lib = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import Lib exposing [add]

test "main unit" {
  expect add 2 2 == 4
}
|}

let dep_test_submodule_required () =
  with_files
    [ ("lib.tesl", dep_with_test); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let out = emit_ok "main importing lib-with-tests" main_p in
       assert_contains ~what:"dep test submodule require"
         "(require (submod (file \"lib.rkt\") test))" out
     | _ -> assert false)

let dep_without_tests_not_required () =
  with_files
    [ ("lib.tesl", dep_without_test); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let out = emit_ok "main importing testless lib" main_p in
       (* a LEAF testless dep (testless transitive closure) emits NO test
          submodule — requiring it would be a resolve error at raco test
          time.  A testless MIDDLE module (transitively tested deps) DOES —
          see transitive_dep_tests_compose. *)
       assert_not_contains ~what:"testless dep gate"
         "(submod (file \"lib.rkt\") test)" out
     | _ -> assert false)

let dep_doctest_counts_as_tests () =
  let lib = {|#lang tesl
module Lib exposing [add]

import Tesl.Prelude exposing [Int]

#> add 1 1
#= 2
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  with_files
    [ ("lib.tesl", lib); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let out = emit_ok "main importing doctest-only lib" main_p in
       (* doctests are synthesized DTest decls at parse time, so the dep DOES
          emit a test submodule — the gate must include them *)
       assert_contains ~what:"doctest-only dep"
         "(require (submod (file \"lib.rkt\") test))" out
     | _ -> assert false)

let single_test_selection_skips_dep_requires () =
  with_files
    [ ("lib.tesl", dep_with_test); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let code, out =
         run_cc ["--test-name"; "main unit"; "--test-kind"; "test"; main_p] in
       if code <> 0 then failf "single-test emit failed:\n%s" out;
       (* --test-name means "run exactly this block of THIS entry file" *)
       assert_not_contains ~what:"single-test selection"
         "(submod (file \"lib.rkt\") test)" out;
       assert_contains ~what:"single-test selection keeps the named block"
         "main unit" out
     | _ -> assert false)

(* ── 7. REVIEW2 batch (2026-07-09) ──────────────────────────────────────────
   One case per confirmed finding fixed in this batch; see the per-case
   comments for the pre-fix failure mode. *)

(** Repo root (for TESL_REPO_ROOT when invoking raco): env override, else walk
    up from cwd looking for a directory containing `compiler/`. *)
let repo_root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name else find parent
    in
    find (Sys.getcwd ())

let run_shell cmd =
  let ic = Unix.open_process_in (cmd ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let racket_available = lazy (fst (run_shell "command -v raco") = 0)

let write_file path content =
  let oc = open_out path in output_string oc content; close_out oc

(* ITEM 4 (require filter): the ~700-name config-only require filter
   (currency ctors All/Try/Top, timezone ctors, SI aliases) applied to LOCAL
   imports too — a user record named `All` exported by a local module had its
   require binding silently dropped, so the check-green program crashed at
   load with "All: unbound identifier".  The filter is now scoped to Tesl.*
   stdlib imports only. *)
let local_export_named_like_currency_ctor () =
  let dep = {|#lang tesl
module Dep exposing [All]

import Tesl.Prelude exposing [Int]

record All {
  x: Int
}
|} in
  let main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Bool(..), Int]
import Dep exposing [All]

fn getX() -> Int =
  let a = All { x: 4 }
  a.x

test "record named All" {
  expect getX() == 4
}
|} in
  with_files
    [ ("dep.tesl", dep); ("main.tesl", main) ]
    (function
     | [_dep_p; main_p] ->
       check_ok "local `All` export" main_p;
       let out = emit_ok "main importing record All" main_p in
       (* pre-fix: the require disappeared entirely (All was its only binding) *)
       assert_contains ~what:"local-module require not filtered"
         "(only-in (file \"dep.rkt\") All" out
     | _ -> assert false)

(* ITEM 1 (capability implies): `capability admin implies cacheCap Sessions`
   rendered the implies list via raw String.concat — two identifiers, the
   first (`cacheCap`) unbound at raco make.  Now rendered through cap_ident;
   and a DCapability implies naming an IMPORTED module's cache both counts as
   a cache USE (tesl/tesl/cache require) and gets the synthesized
   cacheCap_<Name> define. *)
let cap_implies_cache_cap_local = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Nothing, Something]
import Tesl.Database exposing [Database, Memory]
import Tesl.Cache exposing [Cache]

database TestDB = Database {
  schema: "public"
  entities: []
  backend: Memory
}

cache Sessions = Cache {
  database: TestDB
  defaultTtl: 3600
  valueType: String
}

capability admin implies cacheCap Sessions

fn getSession(k: String) -> Maybe String requires [admin] =
  Cache.get Sessions (k)
|}

let cap_implies_renders_cache_cap_ident () =
  with_files
    [ ("main.tesl", cap_implies_cache_cap_local) ]
    (function
     | [main_p] ->
       check_ok "capability implies cacheCap (local cache)" main_p;
       let out = emit_ok "capability implies cacheCap" main_p in
       assert_contains ~what:"implies via cap_ident"
         "(define-capability admin (implies cacheCap_Sessions))" out;
       assert_not_contains ~what:"implies via cap_ident"
         "(implies cacheCap Sessions)" out
     | _ -> assert false)

let cap_implies_imported_cache_lib = {|#lang tesl
module CacheLib exposing [TestDB, Sessions, getSession]

import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Nothing, Something]
import Tesl.Database exposing [Database, Memory]
import Tesl.Cache exposing [Cache]

database TestDB = Database {
  schema: "public"
  entities: []
  backend: Memory
}

cache Sessions = Cache {
  database: TestDB
  defaultTtl: 3600
  valueType: String
}

fn getSession(k: String) -> Maybe String requires [cacheCap Sessions] =
  Cache.get Sessions (k)
|}

let cap_implies_imported_cache_main = {|#lang tesl
module Main exposing [fetch]

import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe, Nothing, Something]
import CacheLib exposing [getSession]

capability admin implies cacheCap Sessions

fn fetch(k: String) -> Maybe String requires [admin] =
  getSession k
|}

let cap_implies_imported_cache_synthesized () =
  with_files
    [ ("cache-lib.tesl", cap_implies_imported_cache_lib);
      ("main.tesl", cap_implies_imported_cache_main) ]
    (function
     | [_lib_p; main_p] ->
       check_ok "capability implies imported cacheCap" main_p;
       let out = emit_ok "capability implies imported cacheCap" main_p in
       (* the implies mention must synthesize the capability VALUE binding … *)
       assert_contains ~what:"synthesized cacheCap define"
         "(define cacheCap_Sessions (cache-spec-capability (cache-for-name 'Sessions)))" out;
       (* … and count as a cache USE so cache-for-name is require-bound *)
       assert_contains ~what:"cache runtime require" "tesl/tesl/cache" out;
       assert_contains ~what:"implies via cap_ident"
         "(define-capability admin (implies cacheCap_Sessions))" out
     | _ -> assert false)

(* ITEM 3 (2-arg Job): `jobs: [Job PingJob handlePing]` type-checked green but
   desugar's job_entries only extracts the documented 3-arg shape
   (LANGUAGE-SPEC §queues: `Job <JobType> <workerFn> <dead-slot>`), so the
   queue emitted `#:job-types ()` and every enqueue failed at RUNTIME.  The
   2-arg spelling is now a CHECK-time rejection. *)
let two_arg_job_src dead_slot = Printf.sprintf {|#lang tesl
module Main exposing [submit]

import Tesl.Prelude exposing [String, Int, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, Job, queueWrite, queueRead]

database QDb = Database {
  backend: Memory
  entities: []
}

record PingJob {
  msg: String
}

queue PingQueue = Queue {
  database: QDb
  jobs: [Job PingJob handlePing%s]
}

fn handlePing(j: PingJob) -> String
  requires [] =
  j.msg

fn submit(m: String) -> Unit
  requires [queueWrite] =
  enqueue PingJob { msg: m }
|} dead_slot

let two_arg_job_rejected () =
  with_files
    [ ("main.tesl", two_arg_job_src "") ]
    (function
     | [main_p] ->
       let out = check_fails "2-arg Job entry" main_p in
       assert_contains ~what:"2-arg Job diagnostic"
         "a `Job` entry takes exactly three arguments" out
     | _ -> assert false);
  (* control: the documented 3-arg spelling stays green *)
  with_files
    [ ("main.tesl", two_arg_job_src " Nothing") ]
    (function
     | [main_p] -> check_ok "3-arg Job entry" main_p
     | _ -> assert false)

(* ITEM 2 (lazy job-type-refs): define-queue minted nominal job-type-refs at
   MACRO EXPANSION time, so a job record declared AFTER its queue in the same
   module was unbound at that point and silently degraded to a bare-symbol
   (spelling-routed) entry — the DESIGN-4/#41 misroute backstop self-disabled
   conditionally on textual declaration order.  The refs are now a promise
   minted on first access from quote-syntax'd identifiers, which resolve
   against the FULLY EXPANDED module.  Probed at runtime via the domain
   registry: queue-before-record must yield type-ref entries. *)
let queue_first_src = {|#lang tesl
module Main exposing [submit]

import Tesl.Prelude exposing [String, Int, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, Job, queueWrite, queueRead]

database QDb = Database {
  backend: Memory
  entities: []
}

queue PingQueue = Queue {
  database: QDb
  jobs: [Job PingJob handlePing Nothing]
}

record PingJob {
  msg: String
}

fn handlePing(j: PingJob) -> String
  requires [] =
  j.msg

fn submit(m: String) -> Unit
  requires [queueWrite] =
  enqueue PingJob { msg: m }
|}

let queue_first_nominal_refs () =
  if not (Lazy.force racket_available) then ()
  else
    with_files
      [ ("main.tesl", queue_first_src) ]
      (function
       | [main_p] ->
         let dir = Filename.dirname main_p in
         let out = emit_ok "queue-before-record module" main_p in
         (* the queue decl PRECEDES the record decl in queue_first_src — the
            degraded order pre-fix *)
         write_file (Filename.concat dir "main.rkt") out;
         let probe = Printf.sprintf {|#lang racket
(require (only-in (file "main.rkt"))
         (only-in tesl/tesl/queue queue-spec-job-type-refs)
         (only-in tesl/dsl/types type-ref?)
         (only-in tesl/dsl/private/domain-registry domain-registry-of-kind))
(for ([s (in-list (domain-registry-of-kind 'queues))])
  (printf "nominal=~a\n"
          (andmap type-ref? (queue-spec-job-type-refs s))))
|} in
         write_file (Filename.concat dir "probe.rkt") probe;
         let code, pout =
           run_shell (Printf.sprintf "cd %s && TESL_REPO_ROOT=%s racket probe.rkt"
                        (Filename.quote dir) (Filename.quote repo_root)) in
         if code <> 0 then failf "queue-first probe failed:\n%s" pout;
         assert_contains ~what:"queue-first nominal refs" "nominal=#t" pout;
         assert_not_contains ~what:"queue-first nominal refs" "nominal=#f" pout
       | _ -> assert false)

(* ITEM 9 (transitive dep tests): main→A(no tests)→B(failing test) — the
   dep-test-submodule require was gated on the DIRECT import's own decls, so
   A was skipped and B's failing test never ran ("1 test passed", exit 0).
   The gate is now "declares tests directly OR transitively", which is
   exactly the condition under which the dep's emitted .rkt has a test
   submodule (a testless middle module still emits one that pulls its own
   deps' test submodules). *)
let sandwich_lib_b = {|#lang tesl
module LibB exposing [double]

import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int =
  n * 2

test "deliberately failing" {
  expect double 2 == 5
}
|}

let sandwich_lib_a = {|#lang tesl
module LibA exposing [quad]

import Tesl.Prelude exposing [Int]
import LibB exposing [double]

fn quad(n: Int) -> Int =
  double (double n)
|}

let sandwich_main = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int]
import LibA exposing [quad]

test "main unit" {
  expect quad 1 == 4
}
|}

let transitive_dep_tests_compose () =
  with_files
    [ ("lib-b.tesl", sandwich_lib_b);
      ("lib-a.tesl", sandwich_lib_a);
      ("main.tesl", sandwich_main) ]
    (function
     | [lib_b_p; lib_a_p; main_p] ->
       let dir = Filename.dirname main_p in
       let a_out = emit_ok "testless middle module" lib_a_p in
       (* the testless MIDDLE module emits a test submodule pulling B's *)
       assert_contains ~what:"middle module test submodule"
         "(require (submod (file \"lib-b.rkt\") test))" a_out;
       let main_out = emit_ok "sandwich main" main_p in
       (* main gates on A's TRANSITIVE closure, not A's own (empty) decls *)
       assert_contains ~what:"transitive dep-test gate"
         "(require (submod (file \"lib-a.rkt\") test))" main_out;
       if Lazy.force racket_available then begin
         write_file (Filename.concat dir "lib-b.rkt") (emit_ok "lib-b" lib_b_p);
         write_file (Filename.concat dir "lib-a.rkt") a_out;
         write_file (Filename.concat dir "main.rkt") main_out;
         let code, out =
           run_shell (Printf.sprintf "cd %s && TESL_REPO_ROOT=%s raco test main.rkt"
                        (Filename.quote dir) (Filename.quote repo_root)) in
         (* B's failing test must FAIL main's raco test (pre-fix: exit 0) *)
         if code = 0 then
           failf "sandwich raco test must fail via LibB's failing test:\n%s" out;
         assert_contains ~what:"B's test ran" "test failures" out
       end
     | _ -> assert false)

(* ITEM 11 (qualified partial application): `applyTwice (PartialLib.addN 3) 1`
   — is_under_applied matched bare EVar heads only, so the qualified twin of
   the fixed bug still emitted a direct under-applied call (runtime arity
   trap) while the let-bound spelling eta-expanded fine. *)
let qualified_partial_lib = {|#lang tesl
module PartialLib exposing [addN]

import Tesl.Prelude exposing [Int]

fn addN(a: Int, b: Int) -> Int =
  a + b
|}

let qualified_partial_main = {|#lang tesl
module Main exposing [applyTwice]

import Tesl.Prelude exposing [Bool(..), Int]
import PartialLib

fn applyTwice(f: Int -> Int, n: Int) -> Int =
  f (f n)

test "qualified partial application in argument position" {
  expect applyTwice (PartialLib.addN 3) 1 == 7
}
|}

let qualified_partial_application_eta_expands () =
  with_files
    [ ("partial-lib.tesl", qualified_partial_lib);
      ("main.tesl", qualified_partial_main) ]
    (function
     | [_lib_p; main_p] ->
       let out = emit_ok "qualified partial application" main_p in
       (* pre-fix: `(applyTwice (addN 3) 1)` — direct under-applied call *)
       assert_not_contains ~what:"qualified under-application delegated"
         "(applyTwice (addN 3) 1)" out;
       assert_contains ~what:"qualified under-application eta-expands"
         "(lambda (tesl-p-" out
     | _ -> assert false)

(* ITEM 12 (Money/PosixMillis newtype field decode): moneyCodec was missing
   from base_of_prim_codec (a Money-newtype field stayed unwrapped after
   decode), and the `with_codec <Newtype>` arm had no decoder for Money /
   PosixMillis bases, so it applied the constructor to the RAW jsexpr.
   PosixMillis is itself a runtime newtype, so its decode additionally wraps
   the BASE constructor. *)
let money_posix_newtype_codecs = {|#lang tesl
module Main exposing []

import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, moneyCodec]
import Tesl.Money exposing [Money]
import Tesl.Time exposing [PosixMillis]

type Price = Money

record Item {
  price: Price
}

codec Item {
  toJson {
    price -> "price" with_codec moneyCodec
  }
  fromJson [
    {
      price <- "price" with_codec moneyCodec
    }
  ]
}

type Cost = Money

record Order {
  cost: Cost
}

codec Order {
  toJson {
    cost -> "cost" with_codec Cost
  }
  fromJson [
    {
      cost <- "cost" with_codec Cost
    }
  ]
}

type Stamp = PosixMillis

record Event {
  at: Stamp
}

codec Event {
  toJson {
    at -> "at" with_codec Stamp
  }
  fromJson [
    {
      at <- "at" with_codec Stamp
    }
  ]
}
|}

let money_posix_newtype_decode_wraps () =
  with_files
    [ ("main.tesl", money_posix_newtype_codecs) ]
    (function
     | [main_p] ->
       check_ok "money/posix newtype codecs" main_p;
       let out = emit_ok "money/posix newtype codecs" main_p in
       (* prim-codec spelling: decode then wrap in the newtype ctor *)
       assert_contains ~what:"moneyCodec spelling wraps"
         "(Price (tesl-codec-decode-field _j \"price\" tesl-json-money-codec))" out;
       (* newtype-name spelling, Money base: decode via the money prim *)
       assert_contains ~what:"Money-newtype spelling decodes base"
         "(Cost (tesl-decode-prim-field _j \"cost\" tesl-decode-prim-money))" out;
       (* newtype-name spelling, PosixMillis base: decode + BASE ctor wrap *)
       assert_contains ~what:"PosixMillis-newtype spelling wraps base ctor"
         "(Stamp (PosixMillis (tesl-decode-prim-field _j \"at\" tesl-decode-prim-posix-millis)))" out;
       (* pre-fix raw-jsexpr shapes must be gone *)
       assert_not_contains ~what:"raw jsexpr into newtype ctor"
         "(Cost (jsexpr-required-field" out;
       assert_not_contains ~what:"raw jsexpr into newtype ctor"
         "(Stamp (jsexpr-required-field" out
     | _ -> assert false)

(* ITEM 17 (asTool shadowing): a module declaring its own `fn asTool` — the
   checker blesses the shadow (builtin form inert), but the broadened emit
   guard claimed every asTool-headed application and crashed with the
   issue-#24 "please report this bug" failwith in argument position.  Under
   the shadow predicate both emit paths now treat it as an ordinary call. *)
let astool_shadow_src = {|#lang tesl
module Main exposing [run]

import Tesl.Prelude exposing [Int]

fn asTool(n: Int) -> Int = n + 1

fn double(n: Int) -> Int = n * 2

fn run() -> Int = double (asTool 20)
|}

let astool_shadow_emits_plain_call () =
  with_files
    [ ("main.tesl", astool_shadow_src) ]
    (function
     | [main_p] ->
       check_ok "shadowed asTool" main_p;
       (* pre-fix: emit exited 1 with the issue-#24 failwith *)
       let out = emit_ok "shadowed asTool" main_p in
       assert_contains ~what:"ordinary call to the user's asTool"
         "(double (asTool 20))" out
     | _ -> assert false)

let tests = [
  test_case "publish record payload emits keyword ctor (same-module)" `Quick publish_record_payload_same_module;
  test_case "publish record payload emits keyword ctor (cross-module)" `Quick publish_record_payload_cross_module;
  test_case "publish ADT payload stays positional" `Quick publish_adt_payload_stays_positional;
  test_case "--generate-ts SSE endpoint references only defined names" `Quick ts_sse_unit_defined;
  test_case "exhaustive EmailBody case accepted + list-shape lowering" `Quick emailbody_exhaustive_case_accepted;
  test_case "EmailBody case missing arm rejected" `Quick emailbody_missing_arm_rejected;
  test_case "EmailBody endpoint body/return rejected at check time" `Quick emailbody_endpoint_positions_rejected;
  test_case "nested EmailBody record rejected in endpoint positions (item 10)" `Quick emailbody_nested_record_endpoint_rejected;
  test_case "EmailBody sseChannel payload rejected (item 10)" `Quick emailbody_sse_payload_rejected;
  test_case "EmailBody queue-job record rejected (item 10)" `Quick emailbody_job_record_rejected;
  test_case "EmailBody stays legal in fn/record data positions" `Quick emailbody_data_positions_stay_legal;
  test_case "partial application in argument position eta-expands" `Quick partial_application_argument_position;
  test_case "newtype field codec: prim spelling wraps decode" `Quick newtype_field_prim_codec_spelling;
  test_case "newtype field codec: newtype-name spelling decodes via base" `Quick newtype_field_newtype_codec_spelling;
  test_case "dep test submodule required when dep declares tests" `Quick dep_test_submodule_required;
  test_case "testless dep gets no test-submodule require" `Quick dep_without_tests_not_required;
  test_case "doctest-only dep counts as declaring tests" `Quick dep_doctest_counts_as_tests;
  test_case "--test-name selection skips dep test-submodule requires" `Quick single_test_selection_skips_dep_requires;
  (* REVIEW2 batch (2026-07-09) *)
  test_case "local export named like a currency ctor keeps its require" `Quick local_export_named_like_currency_ctor;
  test_case "capability implies cacheCap renders via cap_ident" `Quick cap_implies_renders_cache_cap_ident;
  test_case "capability implies imported cacheCap synthesizes the value" `Quick cap_implies_imported_cache_synthesized;
  test_case "2-arg Job entry rejected at check time" `Quick two_arg_job_rejected;
  test_case "queue-before-record still mints nominal job-type-refs" `Quick queue_first_nominal_refs;
  test_case "transitive dep tests compose through a testless middle module" `Quick transitive_dep_tests_compose;
  test_case "qualified partial application in argument position eta-expands" `Quick qualified_partial_application_eta_expands;
  test_case "Money/PosixMillis newtype field decode wraps" `Quick money_posix_newtype_decode_wraps;
  test_case "user-shadowed asTool emits an ordinary call" `Quick astool_shadow_emits_plain_call;
]

let () =
  run "Emit-Incidentals" [ ("matrix-2026-07-batch", tests) ]
