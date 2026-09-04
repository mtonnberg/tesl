(** `inList` / `notInList` need a list LITERAL (language review 2026-09-02, H1).

    Until then a non-literal operand — a parameter, a `let`, a call — was read by
    `Sql_query` as an EMPTY member list, and both renderers turned an empty list into a
    constant predicate: `where false` for `inList`, `where true` for `notInList`.  So

      select t from T where notInList t.ownerId blocked

    compiled cleanly and returned EVERY row, blocked ones included, on the Memory store and
    on Postgres alike — an access-control filter silently inverted, invisible to any test
    because the two backends agreed.

    Two layers now refuse it and this file pins both: the checker names the operand
    ({!Validation_advanced.check_sql_list_membership_operands}), and should that rule ever be
    bypassed, `Sql_query` no longer recognises the shape (fail closed) so the emitter cannot
    render a constant. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c
    | _ -> 255 in
  (code, out)

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-inlist" "" in
  let path = Filename.concat dir "Inlist.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let check src =
  with_temp_file src (fun path ->
    run_command (Printf.sprintf "%s --check %s 2>&1" (Filename.quote compiler) (Filename.quote path)))

let should_fail pat src =
  let code, out = check src in
  if code = 0 then failf "expected a static failure matching %S, but compiled cleanly:\n%s" pat out;
  let re = Str.regexp_case_fold pat in
  (try ignore (Str.search_forward re out 0)
   with Not_found -> failf "expected a failure matching %S, got:\n%s" pat out)

let should_pass src =
  let code, out = check src in
  if code <> 0 then failf "expected a clean compile, got (exit %d):\n%s" code out

let fixture body = Printf.sprintf {|module Inlist exposing []

import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.DB exposing [dbRead]
import Tesl.List exposing [List.length]

entity Post table "posts" primaryKey id {
  id: String
  author: String
}

%s
|} body

(* ── The literal form is the supported one ─────────────────────────────── *)

let test_literal_list_compiles () =
  should_pass (fixture {|
fn visible() -> Int requires [dbRead] =
  let rows = select p from Post
    where notInList p.author ["mallory"]
  List.length rows

fn staff() -> Int requires [dbRead] =
  let rows = select p from Post
    where inList p.author ["alice", "bob"]
  List.length rows
|})

(* ── Every non-literal operand is named and refused ─────────────────────── *)

let test_variable_operand_refused () =
  should_fail "`notInList` needs a list literal.*variable"
    (fixture {|
fn visible(blocked: List String) -> Int requires [dbRead] =
  let rows = select p from Post
    where notInList p.author blocked
  List.length rows
|})

let test_in_list_variable_operand_refused () =
  should_fail "`inList` needs a list literal.*variable"
    (fixture {|
fn staff(allowed: List String) -> Int requires [dbRead] =
  let rows = select p from Post
    where inList p.author allowed
  List.length rows
|})

let test_let_bound_operand_refused () =
  should_fail "`notInList` needs a list literal"
    (fixture {|
fn visible() -> Int requires [dbRead] =
  let blocked = ["mallory"]
  let rows = select p from Post
    where notInList p.author blocked
  List.length rows
|})

let test_call_operand_refused () =
  should_fail "`inList` needs a list literal.*call"
    (fixture {|
fn allowed() -> List String = ["alice"]

fn staff() -> Int requires [dbRead] =
  let rows = select p from Post
    where inList p.author (allowed ())
  List.length rows
|})

(* The hint tells the author what the old behaviour would have been, because that is the
   part that makes this an error rather than a limitation. *)
let test_hint_names_the_constant () =
  should_fail "would have compiled to a constant `where true` and returned every row"
    (fixture {|
fn visible(blocked: List String) -> Int requires [dbRead] =
  let rows = select p from Post
    where notInList p.author blocked
  List.length rows
|})

(* Fail-closed backstop: the parser itself no longer recognises the shape. *)
let test_sql_query_fails_closed () =
  let open Ast in
  let loc = Location.dummy_loc "x" in
  let var name = EVar { name; loc } in
  let app fn arg = EApp { fn; arg; loc } in
  (* select p from Post where notInList p.author blocked *)
  let field = EField { obj = var "p"; field = "author"; loc } in
  let query =
    app (app (app (app (app (app (app (var "select") (var "p")) (var "from")) (var "Post"))
      (var "where")) (var "notInList")) field) (var "blocked") in
  (match Sql_query.extract_select_query query with
   | Some _ -> fail "a non-literal `notInList` operand was recognised as a query"
   | None -> ());
  let literal =
    app (app (app (app (app (app (app (var "select") (var "p")) (var "from")) (var "Post"))
      (var "where")) (var "notInList")) field)
      (EList { elems = [ELit { lit = LString "mallory"; loc }]; loc }) in
  (match Sql_query.extract_select_query literal with
   | Some _ -> ()
   | None -> fail "the literal `notInList` form must still be recognised")

let () =
  run "sql-list-membership"
    [
      ( "literal form",
        [ test_case "compiles" `Quick test_literal_list_compiles;
          test_case "Sql_query recognises literal, refuses variable" `Quick
            test_sql_query_fails_closed ] );
      ( "non-literal operands refused",
        [ test_case "notInList variable" `Quick test_variable_operand_refused;
          test_case "inList variable" `Quick test_in_list_variable_operand_refused;
          test_case "let-bound list" `Quick test_let_bound_operand_refused;
          test_case "call result" `Quick test_call_operand_refused;
          test_case "hint names the old constant predicate" `Quick test_hint_names_the_constant ] );
    ]
