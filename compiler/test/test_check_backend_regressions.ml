(** Regressions where `tesl check` disagreed with what the backend and the generated clients
    actually do: programs that checked clean and then failed to emit or build, repeated
    endpoint clauses that silently replaced each other, seed inserts whose field types went
    unchecked, lint false positives, SQL bounds, and the `Maybe` wire shape.  The tests drive
    the real compiler binary on inline programs, so they exercise the same path a user's
    `tesl check` does. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let dir = Filename.dirname Sys.argv.(0) in
    let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let c2 = Filename.concat dir "../bin/main.exe" in
    let found = if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl" in
    (* Absolute: the tests run the compiler from inside temporary project directories, and a
       path relative to the test's own directory stops resolving after that `cd`. *)
    if found <> "tesl" && Filename.is_relative found
    then Filename.concat (Sys.getcwd ()) found else found

let failf fmt = Printf.ksprintf failwith fmt

let run_cc ?(cwd=".") args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote cwd) (String.concat " " q) in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

(* The compiler resolves imports by file name, so a file must be named after its module. *)
let kebab_of_module m =
  let buf = Buffer.create 16 in
  String.iteri (fun i c ->
    if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
    else if c >= 'A' && c <= 'Z' then begin
      Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c)
    end else Buffer.add_char buf c) m;
  Buffer.contents buf

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun n -> remove_tree (Filename.concat path n)) (Sys.readdir path);
      (try Unix.rmdir path with _ -> ())
    end else (try Sys.remove path with _ -> ())

(** [with_project files k] writes [(module_name, source)] files into a fresh directory and
    calls [k dir]. *)
let with_project files k =
  let dir = Filename.temp_dir "tesl-check-backend" "" in
  List.iter (fun (m, src) ->
    let path = Filename.concat dir (kebab_of_module m ^ ".tesl") in
    Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src)) files;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> k dir)

let file_of m = kebab_of_module m ^ ".tesl"

let check_module ?(extra=[]) m src =
  with_project ((m, src) :: extra) (fun dir -> run_cc ~cwd:dir ["--check"; file_of m])

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let expect_error ~label (code, out) needle =
  if code = 0 then failf "%s: expected a check failure, got success:\n%s" label out;
  if not (contains out needle) then failf "%s: expected %S in:\n%s" label needle out

let expect_clean ~label (code, out) =
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

(* ── The check/emit gap (class) ──────────────────────────────────────────────
   `tesl check` was clean, then the Go emitter refused the program (or
   emitted Go that did not build) the first time `tesl test`/`run`/`build` ran.  `check`
   now runs the emitter, so an emitter refusal is a check error. *)

let maybe_body_without_codec = {|module MaybeBody exposing [S]

import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]

record StartBody {
  workItem: String
  agent: Maybe String
}

handler post start(body: StartBody) -> String =
  body.workItem

api A {
  post "/start"
    body body: StartBody
    -> String
}

server S for A {
  start
}

api-test "start" for S {
  let r = post "/start" body { "workItem": "w" }
  expect r.status == 200
}
|}

let test_emitter_refusal_is_a_check_error () =
  (* The program is only refused by the emitter; before this pass `--check` exited 0. *)
  expect_error ~label:"via --check" (check_module "MaybeBody" maybe_body_without_codec)
    "error[V001]"

(* A library is emitted as part of the entries that import it, never alone: a module
   that enqueues onto a queue its importer declares cannot be emitted by itself, and
   checking it must not pretend otherwise. *)
let test_library_module_is_not_emitted_alone () =
  expect_clean ~label:"library enqueue" (check_module "QueueLib" {|module QueueLib exposing [PingJob, enqueuePing, libQueueWrite]

import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [queueWrite]

capability libQueueWrite implies queueWrite

record PingJob {
  name: String
}

fn enqueuePing(name: String) -> String
  requires [libQueueWrite] =
  enqueue PingJob { name: name }
  "queued"
|})

let test_emittable_program_stays_clean () =
  expect_clean ~label:"plain program" (check_module "Plain" {|module Plain exposing [double]

import Tesl.Prelude exposing [Int]

fn double(x: Int) -> Int =
  x * 2
|})

let test_check_json_reports_emitter_refusal () =
  with_project [("MaybeBody", maybe_body_without_codec)] (fun dir ->
    let code, out = run_cc ~cwd:dir ["--check-json"; file_of "MaybeBody"] in
    if code = 0 then failf "--check-json must exit non-zero:\n%s" out;
    if not (contains out "\"severity\":\"error\"") then failf "no error diagnostic in:\n%s" out)

let test_agent_context_reports_emitter_refusal () =
  with_project [("MaybeBody", maybe_body_without_codec)] (fun dir ->
    let code, out = run_cc ~cwd:dir ["agent-context"; file_of "MaybeBody"] in
    if code = 0 then failf "agent-context must exit non-zero:\n%s" out;
    if not (contains out "\"ok\":false") then failf "agent-context must report ok:false:\n%s" out)


(* ── a repeated endpoint clause used to replace the first silently ─────── *)

let two_auth_lines = {|module TwoAuth exposing [S]

import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]

fact Keyed(who: String)
fact Named(who: String)

auth keyAuth(req: HttpRequest) -> who: String ::: Keyed who =
  case Dict.lookup "x-api-key" req.headers of
    Nothing -> fail 401 "no key"
    Something k -> ok k ::: Keyed who

auth nameAuth(req: HttpRequest) -> who: String ::: Named who =
  fail 403 "no"

handler get one(other: String ::: Named other) -> String =
  "reached"

api A {
  get "/two"
    auth identity: String ::: Keyed identity via keyAuth
    auth other: String ::: Named other via nameAuth
    -> String
}

server S for A {
  one
}
|}

let test_second_auth_line_is_refused () =
  (* Before: the handler took the SECOND auth's proof and the first auth function (the
     api-key check) silently never ran — and the program checked clean. *)
  expect_error ~label:"two auth lines" (check_module "TwoAuth" two_auth_lines)
    "duplicate `auth` clause"

let test_second_body_clause_is_refused () =
  expect_error ~label:"two body clauses" (check_module "TwoBody" {|module TwoBody exposing [S]

import Tesl.Prelude exposing [String]

record A1 {
  a: String
}

handler post p(body: A1) -> String =
  body.a

api Api {
  post "/p"
    body body: A1
    body other: A1
    -> String
}

server S for Api {
  p
}
|}) "duplicate `body` clause"

(* ── seed inserts are type-checked like any insert ─────────────────────── *)

let seed_program field_value = Printf.sprintf {|module SeedTypes exposing [S]

import Tesl.Prelude exposing [String, Int]
import Tesl.Time exposing [PosixMillis, Time.secondsToPosix, addMs]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.ApiTest exposing [statusOk]
import Tesl.Database exposing [Database, Memory]

entity Run table "runs" primaryKey id {
  id: String
  queuedAt: PosixMillis
}

database Db = Database {
  schema: "s"
  entities: [Run]
  backend: Memory
}

handler get count() -> Int
  requires [dbRead Run] =
  selectCount r from Run

api A {
  get "/c"
    -> Int
}

server S for A {
  count
}

api-test "seed" for S requires [dbRead Run, dbWrite Run] {
  seed {
    insert Run { id: "a", queuedAt: %s }
  }
  let r = get "/c"
  expect statusOk r.status
}
|} field_value

let test_seed_int_literal_for_posix_is_a_type_error () =
  (* The spec promised it; the checker only checked the field NAMES. *)
  let result = check_module "SeedTypes" (seed_program "1700000000300") in
  expect_error ~label:"seed Int literal" result "cannot unify Int with PosixMillis";
  expect_error ~label:"seed hint" result "addMs (Time.secondsToPosix 0) ms"

let test_seed_constructed_posix_is_clean () =
  expect_clean ~label:"seed built PosixMillis"
    (check_module "SeedTypes" (seed_program "addMs (Time.secondsToPosix 0) 1700000000300"))

(* ── W050 must credit what an api-test and an inline capture reference ──── *)

let test_lint_credits_api_test_server_and_inline_codec () =
  let app = {|module LintApp exposing [Srv]

import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]

handler get read(id: String) -> String =
  id

api A {
  get "/r/:id"
    capture id: String using stringCodec
    -> String
}

server Srv for A {
  read
}
|} in
  let tests = {|module LintAppTests exposing []

import Tesl.ApiTest exposing [statusOk]
import LintApp exposing [Srv]

api-test "r" for Srv {
  let r = get "/r/x"
  expect statusOk r.status
}
|} in
  with_project [("LintApp", app); ("LintAppTests", tests)] (fun dir ->
    let _, out_app = run_cc ~cwd:dir ["--lint"; file_of "LintApp"] in
    if contains out_app "W050" then failf "inline capture codec flagged unused:\n%s" out_app;
    let _, out_tests = run_cc ~cwd:dir ["--lint"; file_of "LintAppTests"] in
    if contains out_tests "W050" then failf "api-test server flagged unused:\n%s" out_tests)

(* ── a limit/offset expression is a statement PARAMETER, never spliced ─── *)

let emitted_module_text m src =
  with_project [(m, src)] (fun dir ->
    let out = Filename.concat dir "go-out" in
    let code, log = run_cc ~cwd:dir [file_of m; "--out"; out] in
    if code <> 0 then failf "emission failed:\n%s" log;
    let ic = Unix.open_process_in (Printf.sprintf "cat %s/internal/*/module.go" (Filename.quote out)) in
    let text = In_channel.input_all ic in
    ignore (Unix.close_process_in ic); text)

let test_limit_expression_is_a_parameter () =
  let text = emitted_module_text "PgLimit" {|module PgLimit exposing [page]

import Tesl.Prelude exposing [String, Int, List]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

entity Thing table "things" primaryKey id {
  id: String
  n: Int
}

database Db = Database {
  schema: "public"
  entities: [Thing]
  backend: Postgres (PostgresConfig {
    dbName: "app"
    user: "tesl"
    password: ""
    connection: TcpConnection {
      host: "127.0.0.1"
      port: 5432
    }
  })
}

fn page(size: Int, skip: Int) -> List Thing
  requires [dbRead Thing] =
  select t from Thing order t.n asc limit size offset skip
|} in
  if not (contains text "limit $1 offset $2") then
    failf "the bounds must be $n parameters in the statement:\n%s" text;
  if not (contains text "teslrt.SqlBound(") then
    failf "the bounds must go through teslrt.SqlBound:\n%s" text

(* ── Maybe is null/value on the wire, the envelope in storage ──────────── *)

let test_maybe_wire_and_storage_encoders_differ () =
  let text = emitted_module_text "WireMaybe" {|module WireMaybe exposing [S]

import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]

record View {
  note: Maybe String
}

handler get view() -> View =
  View { note: Nothing }

api A {
  get "/v"
    -> View
}

server S for A {
  view
}
|} in
  if not (contains text "teslrt.EncodeMaybeWire(") then
    failf "a response's Maybe field must encode through the wire rule:\n%s" text

let () =
  run "check-backend-regressions" [
    "check-emit-gap", [
      test_case "emitter refusal fails --check" `Quick test_emitter_refusal_is_a_check_error;
      test_case "emittable program stays clean" `Quick test_emittable_program_stays_clean;
      test_case "library module not emitted alone" `Quick test_library_module_is_not_emitted_alone;
      test_case "emitter refusal in --check-json" `Quick test_check_json_reports_emitter_refusal;
      test_case "emitter refusal in agent-context" `Quick test_agent_context_reports_emitter_refusal;
    ];
    "endpoint-clauses", [
      test_case "second auth line refused" `Quick test_second_auth_line_is_refused;
      test_case "second body clause refused" `Quick test_second_body_clause_is_refused;
    ];
    "seed-types", [
      test_case "Int literal for PosixMillis in seed" `Quick test_seed_int_literal_for_posix_is_a_type_error;
      test_case "constructed PosixMillis in seed" `Quick test_seed_constructed_posix_is_clean;
    ];
    "sql-bounds", [
      test_case "limit/offset expression is a parameter" `Quick test_limit_expression_is_a_parameter;
    ];
    "wire", [
      test_case "Maybe wire encoder" `Quick test_maybe_wire_and_storage_encoders_differ;
    ];
    "lint", [
      test_case "W050 credits api-test server + inline codec" `Quick test_lint_credits_api_test_server_and_inline_codec;
    ];
  ]
