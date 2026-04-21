(** Antagonistic regression tests for Critical Review 52.

    Adversarial focus areas:
      - Record ghost-witness subject check (soundness hole discovered in R52).
      - Lambda proof-annotation bypass (soundness hole — the lambda
        parameter's `::: Pred x` is silently ignored at the call site).
      - ForAll empty-list rejection (spec section 16.9 explicitly requires
        that `[]` not vacuously satisfy any `ForAll P`).
      - Qualified-only import broken at runtime (`import Tesl.List` with no
        exposing clause should make `List.length` callable via qualification;
        today the emit layer emits `tesl_import_List_length` which is unbound).
      - Non-exhaustive guard-only case arms (guard makes the arm conditional
        but the compiler still accepts it as exhaustive).
      - Integer fixnum negative-boundary parsing.
      - Formatter partial whitespace normalisation.

    Suffix conventions:
      - `_bug` — still-open regression; the test asserts the CURRENT
        (incorrect) behaviour so the suite fails the moment the bug is fixed.
      - `_fixed` — the fix has already landed in this review round.
      - No suffix — positive control. *)

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

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file _prefix _suffix content f =
  let dir = Filename.temp_dir "tesl-r52" "" in
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
  write_file path content;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r52" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r52" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* A "currently passes" test: the behaviour is wrong — the compiler should
   reject this program. The test intentionally fails (flips red) once the
   fix lands so the maintainer knows to replace it with `should_fail_src`. *)
let [@warning "-32"] should_currently_pass_src src =
  with_temp_file "tesl-r52" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "this test captures a KNOWN-OPEN bug. The compiler now REJECTS \
             this input (which is the correct behaviour). Please flip this \
             test to `should_fail_src` with the new diagnostic.\n\ntool output:\n%s" out)

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact]
import Tesl.Maybe exposing [Maybe(..)]
|}

let positive_decl = {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R52_L — LAMBDA PROOF SOUNDNESS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_L01 — FIXED. A `let`-bound lambda with a proof-annotated parameter is
   applied to an unproven value. The compiler now rejects this via the
   let_lambda_errors check in check_expr_call_proofs. *)
let r52_l01_lambda_launders_proof_bug () =
  should_fail_src "does not statically satisfy declared proof" (base_header ^ {|
fact IsPositive (n: Int)

fn bypass(x: Int) -> Int =
  let launder = fn(n: Int ::: IsPositive n) -> n
  launder x
|})

(* R52_L02 — FIXED. Inline application of a proof-annotated lambda to a raw
   value. The compiler now detects the ELambda head in EApp and checks proofs. *)
let r52_l02_inline_lambda_launders_proof_bug () =
  should_fail_src "does not statically satisfy declared proof" (base_header ^ {|
fact IsPositive (n: Int)

fn bypass(x: Int) -> Int =
  (fn(n: Int ::: IsPositive n) -> n) x
|})

(* R52_L03 — FIXED. A proof-annotated lambda passed through a generic HOF is
   rejected because the alias is used in a non-call position. *)
let r52_l03_lambda_via_hof_launders_proof_bug () =
  should_fail_src "cannot be passed around" (base_header ^ {|
fact IsPositive (n: Int)

fn applyFn(f: Int -> Int, x: Int) -> Int = f x

fn bypass(x: Int) -> Int =
  let laundered = fn(n: Int ::: IsPositive n) -> n
  applyFn laundered x
|})

(* R52_L04 — control. Passing the proof-annotated lambda to an argument
   obtained via `check` should still work (it is not a laundering). Once
   the laundering bug is closed, the fix must NOT regress this legitimate
   case. *)
let r52_l04_lambda_with_checked_arg_ok () =
  should_pass_src (base_header ^ positive_decl ^ {|
fn usage(raw: Int) -> Int =
  let checked = check isPositive raw
  let f = fn(n: Int ::: IsPositive n) -> n
  f checked
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_R — RECORD GHOST WITNESS — SUBJECT IDENTITY
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_R01 — BUG. The spec section 11.7 "Subject check" requires that the
   proof subjects inside the ghost witness match the subjects of the
   fields in the record literal. A Fact-typed parameter bound to
   `BothPos x y` is accepted as a witness for `Pair { a: y, b: x }`,
   silently retargeting the cross-field proof. *)
let r52_r01_ghost_witness_subject_swap_bug () =
  should_fail_src "ghost witness subjects do not match record fields" (base_header ^ {|
fact IsPositive (n: Int)
fact BothPos (a: Int) (b: Int)

record Pair {
  a: Int ::: IsPositive a
  b: Int ::: IsPositive b
} ::: BothPos a b

fn constructSwapped(x: Int ::: IsPositive x, y: Int ::: IsPositive y, w: Fact (BothPos x y)) -> Pair =
  Pair { a: y, b: x } ::: detachFact w
|})

(* R52_R02 — control. Correct ghost witness with matching subjects must
   still be accepted. *)
let r52_r02_ghost_witness_correct_subjects_ok () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact BothPos (a: Int) (b: Int)

record Pair {
  a: Int ::: IsPositive a
  b: Int ::: IsPositive b
} ::: BothPos a b

fn makeOk(x: Int ::: IsPositive x, y: Int ::: IsPositive y, w: Fact (BothPos x y)) -> Pair =
  Pair { a: x, b: y } ::: detachFact w
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_F — ForAll on empty list
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_F01 — FIXED. Spec section 16.9 says an empty list literal does NOT
   vacuously satisfy any `ForAll P`. The compiler now rejects this. *)
let r52_f01_forall_empty_list_bug () =
  should_fail_src "requires proof" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]

fact IsPositive (n: Int)

fn needPosList(xs: List Int ::: ForAll IsPositive xs) -> Int =
  List.length xs

fn emptyCase() -> Int =
  needPosList []
|}

(* R52_F02 — control. List produced by `List.filterCheck isPositive xs`
   legitimately satisfies `ForAll IsPositive`. *)
let r52_f02_forall_filtercheck_ok () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]

fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "np"

fn needPosList(xs: List Int ::: ForAll IsPositive xs) -> Int =
  List.length xs

fn okCase(xs: List Int) -> Int =
  let checked = List.filterCheck isPositive xs
  needPosList checked
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R52_Q — QUALIFIED-ONLY IMPORT
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_Q01 — FIXED. `import Module` (no exposing) now emits proper `only-in`
   bindings for every qualified name used in the file. `List.length` is bound
   to `tesl_import_List_length` in the generated Racket, so the program both
   compiles and runs correctly. *)
let r52_q01_qualified_only_compiles_bug () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List

fn demo() -> Int =
  List.length [1, 2, 3]
|}

(* R52_Q02 — control. Explicit dotted exposing works. *)
let r52_q02_qualified_explicit_ok () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.length]

fn demo() -> Int =
  List.length [1, 2, 3]
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R52_G — CASE GUARDS AND EXHAUSTIVENESS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_G01 — BUG. A case arm with a guard is accepted as exhaustive, but
   when the guard fails there is no fallback arm and the function falls
   off the end. The spec's exhaustiveness rule should NOT credit a
   guarded arm as a full match. *)
let r52_g01_guard_only_arm_not_exhaustive_bug () =
  should_fail_src "non-exhaustive case" (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something n where n > 0 -> n
|})

(* R52_G02 — control. Adding the catch-all makes the body exhaustive. *)
let r52_g02_guard_with_fallback_ok () =
  should_pass_src (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something n where n > 0 -> n
    Something _ -> 0
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_P — PROOF SUBJECT DIAGNOSTICS (UX)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_P01 — Baseline: bypass attempt is rejected with a clear diagnostic. *)
let r52_p01_hint_vs_message_uses_different_names () =
  should_fail_src "does not statically satisfy declared proof" (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn tryBypass(mimic: Int) -> Int =
  needPos mimic
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_T — TYPE SYSTEM / PROOFS — DEEP
   ═══════════════════════════════════════════════════════════════════════════ *)

let triple_preamble = {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
fact IsEven (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "np"

check isSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "ns"

check isEven(n: Int) -> n: Int ::: IsEven n =
  if n % 2 == 0 then
    ok n ::: IsEven n
  else
    fail 400 "ne"
|}

(* R52_T01 — control. Three chained checks compose into a 3-ary proof on
   the final bound value. *)
let r52_t01_triple_check_compose_ok () =
  should_pass_src (base_header ^ triple_preamble ^ {|
fn needThree(n: Int ::: IsPositive n && IsSmall n && IsEven n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check isPositive raw
  let b = check isSmall a
  let c = check isEven b
  needThree c
|})

(* R52_T02 — Document a flat-conjunction commute. Passing a triple proof
   in a different order must still satisfy the conjunction. *)
let r52_t02_triple_proof_commutes_ok () =
  should_pass_src (base_header ^ triple_preamble ^ {|
fn needReordered(n: Int ::: IsEven n && IsPositive n && IsSmall n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check isPositive raw
  let b = check isSmall a
  let c = check isEven b
  needReordered c
|})

(* R52_T03 — control. Compound `&&` attach expression with proof
   variables (from a two-way decomposition). *)
let r52_t03_compound_attach_explicit_ok () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "np"

check isSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "ns"

fn needBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check isPositive raw
  let b = check isSmall a
  let (v ::: p1 && p2) = b
  let reat = v ::: p1 && p2
  needBoth reat
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_S — SHADOWING / SCOPING EDGE CASES
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_S01 — Shadowing a record field name via a let inside a function
   that takes the record. Should be fine (fields are not visible as
   bindings). *)
let r52_s01_field_name_let_ok () =
  should_pass_src (base_header ^ {|
record Point { x: Int, y: Int }

fn demo(p: Point) -> Int =
  let localX = 42
  p.x + localX
|})

(* R52_S02 — control. Shadowing via case binder is rejected. *)
let r52_s02_case_shadow_rejected () =
  should_fail_src "shadows" (base_header ^ {|
fn demo(x: Int) -> Int =
  case x of
    _ ->
      let x = 42
      x
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_X — SUBTLE PARSER EDGE CASES
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_X01 — control. A proof pattern `(v ::: p)` directly around a
   function return works even when the proof predicate is multi-argument. *)
let r52_x01_multi_arg_proof_decompose_ok () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check inRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn demo(lo: Int, hi: Int, raw: Int) -> Int =
  let checked = check inRange lo hi raw
  let (v ::: p) = checked
  v
|})

(* R52_X02 — control. Proof annotation on lambda parameter with no
   conjunction (simplest case). Parser accepts; see R52_L for the
   soundness issue. *)
let r52_x02_lambda_proof_annotation_parses () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

fn demo(n: Int ::: IsPositive n) -> Int =
  let f = fn(m: Int ::: IsPositive m) -> m
  f n
|})

(* R52_X03 — FIXED. Nested `exists` with the SAME witness name is now
   rejected: the inner `exists p` shadows the outer `exists p` witness,
   making the two existential packages indistinguishable. *)
let r52_x03_nested_exists_same_witness_bug () =
  should_fail_src "exists witness.*shadows" (base_header ^ positive_decl ^ {|
fn nested(raw: Int)
  -> exists x: Int => exists y: Int => Int ::: IsPositive x && IsPositive y =
  let p = check isPositive raw
  exists p =>
    exists p =>
      p
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R52_FMT — FORMATTER
   ═══════════════════════════════════════════════════════════════════════════ *)

let run_fmt_and_read src =
  with_temp_file "tesl-r52" ".tesl" src (fun path ->
    let _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let contents = In_channel.input_all ic in
    close_in ic;
    contents)

(* R52_FMT01 — FIXED. The formatter now collapses multiple internal spaces
   between identifiers and keywords into a single space. *)
let r52_fmt01_internal_spaces_not_collapsed_bug () =
  let got = run_fmt_and_read
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn   demo  (a: Int, b: Int)    -> Int   = a + b
|} in
  (* Verify that the multiple spaces have been collapsed to single spaces *)
  let re_collapsed = Str.regexp_string "fn demo" in
  (try ignore (Str.search_forward re_collapsed got 0)
   with Not_found ->
     failwith ("Expected 'fn demo' (collapsed) in formatter output:\n" ^ got));
  (* Verify the multi-space form is no longer present *)
  let re_old = Str.regexp_string "fn   demo" in
  (try ignore (Str.search_forward re_old got 0);
       failwith ("Formatter still emits 'fn   demo' (not collapsed):\n" ^ got)
   with Not_found -> ())

(* R52_FMT02 — Formatter normalises whitespace AROUND `->` already
   (control / regression). *)
let r52_fmt02_arrow_is_spaced () =
  let got = run_fmt_and_read
    {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(n: Int) -> Int = n
|} in
  let re = Str.regexp_string ") -> Int" in
  try ignore (Str.search_forward re got 0)
  with Not_found -> failwith "expected formatter to keep `) -> Int` spacing"

(* ═══════════════════════════════════════════════════════════════════════════
   R52_N — Fresh adversarial coverage
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R52_N01 — Multiparameter fact through a proof-decomposition + reattach. *)
let r52_n01_multi_param_decomp_reattach_ok () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check inRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "oor"

fn need(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n

fn demo(lo: Int, hi: Int, raw: Int) -> Int =
  let checked = check inRange lo hi raw
  let (v ::: p) = checked
  let reat = v ::: p
  need lo hi reat
|})

(* R52_N02 — control. Reattaching a proof to a DIFFERENT (unrelated) binder
   is correctly rejected. *)
let r52_n02_decompose_reuse_proof_for_unrelated_rejected () =
  should_fail_src "does not statically satisfy" (base_header ^ positive_decl ^ {|
fn need(n: Int ::: IsPositive n) -> Int = n

fn demo(raw: Int, other: Int) -> Int =
  let p = check isPositive raw
  let (v ::: proof) = p
  let weird = other ::: proof
  need weird
|})

(* R52_N03 — control. Proof re-attach to the binder from which it was
   detached is fine. *)
let r52_n03_decompose_reattach_same_binder_ok () =
  should_pass_src (base_header ^ positive_decl ^ {|
fn need(n: Int ::: IsPositive n) -> Int = n

fn demo(raw: Int) -> Int =
  let p = check isPositive raw
  let (v ::: proof) = p
  let reat = v ::: proof
  need reat
|})

(* R52_N04 — control. A case-arm proof binder can be reattached to the
   originating subject. *)
let r52_n04_establish_case_arm_same_subject_ok () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

establish provePositive(n: Int) -> Maybe (Fact (IsPositive n)) =
  if n > 0 then
    Something (IsPositive n)
  else
    Nothing

fn need(n: Int ::: IsPositive n) -> Int = n

fn demo(x: Int) -> Int =
  let mRes = provePositive x
  case mRes of
    Something pX ->
      need <| x ::: pX
    Nothing -> 0
|})

(* R52_N05 — control. Reattaching a proof to a DIFFERENT binder in the
   same function (when both are in scope) IS correctly rejected — the
   subject-tracking for `Something pX` arms works for this particular
   shape. This rules out a hypothesised variant of the R52_R01 ghost-witness
   bug; the ghost-witness bug is specific to the record-invariant path. *)
let r52_n05_establish_case_arm_retarget_rejected () =
  should_fail_src "different subject\\|does not statically satisfy" (base_header ^ {|
fact IsPositive (n: Int)

establish provePositive(n: Int) -> Maybe (Fact (IsPositive n)) =
  if n > 0 then
    Something (IsPositive n)
  else
    Nothing

fn need(n: Int ::: IsPositive n) -> Int = n

fn demo(x: Int, y: Int) -> Int =
  let mRes = provePositive x
  case mRes of
    Something pX ->
      need <| y ::: pX
    Nothing -> 0
|})

(* R52_N06 — control. `forgetFact` then re-check cycle keeps the proof
   fresh and tied to the latest bind. *)
let r52_n06_forget_recheck_ok () =
  should_pass_src (base_header ^ positive_decl ^ {|
fn need(n: Int ::: IsPositive n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check isPositive raw
  let b = forgetFact a
  let c = check isPositive b
  need c
|})

(* R52_N07 — Control: integer literal at the exact upper bound compiles. *)
let r52_n07_max_int_literal_ok () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn maxInt() -> Int = 4611686018427387903
|}

(* R52_N08 — The literal JUST above the positive fixnum cap is rejected. *)
let r52_n08_above_max_int_literal_rejected () =
  should_fail_src "out of range\\|fixnum" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn tooBig() -> Int = 4611686018427387904
|}

(* R52_N09 — FIXED (R52-INT-NEG). The lexer now allows the literal
   4611686018427387904 (= 2^62) under a unary minus, so `-2^62` is valid.
   The positive literal 4611686018427387904 alone is still rejected. *)
let r52_n09_below_min_int_literal_bug () =
  (* -2^62 is now valid as the minimum Tesl Int value *)
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn negMin() -> Int = -4611686018427387904
|};
  (* Positive 2^62 is still too large *)
  should_fail_src "out of range" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn tooBig() -> Int = 4611686018427387904
|}

(* R52_N10 — control. A proof-bearing argument cannot be used with a
   function expecting a different predicate even when both are 1-arg. *)
let r52_n10_wrong_predicate_rejected () =
  should_fail_src "does not statically satisfy" (base_header ^ {|
fact IsPositive (n: Int)
fact IsEven (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "np"

fn needEven(n: Int ::: IsEven n) -> Int = n

fn demo(raw: Int) -> Int =
  let p = check isPositive raw
  needEven p
|})

(* R52_N11 — BUG. Exhaustiveness: a nested `case` inside a guarded outer
   arm does not rescue the missing fallback. *)
let r52_n11_nested_guard_non_exhaustive_bug () =
  should_fail_src "non-exhaustive case" (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing ->
      0
    Something n where n > 0 ->
      case n of
        42 -> 42
        _  -> n
|})

(* R52_N12 — control. Explicit catch-all arm yields exhaustiveness. *)
let r52_n12_nested_guard_with_catchall_ok () =
  should_pass_src (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing ->
      0
    Something n where n > 0 ->
      n
    Something _ ->
      0
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TEST REGISTRATION
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review52-Antagonistic" [
    "lambda-proof-soundness", [
      test_case "R52_L01 let-bound lambda proof enforced (fixed)"              `Quick r52_l01_lambda_launders_proof_bug;
      test_case "R52_L02 inline lambda proof enforced (fixed)"                 `Quick r52_l02_inline_lambda_launders_proof_bug;
      test_case "R52_L03 lambda via HOF rejected (fixed)"                      `Quick r52_l03_lambda_via_hof_launders_proof_bug;
      test_case "R52_L04 lambda with checked arg still works (control)"        `Quick r52_l04_lambda_with_checked_arg_ok;
    ];
    "record-ghost-witness-subject", [
      test_case "R52_R01 ghost witness subject swap via Fact param (fixed)"     `Quick r52_r01_ghost_witness_subject_swap_bug;
      test_case "R52_R02 correct ghost witness subjects (control)"             `Quick r52_r02_ghost_witness_correct_subjects_ok;
    ];
    "forall-empty-list", [
      test_case "R52_F01 empty list vacuous ForAll rejected (fixed)"           `Quick r52_f01_forall_empty_list_bug;
      test_case "R52_F02 filterCheck produces ForAll (control)"                `Quick r52_f02_forall_filtercheck_ok;
    ];
    "qualified-only-import", [
      test_case "R52_Q01 `import Module` qualified names work (fixed)"          `Quick r52_q01_qualified_only_compiles_bug;
      test_case "R52_Q02 explicit dotted exposing works (control)"             `Quick r52_q02_qualified_explicit_ok;
    ];
    "guarded-case-exhaustiveness", [
      test_case "R52_G01 guard-only arm accepted as exhaustive (fixed)"         `Quick r52_g01_guard_only_arm_not_exhaustive_bug;
      test_case "R52_G02 guard + catch-all arm (control)"                      `Quick r52_g02_guard_with_fallback_ok;
    ];
    "proof-subject-diagnostics", [
      test_case "R52_P01 bypass diagnostic present"                            `Quick r52_p01_hint_vs_message_uses_different_names;
    ];
    "type-system-deep", [
      test_case "R52_T01 triple check compose (control)"                       `Quick r52_t01_triple_check_compose_ok;
      test_case "R52_T02 triple proof commutes"                                `Quick r52_t02_triple_proof_commutes_ok;
      test_case "R52_T03 compound attach with proof variables (control)"       `Quick r52_t03_compound_attach_explicit_ok;
    ];
    "shadowing-edges", [
      test_case "R52_S01 field-name shadow via let is fine"                    `Quick r52_s01_field_name_let_ok;
      test_case "R52_S02 case binder shadow rejected (control)"                `Quick r52_s02_case_shadow_rejected;
    ];
    "parser-edges", [
      test_case "R52_X01 multi-arg proof decompose (control)"                  `Quick r52_x01_multi_arg_proof_decompose_ok;
      test_case "R52_X02 lambda proof annotation parses"                       `Quick r52_x02_lambda_proof_annotation_parses;
      test_case "R52_X03 nested exists same witness name (fixed)"               `Quick r52_x03_nested_exists_same_witness_bug;
    ];
    "formatter", [
      test_case "R52_FMT01 internal spaces collapsed (fixed)"                  `Quick r52_fmt01_internal_spaces_not_collapsed_bug;
      test_case "R52_FMT02 arrow is spaced (control)"                          `Quick r52_fmt02_arrow_is_spaced;
    ];
    "new-adversarial", [
      test_case "R52_N01 multi-param decompose reattach (control)"             `Quick r52_n01_multi_param_decomp_reattach_ok;
      test_case "R52_N02 proof retargeted to unrelated value rejected (ctrl)"  `Quick r52_n02_decompose_reuse_proof_for_unrelated_rejected;
      test_case "R52_N03 decompose reattach same binder (control)"             `Quick r52_n03_decompose_reattach_same_binder_ok;
      test_case "R52_N04 establish case-arm same subject (control)"            `Quick r52_n04_establish_case_arm_same_subject_ok;
      test_case "R52_N05 establish case-arm subject retarget rejected"            `Quick r52_n05_establish_case_arm_retarget_rejected;
      test_case "R52_N06 forget + recheck cycle (control)"                     `Quick r52_n06_forget_recheck_ok;
      test_case "R52_N07 max Int literal compiles (control)"                   `Quick r52_n07_max_int_literal_ok;
      test_case "R52_N08 above-max literal rejected (control)"                 `Quick r52_n08_above_max_int_literal_rejected;
      test_case "R52_N09 below-min Int literal -2^62 now valid (fixed)"         `Quick r52_n09_below_min_int_literal_bug;
      test_case "R52_N10 wrong predicate rejected (control)"                   `Quick r52_n10_wrong_predicate_rejected;
      test_case "R52_N11 nested case inside guarded arm (fixed)"                `Quick r52_n11_nested_guard_non_exhaustive_bug;
      test_case "R52_N12 nested case with explicit catch-all (control)"        `Quick r52_n12_nested_guard_with_catchall_ok;
    ];
  ]
