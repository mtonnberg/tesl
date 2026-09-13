open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note, makeNote]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String, memo: String }
fn makeNote(id: String) -> Note = Note { id: id, author: "writer", title: id, memo: "base" }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, makeNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Float exposing [Float]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { memo: String, id: String, owner: String, title: String, count: Int, label: String, enabled: Bool, ratio: Float, extra: Maybe String }
fn makeNote(id: String) -> Note = Note { id: id, owner: "writer", title: id, count: 9, memo: "base", label: "new", enabled: False, ratio: 1.0, extra: Nothing }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [Bool(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: []
 fixtures: []
 entities: { Note: Derived [Rename author owner, Default count 123456789012345678901234567890, Default label "derived", Default enabled True, Default ratio -0.0] }
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
let app = {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.App exposing [App]
import Tesl.Env exposing [envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent exposing [Note, makeNote]
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig { namespace: "notes", dbName: "unused", user: "unused", password: "unused", connection: TcpConnection { host: "127.0.0.1", port: 5432 } })
}
api NotesApi {
 get "/health" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 post "/three" -> String
 put "/one" -> String
}
handler get health() -> String = "ready"
handler get all() -> List Note requires [dbRead Note] = select note from Note order note.id asc
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "inserted"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "inserted"
handler post addThree() -> String requires [dbWrite Note] =
 let rows = [makeNote "three"]
 let _ = insertMany rows in Note
 "inserted"
handler put editOne() -> String requires [dbWrite Note] =
 update note in Note
  where note.id == "one"
  set note.memo = "edited"
 "updated"
server NotesServer for NotesApi { health, all, addOne, addTwo, addThree, editOne }
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
 write path (Migration_header.encode header ^ Source_input.read path)
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


let artifact path all=(List.find (fun (a:Emit_go.artifact)->a.path=path) all).contents
let get=function Ok v->v | Error es->fail(String.concat "\n" (List.map(fun(e:S.error)->e.message)es))
let source_metadata ()=project (fun root save path ->
 seal_edge root path;let file=save "app.tesl" app in accepts file app;
 let ast=match Parser.parse_module path (Source_input.read path) with Ok x->x|Err e->fail e.msg in
 let abi=Result.get_ok(Migration_abi.current()) in
 let d=Option.get(get(D.check ~compiler_abi:(Migration_abi.id abi) ~source:(Source_input.read path) ast)) in
 let t=Option.get(D.transforms d) in
 check bool "no fabricated source callback" true ((List.hd(T.rows t)).function_binding=None);
 let all=emit ~physical:true file in
 let wire=artifact "row-transform-history.json" all in
 check bool "canonical derived mode" true (Compile.string_contains wire "\"mode\":\"derived\"");
 check bool "no fabricated callback bridge" false (List.exists(fun(a:Emit_go.artifact)->Compile.string_contains a.path "TeslCompiledRowCallback")all);
 match Compile.compile_go_source file app with
 | Compile.GoFailure _ -> () | _ -> fail "Derived gained public execution before activation")
let refusals ()=List.iter(fun(label,changed,code)->project(fun root save path->
 write path changed;
 let ds=errors path changed in
 check bool (label ^ "\n" ^ describe ds) true (List.exists(fun(d:Compile.diagnostic)->d.code=code)ds);
 ignore root;ignore save)) [
 "missing default",replace ", Default count 123456789012345678901234567890" "" source,"MIG016";
 "wrong primitive default",replace "Default count 123456789012345678901234567890" "Default count \"bad\"" source,"MIG022";
 "PK rename",replace "Rename author owner" "Rename id owner" source,"MIG009"]
let nominal_mapping_boundary ()=
 let schema revision field = Printf.sprintf {|module Schema.Notes.%s exposing [Note, Key]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Key { value: String }
codec Key {
 toJson { value -> "key" with_codec stringCodec }
 fromJson [ { value <- "key" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: Key, %s: String }
|} revision field in
 project ~before:(schema "V1" "title") ~after:(schema "VCurrent" "heading") (fun root save path ->
 let edge={|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: [Same Schema.Notes.V1.Key Schema.Notes.VCurrent.Key]
 fixtures: []
 entities: { Note: Derived [Rename title heading] }
}
|} in
 write path edge;accepts path edge;seal_edge root path;
 let database=String.sub app 0 (Str.search_forward (Str.regexp_string "api NotesApi") app 0)
  |> replace "exposing [Note, makeNote]" "exposing [Note]" in
 let file=save "app.tesl" database in accepts file database;
 match Compile.compile_row_source_artifacts ~storage:true ~physical:true file database with
 | Compile.GoSuccess artifacts ->
   check bool "separate mapping adapter" true(List.exists(fun(a:Emit_go.artifact)->Compile.string_contains a.contents "func TeslCompiledNominalMapping")artifacts);
   check bool "no fabricated source callback" false(List.exists(fun(a:Emit_go.artifact)->Compile.string_contains a.path "TeslCompiledRowCallback")artifacts)
 | Compile.GoFailure ds->fail(describe ds))
let export destination=project(fun root save path->
 seal_edge root path;let edge=Source_input.read path in
 let build version =
  let file=save "app.tesl" app in accepts file app;
  let out=Filename.concat destination version in
  List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then write(Filename.concat out a.path)a.contents)(emit ~physical:true file);
  if version="v2" then List.iter (fun (name,target) ->
   write (Filename.concat out target) (Source_input.read (Filename.concat (repository ()) ("compiler/test/fixtures/row-derived/" ^ name))))
   ["wire_test.go","internal/teslrt/derived_wire_test.go";"adapter_test.go","internal/teslmodapp/derived_adapter_test.go"];
  let driver=fixture "main.go" |> String.split_on_char '\n' |> List.filter (fun line -> not (Compile.string_contains line "encoding/json" || Compile.string_contains line "TestAccessEffects")) |> String.concat "\n" |> replace "handled, code := rt.RunSchemaCommand" "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V2\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" in
  write(Filename.concat out "cmd/access-test/main.go")driver;
  command out (Filename.concat out "build.log") "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test" in
 remove path;remove(Filename.concat root "schema/notes/v1.tesl");
 ignore(save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old));build "v1";
 ignore(save "schema/notes/v1.tesl" old);ignore(save "schema/notes/v-current.tesl" fresh);write path edge;
 install_contract root path;build "v2")
let native_companion ()=
 let out=Filename.temp_dir "tesl-row-derived-wire-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_DERIVED_TEST"=None then remove out)(fun()->
 export out;
 command (Filename.concat out "v2") (Filename.concat out "typed.log") "timeout 120s go test -p 1 -race -tags tesl_migration_test -timeout 90s ./internal/teslmodapp ./internal/teslrt -run '^TestDerived' -count=1 -v")
let native_legacy ()=
 let out=Filename.temp_dir "tesl-derived-legacy-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_DERIVED_TEST"=None then remove out)(fun()->
 let before=old |> replace "[Note, makeNote]" "[Note, makeNote, Metadata]"
  |> replace "entity Note" {|import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
entity Note|}
  |> replace "memo: String }" "memo: String, metadata: Metadata }"
  |> replace "memo: \"base\" }" "memo: \"base\", metadata: Metadata { text: id } }" in
 project ~before (fun root save path ->
 let edge=source |> replace "Rename author owner" "Legacy author \"former\", LegacyWith metadata toOld, Default owner \"new-owner\"" in
 let edge=edge ^ "\nfn toOld(row: Schema.Notes.VCurrent.Note) -> Schema.Notes.V1.Metadata = Schema.Notes.V1.Metadata { text: row.memo }\n" in
 write path edge;accepts path edge;seal_edge root path;
 let database=String.sub app 0 (Str.search_forward (Str.regexp_string "api NotesApi") app 0) in
 let file=save "app.tesl" database in accepts file database;
 List.iter(fun(a:Emit_go.artifact)->if not(Filename.check_suffix a.path ".json")then write(Filename.concat out a.path)a.contents)(emit ~physical:true file);
 List.iter(fun(name,target)->write(Filename.concat out target)(Source_input.read(Filename.concat(repository())("compiler/test/fixtures/row-derived/"^name))))
  ["legacy_wire_test.go","internal/teslrt/derived_legacy_wire_test.go";"legacy_adapter_test.go","internal/teslmodapp/derived_legacy_adapter_test.go"]);
 command out (Filename.concat out "native.log") "timeout 120s go test -p 1 -race -tags tesl_migration_test -timeout 90s ./internal/teslmodapp ./internal/teslrt -run '^TestDerivedLegacy' -count=1 -v")
let native ()=
 let out=Filename.temp_dir "tesl-row-derived-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_DERIVED_TEST"=None then remove out)(fun()->
 export out;
 command (Filename.concat(repository())"runtime/go") (Filename.concat out "postgres.log")
 (Printf.sprintf "TESL_ROW_DERIVED_PROGRAMS=%s timeout 150s go test -p 1 -race -tags tesl_migration_test -timeout 120s ./teslrt -run '^TestPgRowDerivedActualApp$' -count=1 -v" (Filename.quote out)))
let ()=match Sys.getenv_opt "TESL_ROW_DERIVED_EXPORT" with
 | Some root->export root
 | None->run "checked Derived row adapters" ["derived",[
 test_case "checked source generates adapter without user callback" `Quick source_metadata;
 test_case "invalid mappings retain compiler refusal" `Quick refusals;
 test_case "nominal Derived uses separate checked mapping certificate" `Quick nominal_mapping_boundary;
 test_case "actual typed adapter and rehashed closed-mode negatives" `Quick native_companion;
 test_case "Derived Legacy and LegacyWith old codec composition" `Quick native_legacy;
 test_case "actual unchanged App Derived worker and Contract" `Quick native]]
