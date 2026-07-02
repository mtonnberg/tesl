(** Wave-2 antagonistic soundness corpus.

    A broad positive/negative sweep over the soundness properties the stability
    program cares most about, written because the project has a history of
    letting incorrect code through the checker.  Every NEGATIVE case is a program
    that MUST be rejected (a forgery / laundering / undecidable-comparison
    attempt); every POSITIVE case is the closest legitimate program that MUST
    keep compiling, so a future "fix" cannot silently over-reject.

    Dimensions covered:
      A. FromDb provenance forgery via a SHADOWED SQL builtin (S4b): naming a
         local `fn insert`/`fn select`/… and using it to mint a `:::`-attached
         FromDb return.  Identifier privilege must be decided by RESOLUTION, not
         spelling — this is the single shared, shadow-aware decision site.
      B. Plain FromDb forgery (no DB site at all), across expression shapes, to
         exercise the totality of the DB-site walk.
      C. Legitimate FromDb (a real select) — must still compile.
      D. FromQueue / FromDeadQueue forgery — these provenance proofs can NEVER be
         minted in a body (no user-level dequeue expression), so a `:::` return
         claiming them is always a forgery.
      E. Capability laundering: a real SQL read/write with the wrong `requires`.
      F. Decidable-comparison discipline (S14 / TSS-2 / TSS-3 / HM-2): `==`/`<`
         are only defined for types with decidable equality / a total order.
         Functions (as parameters OR as bare top-level references) and record
         literals must be rejected; primitives and generic type variables pass. *)

open Alcotest

(* ── Helpers (same shape as the other antagonistic suites) ──────────────── *)

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

(* C13: capture the process EXIT CODE, not just the diagnostic text.  A
   should-pass program that regresses to a non-zero exit with no `error[` line
   (or a should-fail program that exits 0 while printing something that matches
   a pattern) would otherwise slip through.  Both `should_pass` and `should_fail`
   now assert the exit code AND the text. *)
let compile_string src =
  (* The `tesl-` filename prefix makes the module-name/file-name check skip the
     temp file (validation_advanced.check_file_module_name_match), so `module T`
     is accepted in every fixture below. *)
  let tmp = Filename.temp_file "tesl-wave2-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in
  (try Sys.remove tmp with _ -> ());
  (code, out)

let should_pass src =
  let (code, out) = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error;
  if code <> 0 then Printf.eprintf "Unexpected non-zero exit (%d):\n%s\n" code out;
  check int "should exit 0" 0 code

let should_fail pattern src =
  let (code, out) = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found;
  if code = 0 then Printf.eprintf "Expected non-zero exit but got 0:\n%s\n" out;
  check bool "should exit non-zero" true (code <> 0)

(* Shared prefixes. *)
let task_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Maybe exposing [Maybe(..)]
entity Task table "tasks" primaryKey id {
  id: String
  title: String
}
|}

let prim_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Bool(..), Int, String]
|}

(* forgery / provenance rejection messages (either gate). *)
let forge_pat = "cannot declare a proof.*return\\|cannot introduce new proofs"

(* ── A. FromDb forgery via a shadowed SQL builtin (all REJECTED) ─────────── *)

(* Build a program that shadows [name] with a user fn and forges FromDb using it. *)
let shadow_forge name =
  task_hdr ^ Printf.sprintf {|
fn %s(x: Task) -> Task = x
fn forge(id: String) -> t: Task ::: FromDb (Id == id) t = %s (Task { id: id, title: "x" })
|} name name

let sql_builtins =
  [ "select"; "selectOne"; "selectMany"; "insert"; "insertMany";
    "upsert"; "update"; "updateAndReturnOne"; "delete"; "deleteAndReturnResult" ]

let make_shadow_case name =
  test_case (Printf.sprintf "shadowed `fn %s` cannot forge FromDb" name) `Quick
    (fun () -> should_fail forge_pat (shadow_forge name))

(* ── B. Plain FromDb forgery, various body shapes (all REJECTED) ─────────── *)

let test_b_plain_construct () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forge(id: String) -> t: Task ::: FromDb (Id == id) t =
  Task { id: id, title: "x" }
|})

let test_b_let_body () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forge(id: String) -> t: Task ::: FromDb (Id == id) t =
  let tmp = Task { id: id, title: "x" }
  tmp
|})

let test_b_if_body () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forge(id: String, flag: String) -> t: Task ::: FromDb (Id == id) t =
  if flag == "a" then
    Task { id: id, title: "x" }
  else
    Task { id: id, title: "y" }
|})

let test_b_case_body () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forge(m: Maybe String, id: String) -> t: Task ::: FromDb (Id == id) t =
  case m of
    Nothing -> Task { id: id, title: "x" }
    Something s -> Task { id: s, title: "y" }
|})

(* ── C. Legitimate FromDb with a real DB site (all ACCEPTED) ─────────────── *)

let test_c_real_selectone () =
  should_pass
    (task_hdr ^ {|
fn getT(id: String) -> t: Task ::: FromDb (Id == id) t
  requires [dbRead] =
  let r = selectOne t from Task where t.id == id
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|})

let test_c_named_pack () =
  should_pass
    (task_hdr ^ {|
fn fetchT(id: String) -> Task ? FromDb (Id == id)
  requires [dbRead] =
  let r = selectOne t from Task where t.id == id
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|})

let test_c_param_passthrough () =
  should_pass
    (task_hdr ^ {|
fn passthru(t: Task ::: FromDb (Id == id) t) -> t: Task ::: FromDb (Id == id) t = t
|})

(* A user fn genuinely named `select` is allowed (R57_B1) as long as it does not
   forge provenance — using it in a NON-proof-returning fn must still compile. *)
let test_c_shadow_name_no_forgery () =
  should_pass
    (task_hdr ^ {|
fn select(x: Task) -> Task = x
fn useIt(id: String) -> Task = select (Task { id: id, title: "x" })
|})

(* ── D. FromQueue / FromDeadQueue forgery (all REJECTED) ─────────────────── *)

let test_d_fromqueue_plain () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forgeQ(id: String) -> t: Task ::: FromQueue t = Task { id: id, title: "x" }
|})

let test_d_fromdeadqueue_plain () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forgeD(id: String) -> t: Task ::: FromDeadQueue t = Task { id: id, title: "x" }
|})

(* Even WITH a real DB site, a FromQueue return is a forgery — the DB does not
   mint queue provenance. *)
let test_d_fromqueue_with_db_still_rejected () =
  should_fail forge_pat
    (task_hdr ^ {|
fn forgeQ(id: String) -> t: Task ::: FromQueue t
  requires [dbRead] =
  let r = selectOne t from Task where t.id == id
  case r of
    Nothing -> fail 404 "nf"
    Something t -> t
|})

(* ── E. Capability laundering: real SQL with the wrong `requires` ────────── *)

let test_e_delete_no_cap_rejected () =
  should_fail "dbWrite\\|privileged operations\\|does not declare"
    (task_hdr ^ {|
fn del() -> String requires [] =
  delete o from Task where o.id == "x"
  "ok"
|})

let test_e_delete_with_cap_accepted () =
  should_pass
    (task_hdr ^ {|
fn del() -> String requires [dbWrite] =
  delete o from Task where o.id == "x"
  "ok"
|})

let test_e_select_no_cap_rejected () =
  should_fail "dbRead\\|privileged operations\\|does not declare"
    (task_hdr ^ {|
fn rd(id: String) -> Maybe Task requires [] =
  selectOne t from Task where t.id == id
|})

let test_e_select_with_cap_accepted () =
  should_pass
    (task_hdr ^ {|
fn rd(id: String) -> Maybe Task requires [dbRead] =
  selectOne t from Task where t.id == id
|})

(* dbRead is NOT enough for a write. *)
let test_e_delete_only_read_cap_rejected () =
  should_fail "dbWrite\\|privileged operations\\|does not declare"
    (task_hdr ^ {|
fn del() -> String requires [dbRead] =
  delete o from Task where o.id == "x"
  "ok"
|})

(* ── F. Decidable-comparison discipline (==/<) ───────────────────────────── *)

let ok_expr expr =
  should_pass (prim_hdr ^ Printf.sprintf "fn f(a: Int, b: Int) -> Bool = %s\n" expr)

let test_f_eq_int () = ok_expr "a == b"
let test_f_neq_int () = ok_expr "a != b"
let test_f_lt_int () = ok_expr "a < b"
let test_f_le_int () = ok_expr "a <= b"
let test_f_gt_int () = ok_expr "a > b"
let test_f_ge_int () = ok_expr "a >= b"

let test_f_eq_string () =
  should_pass (prim_hdr ^ "fn f(a: String, b: String) -> Bool = a == b\n")
let test_f_lt_string_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ "fn f(a: String, b: String) -> Bool = a < b\n")
let test_f_eq_bool () =
  should_pass (prim_hdr ^ "fn f(a: Bool, b: Bool) -> Bool = a == b\n")

let float_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Bool(..)]
import Tesl.Float exposing [Float]
|}
let test_f_eq_float () =
  should_pass (float_hdr ^ "fn f(a: Float, b: Float) -> Bool = a == b\n")
let test_f_lt_float () =
  should_pass (float_hdr ^ "fn f(a: Float, b: Float) -> Bool = a < b\n")

(* Functions as PARAMETERS — no decidable equality / order (S14 / TSS-2). *)
let test_f_eq_funparam_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ "fn f(g: (Int) -> Int, h: (Int) -> Int) -> Bool = g == h\n")
let test_f_neq_funparam_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ "fn f(g: (Int) -> Int, h: (Int) -> Int) -> Bool = g != h\n")
let test_f_lt_funparam_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ "fn f(g: (Int) -> Int, h: (Int) -> Int) -> Bool = g < h\n")

(* Functions as BARE top-level references (TSS-3): the type-based check infers
   None for these, so they used to slip through and emit `(equal? proc proc)`. *)
let test_f_eq_bare_fn_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn g(x: Int) -> Int = x
fn h(x: Int) -> Int = x
fn f() -> Bool = g == h
|})
let test_f_lt_bare_fn_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ {|
fn g(x: Int) -> Int = x
fn f() -> Bool = g < g
|})
let test_f_neq_bare_fn_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn g(x: Int) -> Int = x
fn f() -> Bool = g != g
|})

(* A NULLARY fn used bare is its RESULT (a value), not a function — equatable. *)
let test_f_nullary_fn_value_accepted () =
  should_pass
    (prim_hdr ^ {|
fn pi() -> Int = 3
fn f() -> Bool = pi == pi
|})

(* Generic type variables stay permissive by design (TSS-1 residual). *)
let test_f_eq_generic_tvar_accepted () =
  should_pass (prim_hdr ^ "fn f(a: a, b: a) -> Bool = a == b\n")
let test_f_lt_generic_tvar_accepted () =
  should_pass (prim_hdr ^ "fn f(a: a, b: a) -> Bool = a < b\n")

(* Record literals: `<` is a runtime-crashing bypass (HM-2) → rejected;
   `==` is structurally decidable → accepted. *)
let test_f_lt_record_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ {|
record R { x: Int }
fn f() -> Bool = R { x: 1 } < R { x: 2 }
|})
let test_f_eq_record_accepted () =
  should_pass
    (prim_hdr ^ {|
record R { x: Int }
fn f() -> Bool = R { x: 1 } == R { x: 2 }
|})

(* A newtype whose base is Int IS orderable; a newtype whose base is a function
   is NOT equatable (the recursive alias/newtype resolution). *)
let test_f_newtype_int_orderable_accepted () =
  should_pass
    (prim_hdr ^ {|
type Age = Int
fn f(a: Age, b: Age) -> Bool = a < b
|})
let test_f_newtype_fn_eq_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
type Callback = (Int) -> Int
fn f(a: Callback, b: Callback) -> Bool = a == b
|})

(* TS-ORD/EQ #1 (the real hole the retired shadow inferencer could not see): a
   non-orderable CONTAINER — the exact shape produced by stdlib results such as
   `String.toInt x : Maybe Int` — is ordered by NEITHER structural comparison; it
   must be rejected.  Driven purely from the HM-resolved operand type. *)
let test_f_lt_maybe_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(a: Maybe Int, b: Maybe Int) -> Bool = a < b
|})
(* …but a container of equatable elements IS structurally equatable (no over-reject). *)
let test_f_eq_maybe_int_accepted () =
  should_pass
    (prim_hdr ^ {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(a: Maybe Int, b: Maybe Int) -> Bool = a == b
|})
(* A container that transitively holds a function is NOT equatable (recurses into
   type arguments AND through the alias to the function base). *)
let test_f_eq_maybe_fn_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
import Tesl.Maybe exposing [Maybe(..)]
type Fn = (Int) -> Int
fn f(a: Maybe Fn, b: Maybe Fn) -> Bool = a == b
|})

(* S14b: a PARTIAL application of a top-level fn (supplied args < arity) is a
   function VALUE.  It infers a WRONG concrete return type at the comparison
   site (as if fully applied), so it slips past the inference-based check unless
   the syntactic function-value guard runs first — this was the residual left
   open when TSS-3 matched only a bare `EVar`.  A FULL application returns a
   concrete value and stays comparable (guards must not over-reject it). *)
let test_f_eq_partial_app_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool = (add 1) == (add 2)
|})
let test_f_lt_partial_app_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool = (add 1) < (add 2)
|})
let test_f_eq_full_app_accepted () =
  should_pass
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool = (add 1 2) == (add 3 4)
|})
let test_f_lt_full_app_accepted () =
  should_pass
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool = (add 1 2) < (add 3 4)
|})
(* Lambda literals are function values — never comparable. *)
let test_f_eq_lambda_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ "fn f() -> Bool = (fn(x: Int) -> x) == (fn(y: Int) -> y)\n")
let test_f_lt_lambda_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ "fn f() -> Bool = (fn(x: Int) -> x) < (fn(y: Int) -> y)\n")

(* A5: a LET-BOUND partial application (`let g = add 1`) is the residual left
   open after S14b: it infers the WRONG concrete return type at the ELet, so the
   bound name's env entry was `Int` (add's return) and the comparison slipped past
   BOTH the type-based check and the AST-shape allowlist (which never saw a bare
   EApp — only an EVar).  Decide-by-resolution: infer_expr_type now resolves an
   under-applied call to a real curried TFun, so is_equatable/is_orderable reject
   the let-bound name directly; the error renders the inferred arrow type key
   (e.g. `Int -> Int`).  The AST-shape guard operand_is_function_valued is deleted. *)
let test_f_eq_letbound_partial_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool =
  let g = add 1
  let h = add 2
  g == h
|})
let test_f_neq_letbound_partial_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool =
  let g = add 1
  let h = add 2
  g != h
|})
(* Exact A5 example: one let-bound side, one bare-partial side. *)
let test_f_eq_letbound_vs_partial_rejected () =
  should_fail "equality operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool =
  let g = add 1
  g == (add 2)
|})
let test_f_lt_letbound_partial_rejected () =
  should_fail "ordering operator.*not defined for type"
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool =
  let g = add 1
  let h = add 2
  g < h
|})
(* A let-bound FULL application still infers a concrete comparable value and is
   accepted — the fix must not over-reject the aliased fully-applied form. *)
let test_f_eq_letbound_full_app_accepted () =
  should_pass
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn f() -> Bool =
  let x = add 1 2
  let y = add 3 4
  x == y
|})
(* Partial application still USABLE as a closure applied later (lesson13 pattern) —
   accepted; the arrow inference must not leak into non-comparison positions. *)
let test_f_letbound_partial_applied_later_accepted () =
  should_pass
    (prim_hdr ^ {|
fn add(x: Int, y: Int) -> Int = x + y
fn inc(n: Int) -> Int =
  let addOne = add 1
  addOne n
|})

(* ── G. ForAll list-proof consistency (§6.3 / S9 / S9-EField) ─────────────── *)

let forall_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Bool(..), Int, List]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

(* A bare list VARIABLE with no tracked per-element proof cannot satisfy ForAll. *)
let test_g_forall_bare_var_rejected () =
  should_fail "no tracked .ForAll. proof"
    (forall_hdr ^ {|
fn f(xs: List Int) -> List Int ? ForAll IsPositive = xs
|})

(* S9-EField: a record field access carries no per-element proof, so returning it
   at a ForAll position is a smuggle. *)
let test_g_forall_field_smuggle_rejected () =
  should_fail "does not establish .ForAll"
    (forall_hdr ^ {|
record W { items: List Int }
fn f(w: W) -> List Int ? ForAll IsPositive = w.items
|})

(* §6.3: a non-empty list LITERAL mints no per-element proof. *)
let test_g_forall_list_literal_rejected () =
  should_fail "does not establish .ForAll"
    (forall_hdr ^ {|
fn f() -> List Int ? ForAll IsPositive = [1, 2, 3]
|})

(* [] satisfies ForAll vacuously. *)
let test_g_forall_empty_list_accepted () =
  should_pass
    (forall_hdr ^ {|
fn f() -> List Int ? ForAll IsPositive = []
|})

(* List.filterCheck with a real check fn establishes ForAll on every survivor. *)
let test_g_forall_filtercheck_accepted () =
  should_pass
    (forall_hdr ^ {|
fn f(xs: List Int) -> List Int ? ForAll IsPositive = List.filterCheck checkPos xs
|})

(* ── H. Handler↔endpoint positional arity contract (S16) ─────────────────── *)

let arity_hdr = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.Http exposing [HttpRequest]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Dict exposing [Dict.lookup]
record NewT { title: String }
codec NewT { toJson_forbidden fromJson [ { title <- "title" with_codec stringCodec } ] }
fact Authed (u: String)
auth theAuth(request: HttpRequest) -> u: String ::: Authed u =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something u -> ok u ::: Authed u
capturer tCap: id: String using stringCodec
|}

let arity_pat = "supplies .* positionally\\|arity mismatch"

(* auth + body ⇒ 2 supplied; handler with 2 params is correct. *)
let test_h_arity_auth_body_correct () =
  should_pass
    (arity_hdr ^ {|
handler h(u: String ::: Authed u, body: NewT) -> String requires [] = body.title
api A { post "/t" auth u: String ::: Authed u via theAuth body body: NewT -> String }
server S for A { h = h }
|})

(* handler drops the body param (1 param, 2 supplied) ⇒ rejected. *)
let test_h_arity_too_few_rejected () =
  should_fail arity_pat
    (arity_hdr ^ {|
handler h(u: String ::: Authed u) -> String requires [] = u
api A { post "/t" auth u: String ::: Authed u via theAuth body body: NewT -> String }
server S for A { h = h }
|})

(* handler has an extra param (3 params, 2 supplied) ⇒ rejected. *)
let test_h_arity_too_many_rejected () =
  should_fail arity_pat
    (arity_hdr ^ {|
handler h(u: String ::: Authed u, body: NewT, extra: String) -> String requires [] = body.title
api A { post "/t" auth u: String ::: Authed u via theAuth body body: NewT -> String }
server S for A { h = h }
|})

(* auth + capture ⇒ 2 supplied; handler with 2 params is correct. *)
let test_h_arity_auth_capture_correct () =
  should_pass
    (arity_hdr ^ {|
handler h(u: String ::: Authed u, id: String) -> String requires [] = id
api A { get "/t/:id" auth u: String ::: Authed u via theAuth capture id: String via tCap -> String }
server S for A { h = h }
|})

(* handler drops the capture param (1 param, 2 supplied) ⇒ rejected. *)
let test_h_arity_capture_missing_rejected () =
  should_fail arity_pat
    (arity_hdr ^ {|
handler h(u: String ::: Authed u) -> String requires [] = u
api A { get "/t/:id" auth u: String ::: Authed u via theAuth capture id: String via tCap -> String }
server S for A { h = h }
|})

let () =
  run "Wave2-Soundness" [
    "A-fromdb-shadow-forgery", List.map make_shadow_case sql_builtins;
    "B-plain-fromdb-forgery", [
      test_case "plain construct" `Quick test_b_plain_construct;
      test_case "let body" `Quick test_b_let_body;
      test_case "if body" `Quick test_b_if_body;
      test_case "case body" `Quick test_b_case_body;
    ];
    "C-legit-fromdb", [
      test_case "real selectOne accepted" `Quick test_c_real_selectone;
      test_case "named-pack ? FromDb accepted" `Quick test_c_named_pack;
      test_case "param passthrough accepted" `Quick test_c_param_passthrough;
      test_case "shadow name without forgery accepted" `Quick test_c_shadow_name_no_forgery;
    ];
    "D-queue-provenance-forgery", [
      test_case "FromQueue plain rejected" `Quick test_d_fromqueue_plain;
      test_case "FromDeadQueue plain rejected" `Quick test_d_fromdeadqueue_plain;
      test_case "FromQueue with real DB still rejected" `Quick test_d_fromqueue_with_db_still_rejected;
    ];
    "E-capability-laundering", [
      test_case "delete requires [] rejected" `Quick test_e_delete_no_cap_rejected;
      test_case "delete requires [dbWrite] accepted" `Quick test_e_delete_with_cap_accepted;
      test_case "selectOne requires [] rejected" `Quick test_e_select_no_cap_rejected;
      test_case "selectOne requires [dbRead] accepted" `Quick test_e_select_with_cap_accepted;
      test_case "delete requires [dbRead] (read-only) rejected" `Quick test_e_delete_only_read_cap_rejected;
    ];
    "F-decidable-comparison", [
      test_case "== Int accepted" `Quick test_f_eq_int;
      test_case "!= Int accepted" `Quick test_f_neq_int;
      test_case "< Int accepted" `Quick test_f_lt_int;
      test_case "<= Int accepted" `Quick test_f_le_int;
      test_case "> Int accepted" `Quick test_f_gt_int;
      test_case ">= Int accepted" `Quick test_f_ge_int;
      test_case "== String accepted" `Quick test_f_eq_string;
      test_case "< String rejected" `Quick test_f_lt_string_rejected;
      test_case "== Bool accepted" `Quick test_f_eq_bool;
      test_case "== Float accepted" `Quick test_f_eq_float;
      test_case "< Float accepted" `Quick test_f_lt_float;
      test_case "== fn-param rejected" `Quick test_f_eq_funparam_rejected;
      test_case "!= fn-param rejected" `Quick test_f_neq_funparam_rejected;
      test_case "< fn-param rejected" `Quick test_f_lt_funparam_rejected;
      test_case "== bare-fn rejected (TSS-3)" `Quick test_f_eq_bare_fn_rejected;
      test_case "< bare-fn rejected (TSS-3)" `Quick test_f_lt_bare_fn_rejected;
      test_case "!= bare-fn rejected (TSS-3)" `Quick test_f_neq_bare_fn_rejected;
      test_case "nullary fn value == accepted" `Quick test_f_nullary_fn_value_accepted;
      test_case "== generic tvar accepted" `Quick test_f_eq_generic_tvar_accepted;
      test_case "< generic tvar accepted" `Quick test_f_lt_generic_tvar_accepted;
      test_case "< record literal rejected (HM-2)" `Quick test_f_lt_record_rejected;
      test_case "== record accepted" `Quick test_f_eq_record_accepted;
      test_case "< newtype-of-Int accepted" `Quick test_f_newtype_int_orderable_accepted;
      test_case "== newtype-of-fn rejected" `Quick test_f_newtype_fn_eq_rejected;
      test_case "< Maybe rejected (#1 stdlib-result hole)" `Quick test_f_lt_maybe_rejected;
      test_case "== Maybe Int accepted (equatable container)" `Quick test_f_eq_maybe_int_accepted;
      test_case "== Maybe-of-fn rejected (transitive)" `Quick test_f_eq_maybe_fn_rejected;
      test_case "== partial-app rejected (S14b)" `Quick test_f_eq_partial_app_rejected;
      test_case "< partial-app rejected (S14b)" `Quick test_f_lt_partial_app_rejected;
      test_case "== full-app accepted (no over-reject)" `Quick test_f_eq_full_app_accepted;
      test_case "< full-app accepted (no over-reject)" `Quick test_f_lt_full_app_accepted;
      test_case "== lambda rejected (S14b)" `Quick test_f_eq_lambda_rejected;
      test_case "< lambda rejected (S14b)" `Quick test_f_lt_lambda_rejected;
      test_case "== let-bound partial rejected (A5)" `Quick test_f_eq_letbound_partial_rejected;
      test_case "!= let-bound partial rejected (A5)" `Quick test_f_neq_letbound_partial_rejected;
      test_case "== let-bound vs bare-partial rejected (A5)" `Quick test_f_eq_letbound_vs_partial_rejected;
      test_case "< let-bound partial rejected (A5)" `Quick test_f_lt_letbound_partial_rejected;
      test_case "== let-bound full-app accepted (A5 no over-reject)" `Quick test_f_eq_letbound_full_app_accepted;
      test_case "let-bound partial applied later accepted (A5 lesson13)" `Quick test_f_letbound_partial_applied_later_accepted;
    ];
    "G-forall-list-proofs", [
      test_case "bare var at ForAll rejected" `Quick test_g_forall_bare_var_rejected;
      test_case "field access at ForAll rejected (S9-EField)" `Quick test_g_forall_field_smuggle_rejected;
      test_case "non-empty list literal at ForAll rejected" `Quick test_g_forall_list_literal_rejected;
      test_case "empty list at ForAll accepted" `Quick test_g_forall_empty_list_accepted;
      test_case "filterCheck at ForAll accepted" `Quick test_g_forall_filtercheck_accepted;
    ];
    "H-handler-endpoint-arity", [
      test_case "auth+body correct arity accepted" `Quick test_h_arity_auth_body_correct;
      test_case "too few params rejected" `Quick test_h_arity_too_few_rejected;
      test_case "too many params rejected" `Quick test_h_arity_too_many_rejected;
      test_case "auth+capture correct arity accepted" `Quick test_h_arity_auth_capture_correct;
      test_case "missing capture param rejected" `Quick test_h_arity_capture_missing_rejected;
    ];
  ]
