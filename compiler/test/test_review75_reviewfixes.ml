(** Regression tests for the 2026-07 external-review soundness fixes.

    Guards the fail-open boundary-validator class the review found (see
    EXECUTIVE-REVIEW-2026-07.md / TECHNICAL-REVIEW-2026-07.md and
    roadmap/next/review_2026_07_master.md).  Each forged program below compiled
    CLEAN before the fix (exit 0) and now must be REJECTED; each control is the
    legitimate variant that must still compile — so the delta isolates the
    security property, not a syntax error.

    Covered:
    - PF-3/4/6, AUTH-1, PFC-1: `check`/`auth` `ok` proof validator now descends
      into transaction / with-database / with-capabilities wrappers.
    - PF-5: `establish` body fact-constructor check descends into wrappers.
    - SHADOW-1: no-shadowing (V001) now descends into bare constructor args.
    - AUTH-VIA: endpoint `auth ... via <fn>` is validated at the frontend.
*)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r75" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
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

(* ── PF: wrapper-nested proof forgery in check/auth ─────────────────────── *)

let test_R75_PF01_check_transaction_forgery_rejected () =
  should_fail "does not match declared return spec" {|
#lang tesl
module R75Pf01 exposing [A, B, chk]
import Tesl.Prelude exposing [Int]
fact A (n: Int)
fact B (n: Int)
check chk(n: Int) -> n: Int ::: B n =
  transaction {
    ok n ::: A n
  }
|}

let test_R75_PF02_check_transaction_legit_accepted () =
  should_pass {|
#lang tesl
module R75Pf02 exposing [B, chk]
import Tesl.Prelude exposing [Int]
fact B (n: Int)
check chk(n: Int) -> n: Int ::: B n =
  transaction {
    ok n ::: B n
  }
|}

let test_R75_AUTH01_auth_transaction_forgery_rejected () =
  should_fail "does not match declared return spec" {|
#lang tesl
module R75Auth01 exposing [adminAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
fact IsAdmin (u: String)
fact NotAdmin (u: String)
auth adminAuth(request: HttpRequest) -> u: String ::: IsAdmin u =
  transaction {
    ok "anyone" ::: NotAdmin u
  }
|}

let test_R75_PF05_establish_transaction_forgery_rejected () =
  should_fail "fact constructor" {|
#lang tesl
module R75Pf05 exposing [A, B, mk]
import Tesl.Prelude exposing [Int, Fact]
fact A (n: Int)
fact B (n: Int)
establish mk(n: Int) -> Fact (B n) =
  transaction {
    A n
  }
|}

(* ── SHADOW: no-shadowing descends into constructor args ────────────────── *)

let test_R75_SHADOW01_ctor_arg_shadow_rejected () =
  should_fail "shadows an existing name" {|
#lang tesl
module R75Shadow01 exposing [InBounds, checkInBounds, needsProof, forge]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact InBounds (n: Int)
check checkInBounds(n: Int) -> n: Int ::: InBounds n =
  if n >= 0 && n <= 1000 then
    ok n ::: InBounds n
  else
    fail 400 "out of bounds"
fn needsProof(n: Int ::: InBounds n) -> Int =
  n
fn forge(n: Int ::: InBounds n, raw: Maybe Int) -> Maybe Int =
  Something (case raw of
               Something n -> needsProof n
               Nothing -> 0)
|}

(* ── AUTH-VIA: endpoint auth `via` validated at the frontend ─────────────── *)

let test_R75_AV01_auth_via_undeclared_rejected () =
  should_fail "is not a declared function" {|
#lang tesl
module R75Av01 exposing [MyApi]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
fact Authenticated (u: String)
api MyApi {
  get "/secret"
    auth u: String ::: Authenticated u via ghostAuth
    -> String
}
|}

let test_R75_AV02_auth_via_legit_accepted () =
  should_pass {|
#lang tesl
module R75Av02 exposing [MyApi, cookieAuth, secret]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
fact Authenticated (u: String)
auth cookieAuth(request: HttpRequest) -> u: String ::: Authenticated u =
  ok "user" ::: Authenticated u
handler secret(u: String ::: Authenticated u) -> String requires [] = u
api MyApi {
  get "/secret"
    auth u: String ::: Authenticated u via cookieAuth
    -> String
}
|}

(* ── FromDb provenance on the non-existential named-pack form (F1/F2) ────── *)

let fromdb_entity = {|
entity Todo table "todos" primaryKey id {
  id: String
  ownerId: String @db(text)
  createdAt: PosixMillis
}
|}

let test_R75_F1_named_pack_insert_id_forgery_rejected () =
  should_fail "forged FromDb" ({|
#lang tesl
module R75F1 exposing [createTodo]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Time exposing [nowMillis, PosixMillis, time]
capability aDbRead implies dbRead
capability aDbWrite implies dbWrite
|} ^ fromdb_entity ^ {|
handler createTodo(claimedId: String)
  -> Todo ? FromDb (Id == claimedId)
  requires [aDbRead, aDbWrite, time] =
  insert Todo { id: "totally-different-literal", ownerId: "x", createdAt: nowMillis() }
|})

let test_R75_F2_named_pack_owner_forgery_rejected () =
  should_fail "forged FromDb" ({|
#lang tesl
module R75F2 exposing [createTodo]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Time exposing [nowMillis, PosixMillis, time]
capability aDbRead implies dbRead
capability aDbWrite implies dbWrite
|} ^ fromdb_entity ^ {|
handler createTodo(victim: String)
  -> Todo ? FromDb (OwnerId == victim)
  requires [aDbRead, aDbWrite, time] =
  insert Todo { id: "x", ownerId: "attacker", createdAt: nowMillis() }
|})

let test_R75_F1_named_pack_insert_matching_accepted () =
  should_pass ({|
#lang tesl
module R75F1ok exposing [createTodo]
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Time exposing [nowMillis, PosixMillis, time]
capability aDbRead implies dbRead
capability aDbWrite implies dbWrite
|} ^ fromdb_entity ^ {|
handler createTodo(victim: String)
  -> Todo ? FromDb (OwnerId == victim)
  requires [aDbRead, aDbWrite, time] =
  insert Todo { id: "x", ownerId: victim, createdAt: nowMillis() }
|})

let test_R75_EE1_existential_wrapped_id_rejected () =
  should_fail "existential witness" {|
#lang tesl
module R75Ee1 exposing [createMsg]
import Tesl.Prelude exposing [String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Msg table "msgs" primaryKey id { id: String }
handler createMsg(seed: String)
  -> exists msgId: String => Msg ? FromDb (Id == msgId)
  requires [dbRead, dbWrite] =
  exists msgId =>
    insert Msg { id: seed ++ "-suffix" }
|}

(* ── CAP-COMPOSE: main's grant must cover reachable handlers/workers ─────── *)

let capcompose_app grant = {|
#lang tesl
module App exposing [MyApi, MyServer, getThing, main]
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]
capability adminOnly
capability baseCap
database MyDb = Database { entities: [] backend: Memory }
handler getThing() -> String requires [adminOnly] = "thing"
api MyApi { get "/thing" -> String }
server MyServer for MyApi { getThing = getThing }
main() -> App requires [|} ^ grant ^ {|] =
  App { database: MyDb api: MyServer port: 8086 }
|}

let test_R75_CAPC_ungranted_handler_cap_rejected () =
  (* main grants only [baseCap]; wired handler requires [adminOnly] → runtime 500
     if not caught at compile time. *)
  should_fail "does not grant it" (capcompose_app "baseCap")

let test_R75_CAPC_granted_handler_cap_accepted () =
  should_pass (capcompose_app "baseCap, adminOnly")

(* ── PFC-2b: ADT field proofs enforced at construction ──────────────────── *)

let adt_field_proof src = {|
#lang tesl
module AdtField exposing [IsPositive, PositiveTree, checkPositive, mk]
import Tesl.Prelude exposing [Bool(..), Int]
fact IsPositive (n: Int)
type PositiveTree
  = Leaf
  | Node (left: PositiveTree) (value: Int ::: IsPositive value) (right: PositiveTree)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"
|} ^ src

let test_R75_ADTFIELD_literal_construction_rejected () =
  (* `Node Leaf 5 Leaf` — the value field is `::: IsPositive value` but 5 is not
     proven positive; before the fix this compiled clean (decorative field proof). *)
  should_fail "IsPositive" (adt_field_proof {|
fn mk() -> PositiveTree =
  Node Leaf 5 Leaf
|})

let test_R75_ADTFIELD_proven_construction_accepted () =
  should_pass (adt_field_proof {|
fn mk(v: Int ::: IsPositive v) -> PositiveTree =
  Node Leaf v Leaf
|})

(* ── PFC-2 (a)+(b): field-proof propagation + container producer check ──── *)

let pfc2_prelude = {|
fact IsPositive (n: Int)
type PositiveTree
  = Leaf
  | Node (left: PositiveTree) (value: Int ::: IsPositive value) (right: PositiveTree)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"
fn needPos(n: Int ::: IsPositive n) -> Int = n
|}

(* (a): a field proof propagates to a pattern binder on destructuring. *)
let test_R75_FIELDPROP_destructure_carries_proof () =
  should_pass ({|
#lang tesl
module Pfc2A exposing [IsPositive, PositiveTree, checkPos, needPos, getVal]
import Tesl.Prelude exposing [Bool(..), Int]
|} ^ pfc2_prelude ^ {|
fn getVal(t: PositiveTree) -> Int =
  case t of
    Leaf -> 0
    Node l cur r -> needPos cur
|})

(* (b): a plain fn cannot mint the proof through a Maybe container. *)
let test_R75_PFC2_maybe_forgery_rejected () =
  should_fail "does not carry" ({|
#lang tesl
module Pfc2M exposing [IsPositive, PositiveTree, checkPos, needPos, launder]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Maybe exposing [Maybe(..)]
|} ^ pfc2_prelude ^ {|
fn launder() -> Maybe (Int ? IsPositive) =
  Something (0 - 999)
|})

(* (b): nor through an Either container. *)
let test_R75_PFC2_either_forgery_rejected () =
  should_fail "does not carry" ({|
#lang tesl
module Pfc2E exposing [IsPositive, PositiveTree, checkPos, needPos, launder]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Either exposing [Either(..)]
|} ^ pfc2_prelude ^ {|
fn launder() -> Either String (Int ? IsPositive) =
  Right (0 - 999)
|})

(* (b) control: a payload validated via a `check` is accepted. *)
let test_R75_PFC2_checked_payload_accepted () =
  should_pass ({|
#lang tesl
module Pfc2Ok exposing [IsPositive, PositiveTree, checkPos, needPos, produce]
import Tesl.Prelude exposing [Bool(..), Int]
import Tesl.Maybe exposing [Maybe(..)]
|} ^ pfc2_prelude ^ {|
fn produce(raw: Int) -> Maybe (v: Int ::: IsPositive v) =
  if raw > 0 then
    let good = check checkPos raw
    Something good
  else
    Nothing
|})

(* ── TS-EQ (#3): equality recurses through nominal fields ────────────────── *)

let test_R75_EQFIELD_function_field_record_rejected () =
  (* A record whose field is a function has no decidable equality; `==` used to
     compile to a meaningless `equal?` on closures. *)
  should_fail "not defined for type" {|
#lang tesl
module EqField exposing [Handler, same]
import Tesl.Prelude exposing [Bool(..), Int]
record Handler {
  id: Int
  callback: (Int -> Int)
}
fn same(a: Handler, b: Handler) -> Bool =
  a == b
|}

let test_R75_EQFIELD_plain_record_accepted () =
  should_pass {|
#lang tesl
module EqOk exposing [Point, same]
import Tesl.Prelude exposing [Bool(..), Int]
record Point {
  x: Int
  y: Int
}
fn same(a: Point, b: Point) -> Bool =
  a == b
|}

(* ── DRIFT-1: the Tesl.Cli module was removed (config is env-vars-only) ──────
   Both an explicit `import Tesl.Cli` and a bare `cli.args` must now be
   COMPILE-TIME errors (they were the checker↔runtime name-resolution drift:
   typecheck-clean but unbound at runtime). *)
let test_R75_DRIFT1_import_cli_rejected () =
  should_fail "unknown stdlib module" {|
#lang tesl
module Drift1Import exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Cli exposing [lookupPortArgument]
fn f() -> Int = 1
|}

let test_R75_DRIFT1_bare_cli_args_rejected () =
  should_fail "unknown name: cli" {|
#lang tesl
module Drift1Bare exposing [f]
import Tesl.Prelude exposing [List, String]
fn f() -> List String = cli.args
|}

(* ── CAP-UUID: UUID.v4/v7 are nullary uuid-EFFECTS. Calling one without declaring
   `requires [uuid]` must be rejected (they used to compile clean with requires []
   while runtime-gated), and the corrected form must compile (they were also
   uncallable due to a unit->T type bug). *)
let test_R75_CAPUUID_missing_requires_rejected () =
  should_fail "requiring \\[uuid\\]\\|capability" {|
#lang tesl
module CapUuidBad exposing [gen]
import Tesl.Prelude exposing [String]
import Tesl.UUID exposing [uuid, UUID.v7]
fn gen() -> String requires [] = UUID.v7()
|}

let test_R75_CAPUUID_declared_accepted () =
  should_pass {|
#lang tesl
module CapUuidOk exposing [gen4, gen7]
import Tesl.Prelude exposing [String]
import Tesl.UUID exposing [uuid, UUID.v4, UUID.v7]
fn gen4() -> String requires [uuid] = UUID.v4()
fn gen7() -> String requires [uuid] = UUID.v7()
|}

(* ── A2-4: a declarative `agent X = Agent {…}` block must bound its tools'
   authority — a tool requiring a capability the agent doesn't declare is rejected
   (the same Agent{} built in a fn body was charged; the block was not). *)
let test_R75_A24_agent_tool_cap_uncovered_rejected () =
  should_fail "does not declare\\|must bound the authority" {|
#lang tesl
module A24Bad exposing []
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [requireEnv]
import Tesl.Agent exposing [aiProvider, anthropic, Agent, asTool]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]
capability botAi implies aiProvider
agent Bot requires [botAi] = Agent {
  provider: anthropic (requireEnv "KEY") "claude-opus-4-8"
  systemPrompt: "sys"
  tools: [asTool genTool]
  maxTokens: 64
}
fn genTool(x: String) -> String requires [random] = generatePrefixedId x
|}

let test_R75_A24_agent_tool_cap_covered_accepted () =
  should_pass {|
#lang tesl
module A24Ok exposing []
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [requireEnv]
import Tesl.Agent exposing [aiProvider, anthropic, Agent, asTool]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]
capability botAi implies aiProvider
agent Bot requires [botAi, random] = Agent {
  provider: anthropic (requireEnv "KEY") "claude-opus-4-8"
  systemPrompt: "sys"
  tools: [asTool genTool]
  maxTokens: 64
}
fn genTool(x: String) -> String requires [random] = generatePrefixedId x
|}

(* ── NT-07: Int32 is a NOMINAL boundary type — it does not unify with Int, so an
   Int cannot be used where Int32 is expected without an explicit Int32.fromInt. *)
let test_R75_NT07_int_not_int32_rejected () =
  should_fail "cannot unify Int with Int32\\|unify.*Int32" {|
#lang tesl
module Nt07Bad exposing [f]
import Tesl.Prelude exposing [Int]
import Tesl.Int32 exposing [Int32, Int32.toInt]
fn f(n: Int) -> Int = Int32.toInt n
|}

let test_R75_NT07_int32_conversions_accepted () =
  should_pass {|
#lang tesl
module Nt07Ok exposing [narrow, widen]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int32 exposing [Int32, Int32.fromInt, Int32.toInt]
fn narrow(n: Int) -> Maybe Int32 = Int32.fromInt n
fn widen(x: Int32) -> Int = Int32.toInt x
|}

(* ── NT-07 width-match at SQL write/query sites ──────────────────────────────
   An entity column must be written (insert / update…set) and compared (where)
   with its EXACT declared type — coercion is not accepted at any SQL boundary
   (spec §11.6).  An `Int` into an `Int32` column, or a raw `String` into a
   newtype column, is a COMPILE error, not a silent narrowing caught only by
   Postgres at write time.  These sites previously bypassed the field check. *)
let sql_width_prelude = {|
#lang tesl
module SqlW exposing [f]
import Tesl.Prelude exposing [String, Int, List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Int32 exposing [Int32]
type UserId = String
entity Widget table "widgets" primaryKey id {
  id: String
  count: Int32
  owner: UserId
}
|}

let test_R75_NT07SQL_insert_int_into_int32_rejected () =
  should_fail "unify Int with Int32\\|unify.*Int32" (sql_width_prelude ^ {|
fn f(n: Int) -> String requires [dbWrite] =
  insert Widget { id: "w", count: n, owner: UserId "u" }
  "ok"
|})

let test_R75_NT07SQL_insert_string_into_newtype_rejected () =
  should_fail "unify String with UserId\\|unify.*UserId" (sql_width_prelude ^ {|
fn f(c: Int32, s: String) -> String requires [dbWrite] =
  insert Widget { id: "w", count: c, owner: s }
  "ok"
|})

let test_R75_NT07SQL_set_int_into_int32_rejected () =
  should_fail "SET clause: type mismatch\\|field type is `Int32`" (sql_width_prelude ^ {|
fn f(n: Int) -> String requires [dbRead, dbWrite] =
  update w in Widget where w.id == "x" set w.count = n
  "ok"
|})

let test_R75_NT07SQL_set_string_into_newtype_rejected () =
  should_fail "SET clause: type mismatch\\|field type is `UserId`" (sql_width_prelude ^ {|
fn f(s: String) -> String requires [dbRead, dbWrite] =
  update w in Widget where w.id == "x" set w.owner = s
  "ok"
|})

let test_R75_NT07SQL_where_string_into_newtype_rejected () =
  should_fail "WHERE clause: type mismatch\\|field type is `UserId`" (sql_width_prelude ^ {|
fn f(s: String) -> List Widget requires [dbRead] =
  select w from Widget where w.owner == s
|})

let test_R75_NT07SQL_exact_types_accepted () =
  should_pass (sql_width_prelude ^ {|
fn f(c: Int32, u: UserId) -> List Widget requires [dbRead, dbWrite] =
  insert Widget { id: "w", count: c, owner: u }
  update w in Widget where w.id == "w" set w.count = c set w.owner = u
  select w from Widget where w.owner == u
|})

(* ── S6a: an SSE endpoint cannot hold a body/response/return. It's structurally
   unrepresentable (sse_clause has no such fields); a written clause is REJECTED,
   never silently dropped. A valid SSE (subscribe only) still compiles. *)
let test_R75_S6A_sse_with_body_rejected () =
  should_fail "an SSE endpoint cannot declare" {|
#lang tesl
module S6aBad exposing [EvApi]
import Tesl.Prelude exposing [String]
api EvApi {
  sse "/events/:userId" capture userId: String body payload: String -> String
}
|}

let test_R75_S6A_valid_sse_accepted () =
  should_pass {|
#lang tesl
module S6aOk exposing [EvApi]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
api EvApi {
  sse "/events/:userId" capture userId: String using stringCodec subscribe UserEvents(userId)
}
|}

let () =
  run "Review75-ReviewFixes" [
    "eq-nominal-fields", [
      test_case "R75_EQFIELD function-field record rejected" `Quick test_R75_EQFIELD_function_field_record_rejected;
      test_case "R75_EQFIELD plain record accepted" `Quick test_R75_EQFIELD_plain_record_accepted;
    ];
    "pfc2-container-minting", [
      test_case "R75_FIELDPROP destructure carries field proof (a)" `Quick test_R75_FIELDPROP_destructure_carries_proof;
      test_case "R75_PFC2 Maybe container forgery rejected (b)" `Quick test_R75_PFC2_maybe_forgery_rejected;
      test_case "R75_PFC2 Either container forgery rejected (b)" `Quick test_R75_PFC2_either_forgery_rejected;
      test_case "R75_PFC2 checked payload accepted (b control)" `Quick test_R75_PFC2_checked_payload_accepted;
    ];
    "adt-field-proof-construction", [
      test_case "R75_ADTFIELD literal construction rejected" `Quick test_R75_ADTFIELD_literal_construction_rejected;
      test_case "R75_ADTFIELD proven construction accepted" `Quick test_R75_ADTFIELD_proven_construction_accepted;
    ];
    "cap-compose", [
      test_case "R75_CAPC ungranted wired-handler cap rejected" `Quick test_R75_CAPC_ungranted_handler_cap_rejected;
      test_case "R75_CAPC granted wired-handler cap accepted" `Quick test_R75_CAPC_granted_handler_cap_accepted;
    ];
    "fromdb-provenance", [
      test_case "R75_F1 named-pack insert id forgery rejected" `Quick test_R75_F1_named_pack_insert_id_forgery_rejected;
      test_case "R75_F2 named-pack owner forgery rejected" `Quick test_R75_F2_named_pack_owner_forgery_rejected;
      test_case "R75_F1ok named-pack matching provenance accepted" `Quick test_R75_F1_named_pack_insert_matching_accepted;
      test_case "R75_EE1 existential wrapped id rejected" `Quick test_R75_EE1_existential_wrapped_id_rejected;
    ];
    "wrapper-proof-forgery", [
      test_case "R75_PF01 transaction check forgery rejected" `Quick test_R75_PF01_check_transaction_forgery_rejected;
      test_case "R75_PF02 transaction check legit accepted" `Quick test_R75_PF02_check_transaction_legit_accepted;
      test_case "R75_AUTH01 transaction auth forgery rejected" `Quick test_R75_AUTH01_auth_transaction_forgery_rejected;
      test_case "R75_PF05 transaction establish forgery rejected" `Quick test_R75_PF05_establish_transaction_forgery_rejected;
    ];
    "shadow-descent", [
      test_case "R75_SHADOW01 ctor-arg shadow rejected" `Quick test_R75_SHADOW01_ctor_arg_shadow_rejected;
    ];
    "auth-via-validation", [
      test_case "R75_AV01 auth via undeclared rejected" `Quick test_R75_AV01_auth_via_undeclared_rejected;
      test_case "R75_AV02 auth via legit accepted" `Quick test_R75_AV02_auth_via_legit_accepted;
    ];
    "drift1-cli-removed", [
      test_case "R75_DRIFT1 import Tesl.Cli rejected" `Quick test_R75_DRIFT1_import_cli_rejected;
      test_case "R75_DRIFT1 bare cli.args rejected" `Quick test_R75_DRIFT1_bare_cli_args_rejected;
    ];
    "cap-uuid", [
      test_case "R75_CAPUUID missing requires [uuid] rejected" `Quick test_R75_CAPUUID_missing_requires_rejected;
      test_case "R75_CAPUUID declared uuid accepted" `Quick test_R75_CAPUUID_declared_accepted;
    ];
    "a2-4-agent-tool-caps", [
      test_case "R75_A24 agent tool cap uncovered rejected" `Quick test_R75_A24_agent_tool_cap_uncovered_rejected;
      test_case "R75_A24 agent tool cap covered accepted" `Quick test_R75_A24_agent_tool_cap_covered_accepted;
    ];
    "nt07-int32", [
      test_case "R75_NT07 Int not usable as Int32" `Quick test_R75_NT07_int_not_int32_rejected;
      test_case "R75_NT07 Int32 conversions accepted" `Quick test_R75_NT07_int32_conversions_accepted;
    ];
    "nt07-sql-width", [
      test_case "R75_NT07SQL insert Int->Int32 rejected" `Quick test_R75_NT07SQL_insert_int_into_int32_rejected;
      test_case "R75_NT07SQL insert String->newtype rejected" `Quick test_R75_NT07SQL_insert_string_into_newtype_rejected;
      test_case "R75_NT07SQL set Int->Int32 rejected" `Quick test_R75_NT07SQL_set_int_into_int32_rejected;
      test_case "R75_NT07SQL set String->newtype rejected" `Quick test_R75_NT07SQL_set_string_into_newtype_rejected;
      test_case "R75_NT07SQL where String->newtype rejected" `Quick test_R75_NT07SQL_where_string_into_newtype_rejected;
      test_case "R75_NT07SQL exact types accepted" `Quick test_R75_NT07SQL_exact_types_accepted;
    ];
    "s6a-endpoint-sum-type", [
      test_case "R75_S6A SSE with body rejected" `Quick test_R75_S6A_sse_with_body_rejected;
      test_case "R75_S6A valid SSE accepted" `Quick test_R75_S6A_valid_sse_accepted;
    ];
  ]
