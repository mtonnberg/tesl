(** Issue #114: runtime list membership stays typed and parameterized, including
    the empty-list and NULL semantics of the existing literal form. *)

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


let test_literal_list_compiles () =
  should_pass (fixture {|
fn staff() -> List Post requires [dbRead Post] =
  select p from Post where inList p.author ["alice", "bob"]
fn visible() -> List Post requires [dbRead Post] =
  select p from Post where notInList p.author []
|})

let test_runtime_list_compiles () =
  should_pass (fixture {|
record Page { authors: List String }
fn allowed() -> List String = ["alice"]
fn staff(authors: List String) -> List Post requires [dbRead Post] =
  select p from Post where inList p.author authors
fn visible(blocked: List String) -> List Post requires [dbRead Post] =
  select p from Post
    where notInList p.author blocked
fn local() -> List Post requires [dbRead Post] =
  let names = ["alice", "bob"]
  select p from Post where inList p.author names
fn computed() -> List Post requires [dbRead Post] =
  select p from Post where inList p.author (allowed ())
fn field(page: Page) -> List Post requires [dbRead Post] =
  select p from Post where inList p.author page.authors
|})

let test_wrong_list_type () =
  List.iter (fun (annotation, value) ->
    should_fail "cannot unify" (fixture (Printf.sprintf {|
fn staff(names: %s) -> List Post requires [dbRead Post] =
  select p from Post where inList p.author %s
|} annotation value)))
    ["List Int", "names"; "String", "names"; "List String", "[names]"]

let test_nominal_element_type () =
  should_fail "cannot unify" (fixture {|
type AuthorId = String
fn staff(names: List AuthorId) -> List Post requires [dbRead Post] =
  select p from Post where inList p.author names
|})

let test_sql_query_preserves_runtime_operand () =
  let open Ast in
  let loc = Location.dummy_loc "x" in
  let var name = EVar { name; loc } in
  let app fn arg = EApp { fn; arg; loc } in
  let field = EField { obj = var "p"; field = "author"; loc } in
  let query = List.fold_left app (var "select")
      [var "p"; var "from"; var "Post"; var "where"; var "notInList"; field; var "blocked"] in
  match Sql_query.extract_select_query query with
  | Some (seed, clauses) ->
    (match seed.static_clauses @ clauses with
     | [SqlNotInList { field = "author"; values = EVar { name = "blocked"; _ } }] -> ()
     | _ -> fail "runtime operand was lost or interpreted as an empty literal")
  | None -> fail "runtime membership was not recognized"

let runtime_source header = Printf.sprintf {|module InlistRuntime exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.List exposing [List.length, List.map]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

type OwnerId = String
entity Item table "items" primaryKey id {
  id: String
  score: Int
  owner: Maybe String
  ownerId: OwnerId
}
database Db = Database {
  schema: "issue114"
  entities: [Item]
  backend: Postgres (PostgresConfig {
    dbName: env "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE"
    user: env "TESL_TEST_POSTGRES_SHARED_USER"
    password: env "PGPASSWORD"
    connection: TcpConnection {
      host: env "TESL_TEST_POSTGRES_SHARED_HOST"
      port: envInt "TESL_TEST_POSTGRES_SHARED_PORT" 5432
    }
  })
}
fn selected(ids: List String) -> List Item requires [dbRead Item] =
  select i from Item where inList i.id ids
fn excluded(ids: List String) -> List Item requires [dbRead Item] =
  select i from Item where notInList i.id ids
fn owners(names: List (Maybe String)) -> Int requires [dbRead Item] =
  selectCount i from Item where inList i.owner names
fn otherOwners(names: List (Maybe String)) -> Int requires [dbRead Item] =
  selectCount i from Item where notInList i.owner names
fn scores(values: List Int) -> Int requires [dbRead Item] =
  selectSum i.score from Item where inList i.score values
fn ownerIds(ids: List OwnerId) -> Int requires [dbRead Item] =
  selectCount i from Item where inList i.ownerId ids
fn mixed(ids: List String, floor: Int) -> List Item requires [dbRead Item] =
  select i from Item
    where i.score > floor && inList i.id ids
    order i.id asc
    limit 1
fn single(ids: List String) -> Maybe Item requires [dbRead Item] =
  selectOne i from Item where inList i.id ids
fn makeIds() -> List String = ["a", "b"]

%s requires [dbRead Item, dbWrite Item] {
  delete i from Item
  let _ = insert Item { id: "a", score: 1, owner: Nothing, ownerId: OwnerId "x" }
  let _ = insert Item { id: "b", score: 2, owner: Something "bob", ownerId: OwnerId "y" }
  let _ = insert Item { id: "c", score: 9223372036854775808, owner: Something "cara", ownerId: OwnerId "x" }
  let ids = makeIds ()
  expect List.length (selected ids) == 2
  expect List.length (selected ["a", "a", "missing"]) == 1
  expect List.length (excluded ids) == 1
  expect List.length (selected []) == 0
  expect List.length (excluded []) == 3
  expect List.length (selected ["a') OR true --"]) == 0
  let rows = selected ids
  let mapped = List.map (fn (r: Item) -> r.id) rows
  expect List.length (selected mapped) == 2
  expect owners [Nothing] == 1
  expect owners [Nothing, Something "bob"] == 2
  expect otherOwners [Nothing, Something "bob"] == 1
  expect owners [] == 0
  expect otherOwners [] == 3
  expect scores [9223372036854775808] == 9223372036854775808
  expect ownerIds [OwnerId "x"] == 2
  expect List.length (mixed ids 0) == 1
  expect single [] == Nothing
  expect single ["a"] != Nothing

}
|} header

let emitted source =
  match Compile.compile_go_source "<inlist-runtime>" source with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics ->
    failf "Go compilation failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))

let run_generated header =
  let artifacts = emitted (runtime_source header) in
  let root = Filename.temp_dir "tesl-inlist-runtime" "" in
  let rec mkdir path =
    if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o755) in
  let rec remove path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    List.iter (fun (a : Emit_go.artifact) ->
      let path = Filename.concat root a.path in
      mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun oc -> output_string oc a.contents)) artifacts;
    let code, formatting = run_command (Printf.sprintf "cd %s && gofmt -l internal 2>&1"
        (Filename.quote root)) in
    if code <> 0 || String.trim formatting <> "" then
      failf "generated Go is not gofmt-stable:\n%s" formatting;
    let code, out = run_command (Printf.sprintf "cd %s && go test -count=1 ./... 2>&1"
        (Filename.quote root)) in
    if code <> 0 then failf "generated runtime tests failed (%d):\n%s" code out)

let test_memory_runtime () = run_generated {|test "runtime list membership on Memory"|}

let test_postgres_runtime () =
  if List.for_all (fun name -> Sys.getenv_opt name <> None)
       ["TESL_TEST_POSTGRES_SHARED_HOST"; "TESL_TEST_POSTGRES_SHARED_PORT";
        "TESL_TEST_POSTGRES_SHARED_USER"; "TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE"] then
    run_generated {|test "runtime list membership on PostgreSQL" with database Db|}
  else Printf.printf "SKIP: no shared PostgreSQL cluster configured\n%!"

let () =
  run "sql-list-membership"
    [ "typing", [
        test_case "literal lists" `Quick test_literal_list_compiles;
        test_case "variables, calls and record fields" `Quick test_runtime_list_compiles;
        test_case "wrong list or element type" `Quick test_wrong_list_type;
        test_case "nominal element types" `Quick test_nominal_element_type;
        test_case "Sql_query preserves runtime operands" `Quick test_sql_query_preserves_runtime_operand ];
      "runtime", [
        test_case "Memory membership, empty lists and NULLs" `Slow test_memory_runtime;
        test_case "PostgreSQL membership, empty lists and NULLs" `Slow test_postgres_runtime ] ]
