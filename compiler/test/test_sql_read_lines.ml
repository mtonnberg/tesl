(** The Go debugger's SQL lens on a query LINE (not only after it).

    A checkpoint normally pauses BEFORE its statement. On a query line that
    would expose no SQL capture because the driver has not run yet, and there is
    no next statement when the query is the function's LAST statement.

    The Go emitter puts a READ checkpoint after the statement, so the SQL capture
    and result are present. Writes retain their checkpoint before the statement.
    This test pins the generated debug behavior:

      - a read statement's checkpoint follows its query;
      - a WRITE checkpoint precedes its mutation;
      - a module with no query emits no SQL operation;
      - the result binding accompanies the checkpoint, so the after-pause
        can show the statement's result.

    Runtime SQL capture is pinned by the Go runtime tests. *)

open Alcotest

let failf fmt = Printf.ksprintf failwith fmt

let emit src =
  match Compile.compile_go_source ~debug:true "Probe.tesl" src with
  | Compile.GoFailure diagnostics ->
    failf "probe must compile: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    match List.find_opt (fun (a : Emit_go.artifact) -> a.path = "internal/teslmodprobe/module.go") artifacts with
    | Some artifact -> artifact.contents
    | None -> failf "probe emitted no module.go artifact"

let index_of hay needle =
  try Str.search_forward (Str.regexp_string needle) hay 0
  with Not_found -> failf "generated Go missing %S:\n%s" needle hay

let index_of_from hay needle from =
  try Str.search_forward (Str.regexp_string needle) hay from
  with Not_found -> failf "generated Go missing %S after offset %d:\n%s" needle from hay

let db_prelude = {|module Probe exposing [readOne, writeOne]
import Tesl.Prelude exposing [Int, String, List, Bool(..)]
import Tesl.Database exposing [Database, Memory]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.List exposing [List.length]

entity Row table "probe_rows" primaryKey id {
  id: String
  name: String
}

database D = Database {
  schema: "probe"
  entities: [Row]
  backend: Memory
}
|}

let check_order ~line ~query ~checkpoint_first src =
  let out = emit src in
  let checkpoint = index_of out (Printf.sprintf "Line: %d," line) in
  let query = index_of out query in
  if (checkpoint < query) <> checkpoint_first then
    failf "line %d checkpoint has wrong query ordering:\n%s" line out

(* ── Reads pause after execution ──────────────────────────────────────────── *)

let t_read_statement_line_is_listed () =
  (* line 19 = the `let rows = select …` statement *)
  check_order ~line:19 ~query:"teslrt.TableSelect(" ~checkpoint_first:false
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead Row] =
  let rows = select r from Row where r.name == "ada"
  List.length rows

fn writeOne() -> Int requires [dbWrite Row] =
  1
|})

let t_tail_read_is_listed () =
  (* The case that motivated this: the query IS the last statement, so there is
     no next line to step to. *)
  check_order ~line:19 ~query:"teslrt.TableSelect(" ~checkpoint_first:false
    (db_prelude ^ {|
fn readOne() -> List Row requires [dbRead Row] =
  select r from Row where r.name == "ada"

fn writeOne() -> Int requires [dbWrite Row] =
  1
|})

(* ── Writes keep pausing BEFORE ──────────────────────────────────────────── *)

let t_write_line_is_not_listed () =
  check_order ~line:22 ~query:"teslrt.TableInsert(" ~checkpoint_first:true
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead Row] =
  1

fn writeOne() -> Int requires [dbWrite Row] =
  let _ = insert Row { id: "r1", name: "ada" }
  1
|})

let t_read_and_write_in_one_function_lists_only_the_read () =
  (* A function that both writes and reads lists the READ line and not the write:
     pausing after a read is safe whatever else the function does, and a breakpoint
     on a mutation must still stop before the world changes. *)
  let src =
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead Row] =
  1

fn writeOne() -> Int requires [dbRead Row, dbWrite Row] =
  let _ = insert Row { id: "r1", name: "ada" }
  let rows = select r from Row
   List.length rows
|}) in
  check_order ~line:22 ~query:"teslrt.TableInsert(" ~checkpoint_first:true src;
  check_order ~line:23 ~query:"teslrt.TableSelect(" ~checkpoint_first:false src

(* The free-floating `with database D { … }` BLOCK is gone from the language — a database is
   connected by `main`, and a test binds one in its own header — so the two cases that pinned
   "the block is one statement, and its head line carries it" have no subject. What they were
   really about, that a read line is listed and a write line is not, is pinned by the two
   cases above on ordinary statements. *)

(* ── No query → no SQL artifact ──────────────────────────────────────────── *)

let t_no_query_emits_no_table () =
  let out = emit {|module Probe exposing [f]
import Tesl.Prelude exposing [Int]

fn f(n: Int) -> Int =
  let m = n + 1
  m
|} in
  if List.exists (fun operation ->
       try ignore (Str.search_forward (Str.regexp_string operation) out 0); true
       with Not_found -> false)
       [ "teslrt.TableSelect"; "teslrt.TableInsert"; "teslrt.TableUpdate";
         "teslrt.TableDelete"; "teslrt.DbSelect"; "teslrt.DbInsert";
         "teslrt.DbUpdate"; "teslrt.DbDelete" ] then
    failf "query-free module emitted a SQL operation:\n%s" out

(* ── The binding name travels with the checkpoint ────────────────────────── *)

let t_checkpoint_carries_the_binding_name () =
  let out =
    emit (db_prelude ^ {|
fn readOne() -> Int requires [dbRead Row] =
  let rows = select r from Row where r.name == "ada"
  List.length rows

fn writeOne() -> Int requires [dbWrite Row] =
  1
|})
  in
  let checkpoint = index_of out "Line: 19," in
  let binding = index_of_from out "Name: \"rows\"" checkpoint in
  let next_checkpoint =
    try Str.search_forward (Str.regexp_string "teslrt.Checkpoint(") out (checkpoint + 1)
    with Not_found -> String.length out
  in
  if binding >= next_checkpoint then
    failf
      "the statement checkpoint must carry its binding name (`rows`) so the \
       after-the-statement pause can show the query's result:\n%s" out

let () =
  run "SQL-Read-Lines" [
    "reads", [
      test_case "a read checkpoint follows the statement" `Quick
        t_read_statement_line_is_listed;
      test_case "a tail read checkpoint follows the statement" `Quick
        t_tail_read_is_listed;
    ];
    "writes", [
      test_case "a write checkpoint precedes the statement" `Quick t_write_line_is_not_listed;
      test_case "mixed function preserves read/write ordering" `Quick
        t_read_and_write_in_one_function_lists_only_the_read;
    ];
    "shape", [
      test_case "a module with no query emits no SQL artifact" `Quick
        t_no_query_emits_no_table;
      test_case "the checkpoint carries the binding name" `Quick
        t_checkpoint_carries_the_binding_name;
    ];
  ]
