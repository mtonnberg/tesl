(** ProofSuite family M — CASE EXHAUSTIVENESS + proof-through-pattern.

    Proves the STATIC checker rejects non-total `case` expressions (and accepts
    total ones), and that a proof riding on a value flows through a pattern
    binder so a post-`case` proof requirement is satisfied — all at compile time,
    with no runtime net.

    Hardening: [should_fail] additionally fails if the compiler output contains
    a runtime-leak marker (`raise-user-error`, `check-fail`, a Racket
    backtrace) — exhaustiveness rejection must be STATIC.

    Verified error strings (all `error[V001]:`):
      - "non-exhaustive case: missing constructor(s) [Blue]"
      - "non-exhaustive case: constructor(s) [..] only appear in guarded arms — …"
      - "non-exhaustive case: literal patterns (Int, Float, or String) always require a catch-all arm `_ -> ...`"
      - "duplicate case arm: constructor `Red` is already covered"
      - "unreachable case arm (a catch-all arm at line N already matches everything)"
      - "pattern `Circle` expects 1 field but was used without any"
      - "non-exhaustive case: nested constructor/literal patterns leave uncovered values"
    Proof-through-pattern enforcement reuses the proof checker:
      - "call to `needPositive` argument `n` does not statically satisfy declared proof `IsPositive m`" *)

open Alcotest

(* ── Harness (self-contained, kebab-case filenames, runtime-leak hardening) ── *)

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

let file_name_of_src content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re content 0);
    let mname = Str.matched_group 2 content in
    let buf = Buffer.create (String.length mname + 4) in
    String.iteri (fun i c ->
      if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
      else if c >= 'A' && c <= 'Z' then
        (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c) mname;
    Buffer.contents buf ^ ".tesl"
  with Not_found -> "test.tesl"

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psM" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception";
]

let assert_no_runtime_leak pat out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "STATIC-REJECTION VIOLATED for %S: output contains runtime-leak \
                marker %S:\n%s" pat m out)
    leak_markers

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    assert_no_runtime_leak pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── ADT fixtures (verbatim grammar; multi-line `=`/`|` layout) ────────────── *)

(* A 3-constructor nullary ADT. *)
let color_adt = {|
type Color
  = Red
  | Green
  | Blue
|}

(* Field-carrying ADT (positional fields). *)
let shape_adt = {|
type Shape
  = Circle Int
  | Square Int
  | Triangle Int Int
|}

(* ── M1 — non-exhaustive: missing constructor ─────────────────────────────── *)
(* Sweep: omit each constructor of Color in turn. *)

let color_ctors = [ "Red"; "Green"; "Blue" ]

(* Build a case body covering every ctor except [missing]. *)
let cover_except missing =
  color_ctors
  |> List.filter (fun c -> c <> missing)
  |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
  |> String.concat "\n"

let m1_missing_ctor =
  List.mapi (fun i missing ->
    Printf.sprintf "M1 missing %s" missing,
    (fun () ->
       should_fail (Printf.sprintf "non-exhaustive case: missing constructor.*%s" missing)
         (Printf.sprintf {|
#lang tesl
module MMiss%d exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
%s
|} i color_adt (cover_except missing))))
    color_ctors

let test_M1_two_missing () =
  should_fail "non-exhaustive case: missing constructor"
    (Printf.sprintf {|
#lang tesl
module MMissTwo exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
    Red -> "r"
|} color_adt)

(* Larger ADT (5 nullary ctors): sweep omitting each one. *)
let day_adt = {|
type Day
  = Mon
  | Tue
  | Wed
  | Thu
  | Fri
|}
let day_ctors = [ "Mon"; "Tue"; "Wed"; "Thu"; "Fri" ]

let cover_days_except missing =
  day_ctors
  |> List.filter (fun c -> c <> missing)
  |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
  |> String.concat "\n"

let m1_day_missing =
  List.mapi (fun i missing ->
    Printf.sprintf "M1 Day missing %s" missing,
    (fun () ->
       should_fail (Printf.sprintf "non-exhaustive case: missing constructor.*%s" missing)
         (Printf.sprintf {|
#lang tesl
module MDay%d exposing []
import Tesl.Prelude exposing [String]
%s
fn f(d: Day) -> String =
  case d of
%s
|} i day_adt (cover_days_except missing))))
    day_ctors

let test_M1_exhaustive_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MExhPos exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
    Red -> "r"
    Green -> "g"
    Blue -> "b"
|} color_adt)

let test_M1_day_exhaustive_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MDayPos exposing []
import Tesl.Prelude exposing [String]
%s
fn f(d: Day) -> String =
  case d of
    Mon -> "m"
    Tue -> "t"
    Wed -> "w"
    Thu -> "th"
    Fri -> "f"
|} day_adt)

let test_M1_wildcard_catchall_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MWildPos exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
    Red -> "r"
    _ -> "other"
|} color_adt)

(* ── M2 — guarded-only arms ──────────────────────────────────────────────── *)
(* A constructor matched ONLY with a `where` guard, with no unguarded fallback,
   is non-total (if the guard fails at runtime there is no match). *)

let test_M2_single_guarded_only () =
  should_fail "only appear in guarded arms"
    (Printf.sprintf {|
#lang tesl
module MGuard1 exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
%s
fn f(s: Shape) -> String =
  case s of
    Circle r where r > 5 -> "big"
    Square _ -> "sq"
    Triangle _ _ -> "tri"
|} shape_adt)

let test_M2_all_guarded_only () =
  should_fail "only appear in guarded arms"
    (Printf.sprintf {|
#lang tesl
module MGuardAll exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
%s
fn f(s: Shape) -> String =
  case s of
    Circle r where r > 5 -> "bc"
    Square r where r > 5 -> "bs"
    Triangle a b where a > b -> "bt"
|} shape_adt)

(* Guarded-only sweep: each Color constructor matched only under a guard, with
   one other constructor as an unguarded fallback that does NOT cover it. *)
let m2_guarded_only_sweep =
  List.mapi (fun i guarded ->
    let others =
      color_ctors |> List.filter (fun c -> c <> guarded)
      |> List.map (fun c -> Printf.sprintf "    %s -> \"%s\"" c (String.lowercase_ascii c))
      |> String.concat "\n" in
    Printf.sprintf "M2 only-%s-guarded" guarded,
    (fun () ->
       should_fail (Printf.sprintf "only appear in guarded arms")
         (Printf.sprintf {|
#lang tesl
module MGuardSweep%d exposing []
import Tesl.Prelude exposing [String, Bool(..)]
%s
fn f(c: Color, flag: Bool) -> String =
  case c of
    %s where flag -> "guarded"
%s
|} i color_adt guarded others)))
    color_ctors

let test_M2_guard_with_unguarded_fallback_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MGuardOk exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
%s
fn f(s: Shape) -> String =
  case s of
    Circle r where r > 5 -> "big circle"
    Circle _ -> "small circle"
    Square _ -> "sq"
    Triangle _ _ -> "tri"
|} shape_adt)

(* ── M3 — literal patterns without a catch-all ────────────────────────────── *)

let test_M3_int_literals_no_catchall () =
  should_fail "literal patterns .* always require a catch-all"
    {|
#lang tesl
module MLitInt exposing []
import Tesl.Prelude exposing [String, Int]
fn f(n: Int) -> String =
  case n of
    0 -> "zero"
    1 -> "one"
    2 -> "two"
|}

let test_M3_string_literals_no_catchall () =
  should_fail "literal patterns .* always require a catch-all"
    {|
#lang tesl
module MLitStr exposing []
import Tesl.Prelude exposing [String]
fn f(s: String) -> String =
  case s of
    "yes" -> "y"
    "no" -> "n"
|}

let test_M3_int_literals_with_catchall_positive () =
  should_pass
    {|
#lang tesl
module MLitOk exposing []
import Tesl.Prelude exposing [String, Int]
fn f(n: Int) -> String =
  case n of
    0 -> "zero"
    1 -> "one"
    _ -> "many"
|}

(* ── M4 — duplicate / unreachable arms ────────────────────────────────────── *)

let test_M4_duplicate_constructor () =
  should_fail "duplicate case arm.*already covered\\|already covered"
    (Printf.sprintf {|
#lang tesl
module MDupCtor exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
    Red -> "r"
    Red -> "r2"
    Green -> "g"
    Blue -> "b"
|} color_adt)

let test_M4_duplicate_literal () =
  should_fail "duplicate case arm\\|already covered\\|already matched"
    {|
#lang tesl
module MDupLit exposing []
import Tesl.Prelude exposing [String, Int]
fn f(n: Int) -> String =
  case n of
    0 -> "z"
    0 -> "z2"
    _ -> "o"
|}

let test_M4_unreachable_after_catchall () =
  should_fail "unreachable case arm\\|catch-all"
    (Printf.sprintf {|
#lang tesl
module MUnreach exposing []
import Tesl.Prelude exposing [String]
%s
fn f(c: Color) -> String =
  case c of
    Red -> "r"
    _ -> "rest"
    Green -> "g"
|} color_adt)

(* ── M5 — wrong constructor arity ─────────────────────────────────────────── *)

let test_M5_nullary_pattern_on_fielded_ctor () =
  should_fail "expects 1 field but was used without any\\|expects .* field"
    (Printf.sprintf {|
#lang tesl
module MArity1 exposing []
import Tesl.Prelude exposing [String, Int]
%s
fn f(s: Shape) -> String =
  case s of
    Circle -> "c"
    Square _ -> "s"
    Triangle _ _ -> "t"
|} shape_adt)

let test_M5_triangle_too_few_fields () =
  should_fail "expects 2 field\\|expects .* field\\|nested constructor"
    (Printf.sprintf {|
#lang tesl
module MArity2 exposing []
import Tesl.Prelude exposing [String, Int]
%s
fn f(s: Shape) -> String =
  case s of
    Circle _ -> "c"
    Square _ -> "s"
    Triangle a -> "t"
|} shape_adt)

let test_M5_correct_arity_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MArityOk exposing []
import Tesl.Prelude exposing [String, Int]
%s
fn f(s: Shape) -> String =
  case s of
    Circle r -> "c"
    Square w -> "s"
    Triangle a b -> "t"
|} shape_adt)

(* ── M1b — Maybe exhaustiveness ───────────────────────────────────────────── *)

let test_M1b_maybe_missing_nothing () =
  should_fail "non-exhaustive case: missing constructor.*Nothing"
    {|
#lang tesl
module MMaybeN exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> String =
  case m of
    Something x -> "s"
|}

let test_M1b_maybe_missing_something () =
  should_fail "non-exhaustive case: missing constructor.*Something"
    {|
#lang tesl
module MMaybeS exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> String =
  case m of
    Nothing -> "n"
|}

let test_M1b_maybe_complete_positive () =
  should_pass
    {|
#lang tesl
module MMaybeOk exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> String =
  case m of
    Nothing -> "n"
    Something x -> "s"
|}

let test_M1b_maybe_nested_literal_incomplete () =
  should_fail "nested constructor/literal patterns leave uncovered values\\|non-exhaustive"
    {|
#lang tesl
module MMaybeLit exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> String =
  case m of
    Nothing -> "n"
    Something 0 -> "zero"
|}

let test_M1b_maybe_nested_literal_with_binder_positive () =
  should_pass
    {|
#lang tesl
module MMaybeLitOk exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> String =
  case m of
    Nothing -> "n"
    Something 0 -> "zero"
    Something _ -> "nonzero"
|}

(* ── M6 — nested non-exhaustive constructor patterns ──────────────────────── *)

let nested_setup = {|
import Tesl.Maybe exposing [Maybe(..)]
type Box
  = Wrapped (inner: Maybe Int)
  | Empty
|}

let test_M6_nested_missing_inner () =
  should_fail "nested constructor/literal patterns leave uncovered values\\|non-exhaustive"
    (Printf.sprintf {|
#lang tesl
module MNest1 exposing []
import Tesl.Prelude exposing [String, Int]
%s
fn f(b: Box) -> String =
  case b of
    Wrapped (Something n) -> "some"
    Empty -> "empty"
|} nested_setup)

let test_M6_nested_complete_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MNestOk exposing []
import Tesl.Prelude exposing [String, Int]
%s
fn f(b: Box) -> String =
  case b of
    Wrapped (Something n) -> "some"
    Wrapped Nothing -> "none"
    Empty -> "empty"
|} nested_setup)

(* ── M7 — proof-through-pattern ───────────────────────────────────────────── *)
(* A proof riding on an ADT field flows through `Something v` / `Right v` so the
   bound value satisfies a post-case proof requirement.  Modeled on
   example/learn/lesson52-maybe-proof.tesl. *)

let proof_tree_setup = {|
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
type PosTree
  = Leaf
  | Node (left: PosTree) (value: Int ::: IsPositive value) (right: PosTree)
fn needPositive(n: Int ::: IsPositive n) -> Int = n
|}

let test_M7_proof_through_maybe_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MProofMaybe exposing []
import Tesl.Prelude exposing [Int]
%s
fn findMax(t: PosTree) -> Maybe (Int ? IsPositive) =
  case t of
    Leaf -> Nothing
    Node _ cur Leaf -> Something cur
    Node _ _ r -> findMax r
fn consume(t: PosTree) -> Int =
  let m = findMax t
  case m of
    Nothing -> 0
    Something v -> needPositive v
|} proof_tree_setup)

let test_M7_proof_through_either_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module MProofEither exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Either exposing [Either(..)]
%s
fn findMin(t: PosTree) -> Either String (Int ? IsPositive) =
  case t of
    Leaf -> Left "none"
    Node Leaf cur _ -> Right cur
    Node l _ _ -> findMin l
fn consume(t: PosTree) -> Int =
  let m = findMin t
  case m of
    Left _ -> 0
    Right v -> needPositive v
|} proof_tree_setup)

let test_M7_no_proof_through_plain_maybe_negative () =
  (* A PLAIN Maybe Int (no proof on the field) cannot satisfy the post-case
     requirement — the bound value carries no proof. *)
  should_fail "does not statically satisfy declared proof.*IsPositive"
    (Printf.sprintf {|
#lang tesl
module MProofNeg exposing []
import Tesl.Prelude exposing [Int]
%s
fn consume(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something v -> needPositive v
|} proof_tree_setup)

let test_M7_partial_arm_loses_proof_negative () =
  (* One arm forwards the proven value, another arm forwards a RAW value to the
     same proof-requiring consumer — the raw arm must be rejected. *)
  should_fail "does not statically satisfy declared proof.*IsPositive"
    (Printf.sprintf {|
#lang tesl
module MProofPartial exposing []
import Tesl.Prelude exposing [Int]
%s
fn findMax(t: PosTree) -> Maybe (Int ? IsPositive) =
  case t of
    Leaf -> Nothing
    Node _ cur Leaf -> Something cur
    Node _ _ r -> findMax r
fn consume(t: PosTree, raw: Int) -> Int =
  let m = findMax t
  case m of
    Nothing -> needPositive raw
    Something v -> needPositive v
|} proof_tree_setup)

let test_M7_proof_through_into_divide_positive () =
  (* The proof extracted via a pattern discharges a DIVISION obligation
     downstream (cross-family flow). *)
  should_pass
    {|
#lang tesl
module MProofDiv exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide, IsNonZero]
import Tesl.Maybe exposing [Maybe(..)]
type NzTree
  = Leaf
  | Node (left: NzTree) (value: Int ::: IsNonZero value) (right: NzTree)
fn firstNz(t: NzTree) -> Maybe (Int ? IsNonZero) =
  case t of
    Leaf -> Nothing
    Node Leaf cur _ -> Something cur
    Node l _ _ -> firstNz l
fn divByFirst(t: NzTree, a: Int) -> Int =
  let m = firstNz t
  case m of
    Nothing -> 0
    Something d -> Int.divide a d
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let () =
  run "ProofSuite-M-Exhaustive" [
    "M1-missing-constructor", to_cases (m1_missing_ctor @ m1_day_missing @ [
      "M1 two missing", test_M1_two_missing;
      "M1 exhaustive (positive)", test_M1_exhaustive_positive;
      "M1 wildcard catch-all (positive)", test_M1_wildcard_catchall_positive;
      "M1 Day exhaustive (positive)", test_M1_day_exhaustive_positive;
    ]);
    "M1b-maybe-exhaustiveness", to_cases [
      "M1b Maybe missing Nothing", test_M1b_maybe_missing_nothing;
      "M1b Maybe missing Something", test_M1b_maybe_missing_something;
      "M1b Maybe complete (positive)", test_M1b_maybe_complete_positive;
      "M1b Maybe nested literal incomplete", test_M1b_maybe_nested_literal_incomplete;
      "M1b Maybe nested literal + binder (positive)", test_M1b_maybe_nested_literal_with_binder_positive;
    ];
    "M2-guarded-only-arms", to_cases (m2_guarded_only_sweep @ [
      "M2 single guarded-only", test_M2_single_guarded_only;
      "M2 all guarded-only", test_M2_all_guarded_only;
      "M2 guard + unguarded fallback (positive)", test_M2_guard_with_unguarded_fallback_positive;
    ]);
    "M3-literal-no-catchall", to_cases [
      "M3 Int literals no catch-all", test_M3_int_literals_no_catchall;
      "M3 String literals no catch-all", test_M3_string_literals_no_catchall;
      "M3 Int literals + catch-all (positive)", test_M3_int_literals_with_catchall_positive;
    ];
    "M4-duplicate-unreachable", to_cases [
      "M4 duplicate constructor", test_M4_duplicate_constructor;
      "M4 duplicate literal", test_M4_duplicate_literal;
      "M4 unreachable after catch-all", test_M4_unreachable_after_catchall;
    ];
    "M5-wrong-arity", to_cases [
      "M5 nullary pattern on fielded ctor", test_M5_nullary_pattern_on_fielded_ctor;
      "M5 triangle too few fields", test_M5_triangle_too_few_fields;
      "M5 correct arity (positive)", test_M5_correct_arity_positive;
    ];
    "M6-nested-non-exhaustive", to_cases [
      "M6 nested missing inner", test_M6_nested_missing_inner;
      "M6 nested complete (positive)", test_M6_nested_complete_positive;
    ];
    "M7-proof-through-pattern", to_cases [
      "M7 proof through Maybe (positive)", test_M7_proof_through_maybe_positive;
      "M7 proof through Either (positive)", test_M7_proof_through_either_positive;
      "M7 proof through into divide (positive)", test_M7_proof_through_into_divide_positive;
      "M7 no proof through plain Maybe (negative)", test_M7_no_proof_through_plain_maybe_negative;
      "M7 partial arm loses proof (negative)", test_M7_partial_arm_loses_proof_negative;
    ];
  ]
