(** Antagonistic regression tests for Critical Review 30.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary identified during Review 30.

    Findings covered:
      G01  fn with binding return proof annotation: static checker trusts undeclared proof
      G02  Record update syntax bypasses proof annotation on proof-bearing fields
      G03  inline check call (without let) loses proof subject — needs good error
      G04  ForAll annotation type-mismatch error is confusing (IsPositive on List vs Int)
      G05  Partial application with literal argument to proof-requiring parameter rejected
      G06  Mutual recursion compiles without error (no cycle detection concern)
      G07  Circular module-level bindings compile without error (no static cycle check)
      G08  ADT with same-named constructor and type is correctly rejected
      G09  establish with fail is correctly rejected  
      G10  Capability transitive propagation: missing declaration caught
      G11  Case branch type mismatch is caught
      G12  if/then/else branch type mismatch is caught
      G13  Record construction with unknown field gives clear error
      G14  Record construction with missing field gives clear error
      G15  List with heterogeneous element types gives clear error
      G16  Cross-subject multi-param proof confusion is caught
      G17  Newtype nominal safety: UserId ≠ ProjectId
      G18  forgetFact then re-establish bypass: compiles but subject check at use site
      G19  LSP type-at-json returns null for many expression positions (coverage gap)
      G20  String interpolation of ADT type compiles without error (no ADT-in-interp check)
      G21  fn binding return proof is NOT validated by static checker (runtime fallback)
      G22  record field proof annotation NOT enforced on record update (soundness gap)
      G23  duplicate fact declaration is correctly rejected
      G24  import ordering: import after definition gives clear error
      G25  undefined function call gives clear type error
      G26  arity error: too many arguments gives clear message
      G27  % operator requires IsNonZero proof on right operand
      G28  establish cannot use fail — correctly rejected
      G29  ForAll proof stripped after List.map — correctly rejected at call site
      G30  paren-style call syntax f(x) is accepted (compiles) — legacy accommodation *)

open Alcotest

(* ── Helpers ────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r30-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let proof_prelude =
  prelude ^
  "fact IsPositive (n: Int)\n" ^
  "fact IsSmall (n: Int)\n" ^
  "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
  "  if n > 0 then\n" ^
  "    ok n ::: IsPositive n\n" ^
  "  else\n" ^
  "    fail 400 \"neg\"\n" ^
  "check checkSmall(n: Int) -> n: Int ::: IsSmall n =\n" ^
  "  if n < 100 then\n" ^
  "    ok n ::: IsSmall n\n" ^
  "  else\n" ^
  "    fail 400 \"big\"\n" ^
  "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n" ^
  "fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = \"ok\"\n"

(* ── G01: fn binding return proof now rejected by static checker ────────── *)
(*                                                                             *)
(* A `fn` with a binding return spec like `-> n: Int ::: IsPositive n`        *)
(* where the tail expression is just `n` (no proof established) is now        *)
(* detected and rejected by the static checker.                               *)
let test_g01_fn_binding_return_proof_trusted () =
  let src = proof_prelude ^
    (* sneaky declares IsPositive in its return but the body just returns n *)
    "fn sneaky(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  n\n" ^
    "fn callsSneaky(x: Int) -> Int =\n" ^
    "  let r = sneaky x\n" ^
    "  needsPositive r\n" in
  should_fail "cannot declare a proof return type\\|fn.*proof return" src

(* ── G02: Record update now enforces proof annotation on proof-bearing fields ─ *)
(*                                                                                *)
(* A record field declared `bio: String ::: IsTrimmed bio` requires a proven     *)
(* value at update sites. `{ p | bio = rawString }` now correctly requires       *)
(* the new value to carry `IsTrimmed`. The soundness gap is fixed.               *)
let test_g02_record_update_bypasses_field_proof () =
  let src = prelude ^
    "import Tesl.String exposing [String.length]\n" ^
    "fact IsTrimmed (s: String)\n" ^
    "check checkTrimmed(s: String) -> s: String ::: IsTrimmed s =\n" ^
    "  if String.length s > 0 then\n" ^
    "    ok s ::: IsTrimmed s\n" ^
    "  else\n" ^
    "    fail 400 \"empty\"\n" ^
    "record Profile {\n" ^
    "  name: String\n" ^
    "  bio: String ::: IsTrimmed bio\n" ^
    "}\n" ^
    (* update now requires IsTrimmed on newBio *)
    "fn updateBioUnsafe(p: Profile, newBio: String) -> Profile =\n" ^
    "  { p | bio = newBio }\n" in
  should_fail "V001\\|does not statically satisfy\\|IsTrimmed" src

(* ── G03: Inline check call loses proof subject — good error required ─────── *)
(*                                                                              *)
(* `needsPositive (check checkPos x)` requires a named subject but the result of     *)
(* `checkPos x` is an expression without a tracked binder. The compiler        *)
(* should reject this with a clear message guiding the user to use `let`.      *)
let test_g03_inline_check_call_loses_subject () =
  let src = proof_prelude ^
    "fn test(x: Int) -> Int =\n" ^
    "  needsPositive (check checkPos x)\n" in
  should_fail "no trackable subject\\|bind the expression\\|named variable" src

(* ── G04: ForAll annotation with wrong subject type gives confusing error ─── *)
(*                                                                              *)
(* Writing `List Int ::: ForAll IsPositive xs` where IsPositive expects Int    *)
(* gives an error "IsPositive on xs has type List Int but fact expects Int".   *)
(* The error is technically correct but may confuse users: they wrote the      *)
(* proof for the element type, not the list. A hint about ForAll subject       *)
(* scoping would improve the message. Currently tests the error exists.        *)
let test_g04_forall_wrong_subject_type_error () =
  let src = proof_prelude ^
    "import Tesl.List exposing [List.filterCheck, List.length]\n" ^
    "fn badForAll(xs: List Int) -> List Int ::: ForAll IsPositive xs =\n" ^
    "  List.filterCheck checkPos xs\n" in
  should_fail "List Int\\|IsPositive\\|type" src

(* ── G05: Partial application of proof-requiring fn with literal rejected ─── *)
(*                                                                              *)
(* `addPositive 5 y` where `addPositive` requires `IsPositive x` on first arg *)
(* fails: the literal `5` cannot be a proof subject. Users must bind first.    *)
let test_g05_partial_apply_literal_proof_arg_rejected () =
  let src = proof_prelude ^
    "fn addPositive(x: Int ::: IsPositive x, y: Int ::: IsPositive y) -> Int = x + y\n" ^
    "fn applyToFive(y: Int ::: IsPositive y) -> Int =\n" ^
    "  addPositive 5 y\n" in
  should_fail "literal\\|proof\\|no trackable subject\\|V001" src

(* ── G06: Mutual recursion compiles without error ─────────────────────────── *)
(*                                                                              *)
(* Mutual recursion between fn declarations is permitted and compiles.         *)
(* No termination checking exists (by design for alpha phase).                 *)
let test_g06_mutual_recursion_compiles () =
  let src = prelude ^
    "fn isEven(n: Int) -> Bool =\n" ^
    "  if n == 0 then\n" ^
    "    True\n" ^
    "  else\n" ^
    "    isOdd (n - 1)\n" ^
    "fn isOdd(n: Int) -> Bool =\n" ^
    "  if n == 0 then\n" ^
    "    False\n" ^
    "  else\n" ^
    "    isEven (n - 1)\n" in
  should_pass src

(* ── G07: Circular module-level bindings now rejected ──────────────────── *)
(*                                                                             *)
(* `x = y + 1; y = x + 1` is now detected as a circular binding and          *)
(* rejected with an error.                                                    *)
let test_g07_circular_toplevel_bindings_no_error () =
  let src = prelude ^
    "x = y + 1\n" ^
    "y = x + 1\n" in
  should_fail "circular binding" src

(* ── G08: ADT constructor with same name as type is correctly rejected ──── *)
(*                                                                              *)
(* `type Foo = Foo` must be rejected with a clear error message.               *)
let test_g08_adt_same_name_constructor_rejected () =
  let src = prelude ^
    "type Foo\n" ^
    "  = Foo\n" in
  should_fail "same name\\|rename\\|constructor\\|Foo" src

(* ── G09: establish with fail is correctly rejected ─────────────────────── *)
(*                                                                              *)
(* `establish` must be total; using `fail` inside it is a compile error.       *)
let test_g09_establish_fail_rejected () =
  let src = proof_prelude ^
    "establish conditionalProof(n: Int) -> Fact (IsPositive n) =\n" ^
    "  if n > 0 then\n" ^
    "    IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"cannot prove\"\n" in
  should_fail "establish.*fail\\|fail.*establish\\|P001" src

(* ── G10: Capability transitivity: missing declaration is caught ─────────── *)
(*                                                                              *)
(* fn wrapper() calls fn getTime() which requires [time].                      *)
(* wrapper must declare requires [time] or the checker rejects it.            *)
let test_g10_capability_missing_declaration () =
  let src = prelude ^
    "import Tesl.Time exposing [time, nowMillis, PosixMillis]\n" ^
    "fn getTime() -> PosixMillis requires [time] = nowMillis()\n" ^
    "fn wrapper() -> PosixMillis = getTime()\n" in
  should_fail "requires.*time\\|time.*requires\\|V001" src

(* ── G11: Case branch type mismatch is caught ───────────────────────────── *)
(*                                                                              *)
(* Different arms returning different types is a compile error.               *)
let test_g11_case_branch_type_mismatch () =
  let src = prelude ^
    "fn test(n: Int) -> Int =\n" ^
    "  case n of\n" ^
    "    0 -> 0\n" ^
    "    other -> \"not zero\"\n" in
  should_fail "cannot unify\\|String\\|Int\\|T001" src

(* ── G12: if/then/else branch type mismatch is caught ───────────────────── *)
(*                                                                              *)
(* Then branch is Int, else branch is String — should be caught.              *)
let test_g12_if_branch_type_mismatch () =
  let src = prelude ^
    "fn test(b: Bool) -> Int =\n" ^
    "  if b then\n" ^
    "    42\n" ^
    "  else\n" ^
    "    \"not an int\"\n" in
  should_fail "cannot unify\\|String\\|Int\\|T001" src

(* ── G13: Record construction with unknown field gives clear error ────────── *)
(*                                                                              *)
(* MyRec { name: "t", wrongField: 42 } — wrongField doesn't exist.          *)
let test_g13_record_unknown_field_error () =
  let src = prelude ^
    "record MyRec {\n" ^
    "  name: String\n" ^
    "  value: Int\n" ^
    "}\n" ^
    "fn bad() -> MyRec = MyRec { name: \"t\", wrongField: 42 }\n" in
  should_fail "no field\\|wrongField\\|MyRec\\|T001" src

(* ── G14: Record construction with missing field gives clear error ────────── *)
(*                                                                              *)
(* MyRec { name: "t" } without required value field.                         *)
let test_g14_record_missing_field_error () =
  let src = prelude ^
    "record MyRec {\n" ^
    "  name: String\n" ^
    "  value: Int\n" ^
    "}\n" ^
    "fn bad() -> MyRec = MyRec { name: \"t\" }\n" in
  should_fail "missing.*field\\|value\\|T001" src

(* ── G15: List with heterogeneous element types gives clear error ────────── *)
(*                                                                              *)
(* [1, 2, "three"] — mixed Int and String elements.                          *)
let test_g15_heterogeneous_list_type_error () =
  let src = prelude ^
    "fn bad() -> List Int = [1, 2, \"three\"]\n" in
  should_fail "cannot unify\\|String\\|Int\\|T001" src

(* ── G16: Cross-subject multi-param proof confusion is caught ─────────────── *)
(*                                                                              *)
(* `checkLessThan x y` gives `x ::: LessThan x y`. Passing checked to a       *)
(* function that needs `LessThan a x` (wrong second subject) is rejected.      *)
let test_g16_multiparams_cross_subject_caught () =
  let src = prelude ^
    "fact LessThan (a: Int) (b: Int)\n" ^
    "check checkLT(a: Int, b: Int) -> a: Int ::: LessThan a b =\n" ^
    "  if a < b then\n" ^
    "    ok a ::: LessThan a b\n" ^
    "  else\n" ^
    "    fail 400 \"not less\"\n" ^
    "fn needsLT(a: Int ::: LessThan a b, b: Int) -> Int = a\n" ^
    "fn badSwitch(x: Int, y: Int) -> Int =\n" ^
    "  let checked = checkLT x y\n" ^
    (* passing x (not y) as second arg — mismatches LessThan checked y *)
    "  needsLT checked x\n" in
  should_fail "does not statically satisfy\\|LessThan\\|V001" src

(* ── G17: Newtype nominal safety: UserId ≠ ProjectId ─────────────────────── *)
(*                                                                              *)
(* Two newtypes over String must be statically distinct.                       *)
let test_g17_newtype_nominal_distinct () =
  let src = prelude ^
    "type UserId = String\n" ^
    "type ProjectId = String\n" ^
    "fn needsProject(id: ProjectId) -> String = id.value\n" ^
    "fn confuse(uid: UserId) -> String = needsProject uid\n" in
  should_fail "cannot unify\\|UserId\\|ProjectId\\|T001" src

(* ── G18: forgetFact then re-establish: compiles; subject tracked at use ──── *)
(*                                                                              *)
(* After forgetFact, attaching a proof from establish compiles.                *)
(* But passing the result to a proof-requiring function works if the establish  *)
(* proof is about the same subject — establish is the trusted boundary.        *)
let test_g18_forgetFact_reestablish_compiles () =
  (* Build a fresh prelude with forgetFact included so imports precede definitions *)
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact, forgetFact]\n" ^
    "import Tesl.Maybe exposing [Maybe(..)]\n" ^
    "fact IsPositive (n: Int)\n" ^
    "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n" ^
    "establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n\n" ^
    "fn bypass(x: Int) -> Int =\n" ^
    "  let checked = check checkPos x\n" ^
    "  let forgotten = forgetFact checked\n" ^
    "  let fakeProof = provePos forgotten\n" ^
    (* The proof is about forgotten's subject which is the same as x's subject *)
    "  needsPositive (forgotten ::: fakeProof)\n" in
  (* This compiles — establish is trusted boundary by design *)
  should_pass src

(* ── G19: LSP type-at-json returns null for in-function positions ──────────── *)
(*                                                                               *)
(* Checking the `type-at-json` endpoint: it returns null for many positions.    *)
(* The coverage of type information via the LSP is incomplete.                  *)
let test_g19_lsp_type_at_returns_null () =
  let tmp = Filename.temp_file "tesl-r30-lsp" ".tesl" in
  let oc = open_out tmp in
  output_string oc (prelude ^ "fn add(x: Int, y: Int) -> Int = x + y\n");
  close_out oc;
  (* Use the correct subcommand: main.exe uses --type-at-json, wrapper uses type-at-json *)
  let type_at_subcmd =
    if Filename.basename tesl = "main.exe" then "--type-at-json" else "type-at-json"
  in
  let ic = Unix.open_process_in
    (Printf.sprintf "%s %s %s 5 9 2>&1" tesl type_at_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  (* x is at line 5 col 9 — type-at returns null for many expression positions *)
  let is_null =
    let re = Str.regexp "\"type_at\":null" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  (* document: type-at returns null in many positions (LSP coverage gap) *)
  check bool "type-at-json returns null for function parameter position" true is_null

(* ── G20: String interpolation of ADT type now rejected ──────────────────── *)
(*                                                                             *)
(* "color: ${c}" where c is a Color ADT is now rejected at static check       *)
(* time with a clear message about unsupported interpolation types.           *)
let test_g20_adt_interpolation_compiles () =
  let src = prelude ^
    "type Color\n" ^
    "  = Red\n" ^
    "  | Green\n" ^
    "  | Blue\n" ^
    "fn showColor(c: Color) -> String = \"color: ${c}\"\n" in
  should_fail "cannot interpolate" src

(* ── G21: fn binding return proof now validated by static checker ──────── *)
(*                                                                             *)
(* A `fn` with `-> n: Int ::: IsPositive n` where the tail is just `n`       *)
(* (no proof established) is now rejected at compile time.                   *)
let test_g21_fn_binding_return_proof_not_statically_checked () =
  let src = proof_prelude ^
    "fn liar(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  n\n" in
  should_fail "cannot declare a proof return type\\|fn.*proof return" src

(* ── G22: Record update proof annotation now enforced ──────────────────────── *)
(*                                                                               *)
(* Record update `{ p | bio = newBio }` where bio has `IsTrimmed bio`          *)
(* now requires newBio to carry IsTrimmed. The soundness gap is fixed.         *)
let test_g22_record_update_soundness_gap () =
  let src = prelude ^
    "import Tesl.String exposing [String.length]\n" ^
    "fact IsTrimmed (s: String)\n" ^
    "check checkTrimmed(s: String) -> s: String ::: IsTrimmed s =\n" ^
    "  if String.length s > 0 then\n" ^
    "    ok s ::: IsTrimmed s\n" ^
    "  else\n" ^
    "    fail 400 \"empty\"\n" ^
    "record Profile {\n" ^
    "  name: String\n" ^
    "  bio: String ::: IsTrimmed bio\n" ^
    "}\n" ^
    "fn needsTrimmedBio(bio: String ::: IsTrimmed bio) -> String = bio\n" ^
    "fn updateBioUnsafe(p: Profile, newBio: String) -> Profile =\n" ^
    "  { p | bio = newBio }\n" ^
    "fn getAndCheck(p: Profile, newBio: String) -> String =\n" ^
    "  let updated = updateBioUnsafe p newBio\n" ^
    (* field read from updated record has no tracked proof subject *)
    "  needsTrimmedBio updated.bio\n" in
  should_fail "V001\\|does not satisfy\\|does not statically satisfy\\|proof" src

(* ── G23: Duplicate fact declaration is rejected ───────────────────────────── *)
(*                                                                               *)
(* Declaring the same fact name twice should be a compile-time error.           *)
let test_g23_duplicate_fact_rejected () =
  let src = prelude ^
    "fact DuplicateFact (n: Int)\n" ^
    "fact DuplicateFact (n: Int)\n" in
  should_fail "duplicate\\|DuplicateFact\\|V001" src

(* ── G24: import ordering: import after definition gives clear error ──────── *)
(*                                                                              *)
(* The spec requires all imports before any definitions.                        *)
let test_g24_import_after_definition_rejected () =
  let src = prelude ^
    "fn f() -> Int = 0\n" ^
    "import Tesl.String exposing [String.length]\n" in
  should_fail "import.*before\\|import.*after\\|E000" src

(* ── G25: Undefined function gives clear type error ─────────────────────── *)
(*                                                                              *)
(* Calling a non-existent function should give a clear error.                 *)
let test_g25_undefined_function_clear_error () =
  let src = prelude ^
    "fn test() -> Int = nonExistentFn 42\n" in
  should_fail "unknown name\\|nonExistentFn\\|T001" src

(* ── G26: Too many arguments gives clear arity error ────────────────────── *)
(*                                                                              *)
(* `oneArg 1 2` where oneArg takes exactly one argument.                      *)
let test_g26_too_many_args_arity_error () =
  let src = prelude ^
    "fn oneArg(x: Int) -> Int = x\n" ^
    "fn bad() -> Int = oneArg 1 2\n" in
  should_fail "1 argument\\|2\\|T001" src

(* ── G27: % operator requires IsNonZero proof on right operand ──────────── *)
(*                                                                              *)
(* Using `a % b` without proof on b should give a safety error.               *)
let test_g27_modulo_requires_nonzero () =
  let src = prelude ^
    "fn badMod(a: Int, b: Int) -> Int = a % b\n" in
  should_fail "IsNonZero\\|division.*crash\\|V001\\|nonzero" src

(* ── G28: establish cannot use fail — correctly rejected ─────────────────── *)
(*                                                                              *)
(* Using `fail` inside an `establish` body is a compile error.                *)
let test_g28_establish_fail_rejected () =
  let src = prelude ^
    "fact IsOk (n: Int)\n" ^
    "establish bad(n: Int) -> Fact (IsOk n) =\n" ^
    "  fail 400 \"no\"\n" in
  should_fail "establish.*fail\\|fail.*establish\\|P001" src

(* ── G29: ForAll proof stripped after List.map — rejected at call site ────── *)
(*                                                                               *)
(* A `List Int ::: ForAll IsPositive xs` passed through `List.map doubleIt`    *)
(* loses the ForAll annotation; the result cannot be passed to a ForAll-       *)
(* requiring function.                                                          *)
let test_g29_forall_stripped_by_map () =
  (* Build fresh source with imports before all definitions *)
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n" ^
    "import Tesl.Maybe exposing [Maybe(..)]\n" ^
    "import Tesl.List exposing [List.map, List.length]\n" ^
    "fact IsPositive (n: Int)\n" ^
    "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n" ^
    "fn doubleIt(n: Int) -> Int = n + n\n" ^
    "fn needsForAll(xs: List Int ::: ForAll IsPositive xs) -> Int = List.length xs\n" ^
    "fn mapForAll(xs: List Int ::: ForAll IsPositive xs) -> Int =\n" ^
    "  let doubled = List.map doubleIt xs\n" ^
    "  needsForAll doubled\n" in
  should_fail "does not statically satisfy\\|ForAll\\|V001" src

(* ── G30: explicit check call syntax also works with paren-style single arg ── *)
(*                                                                              *)
(* Check functions still require the `check` keyword, but the single argument   *)
(* may be written with parens after the function name. Multi-arg legacy paren   *)
(* calls remain rejected.                                                       *)
let test_g30_paren_single_arg_accepted () =
  let src = proof_prelude ^
    "fn test(x: Int) -> Int =\n" ^
    "  let r = check checkPos(x)\n" ^
    "  r\n" in
  should_pass src

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Review30" [
    "G01", [ test_case "fn binding return proof now rejected by static checker" `Quick test_g01_fn_binding_return_proof_trusted ];
    "G02", [ test_case "record update now enforces field proof annotation" `Quick test_g02_record_update_bypasses_field_proof ];
    "G03", [ test_case "inline check call loses proof subject — good error" `Quick test_g03_inline_check_call_loses_subject ];
    "G04", [ test_case "ForAll with wrong subject type gives error" `Quick test_g04_forall_wrong_subject_type_error ];
    "G05", [ test_case "partial apply with literal to proof param rejected" `Quick test_g05_partial_apply_literal_proof_arg_rejected ];
    "G06", [ test_case "mutual recursion compiles without error" `Quick test_g06_mutual_recursion_compiles ];
    "G07", [ test_case "circular toplevel bindings now rejected (cycle check)" `Quick test_g07_circular_toplevel_bindings_no_error ];
    "G08", [ test_case "ADT same-named constructor rejected" `Quick test_g08_adt_same_name_constructor_rejected ];
    "G09", [ test_case "establish with fail is rejected" `Quick test_g09_establish_fail_rejected ];
    "G10", [ test_case "capability missing declaration caught" `Quick test_g10_capability_missing_declaration ];
    "G11", [ test_case "case branch type mismatch caught" `Quick test_g11_case_branch_type_mismatch ];
    "G12", [ test_case "if/else branch type mismatch caught" `Quick test_g12_if_branch_type_mismatch ];
    "G13", [ test_case "record unknown field gives clear error" `Quick test_g13_record_unknown_field_error ];
    "G14", [ test_case "record missing field gives clear error" `Quick test_g14_record_missing_field_error ];
    "G15", [ test_case "heterogeneous list element type error" `Quick test_g15_heterogeneous_list_type_error ];
    "G16", [ test_case "multi-param cross-subject proof confusion caught" `Quick test_g16_multiparams_cross_subject_caught ];
    "G17", [ test_case "newtype nominal distinct: UserId != ProjectId" `Quick test_g17_newtype_nominal_distinct ];
    "G18", [ test_case "forgetFact + reestablish compiles (establish is trusted boundary)" `Quick test_g18_forgetFact_reestablish_compiles ];
    "G19", [ test_case "LSP type-at returns null for many positions (coverage gap)" `Quick test_g19_lsp_type_at_returns_null ];
    "G20", [ test_case "ADT interpolation in string now rejected" `Quick test_g20_adt_interpolation_compiles ];
    "G21", [ test_case "fn binding return proof now statically validated" `Quick test_g21_fn_binding_return_proof_not_statically_checked ];
    "G22", [ test_case "record update proof annotation now enforced" `Quick test_g22_record_update_soundness_gap ];
    "G23", [ test_case "duplicate fact declaration rejected" `Quick test_g23_duplicate_fact_rejected ];
    "G24", [ test_case "import after definition rejected" `Quick test_g24_import_after_definition_rejected ];
    "G25", [ test_case "undefined function gives clear error" `Quick test_g25_undefined_function_clear_error ];
    "G26", [ test_case "too many arguments gives arity error" `Quick test_g26_too_many_args_arity_error ];
    "G27", [ test_case "% operator requires IsNonZero proof" `Quick test_g27_modulo_requires_nonzero ];
    "G28", [ test_case "establish with fail rejected" `Quick test_g28_establish_fail_rejected ];
    "G29", [ test_case "ForAll stripped by List.map — call site rejection" `Quick test_g29_forall_stripped_by_map ];
    "G30", [ test_case "paren single-arg call f(x) accepted" `Quick test_g30_paren_single_arg_accepted ];
  ]
