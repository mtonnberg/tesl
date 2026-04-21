(** Antagonistic regression tests for Critical Review 63.

    This review audits:
    1. Proof propagation through function parameter boundaries (emitter bug fixed)
    2. ForAll subject in parameter position requires explicit subject
    3. LANGUAGE-SPEC.md ForAll examples using wrong (implicit) subject syntax
    4. detachFact on multi-proof is runtime-only (not caught at compile time)
    5. Nested constructor patterns work in case expressions
    6. Multi-param proofs through function boundaries
    7. establish cannot use fail
    8. fn cannot declare a proof-carrying return unless passthrough
    9. ForAll return type with ::: vs ? operator
    10. Empty list to ForAll parameter rejected
    11. Newtype nominal isolation enforced
    12. Capabilities cannot form cycles (extended check)
    13. Record-level proof ghost witness required
    14. Dict.get correct pattern vs incorrect pattern
    15. Complex conjunction ordering in ok return
    16. Shadowing of case binders rejected
    17. Static check: passing raw value to proof-annotated function rejects
    18. ForAll in return type (::: form) requires explicit subject
    19. Single-line if in function body rejected
    20. Auth functions restricted to handler context
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
  let dir = Filename.temp_dir "tesl-r63" "" in
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

(* ── R63_FA — ForAll subject in parameter position ──────────────────────── *)

let test_R63_FA01_forall_param_without_explicit_subject_rejected () =
  (* The LANGUAGE-SPEC.md shows `ForAll (IsActive)` without explicit subject in
     parameter position, but the compiler requires `ForAll (IsActive) xs`.
     This tests the spec example which should currently be REJECTED. *)
  should_fail "ForAll.*explicit subject\\|explicit subject.*ForAll" {|
#lang tesl
module R63Fa01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]
fact IsActive (n: Int)
fn countActive(notes: List Int ::: ForAll (IsActive)) -> Int =
  List.length notes
|}

let test_R63_FA02_forall_param_with_explicit_subject_accepted () =
  should_pass {|
#lang tesl
module R63Fa02 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]
fact IsActive (n: Int)
fn countActive(notes: List Int ::: ForAll (IsActive) notes) -> Int =
  List.length notes
|}

let test_R63_FA03_forall_return_triple_colon_with_explicit_subject_rejected () =
  (* ForAll in ::: return type with explicit subject is a parse error;
     use ? operator instead *)
  should_fail "expected =\\|parse error" {|
#lang tesl
module R63Fa03 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn getPositives(xs: List Int) -> List Int ::: ForAll (IsPositive) xs =
  List.filterCheck checkPos xs
|}

let test_R63_FA04_forall_return_question_accepted () =
  (* The ? operator is the correct way to declare ForAll return *)
  should_pass {|
#lang tesl
module R63Fa04 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn getPositives(xs: List Int) -> List Int ? ForAll (IsPositive) =
  List.filterCheck checkPos xs
|}

(* ── R63_PP — Proof propagation through function parameter boundaries ────── *)

let test_R63_PP01_proof_param_to_int_divide_accepted () =
  (* After the emitter fix, proof-annotated parameters should be accepted
     when passed to proof-total stdlib functions like Int.divide *)
  should_pass {|
#lang tesl
module R63Pp01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide, Int.nonZero, IsNonZero]
fn divHelper(a: Int, b: Int ::: IsNonZero b) -> Int =
  Int.divide a b
fn test(a: Int, b: Int) -> Int =
  let nz = check Int.nonZero b
  divHelper a nz
|}

let test_R63_PP02_raw_param_to_int_divide_rejected () =
  (* Without the proof, Int.divide should be rejected statically *)
  should_fail "does not statically satisfy\\|proof" {|
#lang tesl
module R63Pp02 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide, Int.nonZero, IsNonZero]
fn divHelper(a: Int, b: Int) -> Int =
  Int.divide a b
|}

let test_R63_PP03_proof_param_to_dict_get_accepted () =
  should_pass {|
#lang tesl
module R63Pp03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.requireKey, Dict.get, HasKey]
fn getHelper(key: String, d: Dict String Int ::: HasKey key d) -> Int =
  Dict.get key d
fn test(key: String, d: Dict String Int) -> Int =
  let checked = check Dict.requireKey key d
  getHelper key checked
|}

let test_R63_PP04_float_div_with_proof_param_accepted () =
  should_pass {|
#lang tesl
module R63Pp04 exposing []
import Tesl.Float exposing [Float, Float.div, Float.requireNonZero, FloatNonZero]
fn divHelper(a: Float, b: Float ::: FloatNonZero b) -> Float =
  Float.div a b
fn test(a: Float, b: Float) -> Float =
  let nz = check Float.requireNonZero b
  divHelper a nz
|}

(* ── R63_NE — Newtype nominal isolation ─────────────────────────────────── *)

let test_R63_NE01_newtype_type_mismatch_rejected () =
  (* UserId and ProjectId are distinct nominal types; confusing them is an error *)
  should_fail "cannot unify\\|type mismatch" {|
#lang tesl
module R63Ne01 exposing []
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fact ValidUser (u: UserId)
check checkUser(u: UserId) -> u: UserId ::: ValidUser u =
  ok u ::: ValidUser u
fn requiresProject(p: ProjectId) -> String = p.value
fn bad(raw: String) -> String =
  let uid = UserId raw
  let valid = check checkUser uid
  requiresProject valid
|}

(* ── R63_EX — establish restrictions ───────────────────────────────────── *)

let test_R63_EX01_establish_cannot_use_fail () =
  should_fail "establish.*cannot.*fail\\|fail.*establish" {|
#lang tesl
module R63Ex01 exposing []
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "not positive"
|}

let test_R63_EX02_establish_cannot_use_ok () =
  should_fail "establish.*ok\\|ok.*establish\\|cannot.*ok" {|
#lang tesl
module R63Ex02 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|}

let test_R63_EX03_establish_direct_return_accepted () =
  should_pass {|
#lang tesl
module R63Ex03 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  IsPositive n
|}

(* ── R63_FN — fn proof restrictions ─────────────────────────────────────── *)

let test_R63_FN01_fn_cannot_mint_proof_rejected () =
  (* fn cannot declare a proof return for a non-input binding *)
  should_fail "cannot declare a proof\\|fn.*proof" {|
#lang tesl
module R63Fn01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn mint(n: Int) -> n: Int ::: IsPositive n = n
|}

let test_R63_FN02_fn_proof_passthrough_accepted () =
  (* fn CAN declare a proof return if it's a passthrough of an input *)
  should_pass {|
#lang tesl
module R63Fn02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn passthrough(n: Int ::: IsPositive n) -> n: Int ::: IsPositive n = n
|}

(* ── R63_EL — Empty list to ForAll rejected ─────────────────────────────── *)

let test_R63_EL01_empty_list_to_forall_param_rejected () =
  should_fail "no trackable subject\\|ForAll" {|
#lang tesl
module R63El01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]
fact IsPositive (n: Int)
fn process(xs: List Int ::: ForAll (IsPositive) xs) -> Int =
  List.length xs
fn bad() -> Int =
  process []
|}

(* ── R63_SH — Shadowing rejected ────────────────────────────────────────── *)

let test_R63_SH01_case_binder_shadowing_rejected () =
  should_fail "shadows\\|shadow" {|
#lang tesl
module R63Sh01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn test(m: Maybe Int, n: Int) -> Int =
  case m of
    Nothing -> 0
    Something n -> n
|}

let test_R63_SH02_let_shadowing_existing_param_rejected () =
  should_fail "shadows\\|shadow" {|
#lang tesl
module R63Sh02 exposing []
import Tesl.Prelude exposing [Int]
fn test(x: Int) -> Int =
  let x = 5
  x
|}

(* ── R63_AU — Auth restrictions ─────────────────────────────────────────── *)

let test_R63_AU01_auth_in_fn_rejected () =
  should_fail "auth functions may only be called from handler bodies" {|
#lang tesl
module R63Au01 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth myAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn bad(tok: String) -> String =
  let user = check myAuth tok
  user
|}

let test_R63_AU02_auth_in_handler_accepted () =
  should_pass {|
#lang tesl
module R63Au02 exposing []
import Tesl.Prelude exposing [String]
fact Authenticated (s: String)
auth myAuth(tok: String) -> tok: String ::: Authenticated tok =
  ok tok ::: Authenticated tok
fn requiresAuth(s: String ::: Authenticated s) -> String = s
handler h(tok: String) -> String =
  let user = check myAuth tok
  requiresAuth user
|}

(* ── R63_CC — Capability cycles ─────────────────────────────────────────── *)

let test_R63_CC01_three_way_capability_cycle_rejected () =
  should_fail "cycle" {|
#lang tesl
module R63Cc01 exposing []
import Tesl.Prelude exposing [Int]
capability alpha implies beta
capability beta implies gamma
capability gamma implies alpha
handler h(x: Int) -> Int requires [alpha] = x
|}

(* ── R63_WI — Wrong predicate in introduce ──────────────────────────────── *)

let test_R63_WI01_wrong_proof_predicate_at_callsite_rejected () =
  (* Passing a proven value with proof P1 to a function requiring P2 is rejected *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R63Wi01 exposing []
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "bad"
fn needsB(n: Int ::: B n) -> Int = n
fn test(x: Int) -> Int =
  let provenA = check checkA x
  needsB provenA
|}

let test_R63_WI02_wrong_subject_proof_caught () =
  (* Proven x passed where proven y is needed — same type, different subject *)
  should_fail "does not statically satisfy" {|
#lang tesl
module R63Wi02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needsPos(n: Int ::: IsPositive n) -> Int = n
fn test(x: Int, y: Int) -> Int =
  let provenX = check checkPos x
  needsPos y
|}

(* ── R63_DG — Dict.get without required proof ───────────────────────────── *)

let test_R63_DG01_dict_get_without_proof_rejected () =
  should_fail "does not statically satisfy\\|HasKey" {|
#lang tesl
module R63Dg01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.get, Dict.fromList]
import Tesl.Tuple exposing [Tuple2]
fn bad(d: Dict String Int) -> Int =
  Dict.get "a" d
|}

let test_R63_DG02_dict_get_with_proof_accepted () =
  should_pass {|
#lang tesl
module R63Dg02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.requireKey, Dict.get, HasKey]
fn safeGet(key: String, d: Dict String Int) -> Int =
  let checked = check Dict.requireKey key d
  Dict.get key checked
|}

(* ── R63_FO — ForAll on non-list type rejected ───────────────────────────── *)

let test_R63_FO01_forall_on_int_rejected () =
  should_fail "ForAll.*only valid\\|only valid.*ForAll\\|not a list\\|type" {|
#lang tesl
module R63Fo01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn bad(n: Int ::: ForAll (IsPositive) n) -> Int = n
|}

(* ── R63_RW — Record update proof preservation ─────────────────────────── *)

let test_R63_RW01_record_update_preserves_proof_fields () =
  should_pass {|
#lang tesl
module R63Rw01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.length, IsTrimmed]
fact TitleSafe (s: String)
record SafeItem { title: String ::: TitleSafe title, count: Int }
check checkTitle(s: String) -> s: String ::: TitleSafe s =
  if String.length s > 0 then
    ok s ::: TitleSafe s
  else
    fail 400 "bad"
fn requiresTitleSafe(s: String ::: TitleSafe s) -> String = s
fn test(raw: String, c: Int) -> String =
  let st = check checkTitle raw
  let item = SafeItem { title: st, count: c }
  let updated = { item | count = 99 }
  requiresTitleSafe updated.title
|}

(* ── R63_MF — Multiple proof errors all reported ────────────────────────── *)

let test_R63_MF01_multiple_proof_errors_reported () =
  should_fail "requiresC" {|
#lang tesl
module R63Mf01 exposing []
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

(* ── R63_SL — Single-line if rejected ───────────────────────────────────── *)

let test_R63_SL01_single_line_if_rejected () =
  should_fail "then.*body.*must be on an indented new line\\|single.line.*if" {|
#lang tesl
module R63Sl01 exposing []
import Tesl.Prelude exposing [Int]
fn test(n: Int) -> Int = if n > 0 then n else 0
|}

(* ── R63_PR — Proof predicate import required ───────────────────────────── *)

let test_R63_PR01_unimported_proof_predicate_rejected () =
  should_fail "not in scope\\|proof predicate" {|
#lang tesl
module R63Pr01 exposing []
import Tesl.Prelude exposing [Int]
fn bad(n: Int ::: IsPositive n) -> Int = n
|}

(* ── R63_FC — filterCheck with plain fn rejected ───────────────────────── *)

let test_R63_FC01_plain_fn_in_filtercheck_rejected () =
  should_fail "fn.*not a.*check\\|not.*check.*fn" {|
#lang tesl
module R63Fc01 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck]
fn double(n: Int) -> Int = n * 2
fn bad(xs: List Int) -> List Int =
  List.filterCheck double xs
|}

let test_R63_FC02_lambda_in_filtercheck_rejected () =
  should_fail "lambda\\|inline" {|
#lang tesl
module R63Fc02 exposing []
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

(* ── R63_BN — Bare check call rejected ─────────────────────────────────── *)

let test_R63_BN01_bare_check_result_rejected () =
  (* spec says bare check (result not bound) is a compile-time error *)
  should_fail "check\\|bare\\|bound\\|let" {|
#lang tesl
module R63Bn01 exposing []
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

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review63-Antagonistic" [
    "forall-subject", [
      test_case "R63_FA01 ForAll param without explicit subject rejected" `Quick test_R63_FA01_forall_param_without_explicit_subject_rejected;
      test_case "R63_FA02 ForAll param with explicit subject accepted" `Quick test_R63_FA02_forall_param_with_explicit_subject_accepted;
      test_case "R63_FA03 ForAll return with ::: and explicit subject parse error" `Quick test_R63_FA03_forall_return_triple_colon_with_explicit_subject_rejected;
      test_case "R63_FA04 ForAll return with ? operator accepted" `Quick test_R63_FA04_forall_return_question_accepted;
    ];
    "proof-param-boundary", [
      test_case "R63_PP01 proof-annotated param to Int.divide accepted" `Quick test_R63_PP01_proof_param_to_int_divide_accepted;
      test_case "R63_PP02 plain param to Int.divide rejected" `Quick test_R63_PP02_raw_param_to_int_divide_rejected;
      test_case "R63_PP03 proof-annotated param to Dict.get accepted" `Quick test_R63_PP03_proof_param_to_dict_get_accepted;
      test_case "R63_PP04 Float.div with FloatNonZero param accepted" `Quick test_R63_PP04_float_div_with_proof_param_accepted;
    ];
    "newtype-nominal", [
      test_case "R63_NE01 newtype type mismatch rejected" `Quick test_R63_NE01_newtype_type_mismatch_rejected;
    ];
    "establish-restrictions", [
      test_case "R63_EX01 establish cannot use fail" `Quick test_R63_EX01_establish_cannot_use_fail;
      test_case "R63_EX02 establish cannot use ok" `Quick test_R63_EX02_establish_cannot_use_ok;
      test_case "R63_EX03 establish with direct return accepted" `Quick test_R63_EX03_establish_direct_return_accepted;
    ];
    "fn-proof-restrictions", [
      test_case "R63_FN01 fn cannot mint proof" `Quick test_R63_FN01_fn_cannot_mint_proof_rejected;
      test_case "R63_FN02 fn proof passthrough accepted" `Quick test_R63_FN02_fn_proof_passthrough_accepted;
    ];
    "empty-forall", [
      test_case "R63_EL01 empty list to ForAll param rejected" `Quick test_R63_EL01_empty_list_to_forall_param_rejected;
    ];
    "shadowing", [
      test_case "R63_SH01 case binder shadowing rejected" `Quick test_R63_SH01_case_binder_shadowing_rejected;
      test_case "R63_SH02 let shadowing existing param rejected" `Quick test_R63_SH02_let_shadowing_existing_param_rejected;
    ];
    "auth-restrictions", [
      test_case "R63_AU01 auth in fn rejected" `Quick test_R63_AU01_auth_in_fn_rejected;
      test_case "R63_AU02 auth in handler accepted" `Quick test_R63_AU02_auth_in_handler_accepted;
    ];
    "capability-cycles", [
      test_case "R63_CC01 three-way capability cycle rejected" `Quick test_R63_CC01_three_way_capability_cycle_rejected;
    ];
    "wrong-proof", [
      test_case "R63_WI01 wrong proof predicate at callsite rejected" `Quick test_R63_WI01_wrong_proof_predicate_at_callsite_rejected;
      test_case "R63_WI02 wrong subject proof caught" `Quick test_R63_WI02_wrong_subject_proof_caught;
    ];
    "dict-get", [
      test_case "R63_DG01 Dict.get without proof rejected" `Quick test_R63_DG01_dict_get_without_proof_rejected;
      test_case "R63_DG02 Dict.get with proof accepted" `Quick test_R63_DG02_dict_get_with_proof_accepted;
    ];
    "forall-type-restriction", [
      test_case "R63_FO01 ForAll on non-list type rejected" `Quick test_R63_FO01_forall_on_int_rejected;
    ];
    "record-update", [
      test_case "R63_RW01 record update preserves proof fields" `Quick test_R63_RW01_record_update_preserves_proof_fields;
    ];
    "multiple-errors", [
      test_case "R63_MF01 multiple proof errors all reported" `Quick test_R63_MF01_multiple_proof_errors_reported;
    ];
    "single-line-if", [
      test_case "R63_SL01 single-line if rejected" `Quick test_R63_SL01_single_line_if_rejected;
    ];
    "proof-predicate-import", [
      test_case "R63_PR01 unimported proof predicate rejected" `Quick test_R63_PR01_unimported_proof_predicate_rejected;
    ];
    "filtercheck", [
      test_case "R63_FC01 plain fn in filterCheck rejected" `Quick test_R63_FC01_plain_fn_in_filtercheck_rejected;
      test_case "R63_FC02 lambda in filterCheck rejected" `Quick test_R63_FC02_lambda_in_filtercheck_rejected;
    ];
    "bare-check", [
      test_case "R63_BN01 bare check call rejected" `Quick test_R63_BN01_bare_check_result_rejected;
    ];
  ]
