open Alcotest
module S = Migration_sparse
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = match (Unix.lstat p).Unix.st_kind with
 | Unix.S_DIR -> Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p
 | _ -> Sys.remove p
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let accepts file =
 let result=Compile.agent_context_result_source file (Source_input.read file) in
 match List.filter (fun (d:Compile.diagnostic) -> d.severity="error") result.diagnostics with
 | [] -> () | errors -> fail (describe errors)
let schema version =
 let fields=if version>=3 then ", token: Maybe String" else "" in
 let values=if version>=3 then ", token: Something id" else "" in
 let indexes=(if version>=2 then "\n index [active] as \"active_lookup\"" else "") ^ (if version>=3 then "\n index [token] as \"token_lookup\"" else "") in
 Printf.sprintf {|module Schema.Notes.VCurrent exposing [Note, makeNote]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { id: String, title: String, active: Bool%s%s
}
fn makeNote(id: String) -> Note = Note { id: id, title: "hello", active: False%s }
|} fields indexes values
let app = {|module App exposing []
import Tesl.Prelude exposing [String, List, Bool(..)]
import Tesl.App exposing [App]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, MigrationTopology(..)]
import Schema.Notes.VCurrent exposing [Note, makeNote]
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  poolSize: 1
  dbName: env "ROW_DATABASE"
  user: env "ROW_LOGIN"
  password: ""
  migrations: MigrationConfig {
   topology: Worker
   controlOwner: env "ROW_OWNER"
   requestRole: env "ROW_REQUEST"
   workerRole: env "ROW_WORKER"
   ddlConnection: env "ROW_DDL"
  }
  connection: TcpConnection { host: env "ROW_HOST", port: envInt "ROW_DB_PORT" 5432 }
 })
}
api NotesApi {
 get "/health" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 put "/edit" -> String
}
handler get health() -> String = "ready"
handler get all() -> List Note requires [dbRead Note] = select note from Note order note.id asc
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "created"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "created"
handler put edit() -> String requires [dbWrite Note] =
 update note in Note
  set note.active = True
 "edited"
server NotesServer for NotesApi { health, all, addOne, addTwo, edit }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}
let additive version target = Printf.sprintf {|module Schema.Notes.Migrate.V%d exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Notes.V%d
import %s
migration = Migration {
 from: Schema.Notes.V%d
 to: %s
 same: []
 fixtures: []
 entities: { Note: Additive [] }
}
|} version (version-1) target (version-1) target
let seal root file =
 let abi=Result.get_ok (Migration_abi.current ()) in
 let inventory=match Migration_inventory.load_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
  | Ok x -> x | Error e -> fail e.message in
 match Migration_seal.create ~project_root:root inventory with Ok x -> x | Error e -> fail e.message
let get = function Ok x -> x | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors))
let edge root path previous current source historical =
 let header=get (Migration_header.create ~previous:(seal root previous) ~current:(seal root current)) in
 let source=Migration_header.encode header ^ source in
 let source=if historical then
  let closure=get (Migration_closure.capture ~project_root:root ~root_file:path ~source) in
  get (Migration_closure.attach ~file:path ~source closure)
 else source in
 write path source; accepts path
let export output =
 let root=Filename.temp_dir "tesl-row-index-source-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
 let file p=Filename.concat root p in
 write (file "tesl.toml") ""; write (file "app.tesl") app;
 let current=file "schema/notes/v-current.tesl" in
 let build version =
  accepts (file "app.tesl");
   let artifacts=match Compile.compile_go_file (file "app.tesl") with
   | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  let destination=Filename.concat output version in
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then write (Filename.concat destination a.path) a.contents) artifacts;
  if version="v2" then (
   let repo=Sys.getenv "TESL_REPO_ROOT" in
   List.iter (fun (source,target) -> write (Filename.concat destination target) (Source_input.read (Filename.concat repo ("compiler/test/fixtures/row-index/"^source))))
    ["bridge.go","internal/teslrt/index_probe_testbuild.go";"probe.go","cmd/index-probe/main.go"]);
  check bool "ordinary main emitted" true (Sys.file_exists (Filename.concat destination "cmd/app/main.go"));
  let command=Printf.sprintf "cd %s && timeout 120s go build -race -tags tesl_migration_test -o app ./cmd/app >build.log 2>&1" (Filename.quote destination) in
  if Sys.command command<>0 then fail (Source_input.read (Filename.concat destination "build.log"));
  if version="v2" then (
   let command=Printf.sprintf "cd %s && timeout 120s go build -race -tags tesl_migration_test -o index-probe ./cmd/index-probe >probe-build.log 2>&1" (Filename.quote destination) in
   if Sys.command command<>0 then fail (Source_input.read (Filename.concat destination "probe-build.log"))) in
 write current (schema 1); build "v1";
 let v1=file "schema/notes/v1.tesl" in
 write v1 (schema 1 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V1");
 write current (schema 2);
 edge root (file "migrations/notes/v2.tesl") v1 current (additive 2 "Schema.Notes.VCurrent") false;
 build "v2";
 let v2=file "schema/notes/v2.tesl" in
 write v2 (schema 2 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V2");
 edge root (file "migrations/notes/v2.tesl") v1 v2 (additive 2 "Schema.Notes.V2") true;
 write current (schema 3);
 edge root (file "migrations/notes/v3.tesl") v2 current (additive 3 "Schema.Notes.VCurrent") false;
 build "v3")
let compilation () =
 let output=Filename.temp_dir "tesl-row-index-programs-" "" in
 Fun.protect ~finally:(fun () -> remove output) (fun () ->
  export output;
  let repo=Unix.realpath (Sys.getenv "TESL_REPO_ROOT") in
  let log=Filename.concat output "postgres.log" in
  let command=Printf.sprintf "cd %s && TESL_ROW_INDEX_PROGRAMS=%s timeout 150s go test -p 1 -race -tags tesl_migration_test -timeout 120s ./teslrt -run '^TestPgRowIndex' -count=1 -v > %s 2>&1"
   (Filename.quote (Filename.concat repo "runtime/go")) (Filename.quote output) (Filename.quote log) in
  if Sys.command command<>0 then fail (Source_input.read log))
let () = match Sys.getenv_opt "TESL_ROW_INDEX_EXPORT" with
 | Some output -> export output
 | None -> run "format5 concurrent indexes" ["native application",[
   test_case "original index workers, readiness and atomic registration" `Quick compilation]]
