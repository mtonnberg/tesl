open Alcotest
module S = Migration_sparse
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let repository () = Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name = Source_input.read (Filename.concat (repository ()) ("example/learn/db-revalidation/" ^ name))
let old = fixture "schema/notes/v1.tesl"
let fresh = fixture "schema/notes/v-current.tesl"
let migration =
 let source=fixture "migrations/notes/v2.tesl" in
 let start=Str.search_forward (Str.regexp "^module ") source 0 in
 String.sub source start (String.length source-start)
let app = fixture "app.tesl"
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
let export ?(legacy=false) ?(strengthening=false) destination =
  let proof_schema={|module Schema.Notes.VCurrent exposing [Note, tryTitle, tryPrior, Prior, NonEmpty]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact Prior (value: String)
fact NonEmpty (value: String)
establish tryPrior(value: String) -> Maybe (v: String ::: Prior v) =
  if value != "old-forbidden" then
    Something (value ::: Prior value)
  else
    Nothing
establish tryTitle(value: String) -> Maybe (v: String ::: Prior v && NonEmpty v) =
  if (value != "old-forbidden") && (value != "") then
    Something (value ::: Prior value && NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, title: String ::: Prior title, memo: String }
|} in
  let old=if strengthening then replace "Schema.Notes.VCurrent" "Schema.Notes.V1" proof_schema else old in
  let fresh=if strengthening then replace "title: String ::: Prior title" "title: String ::: Prior title && NonEmpty title" proof_schema else fresh in
  let migration=if strengthening then {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: [Same Schema.Notes.V1.Prior Schema.Notes.VCurrent.Prior, Same Schema.Notes.V1.NonEmpty Schema.Notes.VCurrent.NonEmpty]
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Revalidate title Schema.Notes.VCurrent.tryTitle] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 case Schema.Notes.VCurrent.tryTitle old.title of
  Nothing -> Reject "empty title"
  Something title -> Row (Schema.Notes.VCurrent.Note { id: old.id, title: title, memo: old.memo })
fn oldNote() -> Maybe Schema.Notes.V1.Note =
 case Schema.Notes.V1.tryPrior "retained" of
  Nothing -> Nothing
  Something title -> Something (Schema.Notes.V1.Note { id: "one", title: title, memo: "base" })
|} else migration in
 let old=if legacy then replace "memo: String }" "memo: String, obsolete: String }" old else old in
 let migration=if legacy then migration
  |> replace "[Revalidate title Schema.Notes.VCurrent.tryTitle]" "[Revalidate title Schema.Notes.VCurrent.tryTitle, Legacy obsolete \"retired\"]"
  |> replace "memo: \"base\" }" "memo: \"base\", obsolete: \"original\" }"
  |> replace "memo: \"retained\" }" "memo: \"retained\", obsolete: \"original\" }" else migration in
 let root=Filename.temp_dir "tesl-revalidate-source-" "" in
 Fun.protect ~finally:(fun()->remove root) (fun()->
 let save p source=let path=Filename.concat root p in write path source;accepts path source;path in
 write (Filename.concat root "tesl.toml") "";
 let current=save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old) in
  let build version =
   let app=if strengthening && version="v1" then replace "tryTitle" "tryPrior" app else app in
  let app=if legacy && version="v1" then app
    |> replace "memo: \"base\" }" "memo: \"base\", obsolete: \"original\" }"
    |> replace "set note.memo = \"touched\"" "set note.memo = \"touched\"\n    set note.obsolete = \"changed-by-old\"" else app in
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
let native ?(strengthening=false) legacy () =
 let out=Filename.temp_dir "tesl-revalidate-app-" "" in
  Fun.protect ~finally:(fun()->remove out) (fun()->export ~legacy ~strengthening out;
  command (Filename.concat(repository())"runtime/go") (Filename.concat out "postgres.log")
   (Printf.sprintf "TESL_ROW_REVALIDATE_LEGACY=%s TESL_ROW_REVALIDATE_PROGRAMS=%s timeout 180s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowRevalidateActualApp$' -count=1 -v" (if legacy then "1" else "0") (Filename.quote out)))
let () = match Sys.getenv_opt "TESL_ROW_REVALIDATE_EXPORT" with
 | Some destination -> export destination
 | None -> run "Revalidate PostgreSQL application" ["postgres",[
    test_case "old writers reject repair and Contract" `Quick (native false);
     test_case "Revalidate and Legacy reverse writes" `Quick (native true);
     test_case "same-column proof strengthening retains exact old proof" `Quick (native ~strengthening:true false);
     test_case "same-column strengthening and removed-field reverse writes" `Quick (native ~strengthening:true true)]]
