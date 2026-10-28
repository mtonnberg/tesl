open Alcotest
module S = Migration_sparse
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let repository () = Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name = Source_input.read (Filename.concat (repository ()) ("example/learn/db-revalidation/" ^ name))
let old = {|module Schema.Notes.V1 exposing [Note, tryTitle, NonEmpty]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
 if value != "" then
  Something (value ::: NonEmpty value)
 else
  Nothing
entity Note table "notes" primaryKey id { id: String, title: String ::: NonEmpty title, memo: String
 unique index [memo] as "notes_memo_unique" }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, tryTitle]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
fn tryTitle(value: String) -> Maybe String = Something value
entity Note table "notes" primaryKey id { id: String, memo: String
 unique index [memo] as "notes_memo_unique" }
|}
let migration = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration { from: Schema.Notes.V1, to: Schema.Notes.VCurrent, same: [], fixtures: [oldNote],
 entities: { Note: Migrate convert [LegacyWith title backward] } }
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: old.id, memo: old.memo })
fn backward(row: Schema.Notes.VCurrent.Note) -> value: String ::: Schema.Notes.V1.NonEmpty value =
 case Schema.Notes.V1.tryTitle row.memo of
  Nothing ->
   case Schema.Notes.V1.tryTitle "valid" of
    Nothing -> backward row
    Something fallback -> fallback
  Something title -> title
fn oldNote() -> Schema.Notes.V1.Note =
 case Schema.Notes.V1.tryTitle "valid" of
  Nothing -> oldNote()
  Something title -> Schema.Notes.V1.Note { id: "fixture", title: title, memo: "base" }
|}
let app = fixture "app.tesl"
 |> replace "order note.title asc" "order note.id asc"
 |> replace "tryTitle \"\"" "tryTitle \"blocked\""
 |> replace "  post \"/one\" -> String" "  post \"/one\" -> String\n  post \"/two\" -> String\n  put \"/touch-all\" -> String\n  put \"/empty\" -> String"
 |> replace "server NotesServer for NotesApi { health, all, one, invalid, repair, touch }" {|handler post two() -> String requires [dbWrite Note] =
  case tryTitle "valid" of
    Nothing -> "refused"
    Something title ->
      let rows = [Note { id: "a-valid", title: title, memo: "second" }]
      let _ = insertMany rows in Note
      "created"
handler put empty() -> String requires [dbWrite Note] =
  case tryTitle "" of
    Nothing -> "refused"
    Something title ->
      update note in Note
        where note.id == "one"
        set note.title = title
      "emptied"
handler put touchAll() -> String requires [dbWrite Note] =
  update note in Note
    set note.memo = "bulk"
  "touched"
server NotesServer for NotesApi { health, all, one, two, touchAll, empty, invalid, repair, touch }|}

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
 let root=Filename.temp_dir "tesl-proof-removal-source-" "" in
 Fun.protect ~finally:(fun()->remove root) (fun()->
 let save p source=let path=Filename.concat root p in write path source;accepts path source;path in
 write (Filename.concat root "tesl.toml") "";
 let current=save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old) in
 let build version =
  let app=if version="v1" then app else app
   |> replace "title: title, " ""
   |> replace "set note.title = title" "set note.memo = title" in
  let file=save "app.tesl" app in
  let out=Filename.concat destination version in
  (match Compile.compile_go_source file app with
  | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds)
  | Compile.GoSuccess artifacts -> List.iter(fun(a:Emit_go.artifact)->write(Filename.concat out a.path)a.contents) artifacts);
  let driver=Source_input.read(Filename.concat(repository())"compiler/test/fixtures/row-access/main.go")
   |> String.split_on_char '\n' |> List.filter(fun line->not(Compile.string_contains line "encoding/json" || Compile.string_contains line "TestAccessEffects"))
   |> String.concat "\n" |> replace "handled, code := rt.RunSchemaCommand"
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
 build "v2")
let native () =
 let out=Filename.temp_dir "tesl-proof-removal-app-" "" in
 Fun.protect ~finally:(fun()->remove out) (fun()->export out;
  command (Filename.concat(repository())"runtime/go") (Filename.concat out "postgres.log")
   (Printf.sprintf "TESL_ROW_PROOF_REMOVAL_PROGRAMS=%s timeout 180s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowProofRemovalActualApp$' -count=1 -v" (Filename.quote out)))
let () = run "removed proven scalar LegacyWith application" ["postgres",[
 test_case "proven old representation and atomic rollback until Contract" `Quick native]]
