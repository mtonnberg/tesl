(** Step-debugger Phase 0+1 compiler tests.

    Covers:
    1. --debug flag adds thsl-src wrappers to function bodies
    2. No --debug means no thsl-src wrappers
    3. Debug output includes the checkpoint require
    4. Debug output does NOT include checkpoint require in normal mode
    5. Correct file/line in thsl-src wrappers
    6. Multiple functions each get their own wrapper
    7. Debug mode is reset between calls (no cross-contamination)
    8. Works with FnKind, CheckKind, HandlerKind, WorkerKind, etc.
    9. thsl-src! function syntax (not the macro form)
    10. Lambda wrapper correctness: balanced parens
    11. Line number accuracy
    12. Test block instrumentation (TsLet)
    13. Normal mode has no debug output
    14. Edge cases: empty bodies, recursive fns, higher-order fns
*)

(* ── Helpers ─────────────────────────────────────────────────────────────────── *)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let stdlib =
  "import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]\n\
   import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]\n"

let module_ ?(name="M") ?(exports="") ?(extra="") body =
  Printf.sprintf "#lang tesl\nmodule %s exposing [%s]\n%s%s\n%s"
    name exports stdlib extra body

let compile_ok_debug name src =
  match Compile.compile_source ~root_path:root ~debug:true "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let compile_ok name src =
  match Compile.compile_source ~root_path:root "<test>" src with
  | Compile.Success racket -> racket
  | Compile.Failure diags ->
    Alcotest.failf "%s: unexpected compile failure: %s" name
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diags))

let contains needle haystack =
  let n = String.length needle in
  let m = String.length haystack in
  if n > m then false
  else begin
    let found = ref false in
    for i = 0 to m - n do
      if String.sub haystack i n = needle then found := true
    done;
    !found
  end

(* ── 1. thsl-src present when --debug ──────────────────────────────────────── *)

let test_debug_adds_thsl_src () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  let racket = compile_ok_debug "debug_adds_thsl_src" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_adds_thsl_src: expected thsl-src in output:\n%s" racket

(* ── 2. B5: ONE emission path — non-debug ALSO emits thsl-src ───────────────── *)
(* After B5 the emitter has a single path: thsl-src! is always emitted and the
   debug-vs-release choice is an expansion-time gate in checkpoint.rkt.  So the
   non-debug compile now ALSO contains thsl-src! (it erases to the bare body at
   raco-compile time when TESL_DEBUG is unset). *)
let test_no_debug_still_has_thsl_src () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  let racket = compile_ok "no_debug_still_has_thsl_src" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "no_debug_still_has_thsl_src: B5 — thsl-src! is now always emitted:\n%s" racket

(* ── 3. Debug output includes checkpoint require ────────────────────────────── *)

let test_debug_includes_checkpoint_require () =
  let src = module_ ~exports:"greet" {|
fn greet(name: String) -> String =
  "hello ${name}"
|} in
  let racket = compile_ok_debug "debug_includes_checkpoint" src in
  if not (contains "tesl/dsl/debug/checkpoint" racket) then
    Alcotest.failf "debug_includes_checkpoint: expected checkpoint require:\n%s" racket

(* ── 4. B5: normal mode ALSO includes the checkpoint require ────────────────── *)
(* The checkpoint require is unconditional now — checkpoint.rkt provides the
   expansion-time-gated thsl-src! macro (zero residue in release). *)
let test_normal_has_checkpoint_require () =
  let src = module_ ~exports:"greet" {|
fn greet(name: String) -> String =
  "hello ${name}"
|} in
  let racket = compile_ok "normal_has_checkpoint_require" src in
  if not (contains "tesl/dsl/debug/checkpoint" racket) then
    Alcotest.failf "normal_has_checkpoint_require: B5 — checkpoint require is now unconditional:\n%s" racket

(* ── 4b. B5: release and --debug emission are byte-identical (one path) ──────── *)
let test_release_equals_debug () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  let s = a + b
  s
|} in
  let release = compile_ok "release_equals_debug_rel" src in
  let debug   = compile_ok_debug "release_equals_debug_dbg" src in
  if not (String.equal release debug) then
    Alcotest.failf "release_equals_debug: B5 — `tesl` and `tesl --debug` must emit identical Racket.\nRELEASE:\n%s\nDEBUG:\n%s" release debug

(* ── 5. thsl-src contains the source file reference ─────────────────────────── *)

let test_debug_thsl_src_has_file_ref () =
  let src = module_ ~exports:"double" {|
fn double(x: Int) -> Int =
  x * 2
|} in
  let racket = compile_ok_debug "debug_thsl_src_file" src in
  (* The file is "<test>" — should appear quoted in the thsl-src call *)
  if not (contains "\"<test>\"" racket) then
    Alcotest.failf "debug_thsl_src_file: expected \"<test>\" in thsl-src output:\n%s" racket

(* ── 6. thsl-src contains a line number ─────────────────────────────────────── *)

let test_debug_thsl_src_has_line_number () =
  let src = module_ ~exports:"square" {|
fn square(n: Int) -> Int =
  n * n
|} in
  let racket = compile_ok_debug "debug_thsl_src_line" src in
  (* thsl-src takes (file line expr) — line should be a positive integer *)
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_thsl_src_line: expected thsl-src in debug output:\n%s" racket

(* ── 7. Multiple functions each get their own wrapper ────────────────────────── *)

let test_debug_multiple_functions () =
  let src = module_ ~exports:"add, mul" {|
fn add(a: Int, b: Int) -> Int =
  a + b

fn mul(a: Int, b: Int) -> Int =
  a * b
|} in
  let racket = compile_ok_debug "debug_multiple_fns" src in
  (* Count occurrences of thsl-src *)
  let count_occurrences needle s =
    let n = String.length needle in
    let m = String.length s in
    let count = ref 0 in
    for i = 0 to m - n do
      if String.sub s i n = needle then incr count
    done;
    !count
  in
  let count = count_occurrences "thsl-src" racket in
  if count < 2 then
    Alcotest.failf "debug_multiple_fns: expected at least 2 thsl-src wrappers, got %d in:\n%s" count racket

(* ── 8. B5: debug flag no longer changes emission (one path) ─────────────────── *)
(* set_debug_mode is now a no-op; both compiles emit identical Racket with
   thsl-src!.  This replaces the old "state leaks between calls" guard, which is
   moot once there is a single emission path. *)
let test_debug_flag_is_noop () =
  let src = module_ ~exports:"id" {|
fn id(x: Int) -> Int =
  x
|} in
  let r1 = compile_ok_debug "debug_noop_1" src in
  let r2 = compile_ok "debug_noop_2" src in
  if not (String.equal r1 r2) then
    Alcotest.failf "debug_flag_is_noop: B5 — debug and non-debug emission must match:\nDEBUG:\n%s\nRELEASE:\n%s" r1 r2

(* ── 9. FnKind function gets thsl-src wrapper ──────────────────────────────── *)

let test_debug_fn_kind () =
  let src = module_ ~exports:"neg" {|
fn neg(x: Int) -> Int =
  0 - x
|} in
  let racket = compile_ok_debug "debug_fn_kind" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_fn_kind: expected thsl-src:\n%s" racket

(* ── 10. String literal body gets thsl-src wrapper ─────────────────────────── *)

let test_debug_string_literal_body () =
  let src = module_ ~exports:"hello" {|
fn hello() -> String =
  "world"
|} in
  let racket = compile_ok_debug "debug_string_literal" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_string_literal: expected thsl-src:\n%s" racket

(* ── 11. Int literal body gets thsl-src wrapper ─────────────────────────────── *)

let test_debug_int_literal_body () =
  let src = module_ ~exports:"answer" {|
fn answer() -> Int =
  42
|} in
  let racket = compile_ok_debug "debug_int_literal" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_int_literal: expected thsl-src:\n%s" racket

(* ── 12. Bool conditional body gets thsl-src wrapper ────────────────────────── *)

let test_debug_bool_literal_body () =
  let src = module_ ~exports:"isPositive" {|
fn isPositive(x: Int) -> Bool =
  if x > 0 then
    True
  else
    False
|} in
  let racket = compile_ok_debug "debug_bool_literal" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_bool_literal: expected thsl-src:\n%s" racket

(* ── 13. If/then/else body gets thsl-src wrapper ────────────────────────────── *)

let test_debug_if_body () =
  let src = module_ ~exports:"clamp" {|
fn clamp(x: Int) -> Int =
  if x > 100 then
    100
  else
    x
|} in
  let racket = compile_ok_debug "debug_if_body" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_if_body: expected thsl-src:\n%s" racket

(* ── 14. Let-binding body gets thsl-src wrapper ─────────────────────────────── *)

let test_debug_let_body () =
  let src = module_ ~exports:"compute" {|
fn compute(x: Int) -> Int =
  let y = x + 1
  y * 2
|} in
  let racket = compile_ok_debug "debug_let_body" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_let_body: expected thsl-src:\n%s" racket

(* ── 15. Function with case gets thsl-src wrapper ───────────────────────────── *)

let test_debug_case_body () =
  let src = module_ ~exports:"describe" ~extra:"type Color\n  = Red\n  | Blue\n" {|
fn describe(c: Color) -> String =
  case c of
    Red -> "red"
    Blue -> "blue"
|} in
  let racket = compile_ok_debug "debug_case_body" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_case_body: expected thsl-src:\n%s" racket

(* ── 16. Debug output is valid enough to contain define/pow ─────────────────── *)

let test_debug_output_has_define_pow () =
  let src = module_ ~exports:"succ" {|
fn succ(n: Int) -> Int =
  n + 1
|} in
  let racket = compile_ok_debug "debug_has_define_pow" src in
  if not (contains "define/pow" racket) then
    Alcotest.failf "debug_has_define_pow: expected define/pow in output:\n%s" racket

(* ── 17. Normal output still correct — define/pow present (now WITH thsl-src) ── *)

let test_normal_output_correct () =
  let src = module_ ~exports:"succ" {|
fn succ(n: Int) -> Int =
  n + 1
|} in
  let racket = compile_ok "normal_output_correct" src in
  if not (contains "define/pow" racket) then
    Alcotest.failf "normal_output_correct: expected define/pow:\n%s" racket;
  (* B5: thsl-src! is now present in normal output too (erased at raco-compile). *)
  if not (contains "thsl-src" racket) then
    Alcotest.failf "normal_output_correct: B5 — expected thsl-src in normal output:\n%s" racket

(* ── 18. Debug checkpoint require appears exactly once ───────────────────────── *)

let test_debug_require_appears_once () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  let racket = compile_ok_debug "debug_require_once" src in
  let count_occurrences needle s =
    let n = String.length needle in
    let m = String.length s in
    let count = ref 0 in
    for i = 0 to m - n do
      if String.sub s i n = needle then incr count
    done;
    !count
  in
  let count = count_occurrences "tesl/dsl/debug/checkpoint" racket in
  if count <> 1 then
    Alcotest.failf "debug_require_once: expected exactly 1 checkpoint require, got %d:\n%s" count racket

(* ── 19. thsl-src! wrapper has the form (thsl-src! "..." N (lambda () ...)) ── *)

let test_debug_thsl_src_form () =
  let src = module_ ~exports:"abs" {|
fn abs(x: Int) -> Int =
  if x < 0 then
    0 - x
  else
    x
|} in
  let racket = compile_ok_debug "debug_thsl_src_form" src in
  (* Look for the function form "(thsl-src! " — the compiler uses thsl-src! not thsl-src *)
  if not (contains "(thsl-src! \"" racket) then
    Alcotest.failf "debug_thsl_src_form: expected (thsl-src! \"...\" in output:\n%s" racket

(* ── 20. B5: two successive non-debug compiles both CONTAIN thsl-src ─────────── *)

let test_two_non_debug_compiles () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let r1 = compile_ok "two_non_debug_1" src in
  let r2 = compile_ok "two_non_debug_2" src in
  if not (contains "thsl-src" r1) then
    Alcotest.failf "two_non_debug_1: B5 — expected thsl-src:\n%s" r1;
  if not (String.equal r1 r2) then
    Alcotest.failf "two_non_debug: emission must be deterministic across calls"

(* ── 21. B5: debug and non-debug compiles all produce identical output ───────── *)

let test_alternating_debug_mode () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x + 1
|} in
  let rd = compile_ok_debug "alternating_debug" src in
  let rn = compile_ok "alternating_normal" src in
  let rd2 = compile_ok_debug "alternating_debug_2" src in
  let rn2 = compile_ok "alternating_normal_2" src in
  List.iter (fun (label, r) ->
    if not (contains "thsl-src" r) then
      Alcotest.failf "%s: B5 — expected thsl-src:\n%s" label r)
    ["alternating_debug", rd; "alternating_normal", rn;
     "alternating_debug_2", rd2; "alternating_normal_2", rn2];
  if not (String.equal rd rn && String.equal rn rd2 && String.equal rd2 rn2) then
    Alcotest.fail "alternating: B5 — debug and non-debug emission must all be identical"

(* ── 22. Single-param function debug wrapper ─────────────────────────────────── *)

let test_debug_single_param_fn () =
  let src = module_ ~exports:"inc" {|
fn inc(n: Int) -> Int =
  n + 1
|} in
  let racket = compile_ok_debug "debug_single_param" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_single_param: expected thsl-src:\n%s" racket

(* ── 23. Zero-param function debug wrapper ───────────────────────────────────── *)

let test_debug_zero_param_fn () =
  let src = module_ ~exports:"constant" {|
fn constant() -> Int =
  99
|} in
  let racket = compile_ok_debug "debug_zero_param" src in
  if not (contains "thsl-src" racket) then
    Alcotest.failf "debug_zero_param: expected thsl-src:\n%s" racket

(* ── 24. Debug thsl-src wrapper is properly closed ──────────────────────────── *)

let test_debug_wrapper_properly_closed () =
  let src = module_ ~exports:"triple" {|
fn triple(x: Int) -> Int =
  x * 3
|} in
  let racket = compile_ok_debug "debug_wrapper_closed" src in
  (* The output should be syntactically balanced — a simple heuristic:
     count opening and closing parens *)
  let open_count = String.fold_left (fun acc c -> if c = '(' then acc + 1 else acc) 0 racket in
  let close_count = String.fold_left (fun acc c -> if c = ')' then acc + 1 else acc) 0 racket in
  if open_count <> close_count then
    Alcotest.failf "debug_wrapper_closed: unbalanced parens (open=%d, close=%d) in:\n%s"
      open_count close_count racket

(* ── 25. Type declaration: compiles fine in debug mode ───────────────────────── *)

let test_debug_const_no_wrapper () =
  let src = module_ ~exports:"Status, getDefault" {|
type Status
  = Active
  | Inactive

fn getDefault() -> Status =
  Active
|} in
  let racket = compile_ok_debug "debug_type_decl_ok" src in
  (* Type declarations do not go through emit_func, only functions do. *)
  if not (contains "Status" racket) then
    Alcotest.failf "debug_type_decl_ok: expected Status in output:\n%s" racket

(* ══════════════════════════════════════════════════════════════════════════════
   NEW EXPANDED TESTS
   ══════════════════════════════════════════════════════════════════════════════ *)

(* ── Additional helpers ──────────────────────────────────────────────────────── *)

let count_occurrences needle s =
  let n = String.length needle in
  let m = String.length s in
  let count = ref 0 in
  for i = 0 to m - n do
    if String.sub s i n = needle then incr count
  done;
  !count

let assert_contains name pattern racket =
  if not (contains pattern racket) then
    Alcotest.failf "%s: expected to find %S in output:\n%s" name pattern racket

let assert_not_contains name pattern racket =
  if contains pattern racket then
    Alcotest.failf "%s: expected NOT to find %S in output:\n%s" name pattern racket

let assert_balanced_parens name racket =
  let opens  = String.fold_left (fun n c -> if c = '(' then n+1 else n) 0 racket in
  let closes = String.fold_left (fun n c -> if c = ')' then n+1 else n) 0 racket in
  if opens <> closes then
    Alcotest.failf "%s: unbalanced parens in debug output: %d opens, %d closes" name opens closes

let assert_line_in_debug name line_num racket =
  let pattern = Printf.sprintf "thsl-src! \"<test>\" %d" line_num in
  if not (contains pattern racket) then
    Alcotest.failf "%s: expected thsl-src! at line %d in:\n%s" name line_num racket

(* ── Group 1: thsl-src! function syntax ─────────────────────────────────────── *)

(* G1.1 thsl-src! (with !) appears in debug output *)
let test_g1_thsl_src_bang_present () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  let racket = compile_ok_debug "g1_thsl_src_bang" src in
  assert_contains "g1_thsl_src_bang" "thsl-src!" racket

(* G1.2 Bare thsl-src (macro form) does NOT appear as standalone call -
   the compiler must use the function form thsl-src! *)
let test_g1_macro_form_not_used () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b
|} in
  let racket = compile_ok_debug "g1_macro_form" src in
  (* thsl-src! is fine; what we must NOT see is "(thsl-src " without the bang *)
  assert_not_contains "g1_macro_form" "(thsl-src \"" racket

(* G1.3 Output contains (lambda () ...) wrapper inside thsl-src! *)
let test_g1_lambda_wrapper_present () =
  let src = module_ ~exports:"greet" {|
fn greet(name: String) -> String =
  "hello ${name}"
|} in
  let racket = compile_ok_debug "g1_lambda_wrapper" src in
  assert_contains "g1_lambda_wrapper" "(lambda ()" racket

(* G1.4 File path "<test>" appears quoted in thsl-src! call *)
let test_g1_file_path_quoted () =
  let src = module_ ~exports:"id" {|
fn id(x: Int) -> Int =
  x
|} in
  let racket = compile_ok_debug "g1_file_path" src in
  assert_contains "g1_file_path" "thsl-src! \"<test>\"" racket

(* G1.5 Line number is a positive integer after the file path *)
let test_g1_line_number_positive () =
  let src = module_ ~exports:"double" {|
fn double(x: Int) -> Int =
  x * 2
|} in
  let racket = compile_ok_debug "g1_line_number" src in
  (* pattern: thsl-src! "<test>" <digits> *)
  let re = Str.regexp {|thsl-src! "<test>" [0-9]+|} in
  (try ignore (Str.search_forward re racket 0)
   with Not_found ->
     Alcotest.failf "g1_line_number: no thsl-src! with numeric line in:\n%s" racket)

(* G1.6 Each let binding in a function body gets its own thsl-src! *)
let test_g1_each_let_gets_wrapper () =
  let src = module_ ~exports:"compute" {|
fn compute(x: Int) -> Int =
  let a = x + 1
  let b = a * 2
  let c = b - 3
  c
|} in
  let racket = compile_ok_debug "g1_each_let" src in
  let count = count_occurrences "thsl-src!" racket in
  if count < 3 then
    Alcotest.failf "g1_each_let: expected at least 3 thsl-src! (one per let + terminal), got %d in:\n%s" count racket

(* G1.7 The terminal expression of a function body also gets thsl-src! *)
let test_g1_terminal_expr_wrapped () =
  let src = module_ ~exports:"answer" {|
fn answer() -> Int =
  42
|} in
  let racket = compile_ok_debug "g1_terminal" src in
  (* This function has no lets — only a terminal expression *)
  assert_contains "g1_terminal" "thsl-src!" racket

(* G1.8 tesl/dsl/debug/checkpoint is required in debug output *)
let test_g1_require_checkpoint () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let racket = compile_ok_debug "g1_require" src in
  assert_contains "g1_require" "tesl/dsl/debug/checkpoint" racket

(* G1.9 B5: tesl/dsl/debug/checkpoint IS in normal output (unconditional require) *)
let test_g1_checkpoint_in_normal () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let racket = compile_ok "g1_checkpoint_normal" src in
  assert_contains "g1_checkpoint_normal" "tesl/dsl/debug/checkpoint" racket

(* G1.10 thsl-src! wraps are inside function bodies, not at top level —
   the require appears at module top level, thsl-src! wraps are inside define/pow *)
let test_g1_wraps_inside_function () =
  let src = module_ ~exports:"succ" {|
fn succ(n: Int) -> Int =
  n + 1
|} in
  let racket = compile_ok_debug "g1_inside_fn" src in
  (* define/pow should precede any thsl-src! in the output *)
  let def_pos =
    try Str.search_forward (Str.regexp "define/pow") racket 0
    with Not_found -> Alcotest.failf "g1_inside_fn: no define/pow in:\n%s" racket
  in
  let wrap_pos =
    try Str.search_forward (Str.regexp "thsl-src!") racket 0
    with Not_found -> Alcotest.failf "g1_inside_fn: no thsl-src! in:\n%s" racket
  in
  if wrap_pos <= def_pos then
    Alcotest.failf "g1_inside_fn: thsl-src! appears before define/pow (pos %d vs %d) in:\n%s"
      wrap_pos def_pos racket

(* G1.11 One-liner function (single expression, no lets) gets thsl-src! on terminal *)
let test_g1_oneliner_fn () =
  let src = module_ ~exports:"pi" {|
fn pi() -> Int =
  3
|} in
  let racket = compile_ok_debug "g1_oneliner" src in
  assert_contains "g1_oneliner" "thsl-src!" racket

(* G1.12 Function with 3+ let bindings: each binding gets its own wrapper *)
let test_g1_three_lets () =
  let src = module_ ~exports:"calc" {|
fn calc(x: Int) -> Int =
  let a = x + 10
  let b = a - 5
  let c = b * 3
  c + 1
|} in
  let racket = compile_ok_debug "g1_three_lets" src in
  let count = count_occurrences "thsl-src!" racket in
  (* 3 lets + 1 terminal = at least 4 *)
  if count < 4 then
    Alcotest.failf "g1_three_lets: expected at least 4 thsl-src! wrappers, got %d in:\n%s" count racket

(* G1.13 check function gets thsl-src! *)
let test_g1_check_kind () =
  let src = module_ ~exports:"isPos" ~extra:"fact Positive (n: Int)\n" {|
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"
|} in
  let racket = compile_ok_debug "g1_check_kind" src in
  assert_contains "g1_check_kind" "thsl-src!" racket

(* G1.14 auth function gets thsl-src! *)
let test_g1_auth_kind () =
  let src = module_ ~exports:"myAuth"
    ~extra:"import Tesl.Http exposing [HttpRequest]\nfact Authenticated (u: String)\n" {|
auth myAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  ok "admin" ::: Authenticated user
|} in
  let racket = compile_ok_debug "g1_auth_kind" src in
  assert_contains "g1_auth_kind" "thsl-src!" racket

(* G1.15 handler function gets thsl-src! *)
let test_g1_handler_kind () =
  let src = module_ ~exports:"ping" {|
handler ping() -> Int
  requires [] =
  42
|} in
  let racket = compile_ok_debug "g1_handler_kind" src in
  assert_contains "g1_handler_kind" "thsl-src!" racket

(* G1.16 establish function gets thsl-src! *)
let test_g1_establish_kind () =
  let src = module_ ~exports:"provePositive" ~extra:"fact Positive (n: Int)\n" {|
establish provePositive(n: Int) -> Fact (Positive n) =
  Positive n
|} in
  let racket = compile_ok_debug "g1_establish_kind" src in
  assert_contains "g1_establish_kind" "thsl-src!" racket

(* ── Group 2: Lambda wrapper correctness (balanced parens) ──────────────────── *)

(* G2.1 Single let function: parens balanced *)
let test_g2_single_let_balanced () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  let y = x + 1
  y
|} in
  let racket = compile_ok_debug "g2_single_let" src in
  assert_balanced_parens "g2_single_let" racket

(* G2.2 Multi-let function: parens balanced *)
let test_g2_multi_let_balanced () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  let a = x + 1
  let b = a + 2
  let c = b + 3
  c
|} in
  let racket = compile_ok_debug "g2_multi_let" src in
  assert_balanced_parens "g2_multi_let" racket

(* G2.3 Function with case expression: parens balanced *)
let test_g2_case_balanced () =
  let src = module_ ~exports:"desc" ~extra:"type Color\n  = Red\n  | Blue\n" {|
fn desc(c: Color) -> String =
  case c of
    Red -> "red"
    Blue -> "blue"
|} in
  let racket = compile_ok_debug "g2_case" src in
  assert_balanced_parens "g2_case" racket

(* G2.4 Function with if expression: parens balanced *)
let test_g2_if_balanced () =
  let src = module_ ~exports:"abs_" {|
fn abs_(x: Int) -> Int =
  if x < 0 then
    0 - x
  else
    x
|} in
  let racket = compile_ok_debug "g2_if" src in
  assert_balanced_parens "g2_if" racket

(* G2.5 Function with nested lets: parens balanced *)
let test_g2_nested_lets_balanced () =
  let src = module_ ~exports:"complex" {|
fn complex(x: Int) -> Int =
  let a = x * 2
  let b = a + a
  b - 1
|} in
  let racket = compile_ok_debug "g2_nested_lets" src in
  assert_balanced_parens "g2_nested_lets" racket

(* G2.6 check function with proof: parens balanced *)
let test_g2_check_proof_balanced () =
  let src = module_ ~exports:"isPos" ~extra:"fact Positive (n: Int)\n" {|
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "not positive"
|} in
  let racket = compile_ok_debug "g2_check_proof" src in
  assert_balanced_parens "g2_check_proof" racket

(* G2.7 Test block with let: parens balanced *)
let test_g2_test_block_balanced () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b

test "add works" {
  let x = add 2 3
  expect x == 5
}
|} in
  let racket = compile_ok_debug "g2_test_block" src in
  assert_balanced_parens "g2_test_block" racket

(* G2.8 Complex example with 5+ lets: parens balanced *)
let test_g2_complex_balanced () =
  let src = module_ ~exports:"big" {|
fn big(x: Int) -> Int =
  let a = x + 1
  let b = a + 2
  let c = b + 3
  let d = c + 4
  let e = d + 5
  e
|} in
  let racket = compile_ok_debug "g2_complex" src in
  assert_balanced_parens "g2_complex" racket

(* G2.9 Function whose body is just a variable reference: parens balanced *)
let test_g2_var_ref_balanced () =
  let src = module_ ~exports:"id" {|
fn id(x: Int) -> Int =
  x
|} in
  let racket = compile_ok_debug "g2_var_ref" src in
  assert_balanced_parens "g2_var_ref" racket

(* G2.10 Function whose body is a string literal: parens balanced *)
let test_g2_string_literal_balanced () =
  let src = module_ ~exports:"hello" {|
fn hello() -> String =
  "world"
|} in
  let racket = compile_ok_debug "g2_string_literal" src in
  assert_balanced_parens "g2_string_literal" racket

(* G2.11 If expression with let in each branch: parens balanced *)
let test_g2_if_with_lets_balanced () =
  let src = module_ ~exports:"clamp" {|
fn clamp(x: Int) -> Int =
  let hi = 100
  let lo = 0
  if x > hi then
    hi
  else if x < lo then
    lo
  else
    x
|} in
  let racket = compile_ok_debug "g2_if_with_lets" src in
  assert_balanced_parens "g2_if_with_lets" racket

(* ── Group 3: Line number accuracy ──────────────────────────────────────────── *)

(* The module_ helper prepends 3 lines of boilerplate:
   line 1: #lang tesl
   line 2: module M exposing [...]
   line 3: import Tesl.Prelude ...
   line 4: import Tesl.Json ...
   line 5: (blank line from module_ format string)
   Then the body starts. We test using a carefully counted snippet. *)

(* G3.1 Line numbers are 1-based (not 0-based) — thsl-src! never emits line 0 *)
let test_g3_no_line_zero () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x + 1
|} in
  let racket = compile_ok_debug "g3_no_line_zero" src in
  assert_not_contains "g3_no_line_zero" "thsl-src! \"<test>\" 0" racket

(* G3.2 Verify that the line number for a one-liner fn body is > 0 *)
let test_g3_line_positive () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let racket = compile_ok_debug "g3_line_positive" src in
  (* Extract the first line number from any thsl-src! occurrence *)
  let re = Str.regexp {|thsl-src! "<test>" \([0-9]+\)|} in
  (try
    ignore (Str.search_forward re racket 0);
    let n = int_of_string (Str.matched_group 1 racket) in
    if n <= 0 then
      Alcotest.failf "g3_line_positive: line number %d is not positive in:\n%s" n racket
   with Not_found ->
     Alcotest.failf "g3_line_positive: no thsl-src! with line number in:\n%s" racket)

(* G3.3 Two functions in file: second function has larger line numbers than first *)
let test_g3_second_fn_larger_lines () =
  let src = module_ ~exports:"f, g" {|
fn f(x: Int) -> Int =
  x

fn g(x: Int) -> Int =
  x + 10
|} in
  let racket = compile_ok_debug "g3_two_fns_lines" src in
  (* Collect all line numbers *)
  let re = Str.regexp {|thsl-src! "<test>" \([0-9]+\)|} in
  let nums = ref [] in
  let pos = ref 0 in
  (try while true do
    pos := Str.search_forward re racket !pos;
    nums := int_of_string (Str.matched_group 1 racket) :: !nums;
    pos := !pos + 1
  done with Not_found -> ());
  let nums = List.rev !nums in
  (match nums with
   | [] -> Alcotest.failf "g3_two_fns_lines: no thsl-src! found in:\n%s" racket
   | [_] -> Alcotest.failf "g3_two_fns_lines: only 1 thsl-src! found, expected >=2 in:\n%s" racket
   | first :: rest ->
     let last = List.nth rest (List.length rest - 1) in
     if last <= first then
       Alcotest.failf "g3_two_fns_lines: expected last line (%d) > first line (%d) in:\n%s"
         last first racket)

(* G3.4 Multi-let function: let bindings get increasing line numbers *)
let test_g3_lets_have_increasing_lines () =
  (* Build a snippet where line numbers are deterministic:
     stdlib is 2 lines, module decl is 1 line, so body starts around line 5.
     We use the raw string so we control exact content. *)
  let src = {|#lang tesl
module M exposing [calc]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]

fn calc(x: Int) -> Int =
  let a = x + 1
  let b = a + 2
  b
|} in
  let racket = compile_ok_debug "g3_lets_increasing" src in
  let re = Str.regexp {|thsl-src! "<test>" \([0-9]+\)|} in
  let nums = ref [] in
  let pos = ref 0 in
  (try while true do
    pos := Str.search_forward re racket !pos;
    nums := int_of_string (Str.matched_group 1 racket) :: !nums;
    pos := !pos + 1
  done with Not_found -> ());
  let nums = List.rev !nums in
  (* line numbers should be distinct and sorted *)
  let sorted = List.sort_uniq compare nums in
  if sorted <> nums then
    Alcotest.failf "g3_lets_increasing: line numbers %s are not strictly increasing in:\n%s"
      (String.concat ", " (List.map string_of_int nums)) racket

(* G3.5 Exact line for a known snippet: fn body at line 7 -> thsl-src! has line 7 *)
let test_g3_exact_line_terminal () =
  (* Carefully crafted: count lines manually.
     Line 1: #lang tesl
     Line 2: module M exposing [f]
     Line 3: import Tesl.Prelude exposing [...]
     Line 4: import Tesl.Json exposing [...]
     Line 5: (blank)
     Line 6: fn f(x: Int) -> Int =
     Line 7:   x + 1
  *)
  let src = {|#lang tesl
module M exposing [f]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]

fn f(x: Int) -> Int =
  x + 1
|} in
  let racket = compile_ok_debug "g3_exact_line" src in
  assert_line_in_debug "g3_exact_line" 7 racket

(* G3.6 First let binding at line 7, second at line 8 *)
let test_g3_exact_lines_lets () =
  let src = {|#lang tesl
module M exposing [g]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]

fn g(x: Int) -> Int =
  let a = x + 1
  let b = a + 2
  b
|} in
  let racket = compile_ok_debug "g3_exact_lets" src in
  assert_line_in_debug "g3_exact_lets" 7 racket;
  assert_line_in_debug "g3_exact_lets" 8 racket

(* G3.7 Line numbers not 0-based: the first line of a file is line 1 *)
let test_g3_first_line_is_one () =
  let src = {|#lang tesl
module M exposing [h]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]

fn h(x: Int) -> Int =
  x
|} in
  let racket = compile_ok_debug "g3_first_line_one" src in
  (* Line 7 is where the body "x" lives; 0-based would give 6 *)
  assert_line_in_debug "g3_first_line_one" 7 racket;
  assert_not_contains "g3_first_line_one" "thsl-src! \"<test>\" 6" racket

(* G3.8 A function on line 10 in a two-function file gets correct lines *)
let test_g3_second_fn_exact_lines () =
  let src = {|#lang tesl
module M exposing [f, g]
import Tesl.Prelude exposing [Int, String, Bool, List, Fact, detachFact]
import Tesl.Json exposing [stringCodec, intCodec, boolCodec, floatCodec, posixMillisCodec]

fn f(x: Int) -> Int =
  x

fn g(x: Int) -> Int =
  x + 99
|} in
  let racket = compile_ok_debug "g3_second_fn_exact" src in
  assert_line_in_debug "g3_second_fn_exact" 7 racket;
  assert_line_in_debug "g3_second_fn_exact" 10 racket

(* ── Group 4: Test block instrumentation (TsLet) ────────────────────────────── *)

(* G4.1 let inside a test block gets thsl-src! wrapper in debug mode *)
let test_g4_test_let_wrapped () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b

test "addition" {
  let x = add 2 3
  expect x == 5
}
|} in
  let racket = compile_ok_debug "g4_test_let" src in
  assert_contains "g4_test_let" "thsl-src!" racket

(* G4.2 B5: let inside a test block ALSO gets a thsl-src! wrapper in normal mode *)
let test_g4_test_let_wrapper_normal () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b

test "addition" {
  let x = add 2 3
  expect x == 5
}
|} in
  let racket = compile_ok "g4_test_let_normal" src in
  assert_contains "g4_test_let_normal" "thsl-src!" racket

(* G4.3 Multiple lets in test block: each wrapped in debug mode *)
let test_g4_multiple_test_lets_wrapped () =
  let src = module_ ~exports:"add, mul" {|
fn add(a: Int, b: Int) -> Int =
  a + b

fn mul(a: Int, b: Int) -> Int =
  a * b

test "ops" {
  let sum = add 2 3
  let product = mul 2 3
  expect sum == 5
  expect product == 6
}
|} in
  let racket = compile_ok_debug "g4_multi_test_lets" src in
  let count = count_occurrences "thsl-src!" racket in
  (* at least 2 thsl-src! for the test lets, plus 2 for fn bodies *)
  if count < 4 then
    Alcotest.failf "g4_multi_test_lets: expected at least 4 thsl-src! wrappers, got %d in:\n%s" count racket

(* G4.4 test block without lets still compiles fine with --debug *)
let test_g4_test_block_no_let () =
  let src = module_ ~exports:"add" {|
fn add(a: Int, b: Int) -> Int =
  a + b

test "inline" {
  expect add 1 2 == 3
}
|} in
  let racket = compile_ok_debug "g4_no_let_test" src in
  (* Should still have thsl-src! from the function body *)
  assert_contains "g4_no_let_test" "thsl-src!" racket

(* G4.5 test block instrumentation: balanced parens *)
let test_g4_test_block_parens_balanced () =
  let src = module_ ~exports:"sub" {|
fn sub(a: Int, b: Int) -> Int =
  a - b

test "subtraction" {
  let result = sub 10 3
  expect result == 7
}
|} in
  let racket = compile_ok_debug "g4_test_balanced" src in
  assert_balanced_parens "g4_test_balanced" racket

(* ── Group 5: B5 — ONE emission path (normal mode carries the same forms) ────── *)
(* The whole group was inverted by B5: where it used to assert that normal mode
   has NO debug output, it now asserts normal mode carries the same thsl-src! /
   checkpoint forms (which the macro erases at raco-compile time). *)

(* G5.1 Normal compile output CONTAINS thsl-src! *)
let test_g5_has_thsl_src_bang () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x + 1
|} in
  let racket = compile_ok "g5_bang" src in
  assert_contains "g5_bang" "thsl-src!" racket

(* G5.2 Normal compile output CONTAINS thsl-src *)
let test_g5_has_thsl_src_any_form () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x + 1
|} in
  let racket = compile_ok "g5_any_form" src in
  assert_contains "g5_any_form" "thsl-src" racket

(* G5.3 Normal compile output CONTAINS tesl/dsl/debug/checkpoint *)
let test_g5_has_checkpoint_require () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let racket = compile_ok "g5_checkpoint" src in
  assert_contains "g5_checkpoint" "tesl/dsl/debug/checkpoint" racket

(* G5.4 debug and non-debug compiles are byte-identical (no fork) *)
let test_g5_debug_equals_normal () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let debug_result  = compile_ok_debug "g5_eq_debug" src in
  let normal_result = compile_ok "g5_eq_normal" src in
  if not (String.equal debug_result normal_result) then
    Alcotest.fail "g5_debug_equals_normal: B5 — debug and non-debug emission must match"

(* G5.5 compile_source with default (no ~debug) argument: still one path *)
let test_g5_default_has_thsl_src () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x
|} in
  let racket = compile_ok "g5_default" src in
  assert_contains "g5_default" "thsl-src" racket

(* G5.6 Normal compile: the (lambda () ...) checkpoint thunk is present *)
let test_g5_lambda_wrapper_normal () =
  let src = module_ ~exports:"inc" {|
fn inc(n: Int) -> Int =
  n + 1
|} in
  let racket = compile_ok "g5_lambda_normal" src in
  assert_contains "g5_lambda_normal" "(lambda ()" racket

(* ── Group 6: Edge cases ─────────────────────────────────────────────────────── *)

(* G6.1 Function with only a literal return (no lets): gets thsl-src! on terminal *)
let test_g6_literal_only () =
  let src = module_ ~exports:"zero" {|
fn zero() -> Int =
  0
|} in
  let racket = compile_ok_debug "g6_literal_only" src in
  assert_contains "g6_literal_only" "thsl-src!" racket;
  assert_balanced_parens "g6_literal_only" racket

(* G6.2 Recursive function compiles fine in debug mode *)
let test_g6_recursive_fn () =
  let src = module_ ~exports:"factorial" {|
fn factorial(n: Int) -> Int =
  if n <= 1 then
    1
  else
    n * factorial (n - 1)
|} in
  let racket = compile_ok_debug "g6_recursive" src in
  assert_contains "g6_recursive" "thsl-src!" racket;
  assert_balanced_parens "g6_recursive" racket

(* G6.3 Function with string interpolation compiles fine *)
let test_g6_string_interp () =
  let src = module_ ~exports:"greet" {|
fn greet(name: String) -> String =
  "Hello, ${name}!"
|} in
  let racket = compile_ok_debug "g6_string_interp" src in
  assert_contains "g6_string_interp" "thsl-src!" racket;
  assert_balanced_parens "g6_string_interp" racket

(* G6.4 Multiple functions: total thsl-src! count matches function count *)
let test_g6_count_matches_fns () =
  let src = module_ ~exports:"f1, f2, f3" {|
fn f1() -> Int = 1
fn f2() -> Int = 2
fn f3() -> Int = 3
|} in
  let racket = compile_ok_debug "g6_count_fns" src in
  let count = count_occurrences "thsl-src!" racket in
  if count < 3 then
    Alcotest.failf "g6_count_fns: expected at least 3 thsl-src! wrappers, got %d in:\n%s" count racket

(* G6.5 Function with bool expression body: parens balanced *)
let test_g6_bool_body_balanced () =
  let src = module_ ~exports:"isEven" {|
fn isEven(n: Int) -> Bool =
  n == 0
|} in
  let racket = compile_ok_debug "g6_bool_body" src in
  assert_contains "g6_bool_body" "thsl-src!" racket;
  assert_balanced_parens "g6_bool_body" racket

(* G6.6 Type declaration alongside function: compiles fine in debug mode *)
let test_g6_type_with_fn () =
  let src = module_ ~exports:"Shape, area" {|
type Shape
  = Circle
  | Square

fn area(s: Shape) -> Int =
  case s of
    Circle -> 314
    Square -> 100
|} in
  let racket = compile_ok_debug "g6_type_with_fn" src in
  assert_contains "g6_type_with_fn" "thsl-src!" racket;
  assert_balanced_parens "g6_type_with_fn" racket

(* G6.7 Debug output still produces valid define/pow for normal functions *)
let test_g6_debug_still_has_define_pow () =
  let src = module_ ~exports:"f" {|
fn f(x: Int) -> Int =
  x * 2
|} in
  let racket = compile_ok_debug "g6_define_pow" src in
  assert_contains "g6_define_pow" "define/pow" racket

(* G6.8 check function with let binding in body: balanced parens *)
let test_g6_check_with_let_balanced () =
  let src = module_ ~exports:"isLarge"
    ~extra:"fact Large (n: Int)\n" {|
check isLarge(n: Int) -> n: Int ::: Large n =
  if n > 1000 then
    ok n ::: Large n
  else
    fail 400 "too small"
|} in
  let racket = compile_ok_debug "g6_check_let" src in
  assert_balanced_parens "g6_check_let" racket

(* ── g7: arity regression for Phase 2 ────────────────────────────────────────── *)
(* thsl-src! must ALWAYS be emitted with 4 args: (file line locals thunk).
   Phase 2 bug: main blocks and test stmts emitted 3-arg calls which crashed
   at runtime because Racket's thsl-src! requires exactly 4 arguments. *)

let src_with_main = module_
  ~extra:"import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\nimport Tesl.App exposing [App]\n" {|
database AppDb = Database {
  schema: "app"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d" user: "u" password: ""
    connection: TcpConnection { host: "h" port: 5432 }
  })
}

fn double(x: Int) -> Int =
  let result = x
  result

handler appRoot() -> String
  requires [] =
  "ok"

api AppApi {
  get "/health" -> String
}

server AppServer for AppApi {
  endpoint_0 = appRoot
}

main() -> App requires [] =
  let y = double 5
  telemetry "done" {}
  App {
    database: AppDb
    api: AppServer
    port: 8080
    queues: []
  }
|}

let src_fn_only = module_ ~exports:"f" {|
fn f(a: Int) -> Int =
  let b = a
  b
|}

(* Check that every thsl-src! call in the source has "(list" immediately after the line num *)
let all_thsl_have_locals src =
  let n = String.length src in
  let pat = "(thsl-src! " in
  let pl = String.length pat in
  let ok = ref true in
  for i = 0 to n - pl - 1 do
    if String.sub src i pl = pat then begin
      (* After (thsl-src! we expect: "\"file\" N (list" or "\"file\" N (list" *)
      (* Skip the quote, file, quote, space, number, space — look for (list in next 80 chars *)
      let window = String.sub src i (min 80 (n - i)) in
      if not (contains "(list" window) then
        ok := false
    end
  done;
  !ok

let test_g7_fn_thsl_has_4_args () =
  let racket = compile_ok_debug "g7_fn_4args" src_fn_only in
  if not (contains "thsl-src!" racket) then
    Alcotest.fail "g7_fn_4args: no thsl-src! found";
  if not (all_thsl_have_locals racket) then
    Alcotest.fail "g7_fn_4args: some thsl-src! call is missing locals (list) — 3-arg arity bug"

let test_g7_main_thsl_has_4_args () =
  let racket = compile_ok_debug "g7_main_4args" src_with_main in
  if not (contains "thsl-src!" racket) then
    Alcotest.fail "g7_main_4args: no thsl-src! found in main block";
  if not (all_thsl_have_locals racket) then
    Alcotest.fail "g7_main_4args: some thsl-src! in main block has only 3 args — arity regression"

let test_g7_main_no_3arg_calls () =
  (* The 3-arg bug would produce (thsl-src! "f" N (lambda — with no (list before (lambda *)
  let racket = compile_ok_debug "g7_main_no3" src_with_main in
  (* A 3-arg call looks like: thsl-src! "..." NUMBER (lambda  with nothing in between *)
  let bad_pattern = "thsl-src! \"" in
  let n = String.length racket in
  let bp_len = String.length bad_pattern in
  let found_3arg = ref false in
  for i = 0 to n - bp_len - 1 do
    if String.sub racket i bp_len = bad_pattern then begin
      (* Look at the 80 chars following to see if (list appears before (lambda *)
      let window = String.sub racket i (min 80 (n - i)) in
      let list_pos = ref max_int in
      let lambda_pos = ref max_int in
      (try let _ = Str.search_forward (Str.regexp "(list") window 0 in
        list_pos := Str.match_beginning () with Not_found -> ());
      (try let _ = Str.search_forward (Str.regexp "(lambda") window 0 in
        lambda_pos := Str.match_beginning () with Not_found -> ());
      if !lambda_pos < !list_pos then found_3arg := true
    end
  done;
  if !found_3arg then
    Alcotest.fail "g7_main_no3: found 3-arg thsl-src! call in main block (lambda before (list)"

let test_g7_fn_no_3arg_calls () =
  let racket = compile_ok_debug "g7_fn_no3" src_fn_only in
  if not (all_thsl_have_locals racket) then
    Alcotest.fail "g7_fn_no3: fn body has 3-arg thsl-src! call"

let test_g7_test_let_has_4_args () =
  let src = module_ {|
test "basic" {
  let x = 42
  expect x == 42
}
|} in
  let racket = compile_ok_debug "g7_test_let_4args" src in
  if contains "thsl-src!" racket && not (all_thsl_have_locals racket) then
    Alcotest.fail "g7_test_let_4args: test block TsLet has 3-arg thsl-src!"

let test_g7_main_balanced () =
  let racket = compile_ok_debug "g7_main_balanced" src_with_main in
  assert_balanced_parens "g7_main_balanced" racket

let test_g7_fn_locals_is_list () =
  (* In fn bodies, each thsl-src! should have a locals list as 3rd arg *)
  let racket = compile_ok_debug "g7_fn_locals" src_fn_only in
  if not (contains "(thsl-src!" racket) then
    Alcotest.fail "g7_fn_locals: no thsl-src! found";
  (* The locals arg should be "(list" right after the line number *)
  if not (contains "(list" racket) then
    Alcotest.fail "g7_fn_locals: no (list found in debug output — locals arg missing"

let test_g7_main_locals_is_list () =
  let racket = compile_ok_debug "g7_main_locals" src_with_main in
  (* main block thsl-src! calls should have (list) as locals (no prior bindings at first) *)
  if not (contains "(list)" racket || contains "(list " racket) then
    Alcotest.fail "g7_main_locals: no (list in main debug output"

(* ── Test registration ───────────────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run "debug" [
    "thsl_src_presence", [
      test_case "debug adds thsl-src"         `Quick test_debug_adds_thsl_src;
      test_case "B5 non-debug has thsl-src"   `Quick test_no_debug_still_has_thsl_src;
      test_case "debug includes checkpoint"   `Quick test_debug_includes_checkpoint_require;
      test_case "B5 normal has checkpoint"    `Quick test_normal_has_checkpoint_require;
      test_case "B5 release == debug"         `Quick test_release_equals_debug;
      test_case "thsl-src has file ref"       `Quick test_debug_thsl_src_has_file_ref;
      test_case "thsl-src has line number"    `Quick test_debug_thsl_src_has_line_number;
      test_case "multiple fns wrapped"        `Quick test_debug_multiple_functions;
      test_case "B5 debug flag is noop"       `Quick test_debug_flag_is_noop;
    ];
    "function_kinds", [
      test_case "fn kind"                     `Quick test_debug_fn_kind;
      test_case "string literal body"         `Quick test_debug_string_literal_body;
      test_case "int literal body"            `Quick test_debug_int_literal_body;
      test_case "bool literal body"           `Quick test_debug_bool_literal_body;
      test_case "if body"                     `Quick test_debug_if_body;
      test_case "let body"                    `Quick test_debug_let_body;
      test_case "case body"                   `Quick test_debug_case_body;
    ];
    "output_correctness", [
      test_case "define/pow present in debug" `Quick test_debug_output_has_define_pow;
      test_case "normal output correct"       `Quick test_normal_output_correct;
      test_case "require appears once"        `Quick test_debug_require_appears_once;
      test_case "thsl-src form"               `Quick test_debug_thsl_src_form;
      test_case "wrapper properly closed"     `Quick test_debug_wrapper_properly_closed;
    ];
    "isolation", [
      test_case "two non-debug compiles"      `Quick test_two_non_debug_compiles;
      test_case "alternating debug mode"      `Quick test_alternating_debug_mode;
      test_case "single param fn"             `Quick test_debug_single_param_fn;
      test_case "zero param fn"               `Quick test_debug_zero_param_fn;
      test_case "const no wrapper"            `Quick test_debug_const_no_wrapper;
    ];
    "g1_thsl_src_bang_syntax", [
      test_case "thsl-src! present"           `Quick test_g1_thsl_src_bang_present;
      test_case "macro form not used"         `Quick test_g1_macro_form_not_used;
      test_case "lambda wrapper present"      `Quick test_g1_lambda_wrapper_present;
      test_case "file path quoted"            `Quick test_g1_file_path_quoted;
      test_case "line number positive"        `Quick test_g1_line_number_positive;
      test_case "each let gets wrapper"       `Quick test_g1_each_let_gets_wrapper;
      test_case "terminal expr wrapped"       `Quick test_g1_terminal_expr_wrapped;
      test_case "require checkpoint"          `Quick test_g1_require_checkpoint;
      test_case "B5 checkpoint in normal too" `Quick test_g1_checkpoint_in_normal;
      test_case "wraps inside fn body"        `Quick test_g1_wraps_inside_function;
      test_case "oneliner fn"                 `Quick test_g1_oneliner_fn;
      test_case "three lets"                  `Quick test_g1_three_lets;
      test_case "check kind"                  `Quick test_g1_check_kind;
      test_case "auth kind"                   `Quick test_g1_auth_kind;
      test_case "handler kind"                `Quick test_g1_handler_kind;
      test_case "establish kind"              `Quick test_g1_establish_kind;
    ];
    "g2_lambda_correctness", [
      test_case "single let balanced"         `Quick test_g2_single_let_balanced;
      test_case "multi let balanced"          `Quick test_g2_multi_let_balanced;
      test_case "case balanced"               `Quick test_g2_case_balanced;
      test_case "if balanced"                 `Quick test_g2_if_balanced;
      test_case "nested lets balanced"        `Quick test_g2_nested_lets_balanced;
      test_case "check proof balanced"        `Quick test_g2_check_proof_balanced;
      test_case "test block balanced"         `Quick test_g2_test_block_balanced;
      test_case "complex balanced"            `Quick test_g2_complex_balanced;
      test_case "var ref balanced"            `Quick test_g2_var_ref_balanced;
      test_case "string literal balanced"     `Quick test_g2_string_literal_balanced;
      test_case "if with lets balanced"       `Quick test_g2_if_with_lets_balanced;
    ];
    "g3_line_numbers", [
      test_case "no line zero"                `Quick test_g3_no_line_zero;
      test_case "line positive"               `Quick test_g3_line_positive;
      test_case "second fn larger lines"      `Quick test_g3_second_fn_larger_lines;
      test_case "lets increasing lines"       `Quick test_g3_lets_have_increasing_lines;
      test_case "exact line terminal"         `Quick test_g3_exact_line_terminal;
      test_case "exact lines lets"            `Quick test_g3_exact_lines_lets;
      test_case "first line is one"           `Quick test_g3_first_line_is_one;
      test_case "second fn exact lines"       `Quick test_g3_second_fn_exact_lines;
    ];
    "g4_test_block_instrumentation", [
      test_case "test let wrapped"            `Quick test_g4_test_let_wrapped;
      test_case "B5 test let wrap in normal"  `Quick test_g4_test_let_wrapper_normal;
      test_case "multiple test lets"          `Quick test_g4_multiple_test_lets_wrapped;
      test_case "test block no let"           `Quick test_g4_test_block_no_let;
      test_case "test block balanced"         `Quick test_g4_test_block_parens_balanced;
    ];
    "g5_one_emission_path", [
      test_case "B5 normal has thsl-src!"     `Quick test_g5_has_thsl_src_bang;
      test_case "B5 normal has thsl-src"      `Quick test_g5_has_thsl_src_any_form;
      test_case "B5 normal has checkpoint"    `Quick test_g5_has_checkpoint_require;
      test_case "B5 debug == normal"          `Quick test_g5_debug_equals_normal;
      test_case "B5 default has thsl-src"     `Quick test_g5_default_has_thsl_src;
      test_case "B5 lambda wrapper normal"    `Quick test_g5_lambda_wrapper_normal;
    ];
    "g6_edge_cases", [
      test_case "literal only"                `Quick test_g6_literal_only;
      test_case "recursive fn"                `Quick test_g6_recursive_fn;
      test_case "string interpolation"        `Quick test_g6_string_interp;
      test_case "count matches fns"           `Quick test_g6_count_matches_fns;
      test_case "bool body balanced"          `Quick test_g6_bool_body_balanced;
      test_case "type with fn"                `Quick test_g6_type_with_fn;
      test_case "debug still define/pow"      `Quick test_g6_debug_still_has_define_pow;
      test_case "check with let balanced"     `Quick test_g6_check_with_let_balanced;
    ];
    "g7_arity_regression", [
      (* Regression tests for the Phase 2 bug where thsl-src! was emitted with
         3 args in main blocks and test stmts, crashing at runtime.
         thsl-src! always requires exactly 4 args: (file line locals thunk). *)
      test_case "fn: thsl-src! has 4 args"    `Quick test_g7_fn_thsl_has_4_args;
      test_case "main: thsl-src! has 4 args"  `Quick test_g7_main_thsl_has_4_args;
      test_case "main: no 3-arg calls"        `Quick test_g7_main_no_3arg_calls;
      test_case "fn: no 3-arg calls"          `Quick test_g7_fn_no_3arg_calls;
      test_case "test-let: 4-arg call"        `Quick test_g7_test_let_has_4_args;
      test_case "main: balanced parens"       `Quick test_g7_main_balanced;
      test_case "fn: locals in 3rd position"  `Quick test_g7_fn_locals_is_list;
      test_case "main: locals is (list)"      `Quick test_g7_main_locals_is_list;
    ];
  ]
