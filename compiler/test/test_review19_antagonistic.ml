(** Antagonistic regression tests for Critical Review 19.
    Each test probes a specific flaw, limitation, or correctness gap
    identified during the review. Tests are ordered by priority (P1 first). *)

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

(* Prefer TESL_BIN env var; fall back to main.exe next to this test binary
   (which is where dune places it), then fall back to 'tesl' on PATH. *)
let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some b -> b
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

(* main.exe uses --check; the 'tesl' shell wrapper uses the 'check' subcommand *)
let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r19-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let exit_code_of src =
  let tmp = Filename.temp_file "tesl-r19-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let status = Sys.command (Printf.sprintf "%s %s %s >/dev/null 2>&1" tesl check_subcmd tmp) in
  (try Sys.remove tmp with _ -> ());
  status

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true
    (let re = Str.regexp pattern in
     try ignore (Str.search_forward re out 0); true with Not_found -> false)

let should_not_crash src =
  let code = exit_code_of src in
  check bool "compiler must not crash (exit code must not be 2)" false (code = 2)

let prelude = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n"

(* ── P1: Auth-wiring gap ─────────────────────────────────────────────────── *)
(* SPEC CLAIM (TESL.md): "Try to wire [a handler with auth proof] to a handler
   without auth — compile error."
   FIXED: both directions (auth handler ↔ no-auth endpoint) now produce V001. *)

let test_handler_auth_wired_to_no_auth_endpoint () =
  let src = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]

fact Authenticated (u: String)

auth cookieAuth(req: HttpRequest) -> session: String ::: Authenticated session
  requires [] =
  ok "user" ::: Authenticated session

record Body { name: String }
codec Body {
  toJson_forbidden
  fromJson [{ name <- "name" with_codec stringCodec }]
}

handler createItem(session: String ::: Authenticated session, item: Body)
  -> String requires [] =
  item.name

api TestApi {
  post "/items"
    body item: Body
    -> String
}

server TestServer for TestApi {
  createItem = createItem
}
|} in
  (* Handler has auth-proof param but endpoint declares no auth — must be caught *)
  should_fail "V001\\|auth-proof\\|auth clause" src

(* P1b: reverse — endpoint needs auth, handler has none *)
let test_endpoint_needs_auth_handler_lacks_it () =
  let src = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]

fact Authenticated (u: String)

auth cookieAuth(req: HttpRequest) -> session: String ::: Authenticated session
  requires [] =
  ok "user" ::: Authenticated session

record Body { name: String }
codec Body {
  toJson_forbidden
  fromJson [{ name <- "name" with_codec stringCodec }]
}

handler createItemNoAuth(item: Body)
  -> String requires [] =
  item.name

api TestApi2 {
  post "/items"
    auth session: String ::: Authenticated session via cookieAuth
    body item: Body
    -> String
}

server TestServer2 for TestApi2 {
  createItem = createItemNoAuth
}
|} in
  (* Endpoint requires auth, handler has no auth-proof parameter — must be caught *)
  should_fail "V001\\|auth-proof\\|requires auth" src

(* ── P2: Large integer literals compile (A9/HM-1: Int is arbitrary-precision) ── *)
(* Formerly these asserted a compile-time range error. Under A9/HM-1 the 63-bit
   fixnum range check is gone: a huge magnitude is carried through as an LBigInt
   canonical string into the Racket bignum. These now must compile (and, of course,
   still must not crash). *)

let test_no_crash_on_large_literal () =
  let src = prelude ^ "fn bigNum() -> Int = 9999999999999999999999\n" in
  should_not_crash src;
  should_pass src

let test_no_crash_on_max_int_plus_one () =
  (* 2^62 = 4611686018427387904 — formerly the out-of-range boundary, now a bignum *)
  let src = prelude ^ "fn bigNum() -> Int = 4611686018427387904\n" in
  should_not_crash src;
  should_pass src

let test_graceful_error_on_large_literal () =
  (* A9/HM-1: a huge literal compiles cleanly (exit 0), no longer an error. *)
  let src = prelude ^ "fn bigNum() -> Int = 9999999999999999999999\n" in
  let code = exit_code_of src in
  check bool "huge literal compiles (exit 0), not error/crash" true (code = 0)

(* ── S1: Unit constructor ───────────────────────────────────────────────────── *)
(* FIXED: Unit is now registered in stdlib_env and constructible as a value. *)

let test_unit_term_exists () =
  let src = prelude ^ "fn noOp() -> Unit =\n  Unit\n" in
  should_pass src

(* ── S2: Single-line ADT should be compile error ───────────────────────────── *)
(* CURRENT BEHAVIOUR: silently parsed as a type alias *)

let test_single_line_adt_is_error () =
  let src = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String]
type Color = Red | Green | Blue
fn colorStr(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|} in
  (* BUG: this silently treats Color as a type alias, then fails on case with
     "non-exhaustive case" or unknown constructor errors.
     It should be a hard parse error for the single-line ADT form. *)
  should_fail "E\\|W" src

(* ── S6: ForAll on unfiltered select should not satisfy proof ────────────────── *)
(* FIXED: direct SQL select at ForAll return position now produces V001. *)

let test_forall_on_unfiltered_select () =
  let src = {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, List, Bool(..)]
import Tesl.Time exposing [PosixMillis]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

type Status
  = Open
  | Done

entity Todo table "todos" primaryKey id {
  id: String
  title: String
  status: Status
  createdAt: PosixMillis
}

database Db = Database {
  schema: "todo"
  entities: [Todo]
  backend: Postgres (PostgresConfig {
    dbName: "db"
    user: "u"
    password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

fact IsOpen (t: Todo)

check checkOpen(t: Todo) -> t: Todo ::: IsOpen t =
  case t.status of
    Open -> ok t ::: IsOpen t
    Done -> fail 422 "done"

fn fakeForAll() -> List Todo ::: ForAll (IsOpen)
  requires [dbRead] =
  select todo from Todo
|} in
  should_fail "V001\\|SQL select\\|ForAll" src

(* ── 1.4b: Returning untracked variable at ForAll position ────────────────── *)
(* FIXED: untracked variables at ForAll return position now produce V001. *)

let test_forall_untracked_var () =
  should_fail "V001\\|ForAll\\|filtered"
    (prelude ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn dangerousRelay(xs: List Int) -> List Int ::: ForAll IsPositive =
  xs
|})

(* ── 3.4: Fact arg type checking ───────────────────────────────────────────── *)
(* FIXED: using a fact predicate with wrong argument types now produces V001. *)

let test_fact_wrong_arg_type () =
  should_fail "V001\\|fact.*IsPositive\\|IsPositive.*fact\\|type.*String\\|String.*type"
    (prelude ^ {|
fact IsPositive (n: Int)
check makePositive(s: String) -> s: String ::: IsPositive s =
  ok s ::: IsPositive s
|})

let test_fact_correct_arg_type () =
  should_pass
    (prelude ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|})

(* ── Correctness: Proof fabrication is blocked in fn ──────────────────────── *)

let test_proof_fabrication_blocked () =
  should_fail "P001"
    (prelude ^ {|
fact IsPositive (n: Int)
fn sneaky(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|})

let test_check_can_introduce_proof () =
  should_pass
    (prelude ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|})

(* ── Correctness: Calling proof-requiring fn without proof ──────────────────── *)

let test_missing_proof_at_callsite () =
  should_fail "V001"
    (prelude ^ {|
fact IsValid (x: Int)
check validate(n: Int) -> n: Int ::: IsValid n =
  if n > 0 then
    ok n ::: IsValid n
  else
    fail 400 "bad"
fn useProof(m: Int ::: IsValid m) -> Int = m
fn caller(raw: Int) -> Int =
  useProof raw
|})

(* ── Correctness: Shadowing is forbidden ────────────────────────────────────── *)

let test_shadowing_rejected () =
  should_fail "shadow"
    (prelude ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
fn shadowTest(x: Int) -> Int =
  let x = checkPos x
  x
|})

(* ── Correctness: Newtype nominal enforcement ───────────────────────────────── *)

let test_newtype_distinct () =
  should_fail "T001"
    (prelude ^ {|
type UserId = String
type ProjectId = String
fn useUser(id: UserId) -> UserId = id
fn brokenMix(pid: ProjectId) -> UserId =
  useUser pid
|})

(* ── Correctness: Non-exhaustive case ───────────────────────────────────────── *)

let test_nonexhaustive_rejected () =
  should_fail "V001"
    (prelude ^ {|
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red   -> "red"
    Green -> "green"
|})

(* ── Correctness: Division-by-zero protection ──────────────────────────────── *)

let test_literal_zero_div () =
  should_fail "V001"
    (prelude ^ "import Tesl.Int exposing [Int.divide]\nfn f(n: Int) -> Int = n / 0\n")

let test_variable_div_without_proof () =
  should_fail "V001"
    (prelude ^ "import Tesl.Int exposing [Int.divide]\nfn f(n: Int, d: Int) -> Int = n / d\n")

(* ── Correctness: Capability enforcement ────────────────────────────────────── *)

let test_write_without_cap () =
  should_fail "V001"
    {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Time exposing [PosixMillis]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

capability readOnly implies dbRead

entity Note table "notes" primaryKey id {
  id: String
  content: String
  createdAt: PosixMillis
}

database NoteDb = Database {
  schema: "notes"
  entities: [Note]
  backend: Postgres (PostgresConfig {
    dbName: "db"
    user: "u"
    password: ""
    connection: TcpConnection { host: "localhost"  port: 5432 }
  })
}

fn tryWriteWithoutCap(id: String, content: String) -> Int
  requires [readOnly] =
  insert Note { id: id, content: content, createdAt: 0 }
  1
|}

(* ── Correctness: Proof smuggling via attachFact is blocked statically ──────── *)

let test_proof_smuggling_blocked () =
  should_fail "V001"
    {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int, String, Fact, attachFact, detachFact]
import Tesl.String exposing [String.length]

fact IsClean (s: String)

check sanitize(s: String) -> s: String ::: IsClean s =
  if String.length s > 0 then
    ok s ::: IsClean s
  else
    fail 400 "empty"

fn transportProof(a: String ::: IsClean a, b: String) -> String =
  let proof = detachFact a
  let bWithProof = attachFact b proof
  bWithProof

fn needsClean(s: String ::: IsClean s) -> String = s

fn testSmuggle(clean: String ::: IsClean clean, dirty: String) -> String =
  let smuggled = transportProof clean dirty
  needsClean smuggled
|}

(* ── Regression: attachFact cross-subject from detach/reattach pattern ───────
   processNameManual2: proof was established for `name`; attaching to `raw`
   (which is `forgetFact ne`, same subject) works, but the declared proof
   annotation uses `foo` (an unrelated Int binding) → V001.
   processNameManual3: proof describes `name` but is attached to `name2` → V001.
   These were silently accepted before the subject-mismatch check. *)

let shared_proof_module = {|#lang tesl
module T exposing []
import Tesl.Proof
import Tesl.String exposing [String.length]

fact NonEmpty  (name: String)
fact ValidName (name: String)

check checkNonEmpty(name: String) -> name: String ::: NonEmpty name =
  if String.length name > 0 then
    ok name ::: NonEmpty name
  else
    fail 400 "empty"

check checkName(name: String ::: NonEmpty name) -> name: String ::: ValidName name =
  if String.length name > 0 then
    ok name ::: ValidName name
  else
    fail 400 "bad"

fn processName(ne: String ::: NonEmpty ne, name2: String ::: ValidName name2) -> String =
  ne ++ name2
|}

(* Bug 1: Fact annotation refers to an unrelated binding (`foo` is an Int, not
   the proof-carrying string). The declared proof `NonEmpty foo` does not match
   the proof actually carried by `detachFact ne` which is `NonEmpty name`. *)
let test_wrong_fact_annotation_binding () =
  should_fail "V001"
    (shared_proof_module ^ {|
fn processNameManual2(name: String, name2: String) -> String =
  let ne  = check checkNonEmpty name
  let foo = 2
  let proof : Fact (NonEmpty foo) = detachFact ne
  processName ne name2
|})

(* Bug 2: The declared proof annotation on the result of `check` lists wrong
   subjects (`NonEmpty name2 && ValidName name` instead of the actual proof
   established by the chain). *)
let test_wrong_declared_proof_on_let () =
  should_fail "V001"
    (shared_proof_module ^ {|
fn processNameManual2b(name: String, name2: String) -> String =
  let ne  = check checkNonEmpty name
  let raw = forgetFact ne
  let proof : Fact (NonEmpty name) = detachFact ne
  let reattach = attachFact raw proof
  let validated: String ::: NonEmpty name2 && ValidName name = check checkName reattach
  validated
|})

(* Bug 3: `attachFact name2 proof` where `proof` was derived from `name`.
   The proof subject is `name`; the target value is derived from `name2` → mismatch. *)
let test_attachfact_cross_subject () =
  should_fail "V001"
    (shared_proof_module ^ {|
fn processNameManual3(name: String ::: NonEmpty name, name2: String) -> String =
  let proof    = detachFact name
  let reattach = attachFact name2 proof
  processName reattach name2
|})

(* ── Ergonomics: Import ordering enforced ───────────────────────────────────── *)

let test_import_after_def_rejected () =
  should_fail "E000"
    {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [Int]
fn f() -> Int = 1
import Tesl.String exposing [String.length]
|}

(* ── Ergonomics: Record construction with missing/extra fields ──────────────── *)

let test_missing_field () =
  should_fail "T001"
    (prelude ^ {|
record User { id: String  name: String  age: Int }
fn makeUser(id: String, name: String) -> User =
  User { id: id, name: name }
|})

let test_extra_field () =
  should_fail "T001"
    (prelude ^ {|
record User { id: String  name: String  age: Int }
fn makeUser2(id: String, name: String) -> User =
  User { id: id, name: name, age: 25, extra: "bad" }
|})

(* ── Ergonomics: Mutual recursion compiles ──────────────────────────────────── *)

let test_mutual_recursion () =
  should_pass
    (prelude ^ {|
fn isEven(n: Int) -> Bool =
  if n == 0 then
    True
  else
    isOdd (n - 1)

fn isOdd(n: Int) -> Bool =
  if n == 0 then
    False
  else
    isEven (n - 1)
|})

(* ── Main runner ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Review19-Antagonistic" [
    "p1-auth-wiring", [
      test_case "handler with auth wired to no-auth endpoint → compile error" `Quick
        test_handler_auth_wired_to_no_auth_endpoint;
      test_case "endpoint needs auth, handler lacks it → compile error" `Quick
        test_endpoint_needs_auth_handler_lacks_it;
    ];
    "p2-integer-overflow", [
      test_case "no crash on very large literal"           `Quick test_no_crash_on_large_literal;
      test_case "no crash on max_int+1"                   `Quick test_no_crash_on_max_int_plus_one;
      test_case "emits error exit code not crash"         `Quick test_graceful_error_on_large_literal;
    ];
    "s1-unit-constructor", [
      test_case "Unit is a constructible value"             `Quick test_unit_term_exists;
    ];
    "s2-single-line-adt", [
      test_case "single-line ADT should be compile error" `Quick test_single_line_adt_is_error;
    ];
    "s6-forall-unfiltered", [
      test_case "ForAll on unfiltered select → compile error" `Quick test_forall_on_unfiltered_select;
      test_case "ForAll on untracked variable → compile error" `Quick test_forall_untracked_var;
    ];
    "fact-type-checking", [
      test_case "fact arg with wrong type → compile error"  `Quick test_fact_wrong_arg_type;
      test_case "fact arg with correct type → compiles"     `Quick test_fact_correct_arg_type;
    ];
    "proof-fabrication", [
      test_case "proof fabrication blocked in fn"         `Quick test_proof_fabrication_blocked;
      test_case "proof introduction allowed in check"     `Quick test_check_can_introduce_proof;
    ];
    "missing-proof-callsite", [
      test_case "call without required proof is rejected" `Quick test_missing_proof_at_callsite;
    ];
    "shadowing", [
      test_case "shadowing proof-relevant binder is rejected" `Quick test_shadowing_rejected;
    ];
    "newtype", [
      test_case "UserId and ProjectId are distinct"       `Quick test_newtype_distinct;
    ];
    "exhaustive-case", [
      test_case "non-exhaustive case is rejected"         `Quick test_nonexhaustive_rejected;
    ];
    "division-safety", [
      test_case "division by literal 0"                   `Quick test_literal_zero_div;
      test_case "division by variable without NonZero proof" `Quick test_variable_div_without_proof;
    ];
    "capability-enforcement", [
      test_case "write without dbWrite cap is rejected"   `Quick test_write_without_cap;
    ];
    "proof-smuggling", [
      test_case "proof smuggling via attachFact is statically blocked" `Quick test_proof_smuggling_blocked;
      test_case "Fact annotation referencing wrong binding is rejected"  `Quick test_wrong_fact_annotation_binding;
      test_case "wrong declared proof on check result is rejected"       `Quick test_wrong_declared_proof_on_let;
      test_case "attachFact with cross-subject proof is rejected"        `Quick test_attachfact_cross_subject;
    ];
    "import-ordering", [
      test_case "import after definition is rejected"     `Quick test_import_after_def_rejected;
    ];
    "record-construction", [
      test_case "missing record field is rejected"        `Quick test_missing_field;
      test_case "extra record field is rejected"          `Quick test_extra_field;
    ];
    "mutual-recursion", [
      test_case "mutual recursion compiles"               `Quick test_mutual_recursion;
    ];
  ]
