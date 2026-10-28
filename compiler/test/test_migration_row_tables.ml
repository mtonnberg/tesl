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
 let fields,values = match version with
 | 1 -> "author: String, title: String", "author: \"writer\", title: \"hello\""
 | 2 -> "author: String, title: String, priority: Int, memo: Maybe String", "author: \"writer\", title: \"hello\", priority: 9, memo: Nothing"
 | _ -> "owner: String, title: String, priority: Int, memo: Maybe String, count: Int", "owner: \"writer\", title: \"hello\", priority: 9, memo: Nothing, count: 7" in
 Printf.sprintf {|module Schema.Notes.VCurrent exposing [Note, makeNote]
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { id: String, %s }
fn makeNote(id: String) -> Note = Note { id: id, %s }
|} fields values
let app = {|module App exposing []
import Tesl.Prelude exposing [String, List]
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
server NotesServer for NotesApi { health, all, addOne, addTwo }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}
let additive target = Printf.sprintf {|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Notes.V1
import %s
migration = Migration {
 from: Schema.Notes.V1
 to: %s
 same: []
 fixtures: []
 entities: { Note: Additive [Default priority 9] }
}
|} target target
let transforming = {|module Schema.Notes.Migrate.V3 exposing [migration, oldNote]
import Tesl.Prelude exposing [String, Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V2
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V2
 to: Schema.Notes.VCurrent
 same: []
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Notes.V2.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, priority: old.priority, memo: old.memo, count: 7 })
fn oldNote() -> Schema.Notes.V2.Note =
 Schema.Notes.V2.Note { id: "seed", author: "writer", title: "hello", priority: 9, memo: Nothing }
|}
(* New tables retain ordinary nominal entity code before their first window. *)
let note_schema = schema
let schema version =
 let source=note_schema version in
 if version=1 then source else
 let fields,values=if version=2 then "", "" else ", count: Int", ", count: 11" in
 (source |> replace "exposing [Note, makeNote]" "exposing [Note, makeNote, Added, makeAdded]") ^
 Printf.sprintf {|entity Added table "added" primaryKey id { id: String, code: String%s
 index [code] as "added_code_lookup"
}
fn makeAdded(id: String) -> Added = Added { id: id, code: "new-table"%s }
|} fields values
let note_app = app
let app version = if version=1 then note_app else note_app
 |> replace "exposing [Note, makeNote]" "exposing [Note, makeNote, Added, makeAdded]"
let app version = if version=1 then app version else app version
 |> replace " get \"/all\" -> List Note" " get \"/all\" -> List Note\n get \"/added\" -> List Added\n post \"/added\" -> String"
 |> replace "server NotesServer for NotesApi { health, all, addOne, addTwo }" {|handler get added() -> List Added requires [dbRead Added] = select row from Added order row.id asc
handler post addAdded() -> String requires [dbWrite Added] =
 let rows = [makeAdded "new"]
 let _ = insertMany rows in Added
 "created"
server NotesServer for NotesApi { health, all, added, addAdded, addOne, addTwo }|}
 |> replace "[dbRead Note, dbWrite Note, envRead]" "[dbRead Note, dbWrite Note, dbRead Added, dbWrite Added, envRead]"
let old_additive=additive
let additive target=old_additive target |> replace "Note: Additive [Default priority 9]" "Note: Additive [Default priority 9], Added: New"
let transforming=transforming
 |> replace "fixtures: [oldNote]" "fixtures: [oldNote, oldAdded]"
 |> replace "Note: Migrate convert [Rename author owner]" "Note: Migrate convert [Rename author owner], Added: Migrate convertAdded []"
 |> fun source -> source ^ {|fn convertAdded(old: Schema.Notes.V2.Added) -> Migrated Schema.Notes.VCurrent.Added =
 Row (Schema.Notes.VCurrent.Added { id: old.id, code: old.code, count: 11 })
fn oldAdded() -> Schema.Notes.V2.Added = Schema.Notes.V2.Added { id: "seed", code: "new-table" }
|}
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
 let root=Filename.temp_dir "tesl-row-tables-source-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
 let file p=Filename.concat root p in
 write (file "tesl.toml") "";
 let current=file "schema/notes/v-current.tesl" in
 let build version =
  let app=app (if version="v1" then 1 else if version="v2" then 2 else 3) in
  write (file "app.tesl") app;
  accepts (file "app.tesl");
  (* The common public compile route remains gated separately. This uses checked
     source emission but runs the ordinary generated main and schema CLI. *)
  let artifacts=match Compile.compile_row_source_artifacts ~storage:true ~physical:true
    (file "app.tesl") app with
   | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  let destination=Filename.concat output version in
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then write (Filename.concat destination a.path) a.contents) artifacts;
  check bool "ordinary main emitted" true (Sys.file_exists (Filename.concat destination "cmd/app/main.go"));
  let command=Printf.sprintf "cd %s && timeout 120s go build -race -tags tesl_migration_test -o app ./cmd/app >build.log 2>&1" (Filename.quote destination) in
  if Sys.command command<>0 then fail (Source_input.read (Filename.concat destination "build.log")) in
 write current (schema 1); build "v1";
 let v1=file "schema/notes/v1.tesl" in
 write v1 (schema 1 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V1");
 write current (schema 2);
 edge root (file "migrations/notes/v2.tesl") v1 current (additive "Schema.Notes.VCurrent") false;
 build "v2";
 let v2=file "schema/notes/v2.tesl" in
 write v2 (schema 2 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V2");
 edge root (file "migrations/notes/v2.tesl") v1 v2 (additive "Schema.Notes.V2") true;
 write current (schema 3);
 edge root (file "migrations/notes/v3.tesl") v2 current transforming false;
 let bytes=app 3 in
 write (file "app.tesl") bytes;
 let entry=match Parser.parse_module (file "app.tesl") bytes with Ok ast -> ast | Err e -> fail e.msg in
 let contract=get(Migration_program.with_source_history ~entry ~source:bytes (function
  | None -> fail "missing new-table history"
  | Some history ->
   let rows=List.assoc "App.Main" (Migration_program.row_histories history) in
   let plan=get(Migration_retained_storage.plan rows) in
   get(Migration_contract.source ~plan ~version:3))) in
 let contract_file=file "migrations/notes/v3-contract.tesl" in
 write contract_file contract; accepts contract_file;
 build "v3")
let compilation () =
 let output=Filename.temp_dir "tesl-row-tables-programs-" "" in
 Fun.protect ~finally:(fun () -> remove output) (fun () ->
  export output;
  let repo=match Sys.getenv_opt "TESL_REPO_ROOT" with Some p -> Unix.realpath p | None -> fail "TESL_REPO_ROOT required" in
  let log=Filename.concat output "postgres.log" in
  let command=Printf.sprintf "cd %s && TESL_ROW_TABLES_PROGRAMS=%s timeout 210s go test -p 1 -race -tags tesl_migration_test -timeout 180s ./teslrt -run '^TestPgRowTables' -count=1 -v > %s 2>&1"
   (Filename.quote (Filename.concat repo "runtime/go")) (Filename.quote output) (Filename.quote log) in
  if Sys.command command<>0 then fail (Source_input.read log))
let () = match Sys.getenv_opt "TESL_ROW_TABLES_EXPORT" with
 | Some output -> export output
 | None -> run "format5 new tables" ["native application",[
   test_case "authentic new table birth and later transform" `Quick compilation]]
