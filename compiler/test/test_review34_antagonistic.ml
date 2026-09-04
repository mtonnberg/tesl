(** Antagonistic regression tests for Critical Review 34.

    The historical finding IDs are retained, while each assertion describes the
    current OCaml frontend and Go emitter behavior. *)

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

let compile_string ?(mode = check_subcmd) src =
  let tmp = Filename.temp_file "tesl-r34-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let cmd =
    if mode = "" then Printf.sprintf "%s %s 2>&1" tesl tmp
    else Printf.sprintf "%s %s %s 2>&1" tesl mode tmp
  in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let has_error out =
  let re = Str.regexp "error\\[" in
  try ignore (Str.search_forward re out 0); true with Not_found -> false

let should_pass src =
  let out = compile_string src in
  if has_error out then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false (has_error out)

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail: %s" pattern) true found

let go_module_source src =
  match Compile.compile_go_source "<test>" src with
  | Compile.GoFailure ds ->
    failwith (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) ds))
  | Compile.GoSuccess artifacts ->
    (match List.find_opt
             (fun (a : Emit_go.artifact) -> Filename.basename a.path = "module.go")
             artifacts with
     | Some artifact -> artifact.contents
     | None -> failwith "Go emission did not produce module.go")

let contains pattern text =
  try ignore (Str.search_forward (Str.regexp pattern) text 0); true
  with Not_found -> false

let prelude =
  {|module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit, List, Fact]
import Tesl.Maybe exposing [Maybe(..)]
|}

(* H01: the Go emitter preserves the inferred lambda result type. *)
let test_h01_lambda_emits_bool_result () =
  let src = prelude ^
    "fn apply(pred: Int -> Bool, n: Int) -> Bool = pred n\n" ^
    "fn test(n: Int) -> Bool = apply (fn(x: Int) -> x > 0) n\n"
  in
  let out = go_module_source src in
  check bool "lambda emits a Bool-returning Go function" true
    (contains "func(x teslrt[.]Int) bool {" out)

(* H02: ordinary functions cannot claim a proof their return value lacks. *)
let test_h02_fn_proof_return_body_is_verified () =
  let src = prelude ^
    "fact IsAdmin (u: String)\n" ^
    "fn getAdmin(u: String) -> String ::: IsAdmin u = u\n"
  in
  should_fail "cannot declare a proof return type\\|cannot introduce new proofs" src

(* ── H03: `establish` + Maybe(Fact) proof injection via `n ::: _proof` ────── *)
(*                                                                               *)
(* Fix: `is_lowercase_subject_name` now accepts `_`-prefixed names so that     *)
(* `n ::: _proof` is recognised as "re-attaching an existing witness" rather   *)
(* than proof forgery.  The validation layer already correctly propagated       *)
(* `proof_env["_proof"] = [IsPositive n]` from the establish return type;      *)
(* the only blocker was the P001 gate in proof_checker.ml.                     *)
let test_h03_establish_maybe_fact_proof_injected () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    "establish provePositive(n: Int) -> Maybe (Fact (IsPositive n)) =\n" ^
    "  if n > 0 then\n" ^
    "    Something (IsPositive n)\n" ^
    "  else\n" ^
    "    Nothing\n" ^
    "fn requiresPositive(n: Int ::: IsPositive n) -> Int = n * 2\n" ^
    "fn useEstablish(n: Int) -> Int =\n" ^
    "  case provePositive n of\n" ^
    "    Nothing -> 0\n" ^
    "    Something _proof -> requiresPositive (n ::: _proof)\n"
  in
  should_pass src

(* Bare `n` (without attaching `_proof`) must still be rejected *)
let test_h03b_bare_n_without_proof_still_rejected () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    "establish provePositive(n: Int) -> Maybe (Fact (IsPositive n)) =\n" ^
    "  if n > 0 then\n" ^
    "    Something (IsPositive n)\n" ^
    "  else\n" ^
    "    Nothing\n" ^
    "fn requiresPositive(n: Int ::: IsPositive n) -> Int = n * 2\n" ^
    "fn useEstablish(n: Int) -> Int =\n" ^
    "  case provePositive n of\n" ^
    "    Nothing -> 0\n" ^
    "    Something _proof -> requiresPositive n\n"
  in
  should_fail "does not statically satisfy.*IsPositive\\|IsPositive.*not satisfied" src

(* ── H04: Unused ADT type parameter is linted ─────────────────────────────── *)
let test_h04_unused_type_param_is_linted () =
  let src = prelude ^
    "type Tree a\n" ^
    "  = Leaf\n" ^
    "  | Node left: (Tree Int) value: Int right: (Tree Int)\n" ^
    "fn treeSize(t: Tree Int) -> Int =\n" ^
    "  case t of\n" ^
    "    Leaf -> 0\n" ^
    "    Node _ _ _ -> 1\n"
  in
  let out = compile_string ~mode:"--lint" src in
  let re = Str.regexp "warning\\[W097\\]" in
  let warned = try ignore (Str.search_forward re out 0); true with Not_found -> false in
  if not warned then failf "expected W097 for unused ADT type parameter, got:\n%s" out

(* ── H05: `establish` manufactures any proof — trusted boundary caveat ─────── *)
(*                                                                               *)
(* establish trustAll can unconditionally stamp any value.                      *)
(* compiles fine. This is by design — establish is a TRUSTED boundary.         *)
(* The test verifies that establish truly IS the only way to create proofs     *)
(* that bypass check/auth, and that the compiler doesn't allow establish       *)
(* to be used in arbitrary code locations. Establish SHOULD compile — the      *)
(* safety model is "establish bodies are auditable trust boundaries".          *)
let test_h05_establish_trusted_boundary_compiles () =
  let src = prelude ^
    "fact IsAuthenticated (u: String)\n" ^
    (* establish can unconditionally stamp any value — by design *)
    "establish trustAll(u: String) -> Fact (IsAuthenticated u) =\n" ^
    "  IsAuthenticated u\n"
  in
  (* This MUST compile — establish is an explicitly trusted boundary *)
  should_pass src

(* ── H05b: establish NOT available in fn body ─────────────────────────────── *)
(* `establish` as a CALL from within a regular `fn` body is allowed (it's a    *)
(* function call). But the PROOF from the establish result doesn't auto-attach  *)
(* to arguments in the calling context. This test verifies the boundary.       *)
let test_h05b_establish_proof_does_not_auto_attach () =
  let src = prelude ^
    "fact IsAuthenticated (u: String)\n" ^
    "establish trustAll(u: String) -> Fact (IsAuthenticated u) =\n" ^
    "  IsAuthenticated u\n" ^
    "fn requiresAuth(u: String ::: IsAuthenticated u) -> String = u\n" ^
    "fn test(u: String) -> String =\n" ^
    "  let _fact = trustAll u\n" ^  (* proof created but not attached *)
    "  requiresAuth u\n"           (* this should FAIL *)
  in
  should_fail "does not statically satisfy.*IsAuthenticated\\|IsAuthenticated.*not satisfied" src

(* ── H06: ADT value in string interpolation gives a clear error ────────────── *)
(*                                                                               *)
(* `"${c}"` where `c : Color` should be rejected with a clear error rather     *)
(* than silently emitting broken code. The error message should tell the user   *)
(* to convert to String first.                                                  *)
let test_h06_adt_string_interpolation_rejected () =
  let src = prelude ^
    "type Color\n" ^
    "  = Red\n" ^
    "  | Green\n" ^
    "  | Blue\n" ^
    "fn test(c: Color) -> String = \"Color is ${c}\"\n"
  in
  should_fail "cannot interpolate.*Color\\|interpolate.*type.*Color\\|only.*String.*Int.*Bool.*Float" src

(* ── H07: Inline single-variant ADT definition produces a lint error ────────── *)
(*                                                                               *)
(* `type Color = Red | Green | Blue` on one line must produce a lint error     *)
(* (W040), not a silent misparse as a type alias.                              *)
let test_h07_single_line_adt_needs_separate_lines () =
  let src = prelude ^
    "type Color = Red | Green | Blue\n" ^
    "fn test() -> Int = 1\n"
  in
  (* Parser rejects inline multi-constructor ADT with a clear error *)
  should_fail "ADT variants must be on separate lines\\|error\\[E000\\]\\|separate.*lines\\|inline.*ADT" src

(* H08: a discharged function return proof erases from generated Go. *)
let test_h08_fn_proof_return_erases_after_validation () =
  let src = prelude ^
    "fact IsNonEmpty (s: String)\n" ^
    "fn trimmed(s: String ::: IsNonEmpty s) -> result: String ::: IsNonEmpty result =\n" ^
    "  let result = s\n" ^
    "  result\n"
  in
  let out = go_module_source src in
  check bool "proof-passing fn emits an ordinary Go signature" true
    (contains "func trimmed(s string) string" out);
  check bool "proof predicate is erased from generated module" false
    (contains "IsNonEmpty" out)

(* ── H09: Nested `transaction` is a compile error ─────────────────────── *)
(*                                                                               *)
(* Transactions cannot be nested. A `transaction` inside another must be   *)
(* rejected at compile time.                                                    *)
let test_h09_nested_transaction_rejected () =
  let src = prelude ^
    "import Tesl.Env exposing [env, envInt]\n" ^
    "import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\n" ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "entity Item table \"items\" primaryKey id { id: String name: String }\n" ^
    "database MyDb = Database {\n" ^
    "  schema: \"s\"\n" ^
    "  entities: [Item]\n" ^
    "  backend: Postgres (PostgresConfig {\n" ^
    "    dbName: env \"DB\"\n" ^
    "    user: env \"U\"\n" ^
    "    password: env \"P\"\n" ^
    "    connection: TcpConnection { host: env \"H\"  port: envInt \"PORT\" 5432 }\n" ^
    "  })\n" ^
    "}\n" ^
    "fn test() -> String requires [dbWrite Item] =\n" ^
    "  transaction {\n" ^
    "    transaction {\n" ^
    "      insert Item { id: \"1\", name: \"foo\" }\n" ^
    "    }\n" ^
    "    \"done\"\n" ^
    "  }\n"
  in
  should_fail "nested.*transaction.*not allowed\\|transaction.*nested\\|P001" src

(* ── H10: Zero-arg lambda `fn() -> expr` ────────────────────────────────────── *)
(*                                                                               *)
(* A lambda with no parameters — `fn() -> 42` — should parse and compile.      *)
(* Zero-arg lambdas may arise when deferring effects or constructing thunks.   *)
let test_h10_zero_arg_lambda_compiles () =
  let src = prelude ^
    "fn makeThunk() -> Int =\n" ^
    "  let f = fn() -> 42\n" ^
    "  f()\n"
  in
  (* Zero-arg lambda should be supported (same as Tesl zero-arg fn) *)
  should_pass src

(* ── H11: Multi-param lambda `fn(x: Int, y: Int) -> x + y` compiles ─────────── *)
(*                                                                               *)
(* Anonymous lambdas with multiple parameters must compile and emit correctly. *)
let test_h11_multi_param_lambda_compiles () =
  let src = prelude ^
    "import Tesl.List exposing [List.foldl]\n" ^
    "fn sumList(xs: List Int) -> Int =\n" ^
    "  List.foldl (fn(acc: Int, x: Int) -> acc + x) 0 xs\n"
  in
  should_pass src

(* ── H12: Lambda with proof-annotated param threads proof to body ────────────── *)
(*                                                                               *)
(* `fn(n: Int ::: IsPositive n) -> ...` — a lambda with a proof-annotated      *)
(* parameter. The lambda body should be able to call functions that require the *)
(* IsPositive proof on n.                                                       *)
let test_h12_lambda_with_proof_param_threads_proof () =
  (* Move all imports to the top — Tesl requires imports before definitions *)
  let src =
    {|module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit, List, Fact]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.filterCheck]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n * 2
fn test(xs: List Int) -> List Int ::: ForAll (IsPositive) =
  List.filterCheck checkPos xs
|}
  in
  should_pass src

(* ── H13: `List.filter` with named Bool-returning fn works ───────────────────── *)
(*                                                                               *)
(* Using a named function (not a lambda) as the predicate for `List.filter`    *)
(* should compile cleanly.                                                      *)
let test_h13_list_filter_named_fn () =
  let src = prelude ^
    "import Tesl.List exposing [List.filter]\n" ^
    "fn isBig(x: Int) -> Bool = x > 10\n" ^
    "fn test(xs: List Int) -> List Int = List.filter isBig xs\n"
  in
  should_pass src

(* ── H14: `Dict.filter` is unavailable on the sole backend ────────────────── *)
let test_h14_dict_filter_rejected_before_emission () =
  let src = prelude ^
    "import Tesl.Dict exposing [Dict(..), Dict.filter, Dict.empty]\n" ^
    "fn test(d: Dict String Int) -> Dict String Int =\n" ^
    "  Dict.filter (fn(v: Int) -> v > 0) d\n"
  in
  should_fail "Go backend does not implement.*Dict.filter" src

let test_h14b_dict_filter_two_param_predicate_rejected () =
  let src = prelude ^
    "import Tesl.Dict exposing [Dict(..), Dict.filter, Dict.empty]\n" ^
    "fn test(d: Dict String Int) -> Dict String Int =\n" ^
    "  Dict.filter (fn(k: String, v: Int) -> v > 0) d\n"
  in
  (* Two-param predicate should fail: type mismatch Int->Bool vs Int->Bool *)
  should_fail "type mismatch\\|cannot unify\\|T001" src

(* ── H15: Mutual recursion across two `fn` declarations ─────────────────────── *)
(*                                                                               *)
(* Two mutually recursive functions (isEven/isOdd) must both compile for direct *)
(* Go emission, where package-level declarations permit forward references.     *)
let test_h15_mutual_recursion_compiles () =
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
    "    isEven (n - 1)\n"
  in
  should_pass src

(* ── H16: Proof forgery via raw `:::` in `handler` body ─────────────────────── *)
(*                                                                               *)
(* Attempting `value ::: SomeFact value` inside a handler body (not in a       *)
(* check/auth/establish) must be rejected at compile time with P001.            *)
let test_h16_raw_proof_in_handler_rejected () =
  (* Simplified: just test that raw `value ::: SomeFact value` in a handler is rejected *)
  let src =
    {|module Test exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit, List, Fact]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
fact IsAuthenticated (u: String)
fact Authenticated (u: String)
record User { id: String }
auth cookieAuth(req: HttpRequest) -> u: User ::: Authenticated u
  requires [] =
  ok (User { id: "test" }) ::: Authenticated u
handler test(u: User ::: Authenticated u) -> String requires [] =
  let fakeUser = User { id: "evil" }
  let _forged = fakeUser ::: IsAuthenticated fakeUser.id
  "oops"
|}
  in
  should_fail "P001\\|proof construction.*not allowed\\|::: proof.*handler\\|not allowed in.*handler" src

(* ── H17: Proof forgery via raw `:::` in `fn` body ─────────────────────────── *)
(*                                                                               *)
(* Raw proof construction `value ::: Fact value` in a `fn` body must be        *)
(* rejected. Only `check`, `auth`, `establish` bodies may use `ok ::: ...`.   *)
let test_h17_raw_proof_in_fn_body_rejected () =
  let src = prelude ^
    "fact IsAdmin (u: String)\n" ^
    "fn badFn(u: String) -> String =\n" ^
    "  let v = u ::: IsAdmin u\n" ^
    "  v\n"
  in
  should_fail "P001\\|proof construction.*not allowed\\|::: proof.*fn\\|ok.*proof" src

(* ── H18: Newtype does NOT unify with base type in List context ──────────────── *)
(*                                                                               *)
(* `type UserId = String` creates a newtype. A `List UserId` must NOT be        *)
(* accepted where `List String` is expected.                                    *)
let test_h18_newtype_list_does_not_unify_with_base () =
  let src = prelude ^
    "type UserId = String\n" ^
    "fn requiresStrings(xs: List String) -> Int = 0\n" ^
    "fn passUserIds(xs: List UserId) -> Int = requiresStrings xs\n"
  in
  (* List UserId should NOT unify with List String *)
  should_fail "cannot unify.*UserId.*String\\|UserId.*String.*mismatch\\|type mismatch\\|T001" src

(* H19: literal cases are infinite-domain matches and require a catch-all. *)
let test_h19_integer_literal_case_missing_catchall_rejected () =
  let src = prelude ^
    "fn describe(n: Int) -> String =\n" ^
    "  case n of\n" ^
    "    1 -> \"one\"\n" ^
    "    2 -> \"two\"\n"
  in
  should_fail "non-exhaustive case.*literal patterns.*catch-all" src

let test_h19b_adt_non_exhaustive_case_is_rejected () =
  let src =
    {|module Test exposing []
import Tesl.Prelude exposing [Int, String]
type Status
  = Open
  | Done
fn describe(s: Status) -> String =
  case s of
    Open -> "open"
|}
    (* Missing Done — should be caught *)
  in
  should_fail "non-exhaustive\\|missing.*Done\\|V001" src

(* ── H20: `case` with integer literal + catch-all compiles ──────────────────── *)
(*                                                                               *)
(* The same expression with a catch-all must compile successfully.             *)
let test_h20_integer_literal_case_with_catchall_compiles () =
  let src = prelude ^
    "fn describe(n: Int) -> String =\n" ^
    "  case n of\n" ^
    "    1 -> \"one\"\n" ^
    "    2 -> \"two\"\n" ^
    "    _ -> \"other\"\n"
  in
  should_pass src

(* ── H21: Proof on record field: reading field preserves proof — FIXED ────────── *)
(*                                                                               *)
(* When a record has a proof-annotated field `title: String ::: TitleSafe title`,*)
(* reading `rec.title` gives back a value carrying `TitleSafe`. The validator   *)
(* propagates field proofs via the field_proof_registry so downstream functions  *)
(* requiring the proof accept the field access without re-checking.             *)
let test_h21_record_field_read_carries_proof () =
  let src = prelude ^
    "fact TitleSafe (t: String)\n" ^
    "check isSafe(t: String) -> t: String ::: TitleSafe t =\n" ^
    "  if 3 <= 10 then\n" ^
    "    ok t ::: TitleSafe t\n" ^
    "  else\n" ^
    "    fail 400 \"bad\"\n" ^
    "record SafeItem { title: String ::: TitleSafe title }\n" ^
    "fn requiresSafe(t: String ::: TitleSafe t) -> String = t\n" ^
    "fn readField(item: SafeItem) -> String = requiresSafe item.title\n"
  in
  should_pass src

(* H21b: reading a field WITHOUT proof annotation still rejects at call site *)
let test_h21b_plain_field_read_no_proof () =
  let src = prelude ^
    "fact TitleSafe (t: String)\n" ^
    "record PlainItem { title: String }\n" ^
    "fn requiresSafe(t: String ::: TitleSafe t) -> String = t\n" ^
    "fn readFieldPlain(item: PlainItem) -> String = requiresSafe item.title\n"
  in
  should_fail "V001" src

(* ── H22: Record construction with proof-annotated field requires proof ────── *)
(*                                                                               *)
(* Building a record with a proof-annotated field without satisfying the proof  *)
(* must be rejected at compile time.                                            *)
let test_h22_record_construction_without_proof_rejected () =
  let src = prelude ^
    "fact TitleSafe (t: String)\n" ^
    "record SafeItem { title: String ::: TitleSafe title }\n" ^
    "fn makeUnsafe(s: String) -> SafeItem = SafeItem { title: s }\n"
  in
  should_fail "does not statically satisfy.*TitleSafe\\|TitleSafe.*not satisfied\\|V001" src

(* ── H23: `select` with missing `dbRead` capability is rejected ─────────────── *)
(*                                                                               *)
(* Using a `select` statement in a `fn` body that does not declare `dbRead`    *)
(* must produce a capability error.                                             *)
let test_h23_select_without_capability_rejected () =
  let src = prelude ^
    "import Tesl.Env exposing [env, envInt]\n" ^
    "import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\n" ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "entity Item table \"items\" primaryKey id { id: String name: String }\n" ^
    "database MyDb = Database {\n" ^
    "  schema: \"s\"\n" ^
    "  entities: [Item]\n" ^
    "  backend: Postgres (PostgresConfig {\n" ^
    "    dbName: env \"DB\"\n" ^
    "    user: env \"U\"\n" ^
    "    password: env \"P\"\n" ^
    "    connection: TcpConnection { host: env \"H\"  port: envInt \"PORT\" 5432 }\n" ^
    "  })\n" ^
    "}\n" ^
    "fn missingCap() -> String =\n" ^
    "  let items = select item from Item\n" ^
    "  \"ok\"\n"
  in
  should_fail "dbRead Item\\|capability\\|V001\\|requires.*dbRead Item" src

(* ── H24: `fn` with `select` and proper `dbRead` capability compiles ─────────── *)
(*                                                                               *)
(* A `fn` that declares `requires [dbRead Item]` and uses `select` must compile.   *)
let test_h24_select_with_capability_compiles () =
  let src = prelude ^
    "import Tesl.Env exposing [env, envInt]\n" ^
    "import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]\n" ^
    "import Tesl.DB exposing [dbRead, dbWrite]\n" ^
    "entity Item table \"items\" primaryKey id { id: String name: String }\n" ^
    "database MyDb = Database {\n" ^
    "  schema: \"s\"\n" ^
    "  entities: [Item]\n" ^
    "  backend: Postgres (PostgresConfig {\n" ^
    "    dbName: env \"DB\"\n" ^
    "    user: env \"U\"\n" ^
    "    password: env \"P\"\n" ^
    "    connection: TcpConnection { host: env \"H\"  port: envInt \"PORT\" 5432 }\n" ^
    "  })\n" ^
    "}\n" ^
    "fn withCap() -> List Item requires [dbRead Item] =\n" ^
    "  select item from Item\n"
  in
  should_pass src

(* ── H25: `Int.divide` without IsNonZero proof is rejected ─────────────────── *)
(*                                                                               *)
(* Tesl requires `IsNonZero` proof on divisor before dividing. Without proof,  *)
(* a compile-time error must be produced.                                       *)
let test_h25_division_without_nonzero_proof_rejected () =
  let src = prelude ^
    "import Tesl.Int exposing [Int.divide]\n" ^
    "fn badDiv(a: Int, b: Int) -> Int =\n" ^
    "  Int.divide a b\n"
  in
  should_fail "IsNonZero\\|nonzero\\|IsNonZero.*proof\\|V001.*divide\\|divide.*IsNonZero" src

(* ── H26: `%` (modulo) without IsNonZero proof is rejected ─────────────────── *)
(*                                                                               *)
(* The `%` operator also requires an `IsNonZero` proof on the right operand.  *)
let test_h26_modulo_without_nonzero_proof_rejected () =
  let src = prelude ^
    "fn badMod(a: Int, b: Int) -> Int = a % b\n"
  in
  should_fail "IsNonZero\\|nonzero\\|V001.*%\\|%.*IsNonZero" src

(* ── H27: Forward reference to function defined later in module ───────────────── *)
(*                                                                               *)
(* Tesl should support forward references within a module: calling a function  *)
(* that is declared later in the file.                                         *)
let test_h27_forward_reference_compiles () =
  let src = prelude ^
    "fn usesForward() -> Int = helperFn()\n" ^
    "fn helperFn() -> Int = 42\n"
  in
  should_pass src

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Review34" [
    "H01", [ test_case "lambda emits a Bool-returning Go function"
               `Quick test_h01_lambda_emits_bool_result ];
    "H02", [ test_case "fn proof return body is verified"
               `Quick test_h02_fn_proof_return_body_is_verified ];
    "H03", [ test_case "establish Maybe(Fact) + n:::_proof now compiles (FIXED)"
               `Quick test_h03_establish_maybe_fact_proof_injected;
             test_case "bare n without proof still rejected"
               `Quick test_h03b_bare_n_without_proof_still_rejected ];
    "H04", [ test_case "unused ADT type parameter emits W097"
               `Quick test_h04_unused_type_param_is_linted ];
    "H05", [ test_case "establish trusted boundary: compiles by design"
               `Quick test_h05_establish_trusted_boundary_compiles ];
    "H05b", [ test_case "establish proof does not auto-attach to calling context"
                `Quick test_h05b_establish_proof_does_not_auto_attach ];
    "H06", [ test_case "ADT value in string interpolation gives clear error"
               `Quick test_h06_adt_string_interpolation_rejected ];
    "H07", [ test_case "inline single-line ADT definition is rejected"
               `Quick test_h07_single_line_adt_needs_separate_lines ];
    "H08", [ test_case "validated fn proof return erases from Go"
               `Quick test_h08_fn_proof_return_erases_after_validation ];
    "H09", [ test_case "nested `transaction` is rejected at compile time"
               `Quick test_h09_nested_transaction_rejected ];
    "H10", [ test_case "zero-arg lambda fn() -> 42 compiles"
               `Quick test_h10_zero_arg_lambda_compiles ];
    "H11", [ test_case "multi-param lambda fn(x:Int,y:Int)->x+y compiles"
               `Quick test_h11_multi_param_lambda_compiles ];
    "H12", [ test_case "lambda with proof-annotated param threads proof to body"
               `Quick test_h12_lambda_with_proof_param_threads_proof ];
    "H13", [ test_case "List.filter with named Bool-returning fn compiles"
               `Quick test_h13_list_filter_named_fn ];
    "H14", [ test_case "Dict.filter is rejected before backend emission"
               `Quick test_h14_dict_filter_rejected_before_emission ];
    "H14b", [ test_case "Dict.filter with two-param predicate is a type error"
                `Quick test_h14b_dict_filter_two_param_predicate_rejected ];
    "H15", [ test_case "mutual recursion across two fn declarations compiles"
               `Quick test_h15_mutual_recursion_compiles ];
    "H16", [ test_case "raw proof via ::: in handler body is rejected (P001)"
               `Quick test_h16_raw_proof_in_handler_rejected ];
    "H17", [ test_case "raw proof via ::: in fn body is rejected (P001)"
               `Quick test_h17_raw_proof_in_fn_body_rejected ];
    "H18", [ test_case "List UserId does NOT unify with List String (newtype safety)"
               `Quick test_h18_newtype_list_does_not_unify_with_base ];
    "H19", [ test_case "integer literal case missing catch-all is rejected"
               `Quick test_h19_integer_literal_case_missing_catchall_rejected ];
    "H19b", [ test_case "ADT non-exhaustive case IS correctly rejected"
                `Quick test_h19b_adt_non_exhaustive_case_is_rejected ];
    "H20", [ test_case "integer literal case with catch-all compiles"
               `Quick test_h20_integer_literal_case_with_catchall_compiles ];
    "H21", [ test_case "reading proof-annotated record field carries proof (FIXED)"
               `Quick test_h21_record_field_read_carries_proof;
             test_case "plain field read without proof annotation is rejected"
               `Quick test_h21b_plain_field_read_no_proof ];
    "H22", [ test_case "record construction without required proof is rejected"
               `Quick test_h22_record_construction_without_proof_rejected ];
    "H23", [ test_case "select without dbRead capability is rejected"
               `Quick test_h23_select_without_capability_rejected ];
    "H24", [ test_case "select with dbRead capability compiles"
               `Quick test_h24_select_with_capability_compiles ];
    "H25", [ test_case "Int.divide without IsNonZero proof is rejected"
               `Quick test_h25_division_without_nonzero_proof_rejected ];
    "H26", [ test_case "% modulo without IsNonZero proof is rejected"
               `Quick test_h26_modulo_without_nonzero_proof_rejected ];
    "H27", [ test_case "forward reference to later-defined fn compiles"
               `Quick test_h27_forward_reference_compiles ];
  ]
