(** Antagonistic regression tests for Critical Review 60.

    This review audits:
    1.  lesson30 doc inconsistency: named fn passed directly to List.map on ForAll list
    2.  ok with non-identifier (constructor call) is rejected with clear error
    3.  ok with wrong binding name is rejected with clear error
    4.  Proof loss through unannotated record field access (by design, clear error)
    5.  Proof loss through Tuple2.first/second (by design, clear error)
    6.  forgetFact strips proof statically
    7.  establish cannot contain ok :::
    8.  Multi-param proof with swapped literal args is caught statically
    9.  fn cannot mint proofs with ok :::
    10. Constructor same-name-as-type rejected
    11. check called without check keyword in test blocks
    12. Inline literal at proof-subject position rejected in test
    13. Proof requirement from callee propagated to fn signature
    14. Proof in nested case arm is not propagated to outer scope
    15. ForAll on Dict type rejected (wrong type)
    16. lambda with proof-annotated param works in List.map with ForAll
    17. establish cannot contain fail
    18. establish cannot call check
    19. Int.divide without IsNonZero proof is rejected
    20. Proof subject confusion: forgetFact error shows original name
    21. Chaining 5 checks with full accumulation works
    22. Record with proof-annotated fields: bad construction rejected
    23. Case-arm binding does not propagate proof from scrutinee
    24. Auth function cannot be called from fn body
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
  let dir = Filename.temp_dir "tesl-r60" "" in
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

(* ── R60_FL — ForAll/List.map documentation inconsistency ──────────────────── *)

let test_R60_FL01_named_fn_in_forall_map_rejected () =
  (* lesson30 comments describe "Form 1" where a named function with proof-annotated
     params can be passed directly to List.map on a ForAll list.
     In practice the compiler rejects this — only lambda wrappers work.
     This test documents the gap: Form 1 in the docs is NOT implemented. *)
  should_fail "requires proof annotations on its parameters and cannot be passed as a plain callback" {|
#lang tesl
module R60Fl01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.map]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn requiresProof(n: Int ::: IsPositive n) -> Int = n * 2
fn mapAll(xs: List Int ::: ForAll (IsPositive) xs) -> List Int =
  List.map requiresProof xs
|}

let test_R60_FL02_lambda_wrapper_in_forall_map_accepted () =
  (* The working workaround: use an inline lambda with proof-annotated param *)
  should_pass {|
#lang tesl
module R60Fl02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.map]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn requiresProof(n: Int ::: IsPositive n) -> Int = n * 2
fn mapAll(xs: List Int ::: ForAll (IsPositive) xs) -> List Int =
  List.map (fn(n: Int ::: IsPositive n) -> requiresProof n) xs
|}

(* ── R60_OK — ok expression restrictions ────────────────────────────────────── *)

let test_R60_OK01_ok_with_constructor_call_accepted () =
  (* ok expression CAN return a constructor application.
     The emitter creates a let-binding for the return name so the proof template resolves. *)
  should_pass {|
#lang tesl
module R60Ok01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
type MkUserId = String
fact ValidId (u: MkUserId)
check checkId(raw: String) -> u: MkUserId ::: ValidId u =
  if String.length raw >= 3 then
    ok MkUserId raw ::: ValidId u
  else
    fail 400 "bad"
|}

let test_R60_OK02_ok_with_different_binding_name_rejected () =
  (* ok must return the exact declared binding name, not a different variable *)
  should_fail "ok expression returns .transformed. but the declared return binding name is .result." {|
#lang tesl
module R60Ok02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> result: Int ::: IsPositive result =
  let transformed = n + 1
  if transformed > 0 then
    ok transformed ::: IsPositive result
  else
    fail 400 "not positive"
|}

let test_R60_OK03_ok_with_let_bound_var_accepted () =
  (* ok can return a let-bound variable even if it was transformed *)
  should_pass {|
#lang tesl
module R60Ok03 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkAddOne(n: Int) -> result: Int ::: IsPositive result =
  let result = n + 1
  if result > 0 then
    ok result ::: IsPositive result
  else
    fail 400 "not positive"
|}

let test_R60_OK04_ok_with_arithmetic_still_rejected () =
  (* Arbitrary arithmetic expressions in ok are still rejected; only constructor
     applications and the declared binding name are allowed. *)
  should_fail "ok expression returns a non-identifier" {|
#lang tesl
module R60Ok04 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkAndDouble(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok (n * 2) ::: IsPositive n
  else
    fail 400 "neg"
|}

(* ── R60_RF — Record field proof loss ──────────────────────────────────────── *)

let test_R60_RF01_proof_lost_through_unannotated_record_field () =
  (* A value stored in an unannotated record field loses its proof when read back.
     This is by design but is a significant ergonomic limitation. *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Rf01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
record MyRec { value: Int }
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn testProofLoss(raw: Int) -> Int =
  let pos = check checkPos raw
  let r = MyRec { value: pos }
  needsPos r.value
|}

let test_R60_RF02_proof_preserved_through_annotated_record_field () =
  (* With proof annotation on the field, construction requires the proof
     and field access propagates it. *)
  should_pass {|
#lang tesl
module R60Rf02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
record MyRec { value: Int ::: IsPositive value }
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn testProofPreserved(raw: Int) -> Int =
  let pos = check checkPos raw
  let r = MyRec { value: pos }
  needsPos r.value
|}

(* ── R60_TP — Tuple accessor proof loss ─────────────────────────────────────── *)

let test_R60_TP01_proof_lost_through_tuple_first () =
  (* Tuple2.first does not preserve proof from tuple elements.
     This is by design: tuples have no per-element proof annotations. *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Tp01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Tuple exposing [Tuple2(..), Tuple2.first]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn testTupleProofLoss(raw: Int) -> Int =
  let pos = check checkPos raw
  let t = Tuple2 pos "hello"
  let extracted = Tuple2.first t
  needsPos extracted
|}

(* ── R60_FG — forgetFact strips proof statically ─────────────────────────────── *)

let test_R60_FG01_forget_fact_strips_proof () =
  (* forgetFact removes the proof from a value. Attempting to use the result
     in a proof-requiring position is a static error. *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Fg01 exposing []
import Tesl.Prelude exposing [Int, forgetFact]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn testForgetProof(raw: Int) -> Int =
  let pos = check checkPos raw
  let plain = forgetFact pos
  needsPos plain
|}

(* ── R60_CT — Constructor naming restriction ─────────────────────────────────── *)

let test_R60_CT01_constructor_same_name_as_type_rejected () =
  (* Tesl rejects constructors with the same name as their type.
     This differs from Haskell/ML convention where `type UserId = UserId String` is idiomatic.
     The error message suggests renaming to MkUserId. *)
  should_fail "same name as its type.*rename" {|
#lang tesl
module R60Ct01 exposing []
import Tesl.Prelude exposing [String]
type UserId
  = UserId String
|}

let test_R60_CT02_constructor_different_name_accepted () =
  (* Using a different constructor name from the type is accepted *)
  should_pass {|
#lang tesl
module R60Ct02 exposing []
import Tesl.Prelude exposing [String]
type UserId
  = MkUserId String
|}

(* ── R60_MP — Multi-param proof with swapped literal args ─────────────────────── *)

let test_R60_MP01_swapped_literal_args_caught () =
  (* When literal arguments are provided in wrong order to a multi-param proof,
     the static checker catches the mismatch. *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Mp01 exposing []
import Tesl.Prelude exposing [Int]
fact InRange (lo: Int) (hi: Int) (n: Int)
check checkInRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if n >= lo && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"
fn needsInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n
fn badUse(raw: Int) -> Int =
  let checked = check checkInRange 0 100 raw
  needsInRange 100 0 checked
|}

(* ── R60_DV — Int.divide proof requirement ─────────────────────────────────────── *)

let test_R60_DV01_divide_without_proof_rejected () =
  (* Int.divide requires IsNonZero proof on the denominator.
     Direct call without this proof is a static error. *)
  should_fail "does not statically satisfy declared proof.*IsNonZero" {|
#lang tesl
module R60Dv01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn unsafeDivide(a: Int, b: Int) -> Int =
  Int.divide a b
|}

(* ── R60_ES — establish restrictions ─────────────────────────────────────────── *)

let test_R60_ES01_establish_cannot_contain_ok () =
  (* establish functions must return proof constructors directly,
     not use the 'ok' syntax *)
  should_fail "establish functions must return proof constructors directly" {|
#lang tesl
module R60Es01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish positive(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|}

let test_R60_ES02_establish_cannot_contain_fail () =
  (* establish functions must be total — fail is not allowed *)
  should_fail "establish functions cannot use .fail" {|
#lang tesl
module R60Es02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish positive(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let test_R60_ES03_establish_cannot_call_check () =
  (* establish must be total — calling a check function would make it non-total *)
  should_fail "establish functions cannot call .check" {|
#lang tesl
module R60Es03 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"
establish badEstablish(n: Int) -> Fact (IsPositive n) =
  let _ = check checkSmall n
  IsPositive n
|}

(* ── R60_FN — fn proof restrictions ─────────────────────────────────────────── *)

let test_R60_FN01_fn_cannot_mint_proof () =
  (* Plain fn functions cannot use ok ::: to mint new proofs *)
  should_fail "ok .* proof construction is not allowed in .fn." {|
#lang tesl
module R60Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn fakeMint(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|}

(* ── R60_IL — Inline literal at proof-subject position ──────────────────────── *)

let test_R60_IL01_inline_literal_in_test_proof_position () =
  (* Passing an inline literal to a check function that uses it as a proof subject
     is rejected in test blocks because literals cannot be tracked as proof subjects. *)
  should_fail "inline literals cannot be tracked as proof subjects" {|
#lang tesl
module R60Il01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero]
test "inline literal at proof position" {
  let r = check Int.nonZero 5
  expect r == 5
}
|}

(* ── R60_CA — Case arm proof propagation ────────────────────────────────────── *)

let test_R60_CA01_proof_not_propagated_from_scrutinee_through_case () =
  (* Pattern-matching binds a new variable; proofs on the scrutinee
     do not automatically attach to bound case variables *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Ca01 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn caseBindingNoProof(raw: Int) -> Int =
  let pos = check checkPos raw
  case pos of
    n -> needsPos n
|}

(* ── R60_RC — Record construction requires field proofs ─────────────────────── *)

let test_R60_RC01_annotated_field_requires_proof_at_construction () =
  (* Building a record with a proof-annotated field requires the field value
     to carry the declared proof. Unproven values are rejected. *)
  should_fail "does not statically satisfy declared proof" {|
#lang tesl
module R60Rc01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
record SafeCount { count: Int ::: IsPositive count }
fn makeWithRaw(n: Int) -> SafeCount =
  SafeCount { count: n }
|}

(* ── R60_FA — ForAll with wrong collection type rejected ──────────────────────── *)

let test_R60_FA01_forall_on_dict_type_rejected () =
  (* ForAll is only valid on List and Set. Using it on Dict should be rejected
     (the correct annotation is ForAllValues or ForAllKeys). *)
  should_fail "ForAll" {|
#lang tesl
module R60Fa01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict]
fact IsPositive (n: Int)
fn badDictForAll(d: Dict String Int ::: ForAll (IsPositive) d) -> Int = 0
|}

(* ── R60_CP — Capability propagation to callee ──────────────────────────────── *)

let test_R60_CP01_missing_capability_in_caller_caught () =
  (* A function that calls a time-requiring function must declare [time] capability.
     Omitting requires [time] is a static error. *)
  should_fail "requires" {|
#lang tesl
module R60Cp01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Time exposing [time, nowMillis, PosixMillis]
fn badFn() -> PosixMillis =
  nowMillis ()
|}


(* ── Test runner ─────────────────────────────────────────────────────────── *)

(* ── R60_EX — Exhaustiveness checking ─────────────────────────────────────── *)

let test_R60_EX01_missing_adt_ctor_caught () =
  should_fail "non-exhaustive case.*missing.*Blue\\|missing.*Green\\|missing" {|
#lang tesl
module R60Ex01 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
|}

let test_R60_EX02_exhaustive_adt_case_ok () =
  should_pass {|
#lang tesl
module R60Ex02 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_R60_EX03_missing_maybe_ctor_caught () =
  should_fail "non-exhaustive case.*missing.*Nothing\\|missing.*Something" {|
#lang tesl
module R60Ex03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn maybeStr(m: Maybe Int) -> String =
  case m of
    Something v -> "has value"
|}

let test_R60_EX04_exhaustive_maybe_case_ok () =
  should_pass {|
#lang tesl
module R60Ex04 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn maybeStr(m: Maybe Int) -> String =
  case m of
    Nothing -> "empty"
    Something _ -> "has value"
|}

let test_R60_EX05_missing_bool_ctor_caught () =
  should_fail "non-exhaustive case.*missing.*False\\|missing.*True" {|
#lang tesl
module R60Ex05 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn onlyTrue(b: Bool) -> Int =
  case b of
    True -> 1
|}

let test_R60_EX06_wildcard_covers_remaining_ok () =
  (* A wildcard arm with no guard makes the case exhaustive *)
  should_pass {|
#lang tesl
module R60Ex06 exposing []
import Tesl.Prelude exposing [Int, String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    _ -> "other"
|}

let test_R60_EX07_variable_arm_covers_remaining_ok () =
  (* A variable binding arm (no guard) makes the case exhaustive *)
  should_pass {|
#lang tesl
module R60Ex07 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn maybeInt(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something v -> v
|}

let test_R60_EX08_all_guarded_arms_non_exhaustive () =
  (* All arms with guards cannot statically guarantee exhaustiveness *)
  should_fail "non-exhaustive" {|
#lang tesl
module R60Ex08 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn guarded(b: Bool) -> Int =
  case b of
    True where 1 == 1 -> 1
    False where 1 == 1 -> 0
|}

let test_R60_EX09_partial_ctor_with_guard_non_exhaustive () =
  (* One arm has a guard, so that constructor is not statically covered *)
  should_fail "non-exhaustive" {|
#lang tesl
module R60Ex09 exposing []
import Tesl.Prelude exposing [Int, String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red where 1 == 1 -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_R60_EX10_four_ctor_missing_one_caught () =
  should_fail "non-exhaustive" {|
#lang tesl
module R60Ex10 exposing []
import Tesl.Prelude exposing [String]
type Suit
  = Hearts
  | Diamonds
  | Clubs
  | Spades
fn suitStr(s: Suit) -> String =
  case s of
    Hearts -> "hearts"
    Diamonds -> "diamonds"
    Clubs -> "clubs"
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review60-Antagonistic" [
    "forall-map-named-fn", [
      test_case "R60_FL01 named fn in ForAll map rejected" `Quick test_R60_FL01_named_fn_in_forall_map_rejected;
      test_case "R60_FL02 lambda wrapper in ForAll map accepted" `Quick test_R60_FL02_lambda_wrapper_in_forall_map_accepted;
    ];
    "ok-restrictions", [
      test_case "R60_OK01 ok with constructor call accepted" `Quick test_R60_OK01_ok_with_constructor_call_accepted;
      test_case "R60_OK02 ok with wrong binding name rejected" `Quick test_R60_OK02_ok_with_different_binding_name_rejected;
      test_case "R60_OK03 ok with let-bound var accepted" `Quick test_R60_OK03_ok_with_let_bound_var_accepted;
      test_case "R60_OK04 ok with arithmetic still rejected" `Quick test_R60_OK04_ok_with_arithmetic_still_rejected;
    ];
    "record-field-proof", [
      test_case "R60_RF01 proof lost through unannotated field" `Quick test_R60_RF01_proof_lost_through_unannotated_record_field;
      test_case "R60_RF02 proof preserved through annotated field" `Quick test_R60_RF02_proof_preserved_through_annotated_record_field;
    ];
    "tuple-accessor-proof", [
      test_case "R60_TP01 proof lost through Tuple2.first" `Quick test_R60_TP01_proof_lost_through_tuple_first;
    ];
    "forget-fact-static", [
      test_case "R60_FG01 forgetFact strips proof at compile time" `Quick test_R60_FG01_forget_fact_strips_proof;
    ];
    "constructor-naming", [
      test_case "R60_CT01 constructor same name as type rejected" `Quick test_R60_CT01_constructor_same_name_as_type_rejected;
      test_case "R60_CT02 constructor different name accepted" `Quick test_R60_CT02_constructor_different_name_accepted;
    ];
    "multi-param-proof", [
      test_case "R60_MP01 swapped literal args caught" `Quick test_R60_MP01_swapped_literal_args_caught;
    ];
    "int-divide-proof", [
      test_case "R60_DV01 divide without IsNonZero proof rejected" `Quick test_R60_DV01_divide_without_proof_rejected;
    ];
    "establish-restrictions", [
      test_case "R60_ES01 establish cannot contain ok" `Quick test_R60_ES01_establish_cannot_contain_ok;
      test_case "R60_ES02 establish cannot contain fail" `Quick test_R60_ES02_establish_cannot_contain_fail;
      test_case "R60_ES03 establish cannot call check" `Quick test_R60_ES03_establish_cannot_call_check;
    ];
    "fn-proof-restrictions", [
      test_case "R60_FN01 fn cannot mint proof with ok :::" `Quick test_R60_FN01_fn_cannot_mint_proof;
    ];
    "inline-literal", [
      test_case "R60_IL01 inline literal at proof-subject position rejected" `Quick test_R60_IL01_inline_literal_in_test_proof_position;
    ];
    "case-arm-proof", [
      test_case "R60_CA01 proof not propagated through case binding" `Quick test_R60_CA01_proof_not_propagated_from_scrutinee_through_case;
    ];
    "record-construction", [
      test_case "R60_RC01 annotated field requires proof at construction" `Quick test_R60_RC01_annotated_field_requires_proof_at_construction;
    ];
    "forall-wrong-type", [
      test_case "R60_FA01 ForAll on Dict type is rejected" `Quick test_R60_FA01_forall_on_dict_type_rejected;
    ];
    "capability-propagation", [
      test_case "R60_CP01 missing capability in caller caught" `Quick test_R60_CP01_missing_capability_in_caller_caught;
    ];
    "exhaustiveness", [
      test_case "R60_EX01 missing ADT ctor caught" `Quick test_R60_EX01_missing_adt_ctor_caught;
      test_case "R60_EX02 exhaustive ADT case ok" `Quick test_R60_EX02_exhaustive_adt_case_ok;
      test_case "R60_EX03 missing Maybe ctor caught" `Quick test_R60_EX03_missing_maybe_ctor_caught;
      test_case "R60_EX04 exhaustive Maybe case ok" `Quick test_R60_EX04_exhaustive_maybe_case_ok;
      test_case "R60_EX05 missing Bool ctor caught" `Quick test_R60_EX05_missing_bool_ctor_caught;
      test_case "R60_EX06 wildcard covers remaining ok" `Quick test_R60_EX06_wildcard_covers_remaining_ok;
      test_case "R60_EX07 variable arm covers remaining ok" `Quick test_R60_EX07_variable_arm_covers_remaining_ok;
      test_case "R60_EX08 all guarded arms non-exhaustive" `Quick test_R60_EX08_all_guarded_arms_non_exhaustive;
      test_case "R60_EX09 partial ctor with guard non-exhaustive" `Quick test_R60_EX09_partial_ctor_with_guard_non_exhaustive;
      test_case "R60_EX10 four-ctor missing one caught" `Quick test_R60_EX10_four_ctor_missing_one_caught;
    ];
  ]

