open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note, makeNote]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String, memo: String
 unique index [title] as "notes_title_unique" }
fn makeNote(id: String) -> Note = Note { id: id, author: "writer", title: id, memo: "base" }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, makeNote]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, owner: String, title: String, count: Int, memo: String
 unique index [title] as "notes_title_unique" }
fn makeNote(id: String) -> Note = Note { id: id, owner: "writer", title: id, count: 9, memo: "base" }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: []
  fixtures: [oldNote]
  entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  if old.id == "reject" then
    Reject "source rejected"
  else
    Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: amount(), memo: old.memo })
fn amount() -> Int = 7
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", author: "writer", title: "hello", memo: "fixture" }
test "actual pure transformation helper" {
  case convert (oldNote()) of
    Row row -> expect row.owner == "writer"
    Reject reason -> expect False
}
|}
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let project ?(before=old) ?(after=fresh) f =
  let root=Filename.temp_file "tesl-transform-source-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let save p s = let file=Filename.concat root p in write file s; file in
    ignore (save "tesl.toml" ""); ignore (save "schema/notes/v1.tesl" before); ignore (save "schema/notes/v-current.tesl" after);
    let file=save "migrations/notes/v2.tesl" source in f root save file)
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let errors path s = (Compile.agent_context_result_source path s).diagnostics |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts path s = match errors path s with [] -> () | ds -> fail (describe ds)

module RH=Migration_row_history
module P=Migration_program
let app = {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
import Tesl.Telemetry exposing [telemetry]
import Tesl.Env exposing [envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent exposing [Note, makeNote]
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  dbName: "unused"
  user: "unused"
  password: "secret-sentinel"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
api NotesApi {
 get "/health" -> String
 get "/one" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 post "/three" -> String
 post "/four" -> String
 post "/five" -> String
 post "/reject" -> String
 put "/one" -> String
 put "/all" -> String
 put "/conflict" -> String
 put "/effects" -> String
 put "/empty" -> String
 put "/returning" -> String
 put "/missing-returning" -> String
 put "/ambiguous-returning" -> String
 put "/transaction" -> String
}
handler get health() -> String = "ready"
handler get one() -> String requires [dbRead Note] =
 case selectOne note from Note where note.id == "one" of
  Nothing -> "missing"
  Something note -> note.title
handler get all() -> List Note requires [dbRead Note] = select note from Note order note.id asc
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "created"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "created"
handler post addThree() -> String requires [dbWrite Note] =
 let rows = [makeNote "three"]
 let _ = insertMany rows in Note
 "created"
handler post addFour() -> String requires [dbWrite Note] =
 let rows = [makeNote "four"]
 let _ = insertMany rows in Note
 "created"
handler post addFive() -> String requires [dbWrite Note] =
 let rows = [makeNote "five"]
 let _ = insertMany rows in Note
 "created"
handler post addReject() -> String requires [dbWrite Note] =
 let rows = [makeNote "reject"]
 let _ = insertMany rows in Note
 "created"
handler put editOne() -> String requires [dbWrite Note] =
 update note in Note
  where note.id == "one"
  set note.title = "edited"
  set note.memo = "one-edited"
 "edited"
handler put editAll() -> String requires [dbWrite Note] =
 update note in Note
  set note.memo = "all-edited"
 "edited"
fn marked(value: String) -> String =
 telemetry "access-operand" { phase = value }
 value
handler put conflict() -> String requires [dbWrite Note] =
 update note in Note
  set note.title = "duplicate"
 "edited"
handler put effects() -> String requires [dbWrite Note] =
 update note in Note
  where note.id != (marked "where-multi")
  set note.memo = marked "set-multi"
 "edited"
handler put empty() -> String requires [dbWrite Note] =
 update note in Note
  where note.id == (marked "where-zero")
  set note.memo = marked "set-zero"
 "edited"
fn changeReturning(id: String) -> Note requires [dbWrite Note] =
 updateAndReturnOne note in Note
  where note.id == id
  set note.title = "edited"
fn changeAmbiguous() -> Note requires [dbWrite Note] =
 updateAndReturnOne note in Note
  set note.memo = "ambiguous-should-not-write"
handler put ambiguousReturning() -> String requires [dbWrite Note] =
 let row = changeAmbiguous()
 row.title
handler put returning() -> String requires [dbWrite Note] =
 let row = changeReturning "one"
 row.title
handler put missingReturning() -> String requires [dbWrite Note] =
 let row = changeReturning "missing"
 row.title
handler put transactionOnce() -> String requires [dbRead Note, dbWrite Note] =
 transaction {
  let previous = case selectOne note from Note where note.id == "one" of
   Nothing -> "missing"
   Something note -> note.memo
  telemetry "access-transaction" { phase = "between-statements" }
  update note in Note
   where note.id == "one"
   set note.memo = previous ++ "-transaction"
  "committed"
 }
server NotesServer for NotesApi { health, one, all, addOne, addTwo, addThree, addFour, addFive, addReject, editOne, editAll, conflict, effects, empty, returning, missingReturning, ambiguousReturning, transactionOnce }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}
let load file =
 let abi=Result.get_ok (Migration_abi.current ()) in
 match Migration_inventory.load_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
 | Ok i -> i | Error e -> fail e.message
let seal root file=match Migration_seal.create ~project_root:root (load file) with
 | Ok s -> s | Error e -> fail e.message
let seal_edge root path =
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 write path (Migration_header.encode header ^ source)
let emit ?(mode=Emit_go.Release) ?(physical=false) file = match Compile.compile_row_source_artifacts ~mode ~storage:true ~physical file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)


let replace a b s=Str.global_replace (Str.regexp_string a) b s
let repository ()=Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name=Source_input.read (Filename.concat (repository ()) ("compiler/test/fixtures/row-access/" ^ name))
let command directory log text=
 let status=Sys.command (Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory) text (Filename.quote log)) in
 if status<>0 then fail (text ^ "\n" ^ Source_input.read log)
let install_contract root path =
 let get=function Ok value -> value | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error)->e.message) errors)) in
 let abi=Result.get_ok(Migration_abi.current()) in
 let source=Source_input.read path in
 let ast=match Parser.parse_module path source with Ok m->m | Err e->fail e.msg in
 let declaration=match get(D.check ~compiler_abi:(Migration_abi.id abi) ~source ast) with Some d->d | None->fail "missing transform" in
 let before,after=S.inventories(D.coverage declaration) in
 let rows=get(RH.check ~schemas:[before;after] ~edges:[declaration]) in
 let plan=get(Migration_retained_storage.plan rows) in
 let source=get(Migration_contract.source ~plan ~version:2) in
 let file=Filename.concat root "migrations/notes/v2-contract.tesl" in
 write file source; accepts file source

let write_repeated_bridges output =
 write(Filename.concat output "internal/teslmodapp/repeated_read_test_bridge.go")
  "package teslmodapp\n// Invoke the unchanged actual Tesl read handler.\nfunc TestRepeatedRead() { _ = all() }\n";
 write(Filename.concat output "internal/teslrt/repeated_lock_test_bridge.go") {|package teslrt
import ("context"; "fmt")
// Test-only caller lock setup. No migration metadata, codec, row callback or
// physical plan is supplied; read invokes the original generated Tesl handler.
func TestRepeatedLockedRead(database *Database, read func()) {
 WithDatabase(database, func(){
  connection:=database.bound()
  if connection==nil || connection.pool.Config().MaxConns!=1 {panic("test requires actual size-one request pool")}
  WithTransaction(func(){
   tx:=currentTransactionFor(connection)
   if tx==nil {panic("test requires caller-owned SQL transaction")}
   ctx,cancel:=context.WithTimeout(context.Background(),pgLeaseTimeout());defer cancel()
   if _,err:=tx.Exec(ctx,"select id from notes.notes where id='one' for update");err!=nil{panic(fmt.Sprintf("caller row lock: %v",err))}
   read()
  })
 })
}
|}
let repeated_driver driver = driver
 |> replace "MigrationTopology: \"Worker\"" "PoolSize: 1, MigrationTopology: \"Worker\""
 |> replace "if os.Args[1] == \"effects\""
  "if os.Args[1] == \"locked-observe\" {rt.TestRepeatedLockedRead(app.MainDatabase,app.TestRepeatedRead);fmt.Println(\"locked-observe-complete\");return}\n if os.Args[1] == \"effects\""

let export ?(contracts=false) ?(repeated=false) destination=project (fun root save path ->
 seal_edge root path;let edge=Source_input.read path in
 let app=if not contracts then app else app
  |> replace "[String, List]" "[String, List, Bool(..)]"
  |> replace "[telemetry]" "[telemetry, TelemetryConfig]"
  |> replace "App { database: Main" "App { telemetry: TelemetryConfig { service: \"row-access\", endpoint: \"in-memory\", console: True }, database: Main" in
 let file=save "app.tesl" app in
 let build version=
  accepts file (Source_input.read file);
  let artifacts=emit ~mode:(if version="v2debug" then Emit_go.Debug else Emit_go.Release) ~physical:true file in
  let output=Filename.concat destination version in
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then
   let contents=if version<>"v2missing" then a.contents else
    String.split_on_char '\n' a.contents |> List.filter (fun line -> not (Compile.string_contains line "var _ = teslrt.RegisterCompiledRowAccess[")) |> String.concat "\n" in
   write (Filename.concat output a.path) contents) artifacts;
  let driver=fixture "main.go" in
  let driver=if version="v2missing" then replace "if err := rt.PreflightApplicationDatabases" "if os.Args[1] == \"bindings\" {fmt.Println(app.TestAccessBindings());return}\n if err := rt.PreflightApplicationDatabases" driver else driver in
  if version="v2missing" then write (Filename.concat output "internal/teslmodapp/access_bindings_test_bridge.go") (fixture "bindings.go");
  let driver=if version="v2debug" then replace "if os.Args[1] == \"serve\"" "if os.Args[1] == \"debug\" {rt.WithDatabase(app.MainDatabase,func(){json.NewEncoder(os.Stdout).Encode(app.TestAccessDebug())});return}\n if os.Args[1] == \"serve\"" driver else driver in
  let driver=if not contracts then driver else replace "handled, code := rt.RunSchemaCommand" "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V2\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" driver in
  let driver=if repeated then (write_repeated_bridges output;repeated_driver driver) else driver in
  write (Filename.concat output "cmd/access-test/main.go") driver;
  if version="v2debug" then write (Filename.concat output "internal/teslmodapp/access_debug_test_bridge.go") (fixture "debug.go");
  write (Filename.concat output "internal/teslmodapp/access_effects_test_bridge.go") (fixture "effects.go");
  command output (Filename.concat output "build.log") "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test" in
 remove path;remove (Filename.concat root "schema/notes/v1.tesl");
 ignore(save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old));build "v1";
 ignore(save "schema/notes/v1.tesl" old);ignore(save "schema/notes/v-current.tesl" fresh);write path edge;if contracts then install_contract root path;build "v2";(if not contracts then (build "v2debug";build "v2missing"));
 ignore(save "app.tesl" (replace "select note from Note order note.id asc" "select note from Note where note.owner == \"writer\" order note.id asc" app));build "v2query")
let refused_queries () =
 let member="\nentity Member table \"members\" primaryKey id { id: String, name: String }\n" in
 let schema s=(replace "[Note, makeNote]" "[Note, makeNote, Member]" s) ^ member in
 let cases=[
  "computed predicate","select note from Note where note.count == 7","List Note","unchanged Copy or Rename";
  "computed ordering","select note from Note order note.count asc","List Note","unchanged Copy or Rename";
  "aggregate","selectCount note from Note","Int","without joins or aggregates";
  "forward join","select note from Note\n  innerJoin Member on note.owner Member.name","List Note","without joins or aggregates";
  "reverse join","select member from Member\n  innerJoin Note on member.name Note.owner","List Member","joining a transforming entity";
 ] in
 List.iter (fun (label,query,result,reason) -> project ~before:(schema old) ~after:(schema fresh) (fun root save path ->
  seal_edge root path;
  let bytes=app |> replace "[String, List]" "[String, List, Int]"
   |> replace "[Note, makeNote]" "[Note, makeNote, Member]"
   |> replace "get \"/all\" -> List Note" ("get \"/all\" -> " ^ result)
   |> replace "handler get all() -> List Note requires [dbRead Note] = select note from Note order note.id asc"
     ("handler get all() -> " ^ result ^ " requires [dbRead Note, dbRead Member] =\n " ^ query)
   |> replace "main() -> App requires [dbRead Note," "main() -> App requires [dbRead Member, dbRead Note," in
  let file=save "app.tesl" bytes in accepts file bytes;
  match Compile.compile_row_source_artifacts ~storage:true ~physical:true file bytes with
   | Compile.GoSuccess _ -> fail ("unsafe legacy query accepted: " ^ label)
   | Compile.GoFailure ds -> check bool (label ^ "\n" ^ describe ds) true (List.exists (fun (d:Compile.diagnostic) -> Compile.string_contains d.message reason) ds))) cases
let additive_tail_refuses ()=project (fun root save path ->
 let frozen=save "schema/notes/v2.tesl" (replace "Schema.Notes.VCurrent" "Schema.Notes.V2" fresh) in
 let header=match Migration_header.create ~previous:(seal root (Filename.concat root "schema/notes/v1.tesl")) ~current:(seal root frozen) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 let edge=Migration_header.encode header ^ replace "Schema.Notes.VCurrent" "Schema.Notes.V2" source in
 let get=function Ok value -> value | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 let closure=get (Migration_closure.capture ~project_root:root ~root_file:path ~source:edge) in
 write path (get (Migration_closure.attach ~file:path ~source:edge closure));
 let next_header=get (Migration_header.create ~previous:(seal root frozen) ~current:(seal root (Filename.concat root "schema/notes/v-current.tesl"))) in
 ignore(save "migrations/notes/v3.tesl" (Migration_header.encode next_header ^ {|module Schema.Notes.Migrate.V3 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..)]
import Schema.Notes.V2
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V2
 to: Schema.Notes.VCurrent
 same: []
 fixtures: []
 entities: {}
}
|}));
 let file=save "app.tesl" app in accepts file app;
 match Compile.compile_row_source_artifacts ~storage:true ~physical:true file app with
 | Compile.GoSuccess _ -> fail "uncomposed additive tail silently used legacy queries"
 | Compile.GoFailure ds -> check bool (describe ds) true
   (List.exists (fun (d:Compile.diagnostic) -> Compile.string_contains d.message "typed access composition") ds))
let update_cost_diagnostics ()=project (fun root save path ->
 seal_edge root path;
 let file=save "app.tesl" app in
 let warnings bytes =
   let snapshot=Compile.agent_context_result_source file bytes in
   check bool (describe snapshot.diagnostics) true snapshot.ok;
   List.filter (fun (d:Compile.diagnostic) -> d.code="MIG031") snapshot.diagnostics in
 let ds=warnings app in
 check int "all rows, non-key inequality and conflicting bulk update and ambiguous return" 4 (List.length ds);
 List.iter (fun (d:Compile.diagnostic) ->
   check string "suggestion is non-fatal" "warning" d.severity;
   check bool "related actual migration" true
     (match d.metadata with Some metadata -> List.exists (fun (loc,_) -> loc.Location.file=path) metadata.related | None -> false);
   check bool "suggested action" true (match d.metadata with
     | Some {action=Some {class_=Diagnostic_metadata.Suggested;_};_} -> true | _ -> false)) ds;
 let pk=replace "where note.id != (marked \"where-multi\")" "where note.id == (marked \"where-multi\")" app in
 check int "primary key equality avoids row cost warning" 3 (List.length (warnings pk));
 let disjunctive=replace "where note.id == (marked \"where-zero\")" "where note.id == \"one\" || note.id == \"two\"" app in
 check int "OR of primary keys is a multi-row match" 5 (List.length (warnings disjunctive));
 let conjunctive=replace "where note.id != (marked \"where-multi\")" "where note.id == \"one\" && note.title == \"edited\"" app in
 check int "primary-key equality with extra predicates is bounded" 3 (List.length (warnings conjunctive)))

let native ()=
 let output=Filename.temp_dir "tesl-row-access-" "" in
 Fun.protect ~finally:(fun () -> if Sys.getenv_opt "TESL_KEEP_ROW_ACCESS_TEST"=None then remove output) (fun () ->
  export output;
  command (Filename.concat (repository ()) "runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_ACCESS_PROGRAMS=%s timeout 180s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowAccessActualApp$' -count=1 -v" (Filename.quote output));
  Printf.printf "actual generated handler trace passed\n%!")
let native_settled ?(test="TestPgRow(SettledActualApp|FinalityRenewsOutsideBatchesAndWaitsForOwnCAS|HealthyWorkerClaimSkipsActiveCAS|BackfillBackendKillPreservesAtomicProgress|StagedNullabilityAllowsWritesAndPublishesExactProof|StagedNullabilityCrashReceiptAtomicity|ContractPrepareHasOperationDeadline|PrepareRetriesCommittedProgressSnapshot|ClaimRetriesCommittedRenewalSnapshot|BackfillRetriesWriteAfterCASSnapshot|WorkerDrainsInFlightRenewalAfterBatchCommit|RetirementRequiresEntireFinalShardInventory)") ()=
 let output=Filename.temp_dir "tesl-row-settled-" "" in
 Fun.protect ~finally:(fun () -> if Sys.getenv_opt "TESL_KEEP_ROW_SETTLED_TEST"=None then remove output) (fun () ->
  export ~contracts:true output;
  command (Filename.concat (repository ()) "runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_SETTLED_PROGRAMS=%s timeout 210s go test -p 1 -race -tags tesl_migration_test -timeout 180s ./teslrt -run %s -count=1 -v" (Filename.quote output) (Filename.quote ("^" ^ test ^ "$"))))

let key_type = {|module Types.Key exposing [Key, makeKey]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Key { value: String }
codec Key {
 toJson { value -> "storedKey" with_codec stringCodec }
 fromJson [ { value <- "storedKey" with_codec stringCodec } ]
}
fn makeKey(value: String) -> Key = Key { value: value }
|}
let key_schema name extra = Printf.sprintf {|module Schema.Notes.%s exposing [Note, makeNote, Key, makeKey]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
record Key { value: String }
codec Key {
 toJson { value -> "storedKey" with_codec stringCodec }
 fromJson [ { value <- "storedKey" with_codec stringCodec } ]
}
fn makeKey(value: String) -> Key = Key { value: value }
entity Note table "notes" primaryKey id { id: Key, title: String%s }
fn makeNote(value: String) -> Note = Note { id: makeKey value, title: value%s }
|} name (if extra then ", count: Int" else "") (if extra then ", count: 9" else "")
let key_source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]
 fixtures: [oldNote]
 entities: { Note: Migrate convert [] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: Schema.Notes.VCurrent.Key { value: old.id.value }, title: old.title, count: 7 })
fn oldNote() -> Schema.Notes.V1.Note = Schema.Notes.V1.Note { id: Schema.Notes.V1.makeKey "fixture", title: "fixture" }
|}
let key_app = {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.App exposing [App]
import Tesl.Env exposing [envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent exposing [Note, makeNote]
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  dbName: "unused"
  user: "unused"
  password: "secret-sentinel"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
api NotesApi {
 get "/health" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 post "/three" -> String
}
handler get health() -> String = "ready"
handler get all() -> List Note requires [dbRead Note] = select note from Note
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "created"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "created"
handler post addThree() -> String requires [dbWrite Note] =
 let rows = [makeNote "three"]
 let _ = insertMany rows in Note
 "created"
server NotesServer for NotesApi { health, all, addOne, addTwo, addThree }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}
let export_keys destination = project ~before:(key_schema "V1" false) ~after:(key_schema "VCurrent" true) (fun root save path ->
 let old_file=Filename.concat root "schema/notes/v1.tesl" and current_file=Filename.concat root "schema/notes/v-current.tesl" in
 let file=save "app.tesl" key_app in
 let build version =
  accepts file (Source_input.read file);
  let output=Filename.concat destination version in
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json") then write (Filename.concat output a.path) a.contents) (emit ~physical:true file);
  let driver=fixture "main.go" |> replace " \"encoding/json\"" "" in
  let driver=String.split_on_char '\n' driver |> List.filter(fun line->not(Compile.string_contains line "TestAccessEffects")) |> String.concat "\n" in
  let driver=replace "handled, code := rt.RunSchemaCommand" "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V2\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" driver in
  write (Filename.concat output "cmd/access-test/main.go") driver;
  command output (Filename.concat output "build.log") "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test" in
 remove path; remove old_file; write current_file (key_schema "VCurrent" false);build "v1")
let native_keys () =
 let output=Filename.temp_dir "tesl-row-json-key-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_SETTLED_TEST"=None then remove output) (fun()->
  export_keys output;
  command (Filename.concat(repository()) "runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_JSON_KEY_PROGRAMS=%s timeout 210s go test -p 1 -race -tags tesl_migration_test -timeout 180s ./teslrt -run '^TestPgRowJSONKeyBaselineAndCarrier$' -count=1 -v" (Filename.quote output)))

let nominal_key_boundaries () = project ~before:(key_schema "V1" false) ~after:(key_schema "VCurrent" true) (fun root save path ->
 let old_file=Filename.concat root "schema/notes/v1.tesl" and current_file=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root old_file) ~current:(seal root current_file) with
  | Ok header -> header | Error errors -> fail(String.concat "\n" (List.map(fun(e:S.error)->e.message)errors)) in
 let edge=Migration_header.encode header ^ key_source in
 let refused code source = write path source; let ds=errors path source in
  check bool ("nominal primary-key boundary " ^ code ^ "\n" ^ describe ds) true
   (List.exists(fun(d:Compile.diagnostic)->d.code=code)ds) in
 refused "MIG018" edge;
 let copied=replace "id: Schema.Notes.VCurrent.Key { value: old.id.value }" "id: old.id" edge in
 write path copied; accepts path copied;
 let external_file=save "types/key.tesl" key_type in accepts external_file key_type;
 write current_file "module Schema.Notes.VCurrent exposing [Note]\nimport Types.Key exposing [Key]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: Key, title: String }\n";
 let abi=Result.get_ok(Migration_abi.current()) in
 match Migration_inventory.load ~compiler_abi:(Migration_abi.id abi) ~root_file:current_file with
 | Ok _->fail "external nominal key escaped sealed snapshot"
 | Error error->check bool "schema scope refuses external nominal identity" true
   (Compile.string_contains error.message "escapes"))

let list_key_boundary () = project (fun _ save _ ->
 let schema="module Schema.Notes.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String, List]\nentity Note table \"notes\" primaryKey id { id: List String, title: String }\n" in
 let file=save "schema/notes/v-current.tesl" schema in accepts file schema;
 match Migration_storage.describe(load file) with
 | Ok _->fail "List String primary key unexpectedly gained a checked migration carrier"
 | Error errors->check bool ("List carrier has no checked storage assignment: " ^ String.concat ";" (List.map(fun(e:S.error)->e.code ^ ":" ^ e.message) errors)) true
  (List.exists(fun(e:S.error)->e.code="MIG016" && Compile.string_contains e.message "carrier")errors))

let repeated_schema = fresh
 |> replace "owner: String" "assignee: String"
 |> replace "owner: \"writer\"" "assignee: \"writer\""
 |> replace "count: Int" "count: Int, priority: Int"
 |> replace "count: 9" "count: 9, priority: 11"
let repeated_migration = {|module Schema.Notes.Migrate.V3 exposing [migration, oldNote]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V2
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V2
 to: Schema.Notes.VCurrent
 same: []
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Rename owner assignee] }
}
fn convert(old: Schema.Notes.V2.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: old.id, assignee: old.owner, title: old.title, count: old.count, priority: old.count + 1, memo: old.memo })
fn oldNote() -> Schema.Notes.V2.Note = Schema.Notes.V2.Note {
 id: "retained", owner: "writer", title: "hello", count: 7, memo: "fixture"
}
|}
let apply_source_manifest manifest =
 let check = function Ok ()->()|Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_manifest.error)->e.message)errors)) in
 check(Migration_manifest.verify_source manifest ~documents:[]);
 check(Migration_manifest.verify_disk manifest);
 List.iter(fun(e:Migration_manifest.edit)->write e.path e.after)(Migration_manifest.edits manifest)
let with_repeated_project ?(contract=true) f = project(fun root save path ->
 seal_edge root path;if contract then install_contract root path;
 let app_file=save "app.tesl" app in accepts app_file app;
 let abi=Result.get_ok(Migration_abi.current()) in
 let get=function Ok x->x|Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_generate.error)->e.message)errors)) in
 let preview=get(Migration_generate.start_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
  ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes" ~version:2 ~documents:[]) in
 apply_source_manifest preview.manifest;
 let current_file=save "schema/notes/v-current.tesl" repeated_schema in
 let refreshed=get(Migration_generate.refresh_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
  ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes" ~version:3 ~documents:[]) in
 apply_source_manifest refreshed.manifest;
 let previous=seal root (Filename.concat root "schema/notes/v2.tesl") and current=seal root current_file in
 let header=match Migration_header.create ~previous ~current with Ok h->h|Error errors->fail(String.concat "\n" (List.map(fun(e:S.error)->e.message)errors)) in
 let edge=Migration_header.encode header ^ repeated_migration in
 let third=save "migrations/notes/v3.tesl" edge in accepts third edge;accepts app_file app;
 f root save app_file)
let prepare_repeated destination = with_repeated_project(fun root _ app_file ->
 let rec copy relative =
  let file=Filename.concat root relative in
  if Sys.is_directory file then Array.iter(fun name->copy(Filename.concat relative name))(Sys.readdir file)
  else write(Filename.concat destination relative)(Source_input.read file) in
 copy "";
 let artifacts=emit ~physical:true app_file in
 let output=Filename.concat destination "generated" in
 List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then
  write(Filename.concat output a.path)a.contents)artifacts;
 command output (Filename.concat output "build.log") "timeout 120s go build -p 1 ./...";
 Printf.printf "Authentic V3 source and exact Contract-bound Go artifact compiled\n%!")

let repeated_binding_guards () =
 with_repeated_project ~contract:false(fun _ _ app_file->
  match Compile.compile_row_source_artifacts ~storage:true ~physical:true app_file app with
  | Compile.GoSuccess _->fail "V3 emitted without checked predecessor Contract"
  | Compile.GoFailure ds->check bool (describe ds) true
    (List.exists(fun(d:Compile.diagnostic)->Compile.string_contains d.message "exact checked Contract V2")ds));
 with_repeated_project(fun _ save app_file ->
 let artifacts=emit ~physical:true app_file in
 let rows=artifacts |> List.filter(fun(a:Emit_go.artifact)->Compile.string_contains a.path "migration_rows_")
  |> List.map(fun(a:Emit_go.artifact)->a.contents) |> String.concat "\n" in
 check bool "original V2 nominal callback remains registered" true
  (Compile.string_contains rows "teslmodschemanotesmigratev2.TeslCompiledRowCallback");
 check bool "current V3 nominal callback is registered independently" true
  (Compile.string_contains rows "teslmodschemanotesmigratev3.TeslCompiledRowCallback");
 let unsafe=app |> replace "select note from Note order note.id asc"
   "select note from Note where note.priority == 8 order note.id asc" in
 ignore(save "app.tesl" unsafe);accepts app_file unsafe;
 match Compile.compile_row_source_artifacts ~storage:true ~physical:true app_file unsafe with
 | Compile.GoSuccess _->fail "V3 computed predicate silently gained legacy SQL"
 | Compile.GoFailure ds->check bool (describe ds) true
   (List.exists(fun(d:Compile.diagnostic)->Compile.string_contains d.message "unchanged Copy or Rename")ds))

let export_repeated destination =
 export ~contracts:true ~repeated:true destination;
 with_repeated_project(fun _ _ app_file ->
  let bytes=Source_input.read app_file in
  let entry=match Parser.parse_module app_file bytes with Ok ast->ast|Err e->fail e.msg in
  let get=function Ok value->value|Error errors->fail(String.concat "\n"(List.map(fun(e:S.error)->e.message)errors)) in
  let contract=get(P.with_source_history ~entry ~source:bytes (function
   | None->fail "missing repeated source history"
   | Some history->
    let rows=List.assoc "App.Main" (P.row_histories history) in
    let plan=get(Migration_retained_storage.plan rows) in
    get(Migration_contract.source ~plan ~version:3))) in
  let contract_file=Filename.concat(Filename.dirname app_file)"migrations/notes/v3-contract.tesl" in
  write contract_file contract;accepts contract_file contract;
  let output=Filename.concat destination "v3" in
  let artifacts=emit ~physical:true app_file in
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then
   write(Filename.concat output a.path)a.contents)artifacts;
  let driver=fixture "main.go" |> replace "handled, code := rt.RunSchemaCommand"
   "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V3\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" in
  write_repeated_bridges output;
  let driver=repeated_driver driver in
  write(Filename.concat output "cmd/access-test/main.go")driver;
  write(Filename.concat output "internal/teslmodapp/access_effects_test_bridge.go")(fixture "effects.go");
  command output (Filename.concat output "build.log")
   "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test")

let native_repeated () =
 let output=Filename.temp_dir "tesl-row-repeated-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_REPEATED_TEST"=None then remove output)(fun()->
  export_repeated output;
  command(Filename.concat(repository())"runtime/go")(Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_REPEATED_PROGRAMS=%s timeout 210s go test -p 1 -race -tags tesl_migration_test -timeout 180s ./teslrt -run '^TestPgRowRepeatedActualApp$' -count=1 -v" (Filename.quote output)))

let ()=match Sys.getenv_opt "TESL_ROW_REPEATED_EXPORT" with
 | Some root->export_repeated root
 | None->match Sys.getenv_opt "TESL_ROW_REPEATED_PREPARE",Sys.getenv_opt "TESL_ROW_JSON_KEY_EXPORT",Sys.getenv_opt "TESL_ROW_SETTLED_EXPORT",Sys.getenv_opt "TESL_ROW_ACCESS_EXPORT" with
 | Some root,_,_,_ -> prepare_repeated root
 | None,Some root,_,_ -> export_keys root
 | None,None,Some root,_ -> export ~contracts:true root
 | None,None,None,Some root -> export root
 | None,None,None,None -> run "ordinary typed migration queries" ["access",[test_case "actual unchanged V1/V2 App handlers on PostgreSQL" `Quick native;
 test_case "computed, aggregate and both join directions refuse" `Quick refused_queries;
 test_case "additive tail cannot silently use legacy dispatch" `Quick additive_tail_refuses;
 test_case "MIG031 uses checked ownership and primary-key equality" `Quick update_cost_diagnostics;
 test_case "same App serves across actual Contract" `Quick (native_settled ?test:None);
 test_case "old writer CAS miss preserves row and first ABI" `Quick (native_settled ~test:"TestPgRowWorkerCASMiss");
 test_case "nominal JSONB key Copy reconstruction and external scope refuse" `Quick nominal_key_boundaries;
 test_case "generated V1 JSONB key codec and raw carrier boundary" `Quick native_keys;
 test_case "builtin List key has no checked migration carrier" `Quick list_key_boundary;
 test_case "repeated exact current binding requires predecessor Contract" `Quick repeated_binding_guards;
 test_case "actual unchanged App across two windows" `Quick native_repeated]]
