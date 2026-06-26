(** QA-74 — Signature-library completeness and library boundary edge cases.

    Two groups of tests:

    SL (Signature-Library completeness, 25 tests): verify that library modules
    whose exported function signatures reference locally-defined types or proof
    predicates that are NOT also exported produce the correct compile error,
    and that valid configurations compile cleanly.

    LB (Library Boundary edge cases, 15 tests): verify that the `library`
    keyword correctly rejects app-level constructs (api, server, main, workers,
    database, entity) while allowing library-legal constructs (record, fact,
    check, handler, worker, test), and that importing a `library` module vs a
    `module` with server/api produces the expected results.

    Known bug (SL06, SL21): the compiler does not currently extract predicate
    *arguments* (e.g. `IsPositive` in `ForAll IsPositive xs`) when checking
    signature exposure, so SL06 and SL21 are written as should_fail but will
    likely not catch the bug (the compiler passes them silently).  They are
    correct in intent — if the compiler is ever fixed, these tests will start
    passing as expected failures. *)

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
  let content =
    if String.length content > 0 && content.[0] = '\n'
    then String.sub content 1 (String.length content - 1)
    else content
  in
  let dir = Filename.temp_dir "tesl-qa74" "" in
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

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_lint_warn pat src =
  with_temp_file src (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected lint warning matching %S, got:\n%s" pat out)

let should_lint_clean src =
  with_temp_file src (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    if try ignore (Str.search_forward (Str.regexp {|warning\[W080\]|}) out 0); true
       with Not_found -> false
    then failf "expected no W080, but got:\n%s" out)

(* ═══════════════════════════════════════════════════════════════════════════
   Group SL — Signature-Library completeness (25 tests)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* SL01: library exports fn where PARAM uses locally-defined record not exported *)
let test_SL01_param_unexported_record () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|add.*Payload.*exposing" {|
#lang tesl
library Sl01 exposing [process]
import Tesl.Prelude exposing [String]
record Payload { body: String }
fn process(p: Payload) -> String = p.body
|}

(* SL02: library exports fn where RETURN uses locally-defined record not exported *)
let test_SL02_return_unexported_record () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|add.*Response.*exposing" {|
#lang tesl
library Sl02 exposing [makeResponse]
import Tesl.Prelude exposing [String]
record Response { status: String }
fn makeResponse(s: String) -> Response =
  Response { status: s }
|}

(* SL03: library exports check fn where RETURN PROOF PREDICATE not exported *)
let test_SL03_return_proof_predicate_unexported () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|add.*IsReady.*exposing" {|
#lang tesl
library Sl03 exposing [checkReady]
import Tesl.Prelude exposing [Int]
fact IsReady (n: Int)
check checkReady(n: Int) -> n: Int ::: IsReady n =
  if n > 0 then
    ok n ::: IsReady n
  else
    fail 400 "not ready"
|}

(* SL04: library exports fn using `List LocalType` param where LocalType not exported.
   Tests TApp (type application) recursion in signature-exposure check. *)
let test_SL04_list_of_unexported_type_param () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|add.*Item.*exposing" {|
#lang tesl
library Sl04 exposing [countItems]
import Tesl.Prelude exposing [Int, List]
record Item { value: Int }
fn countItems(xs: List Item) -> Int = 0
|}

(* SL05: library exports fn using `Maybe LocalType` return where LocalType not exported *)
let test_SL05_maybe_of_unexported_type_return () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|add.*Box.*exposing" {|
#lang tesl
library Sl05 exposing [findBox]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
record Box { id: Int }
fn findBox(n: Int) -> Maybe Box =
  Nothing
|}

(* SL06: library exports fn with `ForAll IsValid xs` in PARAM where IsValid locally
   defined but NOT exported.
   NOTE: This tests a known bug — the compiler may silently pass this because
   pred_names_with_locs only captures the predicate name ("ForAll") not args
   (["IsValid"]).  Written as should_fail to document the correct expected behaviour.
   If the compiler correctly catches this, the test passes; if it silently succeeds,
   alcotest will report it as a failure (revealing the bug). *)
let test_SL06_forall_pred_arg_unexported_should_fail () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|IsPositive" {|
#lang tesl
library Sl06 exposing [sumPositives]
import Tesl.Prelude exposing [Int, List]
fact IsPositive (n: Int)
fn sumPositives(xs: List Int ::: ForAll IsPositive xs) -> Int = 0
|}

(* SL07: library exports fn with `ForAll IsValid xs` in PARAM where IsValid IS exported.
   Positive case: everything exported, no error. *)
let test_SL07_forall_pred_arg_exported_should_pass () =
  should_pass {|
#lang tesl
library Sl07 exposing [sumPositives, IsPositive]
import Tesl.Prelude exposing [Int, List]
fact IsPositive (n: Int)
fn sumPositives(xs: List Int ::: ForAll IsPositive xs) -> Int = 0
|}

(* SL08: library with check fn where conjunction proof `IsA n && IsB n` in return
   and BOTH exported.  Positive case. *)
let test_SL08_conjunction_proof_both_exported_should_pass () =
  should_pass {|
#lang tesl
library Sl08 exposing [checkBoth, IsA, IsB]
import Tesl.Prelude exposing [Int]
fact IsA (n: Int)
fact IsB (n: Int)
check checkBoth(n: Int) -> n: Int ::: IsA n && IsB n =
  if n > 0 && n < 100 then
    ok n ::: IsA n && IsB n
  else
    fail 400 "bad"
|}

(* SL09: library with check fn where conjunction proof `IsA n && IsB n` in return
   and only IsA exported.  IsB is locally-defined but not exported. *)
let test_SL09_conjunction_proof_one_unexported_should_fail () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|IsB" {|
#lang tesl
library Sl09 exposing [checkBoth, IsA]
import Tesl.Prelude exposing [Int]
fact IsA (n: Int)
fact IsB (n: Int)
check checkBoth(n: Int) -> n: Int ::: IsA n && IsB n =
  if n > 0 && n < 100 then
    ok n ::: IsA n && IsB n
  else
    fail 400 "bad"
|}

(* SL10: library exports fn — type comes from IMPORT (not local) — no error.
   Positive: imported types from Tesl stdlib are never locally-defined. *)
let test_SL10_imported_type_in_param_should_pass () =
  should_pass {|
#lang tesl
library Sl10 exposing [greet, double]
import Tesl.Prelude exposing [String, Int]
fn greet(name: String) -> String = name
fn double(n: Int) -> Int = n * 2
|}

(* SL11: library exports fn — locally-defined type IS exported — no error *)
let test_SL11_locally_defined_type_exported_should_pass () =
  should_pass {|
#lang tesl
library Sl11 exposing [makeUser, User]
import Tesl.Prelude exposing [String, Int]
record User { id: Int name: String }
fn makeUser(id: Int, name: String) -> User =
  User { id: id name: name }
|}

(* SL12: library exports fn with newtype return not exported *)
let test_SL12_newtype_return_not_exported () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|UserId" {|
#lang tesl
library Sl12 exposing [makeUserId]
import Tesl.Prelude exposing [String]
type UserId = String
fn makeUserId(s: String) -> UserId = s
|}

(* SL13: library exports fn with ADT type param not exported *)
let test_SL13_adt_param_not_exported () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|Direction" {|
#lang tesl
library Sl13 exposing [move]
import Tesl.Prelude exposing [Int]
type Direction
  = North
  | South
  | East
  | West
fn move(d: Direction, steps: Int) -> Int =
  case d of
    North -> steps
    South -> 0 - steps
    East  -> steps
    West  -> 0 - steps
|}

(* SL14: library exports fn — same unexported type appears in BOTH param and return.
   Should fail at least once (not silently). *)
let test_SL14_same_unexported_type_in_param_and_return () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|Token" {|
#lang tesl
library Sl14 exposing [refreshToken]
import Tesl.Prelude exposing [String]
record Token { value: String expiry: String }
fn refreshToken(t: Token) -> Token =
  Token { value: t.value expiry: "later" }
|}

(* SL15: library exports check fn — proof predicate IS exported — no error *)
let test_SL15_proof_predicate_exported_should_pass () =
  should_pass {|
#lang tesl
library Sl15 exposing [IsNonNeg, checkNonNeg]
import Tesl.Prelude exposing [Int]
fact IsNonNeg (n: Int)
check checkNonNeg(n: Int) -> n: Int ::: IsNonNeg n =
  if n >= 0 then
    ok n ::: IsNonNeg n
  else
    fail 400 "negative"
|}

(* SL16: library exports fn using ONLY stdlib types (Int, String) — no error *)
let test_SL16_stdlib_types_only_should_pass () =
  should_pass {|
#lang tesl
library Sl16 exposing [add, concat]
import Tesl.Prelude exposing [Int, String]
fn add(a: Int, b: Int) -> Int = a + b
fn concat(a: String, b: String) -> String = a
|}

(* SL17: library exports MULTIPLE fns, one has unexported type.
   The unexported-type error must still be produced. *)
let test_SL17_multiple_fns_one_bad_should_fail () =
  should_fail "not exported\\|consumers cannot use\\|V001" {|
#lang tesl
library Sl17 exposing [double, makeSecret]
import Tesl.Prelude exposing [Int, String]
record Secret { code: Int }
fn double(n: Int) -> Int = n * 2
fn makeSecret(n: Int) -> Secret =
  Secret { code: n }
|}

(* SL18: library with two exported fns, each with different unexported types.
   At least one error (possibly both) must be reported. *)
let test_SL18_two_fns_two_unexported_types_should_fail () =
  should_fail "not exported\\|consumers cannot use\\|V001" {|
#lang tesl
library Sl18 exposing [makeAlpha, makeBeta]
import Tesl.Prelude exposing [String]
record Alpha { a: String }
record Beta { b: String }
fn makeAlpha(s: String) -> Alpha = Alpha { a: s }
fn makeBeta(s: String) -> Beta = Beta { b: s }
|}

(* SL19: W080 for regular MODULE with unexported record in param.
   Regular modules produce W080 lint warning, not a compile error. *)
let test_SL19_module_unexported_record_lint_warn () =
  should_lint_warn "W080\\|not.*exported" {|
#lang tesl
module Sl19 exposing [processData]
import Tesl.Prelude exposing [String]
record DataItem { content: String }
fn processData(d: DataItem) -> String = d.content
|}

(* SL20: W080 for regular MODULE with STDLIB types only — no W080 *)
let test_SL20_module_stdlib_types_no_w080 () =
  should_lint_clean {|
#lang tesl
module Sl20 exposing [triple, hello]
import Tesl.Prelude exposing [Int, String]
fn triple(n: Int) -> Int = n * 3
fn hello(name: String) -> String = name
|}

(* SL21: W080 for regular MODULE with ForAll unexported pred in param.
   NOTE: This tests the same known bug as SL06 — the lint check may also miss
   ForAll predicate arguments.  Written as should_lint_warn to document the
   correct expected behaviour. *)
let test_SL21_module_forall_unexported_pred_lint_warn () =
  should_lint_warn "W080\\|not.*exported\\|IsActive" {|
#lang tesl
module Sl21 exposing [filterActive]
import Tesl.Prelude exposing [Int, List]
fact IsActive (n: Int)
fn filterActive(xs: List Int ::: ForAll IsActive xs) -> List Int = xs
|}

(* SL22: Library exports fn using `Maybe LocalType` in PARAM where LocalType not exported *)
let test_SL22_maybe_of_unexported_type_param () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|Widget" {|
#lang tesl
library Sl22 exposing [unwrapWidget]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
record Widget { label: String }
fn unwrapWidget(mw: Maybe Widget) -> String =
  case mw of
    Nothing -> ""
    Something w -> w.label
|}

(* SL23: Library exports fn with proof REQUIRING locally-defined fact param, fact not exported.
   The fn's parameter annotation uses a locally-defined fact that is not in the exposing list. *)
let test_SL23_param_proof_annotation_unexported_fact () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|IsTrusted" {|
#lang tesl
library Sl23 exposing [processTrusted]
import Tesl.Prelude exposing [String]
fact IsTrusted (s: String)
fn processTrusted(s: String ::: IsTrusted s) -> String = s
|}

(* SL24: Library exports fn where locally-defined type is exported via ExportAdt (..),
   including type and all constructors.  No error — everything exported. *)
let test_SL24_adt_exported_with_constructors_should_pass () =
  should_pass {|
#lang tesl
library Sl24 exposing [Color(..), describe]
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describe(c: Color) -> String =
  case c of
    Red   -> "red"
    Green -> "green"
    Blue  -> "blue"
|}

(* SL25: Library with non-exported fn using unexported type — no error.
   Only exported fns are subject to the signature exposure check. *)
let test_SL25_unexported_fn_unexported_type_no_error () =
  should_pass {|
#lang tesl
library Sl25 exposing []
import Tesl.Prelude exposing [String]
record InternalRecord { data: String }
fn internalHelper(r: InternalRecord) -> String = r.data
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Group LB — Library boundary edge cases (15 tests)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* LB01: library with `api` block — not allowed *)
let test_LB01_library_with_api_rejected () =
  should_fail "not allowed in library\\|library.*api\\|api.*library" {|
#lang tesl
library Lb01 exposing []
import Tesl.Prelude exposing [String]
api Lb01Api {
  get "/ping" -> String
}
|}

(* LB02: library with `server` block — not allowed *)
let test_LB02_library_with_server_rejected () =
  should_fail "not allowed in library\\|library.*server\\|server.*library" {|
#lang tesl
library Lb02 exposing []
import Tesl.Prelude exposing [String]
api Lb02Api { get "/health" -> String }
handler healthH() -> String requires [] = "ok"
server Lb02Server for Lb02Api { health = healthH }
|}

(* LB03: library with `main` block — not allowed *)
let test_LB03_library_with_main_rejected () =
  should_fail "not allowed in library\\|library.*main\\|main.*library" {|
#lang tesl
library Lb03 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
main {
  with capabilities [] {
    add 1 2
  }
}
|}

(* LB04: library with `workers` wiring — not allowed *)
let test_LB04_library_with_workers_wiring_rejected () =
  should_fail "not allowed in library\\|library.*workers\\|workers.*library" {|
#lang tesl
library Lb04 exposing []
import Tesl.Prelude exposing [String]
database Lb04Db { backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
queue Lb04Q { database Lb04Db jobs [Lb04Job] }
record Lb04Job { msg: String }
worker doLb04Job(j: Lb04Job) requires [] = j
workers Lb04Workers for Lb04Q { Lb04Job = doLb04Job }
|}

(* LB05: library with `database` block.
   NOTE: In current phase-1 implementation, `database` alone inside a library
   may or may not be forbidden.  We expect it to be rejected since a library
   should not own infrastructure.  Written as should_fail; if the compiler
   allows it, the test reveals a policy gap. *)
let test_LB05_library_with_database_rejected () =
  should_fail "not allowed in library\\|library.*database\\|database.*library\\|infrastructure\\|V00" {|
#lang tesl
library Lb05 exposing []
database Lb05Db { backend postgres schema "s" entities []
  postgres { database "mydb" user "u" password "" host "localhost" port 5432 socket "" } }
|}

(* LB06: library with `entity` block — entities are infrastructure, not allowed *)
let test_LB06_library_with_entity_rejected () =
  should_fail "not allowed in library\\|library.*entity\\|entity.*library\\|infrastructure\\|V00" {|
#lang tesl
library Lb06 exposing []
import Tesl.Prelude exposing [Int, String]
entity Lb06User table "users" primaryKey id { id: Int name: String }
|}

(* LB07: library with `test` block — tests ARE allowed in libraries (positive case) *)
let test_LB07_library_with_test_block_allowed () =
  should_pass {|
#lang tesl
library Lb07 exposing [double]
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
test "double works" {
  expect double 3 == 6
}
|}

(* LB08: library with only a `record` declaration — no error *)
let test_LB08_library_with_record_only_allowed () =
  should_pass {|
#lang tesl
library Lb08 exposing [Point]
import Tesl.Prelude exposing [Int]
record Point { x: Int y: Int }
|}

(* LB09: library with `fact` and `check` fn — allowed *)
let test_LB09_library_with_fact_and_check_allowed () =
  should_pass {|
#lang tesl
library Lb09 exposing [IsNonZero, checkNonZero]
import Tesl.Prelude exposing [Int]
fact IsNonZero (n: Int)
check checkNonZero(n: Int) -> n: Int ::: IsNonZero n =
  if n != 0 then
    ok n ::: IsNonZero n
  else
    fail 400 "zero"
|}

(* LB10: library with `handler` fn (function, not wiring) — allowed *)
let test_LB10_library_with_handler_fn_allowed () =
  should_pass {|
#lang tesl
library Lb10 exposing [pingHandler]
import Tesl.Prelude exposing [String]
handler pingHandler() -> String requires [] = "pong"
|}

(* LB11: library with `worker` fn (function, not wiring) — allowed *)
let test_LB11_library_with_worker_fn_allowed () =
  should_pass {|
#lang tesl
library Lb11 exposing [processMsg, Lb11Job]
import Tesl.Prelude exposing [String]
record Lb11Job { msg: String }
worker processMsg(j: Lb11Job) -> String requires [] = j.msg
|}

(* LB12: importing a regular `module` that contains a `server` block — should fail.
   This is the existing module-as-library boundary check (not the `library` keyword). *)
let test_LB12_importing_module_with_server_rejected () =
  (* Write two files in the same temp dir, compile the importer *)
  let lib_src = {|#lang tesl
module Lb12Lib exposing []
import Tesl.Prelude exposing [String]
api Lb12Api { get "/x" -> String }
handler xH() -> String requires [] = "x"
server Lb12Server for Lb12Api { x = xH }
|} in
  let app_src = {|#lang tesl
module Lb12App exposing []
import Lb12Lib
|} in
  let dir = Filename.temp_dir "tesl-qa74-lb12" "" in
  let path_lib = Filename.concat dir "lb12-lib.tesl" in
  let path_app = Filename.concat dir "lb12-app.tesl" in
  let oc_lib = open_out path_lib in output_string oc_lib lib_src; close_out oc_lib;
  let oc_app = open_out path_app in output_string oc_app app_src; close_out oc_app;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_lib with _ -> ());
      (try Sys.remove path_app with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_compiler ["--check"; path_app] in
      if code = 0 then failf "expected failure (server in imported module), but succeeded";
      let re = Str.regexp_case_fold "not allowed in library\\|server.*library\\|library.*server" in
      try ignore (Str.search_forward re out 0)
      with Not_found -> failf "expected library boundary error, got:\n%s" out)

(* LB13: importing a clean `library` module — should pass *)
let test_LB13_importing_clean_library_module_allowed () =
  let lib_src = {|#lang tesl
library Lb13Lib exposing [triple]
import Tesl.Prelude exposing [Int]
fn triple(n: Int) -> Int = n * 3
|} in
  let app_src = {|#lang tesl
module Lb13App exposing []
import Tesl.Prelude exposing [Int]
import Lb13Lib exposing [triple]
fn sixTimes(n: Int) -> Int = triple (triple n)
|} in
  let dir = Filename.temp_dir "tesl-qa74-lb13" "" in
  let path_lib = Filename.concat dir "lb13-lib.tesl" in
  let path_app = Filename.concat dir "lb13-app.tesl" in
  let oc_lib = open_out path_lib in output_string oc_lib lib_src; close_out oc_lib;
  let oc_app = open_out path_app in output_string oc_app app_src; close_out oc_app;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_lib with _ -> ());
      (try Sys.remove path_app with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_compiler ["--check"; path_app] in
      if code <> 0 then failf "expected clean compile importing library, got:\n%s" out)

(* LB14: library exports unexported fact (fact not in exposing) AND exports check fn
   that mentions the fact in its return proof.  The fact is not exported but the
   check fn is — so the signature exposes an unexported proof predicate. *)
let test_LB14_exported_check_fn_unexported_fact_should_fail () =
  should_fail "not exported\\|consumers cannot use\\|V001\\|IsInternal" {|
#lang tesl
library Lb14 exposing [checkInternal]
import Tesl.Prelude exposing [Int]
fact IsInternal (n: Int)
check checkInternal(n: Int) -> n: Int ::: IsInternal n =
  if n > 0 then
    ok n ::: IsInternal n
  else
    fail 400 "bad"
|}

(* LB15: library with zero exports (`exposing []`) and no fns referencing unexported types.
   A trivial valid library — should pass. *)
let test_LB15_library_empty_exposing_no_fns_should_pass () =
  should_pass {|
#lang tesl
library Lb15 exposing []
import Tesl.Prelude exposing [Int]
fn helper(n: Int) -> Int = n + 1
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Test runner
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "QA74-Signature-Library" [
    "signature-library-completeness", [
      test_case "SL01 param unexported record → error" `Quick test_SL01_param_unexported_record;
      test_case "SL02 return unexported record → error" `Quick test_SL02_return_unexported_record;
      test_case "SL03 return proof predicate unexported → error" `Quick test_SL03_return_proof_predicate_unexported;
      test_case "SL04 List of unexported type param → error" `Quick test_SL04_list_of_unexported_type_param;
      test_case "SL05 Maybe of unexported type return → error" `Quick test_SL05_maybe_of_unexported_type_return;
      test_case "SL06 ForAll pred arg unexported → should_fail (known bug may pass)" `Quick test_SL06_forall_pred_arg_unexported_should_fail;
      test_case "SL07 ForAll pred arg exported → pass" `Quick test_SL07_forall_pred_arg_exported_should_pass;
      test_case "SL08 conjunction proof both exported → pass" `Quick test_SL08_conjunction_proof_both_exported_should_pass;
      test_case "SL09 conjunction proof one unexported → error" `Quick test_SL09_conjunction_proof_one_unexported_should_fail;
      test_case "SL10 imported (stdlib) types → pass" `Quick test_SL10_imported_type_in_param_should_pass;
      test_case "SL11 locally-defined type exported → pass" `Quick test_SL11_locally_defined_type_exported_should_pass;
      test_case "SL12 newtype return unexported → error" `Quick test_SL12_newtype_return_not_exported;
      test_case "SL13 ADT param unexported → error" `Quick test_SL13_adt_param_not_exported;
      test_case "SL14 same unexported type in param+return → error" `Quick test_SL14_same_unexported_type_in_param_and_return;
      test_case "SL15 proof predicate exported → pass" `Quick test_SL15_proof_predicate_exported_should_pass;
      test_case "SL16 stdlib types only → pass" `Quick test_SL16_stdlib_types_only_should_pass;
      test_case "SL17 multiple fns, one bad → error" `Quick test_SL17_multiple_fns_one_bad_should_fail;
      test_case "SL18 two fns two unexported types → error" `Quick test_SL18_two_fns_two_unexported_types_should_fail;
      test_case "SL19 module unexported record → W080 lint warn" `Quick test_SL19_module_unexported_record_lint_warn;
      test_case "SL20 module stdlib types only → no W080" `Quick test_SL20_module_stdlib_types_no_w080;
      test_case "SL21 module ForAll unexported pred → W080 (known bug may miss)" `Quick test_SL21_module_forall_unexported_pred_lint_warn;
      test_case "SL22 Maybe of unexported type param → error" `Quick test_SL22_maybe_of_unexported_type_param;
      test_case "SL23 param proof annotation unexported fact → error" `Quick test_SL23_param_proof_annotation_unexported_fact;
      test_case "SL24 ADT exported with constructors → pass" `Quick test_SL24_adt_exported_with_constructors_should_pass;
      test_case "SL25 unexported fn with unexported type → no error" `Quick test_SL25_unexported_fn_unexported_type_no_error;
    ];
    "library-boundary-edges", [
      test_case "LB01 library with api → error" `Quick test_LB01_library_with_api_rejected;
      test_case "LB02 library with server → error" `Quick test_LB02_library_with_server_rejected;
      test_case "LB03 library with main → error" `Quick test_LB03_library_with_main_rejected;
      test_case "LB04 library with workers wiring → error" `Quick test_LB04_library_with_workers_wiring_rejected;
      test_case "LB05 library with database → error" `Quick test_LB05_library_with_database_rejected;
      test_case "LB06 library with entity → error" `Quick test_LB06_library_with_entity_rejected;
      test_case "LB07 library with test block → pass" `Quick test_LB07_library_with_test_block_allowed;
      test_case "LB08 library with record only → pass" `Quick test_LB08_library_with_record_only_allowed;
      test_case "LB09 library with fact and check → pass" `Quick test_LB09_library_with_fact_and_check_allowed;
      test_case "LB10 library with handler fn → pass" `Quick test_LB10_library_with_handler_fn_allowed;
      test_case "LB11 library with worker fn → pass" `Quick test_LB11_library_with_worker_fn_allowed;
      test_case "LB12 importing module with server → error" `Quick test_LB12_importing_module_with_server_rejected;
      test_case "LB13 importing clean library module → pass" `Quick test_LB13_importing_clean_library_module_allowed;
      test_case "LB14 exported check fn, unexported fact → error" `Quick test_LB14_exported_check_fn_unexported_fact_should_fail;
      test_case "LB15 library empty exposing, no exports → pass" `Quick test_LB15_library_empty_exposing_no_fns_should_pass;
    ];
  ]
