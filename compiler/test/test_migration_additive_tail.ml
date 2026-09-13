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
let replace a b s=Str.global_replace (Str.regexp_string a) b s
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

let tail_schema = fresh
 |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
 |> replace "memo: String" "memo: String, note: Maybe String, priority: Int"
 |> replace "memo: \"base\"" "memo: \"base\", note: Nothing, priority: 4"
let tail_migration = {|module Schema.Notes.Migrate.V3 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Notes.V2
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V2
 to: Schema.Notes.VCurrent
 same: []
 fixtures: []
 entities: { Note: Additive [Default priority 4] }
}
|}
let apply_source_manifest manifest =
 let check = function Ok ()->()|Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_manifest.error)->e.message)errors)) in
 check(Migration_manifest.verify_source manifest ~documents:[]);
 check(Migration_manifest.verify_disk manifest);
 List.iter(fun(e:Migration_manifest.edit)->write e.path e.after)(Migration_manifest.edits manifest)
let with_tail_project ?(contract=true) ?(on_version=(fun _ _ -> ())) f = project(fun root save path ->
 seal_edge root path;if contract then install_contract root path;
 let app_file=save "app.tesl" app in accepts app_file app;
 on_version 2 app_file;
 let abi=Result.get_ok(Migration_abi.current()) in
 let get=function Ok x->x|Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_generate.error)->e.message)errors)) in
 let preview=get(Migration_generate.start_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
  ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes" ~version:2 ~documents:[]) in
 apply_source_manifest preview.manifest;
 let current_file=save "schema/notes/v-current.tesl" tail_schema in
 let refreshed=get(Migration_generate.refresh_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
  ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes" ~version:3 ~documents:[]) in
 apply_source_manifest refreshed.manifest;
 let previous=seal root (Filename.concat root "schema/notes/v2.tesl") and current=seal root current_file in
 let header=match Migration_header.create ~previous ~current with Ok h->h|Error errors->fail(String.concat "\n" (List.map(fun(e:S.error)->e.message)errors)) in
 let edge=Migration_header.encode header ^ tail_migration in
 let third=save "migrations/notes/v3.tesl" edge in accepts third edge;accepts app_file app;
 f root save app_file)

let get=function Ok value->value|Error errors->fail(String.concat "\n"(List.map(fun(e:S.error)->e.code ^ ": " ^ e.message)errors))
let with_plan app_file f =
 let bytes=Source_input.read app_file in
 let entry=match Parser.parse_module app_file bytes with Ok m->m|Err e->fail e.msg in
 get(P.with_source_history ~entry ~source:bytes(function
 |None->fail "missing complete source history"
 |Some source->let history=List.assoc "App.Main"(P.row_histories source) in
  let plan=get(Migration_retained_storage.plan history) in f source plan))
let settled_prerequisite () = with_tail_project(fun _ _ entry->with_plan entry(fun _ plan ->
 let module L=Migration_retained_storage in
 let third=List.find(fun(v:L.version)->v.version=3)(L.versions plan) in
 let entity=List.find(fun(e:L.entity)->e.source.identity="Note")third.entities in
 check (option int) "additive successor requires exact prior Contract" (Some 2) third.requires_contract_version;
 check int "schema version does not invent a generation" 2 entity.source.generation;
 check int "settled generation default" 2 entity.marker_default_generation;
 check int "no new transforming window" 0(List.length third.windows);
 check bool "retired physical field stays removed" false(List.exists(fun(c:L.column)->c.name="author")entity.columns);
 check int "no obsolete dual-write aliases" 0(List.length entity.rename_dual_writes);
 check bool "completed computed field is required" false (List.find(fun(c:L.column)->c.name="count")entity.columns).nullable))
let artifacts entry = match Compile.compile_row_source_artifacts ~storage:true ~physical:true entry app with
 |Compile.GoSuccess artifacts->artifacts
 |Compile.GoFailure ds->fail("accepted mixed history lacks current access:\n" ^ describe ds)
let artifact name artifacts=(List.find(fun(a:Emit_go.artifact)->a.path=name)artifacts).contents
let current_artifact () = with_tail_project(fun _ _ entry->
 let artifacts=artifacts entry in
 let open Yojson.Basic.Util in
 let json=Yojson.Basic.from_string(artifact "row-transform-history.json" artifacts) in
 check int "new closed companion format" 5 (json |> member "version" |> to_int);
 let db=json |> member "databases" |> to_list |> List.hd in
 let transforms=db |> member "transforms" |> to_list in
 check int "only original real callback retained" 1(List.length transforms);
 let transform=List.hd transforms in
 check int "no invented V3 transform" 2(transform |> member "migrationVersion" |> to_int);
 List.iter(fun field->check int ("format5 retains " ^ field) 0(transform |> member field |> to_list |> List.length))["writeBacks";"legacyWrites"];
 let codecs=db |> member "currentCodecs" |> to_list in
 check int "complete current codec inventory" 1(List.length codecs);
 let codec=List.hd codecs in
 check int "current source schema" 3(codec |> member "schemaVersion" |> to_int);
 check int "current generation retained" 2(codec |> member "generation" |> to_int);
 check string "exact source entity" "Note" (codec |> member "entity" |> to_string);
 let base=Yojson.Basic.from_string(artifact "migration-source-history.json" artifacts) |> member "databases" |> to_list |> List.hd |> member "versions" |> to_list
  |> List.find(fun v->v |> member "version" |> to_int=3) in
 List.iter(fun(field,expected)->check string ("exact " ^ field) (base |> member expected |> to_string)(codec |> member field |> to_string))
  ["schemaSnapshot","schemaSnapshotHash";"storageSnapshot","storageSnapshotHash"];
 let base_entity=base |> member "entities" |> to_list |> List.hd in
 check string "exact type/codec contract" (base_entity |> member "typeContractHash" |> to_string)(codec |> member "typeContractHash" |> to_string);
 let projection=codec |> member "projection" |> to_list |> List.map to_string in
 check (list string) "actual emitted storage order" ["id";"owner";"title";"count";"memo";"note";"priority"] projection;
 let generated=List.filter(fun(a:Emit_go.artifact)->Filename.check_suffix a.path ".go")artifacts |> List.map(fun(a:Emit_go.artifact)->a.contents) |> String.concat "\n" in
 List.iter(fun name->check bool name true(try ignore(Str.search_forward(Str.regexp_string name)generated 0);true with Not_found->false))
  ["LookupCompiledRowCurrent(";"NewCompiledRowCodec[";"RegisterCompiledRowCurrentStorage[";"RegisterCompiledRowCurrentAccess["];
 Option.iter(fun root->List.iter(fun(a:Emit_go.artifact)->write(Filename.concat root a.path)a.contents)artifacts)(Sys.getenv_opt "TESL_MIXED_TAIL_ARTIFACTS"))
let missing_contract () = with_tail_project(fun root _ entry->
 Sys.remove(Filename.concat root "migrations/notes/v2-contract.tesl");
 match Compile.compile_row_source_artifacts ~storage:true ~physical:true entry app with
 |Compile.GoSuccess _->fail "additive successor accepted missing required source Contract"
 |Compile.GoFailure ds->check bool "coded refusal for missing source authority" true (List.exists(fun(d:Compile.diagnostic)->String.starts_with ~prefix:"MIG" d.code)ds))
let storage_only_refused () = with_tail_project(fun _ _ entry->
 match Compile.compile_row_source_artifacts ~storage:true entry app with
 | Compile.GoSuccess _->fail "storage-only current row accepted without physical registration"
 | Compile.GoFailure ds->check bool "constructive current physical requirement" true
   (List.exists(fun(d:Compile.diagnostic)->d.message="current row codec emission requires its checked physical history; enable physical row artifacts")ds))
let original_format () =
 with_tail_project ~on_version:(fun version entry->
  check int "actual predecessor version" 2 version;
  let open Yojson.Basic.Util in
  let json=Yojson.Basic.from_string(artifact "row-transform-history.json" (artifacts entry)) in
  check int "ordinary transform format remains2" 2(json |> member "version" |> to_int);
  let db=json |> member "databases" |> to_list |> List.hd in
  check bool "old format has no current codec field" true(db |> member "currentCodecs" = `Null))
  (fun _ _ _->())
let export_programs destination =
 let emit version entry=List.iter(fun(a:Emit_go.artifact)->write(Filename.concat (Filename.concat destination ("v" ^ string_of_int version)) a.path)a.contents)(artifacts entry) in
 let root=Filename.temp_dir "tesl-mixed-original-v1-" "" in
 Fun.protect ~finally:(fun()->remove root)(fun()->
  write(Filename.concat root "tesl.toml") "";
  write(Filename.concat root "schema/notes/v-current.tesl")(replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old);
  let entry=Filename.concat root "app.tesl" in write entry app;accepts entry app;emit 1 entry);
 with_tail_project ~on_version:emit(fun _ _ entry->emit 3 entry)
let build_programs destination =
 export_programs destination;
 (* Every source fixture has now left its scope and been removed. Only original
    emitted Go inputs remain; standalone JSON is not an input to these binaries. *)
 List.iter(fun version->
  let directory=Filename.concat destination ("v" ^ string_of_int version) in
  let rec clean path=if Sys.is_directory path then Array.iter(fun name->clean(Filename.concat path name))(Sys.readdir path)
   else if Filename.check_suffix path ".json" then Sys.remove path
   else if Filename.check_suffix path ".tesl" then fail "generated program retained Tesl source" in
  clean directory;
  let log=Filename.concat directory "build.log" in
  let command=Printf.sprintf "cd %s && timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/app > %s 2>&1"
   (Filename.quote directory)(Filename.quote log) in
  if Sys.command command<>0 then fail(Source_input.read log)) [1;2;3]
let actual_app () =
 let output=Filename.temp_dir "tesl-current-programs-" "" in
 Fun.protect ~finally:(fun()->remove output)(fun()->
  build_programs output;
  let root=match Sys.getenv_opt "TESL_REPO_ROOT" with Some root->Unix.realpath root |None->fail "TESL_REPO_ROOT required" in
  let log=Filename.concat output "postgres.log" in
  let command=Printf.sprintf "cd %s && TESL_ROW_CURRENT_PROGRAMS=%s timeout 150s go test -p 1 -race -tags tesl_migration_test -timeout 120s ./teslrt -run '^TestPgRowCurrentAdditiveSuccessorOrdinaryApp$' -count=1 -v > %s 2>&1"
   (Filename.quote(Filename.concat root "runtime/go"))(Filename.quote output)(Filename.quote log) in
  if Sys.command command<>0 then fail(Source_input.read log))
let export_source destination = with_tail_project(fun root _ entry ->
 let rec copy rel = let path=Filename.concat root rel in
  if Sys.is_directory path then Array.iter(fun n->copy(Filename.concat rel n))(Sys.readdir path)
  else write(Filename.concat destination rel)(Source_input.read path) in
 copy "";accepts entry app)
let () = match Sys.getenv_opt "TESL_MIXED_TAIL_PROGRAMS",Sys.getenv_opt "TESL_MIXED_TAIL_SOURCE" with
 |Some destination,_->build_programs destination
 |None,Some destination->export_source destination
 |None,None->run "mixed additive successor" ["prerequisite",[
 test_case "accepted additive successor is derived from settled Contract" `Quick settled_prerequisite;
 test_case "actual unchanged App requires current codec access" `Quick current_artifact;
 test_case "missing source Contract remains refused" `Quick missing_contract;
 test_case "predecessor format remains unchanged" `Quick original_format;
 test_case "current storage requires physical mode before emission" `Quick storage_only_refused];
 "native application",[test_case "original V1 transform V2 additive V3 apps" `Quick actual_app]]
