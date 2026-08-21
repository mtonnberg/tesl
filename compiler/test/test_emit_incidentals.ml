(** Emit/checker incidentals from the 2026-07 multi-module matrix batch.

    Five independent bugs fixed together; each case here pins one:

    1. `publish Chan key Notice { … }` with a RECORD payload emitted the
       positional `(Notice v)` — record constructors are keyword-only, so
       EVERY publish of a record-typed sseChannel payload arity-trapped at
       runtime (same-module and cross-module).  Fixed: the EPublish payload
       arm routes record literals through the same `TypeName { … }`
       record-construction arm. ADT variants keep their distinct Go shape.

    2. `--generate-ts` for a module with an SSE endpoint referenced undefined
       `Unit` / `UnitSchema` names — the whole generated client failed tsc
       (issue #11 was fixed on the Elm side only).  Fixed: Unit maps to
       `void` / a defined tolerant schema (emit_ts.ml).

    3. EmailBody as a DATA type: (a) fn returns must emit; (b) an
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
       the value), and `with_codec UserId` failed DECODE
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

let go_artifacts what path =
  match Compile.compile_go_file path with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics ->
    failf "Go emit of %s failed:\n%s" what
      (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let emit_ok what path =
  go_artifacts what path
  |> List.map (fun (a : Emit_go.artifact) -> a.contents)
  |> String.concat "\n"

let rec mkdir_p path =
  if path = "" || path = Filename.current_dir_name || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path

let run_go_tests ?(env="") ?(expect_success=true) what artifacts =
  if Sys.command "go version >/dev/null 2>&1" = 0 then begin
    let root = Filename.temp_dir "tesl-incidental-go" "" in
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
      List.iter (fun (a : Emit_go.artifact) ->
        let path = Filename.concat root a.path in
        mkdir_p (Filename.dirname path);
        Out_channel.with_open_bin path (fun oc -> output_string oc a.contents)) artifacts;
      let command = Printf.sprintf "cd %s && %s go test -count=1 ./... 2>&1"
          (Filename.quote root) env in
      let ic = Unix.open_process_in command in
      let out = In_channel.input_all ic in
      let code = match Unix.close_process_in ic with
        | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
      if expect_success && code <> 0 then failf "%s: generated Go tests failed:\n%s" what out;
      if not expect_success && code = 0 then failf "%s: generated Go tests unexpectedly passed" what)
  end

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

handler post sendNotice(msg: String) -> String
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
  sendNotice
}
|}

let publish_record_payload_same_module () =
  with_files
    [ ("main.tesl", "" ^ publish_module ~import_lib:false ~local_notice:true) ]
    (function
     | [main_p] ->
       check_ok "publish record payload (same-module)" main_p;
       let out = emit_ok "publish record payload (same-module)" main_p in
       (* Record payload remains a typed composite literal before encoding. *)
       assert_contains ~what:"same-module publish payload"
         "teslrt.Publish(NoticesChannel, \"u1\", EncodeNoticeJSON(Notice{Message: msg}))" out;
       assert_not_contains ~what:"same-module publish payload"
         "EncodeNoticeJSON(Notice(msg))" out
     | _ -> assert false)

let publish_record_payload_cross_module () =
  let lib = "module Lib exposing [Notice]\nimport Tesl.Prelude exposing [String]\nimport Tesl.Json exposing [stringCodec]\n\n" ^ notice_record in
  with_files
    [ ("lib.tesl", lib);
      ("main.tesl", "" ^ publish_module ~import_lib:true ~local_notice:false) ]
    (function
     | [_lib_p; main_p] ->
       check_ok "publish record payload (cross-module)" main_p;
       let out = emit_ok "publish record payload (cross-module)" main_p in
       assert_contains ~what:"cross-module publish payload"
         "teslmodlib.Notice{Message: msg}" out
     | _ -> assert false)

let publish_adt_payload_stays_positional () =
  let src = {|module Main exposing [MainServer]
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

handler post createItem(name: String) -> String
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
  createItem
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      check_ok "publish ADT payload" main_p;
      let out = emit_ok "publish ADT payload" main_p in
       (* ADT payload uses the variant payload field, not the record field. *)
       assert_contains ~what:"ADT publish payload"
         "teslrt.Publish(ItemEventsChannel, \"u1\", teslEncode2(ItemEvent{ItemCreatedName: name}))" out;
       assert_not_contains ~what:"ADT publish payload" "ItemEvent{Message:" out
    | _ -> assert false)

(* ── 2. --generate-ts: SSE endpoint and Unit ────────────────────────────── *)

let ts_sse_unit_defined () =
  let src = {|module Main exposing [MainServer]
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

handler get ping() -> String =
  "pong"

api MainApi {
  get "/ping"
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe ItemEvents(userId)
}

server MainServer for MainApi {
  ping
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
  let src = {|module Main exposing []
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
       assert_contains ~what:"EmailBody pattern switch" "switch teslScrut1.Tag" out;
       assert_contains ~what:"EmailBody Text arm" "case teslrt.EmailBodyText:" out;
       assert_contains ~what:"EmailBody Rich arm" "case teslrt.EmailBodyRich:" out
    | _ -> assert false)

let emailbody_missing_arm_rejected () =
  let src = {|module Main exposing []
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
  let src = {|module Main exposing []
import Tesl.Prelude exposing [String, Unit]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

handler post echoBody(b: EmailBody) -> EmailBody =
  b

handler get giveBody() -> EmailBody =
  TextBody "hi"

api A {
  post "/body"
    body b: EmailBody
    -> EmailBody

  get "/body"
    -> EmailBody
}

server S for A {
  echoBody
  giveBody
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "EmailBody endpoint types" main_p in
      assert_contains ~what:"endpoint rejection" "cannot cross the HTTP boundary" out
    | _ -> assert false)

(* GitHub #60: `JsonValue` (Tesl.ApiTest) was only ever built to inspect a
   response body inside `api-test` assertions — it has no runtime predicate/
   decoder for production use, so it type-checked cleanly as a handler body/
   return type and then 400'd on every real request. The checker now rejects
   it in every production type position (handler param/return, endpoint
   body/return) while still allowing it inside `api-test` blocks, which are a
   different decl kind this check never walks. *)
let jsonvalue_production_positions_rejected () =
  let src = {|module Main exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.ApiTest exposing [statusOk, JsonValue]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

handler post echoJson(body: JsonValue) -> JsonValue = body

api EchoApi { post "/echo" body payload: JsonValue -> JsonValue }

server EchoServer for EchoApi { echoJson }

database EchoDb = Database { entities: [] backend: Memory }

main() -> App = App { database: EchoDb api: EchoServer port: 8099 }
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
      let out = check_fails "JsonValue production positions" main_p in
      assert_contains ~what:"JsonValue rejection" "is test-only" out
    | _ -> assert false)

(* The api-test-only escape hatch: JsonValue must stay usable to inspect a
   response body inside `api-test`, since `check_type_names_in_scope` never
   walks DApiTest decls at all — this asserts the rejection above is scoped,
   not a blanket ban on the name. *)
let jsonvalue_allowed_inside_api_test () =
  let src = {|module Main exposing []
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.ApiTest exposing [statusOk]
import Tesl.Json exposing [stringCodec]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

record Echo { message: String }
codec Echo { toJson { message -> "message" with_codec stringCodec } fromJson_forbidden }

handler post echo(message: String) -> Echo = Echo { message: message }

api EchoApi { post "/echo" body message: String -> Echo }

server EchoServer for EchoApi { echo }

database EchoDb = Database { entities: [] backend: Memory }

main() -> App = App { database: EchoDb api: EchoServer port: 8099 }

api-test "raw JSON body round-trips" for EchoServer {
  let r = post "/echo" body "hi"
  expect statusOk r.status
  expect r.body.message == "hi"
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] -> check_ok "JsonValue inside api-test" main_p
    | _ -> assert false)

(* GitHub #60 (second bug): `with_codec dictCodec`/`listCodec`/`setCodec`
   must recursively decode by the field's declared key/value types. The Go
   backend does not expose these codecs yet, so this keeps whole-program check
   coverage and pins that explicit emitter gap rather than silently dropping
   the source case. *)
let dict_list_set_codec_decode_recurses () =
  let src = {|module Main exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.Json exposing [dictCodec, listCodec, setCodec]
import Tesl.Dict exposing [Dict]
import Tesl.Set exposing [Set]

record PayloadBody {
  payload: Dict String String
  tags: List String
  uniqueTags: Set String
}
codec PayloadBody {
  toJson_forbidden
  fromJson [
    {
      payload <- "payload" with_codec dictCodec
      tags <- "tags" with_codec listCodec
      uniqueTags <- "uniqueTags" with_codec setCodec
    }
  ]
}
|} in
  with_files [ ("main.tesl", src) ] (function
    | [main_p] ->
       check_ok "dictCodec/listCodec/setCodec decode" main_p;
       (match Compile.compile_go_file main_p with
        | Compile.GoSuccess _ -> failf "container codecs unexpectedly became Go-emittable without a behavior assertion"
        | Compile.GoFailure diagnostics ->
          let messages = String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
          assert_contains ~what:"documented Go container-codec gap"
            "does not emit the `Tesl.Json` export `dictCodec`" messages)
    | _ -> assert false)

(* Item 10 (review 2026-07-09): the name-level endpoint rejection missed
   NESTED exposure — a wire-positioned record whose field (transitively)
   carries EmailBody passed check and serialized garbage at runtime.  Three
   surfaces: endpoint return of a wrapping record (path chain named), an
   sseChannel payload, and a queue job record. *)
let emailbody_nested_record_endpoint_rejected () =
  let src = {|module Main exposing []
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody, HtmlBody, RichBody]

record Wrapped {
  note: String
  payload: EmailBody
}

record Outer {
  inner: Wrapped
}

handler get wrapped() -> Wrapped =
  Wrapped { note: "n", payload: TextBody "hello" }

handler get outer() -> Outer =
  Outer { inner: Wrapped { note: "n", payload: TextBody "hello" } }

api A {
  get "/wrapped"
    -> Wrapped
  get "/outer"
    -> Outer
}

server S for A {
  wrapped
  outer
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
  let src = {|module Main exposing []
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
  let src = {|module Main exposing []
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
  let src = {|module Main exposing []
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
  let src = {|module Main exposing []
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
       let artifacts = go_artifacts "partial application" main_p in
       let out = artifacts |> List.map (fun (a : Emit_go.artifact) -> a.contents)
         |> String.concat "\n" in
       assert_contains ~what:"arg-position partial application"
         "applyTwice(teslrt.Apply1Of2(addN, teslrt.FromInt64(3))" out;
       assert_not_contains ~what:"arg-position partial application"
         "applyTwice(addN, teslrt.FromInt64(1))" out;
       run_go_tests "partial application" artifacts
    | _ -> assert false)

(* ── 5. newtype record-field codec, both spellings ──────────────────────── *)

let newtype_codec_module ~id_codec = Printf.sprintf {|module Main exposing []
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
       (* Decode wraps the scalar in the nominal Go newtype. *)
       assert_contains ~what:"decode wrap"
         "User{Id: UserId{Value: teslFieldId}, Name: teslFieldName}" out;
       assert_contains ~what:"plain field decode"
         "teslrt.DecodeStringField(teslJSON, \"name\")" out;
       assert_contains ~what:"encode call"
         "\"id\":   teslValue.Id.Value" out
     | _ -> assert false)

let newtype_field_newtype_codec_spelling () =
  with_files [ ("main.tesl", newtype_codec_module ~id_codec:"UserId") ]
    (function
     | [main_p] ->
       check_ok "newtype field, with_codec UserId spelling" main_p;
       let out = emit_ok "newtype field, with_codec UserId spelling" main_p in
       assert_contains ~what:"decode wrap"
         "User{Id: UserId{Value: teslFieldId}, Name: teslFieldName}" out;
       assert_not_contains ~what:"decode wrap"
         "Id: teslFieldId" out
     | _ -> assert false)

(* ── 6. imported-module tests (silent-pass class) ───────────────────────────
   Every local dependency's test artifact must join the emitted Go project.
   Testless dependencies emit none; named filtering skips non-selected blocks.
   The transitive sandwich is pinned in section 7. *)

let dep_with_test = {|module Lib exposing [add]

import Tesl.Prelude exposing [Int]

fn add(a: Int, b: Int) -> Int =
  a + b

test "lib unit" {
  expect add 1 1 == 2
}
|}

let dep_without_test = {|module Lib exposing [add]

import Tesl.Prelude exposing [Int]

fn add(a: Int, b: Int) -> Int =
  a + b
|}

let main_importing_lib = {|module Main exposing []

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
       let artifacts = go_artifacts "main importing lib-with-tests" main_p in
       if not (List.exists (fun (a : Emit_go.artifact) ->
           a.path = "internal/teslmodlib/module_test.go") artifacts) then
         failf "dependency test artifact was not emitted";
       run_go_tests "dependency tests" artifacts
     | _ -> assert false)

let dep_without_tests_not_required () =
  with_files
    [ ("lib.tesl", dep_without_test); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let artifacts = go_artifacts "main importing testless lib" main_p in
       if List.exists (fun (a : Emit_go.artifact) ->
           a.path = "internal/teslmodlib/module_test.go") artifacts then
         failf "testless dependency emitted a Go test artifact";
       run_go_tests "testless dependency" artifacts
     | _ -> assert false)

let dep_doctest_counts_as_tests () =
  let lib = {|module Lib exposing [add]

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
       let artifacts = go_artifacts "main importing doctest-only lib" main_p in
       let out = artifacts |> List.map (fun (a : Emit_go.artifact) -> a.contents)
         |> String.concat "\n" in
       assert_contains ~what:"doctest-only dependency" {|teslWanted != "doctest: add"|} out;
       run_go_tests "doctest dependency" artifacts
     | _ -> assert false)

let single_test_selection_skips_dep_requires () =
  with_files
    [ ("lib.tesl", dep_with_test); ("main.tesl", main_importing_lib) ]
    (function
     | [_lib_p; main_p] ->
       let artifacts = go_artifacts "single-test selection" main_p in
       let out = artifacts |> List.map (fun (a : Emit_go.artifact) -> a.contents)
         |> String.concat "\n" in
       assert_contains ~what:"single-test selection keeps the named block"
         {|teslWanted != "main unit"|} out;
       run_go_tests ~env:"TESL_TEST_NAME='main unit' TESL_TEST_KIND=test"
         "single-test selection" artifacts
     | _ -> assert false)

(* ── 7. REVIEW2 batch (2026-07-09) ──────────────────────────────────────────
   One case per confirmed finding fixed in this batch; see the per-case
   comments for the pre-fix failure mode. *)

(* ITEM 4 (require filter): the ~700-name config-only require filter
   (currency ctors All/Try/Top, timezone ctors, SI aliases) applied to LOCAL
   imports too — a user record named `All` exported by a local module had its
   require binding silently dropped, so the check-green program crashed at
   load with "All: unbound identifier".  The filter is now scoped to Tesl.*
   stdlib imports only. *)
let local_export_named_like_currency_ctor () =
  let dep = {|module Dep exposing [All]

import Tesl.Prelude exposing [Int]

record All {
  x: Int
}
|} in
  let main = {|module Main exposing []

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
       assert_contains ~what:"local-module require not filtered"
         "teslmoddep.All{X: teslrt.FromInt64(4)}" out
     | _ -> assert false)

(* ITEM 1 (capability implies): `capability admin implies cacheCap Sessions`
   used to be interpreted as two identifiers. Go erases capabilities, so the
   artifact assertion verifies that local/imported cache declarations and calls
   survive after the checker accepts the implication. *)
let cap_implies_cache_cap_local = {|module Main exposing []

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
       assert_contains ~what:"cache remains emitted after proof erasure"
         "var SessionsStore = teslrt.NewCache[string](3600)" out;
       assert_contains ~what:"cache operation remains emitted"
         "teslrt.CacheGet(SessionsStore, k)" out
     | _ -> assert false)

let cap_implies_imported_cache_lib = {|module CacheLib exposing [TestDB, Sessions, getSession]

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

let cap_implies_imported_cache_main = {|module Main exposing [fetch]

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
       assert_contains ~what:"imported cache implementation emitted"
         "var SessionsStore = teslrt.NewCache[string](3600)" out;
       assert_contains ~what:"imported cache call remains after proof erasure"
         "return teslmodcachelib.GetSession(k)" out
     | _ -> assert false)

(* ITEM 3 (2-arg Job): `jobs: [Job PingJob handlePing]` type-checked green but
   desugar's job_entries only extracts the documented 3-arg shape
   (LANGUAGE-SPEC §queues: `Job <JobType> <workerFn> <dead-slot>`), so the
   queue emitted `#:job-types ()` and every enqueue failed at RUNTIME.  The
   2-arg spelling is now a CHECK-time rejection. *)
let two_arg_job_src dead_slot = Printf.sprintf {|module Main exposing [submit]

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
let queue_first_src = {|module Main exposing [submit]

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
  with_files
      [ ("main.tesl", queue_first_src) ]
      (function
       | [main_p] ->
         let artifacts = go_artifacts "queue-before-record module" main_p in
         let out = artifacts |> List.map (fun (a : Emit_go.artifact) -> a.contents)
           |> String.concat "\n" in
         assert_contains ~what:"queue declared before record"
           "var PingQueueQueue = teslrt.NewQueue(\"PingQueue\", 1)" out;
         assert_contains ~what:"job record remains nominal"
           "type PingJob struct" out;
         run_go_tests "queue before record" artifacts
       | _ -> assert false)

(* ITEM 9 (transitive dep tests): main→A(no tests)→B(failing test) — the
   dep-test-submodule require was gated on the DIRECT import's own decls, so
   A was skipped and B's failing test never ran ("1 test passed", exit 0).
   The gate is now "declares tests directly OR transitively", which is
   dependency test artifacts must therefore be collected transitively through
   a testless middle module. *)
let sandwich_lib_b = {|module LibB exposing [double]

import Tesl.Prelude exposing [Int]

fn double(n: Int) -> Int =
  n * 2

test "deliberately failing" {
  expect double 2 == 5
}
|}

let sandwich_lib_a = {|module LibA exposing [quad]

import Tesl.Prelude exposing [Int]
import LibB exposing [double]

fn quad(n: Int) -> Int =
  double (double n)
|}

let sandwich_main = {|module Main exposing []

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
       ignore lib_b_p; ignore lib_a_p;
       let artifacts = go_artifacts "sandwich main" main_p in
       if not (List.exists (fun (a : Emit_go.artifact) ->
           a.path = "internal/teslmodlibb/module_test.go") artifacts) then
         failf "transitive dependency test artifact was not emitted";
       run_go_tests ~expect_success:false "transitive failing dependency test" artifacts
     | _ -> assert false)

(* ITEM 11 (qualified partial application): `applyTwice (PartialLib.addN 3) 1`
   — is_under_applied matched bare EVar heads only, so the qualified twin of
   the fixed bug still emitted a direct under-applied call (runtime arity
   trap) while the let-bound spelling eta-expanded fine. *)
let qualified_partial_lib = {|module PartialLib exposing [addN]

import Tesl.Prelude exposing [Int]

fn addN(a: Int, b: Int) -> Int =
  a + b
|}

let qualified_partial_main = {|module Main exposing [applyTwice]

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
       check_ok "qualified partial application" main_p;
       (match Compile.compile_go_file main_p with
        | Compile.GoSuccess _ -> failf "qualified partial application needs a Go artifact assertion"
        | Compile.GoFailure diagnostics ->
          let out = String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
          assert_contains ~what:"documented qualified-call Go gap"
            "cannot resolve function `PartialLib.addN`" out)
     | _ -> assert false)

(* ITEM 12 (Money/PosixMillis newtype field decode): moneyCodec was missing
   from base_of_prim_codec (a Money-newtype field stayed unwrapped after
   decode), and the `with_codec <Newtype>` arm had no decoder for Money /
   PosixMillis bases, so it applied the constructor to the RAW jsexpr.
   PosixMillis is itself a runtime newtype, so its decode additionally wraps
   the BASE constructor. *)
let money_posix_newtype_codecs = {|module Main exposing []

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
       (match Compile.compile_go_file main_p with
        | Compile.GoSuccess _ -> failf "moneyCodec unexpectedly became Go-emittable without behavior coverage"
        | Compile.GoFailure diagnostics ->
          let out = String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
          assert_contains ~what:"documented moneyCodec Go gap"
            "does not emit the `Tesl.Json` export `moneyCodec`" out)
     | _ -> assert false)

(* ITEM 17 (asTool shadowing): a module declaring its own `fn asTool` — the
   checker blesses the shadow (builtin form inert), but the broadened emit
   guard claimed every asTool-headed application and crashed with the
   issue-#24 "please report this bug" failwith in argument position.  Under
   the shadow predicate both emit paths now treat it as an ordinary call. *)
let astool_shadow_src = {|module Main exposing [run]

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
         "return double(asTool(teslrt.FromInt64(20)))" out
     | _ -> assert false)

(* Issue #54: `sse "/path" subscribe Channel("literal")` — a broadcast-style
   channel keyed on a fixed string with NO `:param` in the path at all. The
   parser previously recognized only a bare identifier as the subscribe
   argument; a string literal matched neither that arm nor the empty-parens
   arm, so it was silently dropped and the emitted route's key slot fell back
   to `#f` (as if the channel had no key). The connect side then registered
   its listener under key `#f`, while `publish Channel("literal") ...` in a
   handler computed the real string key at runtime — every event silently
   failed to match and was dropped. The route's key slot must now carry the
   literal string itself, matching what `publish` computes. *)
let sse_literal_key_src = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.SSE exposing [SseChannel]

database MainDb = Database {
  schema: "emit_incidentals_sse_literal"
  entities: []
  backend: Memory
}

record RunQueued {
  runId: String
}

codec RunQueued {
  toJson {
    runId -> "runId" with_codec stringCodec
  }
  fromJson [
    {
      runId <- "runId" with_codec stringCodec
    }
  ]
}

sseChannel RunEvents(scope: String) = SseChannel {
  database: MainDb
  payload: RunQueued
}

handler post triggerRun(runId: String) -> String
  requires [pubsub] =
  publish RunEvents("all") RunQueued { runId: runId }
  "ok"

api MainApi {
  post "/trigger"
    body runId: String
    -> String

  sse "/runs/stream"
    subscribe RunEvents("all")
}

server MainServer for MainApi {
  triggerRun
}
|}

let sse_subscribe_literal_key_emits_matching_literal () =
  with_files
    [ ("main.tesl", sse_literal_key_src) ]
    (function
     | [main_p] ->
       check_ok "sse literal subscribe key" main_p;
       let out = emit_ok "sse literal subscribe key" main_p in
       (* Route tuple's key slot is the literal string "all", not #f — it must
          match the key `publish RunEvents("all") ...` computes at runtime. *)
       assert_contains ~what:"sse route key slot carries the literal"
         "teslrt.SseStream(RunEventsChannel, \"all\")" out;
       assert_not_contains ~what:"sse route no longer keys on #f"
         "teslrt.SseStream(RunEventsChannel, \"\")" out
     | _ -> assert false)

let tests = [
  test_case "publish record payload emits keyword ctor (same-module)" `Quick publish_record_payload_same_module;
  test_case "publish record payload emits keyword ctor (cross-module)" `Quick publish_record_payload_cross_module;
  test_case "publish ADT payload stays positional" `Quick publish_adt_payload_stays_positional;
  test_case "--generate-ts SSE endpoint references only defined names" `Quick ts_sse_unit_defined;
  test_case "exhaustive EmailBody case accepted + list-shape lowering" `Quick emailbody_exhaustive_case_accepted;
  test_case "EmailBody case missing arm rejected" `Quick emailbody_missing_arm_rejected;
  test_case "EmailBody endpoint body/return rejected at check time" `Quick emailbody_endpoint_positions_rejected;
  test_case "JsonValue rejected in production handler/endpoint positions (#60)" `Quick jsonvalue_production_positions_rejected;
  test_case "JsonValue still allowed inside api-test (#60)" `Quick jsonvalue_allowed_inside_api_test;
  test_case "dictCodec/listCodec/setCodec decode recurses (#60)" `Quick dict_list_set_codec_decode_recurses;
  test_case "nested EmailBody record rejected in endpoint positions (item 10)" `Quick emailbody_nested_record_endpoint_rejected;
  test_case "EmailBody sseChannel payload rejected (item 10)" `Quick emailbody_sse_payload_rejected;
  test_case "EmailBody queue-job record rejected (item 10)" `Quick emailbody_job_record_rejected;
  test_case "EmailBody stays legal in fn/record data positions" `Quick emailbody_data_positions_stay_legal;
  test_case "partial application in argument position eta-expands" `Quick partial_application_argument_position;
  test_case "newtype field codec: prim spelling wraps decode" `Quick newtype_field_prim_codec_spelling;
  test_case "newtype field codec: newtype-name spelling decodes via base" `Quick newtype_field_newtype_codec_spelling;
  test_case "dependency Go tests emitted and run" `Quick dep_test_submodule_required;
  test_case "testless dependency gets no Go test artifact" `Quick dep_without_tests_not_required;
  test_case "doctest-only dep counts as declaring tests" `Quick dep_doctest_counts_as_tests;
  test_case "--test-name selection skips other dependency tests" `Quick single_test_selection_skips_dep_requires;
  (* REVIEW2 batch (2026-07-09) *)
  test_case "local export named like a currency ctor keeps its require" `Quick local_export_named_like_currency_ctor;
  test_case "capability implies cacheCap renders via cap_ident" `Quick cap_implies_renders_cache_cap_ident;
  test_case "capability implies imported cacheCap synthesizes the value" `Quick cap_implies_imported_cache_synthesized;
  test_case "2-arg Job entry rejected at check time" `Quick two_arg_job_rejected;
  test_case "queue-before-record emits typed Go job" `Quick queue_first_nominal_refs;
  test_case "transitive dep tests compose through a testless middle module" `Quick transitive_dep_tests_compose;
  test_case "qualified partial application in argument position eta-expands" `Quick qualified_partial_application_eta_expands;
  test_case "Money/PosixMillis newtype field decode wraps" `Quick money_posix_newtype_decode_wraps;
  test_case "user-shadowed asTool emits an ordinary call" `Quick astool_shadow_emits_plain_call;
  test_case "sse subscribe literal key emits matching literal (#54)" `Quick sse_subscribe_literal_key_emits_matching_literal;
]

let () =
  run "Emit-Incidentals" [ ("matrix-2026-07-batch", tests) ]
