(** GitHub issues #40 / #41 / #42 — multi-module emit regressions.

    All three shared the same root class as issues #33–36: per-module emitter
    state built from the current module's own decls only, so a construct that
    is correct same-module mis-emitted (or failed to bind) cross-module while
    `tesl --check` (whole-program) passed.

    #40 — an imported record/entity literal in EXPRESSION position missed the
          record/entity construction arms (ctx.record_fields / entity_names
          were local-decls-only) and fell through to the generic constructor
          call: `(Box (hash 'n 3))` → "Box: arity mismatch" at runtime, and
          `(Thing (hash ...))` applied a non-procedure entity-spec.  Fixed by
          harvesting DRecord/DEntity from directly imported local modules.

    #41 — `enqueue Job {...}` in a module whose queue is declared in the
          entrypoint emitted the never-defined `_queue_for_<Job>` identifier
          (raw Racket unbound-identifier at raco make).  Fixed by lowering the
          table-miss to a lazy, fail-closed runtime registry lookup
          (tesl/queue.rkt) — every define-queue already registers its live
          spec process-wide.  DESIGN-4 Topic B upgraded the lookup from the
          name-keyed `(queue-for-job 'Job)` to the NOMINAL macro form
          `(queue-for-job-ref Job)`: the job-type identifier is normalized at
          the enqueue site to a #s(type-ref owner name), so a same-name job
          record declared by a DIFFERENT module fails closed at enqueue with
          both owners instead of silently misrouting by spelling.

    #42 — a stdlib nominal type (Money / TimeZone / a MoneyPer… alias) at an
          endpoint /
          imported-handler signature was emitted as an UNBOUND identifier
          (filtered by config_only_import_names), so normalize-type-identifier
          keyed the minted type-ref to the EMITTING file and define-server
          rejected `#s(type-ref main.rkt Money)` vs `#s(type-ref lib.rkt
          Money)`.  Fixed by providing the type-name symbols from the runtime
          modules and un-filtering them, so both sides key to the declaring
          runtime module — same mechanism that already made PosixMillis and
          user records work. *)

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
  let code, out = run_cc [path] in
  if code <> 0 then failf "emit of %s failed:\n%s" what out;
  out

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
  get "/seed"
    -> Int
}

handler rawBox() -> Int =
  let raw = Box { n: 3 }
  raw.n

handler seedRows() -> Int requires [dbRead, dbWrite] =
  let rows = [Thing { id: "a" }]
  insertMany rows in Thing
  1

server MainServer for MainApi {
  database = DB
  rawBox = rawBox
  seedRows = seedRows
}
|}

let issue40_record_keyword_ctor () =
  with_project ~lib:i40_lib ~main:i40_main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (issue40)" main_p in
    if not (contains "(Box #:n 3)" out) then
      failf "imported record literal must emit the keyword ctor (Box #:n 3) (#40):\n%s" out;
    if contains "(Box (hash" out then
      failf "imported record literal fell through to the generic ctor arm (#40):\n%s" out)

let issue40_entity_plain_hash () =
  with_project ~lib:i40_lib ~main:i40_main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (issue40)" main_p in
    if contains "(Thing (hash" out then
      failf "imported entity literal applied the entity-spec as a procedure (#40):\n%s" out;
    if not (contains {|(hash 'id "a")|} out) then
      failf "imported entity literal must emit a plain field hash (#40):\n%s" out)

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
    let out = emit_ok "main (issue40 ImportAll)" main_p in
    if not (contains "(Box #:n 3)" out) then
      failf "ImportAll record literal must emit the keyword ctor (Box #:n 3):\n%s" out;
    if contains "(Box (hash" out then
      failf "ImportAll record literal fell through to the generic ctor arm:\n%s" out;
    (* entity twin: plain field hash, not spec-as-procedure *)
    if contains "(Thing (hash" out then
      failf "ImportAll entity literal applied the entity-spec as a procedure:\n%s" out;
    if not (contains {|(hash 'id "a")|} out) then
      failf "ImportAll entity literal must emit a plain field hash:\n%s" out)

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
    let out = emit_ok "lib (issue41)" lib_p in
    if contains "_queue_for_" out then
      failf "enqueue without a same-module queue emitted the unbound _queue_for_ identifier (#41):\n%s" out;
    if not (contains "(enqueue! (queue-for-job-ref PingJob)" out) then
      failf "enqueue without a same-module queue must lower to the nominal registry lookup (#41 / DESIGN-4 B):\n%s" out;
    if contains "(queue-for-job '" out then
      failf "the name-keyed (queue-for-job 'X) miss form must no longer be emitted (DESIGN-4 B):\n%s" out)

(* ── #42: stdlib nominal types must be require-bound in emitted modules ──── *)

let i42_lib = {|module Lib exposing [moneyBack]
import Tesl.Prelude exposing [String]
import Tesl.Money exposing [Money, Money.sek]

handler moneyBack() -> Money =
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
  moneyBack = moneyBack
}
|}

let issue42_money_require_bound () =
  with_project ~lib:i42_lib ~main:i42_main (fun ~lib_p ~main_p ->
    let lib_out = emit_ok "lib (issue42)" lib_p in
    let main_out = emit_ok "main (issue42)" main_p in
    (* Both sides must require the type-name symbol from the runtime module so
       normalize-type-identifier keys both type-refs to tesl/tesl/money — an
       unbound Money keys the type-ref to the emitting file and define-server
       rejects the imported handler. *)
    List.iter (fun (what, out) ->
      if not (contains "only-in tesl/tesl/money Money" out) then
        failf "%s must require-bind Money from tesl/tesl/money (#42):\n%s" what out)
      [("lib", lib_out); ("main", main_out)])

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
    let out = emit_ok "lib (issue42 aliases)" lib_p in
    if not (contains "TimeZone" out) then
      failf "TimeZone must be require-bound from tesl/tesl/time (#42):\n%s" out;
    if not (contains "MoneyPerDuration" out) then
      failf "MoneyPerDuration must be require-bound from tesl/tesl/money (#42):\n%s" out)

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
    let out = emit_ok "main (hijack)" main_p in
    if not (contains "(Thing 3)" out) then
      failf "local ADT ctor Thing must keep positional ADT emission (#40 review):\n%s" out;
    if contains {|(hash 'n 3)|} out then
      failf "local ADT ctor construction hijacked by imported entity harvest (#40 review):\n%s" out)

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
    let out = emit_ok "main (private decl)" main_p in
    if not (contains "(Thing #:n 3)" out) then
      failf "local record Thing must win over an unexposed imported entity (#40 review):\n%s" out)

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
    let out = emit_ok "main (property entity)" main_p in
    if contains "(Thing #:id" out then
      failf "property generator keyword-called an entity-spec (#40 review):\n%s" out;
    if not (contains "(hash 'id" out) then
      failf "property generator must build entity rows as plain hashes (#40 review):\n%s" out)

(* EmailBody is the same #42 class: it appears verbatim in emitted type
   positions, so it must be require-bound, not config-only-filtered. *)
let issue42_emailbody_bound () =
  let lib = {|module Lib exposing [bodyBack]
import Tesl.Prelude exposing [String]
import Tesl.Email exposing [EmailBody, TextBody]

handler bodyBack() -> EmailBody =
  TextBody "hello"
|} in
  with_project ~lib ~main:"module Main exposing []\n" (fun ~lib_p ~main_p:_ ->
    let out = emit_ok "lib (emailbody)" lib_p in
    if not (contains "only-in tesl/tesl/email EmailBody" out) then
      failf "EmailBody must be require-bound from tesl/tesl/email (#42 review):\n%s" out)

(* ── name-wired runtime objects (the full #41 class): cache / email /
      publish / sse-route.  A name declared in the SAME module keeps its bare
      define-* binding (byte-stable hit path); a name declared in ANOTHER
      module lowers to the per-call, fail-closed registry lookup
      ((cache-for-name 'C) / (email-for-name 'E) / (channel-for-name 'Ch)) —
      and the tesl/tesl/cache / tesl/tesl/email requires fire on USE, not only
      on local declaration. ─────────────────────────────────────────────── *)

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
    let out = emit_ok "lib (name-wired hit)" lib_p in
    List.iter (fun needle ->
      if not (contains needle out) then
        failf "declaring module must keep the bare local binding %S (#41 hit path):\n%s"
          needle out)
      [ "(cache-get! C "; "(send-email! E #:to "; "(publish-event! Ch " ];
    List.iter (fun banned ->
      if contains banned out then
        failf "declaring module must NOT take the registry-lookup path (%S) (#41 hit path):\n%s"
          banned out)
      [ "(cache-for-name"; "(email-for-name"; "(channel-for-name" ])

let name_wired_cross_module_miss_lookup () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    let code, out = run_cc ["--check"; main_p] in
    if code <> 0 then failf "check of name-wired main must pass (#41):\n%s" out;
    let out = emit_ok "main (name-wired miss)" main_p in
    List.iter (fun needle ->
      if not (contains needle out) then
        failf "using-only module must lower to the registry lookup %S (#41):\n%s"
          needle out)
      [ "(cache-get! (cache-for-name 'C) ";
        "(send-email! (email-for-name 'E) #:to ";
        "(start-email-worker! (email-for-name 'E))";
        "(publish-event! (channel-for-name 'Ch) " ])

let name_wired_requires_fire_on_use () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (name-wired requires)" main_p in
    (* The using-only module has NO local cache/email decl, so before the fix
       even send-email!/cache-get! themselves were unbound (require gated on a
       LOCAL decl). *)
    List.iter (fun needle ->
      if not (contains needle out) then
        failf "using-only module must require %S (declares-OR-uses gate):\n%s"
          needle out)
      [ "tesl/tesl/cache"; "tesl/tesl/email" ])

let name_wired_cachecap_value_synthesized () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p:_ ~main_p ->
    let out = emit_ok "main (cacheCap synth)" main_p in
    if not (contains "(define cacheCap_C (cache-spec-capability (cache-for-name 'C)))" out) then
      failf "non-local `requires [cacheCap C]` must bind the declaring module's \
             capability VALUE via the registry:\n%s" out)

(* The sse-routes list is a top-level define (instantiation time), so a
   cross-module channel must be deferred as a quoted SYMBOL, resolved lazily
   by the subscribe path — never a direct channel-for-name call. *)
let nw_sse_main = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Json exposing [stringCodec]
import Tesl.Queue exposing [pubsub]
import Lib exposing [NoticeEvent(..), Ch]

fn parseUserId(id: String) -> String =
  id

capturer userIdCapture: String using stringCodec via parseUserId

handler sendNotice() -> String requires [pubsub] =
  publish Ch("u1") NoticeSent { message: "m" }
  "ok"

api MainApi {
  get "/send"
    -> String

  sse "/events/:userId"
    capture userId: String via userIdCapture
    subscribe Ch(userId)
}

server MainServer for MainApi {
  sendNotice = sendNotice
}
|}

let name_wired_sse_route_symbol_lazy () =
  with_project ~lib:nw_lib ~main:nw_sse_main (fun ~lib_p ~main_p ->
    let main_out = emit_ok "main (sse symbol)" main_p in
    if not (contains "#f 'Ch " main_out) then
      failf "cross-module sse-route channel must be the quoted symbol 'Ch \
             (lazy resolve at subscribe; instantiation-time position):\n%s" main_out;
    if contains "(channel-for-name 'Ch)" main_out
       && contains "-sse-routes (list (list" main_out
       && contains "(list (list \"events\" #f) #f (channel-for-name" main_out then
      failf "sse-routes must NOT call channel-for-name at instantiation time:\n%s" main_out;
    (* Declaring-module control: a LOCAL channel in the route stays the bare
       binding (byte-stable). *)
    let lib_out = emit_ok "lib (sse local control)" lib_p in
    ignore lib_out)

(* ── entrypoint-closure diagnostic: a name declared NOWHERE in the program
      can never resolve via the registry, so a PROGRAM ROOT (main/server/
      api-test) fails at --check; a plain library stays runtime-resolved. ── *)

let nw_root_ghost = {|module Main exposing [MainServer]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Queue exposing [pubsub]

type Ev = EvMade message: String

handler h() -> String requires [pubsub] =
  publish Ghost("k") EvMade { message: "x" }
  "ok"

api MainApi {
  get "/x"
    -> String
}

server MainServer for MainApi {
  h = h
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

handler h() -> String requires [queueWrite] =
  enqueue GhostJob { name: "x" }
  "ok"

api MainApi {
  get "/x"
    -> String
}

server MainServer for MainApi {
  h = h
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

handler h() -> String =
  "ok"

server MainServer for MainApi {
  h = h
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

(* An imported fn returning `Maybe (v: T ::: P v)` must mark its let-bound
   result a proof carrier so the Something-arm payload stays the NAMED value:
   the ELetProof decomposition emits `(let ([tesl-proof-binding-N v])` — the
   stripped `*v` form traps at runtime with "detach-all-proof: no proof is
   attached" (the empirically red channel).  Assertions derived from the
   actual red/green emit diff of the design repro. *)
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
       let out = emit_ok "main (design4 carrier)" main_p in
       (* Green shape: the decomposition tmp is bound to the NAMED payload. *)
       if not (contains "(let ([tesl-proof-binding-1 v])" out) then
         failf "imported proof-carrier decomposition must bind the NAMED \
                Something payload (red form binds *v and traps at runtime):\n%s" out;
       if contains "(let ([tesl-proof-binding-1 *v])" out then
         failf "imported proof-carrier decomposition stripped the named-value \
                (DESIGN-4 A red form):\n%s" out)

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
       let out = emit_ok "main (design4 qualified carrier)" main_p in
       if not (contains "(let ([tesl-proof-binding-1 v])" out) then
         failf "QUALIFIED imported proof-carrier decomposition must bind the \
                NAMED payload (DESIGN-4 A consumer completeness):\n%s" out)

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
       let out = emit_ok "main (design4 ctor)" main_p in
       if not (contains "(MkPair 7 n)" out) then
         failf "imported proof-annotated ctor field must keep the NAMED value \
                (MkPair 7 n) — the red form strips to *n (DESIGN-4 A):\n%s" out;
       if contains "(MkPair 7 *n)" out then
         failf "imported proof-annotated ctor field stripped the named-value \
                (DESIGN-4 A red form):\n%s" out)

(* ── cache / email names are exportable (declared-in-lib direction) ─────── *)

let cache_email_names_exportable () =
  with_project ~lib:nw_lib ~main:nw_main (fun ~lib_p ~main_p:_ ->
    (* `module Lib exposing [C, E]` used to fail with "only locally-defined
       names can be exported" — DCache/DEmail were missing from decl_names. *)
    let code, out = run_cc ["--check"; lib_p] in
    if code <> 0 then
      failf "exposing a locally declared cache/email name must check (#41 companion):\n%s" out;
    let out = emit_ok "lib (provide)" lib_p in
    if not (contains "(provide LibDb C E Ch" out) then
      failf "exported cache/email names must be provided by the emitted module:\n%s" out)

let () =
  run "Issues-40-41-42" [
    "issue 40 — imported record/entity literal", [
      test_case "imported record literal emits the keyword ctor" `Quick
        issue40_record_keyword_ctor;
      test_case "imported entity literal emits a plain hash" `Quick
        issue40_entity_plain_hash;
      test_case "ImportAll record/entity literal emits the record arms" `Quick
        issue40_importall_record_keyword_ctor;
    ];
    "issue 41 — cross-module enqueue", [
      test_case "table miss lowers to (queue-for-job-ref Job)" `Quick
        issue41_cross_module_enqueue_lookup;
    ];
    "DESIGN-4 A — cross-module proof metadata", [
      test_case "imported proof-carrier decomposition keeps the named value" `Quick
        design4_imported_proof_carrier_named_value;
      test_case "qualified imported proof-carrier keeps the named value" `Quick
        design4_qualified_proof_carrier_named_value;
      test_case "imported proof-annotated ctor field keeps the named value" `Quick
        design4_imported_ctor_proof_field_named_value;
    ];
    "issue 42 — stdlib nominal type-refs", [
      test_case "Money is require-bound on both sides" `Quick
        issue42_money_require_bound;
      test_case "TimeZone and MoneyPer* aliases are require-bound" `Quick
        issue42_timezone_and_rate_aliases_bound;
      test_case "EmailBody is require-bound (same class)" `Quick
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
      test_case "declaring module keeps bare bindings (hit path byte-stable)" `Quick
        name_wired_local_hit_byte_stable;
      test_case "using-only module lowers to registry lookups" `Quick
        name_wired_cross_module_miss_lookup;
      test_case "cache/email requires fire on use, not only local decl" `Quick
        name_wired_requires_fire_on_use;
      test_case "non-local cacheCap value is registry-synthesized" `Quick
        name_wired_cachecap_value_synthesized;
      test_case "cross-module sse-route channel is a lazy symbol" `Quick
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
