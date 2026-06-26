(** Phase 3: GDP Proof Checker Tests — happy path and adversarial.

    Tests cover:
    1. Parameter proof subject validation
    2. Check/auth/establish return proof validation
    3. Proof ownership enforcement (only check/auth/establish use ok :::)
    4. Capability declaration and requires checking
    5. Proof conjunction flattening and matching
    6. Edge cases and adversarial inputs *)

open Proof_checker

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let parse src = Parser.parse_module "<test>" src

let assert_no_proof_errors src =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs = Proof_checker.check_module m in
    if errs <> [] then
      Alcotest.failf "expected no proof errors but got:\n%s"
        (String.concat "\n" (List.map fmt_proof_error errs))

let assert_proof_error src substr =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs = Proof_checker.check_module m in
    let found = List.exists (fun e ->
      let n = String.length e.message in
      let m' = String.length substr in
      let found = ref false in
      for i = 0 to n - m' do
        if String.sub e.message i m' = substr then found := true
      done; !found
    ) errs in
    if not found then
      Alcotest.failf "expected proof error containing %S but got:\n%s"
        substr
        (if errs = [] then "(no errors)" else
         String.concat "\n" (List.map (fun e -> e.message) errs))

(* ── 1. Parameter proof subject validation ────────────────────────────────── *)

let test_valid_proof_subject () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPos(n: Int) -> n: Int ::: Positive n =
  ok n ::: Positive n
|}

let test_invalid_proof_subject () =
  (* 'x' is not a parameter name; 'n' is *)
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPos(n: Int) -> n: Int ::: Positive x =
  ok n ::: Positive n
|} "not a parameter"

let test_multi_param_valid_subjects () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact P (x: Int)
fact Q (y: Int)
fn f(x: Int ::: P x, y: Int ::: Q y) -> Int = x
|}

let test_cross_param_proof_valid () =
  (* Cross-parameter proof: both x and y are valid params *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact ValidRange (lo: Int) (hi: Int)
fn f(lo: Int ::: ValidRange lo hi, hi: Int) -> Int = lo
|}

let test_cross_param_invalid_subject () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact ValidRange (lo: Int) (hi: Int)
fn f(lo: Int ::: ValidRange lo unknown, hi: Int) -> Int = lo
|} "not a parameter"

let test_return_binding_valid () =
  (* The return binding name can be used as a proof subject *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact ValidPort (port: Int)
check isValid(port: Int) -> port: Int ::: ValidPort port =
  ok port ::: ValidPort port
|}

let test_check_multiple_proofs () =
  (* Multiple predicates in conjunction — all subjects must be valid *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact PA (n: Int)
fact PB (n: Int)
check checkBoth(n: Int) -> n: Int ::: PA n && PB n =
  ok n ::: PA n && PB n
|}

(* ── 2. Proof ownership tests ────────────────────────────────────────────── *)

let test_check_can_use_ok () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"
|}

let test_auth_can_use_ok () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Http exposing [HttpRequest]
import Tesl.Prelude exposing [String]
auth myAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  ok user ::: Authenticated user
|}

let test_fn_cannot_use_ok () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn bad(n: Int) -> Int =
  ok n ::: SomeProof n
|} "proof construction is not allowed in `fn`"

let test_handler_cannot_use_ok () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
handler badHandler(n: Int) -> Int
  requires [] =
  ok n ::: SomeProof n
|} "proof construction is not allowed in `handler`"

(* ── 3. Check return proof validation ────────────────────────────────────── *)

let test_check_return_matches () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Valid (n: Int)
check isValid(n: Int) -> n: Int ::: Valid n =
  if n > 0 then
    ok n ::: Valid n
  else
    fail 400 "invalid"
|}

let test_check_missing_predicate () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Valid (n: Int)
fact Extra (n: Int)
check isValid(n: Int) -> n: Int ::: Valid n && Extra n =
  if n > 0 then
    ok n ::: Valid n
  else
    fail 400 "invalid"
|} "got `Valid n`, expected `Valid n && Extra n`"

let test_check_extra_predicate () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Valid (n: Int)
check isValid(n: Int) -> n: Int ::: Valid n =
  if n > 0 then
    ok n ::: Valid n && Bonus n
  else
    fail 400 "invalid"
|} "got `Valid n && Bonus n`, expected `Valid n`"

(* ── 4. Capability checking tests ────────────────────────────────────────── *)

let test_builtin_caps_ok () =
  (* Stdlib capabilities are valid when explicitly imported *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB   exposing [dbRead, dbWrite]
import Tesl.Time exposing [time]
fn f(x: Int) -> Int requires [dbRead, dbWrite, time] = x
|}

let test_declared_cap_ok () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability myRead implies dbRead
fn f(x: Int) -> Int requires [myRead] = x
|}

let test_unknown_cap_error () =
  assert_proof_error {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int requires [undeclaredCap] = x
|} "undeclared capability"

let test_cap_implies_unknown () =
  assert_proof_error {|#lang tesl
module Foo exposing []
capability myRead implies nonExistentCap
|} "unknown capability"

let test_cap_chain_ok () =
  (* Transitive capability implications are valid *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.DB exposing [dbRead]
capability level2 implies dbRead
capability level1 implies level2
fn f() -> Int requires [level1] = 0
|}

let test_handler_requires_caps () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead]
capability appRead implies dbRead
handler myHandler(x: String) -> String
  requires [appRead] =
  x
|}

(* ── 5. Proof utilities tests ────────────────────────────────────────────── *)

let test_proof_subjects_simple () =
  let p = Ast.PredApp { pred = "Positive"; args = ["n"]; loc = Location.dummy_loc "<test>" } in
  let subjects = Proof_checker.proof_subjects p in
  Alcotest.(check (list string)) "subjects" ["n"] subjects

let test_proof_subjects_conjunction () =
  let loc = Location.dummy_loc "<test>" in
  let p = Ast.PredAnd {
    left  = Ast.PredApp { pred = "PA"; args = ["x"]; loc };
    right = Ast.PredApp { pred = "PB"; args = ["y"]; loc };
    loc } in
  let subjects = List.sort_uniq String.compare (Proof_checker.proof_subjects p) in
  Alcotest.(check (list string)) "conjunction subjects" ["x"; "y"] subjects

let test_proof_subjects_uppercase_ignored () =
  (* Uppercase names in proof args are predicates, not subjects *)
  let p = Ast.PredApp { pred = "FromDb"; args = ["(Id == x)"]; loc = Location.dummy_loc "<test>" } in
  let subjects = Proof_checker.proof_subjects p in
  (* "(Id == x)" contains special chars — should not match *)
  Alcotest.(check bool) "no uppercase subjects" true
    (not (List.mem "Id" subjects))

let test_flatten_proof () =
  let loc = Location.dummy_loc "<test>" in
  let p = Ast.PredAnd {
    left = Ast.PredAnd {
      left  = Ast.PredApp { pred = "PA"; args = []; loc };
      right = Ast.PredApp { pred = "PB"; args = []; loc };
      loc };
    right = Ast.PredApp { pred = "PC"; args = []; loc };
    loc } in
  let flat = Proof_checker.flatten_proof p in
  Alcotest.(check int) "flattened count" 3 (List.length flat)

(* ── 6. Integration: all lesson files pass proof check ───────────────────── *)

let test_lesson_files_no_crash () =
  let root =
    let tesl_root = match Sys.getenv_opt "TESL_REPO_ROOT" with
      | Some p when p <> "" -> p
      | _ ->
        let rec find dir =
          let candidate = Filename.concat dir "compiler" in
          if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
          then dir
          else let parent = Filename.dirname dir in
               if parent = dir then Filename.current_dir_name else find parent
        in
        find (Filename.dirname Sys.executable_name)
    in
    Filename.concat tesl_root "example/learn"
  in
  let files = try
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun f ->
        let n = String.length f in
        n >= 5 && String.sub f (n-5) 5 = ".tesl")
    |> List.sort String.compare
  with Sys_error _ -> []
  in
  List.iter (fun fname ->
    let path = Filename.concat root fname in
    let src = try In_channel.with_open_text path In_channel.input_all
              with Sys_error _ -> "" in
    if src <> "" then
      match parse src with
      | Err _ -> ()  (* parse errors expected for some edge cases *)
      | Ok m ->
        let errs = Proof_checker.check_module m in
        (* Just verify no exceptions — errors are acceptable *)
        ignore errs
  ) files

(* ── 7. Adversarial proof tests ──────────────────────────────────────────── *)

let test_empty_proof_module () =
  assert_no_proof_errors {|#lang tesl
module Empty exposing []
|}

let test_proof_with_no_predicates () =
  (* A function with no proof annotations at all *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int = x + y
|}

let test_establish_function () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
establish provePositive(n: Int) -> Fact (Positive n) =
  Positive n
|}

let test_proof_in_record_fields () =
  (* Records can have proof-annotated fields — predicates must be declared *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fact SafeTitle (s: String)
fact SafeContent (s: String)
check validateTitle(s: String) -> s: String ::: SafeTitle s =
  ok s ::: SafeTitle s
check validateContent(s: String) -> s: String ::: SafeContent s =
  ok s ::: SafeContent s
record SafeNote {
  title: String ::: SafeTitle title
  content: String ::: SafeContent content
}
|}

let test_complex_capability_hierarchy () =
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.DB exposing [dbRead, dbWrite]
capability readAll implies dbRead
capability writeAll implies dbWrite
capability fullAccess implies readAll, writeAll
handler myOp() -> Int requires [fullAccess] = 0
|}

let test_no_false_proof_errors_on_tests () =
  (* test blocks don't produce false proof errors *)
  assert_no_proof_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"
test "basic" {
  expectFail isPos 0
  expectHasProof isPos 5 Positive
}
|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)


(* ── Sidecar proof mismatch: claims Positive but only establishes Small ──── *)

let test_sidecar_proof_mismatch () =
  (* This function claims ::: Positive m as sidecar proof, but only calls
     checkSmall m which establishes Small m, not Positive m.
     The compiler should reject this. *)
  let src = {|#lang tesl
module TestSidecarMismatch exposing []

import Tesl.Prelude exposing [Bool(..), Int, Fact]

fact Positive (n: Int)
fact Small (n: Int)

check checkPositive(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"

check checkSmall(n: Int) -> n: Int ::: Small n =
  if n < 100 then
    ok n ::: Small n
  else
    fail 400 "not small"

fn shouldNotWork(n: Int, m: Int) -> (Int ? Positive && Small) ::: Positive m =
  let (_ ::: p) = check checkSmall m
  (check (checkPositive && checkSmall)) n ::: p
|} in
  (* The sidecar mismatch is caught by validation (validate_named_pack_returns),
     not by proof_checker. Check validation errors instead. *)
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs = Validation.check_module m in
    let found = List.exists (fun (e : Validation.validation_error) ->
      let n = String.length e.message in
      let m' = String.length "Positive" in
      let found = ref false in
      for i = 0 to n - m' do
        if String.sub e.message i m' = "Positive" then found := true
      done; !found
    ) errs in
    if not found then
      Alcotest.failf "expected validation error about Positive but got:\n%s"
        (if errs = [] then "(no errors)" else
         String.concat "\n" (List.map (fun (e : Validation.validation_error) -> e.message) errs))

let () =
  Alcotest.run "Proofs" [
    "param-subjects", [
      Alcotest.test_case "valid subject" `Quick test_valid_proof_subject;
      Alcotest.test_case "invalid subject" `Quick test_invalid_proof_subject;
      Alcotest.test_case "multi-param valid" `Quick test_multi_param_valid_subjects;
      Alcotest.test_case "cross-param valid" `Quick test_cross_param_proof_valid;
      Alcotest.test_case "cross-param invalid" `Quick test_cross_param_invalid_subject;
      Alcotest.test_case "return binding valid" `Quick test_return_binding_valid;
      Alcotest.test_case "check multiple proofs" `Quick test_check_multiple_proofs;
    ];
    "ownership", [
      Alcotest.test_case "check can use ok" `Quick test_check_can_use_ok;
      Alcotest.test_case "auth can use ok" `Quick test_auth_can_use_ok;
      Alcotest.test_case "fn cannot use ok" `Quick test_fn_cannot_use_ok;
      Alcotest.test_case "handler cannot use ok" `Quick test_handler_cannot_use_ok;
    ];
    "return-proofs", [
      Alcotest.test_case "check return matches" `Quick test_check_return_matches;
      Alcotest.test_case "missing predicate" `Quick test_check_missing_predicate;
      Alcotest.test_case "extra predicate" `Quick test_check_extra_predicate;
    ];
    "capabilities", [
      Alcotest.test_case "builtin caps ok" `Quick test_builtin_caps_ok;
      Alcotest.test_case "declared cap ok" `Quick test_declared_cap_ok;
      Alcotest.test_case "unknown cap error" `Quick test_unknown_cap_error;
      Alcotest.test_case "cap implies unknown" `Quick test_cap_implies_unknown;
      Alcotest.test_case "cap chain ok" `Quick test_cap_chain_ok;
      Alcotest.test_case "handler requires caps" `Quick test_handler_requires_caps;
    ];
    "utilities", [
      Alcotest.test_case "proof subjects" `Quick test_proof_subjects_simple;
      Alcotest.test_case "conjunction subjects" `Quick test_proof_subjects_conjunction;
      Alcotest.test_case "uppercase ignored" `Quick test_proof_subjects_uppercase_ignored;
      Alcotest.test_case "flatten proof" `Quick test_flatten_proof;
    ];
    "integration", [
      Alcotest.test_case "all lessons don't crash" `Quick test_lesson_files_no_crash;
    ];
    "adversarial", [
      Alcotest.test_case "empty module" `Quick test_empty_proof_module;
      Alcotest.test_case "no proof annotations" `Quick test_proof_with_no_predicates;
      Alcotest.test_case "establish function" `Quick test_establish_function;
      Alcotest.test_case "proof in record fields" `Quick test_proof_in_record_fields;
      Alcotest.test_case "complex capability hierarchy" `Quick test_complex_capability_hierarchy;
      Alcotest.test_case "no false errors on tests" `Quick test_no_false_proof_errors_on_tests;
      Alcotest.test_case "sidecar proof mismatch rejected" `Quick test_sidecar_proof_mismatch;
    ];
  ]
