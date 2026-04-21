(** Antagonistic regression tests for Critical Review 61.

    This review audits:
    1.  Conjunction ordering in `ok` expression: `ok n ::: B n && A n` is rejected when
        return spec declares `A n && B n` — proof order is strictly positional.
    2.  3-level capability chain false positive: handler `requires [level1]` where
        level1 → level2 → level3 → dbRead incorrectly fails (only 2-level deep in cap_covered).
    3.  Compiler hangs (timeout) on invalid tuple literal syntax `[("a", 1)]` — should error.
    4.  Conjunction ordering at call sites IS commutative (B && A required; carry A && B = OK).
    5.  3-level capability chain: 2-level deep still works.
    6.  ForAll parameter requires explicit subject variable in annotation.
    7.  `fn` cannot mint proofs with `ok :::`.
    8.  `establish` cannot call `check` or `auth`.
    9.  Unknown proof predicate in annotation is caught.
    10. `detachFact` on plain (non-proof) value must fail with clear error.
    11. Named function with proof-annotated params rejected in List.map on ForAll list.
    12. Multi-param proof ordering: swapped args at call site caught.
    13. Int.divide requires IsNonZero proof on denominator.
    14. ForAll return must declare inner proof subject; mismatch caught.
    15. forgetFact strips proof — downstream proof requirement fails statically.
    16. Newtype .value accessor loses proof — downstream requirement fails.
    17. Record with proof-annotated field: construction requires proof, raw value rejected.
    18. Exhaustiveness: 5-constructor ADT with missing arm.
    19. Auth cannot be called from plain `fn` body.
    20. Establish returning wrong type (plain Int instead of Fact) is caught.
    21. Proof subject using dotted path rejected.
    22. Missing import for proof predicate gives clear error.
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

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r61" "" in
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

(* ── R61_CO — Conjunction ordering in ok expression ────────────────────────── *)

let test_R61_CO01_ok_reversed_conjunction_now_accepted () =
  (* FIXED (BUG-03): The ok conjunction is now normalised before comparison.
     `ok n ::: B n && A n` where return spec declares `A n && B n` is now ACCEPTED.
     Conjunction order in ok expressions no longer matters. *)
  should_pass {|
#lang tesl
module R61Co01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkBoth(n: Int) -> n: Int ::: A n && B n =
  if n > 0 then
    ok n ::: B n && A n
  else
    fail 400 "bad"
|}

let test_R61_CO02_ok_same_order_accepted () =
  (* Correct order: ok proof matches declared return spec exactly *)
  should_pass {|
#lang tesl
module R61Co02 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkBoth(n: Int) -> n: Int ::: A n && B n =
  if n > 0 then
    ok n ::: A n && B n
  else
    fail 400 "bad"
|}

let test_R61_CO03_callsite_commutativity_accepted () =
  (* At CALL SITES, conjunction is commutative: if a value carries A && B,
     it satisfies a function requiring B && A. Only the ok-expression is strict. *)
  should_pass {|
#lang tesl
module R61Co03 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then 
    ok n ::: A n
  else
    fail 400 "bad"
check checkB(n: Int ::: A n) -> n: Int ::: A n && B n =
  if n > 1 then 
    ok n ::: A n && B n
  else
    fail 400 "bad"
fn requiresBThenA(n: Int ::: B n && A n) -> Int = n
fn test(x: Int) -> Int =
  let a = check checkA x
  let b = check checkB a
  requiresBThenA b
|}

(* ── R61_CP — Capability implication chain depth ────────────────────────────── *)

let test_R61_CP01_3level_cap_chain_now_works () =
  (* FIXED (BUG-02): cap_covered now uses full recursive transitive closure.
     level1 → level2 → level3 → dbRead: handler requires [level1] now correctly
     passes because level1 transitively implies dbRead through 3 levels. *)
  should_pass {|
#lang tesl
module R61Cp01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability level1 implies level2
capability level2 implies level3
capability level3 implies dbRead
fn readSomething(x: Int) -> Int requires [dbRead] = x
handler testHandler(req: Int) -> Int requires [level1] =
  readSomething req
|}

let test_R61_CP02_2level_cap_chain_works () =
  (* 2-level deep implication correctly works: level1 → dbRead is fine *)
  should_pass {|
#lang tesl
module R61Cp02 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability level1 implies dbRead
fn readSomething(x: Int) -> Int requires [dbRead] = x
handler testHandler(req: Int) -> Int requires [level1] =
  readSomething req
|}

let test_R61_CP03_4level_cap_chain_now_works () =
  (* FIXED (BUG-02): Full recursive closure handles arbitrarily deep chains.
     4-level chain level1→level2→level3→level4→dbRead now works correctly. *)
  should_pass {|
#lang tesl
module R61Cp03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability level1 implies level2
capability level2 implies level3
capability level3 implies level4
capability level4 implies dbRead
fn readSomething(x: Int) -> Int requires [dbRead] = x
handler testHandler(req: Int) -> Int requires [level1] =
  readSomething req
|}

(* ── R61_TH — Tuple literal syntax: error instead of hang ───────────────────── *)

let test_R61_TH01_comma_pair_syntax_gives_parse_error () =
  (* FIXED (BUG-01): [("a", 1)] no longer hangs the compiler.
     Now gives a clear parse error: "expected ) but got ,".
     Tesl tuples use `Tuple2 key val` syntax, not `(key, val)`. *)
  should_fail "expected ) but got ," {|
#lang tesl
module R61Th01 exposing []
import Tesl.Prelude exposing [Int, String]
fn test() -> Int =
  let x = [("a", 1)]
  1
|}

let test_R61_TH02_correct_tuple2_syntax_accepted () =
  (* Correct Tuple2 syntax works fine — no parse error *)
  should_pass {|
#lang tesl
module R61Th02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Tuple exposing [Tuple2]
import Tesl.Dict exposing [Dict, Dict.fromList, Dict.size]
fn test() -> Int =
  let d = Dict.fromList [Tuple2 "a" 1, Tuple2 "b" 2]
  Dict.size d
|}

(* ── R61_FW — ForAll parameter requires explicit subject ─────────────────────── *)

let test_R61_FW01_forall_param_without_subject_rejected () =
  (* ForAll annotation on parameter must include explicit subject variable.
     `xs: List Int ::: ForAll (IsPositive)` is rejected without the subject.
     Must write: `xs: List Int ::: ForAll (IsPositive) xs` *)
  should_fail "ForAll" {|
#lang tesl
module R61Fw01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn countPositives(xs: List Int ::: ForAll (IsPositive)) -> Int =
  List.length xs
|}

let test_R61_FW02_forall_param_with_subject_accepted () =
  (* Correct syntax includes the explicit subject variable at the end *)
  should_pass {|
#lang tesl
module R61Fw02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn countPositives(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs
|}

(* ── R61_FN — fn cannot mint proofs ─────────────────────────────────────────── *)

let test_R61_FN01_fn_cannot_mint_proof () =
  (* Plain `fn` cannot use `ok ::: proof` to introduce a proof.
     Only check/auth/establish functions may produce proofs. *)
  should_fail "ok ::: proof" {|
#lang tesl
module R61Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn tryMintProof(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|}

(* ── R61_ES — establish restrictions ────────────────────────────────────────── *)

let test_R61_ES01_establish_cannot_call_check () =
  (* establish must be total; calling check (which can fail) is forbidden *)
  should_fail "establish" {|
#lang tesl
module R61Es01 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
establish tryProve(n: Int) -> Fact (IsPositive n) =
  let _ = check checkPos n
  IsPositive n
|}

let test_R61_ES02_establish_cannot_use_fail () =
  (* establish must be total; using fail is forbidden *)
  should_fail "establish" {|
#lang tesl
module R61Es02 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish badEstablish(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let test_R61_ES03_establish_returning_wrong_type_rejected () =
  (* establish must return Fact (...) or Maybe (Fact (...)). Returning Int is rejected. *)
  should_fail "establish" {|
#lang tesl
module R61Es03 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish badReturn(n: Int) -> Int =
  n
|}

(* ── R61_DP — dotted path in proof subject rejected ──────────────────────────── *)

let test_R61_DP01_dotted_path_proof_subject_rejected () =
  (* GDP subjects must be simple variable names — dotted paths (e.g. c.value)
     are not trackable and are rejected with a clear error. *)
  should_fail "dotted" {|
#lang tesl
module R61Dp01 exposing []
import Tesl.Prelude exposing [Int, String]
record Container { value: Int }
fact IsPositive (n: Int)
check checkPos(c: Container) -> c: Container ::: IsPositive c.value =
  if c.value > 0 then
    ok c ::: IsPositive c.value
  else
    fail 400 "bad"
|}

(* ── R61_AU — auth cannot be called from fn body ─────────────────────────────── *)

let test_R61_AU01_auth_not_callable_from_fn () =
  (* FIXED (LIMIT-06): auth functions are now restricted to handler bodies.
     Calling an auth function from a plain `fn` is rejected with a clear error.
     Auth functions are HTTP-level identity gates — their fail 401 is only
     meaningful inside the request/response cycle of a handler. *)
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R61Au01 exposing []
import Tesl.Prelude exposing [Int, String]
fact Authenticated (s: String)
auth checkAuth(token: String) -> token: String ::: Authenticated token =
  ok token ::: Authenticated token
fn callAuthFromFn(tok: String) -> String =
  let authed = check checkAuth tok
  authed
|}

(* ── R61_NW — newtype .value loses proof ─────────────────────────────────────── *)

let test_R61_NW01_newtype_value_loses_proof () =
  (* Accessing .value on a proven newtype loses the proof.
     The inner String extracted via .value does not carry the proof. *)
  should_fail "proof" {|
#lang tesl
module R61Nw01 exposing []
import Tesl.Prelude exposing [String]
type SafeString = String
fact IsSafe (s: SafeString)
check checkSafe(s: SafeString) -> s: SafeString ::: IsSafe s =
  ok s ::: IsSafe s
fn requiresProvenString(s: String ::: IsSafe s) -> String = s
fn test(raw: String) -> String =
  let safe = check checkSafe (SafeString raw)
  requiresProvenString safe.value
|}

(* ── R61_RC — Record with proof-annotated field: raw value rejected ───────────── *)

let test_R61_RC01_annotated_record_field_rejects_raw_value () =
  (* A record with a proof-annotated field cannot be constructed with a raw (unproven) value.
     Must use a proven value obtained from a check function. *)
  should_fail "proof" {|
#lang tesl
module R61Rc01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
fact TitleSafe (s: String)
check checkTitle(s: String) -> s: String ::: TitleSafe s =
  if String.length s < 100 then 
    ok s ::: TitleSafe s
  else
    fail 400 "bad"
record SafeItem {
  title: String ::: TitleSafe title
}
fn buildBadItem(raw: String) -> SafeItem =
  SafeItem { title: raw }
|}

(* ── R61_EX — Exhaustiveness: 5-constructor ADT ─────────────────────────────── *)

let test_R61_EX01_five_ctor_missing_one_rejected () =
  (* A 5-constructor ADT with one missing arm in case is rejected *)
  should_fail "exhaustive" {|
#lang tesl
module R61Ex01 exposing []
import Tesl.Prelude exposing [String]
type Status
  = Active
  | Pending
  | Suspended
  | Deleted
  | Archived
fn describe(s: Status) -> String =
  case s of
    Active -> "active"
    Pending -> "pending"
    Suspended -> "suspended"
    Deleted -> "deleted"
|}

let test_R61_EX02_five_ctor_all_covered_accepted () =
  (* All 5 constructors covered: no error *)
  should_pass {|
#lang tesl
module R61Ex02 exposing []
import Tesl.Prelude exposing [String]
type Status
  = Active
  | Pending
  | Suspended
  | Deleted
  | Archived
fn describe(s: Status) -> String =
  case s of
    Active -> "active"
    Pending -> "pending"
    Suspended -> "suspended"
    Deleted -> "deleted"
    Archived -> "archived"
|}

(* ── R61_MP — Multi-param proof: swapped args at call site caught ─────────────── *)

let test_R61_MP01_swapped_multi_param_args_rejected () =
  (* Multi-param proof InRange lo hi n: swapping lo and hi at call site is caught.
     Passing (hi, lo, n) instead of (lo, hi, n) fails because the subjects are different. *)
  should_fail "proof" {|
#lang tesl
module R61Mp01 exposing []
import Tesl.Prelude exposing [Int]
fact InRange (lo: Int) (hi: Int) (n: Int)
check checkRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then 
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"
fn requiresInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n
fn test(lo: Int, hi: Int, x: Int) -> Int =
  let checked = check checkRange lo hi x
  requiresInRange hi lo checked
|}

(* ── R61_DV — Int.divide proof requirement ──────────────────────────────────── *)

let test_R61_DV01_divide_without_proof_rejected () =
  (* Int.divide requires IsNonZero proof on denominator; omitting it is an error *)
  should_fail "IsNonZero" {|
#lang tesl
module R61Dv01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn unsafeDivide(a: Int, b: Int) -> Int =
  Int.divide a b
|}

let test_R61_DV02_divide_with_proof_accepted () =
  (* Int.divide with IsNonZero proof succeeds *)
  should_pass {|
#lang tesl
module R61Dv02 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide, Int.nonZero]
fn safeDivide(a: Int, b: Int) -> Int =
  let nonZeroB = check Int.nonZero b
  Int.divide a nonZeroB
|}

(* ── R61_FG — forgetFact strips proof statically ─────────────────────────────── *)

let test_R61_FG01_forget_fact_prevents_proof_use () =
  (* After forgetFact, the proof is stripped. Downstream proof requirement fails. *)
  should_fail "proof" {|
#lang tesl
module R61Fg01 exposing []
import Tesl.Prelude exposing [Int, forgetFact]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n
fn test(x: Int) -> Int =
  let proven = check checkPos x
  let forgotten = forgetFact proven
  requiresPositive forgotten
|}

(* ── R61_FF — ForAll return with wrong inner proof mismatch caught ────────────── *)

let test_R61_FF01_forall_inner_proof_mismatch_rejected () =
  (* check function returns ForAll (IsSmall) but filterCheck can only
     produce the proofs that checkPos establishes (IsPositive). Mismatch.
     Error message mentions "missing" predicates. *)
  should_fail "missing" {|
#lang tesl
module R61Ff01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn wrongForAll(xs: List Int) -> List Int ::: ForAll (IsSmall) =
  List.filterCheck checkPos xs
|}

(* ── R61_NA — Named fn with proof params rejected in List.map on ForAll list ─── *)

let test_R61_NA01_named_fn_in_list_map_rejected () =
  (* Named functions with proof-annotated parameters cannot be passed directly
     to List.map on a ForAll list — only inline lambdas work. This is a known
     limitation documented in lesson30. *)
  should_fail "proof annotations" {|
#lang tesl
module R61Na01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.map]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn requiresProof(n: Int ::: IsPositive n) -> Int = n * 2
fn mapAll(xs: List Int ::: ForAll (IsPositive) xs) -> List Int =
  List.map requiresProof xs
|}

let test_R61_NA02_inline_lambda_in_list_map_accepted () =
  (* Inline lambda with proof-annotated param IS accepted in List.map *)
  should_pass {|
#lang tesl
module R61Na02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.map]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn requiresProof(n: Int ::: IsPositive n) -> Int = n * 2
fn mapAll(xs: List Int ::: ForAll (IsPositive) xs) -> List Int =
  List.map (fn(n: Int ::: IsPositive n) -> requiresProof n) xs
|}

(* ── R61_6C — Deep check chains ─────────────────────────────────────────────── *)

let test_R61_6C01_six_check_chain_accepted () =
  (* 6-check accumulation chain compiles successfully *)
  should_pass {|
#lang tesl
module R61_6c01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)
fact F (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then 
    ok n ::: A n
  else
    fail 400 "bad"
check checkB(n: Int ::: A n) -> n: Int ::: A n && B n =
  if n > 1 then 
    ok n ::: A n && B n
  else
    fail 400 "bad"
check checkC(n: Int ::: A n && B n) -> n: Int ::: A n && B n && C n =
  if n > 2 then 
    ok n ::: A n && B n && C n
  else
    fail 400 "bad"
check checkD(n: Int ::: A n && B n && C n) -> n: Int ::: A n && B n && C n && D n =
  if n > 3 then 
    ok n ::: A n && B n && C n && D n
  else
    fail 400 "bad"
check checkE(n: Int ::: A n && B n && C n && D n) -> n: Int ::: A n && B n && C n && D n && E n =
  if n > 4 then 
    ok n ::: A n && B n && C n && D n && E n
  else
    fail 400 "bad"
check checkF(n: Int ::: A n && B n && C n && D n && E n) -> n: Int ::: A n && B n && C n && D n && E n && F n =
  if n > 5 then 
    ok n ::: A n && B n && C n && D n && E n && F n
  else
    fail 400 "bad"
fn needsAll6(n: Int ::: A n && B n && C n && D n && E n && F n) -> Int = n
fn build6Chain(x: Int) -> Int =
  let a = check checkA x
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  let e = check checkE d
  let f = check checkF e
  needsAll6 f
|}

(* ── R61_MR — Mutual recursion with check functions ─────────────────────────── *)

let test_R61_MR01_mutual_recursion_with_checks_accepted () =
  (* check functions can mutually recurse with each other *)
  should_pass {|
#lang tesl
module R61Mr01 exposing []
import Tesl.Prelude exposing [Int]
fact IsEven (n: Int)
fact IsOdd (n: Int)
check checkEven(n: Int) -> n: Int ::: IsEven n =
  if n == 0 then
    ok n ::: IsEven n
  else
    let _odd = check checkOdd (n - 1)
    ok n ::: IsEven n
check checkOdd(n: Int) -> n: Int ::: IsOdd n =
  if n == 1 then
    ok n ::: IsOdd n
  else
    let _even = check checkEven (n - 1)
    ok n ::: IsOdd n
fn requiresEven(n: Int ::: IsEven n) -> Int = n
fn test(x: Int) -> Int =
  let e = check checkEven x
  requiresEven e
|}

(* ── R61_IM — introAnd with 5 proofs accepted ───────────────────────────────── *)

let test_R61_IM01_intro_and_with_5_proofs_accepted () =
  (* introAnd can chain 5 times to combine 5 separate establish proofs *)
  should_pass {|
#lang tesl
module R61Im01 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, forgetFact, introAnd, andLeft]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)
fact E (n: Int)
establish proveA(n: Int) -> Fact (A n) = A n
establish proveB(n: Int) -> Fact (B n) = B n
establish proveC(n: Int) -> Fact (C n) = C n
establish proveD(n: Int) -> Fact (D n) = D n
establish proveE(n: Int) -> Fact (E n) = E n
fn needsA(n: Int ::: A n) -> Int = n
fn combine5(x: Int) -> Int =
  let pa = proveA x
  let pb = proveB x
  let pc = proveC x
  let pd = proveD x
  let pe = proveE x
  let pab = introAnd pa pb
  let pabc = introAnd pab pc
  let pabcd = introAnd pabc pd
  let pabcde = introAnd pabcd pe
  let x2 = attachFact x pabcde
  let la = andLeft pabcde
  let x3 = forgetFact x2 ::: la
  needsA x3
|}

(* ── R61_EM — establish with Maybe conditional proof ────────────────────────── *)

let test_R61_EM01_establish_maybe_accepted () =
  (* establish can return Maybe (Fact (P)) for conditional proof introduction *)
  should_pass {|
#lang tesl
module R61Em01 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact]
import Tesl.Maybe exposing [Maybe(..)]
fact InRange (lo: Int) (hi: Int) (n: Int)
establish proveInRange(lo: Int, hi: Int, n: Int) -> Maybe (Fact (InRange lo hi n)) =
  if lo <= n && n <= hi then
    Something (InRange lo hi n)
  else
    Nothing
fn requiresInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n
fn tryUse(lo: Int, hi: Int, x: Int) -> Int =
  let proof = proveInRange lo hi x
  case proof of
    Nothing -> -1
    Something p ->
      let x2 = attachFact x p
      requiresInRange lo hi x2
|}

(* ── R61_SF — Stdlib proof-returning functions ───────────────────────────────── *)

let test_R61_SF01_string_trim_provides_istrimmed_proof () =
  (* String.trim returns a value with IsTrimmed proof attached *)
  should_pass {|
#lang tesl
module R61Sf01 exposing []
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.trim, IsTrimmed]
fn requiresTrimmed(s: String ::: IsTrimmed s) -> String = s
fn test(raw: String) -> String =
  let t = String.trim raw
  requiresTrimmed t
|}

let test_R61_SF02_list_sort_provides_issorted_proof () =
  (* List.sort returns a value with IsSorted proof attached *)
  should_pass {|
#lang tesl
module R61Sf02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.sort, IsSorted]
fn requiresSorted(xs: List Int ::: IsSorted xs) -> List Int = xs
fn test(xs: List Int) -> List Int =
  let s = List.sort xs
  requiresSorted s
|}

(* ── R61_3F — Record with 3 proof-annotated fields ──────────────────────────── *)

let test_R61_3F01_three_proof_fields_accepted () =
  (* Record with 3 proof-annotated fields compiles and construction works *)
  should_pass {|
#lang tesl
module R61_3f01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
fact TitleSafe (s: String)
fact LengthOk (n: Int)
fact IsPositive (n: Int)
check checkTitle(s: String) -> s: String ::: TitleSafe s =
  if String.length s < 100 then 
    ok s ::: TitleSafe s
  else
    fail 400 "bad"
check checkLength(n: Int) -> n: Int ::: LengthOk n =
  if n > 0 && n < 100 then 
    ok n ::: LengthOk n
  else
    fail 400 "bad"
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then 
    ok n ::: IsPositive n
  else
    fail 400 "bad"
record SafeTriple {
  title: String ::: TitleSafe title
  count: Int ::: LengthOk count
  score: Int ::: IsPositive score
}
fn build(t: String, c: Int, s: Int) -> SafeTriple =
  let st = check checkTitle t
  let sc = check checkLength c
  let ss = check checkPos s
  SafeTriple { title: st, count: sc, score: ss }
|}

let test_R61_3F02_three_proof_fields_raw_rejected () =
  (* Constructing a 3-proof-field record with raw (unproven) values is rejected *)
  should_fail "proof" {|
#lang tesl
module R61_3f02 exposing []
import Tesl.Prelude exposing [Int, String]
fact TitleSafe (s: String)
fact LengthOk (n: Int)
fact IsPositive (n: Int)
record SafeTriple {
  title: String ::: TitleSafe title
  count: Int ::: LengthOk count
  score: Int ::: IsPositive score
}
fn buildBad(t: String, c: Int, s: Int) -> SafeTriple =
  SafeTriple { title: t, count: c, score: s }
|}

(* ══════════════════════════════════════════════════════════════════════════
   NEW COMPREHENSIVE TESTS FOR FIXED AREAS
   ══════════════════════════════════════════════════════════════════════════ *)

(* ── BUG-01 extended: various bad list literals ──────────────────────────── *)

let test_R61_TH03_nested_paren_in_list_gives_error () =
  (* Multi-element comma-pair list also gives a parse error (no hang) *)
  should_fail "expected )" {|
#lang tesl
module R61Th03 exposing []
import Tesl.Prelude exposing [Int, String]
fn test() -> Int =
  let x = [("a", 1), ("b", 2), ("c", 3)]
  1
|}

let test_R61_TH04_empty_list_still_valid () =
  should_pass {|
#lang tesl
module R61Th04 exposing []
import Tesl.Prelude exposing [Int, List]
fn test() -> List Int = []
|}

let test_R61_TH05_singleton_list_still_valid () =
  should_pass {|
#lang tesl
module R61Th05 exposing []
import Tesl.Prelude exposing [Int, List]
fn test() -> List Int = [42]
|}

(* ── BUG-02 extended: capability chain correctness ──────────────────────── *)

let test_R61_CP04_5level_cap_chain_works () =
  (* 5-level deep transitive chain works with the recursive expansion *)
  should_pass {|
#lang tesl
module R61Cp04 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability appService implies businessLogic
capability businessLogic implies dataAccess
capability dataAccess implies cacheLayer
capability cacheLayer implies dbRead
fn readData(x: Int) -> Int requires [dbRead] = x
handler serve(req: Int) -> Int requires [appService] =
  readData req
|}

let test_R61_CP05_diamond_cap_chain_works () =
  (* Diamond implication: fullAccess implies both readAccess and writeAccess;
     each of those implies a DB capability.  Handler requires only [fullAccess]. *)
  should_pass {|
#lang tesl
module R61Cp05 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]
capability fullAccess implies readAccess, writeAccess
capability readAccess implies dbRead
capability writeAccess implies dbWrite
fn readData(x: Int) -> Int requires [dbRead] = x
fn writeData(x: Int) -> Int requires [dbWrite] = x
handler serve(req: Int) -> Int requires [fullAccess] =
  let r = readData req
  writeData r
|}

let test_R61_CP06_cap_cycle_detection_still_works () =
  (* Capability cycles are still caught — recursive expansion terminates
     because the hashtable in expand_declared prevents revisiting. *)
  should_fail "cycle" {|
#lang tesl
module R61Cp06 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies beta
capability beta implies alpha
handler testHandler(req: Int) -> Int requires [alpha] = req
|}

let test_R61_CP07_fn_missing_cap_still_caught () =
  (* fn functions that need a capability but don't declare it are still caught *)
  should_fail "does not declare" {|
#lang tesl
module R61Cp07 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
fn readData(x: Int) -> Int requires [dbRead] = x
fn callsRead(y: Int) -> Int =
  readData y
|}

(* ── BUG-03 extended: conjunction normalisation ──────────────────────────── *)

let test_R61_CO04_three_term_conjunction_any_order_accepted () =
  (* A && B && C, C && A && B, B && C && A — all equivalent *)
  should_pass {|
#lang tesl
module R61Co04 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
check checkAll(n: Int) -> n: Int ::: A n && B n && C n =
  if n > 0 then
    ok n ::: C n && A n && B n
  else
    fail 400 "bad"
|}

let test_R61_CO05_five_term_conjunction_reverse_order () =
  (* 5-term conjunction in completely reversed order still accepted *)
  should_pass {|
#lang tesl
module R61Co05 exposing []
import Tesl.Prelude exposing [Int]
fact P1 (n: Int)
fact P2 (n: Int)
fact P3 (n: Int)
fact P4 (n: Int)
fact P5 (n: Int)
check checkAll(n: Int) -> n: Int ::: P1 n && P2 n && P3 n && P4 n && P5 n =
  if n > 0 then
    ok n ::: P5 n && P4 n && P3 n && P2 n && P1 n
  else
    fail 400 "bad"
|}

let test_R61_CO06_wrong_predicate_still_rejected () =
  (* Even with normalisation, a wrong predicate is still caught *)
  should_fail "ok proof does not match declared return spec" {|
#lang tesl
module R61Co06 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
check checkBad(n: Int) -> n: Int ::: A n && B n =
  if n > 0 then
    ok n ::: A n && C n
  else
    fail 400 "bad"
|}

let test_R61_CO07_single_predicate_still_works () =
  (* Single (non-conjunction) proofs are unaffected by normalisation *)
  should_pass {|
#lang tesl
module R61Co07 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|}

let test_R61_CO08_conjunction_with_multi_arg_pred () =
  (* Conjunctions with multi-argument predicates normalise correctly *)
  should_pass {|
#lang tesl
module R61Co08 exposing []
import Tesl.Prelude exposing [Int]
fact InRange (lo: Int) (hi: Int) (n: Int)
fact IsPositive (n: Int)
check checkRangePos(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n && IsPositive n =
  if lo <= n && n <= hi && n > 0 then
    ok n ::: IsPositive n && InRange lo hi n
  else
    fail 400 "bad"
|}

(* ── LIMIT-06 extended: auth restriction ────────────────────────────────── *)

let test_R61_AU02_auth_from_check_rejected () =
  (* check functions cannot call auth functions *)
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R61Au02 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
fact IsNonEmpty (s: String)
auth authUser(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
check checkAndAuth(s: String) -> s: String ::: IsNonEmpty s =
  let _ = check authUser s
  ok s ::: IsNonEmpty s
|}

let test_R61_AU03_auth_from_fn_with_alias_rejected () =
  (* Even through a helper fn called from another fn, auth restriction is enforced *)
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R61Au03 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth authUser(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn helper(tok: String) -> String =
  let authed = check authUser tok
  authed
fn caller(tok: String) -> String =
  helper tok
|}

let test_R61_AU04_auth_calling_auth_accepted () =
  (* auth functions CAN call other auth functions for composition *)
  should_pass {|
#lang tesl
module R61Au04 exposing []
import Tesl.Prelude exposing [String]
fact BaseAuth (s: String)
fact ComposedAuth (s: String)
auth baseAuth(tok: String) -> tok: String ::: BaseAuth tok =
  ok tok ::: BaseAuth tok
auth composedAuth(tok: String) -> tok: String ::: ComposedAuth tok =
  let base = check baseAuth tok
  ok base ::: ComposedAuth base
|}

let test_R61_AU05_auth_in_handler_accepted () =
  (* handler bodies CAN call auth functions — this is the primary use case *)
  should_pass {|
#lang tesl
module R61Au05 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth cookieAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn requiresAuth(s: String ::: Authenticated s) -> String = s
handler myHandler(token: String) -> String =
  let authed = check cookieAuth token
  requiresAuth authed
|}

let test_R61_AU06_auth_in_lambda_in_fn_rejected () =
  (* auth called inside a lambda inside a fn body is also caught *)
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R61Au06 exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.List exposing [List.map]
fact Authenticated (s: String)
auth authUser(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn badMap(toks: List String) -> List String =
  List.map (fn(t: String) -> check authUser t) toks
|}

let test_R61_AU07_auth_combined_check_in_fn_rejected () =
  (* The && combinator combining auth with check, used in fn body, is rejected *)
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R61Au07 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
fact IsNonEmpty (s: String)
auth authUser(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
check checkNonEmpty(s: String) -> s: String ::: IsNonEmpty s =
  if String.length s > 0 then
    ok s ::: IsNonEmpty s
  else
    fail 400 "empty"
fn badFn(tok: String) -> String =
  let validated = check (authUser && checkNonEmpty) tok
  validated
|}

(* ── BUG-04 extended: extractFact unavailability ────────────────────────── *)

let test_R61_EF01_extractfact_not_importable () =
  (* extractFact is no longer available in Tesl.Prelude *)
  should_fail "does not export" {|
#lang tesl
module R61Ef01 exposing []
import Tesl.Prelude exposing [Int, Fact, extractFact]
fact IsPositive (n: Int)
fn test(x: Int) -> Int = x
|}

let test_R61_EF02_proof_decomposition_works_instead () =
  (* The correct alternative — proof decomposition with let (x ::: p) = value *)
  should_pass {|
#lang tesl
module R61Ef02 exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact, attachFact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
fn roundTrip(x: Int) -> Int =
  let p = provePos x
  let xp = attachFact x p
  let detached = detachFact xp
  let x2 = attachFact x detached
  x2
|}

(* ── Runtime soundness: filterCheck/allCheck must receive check functions ──── *)

let test_R61_FC01_lambda_in_filtercheck_rejected () =
  (* A plain lambda passed to List.filterCheck crashes at runtime.
     The compiler now catches this at compile time. *)
  should_fail "declared.*check.*function.*not an inline lambda" {|
#lang tesl
module R61Fc01 exposing []
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

let test_R61_FC02_plain_fn_in_filtercheck_rejected () =
  (* A plain fn passed to filterCheck (without proof return) crashes at runtime. *)
  should_fail "is a.*fn.*not a.*check" {|
#lang tesl
module R61Fc02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fn notACheck(n: Int) -> Int = n + 1
fn bad(xs: List Int) -> List Int =
  List.filterCheck notACheck xs
|}

let test_R61_FC03_direct_check_fn_accepted () =
  (* Direct check function reference is the correct pattern. *)
  should_pass {|
#lang tesl
module R61Fc03 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn good(xs: List Int) -> List Int ::: ForAll (IsPositive) =
  List.filterCheck checkPos xs
|}

let test_R61_FC04_and_combination_accepted () =
  (* check && check combination is the correct pattern for combined filtering. *)
  should_pass {|
#lang tesl
module R61Fc04 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
import Tesl.String exposing [String.length]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"
fn good(xs: List Int) -> List Int ::: ForAll (IsPositive && IsSmall) =
  List.filterCheck (checkPos && checkSmall) xs
|}

let test_R61_FC05_allcheck_lambda_rejected () =
  (* Same restriction applies to List.allCheck. *)
  should_fail "declared.*check.*function.*not an inline lambda" {|
#lang tesl
module R61Fc05 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.allCheck]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn bad(xs: List Int) -> Maybe (List Int ::: ForAll (IsPositive)) =
  List.allCheck (fn(n: Int) -> check checkPos n) xs
|}

let test_R61_FC06_dict_filtercheck_fn_rejected () =
  (* Dict.filterCheckValues also enforces the check-function requirement. *)
  should_fail "fn.*not a.*check" {|
#lang tesl
module R61Fc06 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.filterCheckValues]
fn notACheck(v: Int) -> Int = v
fn bad(d: Dict String Int) -> Dict String Int =
  Dict.filterCheckValues notACheck d
|}

let test_R61_FC07_check_with_proof_precondition_in_filtercheck_rejected () =
  (* Combined check with && is valid for filterCheck *)
  should_pass {|
#lang tesl
module R61Fc07 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"
fn narrowWithCombined(xs: List Int) -> List Int ::: ForAll (IsPositive && IsSmall) =
  List.filterCheck (checkPos && checkSmall) xs
|}

let test_R61_FC08_partial_application_of_check_accepted () =
  (* Partial application of a multi-param check function is valid.
     checkInRange 0 100 produces a curried function, which is still a check function. *)
  should_pass {|
#lang tesl
module R61Fc08 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact InRange (n: Int)
check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange n =
  if lo <= n && n <= hi then
    ok n ::: InRange n
  else
    fail 400 "out of range"
fn good(xs: List Int) -> List Int =
  List.filterCheck (checkInRange 0 100) xs
|}

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Review61-Antagonistic" [
    "conjunction-ordering", [
      test_case "R61_CO01 reversed conjunction in ok now accepted (BUG-03 fixed)" `Quick test_R61_CO01_ok_reversed_conjunction_now_accepted;
      test_case "R61_CO02 same-order conjunction in ok accepted" `Quick test_R61_CO02_ok_same_order_accepted;
      test_case "R61_CO03 call-site conjunction is commutative" `Quick test_R61_CO03_callsite_commutativity_accepted;
    ];
    "capability-chain-depth", [
      test_case "R61_CP01 3-level cap chain now works (BUG-02 fixed)" `Quick test_R61_CP01_3level_cap_chain_now_works;
      test_case "R61_CP02 2-level cap chain works" `Quick test_R61_CP02_2level_cap_chain_works;
      test_case "R61_CP03 4-level cap chain now works (BUG-02 fixed)" `Quick test_R61_CP03_4level_cap_chain_now_works;
    ];
    "tuple-literal-parse", [
      test_case "R61_TH01 comma-pair syntax gives parse error (BUG-01 fixed)" `Quick test_R61_TH01_comma_pair_syntax_gives_parse_error;
      test_case "R61_TH02 correct Tuple2 syntax accepted" `Quick test_R61_TH02_correct_tuple2_syntax_accepted;
    ];
    "forall-param-subject", [
      test_case "R61_FW01 ForAll param without subject rejected" `Quick test_R61_FW01_forall_param_without_subject_rejected;
      test_case "R61_FW02 ForAll param with subject accepted" `Quick test_R61_FW02_forall_param_with_subject_accepted;
    ];
    "fn-proof-restrictions", [
      test_case "R61_FN01 fn cannot mint proof" `Quick test_R61_FN01_fn_cannot_mint_proof;
    ];
    "establish-restrictions", [
      test_case "R61_ES01 establish cannot call check" `Quick test_R61_ES01_establish_cannot_call_check;
      test_case "R61_ES02 establish cannot use fail" `Quick test_R61_ES02_establish_cannot_use_fail;
      test_case "R61_ES03 establish wrong return type rejected" `Quick test_R61_ES03_establish_returning_wrong_type_rejected;
    ];
    "proof-subject-dotted-path", [
      test_case "R61_DP01 dotted path in proof subject rejected" `Quick test_R61_DP01_dotted_path_proof_subject_rejected;
    ];
    "auth-fn-restriction", [
      test_case "R61_AU01 auth not callable from fn (LIMIT-06 fixed)" `Quick test_R61_AU01_auth_not_callable_from_fn;
    ];
    "newtype-proof-loss", [
      test_case "R61_NW01 newtype .value loses proof" `Quick test_R61_NW01_newtype_value_loses_proof;
    ];
    "record-field-proof", [
      test_case "R61_RC01 annotated record field rejects raw value" `Quick test_R61_RC01_annotated_record_field_rejects_raw_value;
    ];
    "exhaustiveness-5-ctor", [
      test_case "R61_EX01 5-ctor ADT missing arm rejected" `Quick test_R61_EX01_five_ctor_missing_one_rejected;
      test_case "R61_EX02 5-ctor ADT all covered accepted" `Quick test_R61_EX02_five_ctor_all_covered_accepted;
    ];
    "multi-param-proof", [
      test_case "R61_MP01 swapped multi-param proof args rejected" `Quick test_R61_MP01_swapped_multi_param_args_rejected;
    ];
    "int-divide-proof", [
      test_case "R61_DV01 divide without IsNonZero rejected" `Quick test_R61_DV01_divide_without_proof_rejected;
      test_case "R61_DV02 divide with IsNonZero accepted" `Quick test_R61_DV02_divide_with_proof_accepted;
    ];
    "forget-fact-static", [
      test_case "R61_FG01 forgetFact strips proof statically" `Quick test_R61_FG01_forget_fact_prevents_proof_use;
    ];
    "forall-consistency", [
      test_case "R61_FF01 ForAll inner proof mismatch rejected" `Quick test_R61_FF01_forall_inner_proof_mismatch_rejected;
    ];
    "named-fn-forall-map", [
      test_case "R61_NA01 named fn with proof params rejected in List.map" `Quick test_R61_NA01_named_fn_in_list_map_rejected;
      test_case "R61_NA02 inline lambda in List.map accepted" `Quick test_R61_NA02_inline_lambda_in_list_map_accepted;
    ];
    "deep-check-chain", [
      test_case "R61_6C01 6-check chain compiles" `Quick test_R61_6C01_six_check_chain_accepted;
    ];
    "mutual-recursion", [
      test_case "R61_MR01 mutual recursion with check accepted" `Quick test_R61_MR01_mutual_recursion_with_checks_accepted;
    ];
    "intro-and-chain", [
      test_case "R61_IM01 introAnd with 5 proofs accepted" `Quick test_R61_IM01_intro_and_with_5_proofs_accepted;
    ];
    "establish-maybe", [
      test_case "R61_EM01 establish Maybe conditional proof accepted" `Quick test_R61_EM01_establish_maybe_accepted;
    ];
    "stdlib-proofs", [
      test_case "R61_SF01 String.trim provides IsTrimmed" `Quick test_R61_SF01_string_trim_provides_istrimmed_proof;
      test_case "R61_SF02 List.sort provides IsSorted" `Quick test_R61_SF02_list_sort_provides_issorted_proof;
    ];
    "three-field-record", [
      test_case "R61_3F01 3-proof-field record accepted" `Quick test_R61_3F01_three_proof_fields_accepted;
      test_case "R61_3F02 3-proof-field record raw rejected" `Quick test_R61_3F02_three_proof_fields_raw_rejected;
    ];
    "bug01-extended", [
      test_case "R61_TH03 multi-element comma-pair list gives parse error" `Quick test_R61_TH03_nested_paren_in_list_gives_error;
      test_case "R61_TH04 empty list still valid" `Quick test_R61_TH04_empty_list_still_valid;
      test_case "R61_TH05 singleton list still valid" `Quick test_R61_TH05_singleton_list_still_valid;
    ];
    "bug02-extended", [
      test_case "R61_CP04 5-level cap chain works" `Quick test_R61_CP04_5level_cap_chain_works;
      test_case "R61_CP05 diamond cap chain works" `Quick test_R61_CP05_diamond_cap_chain_works;
      test_case "R61_CP06 cap cycle still detected" `Quick test_R61_CP06_cap_cycle_detection_still_works;
      test_case "R61_CP07 fn missing cap still caught" `Quick test_R61_CP07_fn_missing_cap_still_caught;
    ];
    "bug03-extended", [
      test_case "R61_CO04 3-term conjunction any order accepted" `Quick test_R61_CO04_three_term_conjunction_any_order_accepted;
      test_case "R61_CO05 5-term conjunction reverse order accepted" `Quick test_R61_CO05_five_term_conjunction_reverse_order;
      test_case "R61_CO06 wrong predicate still rejected" `Quick test_R61_CO06_wrong_predicate_still_rejected;
      test_case "R61_CO07 single predicate unaffected" `Quick test_R61_CO07_single_predicate_still_works;
      test_case "R61_CO08 conjunction with multi-arg pred" `Quick test_R61_CO08_conjunction_with_multi_arg_pred;
    ];
    "limit06-extended", [
      test_case "R61_AU02 auth from check rejected" `Quick test_R61_AU02_auth_from_check_rejected;
      test_case "R61_AU03 auth from fn alias rejected" `Quick test_R61_AU03_auth_from_fn_with_alias_rejected;
      test_case "R61_AU04 auth calling auth accepted" `Quick test_R61_AU04_auth_calling_auth_accepted;
      test_case "R61_AU05 auth in handler accepted" `Quick test_R61_AU05_auth_in_handler_accepted;
      test_case "R61_AU06 auth in lambda in fn rejected" `Quick test_R61_AU06_auth_in_lambda_in_fn_rejected;
      test_case "R61_AU07 auth in && combinator in fn rejected" `Quick test_R61_AU07_auth_combined_check_in_fn_rejected;
    ];
    "bug04-extended", [
      test_case "R61_EF01 extractFact not importable" `Quick test_R61_EF01_extractfact_not_importable;
      test_case "R61_EF02 proof decomposition works instead" `Quick test_R61_EF02_proof_decomposition_works_instead;
    ];
    "filtercheck-soundness", [
      test_case "R61_FC01 lambda in filterCheck rejected at compile time" `Quick test_R61_FC01_lambda_in_filtercheck_rejected;
      test_case "R61_FC02 plain fn in filterCheck rejected" `Quick test_R61_FC02_plain_fn_in_filtercheck_rejected;
      test_case "R61_FC03 direct check fn accepted" `Quick test_R61_FC03_direct_check_fn_accepted;
      test_case "R61_FC04 && combination accepted" `Quick test_R61_FC04_and_combination_accepted;
      test_case "R61_FC05 allCheck lambda rejected" `Quick test_R61_FC05_allcheck_lambda_rejected;
      test_case "R61_FC06 Dict.filterCheckValues fn rejected" `Quick test_R61_FC06_dict_filtercheck_fn_rejected;
      test_case "R61_FC07 combined check in filterCheck accepted" `Quick test_R61_FC07_check_with_proof_precondition_in_filtercheck_rejected;
      test_case "R61_FC08 partial application of check accepted" `Quick test_R61_FC08_partial_application_of_check_accepted;
    ];
  ]
