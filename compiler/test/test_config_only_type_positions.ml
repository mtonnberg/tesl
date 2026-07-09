(* Config-only stdlib names must be REJECTED in type positions (and the
   config-block constructors in ordinary EXPRESSION positions).

   Multi-module audit 2026-07 / DESIGN: the checker's in-scope type-name set
   was purely lexical over exposing lists, so every config-only stdlib name
   (`Database`, `Postgres`, `Memory`, `Queue`, `Job`, `App`, `SmtpConfig`,
   `SseChannel`, the TimeZone zone constructors, the Currency constructors, …)
   typechecked in EVERY type position — fn param, return, record field,
   entity field, endpoint body, endpoint return — and then emitted as an
   UNBOUND Racket identifier: normalize-type-identifier keys it to the
   emitting file, minting a meaningless per-file nominal type (same-file) or
   trapping at define-server with a type-ref mismatch (cross-module).  The
   sibling expression hole: the config_stdlib_seed constructors (`Memory`,
   `Exponential`, …) resolved as values in ordinary expressions and crashed
   the generated module at load.

   The fix ({!Stdlib_config_names} + Checker.check_type_names_in_scope +
   Checker.check_config_ctor_expr_positions) rejects at check time.  This
   suite pins the accept/reject matrix:
     - REJECT the reject-set names in all six type positions;
     - REJECT config ctors in ordinary expressions;
     - ACCEPT erased SI quantity aliases (Speed/Duration/Length) everywhere;
     - ACCEPT `main() -> App` (MainKind return specs are exempt);
     - ACCEPT local shadows (`type Email = String`, `record Fixed { … }`) —
       locally-bound names always win;
     - ACCEPT the constructors inside real config blocks;
   and pins {!Emit_racket.config_only_import_names} set-identity with the
   pre-refactor literal (test_stdlib_runtime_binding.ml consumes the list). *)

let parse src = Parser.parse_module "<test>" src

let contains haystack needle =
  let n = String.length haystack and m = String.length needle in
  let found = ref false in
  for i = 0 to n - m do
    if String.sub haystack i m = needle then found := true
  done;
  !found

let errors_of src =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
      (Compile.check_module src m)

let assert_error ~ctx src substr =
  let errs = errors_of src in
  if not (List.exists (fun (d : Compile.diagnostic) -> contains d.message substr) errs)
  then
    Alcotest.failf "[%s] expected an error containing %S but got:\n%s" ctx substr
      (if errs = [] then "(no errors)"
       else String.concat "\n"
              (List.map (fun (d : Compile.diagnostic) -> d.message) errs))

let assert_clean ~ctx src =
  let errs = errors_of src in
  if errs <> [] then
    Alcotest.failf "[%s] expected no errors but got:\n%s" ctx
      (String.concat "\n"
         (List.map (fun (d : Compile.diagnostic) -> d.message) errs))

(* ── The reject matrix ────────────────────────────────────────────────────── *)

let import_for = function
  | "Database" | "Postgres" | "Memory" ->
    "import Tesl.Database exposing [Database, DatabaseBackend, Postgres, \
     Memory, PostgresConfig, PostgresConnection, TcpConnection, SocketConnection]"
  | "Queue" | "Job" ->
    "import Tesl.Queue exposing [Queue, QueueRetryStrategy, Exponential, \
     Fixed, Linear, Job]"
  | "App" -> "import Tesl.App exposing [App]"
  | "SmtpConfig" -> "import Tesl.Email exposing [Email, SmtpConfig]"
  | "SseChannel" -> "import Tesl.SSE exposing [SseChannel]"
  | "Utc" | "EuropeStockholm" ->
    "import Tesl.Time exposing [TimeZone, Utc, EuropeStockholm]"
  | "Usd" -> "import Tesl.Money exposing [Money, Currency, Usd]"
  | n -> Alcotest.failf "no import mapping for %s" n

(* The category-specific message fragment each rejected name must produce. *)
let expected_fragment = function
  | "Database" | "Queue" | "Job" | "App" | "SmtpConfig" | "SseChannel" ->
    "is a config-only stdlib name"
  | "Postgres" | "Memory" ->
    "is a config-block constructor (of `DatabaseBackend`)"
  | "Utc" | "EuropeStockholm" ->
    "is a `TimeZone` constructor, not a type"
  | "Usd" ->
    "is a `Currency` constructor, not a type"
  | n -> Alcotest.failf "no fragment mapping for %s" n

let module_header name =
  Printf.sprintf
    "#lang tesl\nmodule Probe exposing []\nimport Tesl.Prelude exposing [Int, String]\n%s\n"
    (import_for name)

(* (position label, source body using NAME in that type position) *)
let positions name = [
  ("param",    Printf.sprintf "fn fa(x: %s) -> Int = 1\n" name);
  ("return",   Printf.sprintf "fn fb(x: %s) -> %s = x\n" name name);
  ("record",   Printf.sprintf "record R {\n  a: %s\n}\n" name);
  ("entity",   Printf.sprintf
     "entity E table \"e\" primaryKey id {\n  id: String\n  a: %s\n}\n" name);
  ("endpoint-body", Printf.sprintf
     "api A {\n  post \"/x\"\n    body p: %s\n    -> String\n}\n" name);
  ("endpoint-return", Printf.sprintf
     "api A {\n  post \"/x\"\n    body p: String\n    -> %s\n}\n" name);
]

let reject_names =
  [ "Database"; "Postgres"; "Memory"; "Queue"; "Job"; "App"; "SmtpConfig";
    "SseChannel"; "Utc"; "EuropeStockholm"; "Usd" ]

let test_reject_matrix () =
  List.iter (fun name ->
    List.iter (fun (pos, body) ->
      let ctx = Printf.sprintf "%s/%s" name pos in
      assert_error ~ctx (module_header name ^ body) (expected_fragment name)
    ) (positions name)
  ) reject_names

(* ── Accept: erased SI quantity aliases in every position ─────────────────── *)

let units_header =
  "#lang tesl\nmodule Probe exposing []\n\
   import Tesl.Prelude exposing [Int, String]\n\
   import Tesl.Units exposing [Speed, Duration, Length]\n"

let test_accept_si_aliases () =
  List.iter (fun name ->
    (* Same six positions, but bodies must be fully well-typed. *)
    let accept_positions = [
      ("param",    Printf.sprintf "fn fa(x: %s) -> Int = 1\n" name);
      ("return",   Printf.sprintf "fn fb(x: %s) -> %s = x\n" name name);
      ("record",   Printf.sprintf "record R {\n  a: %s\n}\n" name);
      ("entity",   Printf.sprintf
         "entity E table \"e\" primaryKey id {\n  id: String\n  a: %s\n}\n" name);
      ("endpoint-body", Printf.sprintf
         "api A {\n  post \"/x\"\n    body p: %s\n    -> String\n}\n" name);
      ("endpoint-return", Printf.sprintf
         "api A {\n  post \"/x\"\n    body p: String\n    -> %s\n}\n" name);
    ] in
    List.iter (fun (pos, body) ->
      assert_clean ~ctx:(Printf.sprintf "%s/%s" name pos) (units_header ^ body)
    ) accept_positions
  ) [ "Speed"; "Duration"; "Length" ]

(* ── Accept: main() -> App stays exempt (MainKind return specs skipped) ───── *)

let main_app_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int, String, Unit, List]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database D = Database {
  entities: []
  backend: Memory
}

api A {
}

server Srv for A {
}

main() -> App =
  App {
    database: D
    api: Srv
    port: 8099
  }
|}

let test_accept_main_app () = assert_clean ~ctx:"main-App" main_app_src

(* ── Accept: local shadows win ────────────────────────────────────────────── *)

(* `type Email = String` (lesson04 pattern): Email is a config-only name of
   Tesl.Email, but the local newtype owns it. *)
let shadow_email_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]

type Email = String

fn emailAddress(email: Email) -> Bool = True
|}

(* `record Fixed { … }`: Fixed is a config-only QueueRetryBackoff ctor of
   Tesl.Queue (imported here WITHOUT exposing Fixed — an explicit
   `exposing [Fixed]` collision is already rejected by the pre-existing
   shadowing validation). *)
let shadow_fixed_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Queue exposing [Queue]

record Fixed {
  amount: Int
}

fn f(x: Fixed) -> Int = x.amount
|}

let test_accept_local_shadows () =
  assert_clean ~ctx:"shadow-type-Email" shadow_email_src;
  assert_clean ~ctx:"shadow-record-Fixed" shadow_fixed_src

(* ── Expression positions: config ctors outside config blocks ─────────────── *)

let expr_memory_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Database exposing [Database, Memory]

fn f() -> Int =
  let b = Memory
  1
|}

let expr_exponential_test_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Queue exposing [Queue, Exponential]

test "config ctor in a test body" {
  let b = Exponential
  expect 1 == 1
}
|}

(* Item 18 (review 2026-07-09): the expr-position rejection also walks
   api-test/load-test seed statements and bodies (and agent config exprs) —
   `let b = Memory` in an api-test body typechecked via the module-wide seed
   env yet emitted an unbound Racket identifier. *)
let expr_memory_api_test_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Database exposing [Database, Memory]
import Tesl.ApiTest exposing [statusOk]

entity E table "cfg_es" primaryKey id {
  id: String
}

database D = Database {
  entities: [E]
  backend: Memory
}

handler ping() -> String =
  "ok"

api A {
  get "/ping"
    -> String
}

server S for A {
  ping = ping
}

api-test "config ctor in api-test body" for S {
  let b = Memory
  let r = get "/ping"
  expect statusOk r.status
}
|}

(* The same constructor INSIDE its config block stays legal. *)
let config_block_memory_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.Database exposing [Database, Memory]

database D = Database {
  entities: []
  backend: Memory
}
|}

(* A local ADT ctor with a seeded name is the user's own — the config-ctor
   REJECTION must not fire.  (Inference itself still resolves `Fixed` to the
   seeded QueueRetryBackoff ctor here — a PRE-EXISTING precedence quirk of
   `config_ctors @ imported @ local` in check_module_with_metadata that
   fails closed with an ordinary unify error, so this fixture only asserts
   the new rejection stays silent.) *)
let expr_local_ctor_shadow_src = {|#lang tesl
module Probe exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Queue exposing [Queue]

type Rate =
  | Fixed
  | Variable

fn f() -> Rate = Fixed
|}

let assert_no_error_containing ~ctx src substr =
  let errs = errors_of src in
  match List.find_opt (fun (d : Compile.diagnostic) -> contains d.message substr) errs with
  | None -> ()
  | Some d ->
    Alcotest.failf "[%s] expected NO error containing %S but got:\n%s"
      ctx substr d.message

let test_expr_positions () =
  assert_error ~ctx:"expr-let-Memory" expr_memory_src
    "cannot be used in an ordinary expression";
  assert_error ~ctx:"expr-test-Exponential" expr_exponential_test_src
    "cannot be used in an ordinary expression";
  assert_error ~ctx:"expr-apitest-Memory" expr_memory_api_test_src
    "cannot be used in an ordinary expression";
  assert_clean ~ctx:"config-block-Memory" config_block_memory_src;
  assert_no_error_containing ~ctx:"expr-local-ctor-shadow"
    expr_local_ctor_shadow_src "cannot be used in an ordinary expression"

(* ── require_suppressed set-identity with the pre-refactor literal ────────── *)

module SS = Set.Make (String)

(* The exact literal that lived in emit_racket.ml before the refactor to
   {!Stdlib_config_names} (2026-07-09).  test_stdlib_runtime_binding.ml keys
   the runtime provide-existence seam off this set, so the refactored value
   must stay set-identical. *)
let pre_refactor_literal =
  [ "Database"; "DatabaseBackend"; "Postgres"; "Memory"; "PostgresConfig";
    "PostgresConnection"; "TcpConnection"; "SocketConnection";
    "Queue"; "QueueRetryStrategy"; "QueueRetryConfig"; "QueueRetryBackoff";
    "Exponential"; "Fixed"; "Linear";
    "Email"; "SmtpConfig"; "SseChannel"; "App"; "Job"; "Cache";
    "asTool"; "serverTools"; "humanActions";
    "cache"; "Cache.get"; "Cache.set"; "Cache.delete"; "Cache.invalidate";
    "Email.send"; "startEmailWorker";
    "Utc"; "FixedOffset" ]
  @ Tz_zones.ctor_names
  @ Currencies.ctor_names
  @ List.map fst Units_catalog.aliases

let test_require_suppressed_identity () =
  let expected = SS.of_list pre_refactor_literal in
  let actual = SS.of_list Emit_racket.config_only_import_names in
  let missing = SS.diff expected actual and extra = SS.diff actual expected in
  if not (SS.is_empty missing && SS.is_empty extra) then
    Alcotest.failf
      "config_only_import_names drifted from the pre-refactor literal.\n\
       missing: %s\nextra: %s"
      (String.concat ", " (SS.elements missing))
      (String.concat ", " (SS.elements extra))

let test_sublist_disjointness () =
  (* Erased SI aliases must be require-suppressed but NOT rejected in type
     positions; swapping the lists breaks every units program or re-opens the
     unbound-emit hole. *)
  let rejected = SS.of_list Stdlib_config_names.rejected_in_type_position in
  let suppressed = SS.of_list Stdlib_config_names.require_suppressed in
  List.iter (fun alias ->
    if SS.mem alias rejected then
      Alcotest.failf "erased SI alias %s must NOT be in rejected_in_type_position" alias;
    if not (SS.mem alias suppressed) then
      Alcotest.failf "erased SI alias %s must be in require_suppressed" alias
  ) Stdlib_config_names.erased_type_aliases;
  if not (SS.subset rejected suppressed) then
    Alcotest.fail "rejected_in_type_position must be a subset of require_suppressed"

(* ── Runner ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Config-Only-Type-Positions" [
    ("reject-matrix", [
      Alcotest.test_case
        "config-only names rejected in all six type positions" `Quick
        test_reject_matrix;
    ]);
    ("accept-matrix", [
      Alcotest.test_case "erased SI aliases accepted everywhere" `Quick
        test_accept_si_aliases;
      Alcotest.test_case "main() -> App stays exempt" `Quick
        test_accept_main_app;
      Alcotest.test_case "local shadows win" `Quick
        test_accept_local_shadows;
    ]);
    ("expression-positions", [
      Alcotest.test_case
        "config ctors rejected in ordinary expressions, legal in config blocks"
        `Quick test_expr_positions;
    ]);
    ("list-identity", [
      Alcotest.test_case "require_suppressed = pre-refactor literal (as a set)"
        `Quick test_require_suppressed_identity;
      Alcotest.test_case "erased aliases suppressed but not rejected" `Quick
        test_sublist_disjointness;
    ]);
  ]
