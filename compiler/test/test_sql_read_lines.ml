(** The debugger's SQL lens on a query LINE (not only after it).

    A checkpoint pauses BEFORE its statement, so a breakpoint on a query line
    stopped with nothing captured yet: `dsl/sql.rkt` records the statement only
    as it executes, so the "exact statement the driver runs" scope was not
    advertised at all — and the workaround ("step to the next line") does not
    exist when the query is the function's LAST statement.

    The compiler now emits, per module, the 1-based lines whose statement is a
    READ-ONLY query; the runtime swaps those pauses to AFTER the statement
    (dsl/debug/checkpoint.rkt `sql-read-line?`), so the capture is present and
    the paused frame also shows the query's own result.  This test pins the
    EMITTED table:

      - a read statement's line is listed;
      - a WRITE line is never listed (a breakpoint on a mutation must still stop
        before the world changes);
      - a `with database D { … }` / `with transaction { … }` block is ONE
        statement, so the only line you can break on is its head — the head is
        attributed to the block's contents (read-only → listed, any write → not);
      - a module with no query emits no table at all (no cost, no noise);
      - the emitted binding name accompanies the checkpoint, so the after-pause
        can show the statement's result.

    The runtime half (pause ordering, and labelling a capture as this line's
    statement vs the previous one) is pinned by tests/sql-read-lines-tests.rkt. *)

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

let emit src =
  let dir = Filename.temp_dir "tesl-sqlline" "" in
  let path = Filename.concat dir "probe.tesl" in
  let oc = open_out path in output_string oc src; close_out oc;
  let quoted = [ Filename.quote compiler; Filename.quote path ] in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (try Sys.remove path with _ -> ());
  (try Unix.rmdir dir with _ -> ());
  if code <> 0 then failf "probe must compile; got (exit %d):\n%s" code out;
  out

(** The line list from the emitted [register-sql-read-lines!] form, or [] when
    the module emitted no table. *)
let read_lines src =
  let out = emit src in
  let re = Str.regexp "register-sql-read-lines! \"[^\"]*\" '(\\([0-9 ]*\\))" in
  match Str.search_forward re out 0 with
  | _ ->
    Str.matched_group 1 out
    |> String.split_on_char ' '
    |> List.filter_map (fun s -> int_of_string_opt (String.trim s))
    |> List.sort compare
  | exception Not_found -> []

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

let check_lines ~expected src =
  let got = read_lines src in
  if got <> expected then
    failf "expected read-line table %s, got %s"
      (String.concat "," (List.map string_of_int expected))
      (String.concat "," (List.map string_of_int got))

(* ── A read statement's line is listed ───────────────────────────────────── *)

let t_read_statement_line_is_listed () =
  (* line 19 = the `let rows = select …` statement *)
  check_lines ~expected:[ 19 ]
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead] =
  let rows = select r from Row where r.name == "ada"
  List.length rows

fn writeOne() -> Int requires [dbWrite] =
  1
|})

let t_tail_read_is_listed () =
  (* The case that motivated this: the query IS the last statement, so there is
     no next line to step to. *)
  check_lines ~expected:[ 19 ]
    (db_prelude ^ {|
fn readOne() -> List Row requires [dbRead] =
  select r from Row where r.name == "ada"

fn writeOne() -> Int requires [dbWrite] =
  1
|})

(* ── Writes keep pausing BEFORE ──────────────────────────────────────────── *)

let t_write_line_is_not_listed () =
  check_lines ~expected:[]
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead] =
  1

fn writeOne() -> Int requires [dbWrite] =
  let _ = insert Row { id: "r1", name: "ada" }
  1
|})

let t_read_and_write_in_one_function_lists_only_the_read () =
  (* A function that both writes and reads lists the READ line and not the write:
     pausing after a read is safe whatever else the function does, and a breakpoint
     on a mutation must still stop before the world changes. *)
  check_lines ~expected:[ 23 ]
    (db_prelude ^ {|
fn readOne() -> Int requires [dbRead] =
  1

fn writeOne() -> Int requires [dbRead, dbWrite] =
  let _ = insert Row { id: "r1", name: "ada" }
  let rows = select r from Row
  List.length rows
|})

(* The free-floating `with database D { … }` BLOCK is gone from the language — a database is
   connected by `main`, and a test binds one in its own header — so the two cases that pinned
   "the block is one statement, and its head line carries it" have no subject. What they were
   really about, that a read line is listed and a write line is not, is pinned by the two
   cases above on ordinary statements. *)

(* ── No query → no table ─────────────────────────────────────────────────── *)

let t_no_query_emits_no_table () =
  check_lines ~expected:[]
    {|module Probe exposing [f]
import Tesl.Prelude exposing [Int]

fn f(n: Int) -> Int =
  let m = n + 1
  m
|}

(* ── The binding name travels with the checkpoint ────────────────────────── *)

let t_checkpoint_carries_the_binding_name () =
  let out =
    emit (db_prelude ^ {|
fn readOne() -> Int requires [dbRead] =
  let rows = select r from Row where r.name == "ada"
  List.length rows

fn writeOne() -> Int requires [dbWrite] =
  1
|})
  in
  let contains hay needle =
    let n = String.length needle and h = String.length hay in
    let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
    n = 0 || go 0
  in
  if not (contains out "'rows)") then
    failf
      "the statement checkpoint must carry its binding name (`'rows`) so the \
       after-the-statement pause can show the query's result:\n%s" out

let () =
  run "SQL-Read-Lines" [
    "reads", [
      test_case "a read statement's line is listed" `Quick
        t_read_statement_line_is_listed;
      test_case "a tail read (the last statement) is listed" `Quick
        t_tail_read_is_listed;
    ];
    "writes", [
      test_case "a write line is not listed" `Quick t_write_line_is_not_listed;
      test_case "a function that both reads and writes lists only the read" `Quick
        t_read_and_write_in_one_function_lists_only_the_read;
    ];
    "shape", [
      test_case "a module with no query emits no table" `Quick
        t_no_query_emits_no_table;
      test_case "the checkpoint carries the binding name" `Quick
        t_checkpoint_carries_the_binding_name;
    ];
  ]
