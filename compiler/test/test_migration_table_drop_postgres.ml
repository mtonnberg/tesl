open Alcotest
module S = Migration_sparse
let replace a b s =
 if not (Compile.string_contains s a) then fail ("missing replacement: " ^ a);
 Str.global_replace (Str.regexp_string a) b s
let repository () = Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name = Source_input.read (Filename.concat (repository ()) ("example/learn/db-revalidation/" ^ name))
let fresh = fixture "schema/notes/v1.tesl" |> replace "Schema.Notes.V1" "Schema.Notes.VCurrent"
let old = (fresh |> replace "Schema.Notes.VCurrent" "Schema.Notes.V1"
 |> replace "exposing [Note, tryTitle]" "exposing [Note, tryTitle, Archive]") ^
 {|entity Archive table "archive" primaryKey id { id: String, body: String
 index [body] as "archive_body" }
|}
let migration = {|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration { from: Schema.Notes.V1, to: Schema.Notes.VCurrent,
 same: [], fixtures: [], entities: { Archive: Drop } }
|}
let app version =
 let source=fixture "app.tesl"
  |> replace "PostgresConfig, TcpConnection]" "PostgresConfig, TcpConnection, MigrationConfig, MigrationTopology(..)]"
  |> replace "PostgresConfig { namespace:" "PostgresConfig { migrations: MigrationConfig { topology: Worker, controlOwner: \"owner\", requestRole: \"request\", workerRole: \"worker\", ddlConnection: \"\" }, namespace:" in
 if version<>"v1" then source else source
 |> replace "exposing [Note, tryTitle]" "exposing [Note, tryTitle, Archive]"
 |> replace "  get \"/all\" -> List Note" "  get \"/all\" -> List Note\n  get \"/archive\" -> List Archive\n  post \"/archive\" -> String\n  put \"/archive\" -> String"
 |> replace "server NotesServer for NotesApi { health, all, one, invalid, repair, touch }" {|handler get archive() -> List Archive requires [dbRead Archive] =
 select row from Archive order row.id asc
handler post addArchive() -> String requires [dbWrite Archive] =
 let rows = [Archive { id: "old", body: "retained" }]
 let _ = insertMany rows in Archive
 "created"
handler put editArchive() -> String requires [dbWrite Archive] =
 update row in Archive
   where row.id == "old"
   set row.body = "edited"
 "edited"
server NotesServer for NotesApi { health, all, archive, addArchive, editArchive, one, invalid, repair, touch }|}
 |> replace "[dbRead Note, dbWrite Note, envRead]" "[dbRead Note, dbWrite Note, dbRead Archive, dbWrite Archive, envRead]"
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun out -> output_string out s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun(e:S.error)->e.message) es))
let accepts path source =
 let errors=(Compile.agent_context_result_source path source).diagnostics |> List.filter(fun(d:Compile.diagnostic)->d.severity="error") in
 if errors<>[] then fail (Compile.diagnostics_to_json errors)
let command directory log text =
 if Sys.command (Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory) text (Filename.quote log))<>0 then
  fail (text ^ "\n" ^ Source_input.read log)
let export destination =
 let root=Filename.temp_dir "tesl-table-drop-source-" "" in
 Fun.protect ~finally:(fun()->remove root) (fun()->
 let save p source=let path=Filename.concat root p in write path source;accepts path source;path in
 write (Filename.concat root "tesl.toml") "";
 let current=save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old) in
 let build version =
  let app=app version in
  let file=save "app.tesl" app in
  let out=Filename.concat destination version in
  (match Compile.compile_go_source file app with
  | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds)
  | Compile.GoSuccess artifacts -> List.iter(fun(a:Emit_go.artifact)->write(Filename.concat out a.path)a.contents) artifacts);
  let driver=Source_input.read(Filename.concat(repository())"compiler/test/fixtures/row-access/main.go")
   |> String.split_on_char '\n' |> List.filter(fun line->not(Compile.string_contains line "encoding/json" || Compile.string_contains line "TestAccessEffects"))
   |> String.concat "\n"
   |> replace "if err := rt.PreflightApplicationDatabases"
      "if os.Args[1] == \"embedded\" { app.MainDatabase.Config.MigrationTopology=\"Embedded\"; app.MainDatabase.Config.RequestRole=\"\"; app.MainDatabase.Config.WorkerRole=\"\" }\n if err := rt.PreflightApplicationDatabases"
   |> replace "handled, code := rt.RunSchemaCommand"
      "if os.Args[1] == \"contract\" { args=[]string{\"--schema\",\"contract\",\"V2\",\"--json\"} }\n handled, code := rt.RunSchemaCommand" in
  write(Filename.concat out "cmd/access-test/main.go")driver;
  command out (Filename.concat out "build.log") "timeout 120s go build -p 1 -race -tags tesl_migration_test -o app ./cmd/access-test" in
 build "v1";
 ignore(save "schema/notes/v1.tesl" old);ignore(save "schema/notes/v-current.tesl" fresh);
 let path=save "migrations/notes/v2.tesl" migration in
 let abi=Result.get_ok(Migration_abi.current()) in
 let load file=match Migration_inventory.load_with_compatibility
  ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi)) ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
  | Ok x->x | Error e->fail e.message in
 let seal file=match Migration_seal.create ~project_root:root (load file) with Ok x->x|Error e->fail e.message in
 let header=get(Migration_header.create ~previous:(seal(Filename.concat root "schema/notes/v1.tesl")) ~current:(seal current)) in
 write path (Migration_header.encode header ^ migration);
 let source=Source_input.read path in
 let ast=match Parser.parse_module path source with Ok x->x|Err e->fail e.msg in
 let declaration=Option.get(get(Migration_declaration.check ~compiler_abi:(Migration_abi.id abi) ~source ast)) in
 let before,after=Migration_sparse.inventories(Migration_declaration.coverage declaration) in
 let history=get(Migration_row_history.check ~schemas:[before;after] ~edges:[declaration]) in
 let plan=get(Migration_retained_storage.plan history) in
 ignore(save "migrations/notes/v2-contract.tesl" (get(Migration_contract.source ~plan ~version:2)));
 build "v2";
 (* Freeze through the public generator so the successor replays the same sealed
    V2 Drop and reviewed Contract, rather than a hand-assembled history. *)
 let next=match Migration_generate.start_with_compatibility
   ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes"
   ~version:2 ~documents:[] with
  | Ok preview -> preview
  | Error errors -> fail (String.concat "\n" (List.map (fun(e:Migration_generate.error)->e.path ^ ": " ^ e.message) errors)) in
 (match Migration_manifest.verify_disk next.manifest with Ok () -> () | Error _ -> fail "stale successor source manifest");
 List.iter (fun(e:Migration_manifest.edit)->write e.path e.after;
   ignore(Compile.agent_context_result_source e.path e.after)) (Migration_manifest.edits next.manifest);
 List.iter (fun(e:Migration_manifest.edit)->accepts e.path e.after) (Migration_manifest.edits next.manifest);
 build "v3")
let native () =
 let out=Filename.temp_dir "tesl-table-drop-app-" "" in
 Fun.protect ~finally:(fun()->remove out) (fun()->export out;
  command (Filename.concat(repository())"runtime/go") (Filename.concat out "postgres.log")
   (Printf.sprintf "TESL_ROW_TABLE_DROP_PROGRAMS=%s timeout 240s go test -p 1 -race -tags tesl_migration_test -timeout 210s ./teslrt -run '^TestPgRowTableDropActualApp$' -count=1 -v" (Filename.quote out)))
let () = match Sys.getenv_opt "TESL_TABLE_DROP_EXPORT" with
 | Some destination -> export destination
 | None -> run "whole table retirement application" ["postgres",[
   test_case "old overlap and physical Drop with exact Contract retry" `Quick native]]
