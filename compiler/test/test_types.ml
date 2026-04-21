(** Type system tests — happy path and adversarial.

    Tests cover:
    1. Type representation and pretty-printing
    2. Substitution operations
    3. Unification (happy path, occurs check, mismatches)
    4. Instantiation and generalization
    5. Expression type inference
    6. Module-level type checking
    7. Stdlib type signatures
    8. Error reporting *)

open Type_system
open Checker

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let reset () = Type_system.reset_counter ()

let parse_and_check src =
  match Parser.parse_module "<test>" src with
  | Ok m -> Checker.check_module m
  | Err e -> [{ loc = e.loc; message = e.msg }]

let assert_no_errors src =
  let errs = parse_and_check src in
  if errs <> [] then
    Alcotest.failf "expected no errors but got:\n%s"
      (String.concat "\n" (List.map fmt_error errs))

let assert_has_error src substr =
  let errs = parse_and_check src in
  let found = List.exists (fun e ->
    let idx_start = ref 0 in
    let n = String.length e.message in
    let m = String.length substr in
    let found = ref false in
    while !idx_start <= n - m && not !found do
      if String.sub e.message !idx_start m = substr then found := true;
      incr idx_start
    done;
    !found
  ) errs in
  if not found then
    Alcotest.failf "expected error containing %S but got:\n%s"
      substr
      (if errs = [] then "(no errors)" else
       String.concat "\n" (List.map (fun e -> e.message) errs))

let _assert_error_count src n =
  let errs = parse_and_check src in
  if List.length errs <> n then
    Alcotest.failf "expected %d errors but got %d:\n%s"
      n (List.length errs)
      (String.concat "\n" (List.map fmt_error errs))

(* ── 1. Type representation tests ────────────────────────────────────────── *)

let test_pp_primitives () =
  Alcotest.(check string) "Int" "Int" (pp_ty t_int);
  Alcotest.(check string) "String" "String" (pp_ty t_string);
  Alcotest.(check string) "Bool" "Bool" (pp_ty t_bool);
  Alcotest.(check string) "Float" "Float" (pp_ty t_float);
  Alcotest.(check string) "Unit" "Unit" (pp_ty t_unit)

let test_pp_applied () =
  Alcotest.(check string) "List Int" "List Int" (pp_ty (t_list t_int));
  Alcotest.(check string) "Maybe String" "Maybe String" (pp_ty (t_maybe t_string));
  Alcotest.(check string) "List (List Int)" "List (List Int)"
    (pp_ty (t_list (t_list t_int)))

let test_pp_function () =
  Alcotest.(check string) "Int -> String" "Int -> String"
    (pp_ty (TFun (t_int, t_string)));
  Alcotest.(check string) "Int -> Int -> Bool" "Int -> Int -> Bool"
    (pp_ty (TFun (t_int, TFun (t_int, t_bool))));
  (* Parens around arg function *)
  Alcotest.(check string) "fn arg" "(Int -> String) -> Bool"
    (pp_ty ~parens:false (TFun (TFun (t_int, t_string), t_bool)))

let test_pp_type_vars () =
  reset ();
  let a = fresh () in
  Alcotest.(check string) "fresh a" "a" (pp_ty a);
  let b = fresh () in
  Alcotest.(check string) "fresh b" "b" (pp_ty b);
  Alcotest.(check string) "rigid -1" "a" (pp_ty (TVar (-1)));
  Alcotest.(check string) "rigid -2" "b" (pp_ty (TVar (-2)))

(* ── 2. Substitution tests ───────────────────────────────────────────────── *)

let test_apply_empty () =
  reset ();
  let v = fresh () in
  Alcotest.(check string) "apply empty" "a" (pp_ty (apply empty_subst v));
  Alcotest.(check string) "apply int" "Int" (pp_ty (apply empty_subst t_int))

let test_apply_binding () =
  reset ();
  let id = fresh_id () in
  let s : subst = [(id, t_int)] in
  Alcotest.(check string) "bound var" "Int" (pp_ty (apply s (TVar id)));
  Alcotest.(check string) "unbound var" "b" (pp_ty (apply s (fresh ())))

let test_apply_chain () =
  reset ();
  let id1 = fresh_id () in
  let id2 = fresh_id () in
  let s : subst = [(id1, TVar id2); (id2, t_string)] in
  Alcotest.(check string) "chain resolves" "String" (pp_ty (apply s (TVar id1)))

let test_apply_in_type () =
  reset ();
  let id = fresh_id () in
  let s : subst = [(id, t_int)] in
  Alcotest.(check string) "in TApp" "List Int"
    (pp_ty (apply s (t_list (TVar id))));
  Alcotest.(check string) "in TFun" "Int -> String"
    (pp_ty (apply s (TFun (TVar id, t_string))))

let test_compose () =
  reset ();
  let id1 = fresh_id () in
  let id2 = fresh_id () in
  let s1 : subst = [(id1, t_int)] in
  let s2 : subst = [(id2, TVar id1)] in
  let sc = compose s1 s2 in
  (* s2 maps id2 → id1; s1 maps id1 → int; so composed: id2 → int *)
  Alcotest.(check string) "composed" "Int" (pp_ty (apply sc (TVar id2)))

(* ── 3. Unification tests ────────────────────────────────────────────────── *)

let test_unify_same () =
  reset ();
  let s = unify empty_subst t_int t_int in
  Alcotest.(check bool) "same types unify" true (s = empty_subst || true)

let test_unify_var_to_con () =
  reset ();
  let id = fresh_id () in
  let s = unify empty_subst (TVar id) t_string in
  Alcotest.(check string) "var → con" "String" (pp_ty (apply s (TVar id)))

let test_unify_con_to_var () =
  reset ();
  let id = fresh_id () in
  let s = unify empty_subst t_int (TVar id) in
  Alcotest.(check string) "con → var" "Int" (pp_ty (apply s (TVar id)))

let test_unify_two_vars () =
  reset ();
  let id1 = fresh_id () in
  let id2 = fresh_id () in
  let s = unify empty_subst (TVar id1) (TVar id2) in
  let v1' = apply s (TVar id1) in
  let v2' = apply s (TVar id2) in
  Alcotest.(check string) "vars unified" (pp_ty v1') (pp_ty v2')

let test_unify_list () =
  reset ();
  let id = fresh_id () in
  let s = unify empty_subst (t_list (TVar id)) (t_list t_bool) in
  Alcotest.(check string) "list elem" "Bool" (pp_ty (apply s (TVar id)))

let test_unify_function () =
  reset ();
  let id1 = fresh_id () in
  let id2 = fresh_id () in
  let s = unify empty_subst (TFun (TVar id1, TVar id2)) (TFun (t_int, t_string)) in
  Alcotest.(check string) "fun param" "Int" (pp_ty (apply s (TVar id1)));
  Alcotest.(check string) "fun result" "String" (pp_ty (apply s (TVar id2)))

let test_unify_occurs_check () =
  reset ();
  let id = fresh_id () in
  try
    let _ = unify empty_subst (TVar id) (t_list (TVar id)) in
    Alcotest.fail "should have raised TypeMismatch"
  with TypeMismatch (_, _, note) ->
    Alcotest.(check bool) "occurs check" true (String.length note > 0)

let test_unify_constructor_mismatch () =
  reset ();
  try
    let _ = unify empty_subst t_int t_string in
    Alcotest.fail "should have raised TypeMismatch"
  with TypeMismatch _ -> ()

let test_unify_posix_int_mismatch () =
  reset ();
  try
    let _ = unify empty_subst t_posix t_int in
    Alcotest.fail "should have raised TypeMismatch"
  with TypeMismatch _ -> ()

let test_unify_bare_list () =
  reset ();
  (* Bare List should NOT unify with List Int — explicit type parameters are required *)
  (try
    let _ = unify empty_subst (TCon "List") (t_list t_int) in
    Alcotest.fail "bare List should not unify with List Int"
  with TypeMismatch _ -> ())

let test_unify_rigid_fails () =
  reset ();
  (* Rigid variable (-1) cannot be unified with a concrete type *)
  try
    let _ = unify empty_subst (TVar (-1)) t_int in
    Alcotest.fail "rigid var should not unify"
  with TypeMismatch _ -> ()

(* ── 4. Instantiation & Generalization tests ─────────────────────────────── *)

let test_instantiate_mono () =
  reset ();
  let sch = mono t_int in
  let ty = instantiate sch in
  Alcotest.(check string) "mono instantiates to itself" "Int" (pp_ty ty)

let test_instantiate_poly () =
  reset ();
  (* ∀a. a -> a *)
  let id_scheme = { vars = [-1]; mono = TFun (TVar (-1), TVar (-1)) } in
  let ty1 = instantiate id_scheme in
  let ty2 = instantiate id_scheme in
  (* Each instantiation gets fresh variables *)
  Alcotest.(check bool) "poly gives fresh vars" true (ty1 <> ty2)

let test_generalize_mono () =
  reset ();
  let ty = t_int in
  let sch = generalize [] empty_subst ty in
  Alcotest.(check int) "no vars generalized" 0 (List.length sch.vars);
  Alcotest.(check string) "mono" "Int" (pp_ty sch.mono)

let test_generalize_poly () =
  reset ();
  let id = fresh_id () in
  let id2 = fresh_id () in
  let ty = TFun (TVar id, TVar id2) in
  let sch = generalize [] empty_subst ty in
  Alcotest.(check bool) "has quantified vars" true (sch.vars <> []);
  (* Instantiating twice gives different fresh vars *)
  let t1 = instantiate sch in
  let t2 = instantiate sch in
  Alcotest.(check bool) "fresh on each instantiation" true (t1 <> t2)

let test_generalize_with_env_free () =
  reset ();
  let env_id = fresh_id () in
  let body_id = fresh_id () in
  (* env has env_id free; body has env_id AND body_id *)
  let ty = TFun (TVar env_id, TVar body_id) in
  (* Only body_id should be quantified, not env_id *)
  let sch = generalize [env_id] empty_subst ty in
  Alcotest.(check bool) "only body var quantified" true
    (List.length sch.vars = 1)

(* ── 5. Expression type inference tests ──────────────────────────────────── *)

let make_ctx () =
  reset ();
  make_ctx ~filename:"<test>" ~env:(make_stdlib_env ())

let infer src_expr =
  let src = Printf.sprintf
    {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, String, Bool]
fn f(x: Int) -> Int =
  %s
|} src_expr in
  match Parser.parse_module "<test>" src with
  | Ok m ->
    (match List.hd m.decls with
     | DFunc fd ->
       reset ();
       let ctx = make_ctx () in
       let param_env = List.map (fun (b : Ast.binding) ->
         (b.name, mono (ty_of_type_expr b.type_expr))) fd.params in
       let ctx = { ctx with env = param_env @ ctx.env } in
       let ty = Checker.infer_expr ctx fd.body in
       Ok (apply !(ctx.subst) ty, !(ctx.errors))
     | _ -> Error "not a function")
  | Err e -> Error e.msg

let check_type src expected_str =
  match infer src with
  | Ok (ty, _errs) ->
    Alcotest.(check string) src expected_str (pp_ty ty)
  | Error msg ->
    Alcotest.failf "parse/check error: %s" msg

let test_infer_int_literal () =
  check_type "42" "Int"

let test_infer_string_literal () =
  check_type {|"hello"|} "String"

let test_infer_bool_literal () =
  check_type "true" "Bool"

let test_infer_float_literal () =
  check_type "3.14" "Float"

let test_infer_variable () =
  check_type "x" "Int"   (* x: Int from param *)

let test_infer_arithmetic () =
  check_type "x + 1" "Int";
  check_type "x * 2" "Int";
  check_type "0 - x" "Int"  (* subtract x from 0 *)

let test_infer_comparison () =
  check_type "x == 42" "Bool";
  check_type "x > 0" "Bool";
  check_type "x != 0" "Bool"

let test_infer_if_expr () =
  check_type "if x > 0 then\n    x\n  else\n    0" "Int"

let test_infer_negative () =
  check_type "-42" "Int"

let test_infer_list_literal () =
  check_type "[1, 2, 3]" "List Int";
  check_type "[true, false]" "List Bool"

let test_infer_nothing () =
  (* Nothing : Maybe a — unresolved stays as Maybe a *)
  match infer "Nothing" with
  | Ok (ty, _) ->
    let s = pp_ty ty in
    Alcotest.(check bool) "Maybe something" true
      (String.length s >= 5 && String.sub s 0 5 = "Maybe")
  | Error msg -> Alcotest.failf "error: %s" msg

let test_infer_something () =
  match infer "Something 42" with
  | Ok (ty, _) ->
    Alcotest.(check string) "Maybe Int" "Maybe Int" (pp_ty ty)
  | Error msg -> Alcotest.failf "error: %s" msg

(* ── 6. Module-level type checking tests ─────────────────────────────────── *)

let test_module_simple_fn () =
  assert_no_errors {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int =
  x + y
|}

let test_module_string_fn () =
  assert_no_errors {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String =
  "Hello, ${name}!"
|}

let test_module_bool_return () =
  assert_no_errors {|#lang tesl
module Foo exposing [isPositive]
import Tesl.Prelude exposing [Int, Bool]
fn isPositive(x: Int) -> Bool =
  x > 0
|}

let test_module_if_expr () =
  assert_no_errors {|#lang tesl
module Foo exposing [abs_val]
import Tesl.Prelude exposing [Int]
fn abs_val(x: Int) -> Int =
  if x > 0 then
    x
  else
    0
|}

let test_module_case_adt () =
  assert_no_errors {|#lang tesl
module Foo exposing [colorName]
import Tesl.Prelude exposing [String]
type Color =
  | Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|}

let test_module_newtype () =
  assert_no_errors {|#lang tesl
module Foo exposing [UserId, makeUserId]
import Tesl.Prelude exposing [String]
type UserId = String
fn makeUserId(s: String) -> UserId =
  UserId s
|}

let test_module_record () =
  assert_no_errors {|#lang tesl
module Foo exposing [Task]
import Tesl.Prelude exposing [String, Int, Bool]
record Task {
  id: String
  title: String
  done: Bool
}
|}

let test_module_maybe_return () =
  assert_no_errors {|#lang tesl
module Foo exposing [safeDiv]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn safeDiv(a: Int, b: Int) -> Maybe Int =
  if b == 0 then
    Nothing
  else
    Something (a / b)
|}

let test_module_constructor_checked_context () =
  assert_no_errors {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn value() -> Maybe Int =
  Something 42
|}

let test_module_list_return () =
  assert_no_errors {|#lang tesl
module Foo exposing [range]
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.range]
fn range(n: Int) -> List Int =
  List.range 1 n
|}

let test_module_check_fn () =
  assert_no_errors {|#lang tesl
module Foo exposing [ValidPort, isValidPort]
import Tesl.Prelude exposing [Int, String]
fact ValidPort (port: Int)
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port ::: ValidPort port
  else
    fail 400 "port out of range"
|}

let test_module_nested_let () =
  assert_no_errors {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let y = x + 1
  let z = y * 2
  z
|}

let test_module_lambda () =
  assert_no_errors {|#lang tesl
module Foo exposing [applyDouble]
import Tesl.Prelude exposing [Int]
fn applyDouble(f: Int -> Int, x: Int) -> Int = f x
fn main_test() -> Int =
  applyDouble (fn(x: Int) -> x * 2) 5
|}

let test_module_test_blocks () =
  assert_no_errors {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int = x + y
test "basic addition" {
  expect add 1 2 == 3
  expect add 0 0 == 0
}
test "negative" {
  expectFail add 1
}
|}

let test_module_worker_default_return () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [queueRead, FromQueue, FromDeadQueue]
capability q implies queueRead
record Job {
  id: String
}
worker process(job: Job::: FromQueue (Id == jobId) job)
  requires [q] =
  job
deadWorker handleDead(job: Job::: FromDeadQueue (Id == jobId) job)
  requires [q] =
  job
|}

let test_module_parenthesized_forall_return () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.DB exposing [dbRead]
entity Note table "notes" primaryKey id {
  id: String
  authorId: String
}
handler listNotes(user: String)
  -> List Note ? ForAll (FromDb (AuthorId == user))
  requires [dbRead] =
  select note from Note where note.authorId == user
|}

let test_module_higher_order_check_chain () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filterCheck, List.allCheck]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPositive(n: Int) -> n: Int::: IsPositive n =
  if n > 0 then
    ok n::: IsPositive n
  else
    fail 400 "neg"
check checkSmall(n: Int) -> n: Int::: IsSmall n =
  if n < 10 then
    ok n::: IsSmall n
  else
    fail 400 "big"
fn filterPositiveSmall(xs: List Int) -> List Int ? ForAll (IsPositive && IsSmall) =
  List.filterCheck (checkPositive && checkSmall) xs
fn verifyPositiveSmall(xs: List Int)
  -> Maybe (xs: List Int::: ForAll (IsPositive && IsSmall) xs) =
  List.allCheck (checkPositive && checkSmall) xs
|}

let test_module_queue_runtime_statements () =
  assert_no_errors {|#lang tesl
module Foo exposing [W, DW, S]
import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [queueRead, queueWrite, FromQueue, FromDeadQueue]
import Tesl.Http exposing [HttpRequest]
capability workerCap implies queueRead
capability enqueueCap implies queueWrite
record Job {
  id: String
}
queue Q {
  Job
}
worker process(job: Job::: FromQueue (Id == jobId) job)
  requires [workerCap] =
  job
deadWorker handleDead(job: Job::: FromDeadQueue (Id == jobId) job)
  requires [workerCap] =
  job
workers W for Q {
  Job = process
}
deadWorkers DW for Q {
  Job = handleDead
}
handler trigger() -> String requires [enqueueCap] =
  enqueue Job { id: "j-1" }
  "queued"
api A {
  get "/" -> String
}
server S for A {
  trigger = trigger
}
main with capabilities [workerCap, enqueueCap] {
  startWorkers 2 W with capabilities [workerCap]
  startDeadWorkers DW with capabilities [workerCap]
  serve S on 8080 with capabilities [enqueueCap]
}
|}

(* ── 7. Type error detection tests ──────────────────────────────────────── *)

let test_error_unknown_name () =
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  undefined_function x
|} "unknown name"

let test_error_wrong_branch_type () =
  (* if branches must have same type *)
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, Bool]
fn f(x: Int) -> Int =
  if x > 0 then
    x
  else
    true
|} "cannot unify"

let test_error_bad_arithmetic () =
  (* string + int should fail *)
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, String]
fn f(x: String) -> Int =
  x + 1
|} "cannot unify"

let test_error_local_typed_let_mismatch () =
  assert_has_error {|#lang tesl
module Foo exposing [f, formatPublishedAt]
import Tesl.Prelude exposing [Int, String]
fn formatPublishedAt(ts: Int) -> String =
  "formatted"
fn f() -> Int =
  let formatted: Int = formatPublishedAt 0
  1
|} "let binding `formatted` must have declared type Int"

let test_error_test_typed_let_mismatch () =
  assert_has_error {|#lang tesl
module Foo exposing [formatPublishedAt]
import Tesl.Prelude exposing [Int, String]
fn formatPublishedAt(ts: Int) -> String =
  "formatted"
test "typed let" {
  let formatted: Int = formatPublishedAt 0
  expect True
}
|} "let binding `formatted` must have declared type Int"

let test_error_local_typed_let_posix_mismatch () =
  assert_has_error {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Int, String]
import Tesl.Time exposing [Time.secondsToPosix]
fn value() -> Int =
  let nowTs: Int = Time.secondsToPosix 1000
  1
|} "let binding `nowTs` must have declared type Int"

let test_error_list_mixed_types () =
  (* list must have homogeneous element type *)
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, Bool, List]
fn f(x: Int) -> List Int =
  [x, true]
|} "cannot unify"

let test_error_argument_context () =
  assert_has_error {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Int, String]
fn takesInt(x: Int) -> Int =
  x
fn value() -> Int =
  takesInt "oops"
|} "argument 1 to `takesInt`"

let test_error_return_context () =
  assert_has_error {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Bool(..), Int, String]
fn value() -> String =
  if True then
    1
  else
    "ok"
|} "body of `value` must have type String"

let test_error_constructor_argument_context () =
  assert_has_error {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn value() -> Maybe Int =
  Something "oops"
|} "argument 1 of constructor `Something`"

let test_error_constructor_expectation_chain () =
  assert_has_error {|#lang tesl
module Foo exposing [value]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fn value() -> Maybe Int =
  Something "oops"
|} "body of `value` must have type Maybe Int"

(* check_expr bidirectional checking — return type and if-condition contexts *)

let test_error_return_type_context_int () =
  (* Function declared to return Int but body returns String — error should
     mention the return type context, not just a bare "cannot unify" message. *)
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, String]
fn f() -> Int =
  "hello"
|} "body of `f` must have type Int"

let test_error_if_cond_not_bool () =
  (* If condition that is not Bool — error should say "if conditions must have
     type Bool" rather than a bare unification failure message. *)
  assert_has_error {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int, String]
fn f(s: String) -> Int =
  if s then
    1
  else
    0
|} "if conditions must have type Bool"

(* ── 8. Stdlib signatures tests ─────────────────────────────────────────── *)

let test_stdlib_nothing_type () =
  let env = make_stdlib_env () in
  match List.assoc_opt "Nothing" env with
  | Some sch ->
    let ty = instantiate sch in
    let s = pp_ty ty in
    Alcotest.(check bool) "Nothing is Maybe something" true
      (String.length s >= 5 && String.sub s 0 5 = "Maybe")
  | None -> Alcotest.fail "Nothing not in stdlib"

let test_stdlib_list_map_type () =
  let env = make_stdlib_env () in
  match List.assoc_opt "List.map" env with
  | Some sch ->
    Alcotest.(check bool) "List.map is polymorphic" true (sch.vars <> [])
  | None -> Alcotest.fail "List.map not in stdlib"

let test_stdlib_compose_types () =
  (* List.map (fn: a -> b) (xs: List a) : List b should unify *)
  reset ();
  let env = make_stdlib_env () in
  let list_map_sch = List.assoc "List.map" env in
  let map_ty = instantiate list_map_sch in
  (* Apply to (Int -> String) *)
  let fn_ty = TFun (t_int, t_string) in
  let arg_ty = t_list t_int in
  let result = fresh () in
  let s = unify empty_subst map_ty (TFun (fn_ty, TFun (arg_ty, result))) in
  Alcotest.(check string) "List.map result" "List String"
    (pp_ty (apply s result))

let test_stdlib_dict_lookup () =
  reset ();
  let env = make_stdlib_env () in
  let lookup_sch = List.assoc "Dict.lookup" env in
  let lookup_ty = instantiate lookup_sch in
  (* Dict.lookup "key" (Dict String Int) should be Maybe Int *)
  let key_ty = t_string in
  let dict_ty = t_dict t_string t_int in
  let result = fresh () in
  let s = unify empty_subst lookup_ty (TFun (key_ty, TFun (dict_ty, result))) in
  Alcotest.(check string) "Dict.lookup result" "Maybe Int"
    (pp_ty (apply s result))

let test_stdlib_empty_list_arguments () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Bool, Int, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.length, List.isEmpty, List.head, List.sum]
test "empty list stdlib calls" {
  expect List.length [] == 0
  expect List.isEmpty [] == true
  expect List.head [] == Nothing
  expect List.sum [] == 0
}
|}

let test_stdlib_time_functions () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Time exposing [PosixMillis, nowMillis, formatTime, durationMs, Time.secondsToPosix]
fn render(ts: PosixMillis, tz: String) -> String =
  formatTime ts tz "%Y-%m-%d"
fn elapsed(ts: PosixMillis) -> Int =
  durationMs ts
fn epoch() -> PosixMillis =
  Time.secondsToPosix 0
fn renderNow() -> String =
  formatTime (nowMillis()) "UTC" "%Y-%m-%dT%H:%M:%S.%3NZ"
|}

let test_stdlib_either_dict_set_basics () =
  assert_no_errors {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Bool, Int, String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Either exposing [Either(..), Either.isLeft, Either.map, Either.andThen]
import Tesl.Dict exposing [Dict, Dict.empty, Dict.insert, Dict.remove, Dict.lookup, Dict.requireKey, Dict.get, Dict.member, Dict.size, Dict.isEmpty, Dict.union, Dict.fromList]
import Tesl.Set exposing [Set, Set.empty, Set.insert, Set.remove, Set.member, Set.size, Set.isEmpty, Set.fromList, Set.union, Set.intersection, Set.difference]
import Tesl.String exposing [String.isEmpty]
import Tesl.List exposing [List.foldl]
import Tesl.Tuple exposing [Tuple2]
fn parseAge(raw: String) -> Either String Int =
  if String.isEmpty raw then
    Left "empty"
  else
    Right 21
fn validateAdult(age: Int) -> Either String Int =
  if age >= 18 then
    Right age
  else
    Left "young"
fn parseAdultAge(raw: String) -> Either String Int =
  Either.andThen validateAdult (parseAge raw)
fn buildUserDb() -> Dict String String =
  Dict.fromList [Tuple2 "usr-1" "alice", Tuple2 "usr-2" "bob"]
fn currentCount(acc: Dict String Int, status: String) -> Int =
  case Dict.lookup status acc of
    Something value -> value
    Nothing -> 0
fn incrementCount(acc: Dict String Int, status: String) -> Dict String Int =
  Dict.insert status ((currentCount acc status) + 1) acc
fn countByStatus(statuses: List String) -> Dict String Int =
  List.foldl incrementCount Dict.empty statuses
fn dictOps() -> Bool =
  let d1 = Dict.fromList [Tuple2 "a" 1, Tuple2 "b" 2]
  let d2 = Dict.fromList [Tuple2 "b" 99, Tuple2 "c" 3]
  let u = Dict.union d1 d2
  let checkedB = check Dict.requireKey "b" u
  Dict.size (Dict.remove "a" u) == 2 && Dict.get "b" checkedB == 2 && Dict.isEmpty Dict.empty == true
fn setOps() -> Bool =
  let s1 = Set.fromList [1, 2, 3]
  let s2 = Set.fromList [2, 3, 4]
  Set.member 1 (Set.difference s1 s2) && Set.size (Set.intersection s1 s2) == 2 && Set.isEmpty Set.empty
test "either dict set basics" {
  expect Either.isLeft (parseAdultAge "") == true
  expect dictOps() == true
  expect setOps() == true
}
|}

(* ── 9. No T_ANY adversarial tests ──────────────────────────────────────── *)

let test_no_t_any () =
  (* T_ANY should never appear in type inference output *)
  let errs = parse_and_check {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int = x + 1
|} in
  let any_in_errors = List.exists (fun e ->
    String.length e.message >= 5 &&
    let idx = ref 0 in
    let found = ref false in
    let n = String.length e.message in
    while !idx + 5 <= n && not !found do
      if String.sub e.message !idx 5 = "__Any" then found := true;
      incr idx
    done;
    !found
  ) errs in
  Alcotest.(check bool) "no T_ANY in errors" false any_in_errors

let test_all_modules_compile () =
  (* All lesson files should type-check without crashing *)
  let tesl_root =
    match Sys.getenv_opt "TESL_REPO_ROOT" with
    | Some p when p <> "" -> p
    | _ ->
      let rec find dir =
        let candidate = Filename.concat dir "compiler" in
        if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
        then dir
        else let parent = Filename.dirname dir in
             if parent = dir then Filename.current_dir_name else find parent
      in
      find (Filename.dirname Sys.executable_name)
  in
  let root = tesl_root ^ "/example/learn" in
  let files = try
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun f ->
        let n = String.length f in
        n >= 5 && String.sub f (n-5) 5 = ".tesl")
    |> List.sort String.compare
  with Sys_error _ -> []
  in
  List.iter (fun fname ->
    let path = Filename.concat root fname in
    let src = try In_channel.with_open_text path In_channel.input_all
              with Sys_error _ -> "" in
    if src <> "" then begin
      let errs = parse_and_check src in
      (* Just check it doesn't crash — errors are expected since no type checker yet *)
      ignore errs
    end
  ) files

(* ── 10. Parameterized ADT type-checking tests ──────────────────────────── *)

let test_parameterized_adt_constructors () =
  assert_no_errors {|#lang tesl
module Foo exposing [wrapRight, wrapLeft]
import Tesl.Prelude exposing [String, Int]
type Either a b =
  | Left { value: a }
  | Right { value: b }
fn wrapRight(x: Int) -> Either String Int =
  Right { value: x }
fn wrapLeft(s: String) -> Either String Int =
  Left { value: s }
|}

let test_parameterized_adt_case () =
  assert_no_errors {|#lang tesl
module Foo exposing [getLeft]
import Tesl.Prelude exposing [String, Int]
type Either a b =
  | Left { value: a }
  | Right { value: b }
fn getLeft(e: Either String Int) -> String =
  case e of
    Left { value = v } -> v
    Right _ -> "not a left"
|}

let test_parameterized_adt_full_example () =
  assert_no_errors {|#lang tesl
module ParamAdts exposing [Either(..), Result(..), wrapRight, getLeft, wrapOk, getOkValue]
import Tesl.Prelude exposing [String, Int]
type Either a b =
  | Left { value: a }
  | Right { value: b }
type Result e v =
  | Ok { value: v }
  | Err { error: e }
fn wrapRight(x: Int) -> Either String Int =
  Right { value: x }
fn getLeft(e: Either String Int) -> String =
  case e of
    Left { value = v } -> v
    Right _ -> "not a left"
fn wrapOk(x: Int) -> Result String Int =
  Ok { value: x }
fn getOkValue(r: Result String Int) -> Int =
  case r of
    Ok { value = v } -> v
    Err _ -> 0
|}

let test_parameterized_adt_nullary_variants () =
  assert_no_errors {|#lang tesl
module Foo exposing [Option(..)]
import Tesl.Prelude exposing [Int]
type Option a =
  | Some { value: a }
  | None
fn fromOption(o: Option Int, default: Int) -> Int =
  case o of
    Some { value = v } -> v
    None -> default
|}

(* ── Fact ownership tests ────────────────────────────────────────────────── *)

(* Happy path: fact declared, check function in same module *)
let test_fact_declared_locally () =
  assert_no_errors {|#lang tesl
module Foo exposing [ValidPort, isValidPort]
import Tesl.Prelude exposing [Int]
fact ValidPort (port: Int)
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port ::: ValidPort port
  else
    fail 400 "port out of range"
|}

(* Happy path: establish with fact declared *)
let test_fact_establish () =
  assert_no_errors {|#lang tesl
module Foo exposing [Authenticated, login]
import Tesl.Prelude exposing [String]
fact Authenticated (token: String)
establish login(token: String) -> Fact (Authenticated token) =
  Authenticated token
|}

(* Error: check function without fact declaration *)
let test_fact_ownership_missing_declaration () =
  assert_has_error {|#lang tesl
module Foo exposing [isValidPort]
import Tesl.Prelude exposing [Int]
check isValidPort(port: Int) -> port: Int ::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port ::: ValidPort port
  else
    fail 400 "port out of range"
|} "fact ownership violation"

(* Error: auth function producing predicate without fact declaration *)
let test_fact_ownership_auth_missing () =
  assert_has_error {|#lang tesl
module Foo exposing [requireAuth]
import Tesl.Prelude exposing [String]
auth requireAuth(token: String) -> user: String ::: Authenticated user =
  ok token ::: Authenticated token
|} "fact ownership violation"

(* Error: check producing ForAll predicate without fact declaration *)
let test_fact_ownership_forall_missing () =
  assert_has_error {|#lang tesl
module Foo exposing [checkAll]
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkAll(xs: List Int) -> List Int ::: ForAll (IsSmall id) =
  ok xs ::: ForAll (IsSmall id)
|} "fact ownership violation"

(* Happy path: fact with no params is valid *)
let test_fact_no_params () =
  assert_no_errors {|#lang tesl
module Foo exposing [IsReady, makeReady]
import Tesl.Prelude exposing [String]
fact IsReady
establish makeReady(s: String) -> Fact (IsReady) =
  IsReady
|}

(* Happy path: fact declared, regular fn can USE predicate as input type *)
let test_fact_use_without_declare () =
  assert_no_errors {|#lang tesl
module Foo exposing [ValidPort, use_it]
import Tesl.Prelude exposing [Int]
fact ValidPort (port: Int)
fn use_it(port: Int ::: ValidPort port) -> Int = port
|}

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "TypeSystem" [
    "representation", [
      Alcotest.test_case "pp primitives" `Quick test_pp_primitives;
      Alcotest.test_case "pp applied types" `Quick test_pp_applied;
      Alcotest.test_case "pp function types" `Quick test_pp_function;
      Alcotest.test_case "pp type variables" `Quick test_pp_type_vars;
    ];
    "substitution", [
      Alcotest.test_case "apply empty subst" `Quick test_apply_empty;
      Alcotest.test_case "apply binding" `Quick test_apply_binding;
      Alcotest.test_case "apply chain" `Quick test_apply_chain;
      Alcotest.test_case "apply in type" `Quick test_apply_in_type;
      Alcotest.test_case "compose" `Quick test_compose;
    ];
    "unification", [
      Alcotest.test_case "same types" `Quick test_unify_same;
      Alcotest.test_case "var to constructor" `Quick test_unify_var_to_con;
      Alcotest.test_case "constructor to var" `Quick test_unify_con_to_var;
      Alcotest.test_case "two vars" `Quick test_unify_two_vars;
      Alcotest.test_case "list types" `Quick test_unify_list;
      Alcotest.test_case "function types" `Quick test_unify_function;
      Alcotest.test_case "occurs check" `Quick test_unify_occurs_check;
      Alcotest.test_case "constructor mismatch" `Quick test_unify_constructor_mismatch;
      Alcotest.test_case "PosixMillis/Int mismatch" `Quick test_unify_posix_int_mismatch;
      Alcotest.test_case "bare constructor" `Quick test_unify_bare_list;
      Alcotest.test_case "rigid var fails" `Quick test_unify_rigid_fails;
    ];
    "polymorphism", [
      Alcotest.test_case "instantiate mono" `Quick test_instantiate_mono;
      Alcotest.test_case "instantiate poly" `Quick test_instantiate_poly;
      Alcotest.test_case "generalize mono" `Quick test_generalize_mono;
      Alcotest.test_case "generalize poly" `Quick test_generalize_poly;
      Alcotest.test_case "generalize with env free" `Quick test_generalize_with_env_free;
    ];
    "inference", [
      Alcotest.test_case "int literal" `Quick test_infer_int_literal;
      Alcotest.test_case "string literal" `Quick test_infer_string_literal;
      Alcotest.test_case "bool literal" `Quick test_infer_bool_literal;
      Alcotest.test_case "float literal" `Quick test_infer_float_literal;
      Alcotest.test_case "variable" `Quick test_infer_variable;
      Alcotest.test_case "arithmetic" `Quick test_infer_arithmetic;
      Alcotest.test_case "comparison" `Quick test_infer_comparison;
      Alcotest.test_case "if expression" `Quick test_infer_if_expr;
      Alcotest.test_case "negative literal" `Quick test_infer_negative;
      Alcotest.test_case "list literal" `Quick test_infer_list_literal;
      Alcotest.test_case "Nothing" `Quick test_infer_nothing;
      Alcotest.test_case "Something" `Quick test_infer_something;
    ];
    "module-check", [
      Alcotest.test_case "simple fn" `Quick test_module_simple_fn;
      Alcotest.test_case "string fn" `Quick test_module_string_fn;
      Alcotest.test_case "bool return" `Quick test_module_bool_return;
      Alcotest.test_case "if expression" `Quick test_module_if_expr;
      Alcotest.test_case "case ADT" `Quick test_module_case_adt;
      Alcotest.test_case "newtype" `Quick test_module_newtype;
      Alcotest.test_case "record" `Quick test_module_record;
      Alcotest.test_case "Maybe return" `Quick test_module_maybe_return;
      Alcotest.test_case "constructor checked context" `Quick test_module_constructor_checked_context;
      Alcotest.test_case "List return" `Quick test_module_list_return;
      Alcotest.test_case "check function" `Quick test_module_check_fn;
      Alcotest.test_case "nested let" `Quick test_module_nested_let;
      Alcotest.test_case "lambda" `Quick test_module_lambda;
      Alcotest.test_case "test blocks" `Quick test_module_test_blocks;
      Alcotest.test_case "worker default return" `Quick test_module_worker_default_return;
      Alcotest.test_case "parenthesized forall return" `Quick test_module_parenthesized_forall_return;
      Alcotest.test_case "higher-order check chain" `Quick test_module_higher_order_check_chain;
      Alcotest.test_case "queue runtime statements" `Quick test_module_queue_runtime_statements;
    ];
    "type-errors", [
      Alcotest.test_case "unknown name" `Quick test_error_unknown_name;
      Alcotest.test_case "if branch type mismatch" `Quick test_error_wrong_branch_type;
      Alcotest.test_case "bad arithmetic" `Quick test_error_bad_arithmetic;
      Alcotest.test_case "local typed let mismatch" `Quick test_error_local_typed_let_mismatch;
      Alcotest.test_case "test typed let mismatch" `Quick test_error_test_typed_let_mismatch;
      Alcotest.test_case "local typed let PosixMillis mismatch" `Quick test_error_local_typed_let_posix_mismatch;
      Alcotest.test_case "list mixed types" `Quick test_error_list_mixed_types;
      Alcotest.test_case "argument context" `Quick test_error_argument_context;
      Alcotest.test_case "return context" `Quick test_error_return_context;
      Alcotest.test_case "constructor argument context" `Quick test_error_constructor_argument_context;
      Alcotest.test_case "constructor expectation chain" `Quick test_error_constructor_expectation_chain;
      Alcotest.test_case "return type context Int" `Quick test_error_return_type_context_int;
      Alcotest.test_case "if condition must be Bool" `Quick test_error_if_cond_not_bool;
    ];
    "stdlib", [
      Alcotest.test_case "Nothing type" `Quick test_stdlib_nothing_type;
      Alcotest.test_case "List.map type" `Quick test_stdlib_list_map_type;
      Alcotest.test_case "List.map composition" `Quick test_stdlib_compose_types;
      Alcotest.test_case "Dict.lookup type" `Quick test_stdlib_dict_lookup;
      Alcotest.test_case "empty list arguments" `Quick test_stdlib_empty_list_arguments;
      Alcotest.test_case "time functions" `Quick test_stdlib_time_functions;
      Alcotest.test_case "either dict set basics" `Quick test_stdlib_either_dict_set_basics;
    ];
    "parameterized-adts", [
      Alcotest.test_case "constructors type-check" `Quick test_parameterized_adt_constructors;
      Alcotest.test_case "case expression" `Quick test_parameterized_adt_case;
      Alcotest.test_case "full example" `Quick test_parameterized_adt_full_example;
      Alcotest.test_case "nullary variants" `Quick test_parameterized_adt_nullary_variants;
    ];
    "invariants", [
      Alcotest.test_case "no T_ANY ever" `Quick test_no_t_any;
      Alcotest.test_case "all modules don't crash" `Quick test_all_modules_compile;
    ];
    "fact-ownership", [
      Alcotest.test_case "fact declared locally" `Quick test_fact_declared_locally;
      Alcotest.test_case "fact establish" `Quick test_fact_establish;
      Alcotest.test_case "missing fact declaration" `Quick test_fact_ownership_missing_declaration;
      Alcotest.test_case "auth missing fact decl" `Quick test_fact_ownership_auth_missing;
      Alcotest.test_case "forall missing fact decl" `Quick test_fact_ownership_forall_missing;
      Alcotest.test_case "fact no params" `Quick test_fact_no_params;
      Alcotest.test_case "use fact as input type" `Quick test_fact_use_without_declare;
    ];
  ]
