(** ProofSuite family N — TOTAL-ARITHMETIC / division-safety obligations.

    Proves the STATIC checker enforces proof obligations on partial operations
    (no runtime net): `/` and `%` require `IsNonZero` on the divisor; literal
    `/ 0` is "division by zero"; `List.take/drop/repeat` require `IsNonNegative`
    on the count; `Dict.get` requires `HasKey`; `Float.div` requires
    `FloatNonZero`.  Positive companions show the satisfy-the-obligation idiom
    (`check Int.nonZero` → `Int.divide`, `check Dict.requireKey` → `Dict.get`,
    proof-carrying parameters).

    Hardening: [should_fail] additionally fails on any runtime-leak marker.

    Verified error strings (all `error[V001]:`):
      - "division by zero: the right operand of `/` is literally 0"
      - "the right operand of `/` (`b`) has no `IsNonZero` proof; division may crash at runtime"
      - "call to `Int.divide` argument `b` does not statically satisfy declared proof `IsNonZero b`"
      - "call to `List.take` argument `n` does not statically satisfy declared proof `IsNonNegative n`"
      - "call to `Dict.get` argument `dict` does not statically satisfy declared proof `HasKey key dict`"
      - "call to `Float.div` argument `b` does not statically satisfy declared proof `FloatNonZero b`"
      - "argument to `Int.divide` parameter `b` requires proof `IsNonZero b`, but the argument is a literal" *)

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
  let dir = Filename.temp_dir "tesl-psN" "" in
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

(* ── N0 — operator div/mod matrix: {/, %} × divisor-shape ─────────────────── *)
(* Sweep both arithmetic operators across several un-proven divisor shapes; each
   must be rejected with an IsNonZero / division-by-zero diagnostic. *)

type div_case = {
  dc_tag  : string;
  dc_expr : string;   (* the body expression, divisor unproven *)
  dc_pat  : string;
}

let div_shapes op = [
  { dc_tag = "param";   dc_expr = Printf.sprintf "a %s b" op;
    dc_pat = "has no .IsNonZero. proof\\|IsNonZero" };
  { dc_tag = "literal0"; dc_expr = Printf.sprintf "a %s 0" op;
    dc_pat = "division by zero\\|literally 0" };
  { dc_tag = "aliased"; dc_expr = Printf.sprintf "let d = b\n  a %s d" op;
    dc_pat = "has no .IsNonZero. proof\\|IsNonZero" };
  { dc_tag = "sumexpr"; dc_expr = Printf.sprintf "a %s (b + 1)" op;
    dc_pat = "no trackable .IsNonZero. proof\\|has no .IsNonZero. proof\\|IsNonZero" };
]

let div_matrix =
  List.concat_map (fun op ->
    let opname = if op = "/" then "Div" else "Mod" in
    List.map (fun dc ->
      Printf.sprintf "N0 %s/%s" opname dc.dc_tag,
      (fun () ->
         should_fail dc.dc_pat
           (Printf.sprintf {|
#lang tesl
module N0%s%s exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int, b: Int) -> Int =
  %s
|} opname (String.capitalize_ascii dc.dc_tag) dc.dc_expr)))
      (div_shapes op))
    [ "/"; "%" ]

(* ── N1 — operator division / modulo without IsNonZero ────────────────────── *)

let test_N1_div_variable_no_proof () =
  should_fail "has no .IsNonZero. proof\\|IsNonZero"
    {|
#lang tesl
module NDivVar exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int, b: Int) -> Int = a / b
|}

let test_N1_mod_variable_no_proof () =
  should_fail "has no .IsNonZero. proof\\|IsNonZero"
    {|
#lang tesl
module NModVar exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int, b: Int) -> Int = a % b
|}

let test_N1_div_literal_zero () =
  should_fail "division by zero"
    {|
#lang tesl
module NDivZero exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int) -> Int = a / 0
|}

let test_N1_mod_literal_zero () =
  should_fail "division by zero\\|operand of .%. is literally 0"
    {|
#lang tesl
module NModZero exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int) -> Int = a % 0
|}

let test_N1_div_nonzero_literal_positive () =
  (* A non-zero literal divisor is statically safe. *)
  should_pass
    {|
#lang tesl
module NDivLitOk exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int) -> Int = a / 42
|}

let test_N1_div_checked_positive () =
  should_pass
    {|
#lang tesl
module NDivCheckOk exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero]
fn f(a: Int, b: Int) -> Int =
  let safe = check Int.nonZero b
  a / safe
|}

let test_N1_div_proof_param_positive () =
  (* A divisor parameter carrying IsNonZero discharges the operator obligation. *)
  should_pass
    {|
#lang tesl
module NDivParamOk exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [IsNonZero]
fn f(a: Int, b: Int ::: IsNonZero b) -> Int = a / b
|}

(* ── N2 — Int.divide / Int.modulo named fns ───────────────────────────────── *)

let test_N2_int_divide_no_proof () =
  should_fail "does not statically satisfy declared proof.*IsNonZero\\|IsNonZero"
    {|
#lang tesl
module NIntDiv exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn f(a: Int, b: Int) -> Int =
  Int.divide a b
|}

let test_N2_int_divide_literal_arg () =
  (* Even a non-zero literal is rejected for a proof param (no auto-lift). *)
  should_fail "requires proof.*IsNonZero.*literal\\|does not statically satisfy.*IsNonZero\\|IsNonZero"
    {|
#lang tesl
module NIntDivLit exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn f(a: Int) -> Int =
  Int.divide a 5
|}

let test_N2_int_divide_checked_positive () =
  should_pass
    {|
#lang tesl
module NIntDivOk exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero, Int.divide]
fn f(a: Int, b: Int) -> Int =
  let d = check Int.nonZero b
  Int.divide a d
|}

(* ── N3 — List.take / List.drop without IsNonNegative ─────────────────────── *)

(* Sweep List ops needing IsNonNegative on the count. *)
type list_op = { lo_name : string; lo_call_raw : string; lo_call_ok : string }

let list_ops = [
  { lo_name = "List.take"; lo_call_raw = "List.take n xs"; lo_call_ok = "List.take safe xs" };
  { lo_name = "List.drop"; lo_call_raw = "List.drop n xs"; lo_call_ok = "List.drop safe xs" };
]

(* List.repeat takes the element first, the count second; the count needs the
   proof.  Handled separately because its call shape differs. *)
let test_N3_repeat_no_proof () =
  should_fail "does not statically satisfy declared proof.*IsNonNegative\\|IsNonNegative"
    {|
#lang tesl
module NRepeat exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.repeat]
fn f(x: Int, n: Int) -> List Int =
  List.repeat x n
|}

let test_N3_repeat_checked_positive () =
  should_pass
    {|
#lang tesl
module NRepeatOk exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.Int exposing [Int.nonNegative]
import Tesl.List exposing [List.repeat]
fn f(x: Int, n: Int) -> List Int =
  let safe = check Int.nonNegative n
  List.repeat x safe
|}

let n3_listop_no_proof =
  List.mapi (fun i o ->
    Printf.sprintf "N3 %s raw count" o.lo_name,
    (fun () ->
       should_fail "does not statically satisfy declared proof.*IsNonNegative\\|IsNonNegative"
         (Printf.sprintf {|
#lang tesl
module NList%d exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [%s]
fn f(xs: List Int, n: Int) -> List Int =
  %s
|} i o.lo_name o.lo_call_raw)))
    list_ops

let n3_listop_checked_positive =
  List.mapi (fun i o ->
    Printf.sprintf "N3 %s checked count (positive)" o.lo_name,
    (fun () ->
       should_pass
         (Printf.sprintf {|
#lang tesl
module NListOk%d exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.Int exposing [Int.nonNegative]
import Tesl.List exposing [%s]
fn f(xs: List Int, n: Int) -> List Int =
  let safe = check Int.nonNegative n
  %s
|} i o.lo_name o.lo_call_ok)))
    list_ops

let test_N3_take_literal_count () =
  (* A literal count is still rejected (no auto-lift). *)
  should_fail "does not statically satisfy.*IsNonNegative\\|requires proof.*IsNonNegative\\|IsNonNegative"
    {|
#lang tesl
module NTakeLit exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.take]
fn f(xs: List Int) -> List Int =
  List.take 3 xs
|}

let test_N3_proof_param_positive () =
  should_pass
    {|
#lang tesl
module NTakeParamOk exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.Int exposing [IsNonNegative]
import Tesl.List exposing [List.take]
fn f(xs: List Int, n: Int ::: IsNonNegative n) -> List Int =
  List.take n xs
|}

(* ── N4 — Dict.get without HasKey ─────────────────────────────────────────── *)

let test_N4_dict_get_no_proof () =
  should_fail "does not statically satisfy.*HasKey\\|HasKey"
    {|
#lang tesl
module NDictGet exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.get]
fn f(d: Dict String Int, key: String) -> Int =
  Dict.get key d
|}

let test_N4_dict_get_checked_positive () =
  should_pass
    {|
#lang tesl
module NDictGetOk exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.requireKey, Dict.get]
fn f(d: Dict String Int, key: String) -> Int =
  let checked = check Dict.requireKey key d
  Dict.get key checked
|}

let test_N4_dict_get_aliased_dict () =
  (* Re-binding the dict to a fresh name does not establish HasKey. *)
  should_fail "does not statically satisfy.*HasKey\\|HasKey"
    {|
#lang tesl
module NDictAlias exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.get]
fn f(d: Dict String Int, key: String) -> Int =
  let d2 = d
  Dict.get key d2
|}

let test_N4_dict_lookup_no_proof_needed_positive () =
  (* Dict.lookup is the unchecked Maybe-returning alternative — needs no proof. *)
  should_pass
    {|
#lang tesl
module NDictLookupOk exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Dict exposing [Dict, Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fn f(d: Dict String Int, key: String) -> Int =
  case Dict.lookup key d of
    Nothing -> 0
    Something v -> v
|}

(* ── N5 — Float.div without FloatNonZero ──────────────────────────────────── *)

let test_N5_float_div_no_proof () =
  should_fail "does not statically satisfy.*FloatNonZero\\|FloatNonZero"
    {|
#lang tesl
module NFloatDiv exposing []
import Tesl.Prelude exposing []
import Tesl.Float exposing [Float, Float.div]
fn f(a: Float, b: Float) -> Float =
  Float.div a b
|}

let test_N5_float_div_checked_positive () =
  should_pass
    {|
#lang tesl
module NFloatDivOk exposing []
import Tesl.Prelude exposing []
import Tesl.Float exposing [Float, FloatNonZero, Float.requireNonZero, Float.div]
fn f(a: Float, b: Float) -> Float =
  let safe = check Float.requireNonZero b
  Float.div a safe
|}

let test_N5_float_div_proof_param_positive () =
  should_pass
    {|
#lang tesl
module NFloatParamOk exposing []
import Tesl.Prelude exposing []
import Tesl.Float exposing [Float, FloatNonZero, Float.div]
fn f(a: Float, b: Float ::: FloatNonZero b) -> Float =
  Float.div a b
|}

(* ── N5b — named-fn proof-obligation matrix ───────────────────────────────── *)
(* One uniform sweep over every proof-gated stdlib fn: a raw call is rejected;
   a proof-carrying parameter discharges it. *)

type named_op = {
  no_id     : string;
  no_imp    : string;       (* imports *)
  no_fact   : string;       (* expected fact in the regex *)
  no_sig    : string;       (* fn signature line for the raw-call negative *)
  no_body   : string;       (* body for the raw-call negative *)
  no_psig   : string;       (* signature with proof-carrying param (positive) *)
  no_pbody  : string;       (* body for the positive *)
}

let named_ops = [
  { no_id = "IntDivide"; no_fact = "IsNonZero";
    no_imp = "import Tesl.Int exposing [Int.divide, IsNonZero]";
    no_sig = "fn f(a: Int, b: Int) -> Int"; no_body = "Int.divide a b";
    no_psig = "fn f(a: Int, b: Int ::: IsNonZero b) -> Int"; no_pbody = "Int.divide a b" };
  { no_id = "IntModulo"; no_fact = "IsNonZero";
    no_imp = "import Tesl.Int exposing [Int.modulo, IsNonZero]";
    no_sig = "fn f(a: Int, b: Int) -> Int"; no_body = "Int.modulo a b";
    no_psig = "fn f(a: Int, b: Int ::: IsNonZero b) -> Int"; no_pbody = "Int.modulo a b" };
  { no_id = "ListTake"; no_fact = "IsNonNegative";
    no_imp = "import Tesl.List exposing [List.take]\nimport Tesl.Int exposing [IsNonNegative]";
    no_sig = "fn f(xs: List Int, n: Int) -> List Int"; no_body = "List.take n xs";
    no_psig = "fn f(xs: List Int, n: Int ::: IsNonNegative n) -> List Int"; no_pbody = "List.take n xs" };
  { no_id = "ListDrop"; no_fact = "IsNonNegative";
    no_imp = "import Tesl.List exposing [List.drop]\nimport Tesl.Int exposing [IsNonNegative]";
    no_sig = "fn f(xs: List Int, n: Int) -> List Int"; no_body = "List.drop n xs";
    no_psig = "fn f(xs: List Int, n: Int ::: IsNonNegative n) -> List Int"; no_pbody = "List.drop n xs" };
]

let named_op_negatives =
  List.map (fun o ->
    Printf.sprintf "N5b %s raw arg" o.no_id,
    (fun () ->
       should_fail (Printf.sprintf "does not statically satisfy declared proof.*%s\\|%s" o.no_fact o.no_fact)
         (Printf.sprintf {|
#lang tesl
module N5b%s exposing []
import Tesl.Prelude exposing [Int, List]
%s
%s =
  %s
|} o.no_id o.no_imp o.no_sig o.no_body)))
    named_ops

let named_op_positives =
  List.map (fun o ->
    Printf.sprintf "N5b %s proof-param (positive)" o.no_id,
    (fun () ->
       should_pass
         (Printf.sprintf {|
#lang tesl
module N5bP%s exposing []
import Tesl.Prelude exposing [Int, List]
%s
%s =
  %s
|} o.no_id o.no_imp o.no_psig o.no_pbody)))
    named_ops

(* ── N6 — derived / aliased divisor still needs proof ─────────────────────── *)
(* Re-binding a raw value to a fresh name does not establish the proof; the
   subject is tracked through the let. *)

let test_N6_aliased_raw_divisor () =
  should_fail "has no .IsNonZero. proof\\|IsNonZero"
    {|
#lang tesl
module NAlias exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Int, b: Int) -> Int =
  let d = b
  a / d
|}

let test_N6_int_divide_aliased_raw () =
  should_fail "does not statically satisfy.*IsNonZero\\|IsNonZero"
    {|
#lang tesl
module NAlias2 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn f(a: Int, b: Int) -> Int =
  let d = b
  Int.divide a d
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let () =
  run "ProofSuite-N-Arith" [
    "N0-operator-div-mod-matrix", to_cases div_matrix;
    "N1-operator-division", to_cases [
      "N1 a/b no proof", test_N1_div_variable_no_proof;
      "N1 a%b no proof", test_N1_mod_variable_no_proof;
      "N1 a/0 literal zero", test_N1_div_literal_zero;
      "N1 a%0 literal zero", test_N1_mod_literal_zero;
      "N1 a/42 non-zero literal (positive)", test_N1_div_nonzero_literal_positive;
      "N1 a/checked (positive)", test_N1_div_checked_positive;
      "N1 a/proof-param (positive)", test_N1_div_proof_param_positive;
    ];
    "N2-int-divide", to_cases [
      "N2 Int.divide no proof", test_N2_int_divide_no_proof;
      "N2 Int.divide literal arg", test_N2_int_divide_literal_arg;
      "N2 Int.divide checked (positive)", test_N2_int_divide_checked_positive;
    ];
    "N3-list-take-drop-repeat", to_cases (n3_listop_no_proof @ n3_listop_checked_positive @ [
      "N3 take literal count", test_N3_take_literal_count;
      "N3 take proof-param (positive)", test_N3_proof_param_positive;
      "N3 repeat no proof", test_N3_repeat_no_proof;
      "N3 repeat checked (positive)", test_N3_repeat_checked_positive;
    ]);
    "N4-dict-get", to_cases [
      "N4 Dict.get no proof", test_N4_dict_get_no_proof;
      "N4 Dict.get checked (positive)", test_N4_dict_get_checked_positive;
      "N4 Dict.get aliased dict", test_N4_dict_get_aliased_dict;
      "N4 Dict.lookup no proof needed (positive)", test_N4_dict_lookup_no_proof_needed_positive;
    ];
    "N5-float-div", to_cases [
      "N5 Float.div no proof", test_N5_float_div_no_proof;
      "N5 Float.div checked (positive)", test_N5_float_div_checked_positive;
      "N5 Float.div proof-param (positive)", test_N5_float_div_proof_param_positive;
    ];
    "N5b-named-fn-obligation-matrix", to_cases (named_op_negatives @ named_op_positives);
    "N6-aliased-divisor", to_cases [
      "N6 aliased raw divisor (operator)", test_N6_aliased_raw_divisor;
      "N6 aliased raw divisor (Int.divide)", test_N6_int_divide_aliased_raw;
    ];
  ]
