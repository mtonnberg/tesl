(** GitHub issue #77 — a single-line query whose `where` predicate is compound
    swallowed the clauses that follow it.

    Tesl's SQL surface is not keyword-parsed: `select t from T where … order …`
    reaches the compiler as an ordinary application spine, which codegen
    (emit_racket's extractors) reinterprets structurally.  Application binds
    tighter than every binary operator, so the moment the predicate contained an
    operator the spine SPLIT and the trailing clause keywords were swallowed by
    the last operand's own application chain:

      select t from T where t.a == x && ilike t.name p order t.name asc limit 5
                                        └────────── ONE application chain ────┘

    Two symptoms, both of them #77:

      * with a FUNCTIONAL last predicate (`ilike …`) the clause atoms hid inside
        its argument list, no name check ever looked at them, and the query
        failed to extract — so the expression was emitted as ORDINARY
        application, referencing the row binder `t` outside any query.  `tesl
        check` was clean and the generated module could not load
        ("t: unbound identifier");
      * in every other shape a clause keyword landed in name-checked position
        and the compiler rejected valid-reading code with "unknown name: order".

    Also fixed here (reported in the same issue): a multi-line query could not be
    written inside parentheses at all — `List.length (select t from T\n  where …)`
    failed with "expected ) but got NEWLINE" — so a query could not be passed
    straight to a function; it had to be let-bound first.

    What this file pins
    ------------------------------------------------------------------------
    1. SHAPE PARITY.  The single-line and multi-line spellings of the same query
       produce the SAME lowering — asserted through codegen's own extractor, so
       the test cannot pass on a tree that merely looks plausible.
    2. THE CLASS.  A query shape codegen has no lowering for is a CHECK error,
       not a clean check followed by unloadable Racket.  That is the general
       protection: #77 was one shape, and the fall-through was the bug.
    3. The diagnostic names the actual cause (a non-literal `limit`, a
       single-line `update`, `insertMany` on a list literal) rather than only
       the shape.

    Runtime companion: tests/sql-clause-placement-tests.tesl — every shape below
    executed against the Memory backend and compared to the multi-line spelling. *)

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

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let with_source src f =
  let dir = Filename.temp_dir "tesl-issue77" "" in
  let path = Filename.concat dir "issue77.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* The file is named issue77.tesl, so the module header must match. *)
let prelude = {|module Issue77 exposing []
import Tesl.Prelude exposing [Bool(..), Int, List, String, Unit]
import Tesl.List exposing [List.length]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Memory]

entity Thing table "issue77_things" primaryKey id {
  id: String
  orgId: String
  name: String
  qty: Int
  archived: Bool
}

database D = Database {
  entities: [Thing]
  backend: Memory
}
|}

let check src = with_source (prelude ^ src) (fun p -> run_cc ["--check"; p])

let emit src =
  with_source (prelude ^ src) (fun p ->
    let code, out = run_cc [p] in
    if code <> 0 then failf "emit failed (exit %d):\n%s" code out;
    out)

let should_pass label src =
  let code, out = check src in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* ── 1. Parse shape: single-line == multi-line, through codegen's extractor ── *)

let parse_query src =
  (* Parse a one-function module and hand back the fn body, so the assertions
     below run against the SAME extractor codegen uses. *)
  match Parser.parse_module "issue77.tesl" (prelude ^ src) with
  | Err (e : Parser.parse_error) ->
    failf "parse error: %s (at %d:%d)" e.msg (e.loc.start.line + 1) (e.loc.start.col + 1)
  | Ok m ->
    (match List.filter_map (function Ast.DFunc (fd : Ast.func_decl) -> Some fd | _ -> None) m.decls with
     | [ fd ] -> fd.body
     | fds -> failf "expected exactly one fn, got %d" (List.length fds))

(* A query's lowering, reduced to the facts a spelling must not change. *)
type lowered = {
  order   : (string * string) option;
  limit   : int option;
  offset  : int option;
  clauses : int;
}

let lower label src =
  let body = parse_query src in
  (* The body is `with database D { <query> }`; the query is its content. *)
  let query = match body with
    | Ast.EWithDatabase { body = q; _ } -> q
    | other -> other
  in
  match Sql_query.extract_select_query query with
  | None ->
    failf "%s: codegen has no lowering for this query — the #77 fall-through" label
  | Some (seed, clauses) ->
    { order = seed.order; limit = seed.limit; offset = seed.offset;
      clauses = List.length clauses }

let pp_lowered l =
  Printf.sprintf "{order=%s; limit=%s; offset=%s; clauses=%d}"
    (match l.order with None -> "-" | Some (f, d) -> f ^ " " ^ d)
    (match l.limit with None -> "-" | Some n -> string_of_int n)
    (match l.offset with None -> "-" | Some n -> string_of_int n)
    l.clauses

let assert_same_lowering label ~one_line ~multi_line =
  let a = lower (label ^ " (one line)") one_line in
  let b = lower (label ^ " (multi line)") multi_line in
  if a <> b then
    failf "%s: the spelling changed the query\n  one line : %s\n  multi line: %s"
      label (pp_lowered a) (pp_lowered b)

let test_compound_where_then_order () =
  assert_same_lowering "compound where + order"
    ~one_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D { select t from Thing where t.orgId == org && t.archived == False order t.name asc }
|}
    ~multi_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D {
    select t from Thing
      where t.orgId == org && t.archived == False
      order t.name asc
  }
|}

(* The issue's own repro: a functional predicate last, then order + limit. *)
let test_compound_where_ilike_then_order_limit () =
  assert_same_lowering "compound where with ilike + order + limit"
    ~one_line:{|
fn q(org: String, pat: String) -> List Thing requires [dbRead] =
  with database D { select t from Thing where t.orgId == org && t.archived == False && ilike t.name pat order t.name asc limit 5 }
|}
    ~multi_line:{|
fn q(org: String, pat: String) -> List Thing requires [dbRead] =
  with database D {
    select t from Thing
      where t.orgId == org && t.archived == False && ilike t.name pat
      order t.name asc
      limit 5
  }
|}

(* A SINGLE comparison predicate was broken too — the issue reported this shape
   as working, but it only ever "worked" without a trailing clause. *)
let test_single_where_then_order_limit_offset () =
  assert_same_lowering "single where + order + limit + offset"
    ~one_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D { select t from Thing where t.orgId == org order t.name desc limit 2 offset 1 }
|}
    ~multi_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D {
    select t from Thing
      where t.orgId == org
      order t.name desc
      limit 2
      offset 1
  }
|}

let test_or_where_then_order () =
  assert_same_lowering "|| where + order"
    ~one_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D { select t from Thing where t.orgId == org || t.archived == True order t.name asc }
|}
    ~multi_line:{|
fn q(org: String) -> List Thing requires [dbRead] =
  with database D {
    select t from Thing
      where t.orgId == org || t.archived == True
      order t.name asc
  }
|}

(* ── 2. The symptom itself: no free binder / clause keyword in the output ─── *)

let test_emit_has_no_free_binder () =
  let out = emit {|
fn q(org: String, pat: String) -> Int requires [dbRead] =
  with database D {
    let rows = select t from Thing where t.orgId == org && t.archived == False && ilike t.name pat order t.name asc limit 5
    List.length rows
  }
|} in
  (* Before the fix this emitted `(ilike … pat order … asc limit 5)` — the clause
     keywords as ordinary identifiers, and `t` as a free variable. *)
  if contains out " order " then
    failf "`order` was emitted as an ordinary identifier:\n%s" out;
  if contains out " asc " then
    failf "`asc` was emitted as an ordinary identifier:\n%s" out;
  if not (contains out "(order-by") then
    failf "the order clause did not reach the query:\n%s" out;
  if not (contains out "(limit 5)") then
    failf "the limit clause did not reach the query:\n%s" out

(* ── 3. Queries in argument position, both spellings ─────────────────────── *)

let test_query_as_argument_one_line () =
  should_pass "one-line query as a call argument"
    {|
fn q(org: String) -> Int requires [dbRead] =
  with database D {
    List.length (select t from Thing where t.orgId == org && t.archived == False order t.name asc limit 5)
  }
|}

let test_query_as_argument_multi_line () =
  should_pass "multi-line query as a call argument"
    {|
fn q(org: String) -> Int requires [dbRead] =
  with database D {
    List.length (select t from Thing
      where t.orgId == org && t.archived == False
      order t.name asc
      limit 5)
  }
|}

(* ── 4. The class: an unlowerable query fails at CHECK, with the cause ───── *)

(* `limit`/`offset` are lowered from an integer literal only.  Before the gate
   this shape reached codegen, fell through to ordinary application and emitted
   free variables; `tesl check` said nothing. *)
let test_non_literal_limit_rejected_at_check () =
  should_fail "a variable `limit`" ~expect:"lowered from an integer literal"
    {|
fn q(org: String, n: Int) -> List Thing requires [dbRead] =
  with database D { select t from Thing where t.orgId == org order t.name asc limit n }
|}

(* Single-line `update` has never been supported.  It used to check CLEAN and
   fail in the EMITTER (exit 1, no output), which `tesl check` could not see. *)
let test_single_line_update_rejected_at_check () =
  should_fail "single-line update" ~expect:"no lowering for this SQL shape"
    {|
fn q(org: String) -> Unit requires [dbRead, dbWrite] =
  with database D { update t in Thing where t.orgId == org set t.archived = True }
|}

let test_single_line_update_hint_shows_multi_line_form () =
  let _, out = check {|
fn q(org: String) -> Unit requires [dbRead, dbWrite] =
  with database D { update t in Thing where t.orgId == org set t.archived = True }
|} in
  if not (contains out "update p in Entity") then
    failf "the rejection does not show the working multi-line form:\n%s" out

(* `insertMany` takes a NAME, not a list literal — same fall-through class. *)
let test_insert_many_literal_rejected_at_check () =
  should_fail "insertMany on a list literal" ~expect:"the rows must be a NAME"
    {|
fn q() -> Unit requires [dbRead, dbWrite] =
  with database D {
    insertMany [Thing { id: "a", orgId: "o1", name: "alpha", qty: 1, archived: False }] in Thing
  }
|}

(* The gate must not fire on the forms that DO lower — the multi-line update and
   delete chains, and a plain select. *)
let test_gate_accepts_supported_forms () =
  should_pass "multi-line update"
    {|
fn q(org: String) -> Unit requires [dbRead, dbWrite] =
  with database D {
    update t in Thing
      where t.orgId == org
      set t.archived = True
  }
|};
  should_pass "single-line delete with a compound where"
    {|
fn q(org: String) -> Unit requires [dbRead, dbWrite] =
  with database D { delete t from Thing where t.orgId == org && t.archived == False }
|};
  should_pass "insertMany on a bound name"
    {|
fn q() -> Unit requires [dbRead, dbWrite] =
  with database D {
    let rows = [Thing { id: "a", orgId: "o1", name: "alpha", qty: 1, archived: False }]
    insertMany rows in Thing
  }
|}

(* Decide-by-resolution: a user function named `select` stands the rule down —
   the gate must not claim a plain call is a broken query. *)
let test_user_fn_named_select_is_not_a_query () =
  should_pass "user fn named select"
    {|
fn select(n: Int) -> Int =
  n + 1

fn q() -> Int =
  select 41
|}

let () =
  run "issue-77 single-line SQL clause placement" [
    "shape parity (one line == many)", [
      test_case "compound where + order"          `Quick test_compound_where_then_order;
      test_case "compound where + ilike + clauses" `Quick test_compound_where_ilike_then_order_limit;
      test_case "single where + order/limit/offset" `Quick test_single_where_then_order_limit_offset;
      test_case "|| where + order"                 `Quick test_or_where_then_order;
    ];
    "emit", [
      test_case "no free binder or clause keyword" `Quick test_emit_has_no_free_binder;
    ];
    "argument position", [
      test_case "one line"   `Quick test_query_as_argument_one_line;
      test_case "many lines" `Quick test_query_as_argument_multi_line;
    ];
    "unlowerable shapes fail at check", [
      test_case "variable limit"            `Quick test_non_literal_limit_rejected_at_check;
      test_case "single-line update"        `Quick test_single_line_update_rejected_at_check;
      test_case "update hint names the fix" `Quick test_single_line_update_hint_shows_multi_line_form;
      test_case "insertMany list literal"   `Quick test_insert_many_literal_rejected_at_check;
      test_case "supported forms accepted"  `Quick test_gate_accepts_supported_forms;
      test_case "user fn named select"      `Quick test_user_fn_named_select_is_not_a_query;
    ];
  ]
