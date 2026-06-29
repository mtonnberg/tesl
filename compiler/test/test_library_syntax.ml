(** Library syntax tests — Review 73.

    Tests for two new library support features:

    1. Re-export support: a module can list imported names in its own
       `exposing [...]`, making them accessible to downstream consumers.
       Proof predicate identity is preserved through re-export chains.

    2. `library` keyword: an explicit declaration that a module is a
       reusable library.  The compiler immediately enforces that `library`
       modules cannot contain `server`, `api`, or `main` declarations. *)

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
  let dir = Filename.temp_dir "tesl-r73" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
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

let with_two_files content_a name_a content_b name_b f =
  let dir = Filename.temp_dir "tesl-r73-2" "" in
  let path_a = Filename.concat dir (name_a ^ ".tesl") in
  let path_b = Filename.concat dir (name_b ^ ".tesl") in
  let oc_a = open_out path_a in output_string oc_a content_a; close_out oc_a;
  let oc_b = open_out path_b in output_string oc_b content_b; close_out oc_b;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_a with _ -> ());
      (try Sys.remove path_b with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_a path_b)

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

let two_files_should_pass a_name a_src b_name b_src =
  with_two_files a_src a_name b_src b_name (fun _pa pb ->
    let code, out = run_compiler ["--check"; pb] in
    if code <> 0 then failf "expected success for %s, got:\n%s" b_name out)


(* ── REEX — Re-export support ────────────────────────────────────────────── *)

let test_REEX01_reexport_fact_from_imported_module () =
  (* Library B re-exports a fact from Library A; consumer C uses the fact *)
  two_files_should_pass "LibA" {|
#lang tesl
module LibA exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
|} "Consumer" {|
#lang tesl
module Consumer exposing []
import Tesl.Prelude exposing [String]
import LibA exposing [ValidEmail, checkEmail]
fn useEmail(s: String ::: ValidEmail s) -> String = s
fn test(raw: String) -> String =
  let e = check checkEmail raw
  useEmail e
|}

let test_REEX02_reexport_function_from_imported_module () =
  two_files_should_pass "MathLib" {|
#lang tesl
module MathLib exposing [double, triple]
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
fn triple(n: Int) -> Int = n * 3
|} "MathConsumer" {|
#lang tesl
module MathConsumer exposing []
import Tesl.Prelude exposing [Int]
import MathLib exposing [double, triple]
fn compute(n: Int) -> Int = double n + triple n
|}

let test_REEX03_reexport_adt_type () =
  two_files_should_pass "ColorLib" {|
#lang tesl
module ColorLib exposing [Color(..)]
type Color
  = Red
  | Green
  | Blue
|} "ColorConsumer" {|
#lang tesl
module ColorConsumer exposing []
import Tesl.Prelude exposing [String]
import ColorLib exposing [Color(..)]
fn name(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_REEX04_reexport_record_type () =
  two_files_should_pass "UserLib" {|
#lang tesl
module UserLib exposing [User]
import Tesl.Prelude exposing [String, Int]
record User { id: Int name: String }
|} "UserConsumer" {|
#lang tesl
module UserConsumer exposing []
import Tesl.Prelude exposing [String, Int]
import UserLib exposing [User]
fn getName(u: User) -> String = u.name
|}

let test_REEX05_proof_flows_through_reexport_chain () =
  (* Verify proofs from re-exported check functions work end-to-end *)
  two_files_should_pass "ProofLib" {|
#lang tesl
module ProofLib exposing [IsPositive, checkPositive]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|} "ProofConsumer" {|
#lang tesl
module ProofConsumer exposing []
import Tesl.Prelude exposing [Int]
import ProofLib exposing [IsPositive, checkPositive]
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n + 1
fn test(raw: Int) -> Int =
  let n = check checkPositive raw
  requiresPositive n
|}

let test_REEX06_cannot_reexport_name_not_in_import () =
  (* You cannot list a name in exposing if it was not imported *)
  should_fail "unknown or non-local\\|does not export\\|exposes unknown" {|
#lang tesl
module BadReexport exposing [ghostFunction]
import Tesl.Prelude exposing [Int]
fn realFn() -> Int = 42
|}

let test_REEX07_module_keyword_still_works () =
  should_pass {|
#lang tesl
module StillWorks exposing []
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 42
|}

(* ── LIBKW — library keyword syntax ─────────────────────────────────────── *)

let test_LIBKW01_library_keyword_parses_and_compiles () =
  should_pass {|
#lang tesl
library EmailLib exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
|}

let test_LIBKW02_library_with_types_and_functions () =
  should_pass {|
#lang tesl
library MathUtils exposing [double, triple, MathResult(..)]
import Tesl.Prelude exposing [Int]
type MathResult
  = Success value: Int
  | Overflow
fn double(n: Int) -> Int = n * 2
fn triple(n: Int) -> Int = n * 3
|}

let test_LIBKW03_library_with_capabilities () =
  should_pass {|
#lang tesl
library CapLib exposing [myCapability]
import Tesl.DB exposing [dbRead]
capability myCapability implies dbRead
|}

let test_LIBKW04_library_with_auth_function () =
  should_pass {|
#lang tesl
library AuthLib exposing [Authenticated, sessionAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth sessionAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "session" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something token -> ok token ::: Authenticated user
|}

let test_LIBKW05_library_with_worker_function () =
  should_pass {|
#lang tesl
library WorkerLib exposing [JobPayload, processJob]
import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [FromQueue]
record JobPayload { message: String }
worker processJob(job: JobPayload ::: FromQueue (Id == jobId) job) requires [] =
  job
|}

let test_LIBKW06_library_cannot_have_server_block () =
  (* CRITICAL: library keyword explicitly forbids server blocks *)
  should_fail "library module.*server\\|server.*library module\\|not allowed in library" {|
#lang tesl
library BadLib exposing []
import Tesl.Prelude exposing [String]
api BadApi { get "/ping" -> String }
handler ping() -> String requires [] = "pong"
server BadServer for BadApi { ping = ping }
|}

let test_LIBKW07_library_cannot_have_api_block () =
  should_fail "library module.*api\\|api.*library module\\|not allowed in library" {|
#lang tesl
library BadLib2 exposing []
import Tesl.Prelude exposing [String]
api ShouldNotBeHere { get "/health" -> String }
|}

let test_LIBKW08_library_cannot_have_main_block () =
  should_fail "library module.*main\\|main.*library module\\|not allowed in library" {|
#lang tesl
library BadLib3 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.App exposing [App]
fn add(a: Int, b: Int) -> Int = a + b
main() -> App requires [] =
  App {
    database: AppDb
    api: AppServer
    port: 8080
    queues: []
  }
|}

let test_LIBKW09_library_can_be_imported_by_app () =
  two_files_should_pass "ValidateLib" {|
#lang tesl
library ValidateLib exposing [NonEmpty, checkNonEmpty]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact NonEmpty (s: String)
check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if String.length s > 0 then
    ok s ::: NonEmpty s
  else
    fail 400 "empty"
|} "AppModule" {|
#lang tesl
module AppModule exposing []
import Tesl.Prelude exposing [String]
import ValidateLib exposing [NonEmpty, checkNonEmpty]
fn process(s: String ::: NonEmpty s) -> String = s
fn main_logic(raw: String) -> String =
  let ne = check checkNonEmpty raw
  process ne
|}

let test_LIBKW10_library_keyword_gives_helpful_error_on_server () =
  (* Error message should mention both the library keyword and what to do *)
  should_fail "library\\|server\\|move.*application\\|root module" {|
#lang tesl
library Oops exposing []
import Tesl.Prelude exposing [String]
api MyApi { get "/" -> String }
handler root() -> String requires [] = "hello"
server MyServer for MyApi { root = root }
|}

let test_LIBKW11_library_with_check_and_establish () =
  should_pass {|
#lang tesl
library ProofLib exposing [Positive, checkPositive, alwaysPositiveOne]
import Tesl.Prelude exposing [Int, Fact]
fact Positive (n: Int)
check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "bad"
establish alwaysPositiveOne() -> Fact (Positive 1) =
  Positive 1
|}

let test_LIBKW12_library_with_codec () =
  should_pass {|
#lang tesl
library ModelLib exposing [Item]
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
record Item { name: String price: Int }
codec Item {
  toJson { name -> "name" with_codec stringCodec price -> "price" with_codec intCodec }
  fromJson [ { name <- "name" with_codec stringCodec price <- "price" with_codec intCodec } ]
}
|}

let test_LIBKW13_library_exports_handler_function () =
  (* handler KIND functions are allowed in libraries — they're just functions *)
  should_pass {|
#lang tesl
library HandlerLib exposing [pingHandler]
import Tesl.Prelude exposing [String]
handler pingHandler() -> String requires [] = "pong"
|}

let test_LIBKW14_module_with_server_is_still_allowed () =
  (* The `module` keyword (not `library`) can still have server blocks *)
  should_pass {|
#lang tesl
module AppModule exposing [AppServer]
import Tesl.Prelude exposing [String]
api AppApi { get "/health" -> String }
handler health() -> String requires [] = "ok"
server AppServer for AppApi { health = health }
|}

let test_LIBKW15_library_with_multiple_imports_chain () =
  (* Library can import from other libraries *)
  two_files_should_pass "DepLib" {|
#lang tesl
library DepLib exposing [IsPositive, checkPos]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|} "ComposedLib" {|
#lang tesl
library ComposedLib exposing [IsPositive, checkPos, requiresPositive]
import Tesl.Prelude exposing [Int]
import DepLib exposing [IsPositive, checkPos]
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n * 2
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review73-Library-Syntax" [
    "re-export-support", [
      test_case "REEX01 re-export fact from imported module" `Quick test_REEX01_reexport_fact_from_imported_module;
      test_case "REEX02 re-export function" `Quick test_REEX02_reexport_function_from_imported_module;
      test_case "REEX03 re-export ADT type" `Quick test_REEX03_reexport_adt_type;
      test_case "REEX04 re-export record type" `Quick test_REEX04_reexport_record_type;
      test_case "REEX05 proof flows through re-export" `Quick test_REEX05_proof_flows_through_reexport_chain;
      test_case "REEX06 cannot re-export non-imported name" `Quick test_REEX06_cannot_reexport_name_not_in_import;
      test_case "REEX07 module keyword still works" `Quick test_REEX07_module_keyword_still_works;
    ];
    "library-keyword", [
      test_case "LIBKW01 library keyword parses and compiles" `Quick test_LIBKW01_library_keyword_parses_and_compiles;
      test_case "LIBKW02 library with types and functions" `Quick test_LIBKW02_library_with_types_and_functions;
      test_case "LIBKW03 library with capabilities" `Quick test_LIBKW03_library_with_capabilities;
      test_case "LIBKW04 library with auth function" `Quick test_LIBKW04_library_with_auth_function;
      test_case "LIBKW05 library with worker function" `Quick test_LIBKW05_library_with_worker_function;
      test_case "LIBKW06 library cannot have server block" `Quick test_LIBKW06_library_cannot_have_server_block;
      test_case "LIBKW07 library cannot have api block" `Quick test_LIBKW07_library_cannot_have_api_block;
      test_case "LIBKW08 library cannot have main block" `Quick test_LIBKW08_library_cannot_have_main_block;
      test_case "LIBKW09 library can be imported by app" `Quick test_LIBKW09_library_can_be_imported_by_app;
      test_case "LIBKW10 library error message helpful" `Quick test_LIBKW10_library_keyword_gives_helpful_error_on_server;
      test_case "LIBKW11 library with check and establish" `Quick test_LIBKW11_library_with_check_and_establish;
      test_case "LIBKW12 library with codec" `Quick test_LIBKW12_library_with_codec;
      test_case "LIBKW13 library exports handler function" `Quick test_LIBKW13_library_exports_handler_function;
      test_case "LIBKW14 module keyword still allows server" `Quick test_LIBKW14_module_with_server_is_still_allowed;
      test_case "LIBKW15 library imports from other libraries" `Quick test_LIBKW15_library_with_multiple_imports_chain;
    ];
  ]
