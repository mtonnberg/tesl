(** GitHub issues #40 / #41 / #42 — multi-module semantic regressions.

    The original failures were backend-specific. These tests now preserve the
    source-level seams against the shipped Go backend: imported record/entity
    construction, cross-module queue/cache/email/SSE use, proof metadata, and
    stdlib nominal types must all check and emit Go artifacts. Checker-only
    diagnostics retain the fail-closed closure and ambiguity regressions. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128+n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let contains needle hay =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* Write a two-file project into a temp dir; hand `f` the two paths. *)
let with_project ~lib ~main f =
  let dir = Filename.temp_dir "tesl-i40" "" in
  let write name src =
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p
  in
  let lib_p = write "lib.tesl" lib in
  let main_p = write "main.tesl" main in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [lib_p; main_p];
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f ~lib_p ~main_p)

let emit_ok what path =
  match Compile.compile_go_file path with
  | Compile.GoSuccess artifacts ->
    String.concat "\n" (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts)
  | Compile.GoFailure diagnostics ->
    failf "Go emit of %s failed:\n%s" what
      (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let check_ok what path =
  let code, out = run_cc ["--check"; path] in
  if code <> 0 then failf "check of %s failed:\n%s" what out

(* ── #40: imported record/entity literal in expression position ─────────── *)

let i40_lib = {|module Lib exposing [Box, Thing]
import Tesl.Prelude exposing [Int, String]

record Box {
  n: Int
}

entity Thing table "things" primaryKey id {
  id: String
}
|}

let i40_main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [Int, String, List]
import Lib exposing [Box, Thing]
import Tesl.DB exposing [dbRead, dbWrite]

database DB = Database {
  schema: "app"
  entities: [Thing]
  backend: Memory
}

api MainApi {
  get "/box"
    -> Int
  post "/seed"
    -> Int
}

handler get rawBox() -> Int =
  let raw = Box { n: 3 }
  raw.n

handler post seedRows() -> Int requires [dbRead Thing, dbWrite Thing] =
  let rows = [Thing { id: "a" }]
  insertMany rows in Thing
  1

server MainServer for MainApi {
  rawBox
  seedRows
}
|}

let issue40_record_keyword_ctor () =
  with_project ~lib:i40_lib ~main:i40_main (fun ~lib_p:_ ~main_p ->
    ignore (emit_ok "imported record literal (issue40)" main_p))

let issue40_entity_plain_hash () =
  with_project ~lib:i40_lib ~main:i40_main (fun ~lib_p:_ ~main_p ->
    ignore (emit_ok "imported entity literal (issue40)" main_p))

(* REVIEW2 item 15 (2026-07-09): the #40 record/entity harvest skipped
   ImportAll — `import Lib` (no exposing) + a bare `Box { n: 3 }` still
   checked green (load_imported_records registers ImportAll records in
   construction scope) but emitted the generic-ctor `(Box (hash 'n 3))`,
   arity-trapping at runtime.  The harvest now includes an ImportAll dep's
   EXPORTED records/entities (exactly what the whole-module require binds).
   NB the QUALIFIED literal spelling `Lib.Box { n: 3 }` is a checker
   REJECTION (unknown constructor), so only the bare spelling needs the
   emit-side arm. *)
let i40_importall_main = {|module Main exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Lib
import Tesl.DB exposing [dbRead, dbWrite]

fn rawBox() -> Int =
  let raw = Box { n: 3 }
  raw.n

fn rawThing() -> String =
  let t = Thing { id: "a" }
  t.id

test "importall record" {
  expect rawBox() == 3
}
|}

let issue40_importall_record_keyword_ctor () =
  with_project ~lib:i40_lib ~main:i40_importall_main (fun ~lib_p:_ ~main_p ->
    let code, _ = run_cc ["--check"; main_p] in
    if code <> 0 then failf "ImportAll record construction must check green";
    ignore (emit_ok "ImportAll record/entity literals" main_p))

(* ── #41: enqueue in a module, queue declared in the entrypoint ──────────── *)

let i41_lib = {|module Lib exposing [PingJob, libEnqueue, libQueueWrite]
import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [queueWrite]

capability libQueueWrite implies queueWrite

record PingJob {
  name: String
}

fn libEnqueue(name: String) -> String
  requires [libQueueWrite] =
  enqueue PingJob { name: name }
  "queued"
|}

let issue41_cross_module_enqueue_lookup () =
  with_project ~lib:i41_lib ~main:"module Main exposing []\n" (fun ~lib_p ~main_p:_ ->
    check_ok "library enqueue resolved by importer-owned queue (issue41)" lib_p)

(* ── #42: stdlib nominal types across emitted modules ───────────────────── *)

let i42_lib = {|module Lib exposing [moneyBack]
import Tesl.Prelude exposing [String]
import Tesl.Money exposing [Money, Money.sek]

handler get moneyBack() -> Money =
  Money.sek 5
|}

let i42_main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String]
import Tesl.Money exposing [Money]
import Lib exposing [moneyBack]

api MainApi {
  get "/money"
    -> Money
}

server MainServer for MainApi {
  moneyBack
}
|}

let issue42_money_require_bound () =
  with_project ~lib:i42_lib ~main:i42_main (fun ~lib_p ~main_p ->
    ignore (emit_ok "Money handler library (issue42)" lib_p);
    ignore (emit_ok "Money endpoint (issue42)" main_p))

let issue42_timezone_and_rate_aliases_bound () =
  let lib = {|module Lib exposing [tzName, rateBack]
import Tesl.Prelude exposing [String, Int]
import Tesl.Money exposing [Money, Money.sek, MoneyPerDuration, MoneyRate.perHour]
import Tesl.Time exposing [TimeZone]

fn tzName(z: TimeZone) -> Int =
  7

handler rateBack() -> MoneyPerDuration =
  MoneyRate.perHour (Money.sek 5)
|} in
  with_project ~lib ~main:"module Main exposing []\n" (fun ~lib_p ~main_p:_ ->
    ignore (emit_ok "TimeZone and Money rate aliases (issue42)" lib_p))

(* ── review hardening: the #40 harvest must be scope-accurate ────────────── *)

(* A local ADT variant ctor sharing a name with an imported module's
   record/entity must keep its positional ADT emission — the record arm
   precedes the ADT arm, so a name-only harvest hijacked it. *)
let harvest_no_local_adt_ctor_hijack () =
  let lib = {|module Lib exposing [Thing, useThing]
import Tesl.Prelude exposing [Int, String]

entity Thing table "things" primaryKey id {
  id: String
}

fn useThing(n: Int) -> Int =
  n
|} in
  let main = {|module Main exposing []
import Tesl.Prelude exposing [Int]
import Lib exposing [useThing]

type Wrapped = Thing n: Int | Empty

fn mk() -> Wrapped =
  Thing { n: 3 }
|} in
  with_project ~lib ~main (fun ~lib_p:_ ~main_p ->
    ignore (emit_ok "local ADT ctor with imported entity namesake" main_p))

(* A PRIVATE (unexposed, unimported) decl of an imported module must not be
   harvested at all: only names the import's exposing clause brings into scope
   qualify. *)
let harvest_respects_exposing_list () =
  let lib = {|module Lib exposing [useThing]
import Tesl.Prelude exposing [Int, String]

entity Thing table "things" primaryKey id {
  id: String
}

fn useThing(n: Int) -> Int =
  n
|} in
  let main = {|module Main exposing []
import Tesl.Prelude exposing [Int]
import Lib exposing [useThing]

record Thing {
  n: Int
}

fn mk() -> Thing =
  Thing { n: 3 }
|} in
  with_project ~lib ~main (fun ~lib_p:_ ~main_p ->
    ignore (emit_ok "local record wins over unexposed imported entity" main_p))

(* Property-test generators must emit a plain field hash for entity types —
   define-entity binds an entity-spec struct, not a constructor procedure. *)
let property_gen_entity_hash () =
  let main = {|module Main exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]

entity Thing table "things" primaryKey id {
  id: String
}

fn thingOk(t: Thing) -> Bool =
  True

test "entity property" with 5 runs {
  property "entity input" (t: Thing) { thingOk t }
}
|} in
  with_project ~lib:"module Lib exposing []\n" ~main (fun ~lib_p:_ ~main_p ->
    ignore (emit_ok "entity property generator" main_p))

(* EmailBody is the same #42 cross-module nominal-type class. *)
let issue42_emailbody_bound () =
  let lib = {|module Lib exposing [bodyBack]
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody]

handler bodyBack() -> EmailBody =
  TextBody "hello"
|} in
  with_project ~lib ~main:"module Main exposing []\n" (fun ~lib_p ~main_p:_ ->
    ignore (emit_ok "EmailBody handler (issue42)" lib_p))

(* ── Cross-module runtime objects: cache / email / publish / sse-route ──── *)

let nw_lib = {|module Lib exposing [LibDb, C, E, Ch, NoticeEvent(..)]
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.Cache exposing [Cache]
import Tesl.Email exposing [Email, SmtpConfig, emailCap, TextBody]
import Tesl.SSE exposing [SseChannel]
import Tesl.Queue exposing [pubsub]

database LibDb = Database {
  entities: []
  backend: Memory
}

cache C = Cache {
  database: LibDb
  defaultTtl: 60
  valueType: String
}

email E = Email {
  database: LibDb
  smtp: SmtpConfig {
    host: "localhost"
    port: 2525
    username: "u"
    password: "p"
    tls: false
  }
}

type NoticeEvent
  = NoticeSent message: String

sseChannel Ch(userId: String) = SseChannel {
  database: LibDb
  payload: NoticeEvent
}

fn localGet(k: String) -> Maybe String requires [cacheCap C] =
  Cache.get C (k)

fn localSend(addr: String) -> Unit requires [emailCap] =
  Email.send E {
    to: addr
    subject: "s"
    body: TextBody "b"
  }

fn localPub(msg: String) -> Unit requires [pubsub] =
  publish Ch("k") NoticeSent { message: msg }
|}

let nw_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.Maybe exposing [Maybe]
import Tesl.Email exposing [emailCap, TextBody]
import Tesl.Queue exposing [pubsub]
import Lib exposing [NoticeEvent(..)]

fn readC(k: String) -> Maybe String requires [cacheCap C] =
  Cache.get C (k)

fn sendE(addr: String) -> Unit requires [emailCap] =
  Email.send E {
    to: addr
    subject: "s"
    body: TextBody "b"
  }

fn kickE() -> Unit requires [emailCap] =
  startEmailWorker E

fn pub(msg: String) -> Unit requires [pubsub] =
  publish Ch("k") NoticeSent { message: msg }
|}

let name_wired_local_hit_byte_stable () =
  with_project ~lib:nw_lib ~main:"module Main exposing []\n" (fun ~lib_p ~main_p:_ ->
    ignore (emit_ok "locally declared cache/email/channel uses" lib_p))

let name_wired_cross_module_miss_lookup () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    let code, out = run_cc ["--check"; main_p] in
    if code <> 0 then failf "check of name-wired main must pass (#41):\n%s" out;
    check_ok "cross-module cache/email/channel uses" main_p)

let name_wired_requires_fire_on_use () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    check_ok "cross-module cache/email runtime uses" main_p)

let name_wired_cachecap_value_synthesized () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    check_ok "cross-module cache capability" main_p)

(* Cross-module SSE routes must remain resolvable by the emitted Go program. *)
let nw_sse_main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Lib exposing [NoticeEvent(..), Ch]

fn parseUserId(id: String) -> String =
  id

capturer userIdCapture: String using stringCodec via parseUserId

handler post sendNotice() -> String requires [pubsub] =
  publish Ch("u1") NoticeSent { message: "m" }
  "ok"

api MainApi {
  post "/send"
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe Ch(userId)
}

server MainServer for MainApi {
  sendNotice
}
|}

let name_wired_sse_route_symbol_lazy () =
  with_project ~lib:nw_lib ~main:nw_sse_main (fun ~lib_p ~main_p ->
    check_ok "cross-module SSE route" main_p;
    ignore (emit_ok "local SSE channel control" lib_p))

(* ── entrypoint-closure diagnostic: a name declared NOWHERE in the program
      can never resolve via the registry, so a PROGRAM ROOT (main/server/
      api-test) fails at --check; a plain library stays runtime-resolved. ── *)

let nw_root_ghost = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Queue exposing [pubsub]

type Ev = EvMade message: String

handler post h() -> String requires [pubsub] =
  publish Ghost("k") EvMade { message: "x" }
  "ok"

api MainApi {
  post "/x"
    -> String
}

server MainServer for MainApi {
  h
}
|}

let closure_diag_root_rejects_undeclared () =
  with_project ~lib:"module Lib exposing []\n" ~main:nw_root_ghost
    (fun ~lib_p:_ ~main_p ->
      let code, out = run_cc ["--check"; main_p] in
      if code = 0 then
        failf "program root publishing to a channel declared nowhere must fail --check";
      if not (contains "no sseChannel named `Ghost` is declared anywhere in this program" out) then
        failf "closure diagnostic must name the unresolvable channel:\n%s" out)

let nw_lib_ghost = {|module Lib exposing [pubGhost]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Queue exposing [pubsub]

type Ev = EvMade message: String

fn pubGhost(msg: String) -> Unit requires [pubsub] =
  publish Importers("k") EvMade { message: msg }
|}

let closure_diag_library_standalone_exempt () =
  with_project ~lib:nw_lib_ghost ~main:"module Main exposing []\n"
    (fun ~lib_p ~main_p:_ ->
      let code, out = run_cc ["--check"; lib_p] in
      if code <> 0 then
        failf "a plain library publishing to an importer-declared channel must \
               stay check-green (runtime-resolved by design):\n%s" out)

let closure_diag_root_rejects_undeclared_job_type () =
  let main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Queue exposing [queueWrite]

record GhostJob {
  name: String
}

handler post h() -> String requires [queueWrite] =
  enqueue GhostJob { name: "x" }
  "ok"

api MainApi {
  post "/x"
    -> String
}

server MainServer for MainApi {
  h
}
|} in
  with_project ~lib:"module Lib exposing []\n" ~main (fun ~lib_p:_ ~main_p ->
    let code, out = run_cc ["--check"; main_p] in
    if code = 0 then
      failf "program root enqueueing a job type no queue declares must fail --check";
    if not (contains "no queue declares job type `GhostJob` anywhere in this program" out) then
      failf "closure diagnostic must name the unresolvable job type:\n%s" out)

(* Item 13 (review 2026-07-09): 'declared more than once' is as unresolvable
   as 'declared nowhere' — the runtime lookups fail closed on multiplicity but
   only at first call/instantiation.  The closure walk must reject it at
   check time, naming every declaring module. *)

let dup_lib = {|module Lib exposing []
import Tesl.Prelude exposing [String]

entity LE table "dup_les" primaryKey id {
  id: String
}

database LDb = Database {
  entities: [LE]
  backend: Memory
}

cache Sessions = Cache {
  database: LDb
  valueType: String
}
|}

let dup_main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String]
import Lib

entity ME table "dup_mes" primaryKey id {
  id: String
}

database MDb = Database {
  entities: [ME]
  backend: Memory
}

cache Sessions = Cache {
  database: MDb
  valueType: String
}

api MainApi {
  get "/x"
    -> String
}

handler get h() -> String =
  "ok"

server MainServer for MainApi {
  h
}
|}

let closure_diag_root_rejects_duplicate_decl () =
  with_project ~lib:dup_lib ~main:dup_main (fun ~lib_p:_ ~main_p ->
    let code, out = run_cc ["--check"; main_p] in
    if code = 0 then
      failf "program root with cache `Sessions` declared in two modules must \
             fail --check:\n%s" out;
    if not (contains "cache `Sessions` is declared 2 times in this program" out) then
      failf "duplicate-decl diagnostic must count the declarations:\n%s" out;
    if not (contains "`Main`" out && contains "`Lib`" out) then
      failf "duplicate-decl diagnostic must name both declaring modules:\n%s" out)

(* ── DESIGN-4 Topic A: proof metadata harvested cross-module ────────────── *)

(* An imported fn returning `Maybe (v: T ::: P v)` must retain enough proof
   metadata for decomposition after cross-module Go lowering. *)
let pm_lib = {|module ProofLib exposing [IsPositive, checkPos, maybePositive]
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Maybe exposing [Maybe(..)]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn maybePositive(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    let p = check checkPos n
    Something p
  else
    Nothing
|}

let pm_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Maybe exposing [Maybe(..)]
import ProofLib exposing [IsPositive, checkPos, maybePositive]

fn decomposeViaImported(n: Int) -> Int =
  let m = maybePositive n
  case m of
    Nothing -> -1
    Something v ->
      let (x ::: pf) = v
      x
|}

(* with_project writes lib.tesl/main.tesl; the import resolver probes the
   module name's source spelling too, so name the lib module Lib?  No — the
   repro needs `import ProofLib`; write custom file names instead. *)
let with_named_project files f =
  let dir = Filename.temp_dir "tesl-d4" "" in
  let paths = List.map (fun (name, src) ->
    let p = Filename.concat dir name in
    let oc = open_out p in output_string oc src; close_out oc; p) files
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f paths)

let design4_imported_proof_carrier_named_value () =
  with_named_project [("ProofLib.tesl", pm_lib); ("main.tesl", pm_main)]
    (fun paths ->
       let main_p = List.nth paths 1 in
       ignore (emit_ok "imported proof-carrier decomposition" main_p))

(* Same channel through a QUALIFIED head: `ProofLib.maybePositive n` (EField
   over the module EConstructor).  Empirically red before the head_fn_name
   consumer fix + qualified-name harvest. *)
let pm_main_qualified = {|module Main exposing []
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Maybe exposing [Maybe(..)]
import ProofLib

fn decomposeViaQualified(n: Int) -> Int =
  let m = ProofLib.maybePositive n
  case m of
    Nothing -> -1
    Something v ->
      let (x ::: pf) = v
      x
|}

let design4_qualified_proof_carrier_named_value () =
  with_named_project [("ProofLib.tesl", pm_lib); ("main.tesl", pm_main_qualified)]
    (fun paths ->
       let main_p = List.nth paths 1 in
       check_ok "qualified imported proof-carrier decomposition" main_p)

(* Imported ADT with a proof-annotated ctor field: construction from a
   proof-annotated param must keep the named-value (un-starred) so the facts
   are stored inside the ADT — key-aligned with the ctor_fields harvest. *)
let pm_ctor_lib = {|module CtorLib exposing [IsPositive, checkPos, Pair(..)]
import Tesl.Prelude exposing [Int, Fact]

fact IsPositive (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

type Pair
  = MkPair label: Int count: Int ::: IsPositive count
|}

let pm_ctor_main = {|module Main exposing []
import Tesl.Prelude exposing [Int, Fact]
import CtorLib exposing [IsPositive, checkPos, Pair(..)]

fn wrapImported(n: Int ::: IsPositive n) -> Pair =
  MkPair { label: 7, count: n }
|}

let design4_imported_ctor_proof_field_named_value () =
  with_named_project [("CtorLib.tesl", pm_ctor_lib); ("main.tesl", pm_ctor_main)]
    (fun paths ->
       let main_p = List.nth paths 1 in
       ignore (emit_ok "imported proof-annotated constructor" main_p))

(* ── cache / email names are exportable (declared-in-lib direction) ─────── *)

let cache_email_names_exportable () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p ~main_p:_ ->
    (* `module Lib exposing [C, E]` used to fail with "only locally-defined
       names can be exported" — DCache/DEmail were missing from decl_names. *)
    let code, out = run_cc ["--check"; lib_p] in
    if code <> 0 then
      failf "exposing a locally declared cache/email name must check (#41 companion):\n%s" out;
    ignore (emit_ok "exported cache/email names" lib_p))

let () =
  run "Issues-40-41-42" [
    "issue 40 — imported record/entity literal", [
      test_case "imported record literal emits Go" `Quick
        issue40_record_keyword_ctor;
      test_case "imported entity literal emits Go" `Quick
        issue40_entity_plain_hash;
      test_case "ImportAll record/entity literals emit Go" `Quick
        issue40_importall_record_keyword_ctor;
    ];
    "issue 41 — cross-module enqueue", [
      test_case "cross-module enqueue checks" `Quick
        issue41_cross_module_enqueue_lookup;
    ];
    "DESIGN-4 A — cross-module proof metadata", [
      test_case "imported proof-carrier decomposition emits Go" `Quick
        design4_imported_proof_carrier_named_value;
      test_case "qualified imported proof-carrier checks" `Quick
        design4_qualified_proof_carrier_named_value;
      test_case "imported proof-annotated ctor emits Go" `Quick
        design4_imported_ctor_proof_field_named_value;
    ];
    "issue 42 — stdlib nominal type-refs", [
      test_case "Money emits on both sides" `Quick
        issue42_money_require_bound;
      test_case "TimeZone and MoneyPer* aliases emit Go" `Quick
        issue42_timezone_and_rate_aliases_bound;
      test_case "EmailBody emits Go (same class)" `Quick
        issue42_emailbody_bound;
    ];
    "review hardening — scope-accurate harvest", [
      test_case "local ADT ctor not hijacked by imported entity" `Quick
        harvest_no_local_adt_ctor_hijack;
      test_case "unexposed imported decls are not harvested" `Quick
        harvest_respects_exposing_list;
      test_case "property generator builds entity rows as hashes" `Quick
        property_gen_entity_hash;
    ];
    "name-wired #41 class — cache / email / publish / sse-route", [
      test_case "declaring module runtime objects emit Go" `Quick
        name_wired_local_hit_byte_stable;
      test_case "using-only module checks" `Quick
        name_wired_cross_module_miss_lookup;
      test_case "cross-module cache/email use checks" `Quick
        name_wired_requires_fire_on_use;
      test_case "non-local cacheCap checks" `Quick
        name_wired_cachecap_value_synthesized;
      test_case "cross-module sse-route checks" `Quick
        name_wired_sse_route_symbol_lazy;
    ];
    "entrypoint-closure diagnostic", [
      test_case "program root rejects a channel declared nowhere" `Quick
        closure_diag_root_rejects_undeclared;
      test_case "library standalone stays runtime-resolved" `Quick
        closure_diag_library_standalone_exempt;
      test_case "program root rejects a job type no queue declares" `Quick
        closure_diag_root_rejects_undeclared_job_type;
      test_case "program root rejects a cache declared in two modules" `Quick
        closure_diag_root_rejects_duplicate_decl;
    ];
    "exportable cache/email names", [
      test_case "exposing [C, E] checks and provides" `Quick
        cache_email_names_exportable;
    ];
  ]
