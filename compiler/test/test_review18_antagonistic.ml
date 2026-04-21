(** Antagonistic regression tests for Critical Review 18.
    Each test probes a specific flaw, limitation, or correctness gap
    identified during the review. *)

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let tesl = Sys.getenv_opt "TESL_BIN" |> Option.value ~default:"tesl"

let compile_string src =
  let tmp = Filename.temp_file "tesl-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s check %s 2>&1" tesl tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  Sys.remove tmp;
  out

let should_pass src =
  let out = compile_string src in
  check bool "should compile without errors" false
    (String.length out > 0 &&
     (let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false))

let should_fail pattern src =
  let out = compile_string src in
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true
    (let re = Str.regexp pattern in
     try ignore (Str.search_forward re out 0); true with Not_found -> false)

(* ── Bug 2.1: variable * variable multiplication ────────────────────────── *)

let () =
  let test_mul_var_var () =
    (* The most natural way to multiply two variables should compile *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn area(w: Int, h: Int) -> Int = w * h\n"
  in
  let test_mul_var_var_sq () =
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn square(n: Int) -> Int = n * n\n"
  in
  let test_mul_three_vars () =
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn volume(l: Int, w: Int, h: Int) -> Int = l * w * h\n"
  in
  let test_mul_var_lit () =
    (* variable * literal should already work *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn double(n: Int) -> Int = n * 2\n"
  in
  let test_mul_lit_var () =
    (* literal * variable should work *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn double(n: Int) -> Int = 2 * n\n"
  in
  let test_factorial_direct () =
    (* Recursive multiplication without requiring * prefix *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, Bool(..)]\n\
       fn factorial(n: Int) -> Int =\n\
       \  if n <= 1 then\n    1\n  else\n    n * factorial (n - 1)\n"
  in
  run "R18-Bug2.1-Multiplication" [
    "var*var",       [test_case "area fn" `Quick test_mul_var_var];
    "var*var-sq",    [test_case "square fn" `Quick test_mul_var_var_sq];
    "three-vars",    [test_case "volume fn" `Quick test_mul_three_vars];
    "var*lit",       [test_case "double (n*2)" `Quick test_mul_var_lit];
    "lit*var",       [test_case "double (2*n)" `Quick test_mul_lit_var];
    "factorial",     [test_case "recursive multiply" `Quick test_factorial_direct];
  ]

(* ── Bug 2.2: literal patterns in case ─────────────────────────────────── *)

let () =
  let test_int_pattern () =
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\n\
       fn classify(n: Int) -> String =\n\
       \  case n of\n    0 -> \"zero\"\n    1 -> \"one\"\n    _ -> \"other\"\n"
  in
  let test_str_pattern () =
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\n\
       fn method(s: String) -> String =\n\
       \  case s of\n\
       \    \"GET\" -> \"read\"\n\
       \    \"POST\" -> \"write\"\n\
       \    _ -> \"unknown\"\n"
  in
  let test_neg_int_pattern () =
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\n\
       fn sign(n: Int) -> String =\n\
       \  case n of\n    -1 -> \"minus one\"\n    0 -> \"zero\"\n    _ -> \"other\"\n"
  in
  run "R18-Bug2.2-LiteralPatterns" [
    "int",  [test_case "int literal pattern" `Quick test_int_pattern];
    "str",  [test_case "string literal pattern" `Quick test_str_pattern];
    "neg",  [test_case "negative int pattern" `Quick test_neg_int_pattern];
  ]

(* ── Bug 2.3: capability enforcement for fn (not just handler) ─────────── *)

let () =
  let test_fn_uses_time_without_requires () =
    (* A plain fn calling nowMillis() without requires [time] should be an error *)
    should_fail "capability\\|requires\\|time"
      "#lang tesl\nmodule T exposing []\n\
       import Tesl.Prelude exposing [Int]\n\
       import Tesl.Time exposing [nowMillis, PosixMillis]\n\
       fn getTimeWithoutCapability() -> PosixMillis =\n\
       \  nowMillis()\n"
  in
  let test_handler_via_fn_without_capability () =
    (* A handler with requires [] calling a fn that secretly needs time should fail *)
    should_fail "capability\\|requires\\|time"
      "#lang tesl\nmodule T exposing []\n\
       import Tesl.Prelude exposing [Int]\n\
       import Tesl.Time exposing [nowMillis, PosixMillis]\n\
       fn getTimeWithoutCapability() -> PosixMillis =\n\
       \  nowMillis()\n\
       handler badHandler() -> PosixMillis\n\
       \  requires [] =\n\
       \  getTimeWithoutCapability()\n"
  in
  run "R18-Bug2.3-CapabilityFn" [
    "fn-time",     [test_case "fn uses time without requires" `Quick test_fn_uses_time_without_requires];
    "handler-via", [test_case "handler->fn transitive cap leak" `Quick test_handler_via_fn_without_capability];
  ]

(* ── Bug 2.4: ForAll type hole with chained filterCheck ────────────────── *)

let () =
  let test_forall_type_hole () =
    (* Chained filterCheck should not satisfy ForAll (A && B) return type *)
    should_fail "proof\\|ForAll\\|satisfy\\|filterCheck"
      "#lang tesl\nmodule T exposing []\n\
       import Tesl.Prelude exposing [Int, List]\n\
       import Tesl.List exposing [List.filterCheck]\n\
       fact IsPositive (n: Int)\n\
       fact IsSmall (n: Int)\n\
       check isPositive(n: Int) -> n: Int ::: IsPositive n =\n\
       \  if n > 0 then\n    ok n ::: IsPositive n\n  else\n    fail 400 \"not positive\"\n\
       check isSmall(n: Int) -> n: Int ::: IsSmall n =\n\
       \  if n < 100 then\n    ok n ::: IsSmall n\n  else\n    fail 400 \"too big\"\n\
       fn filterBoth(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall) =\n\
       \  let positives = List.filterCheck isPositive xs\n\
       \  List.filterCheck isSmall positives\n"
  in
  run "R18-Bug2.4-ForAllTypeHole" [
    "chained-filter", [test_case "chained filterCheck type hole" `Quick test_forall_type_hole];
  ]

(* ── Bug 2.5: L22-type-hole test in test suite uses invalid single-line if ── *)

let () =
  let test_l22_tesl_syntax () =
    (* The single-line if should be rejected; this test tracks the fix *)
    should_fail "then.*body\\|indented"
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       check checkPos(n: Int) -> n: Int ::: IsPositive n =\n\
       \  if n > 0 then ok n ::: IsPositive n else fail 400 \"x\"\n"
  in
  run "R18-Bug2.5-L22TestSyntax" [
    "single-line-if", [test_case "single-line if rejected" `Quick test_l22_tesl_syntax];
  ]

(* ── Bug 2.6: non-exhaustive ADT match IS actually enforced ───────────── *)
(* NOTE: This was listed as a bug in the review but testing confirmed
   exhaustiveness checking DOES work correctly. Keeping as a regression test. *)

let () =
  let test_non_exhaustive_caught () =
    (* Missing Blue case SHOULD produce an error -- and does *)
    should_fail "non-exhaustive\\|missing constructor\\|Blue"
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [String]\n\
       type Color\n  = Red\n  | Green\n  | Blue\n\
       fn colorStr(c: Color) -> String =\n\
       \  case c of\n    Red -> \"red\"\n    Green -> \"green\"\n"
  in
  let test_wildcard_exhaustive () =
    (* Wildcard _ should satisfy exhaustiveness *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [String]\n\
       type Color\n  = Red\n  | Green\n  | Blue\n\
       fn colorStr(c: Color) -> String =\n\
       \  case c of\n    Red -> \"red\"\n    _ -> \"other\"\n"
  in
  run "R18-Bug2.6-NonExhaustive" [
    "missing-ctor",   [test_case "non-exhaustive ADT match caught" `Quick test_non_exhaustive_caught];
    "wildcard-ok",    [test_case "wildcard satisfies exhaustiveness" `Quick test_wildcard_exhaustive];
  ]

(* ── Design 3.2: type aliases are nominal ─────────────────────────────── *)

let () =
  let test_alias_transparent () =
    (* type UserId = String should be transparent (alias, not newtype) *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [String]\n\
       type UserId = String\n\
       fn makeUser(id: String) -> UserId = id\n\
       fn getId(id: UserId) -> String = id\n"
  in
  run "R18-Design3.2-TypeAlias" [
    "transparent", [test_case "type alias transparent" `Quick test_alias_transparent];
  ]

(* ── Design 3.3: variable shadowing ─────────────────────────────────────── *)

let () =
  let test_shadow_in_let () =
    (* Let binding should be allowed to shadow a param with different name *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn process(n: Int) -> Int =\n\
       \  let result = n + 1\n\
       \  let result2 = result + 1\n\
       \  result2\n"
  in
  let test_shadow_same_name () =
    (* Shadowing a param with the SAME name might be restricted by design,
       but the error should be clear *)
    let out = compile_string
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\n\
       fn process(n: Int) -> Int =\n  let n = n + 1\n  n\n"
    in
    (* Either accept it (good ergonomics) or give a CLEAR error (not cryptic) *)
    let has_clear_error = String.length out = 0 ||
      let re = Str.regexp "shadow\\|rebind" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false
    in
    check bool "shadowing error is clear" true has_clear_error
  in
  run "R18-Design3.3-Shadowing" [
    "different-name", [test_case "let with different name" `Quick test_shadow_in_let];
    "same-name",      [test_case "let shadows same name" `Quick test_shadow_same_name];
  ]

(* ── Design 3.1: multi-subject facts ────────────────────────────────────── *)

let () =
  let test_multi_subject_fact () =
    (* Facts with two subjects should be possible *)
    should_pass
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\n\
       fact Authorized (userId: String) (resourceId: String)\n\
       check checkAuthorized(userId: String, resourceId: String)\n\
       \  -> userId: String ::: Authorized userId resourceId =\n\
       \  if userId == \"admin\" then\n\
       \    ok userId ::: Authorized userId resourceId\n\
       \  else\n\
       \    fail 403 \"not authorized\"\n"
  in
  run "R18-Design3.1-MultiSubjectFact" [
    "two-subjects", [test_case "fact with two subjects" `Quick test_multi_subject_fact];
  ]

(* ── Type 4.4: 4-tuple silently becomes Unit ────────────────────────────── *)

let () =
  let test_4tuple () =
    (* A 4-tuple type annotation should not silently become Unit *)
    let out = compile_string
      "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\n\
       fn mkTuple(a: Int, b: Int, c: Int, d: Int) -> (Int, Int, Int, Int) =\n\
       \  (a, b, c, d)\n"
    in
    (* Either it compiles correctly OR gives a clear unsupported-arity error,
       NOT silently cast to Unit *)
    let silently_unit = String.length out > 0 &&
      let re = Str.regexp "cannot unify.*Unit\\|Unit.*tuple" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false
    in
    check bool "4-tuple must not silently become Unit" false silently_unit
  in
  run "R18-Type4.4-FourTuple" [
    "four-tuple", [test_case "4-tuple not Unit" `Quick test_4tuple];
  ]

(* ── Module resolution: clear error when file not found ─────────────────── *)

let () =
  let test_module_not_found () =
    (* When a module file doesn't exist, the error should say "module not found"
       rather than "unknown name: <fn>" *)
    should_fail "module.*not found\\|file.*not found\\|no such file\\|could not load"
      "#lang tesl\nmodule T exposing []\n\
       import NonExistentModule exposing [something]\n\
       fn f() -> Int = something 1\n"
  in
  run "R18-ModuleResolution" [
    "not-found", [test_case "module not found error" `Quick test_module_not_found];
  ]

(* ── nowMillis capability detection ─────────────────────────────────────── *)

let () =
  let test_nowmillis_requires_time () =
    (* A handler calling nowMillis() without requires [time] should fail *)
    should_fail "capability\\|time\\|requires"
      "#lang tesl\nmodule T exposing []\n\
       import Tesl.Prelude exposing [Int]\n\
       import Tesl.Time exposing [nowMillis, PosixMillis]\n\
       handler getTime() -> PosixMillis\n\
       \  requires [] =\n\
       \  nowMillis()\n"
  in
  run "R18-NowMillisCapability" [
    "now-cap", [test_case "nowMillis needs time capability" `Quick test_nowmillis_requires_time];
  ]
