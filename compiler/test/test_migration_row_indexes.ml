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
  post "/text" -> String
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
handler post addText() -> String requires [dbWrite Note] =
  let rows = [makeNote "", makeNote "A", makeNote "a", makeNote "a ", makeNote "é", makeNote "é"]
  let _ = insertMany rows in Note
  "created"
server NotesServer for NotesApi { health, all, addOne, addTwo, addText, edit }
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
let export ?(stages=false) ?(guards=false) ?(cancelled=false) output =
 let schema version =
  let text=schema version in
   let text=if not stages then text else
   text |> replace "import Tesl.Maybe exposing" "import Tesl.Int32 exposing [Int32]\nimport Tesl.Maybe exposing"
    |> replace "title: \"hello\"" "title: id"
    |> replace "active: Bool" "active: Bool, amount: Maybe Int32 @db(integer), optionalText: Maybe String @db(text)"
    |> replace "fn makeNote" "fn optionalValue(id: String) -> Maybe String =\n if id == \"one\" || id == \"two\" then\n  Nothing\n else\n  Something id\nfn makeNote"
    |> replace "active: False" "active: False, amount: Nothing, optionalText: optionalValue id"
     |> replace "index [active] as \"active_lookup\"" "staging unique index [active] as \"active_lookup\"\n staging unique index [amount] as \"amount_lookup\"\n staging unique index [title] as \"title_lookup\"\n staging unique index [optionalText] as \"optional_text_lookup\"" in
   if not (guards || cancelled) then text else
    let text=text |> replace "active: Bool" "active: Maybe Bool" |> replace "active: False" "active: Nothing"
     |> replace "amount: Maybe Int32 @db(integer)" "amount: Maybe Int32 @db(integer), bigAmount: Maybe Int32 @db(bigint)"
     |> replace "amount: Nothing" "amount: Nothing, bigAmount: Nothing"
     |> replace "staging unique index [amount] as \"amount_lookup\"" "staging unique index [amount] as \"amount_lookup\"\n staging unique index [bigAmount] as \"big_amount_lookup\""
     |> replace "index [token] as \"token_lookup\"" "" in
    if version<3 then text else if cancelled then
     String.split_on_char '\n' text |> List.filter(fun line->not(String.starts_with ~prefix:"staging unique index" (String.trim line))) |> String.concat "\n"
    else text |> replace "staging unique index" "unique index" |> replace "_lookup\"" "_unique\"" in
 let root=Filename.temp_dir "tesl-row-index-source-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
 let file p=Filename.concat root p in
  let application=if guards || cancelled then app |> replace "set note.active = True" "set note.title = \"edited\""
   |> replace "import Tesl.Prelude exposing [String, List, Bool(..)]" "import Tesl.Prelude exposing [String, List, Bool(..)]\nimport Tesl.Maybe exposing [Maybe(..)]" else app in
  write (file "tesl.toml") ""; write (file "app.tesl") application;
 let current=file "schema/notes/v-current.tesl" in
 let build version =
  accepts (file "app.tesl");
   let artifacts=match Compile.compile_go_file (file "app.tesl") with
   | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  let destination=Filename.concat output version in
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then write (Filename.concat destination a.path) a.contents) artifacts;
   if version="v2" && not stages then (
   let repo=Sys.getenv "TESL_REPO_ROOT" in
   List.iter (fun (source,target) -> write (Filename.concat destination target) (Source_input.read (Filename.concat repo ("compiler/test/fixtures/row-index/"^source))))
    ["bridge.go","internal/teslrt/index_probe_testbuild.go";"probe.go","cmd/index-probe/main.go"]);
  check bool "ordinary main emitted" true (Sys.file_exists (Filename.concat destination "cmd/app/main.go"));
  let command=Printf.sprintf "cd %s && timeout 120s go build -race -tags tesl_migration_test -o app ./cmd/app >build.log 2>&1" (Filename.quote destination) in
  if Sys.command command<>0 then fail (Source_input.read (Filename.concat destination "build.log"));
   if version="v2" && not stages then (
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
   build "v3";
   if guards then begin
    write (file "app.tesl") (application ^ {|
fn forbidden(note: Note) -> String requires [dbWrite Note] =
 let _ = upsert Note { id: note.id, title: note.title, active: note.active, amount: note.amount, bigAmount: note.bigAmount, optionalText: note.optionalText, token: note.token } onConflict [title] doUpdate [title]
 "done"
|});
    (match Compile.compile_go_file (file "app.tesl") with
     | Compile.GoSuccess _ -> fail "guarded V3 exposed onConflict"
     | Compile.GoFailure ds -> check bool ("V3 reliance refused: " ^ describe ds) true
       (List.exists(fun (d:Compile.diagnostic)->d.code="MIG030") ds));
    write (file "app.tesl") application;
    let contract_source={|module Schema.Notes.Migrate.V3Contract exposing [contract]
import Tesl.Migration exposing [Contract, Promote(..)]
import Schema.Notes.Migrate.V3
contract = Contract {
 of: Schema.Notes.Migrate.V3
 drops: []
 tighten: []
 promote: [PromoteStage Note [active], PromoteStage Note [amount], PromoteStage Note [bigAmount], PromoteStage Note [title], PromoteStage Note [optionalText]]
}
|} in
    let contract_file=file "migrations/notes/v3-contract.tesl" in
    write contract_file contract_source;
    build "v3-contract";
    let v3=file "schema/notes/v3.tesl" in
    write v3 (schema 3 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V3");
    edge root (file "migrations/notes/v3.tesl") v2 v3 (additive 3 "Schema.Notes.V3") true;
    let header=get(Migration_header.create ~previous:(seal root v3) ~current:(seal root current)) in
    write (file "migrations/notes/v4.tesl") (Migration_header.encode header ^ (additive 4 "Schema.Notes.VCurrent" |> replace "{ Note: Additive [] }" "{}"));
    Sys.remove contract_file;
    (match Compile.compile_go_file (file "app.tesl") with
     | Compile.GoSuccess _ -> fail "unguarded V4 reliance compiled"
     | Compile.GoFailure ds -> check bool ("V4 requires enforcement: " ^ describe ds) true
       (List.exists(fun (d:Compile.diagnostic)->d.code="MIG030"||d.code="MIG013") ds));
    write contract_file contract_source;
    write (file "app.tesl") (application |> replace "let rows = [makeNote \"two\"]\n let _ = insertMany rows in Note"
     "let note = makeNote \"two\"\n let _ = upsert Note { id: note.id, title: note.title, active: note.active, amount: note.amount, bigAmount: note.bigAmount, optionalText: note.optionalText, token: note.token } onConflict [title] doUpdate [token]");
    build "v4";
    write (file "app.tesl") application;
    write current (schema 3 |> replace "unique index [title] as \"title_unique\"" "");
    edge root (file "migrations/notes/v4.tesl") v3 current (additive 4 "Schema.Notes.VCurrent") false;
    (match Compile.compile_go_file (file "app.tesl") with
     | Compile.GoSuccess _ -> fail "guarded/enforced obligation vanished by source omission"
     | Compile.GoFailure ds -> check bool ("active stage cannot be cancelled: " ^ describe ds) true
       (List.exists(fun(d:Compile.diagnostic)->d.code="MIG016"||d.code="MIG030")ds))
   end;
   if cancelled then begin
    let v3=file "schema/notes/v3.tesl" in
    write v3 (schema 3 |> replace "Schema.Notes.VCurrent" "Schema.Notes.V3");
    edge root (file "migrations/notes/v3.tesl") v2 v3 (additive 3 "Schema.Notes.V3") true;
    write current (schema 3 |> replace "token: Maybe String" "token: Maybe String, later: Maybe String" |> replace "token: Something id" "token: Something id, later: Nothing");
    edge root (file "migrations/notes/v4.tesl") v3 current (additive 4 "Schema.Notes.VCurrent") false;
    build "v4"
   end;
   if stages && not guards && not cancelled then List.iter (fun (decision,edit) ->
    write current (edit (schema 3));
    let header=get (Migration_header.create ~previous:(seal root v2) ~current:(seal root current)) in
    write (file "migrations/notes/v3.tesl")
      (Migration_header.encode header ^ additive 3 "Schema.Notes.VCurrent");
    match Compile.compile_go_file (file "app.tesl") with
    | Compile.GoSuccess _ -> fail ("unreviewed stage " ^ decision ^ " compiled")
    | Compile.GoFailure ds -> check bool (decision ^ " requires its protected protocol: " ^ describe ds) true
        (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG030") ds))
     ["promotion",replace "staging unique index [active]" "unique index [active]"])
let compilation ?(stages=false) ?(guards=false) ?(cancelled=false) () =
 let output=Filename.temp_dir "tesl-row-index-programs-" "" in
 Fun.protect ~finally:(fun () -> remove output) (fun () ->
    export ~stages ~guards ~cancelled output;
  let repo=Unix.realpath (Sys.getenv "TESL_REPO_ROOT") in
  let log=Filename.concat output "postgres.log" in
    let budget=if guards then 600 else if cancelled then 300 else if stages then 150 else 120 in
   let command=Printf.sprintf "cd %s && %s=%s timeout %ds go test -p 2 -race -tags tesl_migration_test -timeout %ds ./teslrt -run %s -count=1 -v > %s 2>&1"
    (Filename.quote (Filename.concat repo "runtime/go"))
     (if guards then "TESL_STAGE_GUARD_PROGRAMS" else if cancelled then "TESL_STAGE_CANCELLATION_PROGRAMS" else if stages then "TESL_STAGE_PREPARATION_PROGRAMS" else "TESL_ROW_INDEX_PROGRAMS")
     (Filename.quote output) (budget+30) budget (Filename.quote (if guards then "^TestPgStageGuard" else if cancelled then "^TestPgStageCancel" else if stages then "^TestPgStagePreparation" else "^TestPgRowIndex")) (Filename.quote log) in
  if Sys.command command<>0 then fail (Source_input.read log))
let () = match Sys.getenv_opt "TESL_STAGE_GUARD_EXPORT" with
 | Some output -> export ~stages:true ~guards:true output
 | None -> match Sys.getenv_opt "TESL_STAGE_CANCELLATION_EXPORT" with
 | Some output -> export ~stages:true ~cancelled:true output
 | None -> match Sys.getenv_opt "TESL_STAGE_PREPARATION_EXPORT",Sys.getenv_opt "TESL_ROW_INDEX_EXPORT" with
  | Some output,_ -> export ~stages:true output
  | _,Some output -> export output
  | None,None -> run "format5 concurrent indexes" ["native application",[
    test_case "original index workers, readiness and atomic registration" `Quick (compilation ~stages:false);
     test_case "sealed stage preparation and carry" `Quick (compilation ~stages:true);
     test_case "sealed guarded promotion window and enforcement" `Quick (compilation ~stages:true ~guards:true);
     test_case "reviewed pending-stage cancellation" `Quick (compilation ~stages:true ~cancelled:true)]]
