(** Two SQL-parity rules from the whitebox campaign (2026-09-02).

    1. `==`/`!=` on a `Maybe` column renders as `is [not] distinct from`: the Memory store
       compares a Maybe as a value (`Nothing == Nothing`), SQL's `=` against NULL is never
       true, and a session-revocation filter written `where s.revokedAt == none` therefore
       matched everything in tests and nothing in production.
    2. A query's row binder may not shadow a name in scope: `fn f(r: Row) = select r from Row
       where r.n == r.small` meant "row vs itself" on Memory and "row vs the outer r" on SQL. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       (* Under `dune test` the executable runs from `_build/default/test`, so the compiler
          is `../bin/main.exe`; ci.sh deliberately UNSETS the env variables so the suite
          exercises exactly that path. *)
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
  ((match status with Unix.WEXITED c -> c | _ -> 255), out)

let with_source name src f =
  let dir = Filename.temp_dir "tesl-sqlmaybe" "" in
  let path = Filename.concat dir (name ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let check name src =
  with_source name src (fun path ->
    run_command (Printf.sprintf "%s --check %s 2>&1" (Filename.quote compiler) (Filename.quote path)))

let emitted_module name src =
  with_source name src (fun path ->
    match Compile.compile_go_file path with
    | Compile.GoFailure diagnostics ->
      failf "expected a clean Go emit, got:\n%s"
        (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.GoSuccess artifacts ->
      (match List.find_opt (fun (a : Emit_go.artifact) ->
         Filename.basename a.path = "module.go") artifacts with
       | Some artifact -> artifact.contents
       | None -> failf "no module.go artifact"))

let contains needle haystack =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

let sessions = {|module Sessions exposing [liveSessions]
import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, DatabaseBackend, Postgres, PostgresConfig, TcpConnection]

entity Session table "sessions" primaryKey id {
  id: String
  userId: String
  revokedAt: Maybe String
}

database Db = Database {
  schema: "sessions"
  entities: [Session]
  backend: Postgres (PostgresConfig {
    dbName: "sessions"
    user: "sessions"
    password: "sessions"
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })
}

fn liveSessions(uid: String, none: Maybe String) -> List Session requires [dbRead] =
  select s from Session
    where s.userId == uid && s.revokedAt == none

fn revokedSessions(none: Maybe String) -> List Session requires [dbRead] =
  select s from Session
    where s.revokedAt != none
|}

let test_maybe_equality_is_null_safe () =
  let out = emitted_module "Sessions" sessions in
  if not (contains {|\"revoked_at\" is not distinct from $|} out) then
    failf "Maybe equality must render as `is not distinct from`:\n%s" out;
  if not (contains {|\"revoked_at\" is distinct from $|} out) then
    failf "Maybe inequality must render as `is distinct from`:\n%s" out;
  (* The non-Maybe column keeps the plain operator. *)
  if not (contains {|\"user_id\" = $|} out) then
    failf "a non-Maybe column must keep `=`:\n%s" out

let shadow binder = Printf.sprintf {|module Shadow exposing [same]
import Tesl.Prelude exposing [Bool(..), Int, String, List]
import Tesl.DB exposing [dbRead]

entity Row table "rows" primaryKey id {
  id: String
  n: Int
  small: Int
}

fn same(r: Row) -> List Row requires [dbRead] =
  select %s from Row
    where %s.n == r.small
|} binder binder

let test_binder_shadowing_refused () =
  let code, out = check "Shadow" (shadow "r") in
  if code = 0 then failf "a query binder shadowing a parameter compiled cleanly:\n%s" out;
  if not (contains "query binder `r` shadows a name in scope" out) then
    failf "unexpected diagnostic:\n%s" out

let test_fresh_binder_accepted () =
  let code, out = check "Shadow" (shadow "row") in
  if code <> 0 then failf "a fresh binder must compile (exit %d):\n%s" code out

(* A `secret` column binds through `teslrt.PgSecret`, never `.Reveal()`: the plaintext reaches
   the driver through `driver.Valuer` while every rendering path (the `--debug` SQL preview, a
   trap quoting its arguments) sees the redaction. *)
let vault = {|module Vault exposing [store]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.DB exposing [dbWrite]
import Tesl.Database exposing [Database, DatabaseBackend, Postgres, PostgresConfig, TcpConnection]

secret ApiKey = String

entity Credential table "credentials" primaryKey id {
  id: String
  key: ApiKey
}

database Db = Database {
  schema: "vault"
  entities: [Credential]
  backend: Postgres (PostgresConfig {
    dbName: "vault"
    user: "vault"
    password: "vault"
    connection: TcpConnection {
      host: "localhost"
      port: 5432
    }
  })
}

fn store(id: String, key: ApiKey) -> Credential requires [dbWrite] =
  insert Credential { id: id, key: key }
|}

let test_secret_column_binds_redacting_param () =
  let out = emitted_module "Vault" vault in
  if not (contains "teslrt.PgSecret(" out) then
    failf "a secret column must bind through teslrt.PgSecret:\n%s" out;
  if contains ".Reveal()" out then
    failf "a secret column must not bind its plaintext with .Reveal():\n%s" out

let () =
  run "sql-maybe-equality"
    [
      ( "maybe columns",
        [ test_case "== and != render null-safe" `Quick test_maybe_equality_is_null_safe ] );
      ( "secret columns",
        [ test_case "bind through PgSecret, never Reveal" `Quick test_secret_column_binds_redacting_param ] );
      ( "binder shadowing",
        [ test_case "shadowing a parameter is refused" `Quick test_binder_shadowing_refused;
          test_case "a fresh binder is accepted" `Quick test_fresh_binder_accepted ] );
    ]
