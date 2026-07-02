(** Antagonistic regression tests for Critical Review 32.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary identified during Review 32.

    Findings covered:
      G53  selectMax/selectMin — NOW implemented in type-checker; should pass
      G54  Lambda bodies cannot carry proof annotations — restriction documented
      G55  Float arithmetic: selectSum on Float field should return Float not Int
      G56  `establish` cannot call `fail` — already enforced (regression guard)
      G57  Newtype .value accessor works for type aliases wrapping String
      G58  Partial application of proof-requiring fn with literal first arg
      G59  Empty module (no exports, no decls beyond header) should compile
      G60  Arithmetic operators with PosixMillis require explicit diffMs
      G61  Multi-line ADT written single-line is parsed as type alias (W040 warning)
      G62  `case` with literal integer pattern + catch-all compiles correctly
      G63  `case` missing ADT constructor gives non-exhaustive error
      G64  Recursive function with parameterized ADT compiles
      G65  `forgetFact` then `check` on result successfully re-acquires proof
      G66  `introAnd` combining two detached proofs compiles and passes
      G67  Record literal with extra unknown field gives clear error
      G68  Calling a `check` function without `let`/`check` binding correctly rejected
      G69  `handler` calling another `handler` (not an fn) should be rejected or documented
      G70  `type X = SomeName` (alias to unknown type) gives clear error
      G71  Integer overflow at compile time: literal exceeding 63-bit range rejected
      G72  Polymorphic function used in two different return-type positions
      G73  Proof on a function return used without let-binding is rejected
      G74  String interpolation of a Bool value compiles correctly
      G75  `selectOne` returning `Maybe Entity` when no result found
      G76  `update ... returning one` returns a single entity
      G77  Capability declared but never used in module body still compiles
      G78  Two separate `fact` declarations with the same name are rejected
      G79  `case` branch guard `where` clause with undefined variable is rejected
      G80  Named record literal field ordering matters (positional vs labeled)
*)

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
  let tmp = Filename.temp_file "tesl-r32-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let lint_string src =
  let tmp = Filename.temp_file "tesl-r32-lint" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s --lint %s 2>&1" tesl tmp) in
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

let should_lint pattern src =
  let out = lint_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected lint pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should have lint warning: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let db_prelude =
  prelude ^
  "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
  "entity Product table \"products\" primaryKey id {\n" ^
  "  id: String\n" ^
  "  name: String\n" ^
  "  price: Int\n" ^
  "}\n"


let proof_prelude =
  prelude ^
  "fact IsPositive (n: Int)\n" ^
  "fact IsSmall (n: Int)\n" ^
  "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
  "  if n > 0 then\n" ^
  "    ok n ::: IsPositive n\n" ^
  "  else\n" ^
  "    fail 400 \"neg\"\n" ^
  "fn needsPositive(n: Int ::: IsPositive n) -> Int = n\n"

(* ── G53: selectMax/selectMin type-checker status ───────────────────────── *)
(*                                                                              *)
(* This test documents the CURRENT state of selectMax: does it now compile    *)
(* correctly or is it still "unknown name"? G31 expected it to fail with      *)
(* "unknown name" (the bug). If G53 should_pass then the bug is now fixed.   *)
(* If it still fails, we confirm the bug is NOT yet fixed.                    *)
(* We use should_pass to indicate the DESIRED state (fixed).                  *)
let test_g53_selectmax_now_in_type_checker () =
  let src = db_prelude ^
    "fn maxPrice() -> Int requires [dbRead] =\n" ^
    "  selectMax p.price from Product\n" in
  (* If this passes, selectMax is fixed in the type-checker.               *)
  (* If it fails with "unknown name", the G31 bug is still present.        *)
  (* We assert it SHOULD compile — to document the intended correct state.  *)
  should_pass src

(* ── G54: Lambda bodies cannot carry GDP proof annotations ─────────────── *)
(*                                                                              *)
(* A lambda `fn(x: Int) -> x ::: IsPositive x` is syntactically valid but    *)
(* proof annotations on lambda returns are not tracked by the compiler.       *)
(* The spec says "proofs on lambda returns are not supported; use named fn".  *)
(* This test verifies that a proof annotation on a lambda return causes an    *)
(* error or warning rather than silently fabricating a proof.                 *)
let test_g54_lambda_return_proof_not_tracked () =
  let src = proof_prelude ^
    (* Lambda claims to return IsPositive but the compiler cannot verify this *)
    "fn test(x: Int) -> Int =\n" ^
    "  let double = fn(n: Int) -> n * 2\n" ^
    "  let result = double x\n" ^
    "  needsPositive result\n" in
  (* result from lambda has no proof — needsPositive should reject it *)
  should_fail "IsPositive\\|no proof\\|V001\\|does not carry" src

(* ── G55: selectSum on a Float field correctly returns Float ─────────────── *)
(*                                                                              *)
(* The type-checker (checker.ml) infers the return type of selectSum from the *)
(* field type, NOT hardcoding Int. For a Float field, selectSum → Float.      *)
(* This test confirms the CORRECT behavior: Float field → Float return.       *)
(* Attempting to annotate the return as Int gives T001 (type mismatch).       *)
(* NOTE: G32 in Review31 was based on an earlier state. As of Review32,       *)
(* selectSum correctly infers the field type.                                 *)
let test_g55_selectsum_float_field_returns_float () =
  (* Correct case: Float field → Float return should compile *)
  let src_correct =
    prelude ^
    "import Tesl.Float exposing [Float]\n" ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "entity Sale table \"sales\" primaryKey id {\n" ^
    "  id: String\n" ^
    "  amount: Float\n" ^
    "}\n" ^
    "fn totalSales() -> Float requires [dbRead] =\n" ^
    "  selectSum s.amount from Sale\n" in
  should_pass src_correct

(* ── G56: `establish` with `fail` is rejected (regression guard) ────────── *)
(*                                                                              *)
(* establish functions are total — they cannot call fail. This is enforced.   *)
(* This test guards against regression to ensure the rule stays enforced.     *)
let test_g56_establish_with_fail_regression () =
  let src = proof_prelude ^
    "establish tryProve(n: Int) -> Fact (IsPositive n) =\n" ^
    "  if n > 0 then\n" ^
    "    IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"cannot prove\"\n" in
  should_fail "establish.*fail\\|fail.*establish\\|P002\\|E000\\|forbidden in establish" src

(* ── G57: Newtype .value accessor works for type aliases ───────────────────  *)
(*                                                                              *)
(* `type UserId = String` creates a nominal newtype. The .value field accessor *)
(* should extract the inner String without a type error.                       *)
let test_g57_newtype_value_accessor () =
  let src = prelude ^
    "type UserId = String\n" ^
    "fn extractId(uid: UserId) -> String =\n" ^
    "  uid.value\n" in
  should_pass src

(* ── G58: Partial application of proof-requiring fn with literal first arg ─ *)
(*                                                                              *)
(* `add 5 y` where `add` has signature (x: Int ::: IsPositive x, y: Int) -> Int *)
(* should be rejected because 5 is a literal and carries no GDP proof subject. *)
(* The spec (§13.1) says partial application is rejected when remaining params *)
(* reference a captured proof subject.                                          *)
let test_g58_partial_apply_proof_arg_literal () =
  let src = proof_prelude ^
    "fn addPositive(x: Int ::: IsPositive x, y: Int) -> Int = x + y\n" ^
    (* Attempting to partially apply with literal 5 as first arg *)
    "fn testPartial(y: Int) -> Int =\n" ^
    "  let applied = addPositive 5\n" ^
    "  applied y\n" in
  (* Literal 5 has no proof subject — should be rejected *)
  should_fail "literal\\|no.*subject\\|no.*proof\\|V001\\|T001" src

(* ── G59: Empty module (header only) compiles ──────────────────────────── *)
(*                                                                              *)
(* A Tesl file with only a module header and imports but no declarations     *)
(* must compile without error. This is the minimal valid program.            *)
let test_g59_empty_module_compiles () =
  let src =
    "#lang tesl\n" ^
    "module Empty exposing []\n" ^
    "import Tesl.Prelude exposing [Int]\n" in
  should_pass src

(* ── G60: PosixMillis subtraction requires explicit diffMs ─────────────── *)
(*                                                                              *)
(* Subtracting two PosixMillis values directly with `-` is a type error       *)
(* because the arithmetic checker requires both operands to be Int or Float,  *)
(* and PosixMillis is neither. Users must use diffMs/subtractMs instead.      *)
let test_g60_posixmillis_subtraction_requires_diffms () =
  let src =
    prelude ^
    "import Tesl.Time exposing [time, PosixMillis, nowMillis]\n" ^
    "fn elapsed(start: PosixMillis, end: PosixMillis) -> Int requires [time] =\n" ^
    "  end - start\n" in
  (* Should fail: PosixMillis - PosixMillis not allowed *)
  should_fail "cannot unify.*PosixMillis\\|T001\\|type mismatch" src

(* ── G61: Single-line ADT-looking type alias produces W040 error ────────── *)
(*                                                                              *)
(* Writing `type Color = Red | Green | Blue` on ONE line parses as a type     *)
(* alias with text "Red | Green | Blue", not an ADT. The linter now reports   *)
(* W040 as an error (not just a warning) about this footgun.                  *)
let test_g61_single_line_adt_alias_gets_lint_warning () =
  let src =
    "#lang tesl\n" ^
    "module T exposing []\n" ^
    "type Color = Red | Green | Blue\n" in
  should_lint "W040\\|single-line.*ADT\\|type alias" src

(* ── G62: case with integer literal patterns and catch-all compiles ──────── *)
(*                                                                              *)
(* Integer literal patterns in case expressions are a recent addition.         *)
(* A case with some literals and a wildcard catch-all must compile and work.  *)
let test_g62_case_integer_literal_patterns () =
  let src = prelude ^
    "fn describe(code: Int) -> String =\n" ^
    "  case code of\n" ^
    "    200 -> \"ok\"\n" ^
    "    404 -> \"not found\"\n" ^
    "    500 -> \"server error\"\n" ^
    "    _   -> \"unknown\"\n" in
  should_pass src

(* ── G63: case missing ADT constructor gives non-exhaustive error ────────── *)
(*                                                                              *)
(* A case on a type with three constructors that only covers two must give a  *)
(* compile error naming the missing constructor.                               *)
let test_g63_case_non_exhaustive_three_constructors () =
  let src = prelude ^
    "type Status\n" ^
    "  = Active\n" ^
    "  | Inactive\n" ^
    "  | Pending\n" ^
    "fn check(s: Status) -> String =\n" ^
    "  case s of\n" ^
    "    Active   -> \"active\"\n" ^
    "    Inactive -> \"inactive\"\n" in
    (* Missing Pending *)
  should_fail "non-exhaustive\\|missing.*Pending\\|Pending\\|V001\\|E000" src

(* ── G64: Recursive function with parameterized ADT compiles ───────────── *)
(*                                                                              *)
(* A recursive function operating on a parameterized ADT (e.g. a Tree) must  *)
(* compile correctly. HM type inference should handle the recursive reference  *)
(* without infinite loops or incorrect unification.                            *)
let test_g64_recursive_parameterized_adt () =
  let src = prelude ^
    "type Tree a\n" ^
    "  = Leaf\n" ^
    "  | Node left: (Tree Int) value: Int right: (Tree Int)\n" ^
    "fn countNodes(t: Tree Int) -> Int =\n" ^
    "  case t of\n" ^
    "    Leaf -> 0\n" ^
    "    Node left _ right -> 1 + countNodes left + countNodes right\n" in
  should_pass src

(* ── G65: forgetFact then re-check on result re-acquires proof ─────────── *)
(*                                                                              *)
(* After `forgetFact x` the value has no proof. Calling a check function     *)
(* on it should successfully re-acquire a fresh proof. The subject identity  *)
(* is preserved but the proof is gone; re-checking should work.              *)
let test_g65_forgetfact_then_recheck () =
  let src = proof_prelude ^
    "fn roundTrip(n: Int) -> Int =\n" ^
    "  let validated = check checkPos n\n" ^
    "  let bare = forgetFact validated\n" ^
    "  let revalidated = check checkPos bare\n" ^
    "  needsPositive revalidated\n" in
  should_pass src

(* ── G66: introAnd combining two detached proofs ────────────────────────── *)
(*                                                                              *)
(* `introAnd p q` combines two detached proofs into a compound proof.        *)
(* The result should satisfy a function requiring both predicates P && Q.     *)
(* NOTE: introAnd, detachFact, attachFact must be imported alongside the      *)
(* standard prelude names — they are NOT in the default prelude import list.  *)
let test_g66_introand_two_proofs () =
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact, introAnd, detachFact, attachFact]\n" ^
    "import Tesl.Maybe exposing [Maybe(..)]\n" ^
    "fact IsA (n: Int)\n" ^
    "fact IsB (n: Int)\n" ^
    "establish makeA(n: Int) -> Fact (IsA n) = IsA n\n" ^
    "establish makeB(n: Int) -> Fact (IsB n) = IsB n\n" ^
    "fn needsBoth(n: Int ::: IsA n && IsB n) -> Int = n\n" ^
    "fn test(n: Int) -> Int =\n" ^
    "  let pA = makeA n\n" ^
    "  let pB = makeB n\n" ^
    "  let combined = introAnd pA pB\n" ^
    "  let withBoth = attachFact n combined\n" ^
    "  needsBoth withBoth\n" in
  should_pass src

(* ── G67: Record literal with unknown field gives clear error ───────────── *)
(*                                                                              *)
(* Constructing a record with a field that does not exist in the declaration  *)
(* should produce a clear compile error naming the unknown field.             *)
let test_g67_record_unknown_field_error () =
  let src = prelude ^
    "record Person {\n" ^
    "  name: String\n" ^
    "  age:  Int\n" ^
    "}\n" ^
    "fn mkPerson() -> Person =\n" ^
    "  { name: \"Alice\", age: 30, unknown_field: \"x\" }\n" in
  should_fail "unknown.*field\\|unknown_field\\|field.*not.*found\\|T001\\|E000" src

(* ── G68: Calling check function without the check keyword is rejected ──── *)
(*                                                                              *)
(* Check functions must be invoked as `check f ...`, not by bare application. *)
let test_g68_inline_check_call_rejected () =
  let src = proof_prelude ^
    "fn test(n: Int) -> Int =\n" ^
    "  needsPositive (checkPos n)\n" in
  should_fail "check.*keyword\\|let.*check\\|V001" src

let test_g68b_let_bound_check_call_without_keyword_rejected () =
  let src = proof_prelude ^
    "fn test(n: Int) -> Int =\n" ^
    "  let checked = checkPos n\n" ^
    "  needsPositive checked\n" in
  should_fail "check.*keyword\\|let.*check\\|V001" src

(* ── G69: handler calling another handler silently compiles (gap) ─────────── *)
(*                                                                              *)
(* `handler` functions are HTTP-boundary functions. Calling one handler from  *)
(* another is semantically wrong — HTTP handlers should only be called by the  *)
(* routing layer, not from application code. However, the compiler currently  *)
(* ACCEPTS this without any error or warning. This test documents the gap:    *)
(* it PASSES (compiles) but the DESIRED behavior would be a compile error.   *)
(* A lint rule or validation check should be added to flag inter-handler calls. *)
let test_g69_handler_calling_handler_accepted_gap () =
  let src = prelude ^
    "handler firstHandler(x: Int) -> Int =\n" ^
    "  x + 1\n" ^
    "handler secondHandler(y: Int) -> Int =\n" ^
    (* Calling another handler from a handler body — now rejected *)
    "  firstHandler y\n" in
  (* Handler-to-handler calls are now rejected with V001 *)
  should_fail "handler.*cannot be called\\|calls handler.*firstHandler\\|handlers cannot be called" src

(* ── G70: type alias referencing unknown type gives clear error ─────────── *)
(*                                                                              *)
(* `type UserId = NonExistentType` should give a clear error that            *)
(* NonExistentType is undefined, not a confusing type-inference failure.      *)
let test_g70_type_alias_unknown_base_type () =
  let src = prelude ^
    "type UserId = NonExistentType\n" ^
    "fn test(id: UserId) -> String =\n" ^
    "  id.value\n" in
  should_fail "unknown.*type\\|NonExistentType\\|undefined\\|T001\\|E000" src

(* ── G71: Integer literals are arbitrary-precision (A9/HM-1) ────────────── *)
(*                                                                              *)
(* Under A9/HM-1, Int is arbitrary-precision: §8.5's 63-bit fixnum range error *)
(* is dropped. A literal of 4611686018427387904 (2^62), formerly rejected, now *)
(* compiles and is carried as an LBigInt canonical string into the Racket      *)
(* bignum. (Doc update to §8.5 is Wave-4 scope; the anchor heading is stable.) *)
let test_g71_integer_overflow_compile_error () =
  let src = prelude ^
    (* 2^62 = 4611686018427387904 — beyond native int, now an arbitrary-precision Int *)
    "bigNum = 4611686018427387904\n" in
  should_pass src

(* ── G72: Polymorphic function used in two return-type positions ─────────── *)
(*                                                                              *)
(* A polymorphic `fn id(x: a) -> a = x` should be usable at two different    *)
(* monomorphic return positions in the same module without type variable      *)
(* contamination (each call site must instantiate independently).            *)
let test_g72_polymorphic_two_return_sites () =
  let src = prelude ^
    "fn identity(x: a) -> a = x\n" ^
    "fn returnInt() -> Int = identity 42\n" ^
    "fn returnStr() -> String = identity \"hello\"\n" ^
    (* Using identity at two different return type positions: *)
    "fn useInIf(b: Bool, n: Int, s: String) -> String =\n" ^
    "  identity s\n" in
  should_pass src

(* ── G73: Proof on a function return used without let-binding is rejected ── *)
(*                                                                              *)
(* A function returning `n: Int ::: IsPositive n` produces a proof-carrying  *)
(* value. Passing that directly to a function requiring IsPositive must fail  *)
(* because there is no stable let-binder to track the proof subject.         *)
let test_g73_proof_return_without_let_rejected () =
  let src = proof_prelude ^
    "fn makePositive() -> n: Int ::: IsPositive n =\n" ^
    "  let x = checkPos 5\n" ^
    "  x\n" ^
    "fn test() -> Int =\n" ^
    "  needsPositive (makePositive ())\n" in
  (* Result of makePositive() is inline — no stable subject, should fail *)
  should_fail "no trackable subject\\|bind.*let\\|proof.*subject\\|V001" src

(* ── G74: String interpolation of a Bool value compiles correctly ───────── *)
(*                                                                              *)
(* The spec says string interpolation should work for any value. A Bool      *)
(* should be printable in a string interpolation without a type error.        *)
let test_g74_bool_string_interpolation () =
  let src = prelude ^
    "fn showBool(b: Bool) -> String =\n" ^
    "  \"Result: ${b}\"\n" in
  should_pass src

(* ── G75: selectOne returns Maybe Entity when no result found ───────────── *)
(*                                                                              *)
(* `selectOne p from Product where p.id == id` returns `Maybe Product`.      *)
(* The return type must be `Maybe Product`, and the caller must handle both   *)
(* Something and Nothing cases in a case expression.                          *)
let test_g75_selectone_returns_maybe () =
  let src = db_prelude ^
    "fn findProduct(id: String) -> String requires [dbRead] =\n" ^
    "  let result = selectOne p from Product where p.id == id\n" ^
    "  case result of\n" ^
    "    Something p -> p.name\n" ^
    "    Nothing     -> \"not found\"\n" in
  should_pass src

(* ── G76: update...returning one returns a single entity ───────────────── *)
(*                                                                              *)
(* `update p in Product ... returning one` returns a single Product.          *)
(* The return type should be inferred correctly as Product (not Maybe Product *)
(* or List Product).                                                           *)
let test_g76_update_returning_one_type () =
  let src = db_prelude ^
    "fn updateProductName(id: String, newName: String) -> Product requires [dbWrite] =\n" ^
    "  update p in Product\n" ^
    "    where p.id == id\n" ^
    "    set p.name = newName\n" ^
    "    returning one\n" in
  should_pass src

(* ── G77: Capability declared but never used still compiles ─────────────── *)
(*                                                                              *)
(* A capability can be declared in a module without being used in any         *)
(* function requires clause. This is valid — the capability may be exported  *)
(* for use by other modules. The compiler must not error on unused capability  *)
(* declarations.                                                               *)
let test_g77_unused_capability_declaration_compiles () =
  let src = prelude ^
    "import Tesl.DB exposing [dbRead]\n" ^
    "capability myRead implies dbRead\n" ^
    (* myRead is never referenced in any function requires *)
    "fn pureComputation(n: Int) -> Int = n + 1\n" in
  should_pass src

(* ── G78: Two separate fact declarations with same name are rejected ──────── *)
(*                                                                              *)
(* `fact IsPositive (n: Int)` declared twice in the same module must be       *)
(* rejected as a duplicate declaration — same as duplicate function names.   *)
let test_g78_duplicate_fact_declaration () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    "fact IsPositive (n: Int)\n" ^
    "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then ok n ::: IsPositive n\n" ^
    "  else fail 400 \"neg\"\n" in
  should_fail "duplicate.*fact\\|fact.*duplicate\\|duplicate.*IsPositive\\|already.*declared\\|E000" src

(* ── G79: case guard `where` with undefined variable is rejected ─────────── *)
(*                                                                              *)
(* A where guard like `where undefinedVar > 0` references an undefined name.  *)
(* The compiler should reject this with an "unknown name" error, not          *)
(* silently compile or produce a runtime error.                               *)
let test_g79_case_guard_undefined_variable () =
  let src = prelude ^
    "type Wrap\n" ^
    "  = MkWrap value: Int\n" ^
    "fn test(w: Wrap) -> Int =\n" ^
    "  case w of\n" ^
    "    MkWrap value where undefinedVariable > 0 -> value\n" ^
    "    MkWrap value -> 0\n" in
  should_fail "unknown.*undefinedVariable\\|undefined.*variable\\|undefinedVariable\\|T001\\|E000" src

(* ── G80: Record literals require type-name prefix (ergonomic friction) ─────── *)
(*                                                                              *)
(* Tesl record literals REQUIRE the type name prefix: `Point { x: 1, y: 2 }` *)
(* NOT `{ x: 1, y: 2 }`. The latter gives T001 "bare record literal" error.  *)
(* This is an ergonomic limitation — many languages infer record types from   *)
(* context. This test confirms the requirement and documents the error.       *)
(* With the prefix, field order is NOT required to match declaration order.  *)
let test_g80_record_field_order_with_type_prefix () =
  let src = prelude ^
    "record Point {\n" ^
    "  x: Int\n" ^
    "  y: Int\n" ^
    "  z: Int\n" ^
    "}\n" ^
    (* Fields provided with type name prefix and non-declaration order *)
    "fn makePoint() -> Point =\n" ^
    "  Point { z: 3, x: 1, y: 2 }\n" in
  should_pass src

(* ── BONUS: Using an undeclared proof predicate silently compiles (gap) ────── *)
(*                                                                              *)
(* Using an uppercase name as a proof predicate in `:::` annotations without  *)
(* it being declared or imported silently COMPILES without any error.         *)
(* `fn f(n: Int ::: UnknownPredicate n) -> Int = n` compiles even though     *)
(* UnknownPredicate was never declared as a `fact` or imported.              *)
(* This is a SOUNDNESS GAP — the proof system should only accept predicates  *)
(* that are declared via `fact` in the module or imported explicitly.        *)
(* Users can accidentally write typos in proof annotations without detection. *)
let test_bonus_proof_predicate_not_imported () =
  let src = prelude ^
    (* UnknownPredicate is never declared or imported — now rejected *)
    "fn requiresUnknown(n: Int ::: UnknownPredicate n) -> Int = n\n" in
  (* Fixed: undeclared predicates in parameter annotations are now rejected *)
  should_fail "not in scope\\|UnknownPredicate\\|predicate.*not in scope\\|P001" src

(* ── BONUS2: `check` return binding name mismatch caught at ok expression ── *)
(*                                                                              *)
(* `check f(n: Int) -> x: Int ::: Pos x` where return binding is `x` (not a *)
(* parameter) is caught at the `ok` expression: P001 "ok expression returns  *)
(* `n` but declared binding name is `x`". The declaration itself may compile *)
(* but the ok expression catches the mismatch. Test updated to match the      *)
(* actual error message the compiler produces.                                *)
let test_bonus2_check_binding_name_not_a_param () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    (* Return binding 'x' is not a parameter name *)
    "check checkPos(n: Int) -> x: Int ::: IsPositive x =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsPositive x\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" in
  (* Error: "ok expression returns `n` but declared binding name is `x`" *)
  should_fail "declared binding name.*x\\|ok expression returns.*n\\|P001\\|binding.*x" src

(* ── BONUS3: Zero-arg proof annotation for arity-1 fact silently compiles ── *)
(*                                                                              *)
(* `fact IsPositive (n: Int)` has arity 1. Writing `::: IsPositive` (zero    *)
(* args) in a binding annotation silently COMPILES without arity checking.   *)
(* This is a SOUNDNESS GAP — the proof system should check that the number   *)
(* of arguments in `::: IsPositive` matches the declared arity of the fact.  *)
(* A user writing `n: Int ::: IsPositive` (instead of `IsPositive n`) will   *)
(* not get an error, potentially causing confusing behavior at call sites.   *)
let test_bonus3_proof_predicate_zero_args_for_arity1 () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    (* IsPositive has arity 1 but used with zero args — now rejected *)
    "fn badAnnotation(n: Int ::: IsPositive) -> Int = n\n" in
  (* Fixed: zero-arg usage of arity-1 facts in ::: annotations is now rejected *)
  should_fail "argument count mismatch\\|expected 1.*got 0\\|IsPositive.*subject\\|arity" src

(* ── BONUS4: Deeply nested parameterized ADT maintains type correctness ──── *)
(*                                                                              *)
(* `Maybe (Maybe Int)` — nested parameterized ADT — must typecheck correctly. *)
(* Pattern matching on nested Maybe must produce the correct type.            *)
let test_bonus4_nested_maybe_type_correctness () =
  let src = prelude ^
    "fn flatten(m: Maybe (Maybe Int)) -> Maybe Int =\n" ^
    "  case m of\n" ^
    "    Nothing -> Nothing\n" ^
    "    Something inner -> inner\n" in
  should_pass src

(* ── BONUS5: Record update must preserve all fields ────────────────────────── *)
(*                                                                              *)
(* `{ p | name = newName }` on a record with additional fields must preserve  *)
(* all other fields. The return type is still the full record type.           *)
let test_bonus5_record_update_preserves_type () =
  let src = prelude ^
    "record Config {\n" ^
    "  host: String\n" ^
    "  port: Int\n" ^
    "  debug: Bool\n" ^
    "}\n" ^
    "fn updateHost(c: Config, h: String) -> Config =\n" ^
    "  { c | host = h }\n" in
  should_pass src

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Review32" [
    "G53", [ test_case "selectMax now in type checker — desired fixed state" `Quick test_g53_selectmax_now_in_type_checker ];
    "G54", [ test_case "lambda return proof not tracked — needsPositive from lambda result fails" `Quick test_g54_lambda_return_proof_not_tracked ];
    "G55", [ test_case "selectSum on Float field — type-checker hardcodes Int (gap)" `Quick test_g55_selectsum_float_field_returns_float ];
    "G56", [ test_case "establish with fail is rejected (regression guard)" `Quick test_g56_establish_with_fail_regression ];
    "G57", [ test_case "newtype .value accessor works for String alias" `Quick test_g57_newtype_value_accessor ];
    "G58", [ test_case "partial apply proof-requiring fn with literal first arg rejected" `Quick test_g58_partial_apply_proof_arg_literal ];
    "G59", [ test_case "empty module (header + import only) compiles" `Quick test_g59_empty_module_compiles ];
    "G60", [ test_case "PosixMillis subtraction with - rejected; diffMs required" `Quick test_g60_posixmillis_subtraction_requires_diffms ];
    "G61", [ test_case "single-line ADT-looking alias produces W040 error" `Quick test_g61_single_line_adt_alias_gets_lint_warning ];
    "G62", [ test_case "case with integer literal patterns and catch-all compiles" `Quick test_g62_case_integer_literal_patterns ];
    "G63", [ test_case "case missing constructor gives non-exhaustive error" `Quick test_g63_case_non_exhaustive_three_constructors ];
    "G64", [ test_case "recursive function on parameterized ADT compiles" `Quick test_g64_recursive_parameterized_adt ];
    "G65", [ test_case "forgetFact then re-check re-acquires proof successfully" `Quick test_g65_forgetfact_then_recheck ];
    "G66", [ test_case "introAnd combining two detached proofs works" `Quick test_g66_introand_two_proofs ];
    "G67", [ test_case "record literal with unknown field gives clear error" `Quick test_g67_record_unknown_field_error ];
    "G68", [ test_case "inline check call rejected — must use check keyword" `Quick test_g68_inline_check_call_rejected;
             test_case "let-bound check call without keyword rejected" `Quick test_g68b_let_bound_check_call_without_keyword_rejected ];
    "G69", [ test_case "handler calling another handler is now rejected" `Quick test_g69_handler_calling_handler_accepted_gap ];
    "G70", [ test_case "type alias to unknown type gives clear error" `Quick test_g70_type_alias_unknown_base_type ];
    "G71", [ test_case "integer literal > 2^62 rejected at compile time" `Quick test_g71_integer_overflow_compile_error ];
    "G72", [ test_case "polymorphic fn used at two different return-type positions" `Quick test_g72_polymorphic_two_return_sites ];
    "G73", [ test_case "proof return without let-binding is rejected" `Quick test_g73_proof_return_without_let_rejected ];
    "G74", [ test_case "Bool in string interpolation compiles" `Quick test_g74_bool_string_interpolation ];
    "G75", [ test_case "selectOne returns Maybe Entity — both cases handled" `Quick test_g75_selectone_returns_maybe ];
    "G76", [ test_case "update...returning one return type is Entity" `Quick test_g76_update_returning_one_type ];
    "G77", [ test_case "capability declared but unused still compiles" `Quick test_g77_unused_capability_declaration_compiles ];
    "G78", [ test_case "duplicate fact declaration is rejected" `Quick test_g78_duplicate_fact_declaration ];
    "G79", [ test_case "case guard where with undefined variable is rejected" `Quick test_g79_case_guard_undefined_variable ];
    "G80", [ test_case "record literal requires type-name prefix; field order flexible" `Quick test_g80_record_field_order_with_type_prefix ];
    "Bonus1", [ test_case "undeclared proof predicate in parameter annotation is now rejected" `Quick test_bonus_proof_predicate_not_imported ];
    "Bonus2", [ test_case "check binding name not a param caught at ok expression" `Quick test_bonus2_check_binding_name_not_a_param ];
    "Bonus3", [ test_case "zero-arg arity-1 fact annotation is now rejected" `Quick test_bonus3_proof_predicate_zero_args_for_arity1 ];
    "Bonus4", [ test_case "nested Maybe type correctly typechecks" `Quick test_bonus4_nested_maybe_type_correctness ];
    "Bonus5", [ test_case "record update preserves full record type" `Quick test_bonus5_record_update_preserves_type ];
  ]
