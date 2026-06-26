(** Proof system edges and type system edges — Review 74.

    Group PE: Proof system edges (20 tests)
      PE01–PE20 — proof accumulation, ownership, chains, cross-module facts

    Group TE: Type system edges (20 tests)
      TE01–TE20 — type aliases, ADTs, records, newtype, polymorphism *)

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
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let content =
    if String.length content > 0 && content.[0] = '\n'
    then String.sub content 1 (String.length content - 1)
    else content
  in
  let dir = Filename.temp_dir "tesl-qa74b" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let with_two_files a_name a_src b_name b_src f =
  let dir = Filename.temp_dir "tesl-qa74c" "" in
  let path_a = Filename.concat dir (a_name ^ ".tesl") in
  let path_b = Filename.concat dir (b_name ^ ".tesl") in
  let strip s = if String.length s > 0 && s.[0] = '\n' then String.sub s 1 (String.length s - 1) else s in
  let oc_a = open_out path_a in output_string oc_a (strip a_src); close_out oc_a;
  let oc_b = open_out path_b in output_string oc_b (strip b_src); close_out oc_b;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_a with _ -> ());
      (try Sys.remove path_b with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_b)

let two_files_should_pass a_name a_src b_name b_src =
  with_two_files a_name a_src b_name b_src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got:\n%s" out)

let two_files_should_fail pat a_name a_src b_name b_src =
  with_two_files a_name a_src b_name b_src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── PE: Proof system edges ──────────────────────────────────────────────── *)

(* PE01: Sequential proof accumulation — check A then check B on result,
   then call fn requiring BOTH → should_pass *)
let test_PE01_sequential_proof_accumulation () =
  should_pass {|
#lang tesl
module Pe01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"
fn requiresBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn doTest(raw: Int) -> Int =
  let withPos = check checkPos raw
  let withBoth = check checkSmall withPos
  requiresBoth withBoth
|}

(* PE02: check result directly returned (tail position) → should_pass *)
let test_PE02_check_result_tail_position () =
  should_pass {|
#lang tesl
module Pe02 exposing []
import Tesl.Prelude exposing [Int]
fact Validated (n: Int)
check validate(n: Int) -> n: Int ::: Validated n =
  if n > 0 then
    ok n ::: Validated n
  else
    fail 400 "bad"
check wrapValidate(n: Int) -> n: Int ::: Validated n =
  check validate n
|}

(* PE03: call fn requiring proof without having proof → should_fail *)
let test_PE03_call_requiring_proof_without_proof () =
  should_fail "proof\\|not.*statically\\|IsPositive\\|does not" {|
#lang tesl
module Pe03 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fn requiresProof(n: Int ::: IsPositive n) -> Int = n + 1
fn badCaller(raw: Int) -> Int =
  requiresProof raw
|}

(* PE04: Two separate facts on same value accumulate → should_pass *)
let test_PE04_two_facts_same_value_accumulate () =
  should_pass {|
#lang tesl
module Pe04 exposing []
import Tesl.Prelude exposing [Int]
fact IsEven (n: Int)
fact IsLarge (n: Int)
check checkEven(n: Int) -> n: Int ::: IsEven n =
  if n == (n / 2) * 2 then
    ok n ::: IsEven n
  else
    fail 400 "not even"
check checkLarge(n: Int) -> n: Int ::: IsLarge n =
  if n > 1000 then
    ok n ::: IsLarge n
  else
    fail 400 "not large"
fn needsBoth(n: Int ::: IsEven n && IsLarge n) -> Int = n
fn run(raw: Int) -> Int =
  let even = check checkEven raw
  let both = check checkLarge even
  needsBoth both
|}

(* PE05: establish + use proof in same fn → should_pass *)
let test_PE05_establish_and_use_in_same_fn () =
  should_pass {|
#lang tesl
module Pe05 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact Trusted (n: Int)
establish trust(n: Int) -> Fact (Trusted n) =
  Trusted n
fn requiresTrusted(n: Int ::: Trusted n) -> Int = n
fn run(raw: Int) -> Int =
  let pf = trust raw
  requiresTrusted <| raw ::: pf
|}

(* PE06: establish returns proof, chain with check → should_pass *)
let test_PE06_establish_chain_with_check () =
  should_pass {|
#lang tesl
module Pe06 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact InSystem (n: Int)
fact IsPositive (n: Int)
establish admit(n: Int) -> Fact (InSystem n) =
  InSystem n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needsBoth(n: Int ::: InSystem n && IsPositive n) -> Int = n
fn run(raw: Int) -> Int =
  let pf = admit raw
  let withSys = raw ::: pf
  let withBoth = check checkPos withSys
  needsBoth withBoth
|}

(* PE07: Module B imports fact from A and tries to produce it via check
         → should_fail "P001\\|fact ownership" *)
let test_PE07_cannot_produce_imported_fact () =
  two_files_should_fail "P001\\|fact ownership\\|cannot.*establish\\|only.*owner" "pe07-facts"
  {|
#lang tesl
module Pe07Facts exposing [IsValid, checkValid]
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
check checkValid(n: Int) -> n: Int ::: IsValid n =
  if n > 0 then
    ok n ::: IsValid n
  else
    fail 400 "bad"
|}
  "pe07-bad"
  {|
#lang tesl
module Pe07Bad exposing []
import Tesl.Prelude exposing [Int]
import Pe07Facts exposing [IsValid]
check badForgery(n: Int) -> n: Int ::: IsValid n =
  ok n ::: IsValid n
|}

(* PE08: Module B imports fact from A and USES it (doesn't produce) → should_pass *)
let test_PE08_use_imported_fact_without_producing () =
  two_files_should_pass "pe08-facts"
  {|
#lang tesl
module Pe08Facts exposing [IsSafe, checkSafe]
import Tesl.Prelude exposing [Int]
fact IsSafe (n: Int)
check checkSafe(n: Int) -> n: Int ::: IsSafe n =
  if n >= 0 then
    ok n ::: IsSafe n
  else
    fail 400 "unsafe"
|}
  "pe08-user"
  {|
#lang tesl
module Pe08User exposing []
import Tesl.Prelude exposing [Int]
import Pe08Facts exposing [IsSafe, checkSafe]
fn requiresSafe(n: Int ::: IsSafe n) -> Int = n * 2
fn run(raw: Int) -> Int =
  let safe = check checkSafe raw
  requiresSafe safe
|}

(* PE09: check fn where proof param requires the same fact the fn declares → should_pass *)
let test_PE09_check_requires_and_returns_same_fact () =
  should_pass {|
#lang tesl
module Pe09 exposing []
import Tesl.Prelude exposing [Int]
fact IsA (n: Int)
check recheckA(n: Int ::: IsA n) -> n: Int ::: IsA n =
  ok n ::: IsA n
|}

(* PE10: check fn where proof param requires DIFFERENT fact than fn returns → should_pass *)
let test_PE10_check_requires_one_fact_returns_another () =
  should_pass {|
#lang tesl
module Pe10 exposing []
import Tesl.Prelude exposing [Int]
fact IsA (n: Int)
fact IsB (n: Int)
check checkA(n: Int) -> n: Int ::: IsA n =
  if n > 0 then
    ok n ::: IsA n
  else
    fail 400 "bad"
check enrichWithB(n: Int ::: IsA n) -> n: Int ::: IsB n =
  if n < 1000 then
    ok n ::: IsB n
  else
    fail 400 "too big"
fn needsAandB(n: Int ::: IsA n && IsB n) -> Int = n
fn run(raw: Int) -> Int =
  let withA = check checkA raw
  let withB = check enrichWithB withA
  needsAandB withB
|}

(* PE11: fn with multiple proof params, both supplied → should_pass *)
let test_PE11_multiple_proof_params_both_supplied () =
  should_pass {|
#lang tesl
module Pe11 exposing []
import Tesl.Prelude exposing [Int]
fact ValidX (n: Int)
fact ValidY (n: Int)
check checkX(n: Int) -> n: Int ::: ValidX n =
  if n > 0 then
    ok n ::: ValidX n
  else
    fail 400 "bad x"
check checkY(n: Int) -> n: Int ::: ValidY n =
  if n < 100 then
    ok n ::: ValidY n
  else
    fail 400 "bad y"
fn combine(x: Int ::: ValidX x, y: Int ::: ValidY y) -> Int = x + y
fn run(rawX: Int, rawY: Int) -> Int =
  let vx = check checkX rawX
  let vy = check checkY rawY
  combine vx vy
|}

(* PE12: fn with multiple proof params, only one supplied → should_fail *)
let test_PE12_multiple_proof_params_one_missing () =
  should_fail "proof\\|ValidY\\|does not.*statically\\|not.*satisfy" {|
#lang tesl
module Pe12 exposing []
import Tesl.Prelude exposing [Int]
fact ValidX (n: Int)
fact ValidY (n: Int)
check checkX(n: Int) -> n: Int ::: ValidX n =
  if n > 0 then
    ok n ::: ValidX n
  else
    fail 400 "bad x"
fn combine(x: Int ::: ValidX x, y: Int ::: ValidY y) -> Int = x + y
fn badRun(rawX: Int, rawY: Int) -> Int =
  let vx = check checkX rawX
  combine vx rawY
|}

(* PE13: establish fn returns conjunction of two locally-declared facts → should_pass *)
let test_PE13_establish_conjunction_of_two_facts () =
  should_pass {|
#lang tesl
module Pe13 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsLow (n: Int)
fact IsNonNeg (n: Int)
establish admitLowNonNeg(n: Int) -> Fact (IsLow n && IsNonNeg n) =
  IsLow n && IsNonNeg n
fn needsBoth(n: Int ::: IsLow n && IsNonNeg n) -> Int = n
fn run(raw: Int) -> Int =
  let pf = admitLowNonNeg raw
  needsBoth <| raw ::: pf
|}

(* PE14: check fn declared to return proof but body returns wrong type → should_fail *)
let test_PE14_check_body_returns_wrong_type () =
  should_fail "type.*mismatch\\|expected\\|Int.*String\\|String.*Int" {|
#lang tesl
module Pe14 exposing []
import Tesl.Prelude exposing [Int, String]
fact Validated (n: Int)
check badTyped(n: Int) -> n: Int ::: Validated n =
  if n > 0 then
    ok n ::: Validated n
  else
    fail 400 "bad"
fn wrongReturn(n: Int) -> String =
  badTyped n
|}

(* PE15: library completeness — auth fn with unexported param type → should_fail *)
let test_PE15_unexported_param_type_in_library () =
  should_fail "not in scope\\|unknown.*type\\|UserToken\\|exposing" {|
#lang tesl
module Pe15 exposing [checkToken]
import Tesl.Prelude exposing [Int]
record UserToken { id: Int }
check checkToken(n: Int) -> n: Int ::: ValidToken n =
  if n > 0 then
    ok n ::: ValidToken n
  else
    fail 400 "bad"
|}

(* PE16: Proof predicate used in test block → should_pass
   Test block uses `let` bindings before check calls and expects on the result *)
let test_PE16_proof_predicate_in_test_block () =
  should_pass {|
#lang tesl
module Pe16 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
test "positive value accepted" {
  let n = 5
  let r = check checkPos n
  expect r == 5
}
test "negative value fails" {
  let n = 0
  expectFail (check checkPos n)
}
|}

(* PE17: chain: check A, then check B which requires A's proof, result has both → should_pass *)
let test_PE17_chained_checks_accumulate () =
  should_pass {|
#lang tesl
module Pe17 exposing []
import Tesl.Prelude exposing [Int]
fact StepA (n: Int)
fact StepB (n: Int)
check doA(n: Int) -> n: Int ::: StepA n =
  if n > 0 then
    ok n ::: StepA n
  else
    fail 400 "step a failed"
check doB(n: Int ::: StepA n) -> n: Int ::: StepB n =
  if n < 500 then
    ok n ::: StepB n
  else
    fail 400 "step b failed"
fn needsBoth(n: Int ::: StepA n && StepB n) -> Int = n
fn pipeline(raw: Int) -> Int =
  let afterA = check doA raw
  let afterB = check doB afterA
  needsBoth afterB
|}

(* PE18: check called without capturing result to a name → should_fail
   (The compiler requires check results to be bound: `let x = check f(n)`) *)
let test_PE18_check_result_ignored () =
  should_fail "check.*must be bound\\|bare.*check\\|without a binding\\|silently discarded" {|
#lang tesl
module Pe18 exposing []
import Tesl.Prelude exposing [Int, String]
fact Checked (n: Int)
check doCheck(n: Int) -> n: Int ::: Checked n =
  if n > 0 then
    ok n ::: Checked n
  else
    fail 400 "bad"
fn runAndIgnore(raw: Int) -> String =
  let _ = check doCheck raw
  "done"
|}

(* PE19: establish with wrong fact constructor in body → should_fail *)
let test_PE19_establish_wrong_fact_constructor () =
  should_fail "P001\\|fact ownership\\|not.*owner\\|IsRight\\|IsLeft" {|
#lang tesl
module Pe19 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsLeft (n: Int)
fact IsRight (n: Int)
establish proveLeft(n: Int) -> Fact (IsLeft n) =
  IsRight n
|}

(* PE20: Proof in let binding then passed to requiring function → should_pass *)
let test_PE20_proof_in_let_binding () =
  should_pass {|
#lang tesl
module Pe20 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact Approved (n: Int)
establish approve(n: Int) -> Fact (Approved n) =
  Approved n
fn needsApproval(n: Int ::: Approved n) -> Int = n * 10
fn run(raw: Int) -> Int =
  let pf = approve raw
  let approved = raw ::: pf
  needsApproval approved
|}

(* ── TE: Type system edges ───────────────────────────────────────────────── *)

(* TE01: Self-referential type alias → should_fail *)
let test_TE01_self_referential_type_alias () =
  should_fail "self.referential\\|circular\\|alias.*itself\\|recursive.*alias\\|cycle" {|
#lang tesl
module Te01 exposing []
type MyAlias = MyAlias
|}

(* TE02: Recursive ADT (tree structure) → should_pass *)
let test_TE02_recursive_adt_tree () =
  should_pass {|
#lang tesl
module Te02 exposing []
import Tesl.Prelude exposing [Int]
type Tree
  = Leaf
  | Node { value: Int left: Tree right: Tree }
fn sum(t: Tree) -> Int =
  case t of
    Leaf -> 0
    Node { value left right } -> value + sum left + sum right
|}

(* TE03: Parameterized ADT used with concrete type → should_pass *)
let test_TE03_parameterized_adt_concrete () =
  should_pass {|
#lang tesl
module Te03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn maybeDouble(n: Int) -> Maybe Int =
  if n > 0 then
    Something (n * 2)
  else
    Nothing
fn describe(m: Maybe Int) -> String =
  case m of
    Nothing -> "none"
    Something n -> "${n}"
|}

(* TE04: Nested Maybe type (Maybe (Maybe Int)) → should_pass *)
let test_TE04_nested_maybe () =
  should_pass {|
#lang tesl
module Te04 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn wrap(n: Int) -> Maybe (Maybe Int) = Something (Something n)
fn unwrap(mm: Maybe (Maybe Int)) -> Int =
  case mm of
    Nothing -> 0
    Something Nothing -> 0
    Something (Something n) -> n
|}

(* TE05: Newtype wrapping a complex type → should_pass *)
let test_TE05_newtype_wrapping_complex () =
  should_pass {|
#lang tesl
module Te05 exposing []
import Tesl.Prelude exposing [Int, String]
type UserId
  = MkUserId { value: Int }
type Username
  = MkUsername { name: String }
fn getUserId(uid: UserId) -> Int =
  case uid of
    MkUserId { value } -> value
fn getUsername(un: Username) -> String =
  case un of
    MkUsername { name } -> name
|}

(* TE06: ADT constructor used with wrong number of fields → should_fail *)
let test_TE06_adt_constructor_wrong_field_count () =
  should_fail "field\\|argument\\|ctor\\|constructor\\|mismatch\\|extra\\|unknown" {|
#lang tesl
module Te06 exposing []
import Tesl.Prelude exposing [Int, String]
type Point
  = Point { x: Int y: Int }
fn bad() -> Point = Point { x = 1 y = 2 z = 3 }
|}

(* TE07: Using unknown type name in function signature → should_fail *)
let test_TE07_unknown_type_in_signature () =
  should_fail "not in scope\\|unknown.*type\\|UnknownType" {|
#lang tesl
module Te07 exposing []
import Tesl.Prelude exposing [Int]
fn bad(x: UnknownType) -> Int = 0
|}

(* TE08: ADT type used in function signature → should_pass *)
let test_TE08_type_alias_in_signature () =
  should_pass {|
#lang tesl
module Te08 exposing []
import Tesl.Prelude exposing [Int, String]
type Identifier
  = MkIdentifier { value: Int }
fn makeId(n: Int) -> Identifier = MkIdentifier { value = n }
fn idValue(id: Identifier) -> Int =
  case id of
    MkIdentifier { value } -> value
|}

(* TE09: Record with multiple fields, all accessed → should_pass *)
let test_TE09_record_multiple_fields_accessed () =
  should_pass {|
#lang tesl
module Te09 exposing []
import Tesl.Prelude exposing [Int, String]
record Person {
  name: String
  age: Int
  score: Int
}
fn describe(p: Person) -> String = "${p.name} age ${p.age} score ${p.score}"
fn totalScore(p: Person) -> Int = p.age + p.score
|}

(* TE10: fn returning record literal without type prefix → should_fail *)
let test_TE10_record_literal_without_type_prefix () =
  should_fail "bare record\\|type prefix\\|unknown.*record\\|literal.*type\\|requires.*type\\|ambiguous\\|not.*in.*scope" {|
#lang tesl
module Te10 exposing []
import Tesl.Prelude exposing [Int, String]
record Pair { first: Int second: Int }
fn bad() -> Pair = { first = 1 second = 2 }
|}

(* TE11: ADT with multiple constructors, some with fields some without → should_pass *)
let test_TE11_mixed_constructor_adt () =
  should_pass {|
#lang tesl
module Te11 exposing []
import Tesl.Prelude exposing [Int, String]
type Shape
  = Circle { radius: Int }
  | Square { side: Int }
  | Point
fn area(s: Shape) -> Int =
  case s of
    Circle { radius } -> radius * radius
    Square { side } -> side * side
    Point -> 0
fn describe(s: Shape) -> String =
  case s of
    Circle _ -> "circle"
    Square _ -> "square"
    Point -> "point"
|}

(* TE12: ADT wrapping another ADT → should_pass *)
let test_TE12_newtype_of_newtype () =
  should_pass {|
#lang tesl
module Te12 exposing []
import Tesl.Prelude exposing [Int]
type Inner
  = MkInner { val: Int }
type Outer
  = MkOuter { inner: Inner }
fn makeOuter(n: Int) -> Outer = MkOuter { inner = MkInner { val = n } }
fn getVal(o: Outer) -> Int =
  case o of
    MkOuter { inner } ->
      case inner of
        MkInner { val } -> val
|}

(* TE13: Using an ADT constructor as a function (applying a constructor) → should_pass *)
let test_TE13_adt_constructor_as_function () =
  should_pass {|
#lang tesl
module Te13 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn wrapPositive(n: Int) -> Maybe Int =
  if n > 0 then
    Something n
  else
    Nothing
|}

(* TE14: Record field access on value of correct type → should_pass *)
let test_TE14_record_field_access_correct () =
  should_pass {|
#lang tesl
module Te14 exposing []
import Tesl.Prelude exposing [Int, String]
record Config { host: String port: Int }
fn getPort(c: Config) -> Int = c.port
fn getHost(c: Config) -> String = c.host
fn makeUrl(c: Config) -> String = "${c.host}:${c.port}"
|}

(* TE15: Record field access with wrong field name → should_fail *)
let test_TE15_record_field_access_wrong_name () =
  should_fail "field.*not found\\|unknown field\\|does not have.*field\\|not.*member" {|
#lang tesl
module Te15 exposing []
import Tesl.Prelude exposing [Int, String]
record Config { host: String port: Int }
fn badAccess(c: Config) -> String = c.address
|}

(* TE16: fn that returns the wrong type from its body → should_fail *)
let test_TE16_wrong_return_type () =
  should_fail "type.*mismatch\\|expected\\|String.*Int\\|Int.*String" {|
#lang tesl
module Te16 exposing []
import Tesl.Prelude exposing [Int, String]
fn bad(n: Int) -> String = n * 2
|}

(* TE17: Int arithmetic in function body → should_pass *)
let test_TE17_int_arithmetic () =
  should_pass {|
#lang tesl
module Te17 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
fn sub(a: Int, b: Int) -> Int = a - b
fn mul(a: Int, b: Int) -> Int = a * b
fn compute(n: Int) -> Int = (n + 1) * (n - 1) - n
|}

(* TE18: String interpolation with Int expression → should_pass *)
let test_TE18_string_interpolation_with_int () =
  should_pass {|
#lang tesl
module Te18 exposing []
import Tesl.Prelude exposing [Int, String]
fn format(n: Int, label: String) -> String = "${label}: ${n}"
fn summary(count: Int, total: Int) -> String = "${count} of ${total} items"
|}

(* TE19: Boolean condition in if-then-else → should_pass *)
let test_TE19_boolean_condition () =
  should_pass {|
#lang tesl
module Te19 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn clamp(n: Int, lo: Int, hi: Int) -> Int =
  if n < lo then
    lo
  else
    if n > hi then
      hi
    else
      n
fn classify(n: Int) -> Bool =
  if n > 0 then
    True
  else
    False
|}

(* TE20: Type variable in function (polymorphic behavior) → should_pass or fail *)
let test_TE20_type_variable_polymorphic () =
  should_pass {|
#lang tesl
module Te20 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn fromMaybe(default: a, m: Maybe a) -> a =
  case m of
    Nothing -> default
    Something x -> x
fn withDefault(n: Maybe Int) -> Int = fromMaybe 0 n
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review74-ProofAndTypeEdges" [
    "proof-system-edges", [
      test_case "PE01 sequential proof accumulation" `Quick test_PE01_sequential_proof_accumulation;
      test_case "PE02 check result in tail position" `Quick test_PE02_check_result_tail_position;
      test_case "PE03 call requiring proof without proof" `Quick test_PE03_call_requiring_proof_without_proof;
      test_case "PE04 two facts same value accumulate" `Quick test_PE04_two_facts_same_value_accumulate;
      test_case "PE05 establish and use in same fn" `Quick test_PE05_establish_and_use_in_same_fn;
      test_case "PE06 establish chain with check" `Quick test_PE06_establish_chain_with_check;
      test_case "PE07 cannot produce imported fact" `Quick test_PE07_cannot_produce_imported_fact;
      test_case "PE08 use imported fact without producing" `Quick test_PE08_use_imported_fact_without_producing;
      test_case "PE09 check requires and returns same fact" `Quick test_PE09_check_requires_and_returns_same_fact;
      test_case "PE10 check requires one fact returns another" `Quick test_PE10_check_requires_one_fact_returns_another;
      test_case "PE11 multiple proof params both supplied" `Quick test_PE11_multiple_proof_params_both_supplied;
      test_case "PE12 multiple proof params one missing" `Quick test_PE12_multiple_proof_params_one_missing;
      test_case "PE13 establish conjunction of two facts" `Quick test_PE13_establish_conjunction_of_two_facts;
      test_case "PE14 check body returns wrong type" `Quick test_PE14_check_body_returns_wrong_type;
      test_case "PE15 unexported param type in library" `Quick test_PE15_unexported_param_type_in_library;
      test_case "PE16 proof predicate in test block" `Quick test_PE16_proof_predicate_in_test_block;
      test_case "PE17 chained checks accumulate proofs" `Quick test_PE17_chained_checks_accumulate;
      test_case "PE18 check result ignored is ok" `Quick test_PE18_check_result_ignored;
      test_case "PE19 establish wrong fact constructor" `Quick test_PE19_establish_wrong_fact_constructor;
      test_case "PE20 proof in let binding passed to fn" `Quick test_PE20_proof_in_let_binding;
    ];
    "type-system-edges", [
      test_case "TE01 self-referential type alias" `Quick test_TE01_self_referential_type_alias;
      test_case "TE02 recursive ADT tree" `Quick test_TE02_recursive_adt_tree;
      test_case "TE03 parameterized ADT concrete type" `Quick test_TE03_parameterized_adt_concrete;
      test_case "TE04 nested Maybe type" `Quick test_TE04_nested_maybe;
      test_case "TE05 newtype wrapping complex type" `Quick test_TE05_newtype_wrapping_complex;
      test_case "TE06 ADT constructor wrong field count" `Quick test_TE06_adt_constructor_wrong_field_count;
      test_case "TE07 unknown type in signature" `Quick test_TE07_unknown_type_in_signature;
      test_case "TE08 type alias in function signature" `Quick test_TE08_type_alias_in_signature;
      test_case "TE09 record multiple fields accessed" `Quick test_TE09_record_multiple_fields_accessed;
      test_case "TE10 record literal without type prefix" `Quick test_TE10_record_literal_without_type_prefix;
      test_case "TE11 mixed constructor ADT" `Quick test_TE11_mixed_constructor_adt;
      test_case "TE12 newtype of newtype" `Quick test_TE12_newtype_of_newtype;
      test_case "TE13 ADT constructor as function" `Quick test_TE13_adt_constructor_as_function;
      test_case "TE14 record field access correct" `Quick test_TE14_record_field_access_correct;
      test_case "TE15 record field access wrong name" `Quick test_TE15_record_field_access_wrong_name;
      test_case "TE16 wrong return type" `Quick test_TE16_wrong_return_type;
      test_case "TE17 int arithmetic" `Quick test_TE17_int_arithmetic;
      test_case "TE18 string interpolation with int" `Quick test_TE18_string_interpolation_with_int;
      test_case "TE19 boolean condition in if-then-else" `Quick test_TE19_boolean_condition;
      test_case "TE20 type variable polymorphic" `Quick test_TE20_type_variable_polymorphic;
    ];
  ]
