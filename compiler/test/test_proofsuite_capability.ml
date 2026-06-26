(** ProofSuite family L — CAPABILITY requirements (negative + positive).

    Proves the STATIC checker enforces TESL's capability discipline without the
    runtime net: a handler/worker/fn that performs a privileged operation
    (select/insert/update/delete, time, random, …) or transitively calls a
    callee requiring a capability MUST declare that capability via
    `requires [...]`.  Also: capability implication lattice + cycle detection,
    auth-call restriction (auth functions may only be called from handler
    bodies / other auth fns), and handler isolation (handlers cannot be called
    from code).

    Hardening: [should_fail] additionally fails if the compiler output contains
    any runtime-leak marker (`raise-user-error`, `check-fail`, a Racket
    backtrace).  Rejection of these programs must be STATIC — they must never
    reach the emitted Racket where a runtime guard would catch them.

    Modeled on test_library_negative.ml / test_review20_antagonistic.ml.

    Verified error strings (validation layer, all `error[V001]:` unless noted):
      - "handler 'H' uses [dbRead] but does not declare the required capabilities"
      - "worker 'W' uses [dbWrite] but does not declare the required capabilities"
      - "fn 'F' uses privileged operations and callees requiring [..] but does not declare them"
      - "capability cycle detected: a → b → a"
      - "`C` calls auth function `A` from a `fn`; auth functions may only be called from handler bodies or other auth functions"
      - "`C` calls handler `H` directly; handlers cannot be called from code"
      - "function 'F' requires undeclared capability 'X'"   (error[P001]) *)

open Alcotest

(* ── Compiler resolution ──────────────────────────────────────────────────── *)

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

(* Derive a kebab-case file name from the module/library header so the compiler's
   "module header does not match file name" check stays quiet (it resolves
   imports by file name).  Falls back to test.tesl. *)
let file_name_of_src content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re content 0);
    let mname = Str.matched_group 2 content in
    let buf = Buffer.create (String.length mname + 4) in
    String.iteri (fun i c ->
      if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
      else if c >= 'A' && c <= 'Z' then
        (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c) mname;
    Buffer.contents buf ^ ".tesl"
  with Not_found -> "test.tesl"

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psL" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* Runtime-leak markers: presence means the program reached emitted Racket and
   relied on a dynamic guard, i.e. the static checker FAILED to reject it. *)
let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception";
]

let assert_no_runtime_leak pat out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "STATIC-REJECTION VIOLATED for %S: output contains runtime-leak \
                marker %S — rejection leaked to runtime:\n%s" pat m out)
    leak_markers

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    assert_no_runtime_leak pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── Source fragments ──────────────────────────────────────────────────────── *)

(* A minimal entity + DB-capability import block shared by handler/worker DB
   tests.  Entity declaration alone compiles (no `database` block needed for
   `--check`). *)
let note_entity = {|
entity Note table "notes" primaryKey id {
  id: String @db(text)
  authorId: String @db(text)
  n: Int @db(integer)
}
|}

(* ── L1 — undeclared capability: privileged DB op without `requires` ────────── *)
(* A handler/fn/worker doing select/insert/update/delete must declare the
   matching dbRead/dbWrite capability.  We sweep operation × consumer-kind. *)

(* Each entry: (tag, body-using-op, return-type, op-cap, extra-imports). *)
type db_op = {
  op_tag   : string;
  op_body  : string;   (* a SQL form whose result type matches [op_ret] *)
  op_ret   : string;   (* declared return type of the handler/fn *)
  op_cap   : string;   (* the capability the op needs (for the regex) *)
}

let db_ops = [
  { op_tag = "select";    op_cap = "dbRead";
    op_ret = "List Note";
    op_body = "select note from Note where note.id == id" };
  { op_tag = "selectCount"; op_cap = "dbRead";
    op_ret = "Int";
    op_body = "selectCount note from Note where note.id == id" };
  { op_tag = "selectMax"; op_cap = "dbRead";
    op_ret = "Int";
    op_body = "selectMax note.n from Note where note.id == id" };
  { op_tag = "selectSum"; op_cap = "dbRead";
    op_ret = "Int";
    op_body = "selectSum note.n from Note where note.id == id" };
  { op_tag = "insert";    op_cap = "dbWrite";
    op_ret = "Note";
    op_body = "insert Note { id: id, authorId: id, n: 0 }" };
  { op_tag = "update";    op_cap = "dbWrite";
    op_ret = "Unit";
    op_body = "update note in Note where note.id == id set note.authorId = id returning one" };
  { op_tag = "delete";    op_cap = "dbWrite";
    op_ret = "Unit";
    op_body = "delete note from Note where note.id == id" };
]

let dbops_handler_undeclared =
  List.concat_map (fun o ->
    [ Printf.sprintf "L1H-%s handler %s without %s" o.op_tag o.op_tag o.op_cap,
      (fun () ->
         should_fail "handler 'getN' uses .* but does not declare the required capabilities"
           (Printf.sprintf {|
#lang tesl
module CapL1H%s exposing []
import Tesl.Prelude exposing [List, String, Int, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
handler getN(id: String) -> %s requires [] =
  %s
|} (String.capitalize_ascii o.op_tag) note_entity o.op_ret o.op_body)) ])
    db_ops

let dbops_handler_declared_positive =
  List.concat_map (fun o ->
    [ Printf.sprintf "L1H-%s handler %s WITH %s (positive)" o.op_tag o.op_tag o.op_cap,
      (fun () ->
         should_pass
           (Printf.sprintf {|
#lang tesl
module CapL1HP%s exposing []
import Tesl.Prelude exposing [List, String, Int, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
handler getN(id: String) -> %s requires [%s] =
  %s
|} (String.capitalize_ascii o.op_tag) note_entity o.op_ret o.op_cap o.op_body)) ])
    db_ops

(* Same operation sweep, but the consumer is a plain `fn` that touches the DB.
   A fn doing a privileged op must also declare the capability. *)
let dbops_fn_undeclared =
  List.concat_map (fun o ->
    [ Printf.sprintf "L1F-%s fn %s without %s" o.op_tag o.op_tag o.op_cap,
      (fun () ->
         should_fail "fn 'getN' uses privileged operations.* but does not declare them\\|does not declare the required capabilities"
           (Printf.sprintf {|
#lang tesl
module CapL1F%s exposing []
import Tesl.Prelude exposing [List, String, Int, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
fn getN(id: String) -> %s =
  %s
|} (String.capitalize_ascii o.op_tag) note_entity o.op_ret o.op_body)) ])
    db_ops

(* Worker consumer doing a DB op directly in its body (returns its job).  The
   op bodies reference a parameter named [id]; we bind [let id = j.id] first so
   the op body is reused verbatim. *)
let dbops_worker_undeclared =
  List.concat_map (fun o ->
    [ Printf.sprintf "L1W-%s worker %s without %s" o.op_tag o.op_tag o.op_cap,
      (fun () ->
         should_fail "worker 'doJob' uses .* but does not declare the required capabilities"
           (Printf.sprintf {|
#lang tesl
module CapL1W%s exposing []
import Tesl.Prelude exposing [List, String, Int, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
record JobRec { jid: String }
worker doJob(j: JobRec) requires [] =
  let id = j.jid
  let _r = %s
  j
|} (String.capitalize_ascii o.op_tag) note_entity o.op_body)) ])
    db_ops

(* More privileged ops: time, random.  Each must be declared (and the cap name
   imported).  Sweep negative (no cap) + positive (cap declared). *)
type priv_op = {
  pv_tag  : string;
  pv_imp  : string;   (* imports incl. the capability name *)
  pv_ret  : string;
  pv_body : string;
  pv_cap  : string;
}

let priv_ops = [
  { pv_tag = "time"; pv_cap = "time";
    pv_imp = "import Tesl.Time exposing [nowMillis, time, PosixMillis]";
    pv_ret = "PosixMillis"; pv_body = "nowMillis()" };
  { pv_tag = "random"; pv_cap = "random";
    pv_imp = "import Tesl.Random exposing [random]\nimport Tesl.Id exposing [generatePrefixedId]";
    pv_ret = "String"; pv_body = "generatePrefixedId \"x\"" };
]

let privops_handler_undeclared =
  List.concat_map (fun o ->
    [ Printf.sprintf "L7H-%s op without cap" o.pv_tag,
      (fun () ->
         should_fail "uses .* but does not declare\\|does not declare the required capabilities"
           (Printf.sprintf {|
#lang tesl
module CapPv%s exposing []
import Tesl.Prelude exposing [String, Int]
%s
handler h() -> %s requires [] =
  %s
|} (String.capitalize_ascii o.pv_tag) o.pv_imp o.pv_ret o.pv_body)) ])
    priv_ops

let privops_handler_declared_positive =
  List.concat_map (fun o ->
    [ Printf.sprintf "L7H-%s op with cap (positive)" o.pv_tag,
      (fun () ->
         should_pass
           (Printf.sprintf {|
#lang tesl
module CapPvP%s exposing []
import Tesl.Prelude exposing [String, Int]
%s
handler h() -> %s requires [%s] =
  %s
|} (String.capitalize_ascii o.pv_tag) o.pv_imp o.pv_ret o.pv_cap o.pv_body)) ])
    priv_ops

(* ── L2 — capability-via-callee: caller must re-declare callee requirements ─── *)
(* A fn/handler/worker that calls a fn requiring `dbWrite` from a context that
   declares only `dbRead` (or nothing) is rejected.  `todoWrite`/`todoRead`
   here are user-declared wrappers, exactly the plan's "todoWrite from a
   todoRead context" scenario. *)

let cap_callee_lattice = {|
import Tesl.DB exposing [dbRead, dbWrite]
capability todoRead implies dbRead
capability todoWrite implies dbWrite
|}

let test_L2_fn_calls_dbWrite_callee_with_only_dbRead () =
  should_fail "fn 'reader' uses privileged operations and callees requiring .* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module CapL2A exposing []
import Tesl.Prelude exposing [Int]
%s
fn writer(n: Int) -> Int requires [dbWrite] = n
fn reader(n: Int) -> Int requires [dbRead] =
  writer n
|} cap_callee_lattice)

let test_L2_fn_calls_todoWrite_callee_with_only_todoRead () =
  should_fail "fn 'reader' uses privileged operations and callees requiring .* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module CapL2B exposing []
import Tesl.Prelude exposing [Int]
%s
fn mutate(n: Int) -> Int requires [todoWrite] = n
fn reader(n: Int) -> Int requires [todoRead] =
  mutate n
|} cap_callee_lattice)

let test_L2_fn_calls_callee_declaring_nothing () =
  should_fail "fn 'reader' uses privileged operations and callees requiring .* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module CapL2C exposing []
import Tesl.Prelude exposing [Int]
%s
fn writer(n: Int) -> Int requires [dbWrite] = n
fn reader(n: Int) -> Int requires [] =
  writer n
|} cap_callee_lattice)

let test_L2_handler_calls_callee_without_cap () =
  should_fail "handler 'h' uses .* but does not declare the required capabilities"
    (Printf.sprintf {|
#lang tesl
module CapL2D exposing []
import Tesl.Prelude exposing [Int]
%s
fn writer(n: Int) -> Int requires [dbWrite] = n
handler h(n: Int) -> Int requires [] =
  writer n
|} cap_callee_lattice)

let test_L2_callee_chain_positive () =
  (* Caller declares the callee's requirement transitively via implication. *)
  should_pass
    (Printf.sprintf {|
#lang tesl
module CapL2E exposing []
import Tesl.Prelude exposing [Int]
%s
fn mutate(n: Int) -> Int requires [dbWrite] = n
fn reader(n: Int) -> Int requires [todoWrite] =
  mutate n
|} cap_callee_lattice)

(* Capability-via-callee swept across caller-kinds {fn, handler, worker} ×
   declared-cap {none, only-the-wrong-one}.  The callee requires dbWrite. *)
type cap_caller = {
  cc_id    : string;
  cc_pat   : string;
  cc_decl  : string -> string;  (* given the requires-list text -> caller decl *)
  cc_extra : string;
}

let cap_callers = [
  { cc_id = "fn"; cc_extra = "";
    cc_pat = "fn 'caller' uses privileged operations and callees requiring .* but does not declare them";
    cc_decl = (fun req ->
      Printf.sprintf "fn caller(n: Int) -> Int requires [%s] =\n  writer n" req) };
  { cc_id = "handler"; cc_extra = "";
    cc_pat = "handler 'caller' uses .* but does not declare the required capabilities";
    cc_decl = (fun req ->
      Printf.sprintf "handler caller(n: Int) -> Int requires [%s] =\n  writer n" req) };
  { cc_id = "worker"; cc_extra = "record JobRec { n: Int }";
    cc_pat = "worker 'caller' uses .* but does not declare the required capabilities";
    cc_decl = (fun req ->
      Printf.sprintf "worker caller(j: JobRec) requires [%s] =\n  let _x = writer j.n\n  j" req) };
]

(* declared-cap options that DON'T cover dbWrite *)
let insufficient_caps = [ "none", ""; "wrong", "dbRead" ]

let cap_via_callee_matrix =
  List.concat_map (fun cc ->
    List.map (fun (cap_tag, req) ->
      Printf.sprintf "L2M-%s/%s callee dbWrite uncovered" cc.cc_id cap_tag,
      (fun () ->
         should_fail cc.cc_pat
           (Printf.sprintf {|
#lang tesl
module CapL2M%s%s exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead, dbWrite]
fn writer(n: Int) -> Int requires [dbWrite] = n
%s
%s
|} (String.capitalize_ascii cc.cc_id) (String.capitalize_ascii cap_tag)
   (if cc.cc_extra = "" then "" else cc.cc_extra ^ "\n") (cc.cc_decl req))))
      insufficient_caps)
    cap_callers

(* ── L3 — capability cycles ──────────────────────────────────────────────── *)

let test_L3_two_node_cycle () =
  should_fail "capability cycle detected"
    {|
#lang tesl
module CapCyc2 exposing []
import Tesl.Prelude exposing [Int]
capability a implies b
capability b implies a
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_three_node_cycle () =
  should_fail "capability cycle detected"
    {|
#lang tesl
module CapCyc3 exposing []
import Tesl.Prelude exposing [Int]
capability a implies b
capability b implies c
capability c implies a
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_self_cycle () =
  should_fail "capability cycle detected"
    {|
#lang tesl
module CapCycSelf exposing []
import Tesl.Prelude exposing [Int]
capability a implies a
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_four_node_cycle () =
  should_fail "capability cycle detected"
    {|
#lang tesl
module CapCyc4 exposing []
import Tesl.Prelude exposing [Int]
capability a implies b
capability b implies c
capability c implies d
capability d implies a
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_cycle_within_larger_graph () =
  (* A cycle b↔c embedded in an otherwise-acyclic graph is still caught. *)
  should_fail "capability cycle detected"
    {|
#lang tesl
module CapCycEmb exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability a implies b
capability b implies c
capability c implies b
capability e implies dbRead
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_diamond_no_cycle_positive () =
  (* Diamond lattice (a→b, a→c, b→d, c→d) is acyclic and must compile. *)
  should_pass
    {|
#lang tesl
module CapDiamond exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability d implies dbRead
capability b implies d
capability c implies d
capability a implies b, c
fn f(n: Int) -> Int requires [a] = n
|}

let test_L3_long_chain_no_cycle_positive () =
  should_pass
    {|
#lang tesl
module CapChain exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbRead]
capability e implies dbRead
capability d implies e
capability c implies d
capability b implies c
capability a implies b
fn f(n: Int) -> Int requires [a] = n
|}

(* ── L6b — capability used without importing its name ─────────────────────── *)
(* `random`/`time`/etc. are capability names that must be in scope (imported)
   before they can appear in `requires`. *)

let test_L6b_cap_used_without_import () =
  should_fail "requires undeclared capability\\|undeclared capability"
    {|
#lang tesl
module CapNoImp exposing []
import Tesl.Prelude exposing [String]
import Tesl.Id exposing [generatePrefixedId]
handler h() -> String requires [random] =
  generatePrefixedId "x"
|}

let test_L6b_time_cap_used_without_import () =
  should_fail "requires undeclared capability\\|undeclared capability"
    {|
#lang tesl
module CapNoImpTime exposing []
import Tesl.Prelude exposing []
import Tesl.Time exposing [nowMillis, PosixMillis]
handler h() -> PosixMillis requires [time] =
  nowMillis()
|}

(* ── L4 — auth-call restriction ──────────────────────────────────────────── *)
(* `check <authFn> ...` is only legal in handler bodies or other auth fns. *)

let auth_decls = {|
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no"
    Something userId -> ok userId ::: Authenticated user
|}

(* Sweep: the caller-kind that illegally invokes auth. *)
let auth_callers = [
  "fn",       "fn caller(request: HttpRequest) -> String =\n  let u = check cookieAuth request\n  u";
  "check",    "check caller(request: HttpRequest) -> u: String ::: Authenticated u =\n  let v = check cookieAuth request\n  ok v ::: Authenticated u";
  "establish","establish caller(request: HttpRequest) -> u: String ::: Authenticated u =\n  let v = check cookieAuth request\n  v ::: Authenticated u";
]

let auth_call_negatives =
  List.mapi (fun i (kind, body) ->
    Printf.sprintf "L4-%s auth called from %s" kind kind,
    (fun () ->
       should_fail "auth functions may only be called from handler bodies or other auth functions"
         (Printf.sprintf {|
#lang tesl
module CapAuthCall%d exposing []
import Tesl.Prelude exposing [String]
%s
%s
|} i auth_decls body)))
    auth_callers

let test_L4_auth_from_handler_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module CapAuthPos exposing []
import Tesl.Prelude exposing [String]
%s
handler caller(request: HttpRequest) -> String requires [] =
  let u = check cookieAuth request
  u
|} auth_decls)

(* ── L5 — handler isolation ──────────────────────────────────────────────── *)
(* Handlers cannot be referenced from code; only the server router may. *)

let handler_iso_callers = [
  "fn",       "fn caller(n: Int) -> Int =\n  protectedHandler n";
  "handler",  "handler caller(n: Int) -> Int requires [] =\n  protectedHandler n";
  "worker",   "record JobRec { n: Int }\nworker caller(j: JobRec) requires [] =\n  let _x = protectedHandler j.n\n  j";
]

let handler_iso_negatives =
  List.mapi (fun i (kind, body) ->
    Printf.sprintf "L5-%s handler referenced from %s" kind kind,
    (fun () ->
       should_fail "calls handler `protectedHandler` directly\\|handlers cannot be called from code"
         (Printf.sprintf {|
#lang tesl
module CapHIso%d exposing []
import Tesl.Prelude exposing [Int]
handler protectedHandler(n: Int) -> Int requires [] = n
%s
|} i body)))
    handler_iso_callers

(* ── L6 — unknown / undeclared capability NAME in `requires` ──────────────── *)
(* This is the proof-checker path (error[P001]). *)

let test_L6_unknown_capability_name () =
  should_fail "requires undeclared capability\\|undeclared capability"
    {|
#lang tesl
module CapUnk exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int requires [totallyBogusCap] = n
|}

let test_L6_handler_unknown_capability_name () =
  should_fail "requires undeclared capability\\|undeclared capability"
    {|
#lang tesl
module CapUnkH exposing []
import Tesl.Prelude exposing [Int]
handler h(n: Int) -> Int requires [noSuchCapXyz] = n
|}

(* ── L7 — privileged-op coverage: time/random need their caps ─────────────── *)

let test_L7_time_op_undeclared () =
  should_fail "uses .* but does not declare\\|does not declare the required capabilities"
    {|
#lang tesl
module CapTime exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Time exposing [nowMillis, time, PosixMillis]
handler h() -> PosixMillis requires [] =
  nowMillis()
|}

let test_L7_time_op_declared_positive () =
  should_pass
    {|
#lang tesl
module CapTimeP exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Time exposing [nowMillis, time, PosixMillis]
handler h() -> PosixMillis requires [time] =
  nowMillis()
|}

(* ── L8 — worker / deadWorker capability obligations ──────────────────────── *)

let worker_db_lattice = {|
import Tesl.DB exposing [dbRead, dbWrite]
record JobRec { n: Int }
fn writer(n: Int) -> Int requires [dbWrite] = n
|}

let test_L8_worker_callee_undeclared () =
  should_fail "worker 'doJob' uses .* but does not declare the required capabilities"
    (Printf.sprintf {|
#lang tesl
module CapWkr exposing []
import Tesl.Prelude exposing [Int]
%s
worker doJob(j: JobRec) requires [] =
  let _x = writer j.n
  j
|} worker_db_lattice)

let test_L8_worker_callee_declared_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module CapWkrP exposing []
import Tesl.Prelude exposing [Int]
%s
worker doJob(j: JobRec) requires [dbWrite] =
  let _x = writer j.n
  j
|} worker_db_lattice)

(* ── L9 — transitive-implication satisfaction (positives) ─────────────────── *)

let test_L9_transitive_service_cap_positive () =
  should_pass
    {|
#lang tesl
module CapSvc exposing []
import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead, dbWrite]
capability svc implies dbRead, dbWrite
entity Note table "notes" primaryKey id {
  id: String @db(text)
}
handler getN(id: String) -> List Note requires [svc] =
  select note from Note where note.id == id
|}

let test_L9_deep_transitive_positive () =
  (* svc → mid → dbWrite : two hops, still satisfied. *)
  should_pass
    {|
#lang tesl
module CapDeep exposing []
import Tesl.Prelude exposing [Int]
import Tesl.DB exposing [dbWrite]
capability mid implies dbWrite
capability svc implies mid
fn writer(n: Int) -> Int requires [dbWrite] = n
fn caller(n: Int) -> Int requires [svc] =
  writer n
|}

let test_L9_pure_fn_no_caps_positive () =
  (* A pure fn that touches no privileged op needs no requires. *)
  should_pass
    {|
#lang tesl
module CapPure exposing []
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
fn quad(n: Int) -> Int = double (double n)
|}

(* ── L10 — under-declared multi-cap handler ──────────────────────────────── *)
(* Declares only ONE of the two caps it needs (dbRead but not dbWrite). *)

let test_L10_partial_cap_declaration () =
  should_fail "uses .* but does not declare\\|does not declare the required capabilities"
    {|
#lang tesl
module CapPartial exposing []
import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Note table "notes" primaryKey id {
  id: String @db(text)
}
handler rw(id: String) -> Note requires [dbRead] =
  insert Note { id: id }
|}

let test_L10_both_caps_positive () =
  should_pass
    {|
#lang tesl
module CapBoth exposing []
import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Note table "notes" primaryKey id {
  id: String @db(text)
}
handler getN(id: String) -> List Note requires [dbRead] =
  select note from Note where note.id == id
handler ins(id: String) -> Note requires [dbWrite] =
  insert Note { id: id }
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let () =
  run "ProofSuite-L-Capability" [
    "L1-undeclared-db-capability", to_cases
      (dbops_handler_undeclared @ dbops_handler_declared_positive
       @ dbops_fn_undeclared @ dbops_worker_undeclared);
    "L2-capability-via-callee", to_cases ([
      "L2A fn dbWrite callee, only dbRead", test_L2_fn_calls_dbWrite_callee_with_only_dbRead;
      "L2B fn todoWrite callee, only todoRead", test_L2_fn_calls_todoWrite_callee_with_only_todoRead;
      "L2C fn callee, declares nothing", test_L2_fn_calls_callee_declaring_nothing;
      "L2D handler callee, no cap", test_L2_handler_calls_callee_without_cap;
      "L2E callee chain (positive)", test_L2_callee_chain_positive;
    ] @ cap_via_callee_matrix);
    "L3-capability-cycles", to_cases [
      "L3 two-node cycle", test_L3_two_node_cycle;
      "L3 three-node cycle", test_L3_three_node_cycle;
      "L3 self cycle", test_L3_self_cycle;
      "L3 four-node cycle", test_L3_four_node_cycle;
      "L3 cycle within larger graph", test_L3_cycle_within_larger_graph;
      "L3 diamond acyclic (positive)", test_L3_diamond_no_cycle_positive;
      "L3 long chain acyclic (positive)", test_L3_long_chain_no_cycle_positive;
    ];
    "L4-auth-call-restriction", to_cases (auth_call_negatives @ [
      "L4 auth from handler (positive)", test_L4_auth_from_handler_positive;
    ]);
    "L5-handler-isolation", to_cases handler_iso_negatives;
    "L6-unknown-capability-name", to_cases [
      "L6 unknown cap on fn", test_L6_unknown_capability_name;
      "L6 unknown cap on handler", test_L6_handler_unknown_capability_name;
      "L6b cap used without import", test_L6b_cap_used_without_import;
      "L6b time cap used without import", test_L6b_time_cap_used_without_import;
    ];
    "L7-privileged-op-coverage", to_cases ([
      "L7 time op undeclared", test_L7_time_op_undeclared;
      "L7 time op declared (positive)", test_L7_time_op_declared_positive;
    ] @ privops_handler_undeclared @ privops_handler_declared_positive);
    "L8-worker-capabilities", to_cases [
      "L8 worker callee undeclared", test_L8_worker_callee_undeclared;
      "L8 worker callee declared (positive)", test_L8_worker_callee_declared_positive;
    ];
    "L9-transitive-implication-positives", to_cases [
      "L9 service cap transitive (positive)", test_L9_transitive_service_cap_positive;
      "L9 deep transitive (positive)", test_L9_deep_transitive_positive;
      "L9 pure fn no caps (positive)", test_L9_pure_fn_no_caps_positive;
    ];
    "L10-under-declared-multi-cap", to_cases [
      "L10 partial cap declaration", test_L10_partial_cap_declaration;
      "L10 both caps (positive)", test_L10_both_caps_positive;
    ];
  ]
