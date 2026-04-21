(** Antagonistic regression tests for Critical Review 62.

    This review audits:
    1.  Establish return type not verified against body predicate — compiler trusts
        declared type but body can return different Fact predicate (runtime catches).
    2.  introAnd with inline function call arguments fails proof tracking — only
        works with bound variables (static analysis gap, not a soundness hole).
    3.  Single-line `if` not supported — parse error with specific message.
    4.  Nested let inside let value position — parse error.
    5.  fn cannot return proof-carrying type via `:::` annotation.
    6.  Shadowing via let is correctly rejected.
    7.  Proof predicate must be imported before use.
    8.  Establish can call other establish functions.
    9.  Recursive ADT types work correctly.
    10. forgetFact → re-prove roundtrip works.
    11. Zero-argument functions are callable with ().
    12. Non-exhaustive case correctly rejected.
    13. Duplicate fact declarations rejected.
    14. Capability cycle detection works.
    15. Auth function restriction: auth not callable from fn/check/establish.
    16. filterCheck requires check/auth function (lambda rejected).
    17. Multiple proof errors accumulate and all reported.
    18. Partial application of multi-arg check in filterCheck works.
    19. Inline nested constructor args parse inconsistency (known issue).
    20. Cross-param proof mismatch with same-type args detected.
    21. Single-arg establish with no-arg predicate.
    22. Record field proof: raw value rejected at construction.
    23. fn with ? notation propagates stdlib proof.
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
  let code = match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r62" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* ── R62_ES — Establish body type not checked against declared predicate ──── *)

let test_R62_ES01_establish_wrong_fact_now_rejected () =
  (* FIXED: establish returning a different Fact predicate than declared is now
     caught at compile time. `establish f -> Fact (A n) = B n` is rejected with:
     "body uses fact constructor B; must return declared fact constructor A" *)
  should_fail "body uses fact constructor" {|
#lang tesl
module R62Es01 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
fact IsNegative (n: Int)
establish fakePositive(n: Int) -> Fact (IsPositive n) =
  IsNegative n
|}

let test_R62_ES02_establish_can_call_other_establish () =
  (* establish functions CAN call other establish functions *)
  should_pass {|
#lang tesl
module R62Es02 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact A (n: Int)
fact B (n: Int)
establish proveA(n: Int) -> Fact (A n) = A n
establish proveB(n: Int) -> Fact (B n) =
  let _a = proveA n
  B n
|}

let test_R62_ES03_establish_with_zero_args () =
  (* zero-arg establish is valid *)
  should_pass {|
#lang tesl
module R62Es03 exposing []
import Tesl.Prelude exposing [Fact]
fact GlobalFact
establish proveGlobal() -> Fact (GlobalFact) = GlobalFact
|}

(* ── R62_IA — introAnd with inline args fails proof tracking ─────────────── *)

let test_R62_IA01_introand_inline_args_now_works () =
  (* FIXED: introAnd with inline establish call arguments now correctly tracks
     proofs. `introAnd (proveA x) (proveB x)` now resolves proofs from
     the inline establish calls via proofs_of_evidence_expr fallback. *)
  should_pass {|
#lang tesl
module R62Ia01 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, introAnd, andLeft]
fact A (n: Int)
fact B (n: Int)
establish proveA(n: Int) -> Fact (A n) = A n
establish proveB(n: Int) -> Fact (B n) = B n
fn needsA(n: Int ::: A n) -> Int = n
fn nowWorks(x: Int) -> Int =
  let pab = introAnd (proveA x) (proveB x)
  let la = andLeft pab
  needsA (attachFact x la)
|}

let test_R62_IA02_introand_bound_args_works () =
  (* Workaround: bind fact arguments to let variables before introAnd *)
  should_pass {|
#lang tesl
module R62Ia02 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, introAnd, andLeft]
fact A (n: Int)
fact B (n: Int)
establish proveA(n: Int) -> Fact (A n) = A n
establish proveB(n: Int) -> Fact (B n) = B n
fn needsA(n: Int ::: A n) -> Int = n
fn works(x: Int) -> Int =
  let pa = proveA x
  let pb = proveB x
  let pab = introAnd pa pb
  let la = andLeft pab
  needsA (attachFact x la)
|}

(* ── R62_SL — Single-line if not supported ───────────────────────────────── *)

let test_R62_SL01_single_line_if_rejected () =
  (* Single-line if-then-else is a parse error *)
  should_fail "then.*body.*must be on an indented new line" {|
#lang tesl
module R62Sl01 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int = if n > 0 then n else 0
|}

(* ── R62_SH — Shadowing detection ───────────────────────────────────────── *)

let test_R62_SH01_let_shadowing_rejected () =
  (* let binding that shadows an existing name is rejected *)
  should_fail "shadows" {|
#lang tesl
module R62Sh01 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int =
  let n = 5
  n
|}

(* ── R62_PP — Proof predicate import requirement ─────────────────────────── *)

let test_R62_PP01_predicate_not_imported_rejected () =
  (* Using a proof predicate from another module without importing it is rejected *)
  should_fail "not in scope" {|
#lang tesl
module R62Pp01 exposing []
import Tesl.Prelude exposing [Int]
fn requiresPos(n: Int ::: IsPositive n) -> Int = n
|}

(* ── R62_FN — fn cannot return proof-carrying type ──────────────────────── *)

let test_R62_FN01_fn_with_proof_annotation_rejected () =
  (* fn cannot declare a proof-carrying return type via ::: annotation *)
  should_fail "cannot declare a proof" {|
#lang tesl
module R62Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn test(n: Int) -> n: Int ::: IsPositive n = n
|}

let test_R62_FN02_fn_with_named_pack_proof_works () =
  (* fn CAN use ? notation to propagate stdlib proofs *)
  should_pass {|
#lang tesl
module R62Fn02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.trim, IsTrimmed]
fn safeTrim(s: String) -> String ? IsTrimmed =
  String.trim s
|}

(* ── R62_EX — Exhaustiveness ─────────────────────────────────────────────── *)

let test_R62_EX01_non_exhaustive_case_rejected () =
  (* Non-exhaustive case expression is rejected *)
  should_fail "non-exhaustive" {|
#lang tesl
module R62Ex01 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn name(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
|}

let test_R62_EX02_exhaustive_with_wildcard_accepted () =
  (* Wildcard pattern makes case exhaustive *)
  should_pass {|
#lang tesl
module R62Ex02 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn name(c: Color) -> String =
  case c of
    Red -> "red"
    _ -> "other"
|}

(* ── R62_DU — Duplicate declarations ────────────────────────────────────── *)

let test_R62_DU01_duplicate_fact_rejected () =
  (* Duplicate fact declaration is an error *)
  should_fail "duplicate" {|
#lang tesl
module R62Du01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsPositive (n: Int)
|}

let test_R62_DU02_duplicate_fn_rejected () =
  (* Duplicate function declaration is an error *)
  should_fail "duplicate" {|
#lang tesl
module R62Du02 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int = n
fn test(n: Int) -> Int = n + 1
|}

(* ── R62_CC — Capability cycles ─────────────────────────────────────────── *)

let test_R62_CC01_capability_self_cycle_rejected () =
  should_fail "cycle" {|
#lang tesl
module R62Cc01 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies alpha
handler h(x: Int) -> Int requires [alpha] = x
|}

let test_R62_CC02_capability_mutual_cycle_rejected () =
  should_fail "cycle" {|
#lang tesl
module R62Cc02 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies beta
capability beta implies alpha
handler h(x: Int) -> Int requires [alpha] = x
|}

(* ── R62_FC — filterCheck argument validation ────────────────────────────── *)

let test_R62_FC01_lambda_in_filtercheck_rejected () =
  should_fail "declared.*check.*function.*not an inline lambda" {|
#lang tesl
module R62Fc01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn bad(xs: List Int) -> List Int ::: ForAll (IsPositive) =
  List.filterCheck (fn(n: Int) -> check checkPos n) xs
|}

let test_R62_FC02_plain_fn_in_filtercheck_rejected () =
  should_fail "fn.*not a.*check" {|
#lang tesl
module R62Fc02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fn double(n: Int) -> Int = n * 2
fn bad(xs: List Int) -> List Int =
  List.filterCheck double xs
|}

let test_R62_FC03_partial_application_check_accepted () =
  (* Partial application of a multi-arg check function is valid in filterCheck *)
  should_pass {|
#lang tesl
module R62Fc03 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact InRange (n: Int)
check checkRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange n =
  if lo <= n && n <= hi then
    ok n ::: InRange n
  else
    fail 400 "out of range"
fn filterInRange(xs: List Int) -> List Int =
  List.filterCheck (checkRange 0 100) xs
|}

(* ── R62_AU — Auth call restriction ─────────────────────────────────────── *)

let test_R62_AU01_auth_from_fn_rejected () =
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R62Au01 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth cookieAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn badFn(tok: String) -> String =
  let user = check cookieAuth tok
  user
|}

let test_R62_AU02_auth_from_check_rejected () =
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R62Au02 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
fact IsNonEmpty (s: String)
auth cookieAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
check checkNonEmpty(s: String) -> s: String ::: IsNonEmpty s =
  if String.length s > 0 then
    ok s ::: IsNonEmpty s
  else
    fail 400 "empty"
check badCheck(s: String) -> s: String ::: IsNonEmpty s =
  let _ = check cookieAuth s
  ok s ::: IsNonEmpty s
|}

let test_R62_AU03_auth_from_handler_accepted () =
  should_pass {|
#lang tesl
module R62Au03 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth cookieAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn requiresAuth(s: String ::: Authenticated s) -> String = s
handler myHandler(token: String) -> String =
  let user = check cookieAuth token
  requiresAuth user
|}

(* ── R62_MP — Multiple proof errors all reported ─────────────────────────── *)

let test_R62_MP01_multiple_missing_proofs_all_reported () =
  (* When multiple call sites miss proofs, all errors should be reported *)
  should_fail "requiresC" {|
#lang tesl
module R62Mp01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fn requiresA(n: Int ::: A n) -> Int = n
fn requiresB(n: Int ::: B n) -> Int = n
fn requiresC(n: Int ::: C n) -> Int = n
fn test(x: Int) -> Int =
  requiresA x + requiresB x + requiresC x
|}

(* ── R62_CP — Cross-param proof with same type ───────────────────────────── *)

let test_R62_CP01_wrong_param_proof_caught () =
  (* Passing a proven value from one param as proof for different param *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R62Cp01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn requiresPos(n: Int ::: IsPositive n) -> Int = n
fn test(x: Int, y: Int) -> Int =
  let provenX = check checkPos x
  requiresPos y
|}

(* ── R62_RD — Recursive data types ──────────────────────────────────────── *)

let test_R62_RD01_recursive_adt_accepted () =
  should_pass {|
#lang tesl
module R62Rd01 exposing []
import Tesl.Prelude exposing [Int]
type Tree
  = Leaf
  | Node left:Tree value:Int right:Tree
fn sumTree(t: Tree) -> Int =
  case t of
    Leaf -> 0
    Node l v r -> sumTree l + v + sumTree r
|}

(* ── R62_NE — Nested constructor inline parse issue ─────────────────────── *)

let test_R62_NE01_nested_inline_constructor_now_works () =
  (* FIXED: Multi-line multi-arg constructor applications now parse correctly.
     Indented argument blocks are treated as continuation arguments to the
     constructor/function on the preceding line. *)
  should_pass {|
#lang tesl
module R62Ne01 exposing []
import Tesl.Prelude exposing [Int]
type Tree
  = Leaf
  | Node left:Tree value:Int right:Tree
fn sumTree(t: Tree) -> Int =
  case t of
    Leaf -> 0
    Node l v r -> sumTree l + v + sumTree r
fn buildTreeMultiLine() -> Tree =
  Node
    (Node Leaf 1 Leaf)
    2
    (Node (Node Leaf 3 Leaf) 4 Leaf)
|}

(* ── R62_FR — forgetFact and re-prove roundtrip ─────────────────────────── *)

let test_R62_FR01_forget_and_reprove_works () =
  should_pass {|
#lang tesl
module R62Fr01 exposing []
import Tesl.Prelude exposing [Int, forgetFact, attachFact, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
fn requiresPos(n: Int ::: IsPositive n) -> Int = n
fn test(x: Int) -> Int =
  let p1 = provePos x
  let proved = attachFact x p1
  let raw = forgetFact proved
  let p2 = provePos raw
  let reproved = attachFact raw p2
  requiresPos reproved
|}

(* ── R62_PL — Pipeline operators ─────────────────────────────────────────── *)

let test_R62_PL01_pipe_right_operator_works () =
  should_pass {|
#lang tesl
module R62Pl01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.trim, String.length]
fn double(n: Int) -> Int = n * 2
fn test(s: String) -> Int =
  s |> String.trim |> String.length |> double
|}

let test_R62_PL02_pipe_left_operator_works () =
  should_pass {|
#lang tesl
module R62Pl02 exposing []
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
fn triple(n: Int) -> Int = n * 3
fn test(n: Int) -> Int =
  triple <| double <| n
|}

(* ── R62_CI — Capability implication chain depth ─────────────────────────── *)

let test_R62_CI01_five_level_cap_chain_works () =
  (* Capability implication chains of 5+ levels work (fixed in R61) *)
  should_pass {|
#lang tesl
module R62Ci01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability level1 implies level2
capability level2 implies level3
capability level3 implies level4
capability level4 implies level5
capability level5 implies dbRead
fn readData(x: Int) -> Int requires [dbRead] = x
handler h(x: Int) -> Int requires [level1] = readData x
|}

(* ── R62_IN — Inline if constraint ─────────────────────────────────────────*)

let test_R62_IN01_if_requires_else () =
  should_fail "expected else" {|
#lang tesl
module R62In01 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int =
  if n > 0 then
    n
|}

(* ── R62_WH — Where guards in case ─────────────────────────────────────────*)

let test_R62_WH01_where_guard_in_case_works () =
  should_pass {|
#lang tesl
module R62Wh01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn classify(m: Maybe Int) -> String =
  case m of
    Nothing -> "nothing"
    Something v where v > 0 -> "positive"
    Something v where v < 0 -> "negative"
    Something _ -> "zero"
|}

let test_R62_WH02_all_guarded_arms_non_exhaustive_rejected () =
  should_fail "guarded arms" {|
#lang tesl
module R62Wh02 exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fn badMatch(m: Maybe Int) -> String =
  case m of
    Nothing where True -> "nothing"
    Something _ where True -> "something"
|}

(* ── R62_TA — Type alias proof ──────────────────────────────────────────── *)

let test_R62_TA01_newtype_carries_proof () =
  (* Type aliases (newtypes) can carry proofs independently from base type *)
  should_pass {|
#lang tesl
module R62Ta01 exposing []
import Tesl.Prelude exposing [String]
type UserId = String
fact ValidUser (u: UserId)
check checkUser(u: UserId) -> u: UserId ::: ValidUser u =
  ok u ::: ValidUser u
fn requiresValidUser(u: UserId ::: ValidUser u) -> String = u.value
fn test(raw: String) -> String =
  let uid = UserId raw
  let valid = check checkUser uid
  requiresValidUser valid
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review62-Antagonistic" [
    "establish-type-checking", [
      test_case "R62_ES01 establish wrong Fact predicate now rejected (FIXED)" `Quick test_R62_ES01_establish_wrong_fact_now_rejected;
      test_case "R62_ES02 establish can call other establish" `Quick test_R62_ES02_establish_can_call_other_establish;
      test_case "R62_ES03 zero-arg establish works" `Quick test_R62_ES03_establish_with_zero_args;
    ];
    "introand-inline-args", [
      test_case "R62_IA01 introAnd inline args now works (FIXED)" `Quick test_R62_IA01_introand_inline_args_now_works;
      test_case "R62_IA02 introAnd bound args works correctly" `Quick test_R62_IA02_introand_bound_args_works;
    ];
    "single-line-if", [
      test_case "R62_SL01 single-line if rejected with clear error" `Quick test_R62_SL01_single_line_if_rejected;
    ];
    "shadowing", [
      test_case "R62_SH01 let shadowing rejected" `Quick test_R62_SH01_let_shadowing_rejected;
    ];
    "proof-predicate-import", [
      test_case "R62_PP01 unimported predicate rejected" `Quick test_R62_PP01_predicate_not_imported_rejected;
    ];
    "fn-proof-restrictions", [
      test_case "R62_FN01 fn with proof annotation rejected" `Quick test_R62_FN01_fn_with_proof_annotation_rejected;
      test_case "R62_FN02 fn with ? notation for stdlib proof works" `Quick test_R62_FN02_fn_with_named_pack_proof_works;
    ];
    "exhaustiveness", [
      test_case "R62_EX01 non-exhaustive case rejected" `Quick test_R62_EX01_non_exhaustive_case_rejected;
      test_case "R62_EX02 wildcard makes case exhaustive" `Quick test_R62_EX02_exhaustive_with_wildcard_accepted;
    ];
    "duplicate-decls", [
      test_case "R62_DU01 duplicate fact rejected" `Quick test_R62_DU01_duplicate_fact_rejected;
      test_case "R62_DU02 duplicate fn rejected" `Quick test_R62_DU02_duplicate_fn_rejected;
    ];
    "capability-cycles", [
      test_case "R62_CC01 self-cycle capability rejected" `Quick test_R62_CC01_capability_self_cycle_rejected;
      test_case "R62_CC02 mutual cycle capability rejected" `Quick test_R62_CC02_capability_mutual_cycle_rejected;
    ];
    "filtercheck-soundness", [
      test_case "R62_FC01 lambda in filterCheck rejected" `Quick test_R62_FC01_lambda_in_filtercheck_rejected;
      test_case "R62_FC02 plain fn in filterCheck rejected" `Quick test_R62_FC02_plain_fn_in_filtercheck_rejected;
      test_case "R62_FC03 partial application in filterCheck accepted" `Quick test_R62_FC03_partial_application_check_accepted;
    ];
    "auth-restriction", [
      test_case "R62_AU01 auth from fn rejected" `Quick test_R62_AU01_auth_from_fn_rejected;
      test_case "R62_AU02 auth from check rejected" `Quick test_R62_AU02_auth_from_check_rejected;
      test_case "R62_AU03 auth from handler accepted" `Quick test_R62_AU03_auth_from_handler_accepted;
    ];
    "multiple-errors", [
      test_case "R62_MP01 multiple missing proofs all reported" `Quick test_R62_MP01_multiple_missing_proofs_all_reported;
    ];
    "cross-param-proof", [
      test_case "R62_CP01 wrong param proof caught" `Quick test_R62_CP01_wrong_param_proof_caught;
    ];
    "recursive-adt", [
      test_case "R62_RD01 recursive ADT type accepted" `Quick test_R62_RD01_recursive_adt_accepted;
    ];
    "nested-constructor-parse", [
      test_case "R62_NE01 nested inline constructor now works (FIXED)" `Quick test_R62_NE01_nested_inline_constructor_now_works;
    ];
    "forget-reprove", [
      test_case "R62_FR01 forgetFact then re-prove roundtrip works" `Quick test_R62_FR01_forget_and_reprove_works;
    ];
    "pipeline-operators", [
      test_case "R62_PL01 |> pipe-right works" `Quick test_R62_PL01_pipe_right_operator_works;
      test_case "R62_PL02 <| pipe-left works" `Quick test_R62_PL02_pipe_left_operator_works;
    ];
    "capability-chain-depth", [
      test_case "R62_CI01 5-level cap chain works" `Quick test_R62_CI01_five_level_cap_chain_works;
    ];
    "if-else-constraint", [
      test_case "R62_IN01 if without else is parse error" `Quick test_R62_IN01_if_requires_else;
    ];
    "where-guards", [
      test_case "R62_WH01 where guard in case works" `Quick test_R62_WH01_where_guard_in_case_works;
      test_case "R62_WH02 all-guarded arms non-exhaustive" `Quick test_R62_WH02_all_guarded_arms_non_exhaustive_rejected;
    ];
    "newtype-proof", [
      test_case "R62_TA01 newtype carries proof independently" `Quick test_R62_TA01_newtype_carries_proof;
    ];
  ]
