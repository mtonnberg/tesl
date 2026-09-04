(** End-to-end regression matrix for resource-scoped capabilities. *)

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

let compile src =
  let dir = Filename.temp_dir "tesl-scoped-caps" "" in
  let path = Filename.concat dir "scoped-caps.tesl" in
  Out_channel.with_open_text path (fun oc -> output_string oc src);
  Fun.protect
    ~finally:(fun () -> Sys.remove path; Unix.rmdir dir)
    (fun () ->
      let cmd = Printf.sprintf "%s --check %s 2>&1"
          (Filename.quote compiler) (Filename.quote path) in
      let ic = Unix.open_process_in cmd in
      let out = In_channel.input_all ic in
      let status = Unix.close_process_in ic in
      (status, out))

let should_pass src =
  match compile src with
  | Unix.WEXITED 0, _ -> ()
  | _, out -> failf "expected compile success:\n%s" out

let should_fail needle src =
  match compile src with
  | Unix.WEXITED 0, _ -> fail "expected compile failure"
  | _, out ->
    check bool ("diagnostic contains " ^ needle) true
      (try ignore (Str.search_forward (Str.regexp_string needle) out 0); true
       with Not_found -> false)

let db_source requires = Printf.sprintf {|
module ScopedCaps exposing [Note, readNote]
import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead, dbWrite]
entity Note table "notes" primaryKey id { id: String @db(text) }
fn readNote() -> List Note requires [%s] =
  select note from Note
|} requires

let test_scoped_db_capability_compiles () =
  should_pass (db_source "dbRead Note")

let test_wrong_db_scope_rejected () =
  should_fail "dbRead Note" (db_source "dbRead Other")

let test_bare_db_capability_rejected () =
  should_fail "removed bare capability 'dbRead'" (db_source "dbRead")

let test_scoped_write_implies_same_resource_read () =
  should_pass (Printf.sprintf "%s\ncapability noteWrite implies dbWrite Note\n"
    (db_source "noteWrite"))

let test_scoped_write_does_not_imply_other_resource_read () =
  should_fail "dbRead Note" (Printf.sprintf "%s\ncapability otherWrite implies dbWrite Other\n"
    (db_source "otherWrite"))

let app_source database_entity = Printf.sprintf {|
module ScopedCaps exposing [main]
import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
import Tesl.App exposing [App]
entity Note table "notes" primaryKey id { id: String @db(text) }
entity Other table "others" primaryKey id { id: String @db(text) }
database D = Database { entities: [%s] backend: Memory }
handler get listNotes() -> List Note requires [dbRead Note] = select note from Note
api A { get "/notes" -> List Note }
server S for A { listNotes }
main() -> App requires [dbRead Note] = App { database: D api: S port: 8080 }
|} database_entity

let test_main_database_scope_matches () =
  should_pass (app_source "Note")

let test_main_database_scope_mismatch_rejected () =
  should_fail "not in the database selected by `App.database`" (app_source "Other")

let queue_source requires = Printf.sprintf {|
module ScopedCaps exposing [Ping, push]
import Tesl.Prelude exposing [String, Unit]
import Tesl.Queue exposing [queueWrite, Queue, Job, FromQueue]
import Tesl.Database exposing [Database, DatabaseBackend, Memory]
record Ping { value: String }
worker consume(job: Ping ::: FromQueue (Id == jobId) job) requires [] = job
database D = Database { entities: [] backend: Memory }
queue PingQueue requires [queueWrite PingQueue] = Queue {
  database: D
  jobs: [Job Ping consume Nothing]
}
fn push(ping: Ping) -> Unit requires [%s] = enqueue Ping ping
|} requires

let test_enqueue_uses_queue_name () =
  should_pass (queue_source "queueWrite PingQueue")

let test_enqueue_rejects_job_type_scope () =
  should_fail "queueWrite PingQueue" (queue_source "queueWrite Ping")

let test_capability_algebra () =
  let covers = Validation_capabilities.capability_covers in
  check bool "bare DB grant does not cover scope" false (covers "dbRead" "dbRead Note");
  check bool "write covers same resource read" true (covers "dbWrite Note" "dbRead Note");
  check bool "write cannot cross resource" false (covers "dbWrite User" "dbRead Note");
  check bool "queue write covers queue read" true
    (covers "queueWrite Jobs" "queueRead Jobs");
  check bool "pubsub cannot cross channel" false
    (covers "pubsub Private" "pubsub Public");
  check bool "scoped builtin is not a row variable" true
    (Ast.is_concrete_builtin_capability "dbRead Note")

let test_repository_has_no_bare_db_grants () =
  let root = Compile.default_root_path () in
  let failures = ref [] in
  let check_token path line token =
    let rec search from =
      match String.index_from_opt line from token.[0] with
      | None -> ()
      | Some i ->
        let len = String.length token in
        if i + len <= String.length line && String.sub line i len = token then begin
          let rec next_non_space j =
            if j < String.length line && (line.[j] = ' ' || line.[j] = '\t')
            then next_non_space (j + 1) else j in
          let j = next_non_space (i + len) in
          let scoped = j < String.length line && line.[j] >= 'A' && line.[j] <= 'Z' in
          let db_import_line =
            let trimmed = String.trim line in
            let prefix = "import Tesl.DB exposing" in
            String.length trimmed >= String.length prefix
            && String.sub trimmed 0 (String.length prefix) = prefix in
          if not scoped && not db_import_line then failures := (path ^ ": " ^ line) :: !failures;
          search (i + len)
        end else search (i + 1)
    in
    search 0
  in
  let cmd = Printf.sprintf "git -C %s ls-files '*.tesl'" (Filename.quote root) in
  let ic = Unix.open_process_in cmd in
  let tracked = In_channel.input_lines ic in
  (match Unix.close_process_in ic with
   | Unix.WEXITED 0 -> ()
   | _ -> fail "git ls-files failed while checking bare DB capabilities");
  List.iter (fun relative ->
    let path = Filename.concat root relative in
    In_channel.with_open_text path (fun source ->
      In_channel.input_lines source |> List.iter (fun line ->
        check_token path line "dbRead";
        check_token path line "dbWrite"))
  ) tracked;
  match List.rev !failures with
  | [] -> ()
  | xs -> fail ("bare DB capability in repository .tesl source:\n" ^ String.concat "\n" xs)

let () =
  run "entity-scoped capabilities" [
    "database", [
      test_case "scoped requirement compiles" `Quick test_scoped_db_capability_compiles;
      test_case "wrong scope rejected" `Quick test_wrong_db_scope_rejected;
      test_case "bare DB capability rejected" `Quick test_bare_db_capability_rejected;
      test_case "scoped write implies read" `Quick test_scoped_write_implies_same_resource_read;
      test_case "scope implication cannot cross entity" `Quick test_scoped_write_does_not_imply_other_resource_read;
      test_case "main database scope matches" `Quick test_main_database_scope_matches;
      test_case "main database mismatch rejected" `Quick test_main_database_scope_mismatch_rejected;
    ];
    "queue", [
      test_case "enqueue resolves queue name" `Quick test_enqueue_uses_queue_name;
      test_case "job type is not queue scope" `Quick test_enqueue_rejects_job_type_scope;
    ];
    "algebra", [test_case "coverage matrix" `Quick test_capability_algebra];
    "repository", [test_case "no bare DB grants" `Quick test_repository_has_no_bare_db_grants];
  ]
