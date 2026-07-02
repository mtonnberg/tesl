(** Regression tests for the soundness / correctness holes closed after the
    formal reviews.
    Each NEGATIVE case is a minimal program that was wrongly ACCEPTED before the
    fix and must now be REJECTED; each POSITIVE case is the closest legitimate
    program that must keep compiling, guarding against an over-tightened fix.

    Holes closed:
      PROOF-1  a plain `fn` could forge a fixed set of stdlib proofs
               (IsNonZero/IsNonNegative/IsNonEmpty/HasKey/FloatNonZero) via the
               name-keyed `stdlib_auto_preds` allow-list.
      PROOF-2  FromDb provenance forgeable by shadowing a SQL builtin name
               (`fn select`) — body_has_db_site matched by spelling.
      CAP-1    an effect (dbWrite/time/envRead) laundered through a built-in
               args-carrying constructor (`Something (...)`) escaped the
               capability walk.
      EMIT-1   a user identifier matching a compiler-generated temp grammar
               (`tesl_case_*`, `_tesl_p*`, ...) captured / was captured by a temp.
      HM-2     `<` on a record LITERAL bypassed the orderable-type check and
               emitted runtime-crashing Racket.
      AGENT-1  a proof-annotated agent-tool parameter let untrusted model JSON
               fabricate the proof. *)

open Alcotest

(* ── Helpers (same shape as test_p0_soundness_fixes.ml) ──────────────────── *)

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
  let tmp = Filename.temp_file "tesl-eval-test" ".tesl" in
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
  if has_error then Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

(* ── PROOF-1: stdlib-proof forgery in a plain fn ─────────────────────────── *)

let test_proof1_forge_stdlib_pred_rejected () =
  should_fail "cannot declare a proof return type\\|cannot introduce new proofs"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Int exposing [IsNonNegative]\n\
     fn forge(n: Int) -> n: Int ::: IsNonNegative n = n\n"

let test_proof1_param_passthrough_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Int exposing [IsNonNegative]\n\
     fn passthru(n: Int ::: IsNonNegative n) -> n: Int ::: IsNonNegative n = n\n"

(* ── PROOF-2: FromDb forgery by shadowing `select` ───────────────────────── *)

let test_proof2_fromdb_shadow_select_rejected () =
  should_fail "cannot declare a proof return type\\|cannot introduce new proofs"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     fact FromDb (k: Int) (v: Int)\n\
     fn select(a: Int) -> Int = a * 2\n\
     fn forge(a: Int) -> r: Int ::: FromDb 99 r =\n\
     \  select a\n"

(* ── CAP-1: effect laundered through a built-in constructor ──────────────── *)

let test_cap1_effect_through_ctor_rejected () =
  should_fail "uses privileged operations\\|requires \\[time\\]\\|does not declare"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     import Tesl.Time exposing [nowMillis, PosixMillis]\n\
     fn sneaky() -> Maybe PosixMillis requires [] =\n\
     \  Something (nowMillis())\n"

let test_cap1_pure_ctor_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n\
     fn pureCtor(x: Int) -> Maybe Int requires [] =\n\
     \  Something x\n"

(* ── EMIT-1: reserved compiler-generated name grammar ────────────────────── *)

let test_emit1_reserved_name_rejected () =
  should_fail "reserved compiler-generated name"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(seed: Int) -> Int =\n\
     \  let tesl_case_0 = seed\n\
     \  tesl_case_0\n"

let test_emit1_reserved_param_rejected () =
  should_fail "reserved compiler-generated name"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(_tesl_p0_0: Int) -> Int = _tesl_p0_0\n"

let test_emit1_normal_name_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(seed: Int) -> Int =\n\
     \  let myLocal = seed\n\
     \  myLocal\n"

(* ── EMIT-1 (S5a): temps minted while emitting TEST / api-test / load-test
   bodies (`tesl_ignored_N` for a `_` discard, `tesl_proof_bind_N` for a proof
   binding) were NOT in the reserved grammar (and `tesl_proof_bind_` is a
   near-miss of the reserved `tesl_proof_binding_`), and the reservation walk
   descended DFunc only — so a user binder inside a `test { }` block could
   capture them (silently-wrong Racket that still type-checks).  Both prefixes
   are now reserved and the walk descends the test forms. *)
let test_emit1_reserved_ignored_in_test_rejected () =
  should_fail "reserved compiler-generated name"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fn f(x: Int) -> Int = x\n\
     test \"t\" {\n\
     \  let tesl_ignored_0 = f 1\n\
     \  expect tesl_ignored_0 == 1\n\
     }\n"

let test_emit1_reserved_proof_bind_in_test_rejected () =
  should_fail "reserved compiler-generated name"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fn f(x: Int) -> Int = x\n\
     test \"t\" {\n\
     \  let tesl_proof_bind_0 = f 1\n\
     \  expect tesl_proof_bind_0 == 1\n\
     }\n"

let test_emit1_reserved_ignored_in_func_rejected () =
  should_fail "reserved compiler-generated name"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f(seed: Int) -> Int =\n\
     \  let tesl_ignored_0 = seed\n\
     \  tesl_ignored_0\n"

let test_emit1_normal_name_in_test_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fn f(x: Int) -> Int = x\n\
     test \"t\" {\n\
     \  let myLocal = f 1\n\
     \  expect myLocal == 1\n\
     }\n"

(* ── HM-2: ordering on a record literal ──────────────────────────────────── *)

let test_hm2_record_literal_cmp_rejected () =
  should_fail "ordering operator.*not defined for type"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     record Point { x: Int, y: Int }\n\
     fn bad() -> Bool =\n\
     \  Point { x: 1, y: 2 } < Point { x: 3, y: 4 }\n"

let test_hm2_numeric_cmp_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fn ok() -> Bool = 1 < 2\n"

(* ── TSS-2 (third formal review): equality on a FUNCTION ──────────────────── *)
(* `==`/`!=` were `forall a. a -> a -> Bool` with no decidability constraint, so
   `f == g` on functions type-checked and compiled to a meaningless Racket
   `equal?` (procedure identity).  Functions have no decidable equality and must
   now be rejected at the type level.  (The generic-type-variable residual —
   `a == b` for `a: a` — needs an Eq qualified-type layer and is intentionally
   still permitted; tracked in roadmap/later.) *)
let test_tss2_function_equality_rejected () =
  should_fail "equality operator.*not defined for type"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, Bool(..)]\n\
     fn bad(f: (Int) -> Int, g: (Int) -> Int) -> Bool = f == g\n"

let test_tss2_primitive_equality_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..)]\n\
     fn ok(x: Int, s: String) -> Bool = (x == 1) != (s == \"a\")\n"

(* ── AGENT-1: proof-annotated agent-tool parameter ───────────────────────── *)

let test_agent1_proof_tool_param_rejected () =
  should_fail "must not carry a proof annotation\\|proof"
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, String]\n\
     import Tesl.Agent exposing [Agent, mockProvider, asTool]\n\
     fact IsPositive (n: Int)\n\
     check requirePositive(n: Int) -> n: Int ::: IsPositive n =\n\
     \  if n > 0 then\n\
     \    ok n ::: IsPositive n\n\
     \  else\n\
     \    fail 400 \"x\"\n\
     fn withdraw(amount: Int ::: IsPositive amount) -> String = \"ok\"\n\
     agent BankAgent = Agent {\n\
     \  provider: mockProvider [\"ok\"]\n\
     \  systemPrompt: \"x\"\n\
     \  maxTokens: 64\n\
     \  tools: [asTool withdraw]\n\
     }\n"

let test_agent1_plain_tool_param_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [Int, String]\n\
     import Tesl.Agent exposing [Agent, mockProvider, asTool]\n\
     fn lookup(orderId: String) -> String =\n\
     \  \"shipped\"\n\
     agent ShopAgent = Agent {\n\
     \  provider: mockProvider [\"ok\"]\n\
     \  systemPrompt: \"x\"\n\
     \  maxTokens: 64\n\
     \  tools: [asTool lookup]\n\
     }\n"

(* ── AGENT-2: expression-position `Agent { }` (BYOK) tool validation ─────── *)

let test_agent2_byok_proof_tool_param_rejected () =
  should_fail "must not carry a proof annotation\\|proof"
    "#lang tesl\nmodule T exposing [build]\n\
     import Tesl.Prelude exposing [Int, String]\n\
     import Tesl.Agent exposing [Agent, LlmProvider, mockProvider, asTool]\n\
     fact IsPositive (n: Int)\n\
     fn withdraw(amount: Int ::: IsPositive amount) -> String =\n\
     \  \"withdrew\"\n\
     fn build(p: LlmProvider) -> Agent =\n\
     \  let a = Agent { provider: p, systemPrompt: \"x\", maxTokens: 64, tools: [asTool withdraw] }\n\
     \  a\n"

let test_agent2_byok_plain_tool_param_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing [build]\n\
     import Tesl.Prelude exposing [Int, String]\n\
     import Tesl.Agent exposing [Agent, LlmProvider, mockProvider, asTool]\n\
     fn lookup(orderId: String) -> String =\n\
     \  \"shipped\"\n\
     fn build(p: LlmProvider) -> Agent =\n\
     \  let a = Agent { provider: p, systemPrompt: \"x\", maxTokens: 64, tools: [asTool lookup] }\n\
     \  a\n"

(* ── SQL-1: join entity / join-field validation ──────────────────────────── *)

let sql_schema =
  "#lang tesl\nmodule T exposing [q]\n\
   import Tesl.Prelude exposing [String, List]\n\
   import Tesl.DB exposing [dbRead]\n\
   entity Order table \"orders\" primaryKey id {\n\
   \  id: String\n\
   \  customerId: String\n\
   }\n\
   entity Customer table \"customers\" primaryKey id {\n\
   \  id: String\n\
   \  name: String\n\
   }\n"

let test_sql1_valid_join_accepted () =
  should_pass
    (sql_schema ^
     "fn q() -> List Order requires [dbRead] =\n\
      \  select o from Order\n\
      \  innerJoin Customer on o.customerId Customer.id\n")

let test_sql1_wrong_join_field_rejected () =
  should_fail "unknown field `idd`\\|unknown field"
    (sql_schema ^
     "fn q() -> List Order requires [dbRead] =\n\
      \  select o from Order\n\
      \  innerJoin Customer on o.customerId Customer.idd\n")

let test_sql1_wrong_join_entity_rejected () =
  should_fail "unknown entity `Custmer`\\|unknown entity"
    (sql_schema ^
     "fn q() -> List Order requires [dbRead] =\n\
      \  select o from Order\n\
      \  innerJoin Custmer on o.customerId Custmer.id\n")

let () =
  run "Eval-Review-Fixes" [
    "proof-1-stdlib-forgery", [
      test_case "forged IsNonNegative in a plain fn rejected" `Quick test_proof1_forge_stdlib_pred_rejected;
      test_case "legit param passthrough accepted" `Quick test_proof1_param_passthrough_accepted;
    ];
    "proof-2-fromdb-shadow", [
      test_case "FromDb forged via `fn select` rejected" `Quick test_proof2_fromdb_shadow_select_rejected;
    ];
    "cap-1-constructor-launder", [
      test_case "time effect through Something rejected" `Quick test_cap1_effect_through_ctor_rejected;
      test_case "pure value in Something accepted" `Quick test_cap1_pure_ctor_accepted;
    ];
    "emit-1-reserved-names", [
      test_case "reserved let-binding name rejected" `Quick test_emit1_reserved_name_rejected;
      test_case "reserved parameter name rejected" `Quick test_emit1_reserved_param_rejected;
      test_case "ordinary name accepted" `Quick test_emit1_normal_name_accepted;
      test_case "reserved `tesl_ignored_` in test block rejected" `Quick test_emit1_reserved_ignored_in_test_rejected;
      test_case "reserved `tesl_proof_bind_` in test block rejected" `Quick test_emit1_reserved_proof_bind_in_test_rejected;
      test_case "reserved `tesl_ignored_` in fn body rejected" `Quick test_emit1_reserved_ignored_in_func_rejected;
      test_case "ordinary name in test block accepted" `Quick test_emit1_normal_name_in_test_accepted;
    ];
    "hm-2-orderable-record", [
      test_case "record-literal `<` rejected" `Quick test_hm2_record_literal_cmp_rejected;
      test_case "numeric `<` accepted" `Quick test_hm2_numeric_cmp_accepted;
    ];
    "tss-2-equality-decidability", [
      test_case "function `==` rejected" `Quick test_tss2_function_equality_rejected;
      test_case "primitive `==`/`!=` accepted" `Quick test_tss2_primitive_equality_accepted;
    ];
    "agent-1-tool-proof-param", [
      test_case "proof-annotated tool param rejected" `Quick test_agent1_proof_tool_param_rejected;
      test_case "plain tool param accepted" `Quick test_agent1_plain_tool_param_accepted;
    ];
    "agent-2-byok-expression-agent", [
      test_case "BYOK proof-annotated tool param rejected" `Quick test_agent2_byok_proof_tool_param_rejected;
      test_case "BYOK plain tool param accepted" `Quick test_agent2_byok_plain_tool_param_accepted;
    ];
    "sql-1-join-validation", [
      test_case "valid innerJoin accepted" `Quick test_sql1_valid_join_accepted;
      test_case "wrong join field rejected" `Quick test_sql1_wrong_join_field_rejected;
      test_case "wrong join entity rejected" `Quick test_sql1_wrong_join_entity_rejected;
    ];
  ]
