(** Tesl.Int32 (NT-07) companion surface.

    `Int32` shipped with two functions (fromInt / toInt), so every use of the
    boundary type had to widen to `Int`, compute, and narrow again — and the
    widening detour is exactly what the type exists to prevent.  The module now
    mirrors Tesl.Int under ONE range rule:

      * a result that cannot leave [-2^31, 2^31) is an `Int32`
        (min / max / clamp / modulo / fromIntClamped);
      * a result that can is a `Maybe Int32` — `Nothing` is the out-of-range
        answer, never a silent wrap (fromInt / fromFloat / parse / add /
        subtract / multiply / negate / abs / pow / divide);
      * anything that is not an Int32 has its own type (toInt / toFloat /
        toString / sign / digits, the predicates).

    These tests pin the rule at the CHECKER (the range arithmetic itself is
    tested end-to-end by example/int32-boundary.tesl, which runs in the gate):
    the nominal wall still stands in both directions, every advertised name
    resolves, and each function's result type is the one the rule dictates.  A
    signature drifting to `Int32` where overflow is possible (a silent wrap at
    the wire boundary) fails here. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-int32" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got (exit %d):\n%s" code out)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but it compiled clean" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* Every probe is one module named Probe in probe.tesl. *)
let prog ?(extra_imports = "") ~exposing body =
  Printf.sprintf
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Int, String, Bool]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.Float exposing [Float]\n\
     import Tesl.Int32 exposing [Int32, %s]\n\
     %s\n\
     %s\n"
    exposing extra_imports body

(* ── The nominal wall (NT-07) still stands in both directions ────────────── *)

let t_int_is_not_an_int32 () =
  should_fail "unify Int with Int32\\|unify.*Int32"
    (prog ~exposing:"Int32.add"
       "fn f(n: Int) -> Maybe Int32 = Int32.add n n")

let t_int32_is_not_an_int () =
  should_fail "unify Int32 with Int\\|unify.*Int32"
    (prog ~exposing:"Int32.toInt"
       "fn f(x: Int32) -> Int = x")

let t_int32_literal_is_rejected () =
  (* A bare integer literal is an Int; it must be narrowed explicitly. *)
  should_fail "unify.*Int32"
    (prog ~exposing:"Int32.add"
       "fn f(x: Int32) -> Maybe Int32 = Int32.add x 1")

(* An arithmetic operator on an Int32 used to report the bare
   `cannot unify Int32 with Int`, which reads as "this type cannot do
   arithmetic".  It now names the checked operation (same treatment Money and
   the dimensioned quantities already get). *)

let t_plus_names_the_checked_operation () =
  should_fail "not defined for `Int32`.*Int32\\.add"
    (prog ~exposing:"Int32.toInt" "fn f(a: Int32, b: Int32) -> Int32 = a + b")

let t_minus_names_the_checked_operation () =
  should_fail "not defined for `Int32`.*Int32\\.subtract"
    (prog ~exposing:"Int32.toInt" "fn f(a: Int32, b: Int32) -> Int32 = a - b")

let t_times_names_the_checked_operation () =
  should_fail "not defined for `Int32`.*Int32\\.multiply"
    (prog ~exposing:"Int32.toInt" "fn f(a: Int32, b: Int32) -> Int32 = a * b")

let t_divide_operator_names_the_proof () =
  should_fail "not defined for `Int32`.*Int32\\.divide"
    (prog ~exposing:"Int32.toInt" "fn f(a: Int32, b: Int32) -> Int32 = a / b")

let t_modulo_operator_names_the_proof () =
  should_fail "not defined for `Int32`.*Int32\\.modulo"
    (prog ~exposing:"Int32.toInt" "fn f(a: Int32, b: Int32) -> Int32 = a % b")

(* ── The range rule, per function ────────────────────────────────────────── *)

(* Group 1 — cannot leave the range: result is Int32. *)

let t_range_closed_results_are_int32 () =
  should_pass
    (prog ~exposing:"Int32.min, Int32.max, Int32.clamp, Int32.fromIntClamped, \
                     Int32.minValue, Int32.maxValue"
       "fn f(a: Int32, b: Int32) -> Int32 =\n\
       \  Int32.clamp (Int32.min a (Int32.max a b)) Int32.minValue Int32.maxValue\n\
        fn g(n: Int) -> Int32 = Int32.fromIntClamped n")

let t_fromIntClamped_is_total () =
  (* Saturating narrowing returns Int32, NOT Maybe Int32 — that is the point. *)
  should_fail "unify.*Maybe\\|unify.*Int32"
    (prog ~exposing:"Int32.fromIntClamped"
       "fn f(n: Int) -> Maybe Int32 = Int32.fromIntClamped n")

(* Group 2 — can leave the range: result is Maybe Int32. *)

let t_overflow_possible_results_are_maybe () =
  should_pass
    (prog ~exposing:"Int32.add, Int32.subtract, Int32.multiply, Int32.negate, \
                     Int32.abs, Int32.pow, Int32.fromInt"
       "fn add(a: Int32, b: Int32) -> Maybe Int32 = Int32.add a b\n\
        fn sub(a: Int32, b: Int32) -> Maybe Int32 = Int32.subtract a b\n\
        fn mul(a: Int32, b: Int32) -> Maybe Int32 = Int32.multiply a b\n\
        fn neg(a: Int32) -> Maybe Int32 = Int32.negate a\n\
        fn ab(a: Int32) -> Maybe Int32 = Int32.abs a\n\
        fn pw(a: Int32, b: Int32) -> Maybe Int32 = Int32.pow a b\n\
        fn f(n: Int) -> Maybe Int32 = Int32.fromInt n")

let t_add_does_not_return_a_bare_int32 () =
  (* If `add` ever returned Int32 it would have to wrap silently — the exact
     failure mode Int32 exists to prevent.  Pin it. *)
  should_fail "unify.*Int32\\|unify.*Maybe"
    (prog ~exposing:"Int32.add"
       "fn f(a: Int32, b: Int32) -> Int32 = Int32.add a b")

let t_abs_does_not_return_a_bare_int32 () =
  (* abs(minValue) has no Int32 counterpart. *)
  should_fail "unify.*Int32\\|unify.*Maybe"
    (prog ~exposing:"Int32.abs"
       "fn f(a: Int32) -> Int32 = Int32.abs a")

(* Group 3 — conversions out of the type. *)

let t_conversions_have_their_own_types () =
  should_pass
    (prog ~exposing:"Int32.toInt, Int32.toFloat, Int32.toString, Int32.parse, \
                     Int32.fromFloat, Int32.sign, Int32.digits"
       "fn i(x: Int32) -> Int = Int32.toInt x\n\
        fn fl(x: Int32) -> Float = Int32.toFloat x\n\
        fn s(x: Int32) -> String = Int32.toString x\n\
        fn p(raw: String) -> Maybe Int32 = Int32.parse raw\n\
        fn ff(v: Float) -> Maybe Int32 = Int32.fromFloat v\n\
        fn sg(x: Int32) -> Int = Int32.sign x\n\
        fn f(x: Int32) -> Int = Int32.digits x")

let t_toFloat_is_a_float () =
  should_fail "unify.*Float\\|unify.*Int"
    (prog ~exposing:"Int32.toFloat"
       "fn f(x: Int32) -> Int = Int32.toFloat x")

let t_sign_is_an_int_not_an_int32 () =
  (* sign/digits return Int so they compose with Int arithmetic and compare
     against Int literals (`Int32.sign x == 1`) — mirroring Int.sign. *)
  should_pass
    (prog ~exposing:"Int32.sign"
       "fn f(x: Int32) -> Bool = Int32.sign x == 1")

(* Group 4 — predicates. *)

let t_predicates_return_bool () =
  should_pass
    (prog ~exposing:"Int32.isPositive, Int32.isNegative, Int32.isZero, \
                     Int32.isEven, Int32.isOdd"
       "fn f(x: Int32) -> Bool =\n\
       \  Int32.isPositive x && Int32.isNegative x && Int32.isZero x \
        && Int32.isEven x && Int32.isOdd x")

(* ── Division: the IsNonZero obligation carries over to Int32 ─────────────── *)

let t_divide_requires_a_proven_divisor () =
  should_fail "does not statically satisfy\\|IsNonZero"
    (prog ~exposing:"Int32.divide"
       "fn f(a: Int32, b: Int32) -> Maybe Int32 = Int32.divide a b")

let t_divide_accepts_a_proven_divisor () =
  should_pass
    (prog ~exposing:"IsNonZero, Int32.divide, Int32.modulo"
       "fn f(a: Int32, b: Int32 ::: IsNonZero b) -> Maybe Int32 = Int32.divide a b\n\
        fn g(a: Int32, b: Int32 ::: IsNonZero b) -> Int32 = Int32.modulo a b")

let t_nonZero_mints_the_proof () =
  should_pass
    (prog ~exposing:"IsNonZero, Int32.nonZero, Int32.divide"
       "fn f(a: Int32, b: Int32 ::: IsNonZero b) -> Maybe Int32 = Int32.divide a b\n\
        fn g(a: Int32, raw: Int32) -> Maybe Int32 =\n\
       \  let d = check Int32.nonZero(raw)\n\
       \  f a d")

let t_modulo_stays_in_range () =
  (* |remainder| < |divisor| <= 2^31, so modulo cannot overflow: Int32, not Maybe. *)
  should_fail "unify.*Maybe\\|unify.*Int32"
    (prog ~exposing:"IsNonZero, Int32.modulo"
       "fn f(a: Int32, b: Int32 ::: IsNonZero b) -> Maybe Int32 = Int32.modulo a b")

let t_nonNegative_mints_the_proof () =
  should_pass
    (prog ~exposing:"IsNonNegative, Int32.nonNegative, Int32.toInt"
       "fn use(x: Int32 ::: IsNonNegative x) -> Int = Int32.toInt x\n\
        fn f(raw: Int32) -> Int =\n\
       \  let n = check Int32.nonNegative(raw)\n\
       \  use n")

(* ── Import gating: no name is silently ambient ──────────────────────────── *)

let t_names_need_the_import () =
  should_fail "toFloat"
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Float exposing [Float]\n\
     import Tesl.Int32 exposing [Int32, Int32.toInt]\n\
     fn f(x: Int32) -> Float = Int32.toFloat x\n"

let t_predicate_exposed_by_both_int_modules_is_ambiguous () =
  (* Tesl.Int and Tesl.Int32 both own IsNonZero; exposing both in one file is
     the existing single-source V001, not a Racket-level duplicate import. *)
  should_fail "multiple modules"
    "module Probe exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Int exposing [IsNonZero, Int.abs]\n\
     import Tesl.Int32 exposing [Int32, IsNonZero, Int32.toInt]\n\
     fn f(x: Int32) -> Int = Int.abs (Int32.toInt x)\n"

(* ── Table-level: the module surface is typed, not fail-open ─────────────── *)

let int32_exports () =
  match List.assoc_opt "Tesl.Int32" Type_system.tesl_module_exports with
  | Some names -> names
  | None -> failf "Tesl.Int32 has no export row in tesl_module_exports"

let t_every_export_has_a_scheme () =
  let env = Type_system.make_stdlib_env () in
  let no_scheme = [ "Int32"; "IsNonZero"; "IsNonNegative" ] in  (* type + facts *)
  let missing =
    List.filter
      (fun n -> not (List.mem n no_scheme) && not (List.mem_assoc n env))
      (int32_exports ())
  in
  if missing <> [] then
    failf
      "Tesl.Int32 export(s) with no stdlib_env signature (they would type-check \
       as anything, laundering the nominal type): %s"
      (String.concat ", " missing)

let t_no_export_returns_a_bare_int32_when_overflow_is_possible () =
  (* The range rule as a table invariant: these must NOT be typed `-> Int32`. *)
  let overflow_possible =
    [ "Int32.fromInt"; "Int32.parse"; "Int32.fromFloat"; "Int32.add";
      "Int32.subtract"; "Int32.multiply"; "Int32.negate"; "Int32.abs";
      "Int32.pow"; "Int32.divide" ]
  in
  let env = Type_system.make_stdlib_env () in
  List.iter (fun name ->
    match List.assoc_opt name env with
    | None -> failf "%s has no stdlib_env scheme" name
    | Some sch ->
      let _args, ret = Type_system.split_fun_type sch.Type_system.mono in
      let rendered = Type_system.pp_ty ret in
      if rendered = "Int32" then
        failf
          "%s returns a bare `Int32` — an out-of-range result would have to wrap \
           silently.  It must return `Maybe Int32`."
          name)
    overflow_possible

let t_range_closed_exports_return_int32 () =
  let closed =
    [ "Int32.fromIntClamped"; "Int32.min"; "Int32.max"; "Int32.clamp";
      "Int32.modulo"; "Int32.minValue"; "Int32.maxValue" ]
  in
  let env = Type_system.make_stdlib_env () in
  List.iter (fun name ->
    match List.assoc_opt name env with
    | None -> failf "%s has no stdlib_env scheme" name
    | Some sch ->
      let _args, ret = Type_system.split_fun_type sch.Type_system.mono in
      let rendered = Type_system.pp_ty ret in
      if rendered <> "Int32" then
        failf "%s should return `Int32` (its result cannot leave the range), got %s"
          name rendered)
    closed

(* ── Generated clients: Int32 must be a real wire type ───────────────────── *)

(* The W091 linter steers a wire `Int` field to `Int32`, so an Int32 at an API
   boundary is the RECOMMENDED shape — but neither client generator knew the
   type: TS emitted an undefined `Int32Schema` and Elm an undefined
   `Int32` / `int32Decoder` / `int32Encoder`, so following the linter's advice
   produced a client that does not compile.  Int32 is now an IR type
   (Ir.IRInt32) with a range-checked schema. *)

let client_app = {|module Probe exposing [CountServer]
import Tesl.Prelude exposing [String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int32 exposing [Int32, Int32.fromIntClamped]

type Version = Int32

record Counts {
  total: Int32,
  label: String
}

handler counts() -> Counts =
  Counts { total: Int32.fromIntClamped 5, label: "hi" }

handler versions() -> List Int32 =
  [Int32.fromIntClamped 1]

handler maybeCount() -> Maybe Int32 =
  Something (Int32.fromIntClamped 3)

api CountApi {
  get "/counts"
    -> Counts
  get "/versions"
    -> List Int32
  get "/maybe"
    -> Maybe Int32
}

server CountServer for CountApi {
  counts = counts
  versions = versions
  maybeCount = maybeCount
}
|}

let generate flag =
  with_temp_file client_app (fun path ->
    let code, out = run_compiler [ flag; path ] in
    if code <> 0 then failf "%s failed (exit %d):\n%s" flag code out;
    out)

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0

let t_ts_client_has_no_undefined_int32_schema () =
  let out = generate "--generate-ts" in
  if contains out "Int32Schema" then
    failf
      "the TS client references an undefined `Int32Schema` — an Int32 field must \
       emit a real Zod schema:\n%s" out;
  (* the range is part of the type, so the client checks it too *)
  if not (contains out "z.number().int().gte(-2147483648).lte(2147483647)") then
    failf "the TS client must emit a RANGE-checked integer for Int32:\n%s" out

let t_elm_client_has_no_undefined_int32_names () =
  let out = generate "--generate-elm" in
  List.iter (fun needle ->
    if contains out needle then
      failf "the Elm client references an undefined `%s`:\n%s" needle out)
    [ "int32Decoder"; "int32Encoder"; ": Int32"; "Int32\n" ];
  if not (contains out "(D.field \"total\" D.int)") then
    failf "an Int32 record field must decode with D.int in the Elm client:\n%s" out

let () =
  run "Int32-Surface" [
    "nominal-wall", [
      test_case "an Int is not an Int32" `Quick t_int_is_not_an_int32;
      test_case "an Int32 is not an Int" `Quick t_int32_is_not_an_int;
      test_case "an integer literal is not an Int32" `Quick t_int32_literal_is_rejected;
    ];
    "operator-diagnostics", [
      test_case "+ names Int32.add" `Quick t_plus_names_the_checked_operation;
      test_case "- names Int32.subtract" `Quick t_minus_names_the_checked_operation;
      test_case "* names Int32.multiply" `Quick t_times_names_the_checked_operation;
      test_case "/ names Int32.divide and its proof" `Quick t_divide_operator_names_the_proof;
      test_case "%% names Int32.modulo and its proof" `Quick t_modulo_operator_names_the_proof;
    ];
    "range-rule", [
      test_case "range-closed operations return Int32" `Quick t_range_closed_results_are_int32;
      test_case "fromIntClamped is total (Int32, not Maybe)" `Quick t_fromIntClamped_is_total;
      test_case "overflow-possible operations return Maybe Int32" `Quick
        t_overflow_possible_results_are_maybe;
      test_case "add cannot return a bare Int32" `Quick t_add_does_not_return_a_bare_int32;
      test_case "abs cannot return a bare Int32" `Quick t_abs_does_not_return_a_bare_int32;
      test_case "modulo stays in range (Int32, not Maybe)" `Quick t_modulo_stays_in_range;
    ];
    "conversions", [
      test_case "conversions have their own result types" `Quick
        t_conversions_have_their_own_types;
      test_case "toFloat is a Float" `Quick t_toFloat_is_a_float;
      test_case "sign is an Int, comparable to Int literals" `Quick
        t_sign_is_an_int_not_an_int32;
      test_case "predicates return Bool" `Quick t_predicates_return_bool;
    ];
    "division-proofs", [
      test_case "divide rejects an unproven divisor" `Quick t_divide_requires_a_proven_divisor;
      test_case "divide accepts a proven divisor" `Quick t_divide_accepts_a_proven_divisor;
      test_case "check Int32.nonZero mints IsNonZero" `Quick t_nonZero_mints_the_proof;
      test_case "check Int32.nonNegative mints IsNonNegative" `Quick
        t_nonNegative_mints_the_proof;
    ];
    "import-gating", [
      test_case "an unexposed Int32 name is not ambient" `Quick t_names_need_the_import;
      test_case "IsNonZero from both Int and Int32 is V001" `Quick
        t_predicate_exposed_by_both_int_modules_is_ambiguous;
    ];
    "generated-clients", [
      test_case "the TS client emits a range-checked integer for Int32" `Quick
        t_ts_client_has_no_undefined_int32_schema;
      test_case "the Elm client emits Int/D.int for Int32" `Quick
        t_elm_client_has_no_undefined_int32_names;
    ];
    "surface-tables", [
      test_case "every Tesl.Int32 export has a stdlib_env scheme" `Quick
        t_every_export_has_a_scheme;
      test_case "overflow-possible exports return Maybe Int32" `Quick
        t_no_export_returns_a_bare_int32_when_overflow_is_possible;
      test_case "range-closed exports return Int32" `Quick
        t_range_closed_exports_return_int32;
    ];
  ]
