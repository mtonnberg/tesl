(** Antagonistic regression tests for Critical Review 48.

    Fix 1 — Conjunction proof propagation through check wrappers:
    R48_B01  Bare check-and in check body compiles
    R48_B02  Bare triple check-and in check body compiles
    R48_B03  Let-bound check-and in check body compiles
    R48_B04  Chained check → check wrapper compiles
    R48_B05  Bare single check delegation in check body compiles

    Fix 2 — Lowercase true/false rejected everywhere:
    R48_T01  lowercase true in fn body rejected
    R48_T02  lowercase false in fn body rejected
    R48_T03  lowercase true in test expect rejected
    R48_T04  lowercase false in test expect rejected
    R48_T05  lowercase true as fn argument in test rejected
    R48_T06  lowercase true in test let value rejected
    R48_T07  lowercase true in property body rejected
    R48_T08  uppercase True in fn body accepted
    R48_T09  uppercase True in test expect accepted
    R48_T10  uppercase True as fn argument in test accepted
*)

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
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_temp_file prefix suffix content f =
  let path = Filename.temp_file prefix suffix in
  write_file path content;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r48" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r48" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* ═══════════════════════════════════════════════════════════════════════════
   Fix 1: conjunction proof propagation
   ═══════════════════════════════════════════════════════════════════════════ *)

let test_r48_b01_bare_check_and_in_check () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check cB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "b"
check wrap(n: Int) -> n: Int ::: A n && B n =
  check (cA && cB) n
fn needs(n: Int ::: A n && B n) -> Int = n
|}

let test_r48_b02_bare_triple_check_and () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check cB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "b"
check cC(n: Int) -> n: Int ::: C n =
  if n != 42 then
    ok n ::: C n
  else
    fail 400 "c"
check wrap(n: Int) -> n: Int ::: A n && B n && C n =
  check (cA && cB && cC) n
|}

let test_r48_b03_let_bound_check_and () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check cB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "b"
check wrap(n: Int) -> n: Int ::: A n && B n =
  let v = check (cA && cB) n
  v
|}

let test_r48_b04_chained_check_wrap () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check cB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "b"
check inner(n: Int) -> n: Int ::: A n && B n =
  check (cA && cB) n
check outer(n: Int) -> n: Int ::: A n && B n =
  check inner n
|}

let test_r48_b05_bare_single_check_delegation () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check wrap(n: Int) -> n: Int ::: A n =
  check cA n
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Fix 2: lowercase true/false rejected everywhere
   ═══════════════════════════════════════════════════════════════════════════ *)

let test_r48_t01_lowercase_true_fn_body () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    true
  else
    False
|}

let test_r48_t02_lowercase_false_fn_body () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    True
  else
    false
|}

let test_r48_t03_lowercase_true_in_test_expect () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    True
  else
    False
test "bad" {
  expect f 1 == true
}
|}

let test_r48_t04_lowercase_false_in_test_expect () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    True
  else
    False
test "bad" {
  expect f 0 == false
}
|}

let test_r48_t05_lowercase_true_as_fn_arg_in_test () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn g(b: Bool) -> Int =
  if b then
    1
  else
    0
test "bad" {
  expect g true == 1
}
|}

let test_r48_t06_lowercase_true_in_test_let () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
test "bad" {
  let b = true
  expect b == True
}
|}

let test_r48_t07_lowercase_true_in_property_body () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
test "bad" with 10 runs {
  property "prop" (n: Int where n > 0 && n < 100) {
    true
  }
}
|}

(* Positive control: uppercase True/False should compile *)

let test_r48_t08_uppercase_true_fn_body () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    True
  else
    False
|}

let test_r48_t09_uppercase_true_in_test_expect () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn f(n: Int) -> Bool =
  if n > 0 then
    True
  else
    False
test "ok" {
  expect f 1 == True
  expect f 0 == False
}
|}

let test_r48_t10_uppercase_true_as_fn_arg () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int]
fn g(b: Bool) -> Int =
  if b then
    1
  else
    0
test "ok" {
  expect g True == 1
  expect g False == 0
}
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Fix 3: Proof checker — negative cases (must NOT compile)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R48_P01: check ok returns wrong name — must be rejected *)
let test_r48_p01_check_ok_wrong_binding () =
  should_fail_src "ok expression returns" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact Valid (n: Int)
check checkValid(n: Int) -> n: Int ::: Valid n =
  if n > 0 then
    let result = n
    ok result ::: Valid n
  else
    fail 400 "no"
|}

(* R48_P02: check ok proof doesn't match declared proof *)
let test_r48_p02_check_proof_mismatch () =
  should_fail_src "ok proof does not match" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: B n
  else
    fail 400 "no"
|}

(* R48_P03: auth ok proof doesn't match declared — different predicate *)
let test_r48_p03_auth_proof_wrong_predicate () =
  should_fail_src "ok proof does not match" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
fact Authorized (user: String)
auth myAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId ->
      ok userId ::: Authorized user
|}

(* R48_P04: auth conjunction proof — left half wrong predicate *)
let test_r48_p04_auth_conj_wrong_left () =
  should_fail_src "ok proof does not match" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
fact Authorized (user: String)
fact Session (user: String)
auth myAuth(request: HttpRequest)
  -> user: String ::: Authenticated user && Session user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId ->
      ok userId ::: Authorized user && Session user
|}

(* R48_P05: auth with proof var referencing undefined check *)
let test_r48_p05_undefined_proof_var () =
  should_fail_src "ok proof does not match" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
fact IsAdmin (user: String)
auth myAuth(request: HttpRequest)
  -> user: String ::: IsAdmin user && Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId ->
      ok userId ::: p && Authenticated user
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Fix 3: Proof checker — positive controls (MUST compile)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R48_P07: auth with proof var from delegated check — the canonical working pattern *)
let test_r48_p07_auth_delegated_check_passes () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.startsWith]
fact Authenticated (user: String)
fact IsAdmin (user: String)
check checkIsAdmin(userId: String) -> userId: String ::: IsAdmin userId =
  if String.startsWith userId "admin" then
    ok userId ::: IsAdmin userId
  else
    fail 403 "no"
auth myAuth(request: HttpRequest)
  -> user: String ::: IsAdmin user && Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId ->
      let (admin ::: p) = check checkIsAdmin userId
      ok admin ::: p && Authenticated user
|}

(* R48_P08: auth with binding == ok-value name — no substitution *)
let test_r48_p08_auth_identity_binding () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth myAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something user ->
      ok user ::: Authenticated user
|}

(* R48_P09: auth with binding != ok-value — substitution required *)
let test_r48_p09_auth_subst_binding () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth myAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something foundUser ->
      ok foundUser ::: Authenticated user
|}

(* R48_P10: conjunction check combinator — positive control *)
let test_r48_p10_conjunction_combinator () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check cA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"
check cB(n: Int) -> n: Int ::: B n =
  if n < 100 then
    ok n ::: B n
  else
    fail 400 "b"
check both(n: Int) -> n: Int ::: A n && B n =
  check (cA && cB) n
fn useBoth(n: Int) -> Int =
  let v = check both n
  v + 1
|}

(* R48_P11: auth conjunction with manual proofs — binding != ok *)
let test_r48_p11_auth_conj_manual () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
fact HasSession (user: String)
auth myAuth(request: HttpRequest)
  -> user: String ::: Authenticated user && HasSession user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId ->
      case Dict.lookup "session" request.cookies of
        Nothing -> fail 401 "no session"
        Something _ ->
          ok userId ::: Authenticated user && HasSession user
|}

(* ═══════════════════════════════════════════════════════════════════════════
   Fix 2 continued: lowercase bool in api-test and load-test blocks
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R48_T11: lowercase true in api-test expect *)
let test_r48_t11_lowercase_true_in_api_test () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing [S]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [statusOk]
record Msg { text: String }
codec Msg {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
handler echo(req: Msg) -> Msg = req
api A { post "/echo" body req: Msg -> Msg }
server S for A { echo = echo }
api-test "bad" for S {
  let r = post "/echo" body { "text": "hi" }
  expect true
}
|}

(* R48_T12: lowercase false in api-test let *)
let test_r48_t12_lowercase_false_in_api_test_let () =
  should_fail_src "VBOOL001" {|#lang tesl
module Test exposing [S]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [statusOk]
record Msg { text: String }
codec Msg {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
handler echo(req: Msg) -> Msg = req
api A { post "/echo" body req: Msg -> Msg }
server S for A { echo = echo }
api-test "bad" for S {
  let r = post "/echo" body { "text": "hi" }
  let b = false
  expect statusOk r.status
}
|}

let () =
  Alcotest.run "Review48" [
    "conjunction-proof", [
      test_case "R48_B01: bare check-and in check body" `Quick test_r48_b01_bare_check_and_in_check;
      test_case "R48_B02: bare triple check-and in check body" `Quick test_r48_b02_bare_triple_check_and;
      test_case "R48_B03: let-bound check-and in check body" `Quick test_r48_b03_let_bound_check_and;
      test_case "R48_B04: chained check wrapper" `Quick test_r48_b04_chained_check_wrap;
      test_case "R48_B05: bare single check delegation" `Quick test_r48_b05_bare_single_check_delegation;
    ];
    "bool-casing", [
      test_case "R48_T01: lowercase true in fn body rejected" `Quick test_r48_t01_lowercase_true_fn_body;
      test_case "R48_T02: lowercase false in fn body rejected" `Quick test_r48_t02_lowercase_false_fn_body;
      test_case "R48_T03: lowercase true in test expect rejected" `Quick test_r48_t03_lowercase_true_in_test_expect;
      test_case "R48_T04: lowercase false in test expect rejected" `Quick test_r48_t04_lowercase_false_in_test_expect;
      test_case "R48_T05: lowercase true as fn arg in test rejected" `Quick test_r48_t05_lowercase_true_as_fn_arg_in_test;
      test_case "R48_T06: lowercase true in test let value rejected" `Quick test_r48_t06_lowercase_true_in_test_let;
      test_case "R48_T07: lowercase true in property body rejected" `Quick test_r48_t07_lowercase_true_in_property_body;
      test_case "R48_T08: uppercase True in fn body accepted" `Quick test_r48_t08_uppercase_true_fn_body;
      test_case "R48_T09: uppercase True in test expect accepted" `Quick test_r48_t09_uppercase_true_in_test_expect;
      test_case "R48_T10: uppercase True as fn arg accepted" `Quick test_r48_t10_uppercase_true_as_fn_arg;
      test_case "R48_T11: lowercase true in api-test rejected" `Quick test_r48_t11_lowercase_true_in_api_test;
      test_case "R48_T12: lowercase false in api-test let rejected" `Quick test_r48_t12_lowercase_false_in_api_test_let;
    ];
    "proof-checker-negative", [
      test_case "R48_P01: check ok returns wrong binding name" `Quick test_r48_p01_check_ok_wrong_binding;
      test_case "R48_P02: check proof mismatch" `Quick test_r48_p02_check_proof_mismatch;
      test_case "R48_P03: auth proof wrong predicate" `Quick test_r48_p03_auth_proof_wrong_predicate;
      test_case "R48_P04: auth conjunction wrong left half" `Quick test_r48_p04_auth_conj_wrong_left;
      test_case "R48_P05: undefined proof var in auth" `Quick test_r48_p05_undefined_proof_var;
    ];
    "proof-checker-positive", [
      test_case "R48_P07: auth delegated check passes" `Quick test_r48_p07_auth_delegated_check_passes;
      test_case "R48_P08: auth identity binding passes" `Quick test_r48_p08_auth_identity_binding;
      test_case "R48_P09: auth subst binding passes" `Quick test_r48_p09_auth_subst_binding;
      test_case "R48_P10: conjunction combinator passes" `Quick test_r48_p10_conjunction_combinator;
      test_case "R48_P11: auth conj manual passes" `Quick test_r48_p11_auth_conj_manual;
    ];
  ]
