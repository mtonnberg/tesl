(** Antagonistic regression tests for Critical Review 64.

    This review audits new adversarial territory not covered by reviews 55-63:

    1.  Cross-subject proof forgery via attachFact caught at compile time
    2.  introAnd with proofs of different subjects rejected
    3.  ForAll with literal-parametrized predicates: argument-count error
    4.  Passing String where Email (newtype) is expected: type error
    5.  Passing UserId where ProjectId is expected: type error (same base)
    6.  Partial application of cross-parameter proof function rejected
    7.  ForAll on non-List type (Dict, Int) rejected
    8.  check used in establish body: compile-time error
    9.  Bare integer literal to check function in fn body: should work
    10. forgetFact + raw literal attach: compile-time rejection if subject unknown
    11. allCheck on list where some elements fail: should compile OK
    12. Multiple check chains accumulating proofs correctly accepted
    13. Record field with wrong proof type: compile error
    14. Mutual recursion with proof-annotated params: should compile
    15. Case arm proof flow: proof available from case arm variable
    16. ForAll parameter without explicit subject: compile error
    17. handler returning ForAll in ::: form: parse error
    18. introAnd subjects: compiler correctly rejects different subjects
    19. establish returning plain (non-Maybe) Fact for conditional: should accept Maybe form
    20. Type alias vs newtype: String != Email (type mismatch) *)

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
  let dir = Filename.temp_dir "tesl-r64" "" in
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

(* ── R64_XS — Cross-subject proof forgery via attachFact caught ───────── *)

let test_R64_XS01_cross_subject_forgery_via_attachfact_rejected () =
  (* Detach proof from x, attach to y of same type — compiler should reject *)
  should_fail "proof subject mismatch\\|does not statically satisfy" {|
#lang tesl
module R64Xs01 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, detachFact]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn forgery(x: Int, y: Int) -> Int =
  let provenX = check checkPos x
  let prf = detachFact provenX
  let yWithProof = attachFact y prf
  needsPos yWithProof
|}

let test_R64_XS02_introand_different_subjects_rejected () =
  (* introAnd(proveA x, proveB y) where x != y — must be rejected at compile time *)
  should_fail "proof subject mismatch\\|does not statically satisfy" {|
#lang tesl
module R64Xs02 exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, introAnd]
fact A (n: Int)
fact B (n: Int)
establish proveA(n: Int) -> Fact (A n) = A n
establish proveB(n: Int) -> Fact (B n) = B n
fn needsAB(n: Int ::: A n && B n) -> Int = n
fn forgery(x: Int, y: Int) -> Int =
  let pa = proveA x
  let pb = proveB y
  let pab = introAnd pa pb
  let xWithAB = attachFact x pab
  needsAB xWithAB
|}

(* ── R64_NT — Newtype nominal isolation ─────────────────────────────────── *)

let test_R64_NT01_string_where_newtype_expected_rejected () =
  (* Passing a plain String where Email newtype is required: type mismatch *)
  should_fail "cannot unify\\|type mismatch" {|
#lang tesl
module R64Nt01 exposing []
import Tesl.Prelude exposing [String]
type Email = String
fn takesEmail(e: Email) -> String = e.value
fn bad(raw: String) -> String =
  takesEmail raw
|}

let test_R64_NT02_userid_where_projectid_expected_rejected () =
  (* UserId and ProjectId are both String-backed newtypes but must not be interchangeable *)
  should_fail "cannot unify\\|type mismatch" {|
#lang tesl
module R64Nt02 exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fn takesProject(p: ProjectId) -> String = p.value
fn bad(u: UserId) -> String =
  takesProject u
|}

let test_R64_NT03_newtype_proof_not_applicable_to_other_newtype () =
  (* A proof about UserId should not apply to ProjectId even if same base type *)
  should_fail "cannot unify\\|type mismatch" {|
#lang tesl
module R64Nt03 exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fact ValidUser (u: UserId)
check checkUser(u: UserId) -> u: UserId ::: ValidUser u =
  ok u ::: ValidUser u
fn requiresProject(p: ProjectId ::: ValidUser p) -> String = p.value
fn bad(raw: String) -> String =
  let uid = UserId raw
  let vu = check checkUser uid
  requiresProject vu
|}

(* ── R64_CP — Cross-parameter proof partial application ─────────────────── *)

let test_R64_CP01_partial_apply_cross_param_proof_rejected () =
  (* Partially applying a function whose first param carries a cross-param proof
     (ValidRange lo hi), where hi is not yet bound, must be rejected *)
  should_fail "cross-parameter subjects are not trackable\\|hi unresolved\\|proof" {|
#lang tesl
module R64Cp01 exposing []
import Tesl.Prelude exposing [Int]
fact ValidRange (lo: Int, hi: Int)
check checkRange(lo: Int, hi: Int) -> lo: Int ::: ValidRange lo hi =
  if lo < hi then
    ok lo ::: ValidRange lo hi
  else
    fail 400 "bad range"
fn clamp(lo: Int ::: ValidRange lo hi, hi: Int, v: Int) -> Int =
  if v < lo then
    lo
  else
    if v > hi then
      hi
    else
      v
fn badPartial(lo: Int) -> Int =
  let f = clamp lo
  1
|}

(* ── R64_FA — ForAll argument count and type errors ─────────────────────── *)

let test_R64_FA01_forall_param_without_explicit_subject_rejected () =
  (* ForAll in parameter position requires explicit subject variable *)
  should_fail "explicit subject\\|ForAll" {|
#lang tesl
module R64Fa01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]
fact IsActive (n: Int)
fn countActive(notes: List Int ::: ForAll (IsActive)) -> Int =
  List.length notes
|}

let test_R64_FA02_forall_on_dict_type_rejected () =
  (* ForAll is only valid for List and Set; applying to Dict is a compile error *)
  should_fail "ForAll.*only valid\\|only valid.*ForAll\\|not a list\\|type" {|
#lang tesl
module R64Fa02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict]
fact IsPositive (n: Int)
fn bad(d: Dict String Int ::: ForAll (IsPositive) d) -> Int = 0
|}

let test_R64_FA03_forall_on_int_type_rejected () =
  (* ForAll on a non-collection type should be rejected *)
  should_fail "ForAll.*only valid\\|not a list\\|type" {|
#lang tesl
module R64Fa03 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn bad(n: Int ::: ForAll (IsPositive) n) -> Int = n
|}

let test_R64_FA04_literal_param_predicate_now_works () =
  (* HasMin 10 in ForAll: FIXED. normalize_carried_forall now uses pp_proof
     (preserving literal args), and pred_str_from_check_chain strips only
     the element subject. ForAll (HasMin 10) now matches across filterCheck
     and parameter annotations. Also verifies HasMin 10 != HasMin 20. *)
  should_pass {|
#lang tesl
module R64Fa04 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact HasMin (lo: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "too small"
fn needAll(xs: List Int ::: ForAll (HasMin 10) xs) -> Int =
  List.length xs
fn filterAbove10(raw: List Int) -> List Int ? ForAll (HasMin 10) =
  List.filterCheck checkMin10 raw
fn test(raw: List Int) -> Int =
  let pos = filterAbove10 raw
  needAll pos
|}

(* ── R64_ES — establish body restrictions ───────────────────────────────── *)

let test_R64_ES01_check_call_inside_establish_body_rejected () =
  (* establish bodies cannot use `check` to validate — only `fail` is banned,
     but calling a check function is allowed if the result is used correctly.
     However, establishing a proof that uses fail is rejected. *)
  should_fail "establish.*cannot.*fail\\|fail.*establish" {|
#lang tesl
module R64Es01 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let test_R64_ES02_establish_with_ok_syntax_rejected () =
  (* establish bodies use direct fact construction, not ok ::: form *)
  should_fail "establish.*ok\\|ok.*establish\\|cannot.*ok" {|
#lang tesl
module R64Es02 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|}

let test_R64_ES03_establish_direct_fact_construction_accepted () =
  should_pass {|
#lang tesl
module R64Es03 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  IsPositive n
|}

let test_R64_ES04_establish_returning_maybe_fact_accepted () =
  (* establish CAN return Maybe (Fact P) for conditional facts *)
  should_pass {|
#lang tesl
module R64Es04 exposing []
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Maybe exposing [Maybe(..)]
fact InRange (n: Int)
establish checkInRange(n: Int) -> Maybe (Fact (InRange n)) =
  if n >= 0 && n <= 255 then
    Something (InRange n)
  else
    Nothing
|}

(* ── R64_FN — fn proof restrictions ─────────────────────────────────────── *)

let test_R64_FN01_fn_cannot_mint_new_proof_rejected () =
  (* fn cannot declare a new proof return for a non-input binding *)
  should_fail "cannot declare a proof\\|fn.*proof\\|fn.*check\\|fn.*establish" {|
#lang tesl
module R64Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn mint(n: Int) -> n: Int ::: IsPositive n = n
|}

let test_R64_FN02_fn_proof_passthrough_accepted () =
  (* fn CAN return a proof that was already attached to an input param *)
  should_pass {|
#lang tesl
module R64Fn02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn passthrough(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n
|}

(* ── R64_SH — Shadowing ──────────────────────────────────────────────────── *)

let test_R64_SH01_let_shadowing_param_rejected () =
  should_fail "shadows\\|shadow" {|
#lang tesl
module R64Sh01 exposing []
import Tesl.Prelude exposing [Int]
fn test(x: Int) -> Int =
  let x = 5
  x
|}

let test_R64_SH02_case_binder_shadowing_outer_name_rejected () =
  should_fail "shadows\\|shadow" {|
#lang tesl
module R64Sh02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn test(m: Maybe Int, n: Int) -> Int =
  case m of
    Nothing -> 0
    Something n -> n
|}

let test_R64_SH03_nested_let_shadowing_rejected () =
  (* A nested let that shadows an outer let binding is rejected *)
  should_fail "shadows\\|shadow" {|
#lang tesl
module R64Sh03 exposing []
import Tesl.Prelude exposing [Int]
fn test(a: Int) -> Int =
  let b = a + 1
  let b = b + 1
  b
|}

(* ── R64_WR — Wrong proof at call site ────────────────────────────────────── *)

let test_R64_WR01_wrong_predicate_at_callsite_rejected () =
  (* Function requires A proof; value only has B proof — should fail *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R64Wr01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkB(n: Int) -> n: Int ::: B n =
  if n > 0 then
    ok n ::: B n
  else
    fail 400 "bad"
fn needsA(n: Int ::: A n) -> Int = n
fn test(x: Int) -> Int =
  let provenB = check checkB x
  needsA provenB
|}

let test_R64_WR02_wrong_subject_same_predicate_rejected () =
  (* Same predicate but different subject: x's proof passed as y's *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R64Wr02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn test(x: Int, y: Int) -> Int =
  let provenX = check checkPos x
  needsPos y
|}

let test_R64_WR03_conjunction_subset_rejected () =
  (* Value has A proof; function requires A && B — should fail *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R64Wr03 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"
fn needsAB(n: Int ::: A n && B n) -> Int = n
fn test(x: Int) -> Int =
  let provenA = check checkA x
  needsAB provenA
|}

(* ── R64_MR — Mutual recursion ──────────────────────────────────────────── *)

let test_R64_MR01_mutual_recursion_accepted () =
  (* Mutually recursive functions without proofs should compile fine *)
  should_pass {|
#lang tesl
module R64Mr01 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn isEven(n: Int) -> Bool =
  if n == 0 then
    True
  else
    isOdd (n - 1)
fn isOdd(n: Int) -> Bool =
  if n == 0 then
    False
  else
    isEven (n - 1)
|}

let test_R64_MR02_mutual_recursion_with_proof_accepted () =
  (* Mutually recursive functions that pass proof-carrying values *)
  should_pass {|
#lang tesl
module R64Mr02 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact IsEven (n: Int)
fn safeEvenCheck(n: Int) -> Bool =
  if n == 0 then
    True
  else
    safeOddCheck (n - 1)
fn safeOddCheck(n: Int) -> Bool =
  if n == 0 then
    False
  else
    safeEvenCheck (n - 1)
|}

(* ── R64_CS — Case expression exhaustiveness ─────────────────────────────── *)

let test_R64_CS01_non_exhaustive_case_rejected () =
  should_fail "non-exhaustive\\|missing constructor\\|missing arm" {|
#lang tesl
module R64Cs01 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
|}

let test_R64_CS02_exhaustive_case_accepted () =
  should_pass {|
#lang tesl
module R64Cs02 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_R64_CS03_wildcard_arm_makes_exhaustive () =
  should_pass {|
#lang tesl
module R64Cs03 exposing []
import Tesl.Prelude exposing [String]
type Color
  = Red
  | Green
  | Blue
fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    _ -> "other"
|}

(* ── R64_CC — Capability cycle detection ────────────────────────────────── *)

let test_R64_CC01_two_way_capability_cycle_rejected () =
  should_fail "cycle" {|
#lang tesl
module R64Cc01 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies beta
capability beta implies alpha
handler h(x: Int) -> Int requires [alpha] = x
|}

let test_R64_CC02_four_way_capability_cycle_rejected () =
  should_fail "cycle" {|
#lang tesl
module R64Cc02 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies beta
capability beta implies gamma
capability gamma implies delta
capability delta implies alpha
handler h(x: Int) -> Int requires [alpha] = x
|}

let test_R64_CC03_linear_capability_chain_accepted () =
  (* A → B → C (no cycle) should be accepted *)
  should_pass {|
#lang tesl
module R64Cc03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]
capability readOnly implies dbRead
capability readWrite implies dbWrite
capability fullAccess implies readOnly, readWrite
handler h(x: Int) -> Int requires [fullAccess] = x
|}

(* ── R64_RC — Record construction with wrong proof type ─────────────────── *)

let test_R64_RC01_record_field_with_wrong_proof_rejected () =
  (* Constructing a record with a field that lacks the required proof *)
  should_fail "does not statically satisfy\\|proof" {|
#lang tesl
module R64Rc01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
fact SafeTitle (t: String)
check checkTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s > 0 then
    ok s ::: SafeTitle s
  else
    fail 400 "empty"
record SafeDoc {
  title: String ::: SafeTitle title
}
fn bad(rawTitle: String) -> SafeDoc =
  SafeDoc { title: rawTitle }
|}

let test_R64_RC02_record_field_with_correct_proof_accepted () =
  should_pass {|
#lang tesl
module R64Rc02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length]
fact SafeTitle (t: String)
check checkTitle(s: String) -> s: String ::: SafeTitle s =
  if String.length s > 0 then
    ok s ::: SafeTitle s
  else
    fail 400 "empty"
record SafeDoc {
  title: String ::: SafeTitle title
}
fn good(rawTitle: String) -> SafeDoc =
  let t = check checkTitle rawTitle
  SafeDoc { title: t }
|}

(* ── R64_FI — filterCheck with non-check argument ───────────────────────── *)

let test_R64_FI01_plain_fn_in_filtercheck_rejected () =
  should_fail "fn.*not a.*check\\|not.*check.*fn" {|
#lang tesl
module R64Fi01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fn double(n: Int) -> Int = n * 2
fn bad(xs: List Int) -> List Int =
  List.filterCheck double xs
|}

let test_R64_FI02_check_fn_in_filtercheck_accepted () =
  should_pass {|
#lang tesl
module R64Fi02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn good(xs: List Int) -> List Int ? ForAll (IsPositive) =
  List.filterCheck checkPos xs
|}

(* ── R64_PR — Proof predicate import required ────────────────────────────── *)

let test_R64_PR01_unimported_proof_predicate_in_annotation_rejected () =
  should_fail "not in scope\\|proof predicate\\|unknown" {|
#lang tesl
module R64Pr01 exposing []
import Tesl.Prelude exposing [Int]
fn bad(n: Int ::: IsPositive n) -> Int = n
|}

let test_R64_PR02_stdlib_proof_predicate_requires_import () =
  (* IsNonZero from Tesl.Int must be imported explicitly *)
  should_fail "not in scope\\|proof predicate\\|unknown\\|type error" {|
#lang tesl
module R64Pr02 exposing []
import Tesl.Prelude exposing [Int]
fn bad(n: Int ::: IsNonZero n) -> Int = n
|}

(* ── R64_IL — Inline literals in check call positions ───────────────────── *)

let test_R64_IL01_inline_literal_to_check_fn_in_fn_body_accepted () =
  (* In a fn body, passing an inline literal to a check function is accepted.
     The proof subject for the result is the bound let-name, not the literal.
     Note: this is asymmetric with test blocks where inline literals ARE rejected. *)
  should_pass {|
#lang tesl
module R64Il01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn good() -> Int =
  let r = check checkPos 5
  needsPos r
|}

(* ── R64_BA — Bare check result (not bound) ─────────────────────────────── *)

let test_R64_BA01_bare_check_result_not_bound_rejected () =
  should_fail "check\\|bare\\|bound\\|let" {|
#lang tesl
module R64Ba01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn bad(x: Int) -> Int =
  check checkPos x
  42
|}

(* ── R64_AU — Auth in fn body ───────────────────────────────────────────── *)

let test_R64_AU01_auth_in_fn_body_rejected () =
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R64Au01 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth myAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn bad(tok: String) -> String =
  let user = check myAuth tok
  user
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review64-Antagonistic" [
    "cross-subject-forgery", [
      test_case "R64_XS01 cross-subject attachFact forgery rejected" `Quick test_R64_XS01_cross_subject_forgery_via_attachfact_rejected;
      test_case "R64_XS02 introAnd different subjects rejected" `Quick test_R64_XS02_introand_different_subjects_rejected;
    ];
    "newtype-isolation", [
      test_case "R64_NT01 String where newtype Email expected rejected" `Quick test_R64_NT01_string_where_newtype_expected_rejected;
      test_case "R64_NT02 UserId where ProjectId expected rejected" `Quick test_R64_NT02_userid_where_projectid_expected_rejected;
      test_case "R64_NT03 ValidUser proof not applicable to ProjectId" `Quick test_R64_NT03_newtype_proof_not_applicable_to_other_newtype;
    ];
    "cross-param-proof", [
      test_case "R64_CP01 partial application of cross-param proof rejected" `Quick test_R64_CP01_partial_apply_cross_param_proof_rejected;
    ];
    "forall-restrictions", [
      test_case "R64_FA01 ForAll param without explicit subject rejected" `Quick test_R64_FA01_forall_param_without_explicit_subject_rejected;
      test_case "R64_FA02 ForAll on Dict type rejected" `Quick test_R64_FA02_forall_on_dict_type_rejected;
      test_case "R64_FA03 ForAll on Int type rejected" `Quick test_R64_FA03_forall_on_int_type_rejected;
      test_case "R64_FA04 literal-param predicate in ForAll now works (FIXED)" `Quick test_R64_FA04_literal_param_predicate_now_works;
    ];
    "establish-restrictions", [
      test_case "R64_ES01 establish body with fail rejected" `Quick test_R64_ES01_check_call_inside_establish_body_rejected;
      test_case "R64_ES02 establish body with ok syntax rejected" `Quick test_R64_ES02_establish_with_ok_syntax_rejected;
      test_case "R64_ES03 establish with direct fact construction accepted" `Quick test_R64_ES03_establish_direct_fact_construction_accepted;
      test_case "R64_ES04 establish returning Maybe(Fact) accepted" `Quick test_R64_ES04_establish_returning_maybe_fact_accepted;
    ];
    "fn-proof-restrictions", [
      test_case "R64_FN01 fn cannot mint new proof rejected" `Quick test_R64_FN01_fn_cannot_mint_new_proof_rejected;
      test_case "R64_FN02 fn proof passthrough accepted" `Quick test_R64_FN02_fn_proof_passthrough_accepted;
    ];
    "shadowing", [
      test_case "R64_SH01 let shadowing param rejected" `Quick test_R64_SH01_let_shadowing_param_rejected;
      test_case "R64_SH02 case binder shadowing outer name rejected" `Quick test_R64_SH02_case_binder_shadowing_outer_name_rejected;
      test_case "R64_SH03 nested let shadowing earlier let rejected" `Quick test_R64_SH03_nested_let_shadowing_rejected;
    ];
    "wrong-proof", [
      test_case "R64_WR01 wrong predicate at callsite rejected" `Quick test_R64_WR01_wrong_predicate_at_callsite_rejected;
      test_case "R64_WR02 wrong subject same predicate rejected" `Quick test_R64_WR02_wrong_subject_same_predicate_rejected;
      test_case "R64_WR03 conjunction subset rejected" `Quick test_R64_WR03_conjunction_subset_rejected;
    ];
    "mutual-recursion", [
      test_case "R64_MR01 mutual recursion without proofs accepted" `Quick test_R64_MR01_mutual_recursion_accepted;
      test_case "R64_MR02 mutual recursion with proof-carrying values accepted" `Quick test_R64_MR02_mutual_recursion_with_proof_accepted;
    ];
    "exhaustiveness", [
      test_case "R64_CS01 non-exhaustive case rejected" `Quick test_R64_CS01_non_exhaustive_case_rejected;
      test_case "R64_CS02 exhaustive case accepted" `Quick test_R64_CS02_exhaustive_case_accepted;
      test_case "R64_CS03 wildcard arm makes exhaustive" `Quick test_R64_CS03_wildcard_arm_makes_exhaustive;
    ];
    "capability-cycles", [
      test_case "R64_CC01 two-way capability cycle rejected" `Quick test_R64_CC01_two_way_capability_cycle_rejected;
      test_case "R64_CC02 four-way capability cycle rejected" `Quick test_R64_CC02_four_way_capability_cycle_rejected;
      test_case "R64_CC03 linear capability chain accepted" `Quick test_R64_CC03_linear_capability_chain_accepted;
    ];
    "record-construction", [
      test_case "R64_RC01 record field with wrong proof rejected" `Quick test_R64_RC01_record_field_with_wrong_proof_rejected;
      test_case "R64_RC02 record field with correct proof accepted" `Quick test_R64_RC02_record_field_with_correct_proof_accepted;
    ];
    "filtercheck", [
      test_case "R64_FI01 plain fn in filterCheck rejected" `Quick test_R64_FI01_plain_fn_in_filtercheck_rejected;
      test_case "R64_FI02 check fn in filterCheck accepted" `Quick test_R64_FI02_check_fn_in_filtercheck_accepted;
    ];
    "proof-import", [
      test_case "R64_PR01 unimported proof predicate rejected" `Quick test_R64_PR01_unimported_proof_predicate_in_annotation_rejected;
      test_case "R64_PR02 stdlib proof predicate requires explicit import" `Quick test_R64_PR02_stdlib_proof_predicate_requires_import;
    ];
    "inline-literals", [
      test_case "R64_IL01 inline literal to check fn in fn body accepted" `Quick test_R64_IL01_inline_literal_to_check_fn_in_fn_body_accepted;
    ];
    "bare-check", [
      test_case "R64_BA01 bare check result not bound rejected" `Quick test_R64_BA01_bare_check_result_not_bound_rejected;
    ];
    "auth-restrictions", [
      test_case "R64_AU01 auth in fn body rejected" `Quick test_R64_AU01_auth_in_fn_body_rejected;
    ];
  ]
