open Alcotest
module S = Migration_sparse
let replace a b s =
 if not (Compile.string_contains s a) then fail ("fixture replacement target missing: " ^ a);
 Str.global_replace (Str.regexp_string a) b s
let repository () = Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name = Source_input.read (Filename.concat (repository ()) ("example/learn/db-proof-change/" ^ name))
let old = fixture "schema/notes/v1.tesl"
let fresh = fixture "schema/notes/v-current.tesl"
(* Variants reseal their own checked schemas below. Keep the lesson's exact
   migration body and tests; no copied migration implementation lives here. *)
let migration = fixture "migrations/notes/v2.tesl"
 |> String.split_on_char '\n'
 |> List.filter (fun line -> not (String.starts_with ~prefix:"# tesl:" line))
 |> String.concat "\n"
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
let export ?(delete_rows=false) ?(no_reverse=false) ~weaken ~remove_proof destination =
 let app=app |> replace "  put \"/touch\" -> String" "  put \"/touch\" -> String\n  put \"/mixed\" -> String\n  put \"/obsolete\" -> String" |>
   replace "touchAll, empty, invalid, repair, touch }" "touchAll, empty, invalid, repair, touch, mixed, obsolete }" in
 let app=app ^ {|
handler put mixed() -> String requires [dbWrite Note] =
  case tryTitle "blocked" of
    Nothing -> "refused"
    Something title ->
      transaction {
        update note in Note
          where note.id == "a-valid"
          set note.memo = "must roll back"
        update note in Note
          where note.id == "one"
          set note.title = title
        "updated"
      }
handler put obsolete() -> String requires [dbWrite Note] =
  case tryTitle "obsolete" of
    Nothing -> "refused"
    Something title ->
      update note in Note
        where note.id == "one"
        set note.title = title
      "obsolete"
|}in
 let migration=if no_reverse then replace "Schema.Notes.V1.tryTitle row.title" "Nothing" migration else migration in
 let migration=if not delete_rows then migration else migration
   |> replace "Migrated" "RowChange" |> replace "Row " "KeepRow " |> replace "Reject " "RejectRow "
   |> replace "        RejectRow reason ->" "        DeleteRow reason -> expect False\n        RejectRow reason ->"
   |> replace "case Schema.Notes.VCurrent.tryTitle old.title of"
      "  if old.title == \"obsolete\" then\n    DeleteRow \"obsolete title\"\n  else\n    case Schema.Notes.VCurrent.tryTitle old.title of"
   |> replace "  Nothing -> RejectRow" "      Nothing -> RejectRow"
   |> replace "  Something title -> KeepRow" "      Something title -> KeepRow"in
 let old = if weaken then old |> replace "  Something (value ::: NonEmpty value)" "  if value == \"blocked\" then\n    Nothing\n  else\n    Something (value ::: NonEmpty value)" else old in
 let fresh = if weaken then fresh |> replace "  if value == \"blocked\" then\n    Nothing\n  else\n    Something (value ::: Allowed value)" "  Something (value ::: Allowed value)" else fresh in
 let fresh = if remove_proof then {|module Schema.Notes.VCurrent exposing [Note, tryTitle]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
fn tryTitle(value: String) -> Maybe String = Something value
entity Note table "notes" primaryKey id { id: String, title: String @column("title__v2"), memo: String }
|} else fresh in
 let root=Filename.temp_dir "tesl-proof-retype-source-" "" in
 Fun.protect ~finally:(fun()->remove root) (fun()->
 let save p source=let path=Filename.concat root p in write path source;accepts path source;path in
 write (Filename.concat root "tesl.toml") "";
 let current=save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old) in
 let build version =
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
let native ?(delete_rows=false) ?(no_reverse=false) weaken remove_proof () =
 let out=Filename.temp_dir "tesl-proof-retype-app-" "" in
 Fun.protect ~finally:(fun()->remove out) (fun()->export ~delete_rows ~no_reverse ~weaken ~remove_proof out;
  command (Filename.concat(repository())"runtime/go") (Filename.concat out "postgres.log")
    (Printf.sprintf "TESL_ROW_PROOF_REMOVED=%s TESL_ROW_PROOF_RETYPE_PROGRAMS=%s timeout 180s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^%s$' -count=1 -v" (if remove_proof then "1" else "0") (Filename.quote out) (if no_reverse then "TestPgRowOptionalReverseBackfillActualApp" else if delete_rows then "TestPgRowDeleteOutcomeActualApp" else if weaken then "TestPgRowProofWeakenActualApp" else "TestPgRowProofRetypeActualApp")))
let () = run "changed proven primitive Retype application" ["postgres",[
 test_case "old proof to stronger proof with reverse establish" `Quick (native false false);
 test_case "weaker proof refuses incompatible writes until retirement" `Quick (native true false);
 test_case "removing proof retains atomic optional write-back" `Quick (native true true);
 test_case "explicit deletion and old-writer races use checked Worker CAS" `Quick (native ~delete_rows:true false false);
 test_case "backfill preserves existing old values when write-back refuses" `Quick (native ~no_reverse:true false false)]]
