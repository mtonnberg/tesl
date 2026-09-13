open Alcotest
module C = Migration_canonical
module D = Migration_declaration
module S = Migration_sparse
module H = Migration_row_history
module R = Migration_retained_storage
module L = Migration_transform_link

let get = function
 | Ok value -> value
 | Error errors -> fail (String.concat "\n" (List.map
     (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let rec mkdir path = if not (Sys.file_exists path) then
 (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let write path source = mkdir (Filename.dirname path);
 Out_channel.with_open_bin path (fun channel -> output_string channel source)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
 (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
  Unix.rmdir path) else Sys.remove path

let schema root extra = Printf.sprintf {|module %s exposing [Note, Task]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, title: String%s }
entity Task table "tasks" primaryKey id { id: String, title: String%s }
|} root extra extra

let migration task_value = Printf.sprintf {|module Schema.Work.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migration, Entity(..), Migrated(..)]
import Schema.Work.V1
import Schema.Work.VCurrent
migration = Migration {
  from: Schema.Work.V1, to: Schema.Work.VCurrent, same: [],
  fixtures: [oldNote, oldTask],
  entities: { Note: Migrate convertNote [], Task: Migrate convertTask [] }
}
fn convertNote(old: Schema.Work.V1.Note) -> Migrated Schema.Work.VCurrent.Note =
  Row (Schema.Work.VCurrent.Note { id: old.id, title: old.title, count: 7 })
fn convertTask(old: Schema.Work.V1.Task) -> Migrated Schema.Work.VCurrent.Task =
  Row (Schema.Work.VCurrent.Task { id: old.id, title: old.title, count: %d })
fn oldNote() -> Schema.Work.V1.Note = Schema.Work.V1.Note { id: "note", title: "note" }
fn oldTask() -> Schema.Work.V1.Task = Schema.Work.V1.Task { id: "task", title: "task" }
|} task_value

module Contract = Migration_contract
let replace text old fresh = Str.global_replace (Str.regexp_string old) fresh text
let with_plan ?(old_source=schema "Schema.Work.V1" "") ?(new_source=schema "Schema.Work.VCurrent" ", count: Int") ?(migration_source=migration 11) run =
 let root=Filename.temp_dir "tesl-contract-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  write (Filename.concat root "tesl.toml") "";
  let before=Filename.concat root "schema/work/v1.tesl" in
  let after=Filename.concat root "schema/work/v-current.tesl" in
  let edge=Filename.concat root "migrations/work/v2.tesl" in
  write before old_source;
  write after new_source;
  let abi=match Migration_abi.current () with Ok a -> Migration_abi.id a | Error e -> fail e.message in
  let seal path =
   let inventory=match Migration_inventory.load ~compiler_abi:abi ~root_file:path with Ok x -> x | Error e -> fail e.message in
   match Migration_seal.create ~project_root:root inventory with Ok x -> x | Error e -> fail e.message in
  let header=get(Migration_header.create ~previous:(seal before) ~current:(seal after)) in
  let source=Migration_header.encode header ^ migration_source in write edge source;
  let ast=match Parser.parse_module edge source with Ok m -> m | Err e -> fail e.msg in
  let declaration=match get(D.check ~compiler_abi:abi ~source ast) with Some x -> x | None -> fail "missing migration" in
  let before,after=S.inventories(D.coverage declaration) in
  let history=get(H.check ~schemas:[before;after] ~edges:[declaration]) in
  let plan=get(R.plan history) in
  let file=Filename.concat root "migrations/work/v2-contract.tesl" in
  let source=get(Contract.source ~plan ~version:2) in write file source;
  run root plan file source)
let accept plan file source = get(Contract.check ~plan ~namespace:"work" ~file ~source)
let refuse plan file source = match Contract.check ~plan ~namespace:"work" ~file ~source with
 | Ok _ -> fail "expected exact contract refusal"
 | Error errors -> check bool "coded contract error" true (List.exists(fun(e:S.error)->e.code="MIG022") errors)
let positive ()=with_plan(fun _ plan file source ->
 let c=accept plan file source in
 check int "version" 2 (Contract.version c);
 check (list(pair string int)) "both exact final generations" ["Note",2;"Task",2] (Contract.final_generations c);
 check int "trigger/four nullability stages/marker for each entity" 12 (List.length(Contract.operations c));
 let settled=Contract.settled c in
 List.iter(fun(e:R.entity)->check int "current marker default" 2 e.marker_default_generation;
   check bool "no aliases" true (e.rename_dual_writes=[]);
   check bool "no reverse writes" true (e.reverse_writes=[])) settled.entities;
 check bool "settled has no windows" true (settled.windows=[]);
 ignore(get(Contract.revalidate c));
 let other=get(Contract.check ~plan ~namespace:"other" ~file ~source) in
 check bool "namespace-bound hash" false (Contract.digest c=Contract.digest other);
 let reordered=replace source "Trigger Note, Trigger Task" "Trigger Task, Trigger Note" in
 check string "source order does not change derived DDL order" (Contract.digest c) (Contract.digest(accept plan file reordered)))
let omissions ()=with_plan(fun _ plan file source ->
 List.iter(fun(old,fresh)->refuse plan file (replace source old fresh)) [
 "Trigger Note, Trigger Task","Trigger Note";
 "Trigger Note, Trigger Task","Trigger Note, Trigger Note";
 "NotNull Note count","NotNull Note title";
 "NotNull Note count","NotNull Note missing";
 "Trigger Note","Trigger Unknown";
 "promote: []","promote: [Trigger Note]";
 "drops:","unknown:";
 "of: Schema.Work.Migrate.V2","of: Schema.Work.Migrate.V3";
 "V2Contract","V3Contract";
 "Drop(..)","Drop";
 "Contract, Drop","Drop"])
let runtime_shapes ()=with_plan(fun _ plan file source ->
 List.iter(fun source -> refuse plan file source) [
 source ^ "\nfn unrelated() -> Int = 1\n";
 replace source "drops: [Trigger Note, Trigger Task]" "drops: computed";
 replace source "Trigger Note" "Trigger Note extra";
 replace source "tighten: [NotNull Note count, NotNull Task count]" "tighten: [Trigger Note]";
 replace source "import Schema.Work.Migrate.V2" "import Schema.Work.Migrate.V2\nimport Other.Module";
 replace source "promote: []" "promote: [], promote: []";
 replace source "promote: []" "promote: [], promote:";
 replace source "promote: []" "promote: [], unknown"])
let drift ()=with_plan(fun _ plan file source ->
 let c=accept plan file source in
 write file (source ^ "\n# edited after preparation\n");
 (match Contract.revalidate c with Ok _ -> fail "changed contract accepted" | Error _ -> ());
 write file source;
 ignore(get(Contract.revalidate c)))
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Work.VCurrent
database Main = Database { schema: Schema.Work.VCurrent, migrations: Schema.Work.Migrate,
 backend: Postgres (PostgresConfig { namespace: "work", dbName: "unused", user: "unused", password: "unused",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
|}
let rename_old = {|module Schema.Work.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String
 index [author] as "old_author"
}
|}
let rename_new = {|module Schema.Work.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, owner: String, count: Int
 index [owner] as "new_owner"
}
|}
let rename_migration = {|module Schema.Work.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [String, Int]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Work.V1
import Schema.Work.VCurrent
migration = Migration {
 from: Schema.Work.V1, to: Schema.Work.VCurrent, same: [], fixtures: [oldNote],
 entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Work.V1.Note) -> Migrated Schema.Work.VCurrent.Note =
 Row (Schema.Work.VCurrent.Note { id: old.id, owner: old.author, count: 7 })
fn oldNote() -> Schema.Work.V1.Note = Schema.Work.V1.Note { id: "one", author: "before" }
|}
let retype_old = {|module Schema.Work.V1 exposing [Note, Metadata]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, metadata: Metadata }
|}
let retype_new = {|module Schema.Work.VCurrent exposing [Note, Metadata]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String, extra: String }
codec Metadata {
 toJson { text -> "newText" with_codec stringCodec, extra -> "detail" with_codec stringCodec }
 fromJson [ { text <- "newText" with_codec stringCodec, extra <- "detail" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { metadata: Metadata @column("metadata__v2"), id: String }
|}
let retype_migration = {|module Schema.Work.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Work.V1
import Schema.Work.VCurrent
migration = Migration {
 from: Schema.Work.V1
 to: Schema.Work.VCurrent
 same: []
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Retype metadata, WriteBack metadata metadata backward] }
}
fn convert(old: Schema.Work.V1.Note) -> Migrated Schema.Work.VCurrent.Note =
 Row (Schema.Work.VCurrent.Note { id: old.id, metadata: Schema.Work.VCurrent.Metadata { text: old.metadata.text, extra: "new" } })
fn backward(row: Schema.Work.VCurrent.Note) -> Schema.Work.V1.Metadata =
 Schema.Work.V1.Metadata { text: row.metadata.text }
fn oldNote() -> Schema.Work.V1.Note =
 Schema.Work.V1.Note { id: "one", metadata: Schema.Work.V1.Metadata { text: "old" } }
|}
let public_errors file source = (Compile.agent_context_result_source file source).diagnostics |>
 List.filter(fun(d:Compile.diagnostic)->d.severity="error")
let require_public_ok file source = match public_errors file source with [] -> () | es -> fail(String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.code^": "^d.message)es))
let public_contract ()=with_plan(fun root _ file source ->
 require_public_ok file source;
 let appfile=Filename.concat root "app.tesl" in write appfile app;
 require_public_ok appfile app;
 let broken=replace source "Trigger Note, Trigger Task" "Trigger Note" in
 write file broken;
 check bool "implicit app diagnoses malformed authority" true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG022") (public_errors appfile app));
 check bool "standalone diagnoses malformed authority" true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG022") (public_errors file broken)))
let relative_contract_paths ()=with_plan(fun root _ file source ->
 let cwd=Sys.getcwd () in
 Fun.protect ~finally:(fun () -> Sys.chdir cwd) (fun () ->
  Sys.chdir root;
  List.iter (fun relative -> require_public_ok relative source)
   ["migrations/work/v2-contract.tesl";"./migrations/work/v2-contract.tesl";
    "./migrations/./work/./v2-contract.tesl"];
  let refuses_path path =
   write path source;
   check bool "wrong relative owner remains MIG022" true
    (List.exists(fun(d:Compile.diagnostic)->d.code="MIG022" &&
      Compile.string_contains d.message "canonical schema-family path") (public_errors path source));
   Sys.remove path in
  List.iter refuses_path ["migrations/other/v2-contract.tesl";
    "migrations/work/wrong-contract.tesl";"schema/work/v2-contract.tesl"];
  let alias="migrations/alias" in
  Unix.symlink "work" alias;
  Fun.protect ~finally:(fun () -> Sys.remove alias) (fun () ->
   check bool "symlink cannot relabel canonical family ownership" true
    (public_errors "migrations/alias/v2-contract.tesl" source<>[]));
  let copy=Filename.concat root "contract-copy.tesl" in
  write copy source;Sys.remove file;Unix.symlink copy file;
  Fun.protect ~finally:(fun () -> Sys.remove file;write file source;Sys.remove copy) (fun () ->
   check bool "canonical spelling cannot conceal a symlink source" true
    (List.exists(fun(d:Compile.diagnostic)->d.code="MIG013")
      (public_errors "./migrations/work/v2-contract.tesl" source)));
  let abi=match Migration_abi.current () with Ok a->Migration_abi.id a | Error e->fail e.message in
  let ast=match Parser.parse_module "./migrations/work/v2-contract.tesl" source with Ok m->m | Err e->fail e.msg in
  let checked=match get(Contract.check_module ~compiler_abi:abi ~source ast) with
   | Some c->c | None->fail "relative Contract disappeared" in
  check string "stored source guard is absolute" file (Contract.source_file checked);
  ignore(get(Contract.revalidate checked));
  Source_input.with_overlays ~project_root:root [file,source ^ "\n# changed overlay\n"] (fun () ->
   (match Contract.revalidate checked with Ok _->fail "relative guard accepted changed overlay" | Error _->()));
  let unsaved=source ^ "\n# unsaved reviewed Contract buffer\n" in
  Source_input.with_overlays ~project_root:root [file,unsaved] (fun () ->
   require_public_ok "./migrations/work/v2-contract.tesl" unsaved;
   let ast=match Parser.parse_module "./migrations/work/v2-contract.tesl" unsaved with Ok m->m | Err e->fail e.msg in
   let current=match get(Contract.check_module ~compiler_abi:abi ~source:unsaved ast) with
    | Some c->c | None->fail "unsaved relative Contract disappeared" in
   ignore(get(Contract.revalidate current)))))
let program_capture ()=with_plan(fun root _ file _ ->
 let appfile=Filename.concat root "app.tesl" in write appfile app;
 let entry=match Parser.parse_module appfile app with Ok m -> m | Err e -> fail e.msg in
 let capture f = get(Migration_program.with_source_history ~entry ~source:app (function
  | None -> fail "missing source history" | Some history -> f history)) in
 capture (fun source_history ->
   let program=Migration_program.source_program source_history in
   let contracts=Migration_program.contracts program in
   check int "one bound database" 1 (List.length contracts);
   check string "exact connection owner" "App.Main" (fst(List.hd contracts));
   check int "one explicitly approved contract" 1 (List.length(snd(List.hd contracts)));
   let originals=List.map fst(Migration_program.source_modules source_history) in
   let lowered=List.map(fun m -> match Migration_schema.lower_module ~modules:originals m with Ok m -> Migration_form.erase m | Error _ -> fail "lowering") originals in
   ignore(get(Migration_program.verify_source_history source_history lowered));
   let bytes=Source_input.read file in
   Fun.protect ~finally:(fun ()->write file bytes) (fun ()->
    write file(bytes ^ "\n# changed explicit companion after Program capture\n");
    match Migration_program.verify_source_history source_history lowered with
    | Ok _->fail "Program published an edited current Contract"
    | Error errors->check bool "publication integrity diagnostic" true
       (List.exists(fun(e:S.error)->e.code="MIG013")errors)));

 let absent=Filename.concat root "migrations/work/v2-contract.saved" in
 Unix.rename file absent;
 capture(fun source_history -> check int "absence grants no contraction authority" 0
   (List.length(Migration_program.contracts(Migration_program.source_program source_history))));
 Unix.rename absent file)
let preview_contract ()=with_plan(fun root _ file source ->
 let appfile=Filename.concat root "app.tesl" in write appfile app;
 Sys.remove file;
 let preview=match Migration_preview.generate_contract ~project_root:root ~entry_file:appfile ~database:None ~version:2 ~documents:[] with
  | Ok p -> p | Error errors -> fail(String.concat "\n"(List.map(fun(e:Migration_preview.error)->e.message)errors)) in
 check bool "preview does not write" false (Sys.file_exists file);
 check bool "complete app checks" true (Migration_preview.compilable preview);
 let edits=Migration_manifest.edits(Migration_preview.manifest preview) in
 check int "one new contract source" 1 (List.length edits);
 check string "deterministic reviewed source" source (List.hd edits).after;
 let response=Migration_command.run ["contract";appfile;"--version";"2";"--manifest-json"] in
 check int "compiler command preview" 0 response.exit_code;
 check bool "shared preview operation" true (Compile.string_contains response.stdout "\"operation\":\"contract\"");
 write file source;
 (match Migration_preview.verify preview ~documents:[] with Ok _ -> fail "new contract did not invalidate original preview" | Error _ -> ());
 let response=Migration_command.run ["contract";appfile;"--version";"2";"--manifest-json"] in
 check int "refuse replacing reviewed authority" 1 response.exit_code;
 check bool "constructive refusal" true (Compile.string_contains response.stdout "already exists"))
let rename_contract ()=with_plan ~old_source:rename_old ~new_source:rename_new ~migration_source:rename_migration(fun _ plan file source ->
 let c=accept plan file source in
 require_public_ok file source;
 (match Contract.operations c with
  | C.Seq [C.Bytes "relax-retired-nullability";C.Bytes "Note";C.Seq before;C.Seq after]::_ ->
    check bool "old storage starts NOT NULL" true (List.nth before 2=C.Seq [C.Bytes "bool";C.Bytes "false"]);
    check bool "prepared old storage accepts settled inserts" true (List.nth after 2=C.Seq [C.Bytes "bool";C.Bytes "true"])
  | _ -> fail "retired required storage lacks preparatory operation prefix");
 check bool "explicit old logical column" true (Compile.string_contains source "Column Note author");
 check bool "explicit old index" true (Compile.string_contains source "Index Note old_author");
 check bool "keeps current index" false (Compile.string_contains source "Index Note new_owner");
 let e=List.hd(Contract.settled c).entities in
 check (list string) "settled current physical projection" ["count";"id";"owner"] (List.map(fun(c:R.column)->c.name)e.columns);
 check (list string) "settled exact index inventory" ["new_owner"] (List.map(fun(i:Migration_storage.index)->i.name)e.indexes);
 refuse plan file (replace source "Column Note author" "Column Note owner");
 refuse plan file (replace source "Index Note old_author" "Index Note new_owner"))
let global_preparation_prefix ()=
 let fresh=replace (schema "Schema.Work.VCurrent" ", count: Int") "title:" "label:" in
 let edge=migration 11 |> fun s->replace s "title: old.title" "label: old.title"
  |> fun s->replace s "Note: Migrate convertNote []" "Note: Migrate convertNote [Rename title label]"
  |> fun s->replace s "Task: Migrate convertTask []" "Task: Migrate convertTask [Rename title label]"
  |> fun s->replace s "Entity(..), Migrated(..)" "Entity(..), Rule(..), Migrated(..)" in
 with_plan ~new_source:fresh ~migration_source:edge(fun _ plan file source->
  let c=accept plan file source in
  let op=function C.Seq(C.Bytes tag::C.Bytes entity::_)->tag,entity | _->fail "invalid operation" in
  let operations=List.map op (Contract.operations c) in
  check (list(pair string string)) "all preparations precede all destructive operations"
   ["relax-retired-nullability","Note";"relax-retired-nullability","Task"]
   [List.nth operations 0;List.nth operations 1];
  check int "exact global preparation count" 2
   (List.length(List.filter(fun(tag,_)->tag="relax-retired-nullability")operations));
  refuse plan file (replace source "Trigger Note" "RelaxNull Note title"))
let quoted_index_contract ()=
 let before=replace rename_old "old_author" "of" in
 with_plan ~old_source:before ~new_source:rename_new ~migration_source:rename_migration(fun _ plan file source ->
  require_public_ok file source;
  ignore(accept plan file source);
  check bool "keyword SQL name is quoted" true (Compile.string_contains source "Index Note \"of\"");
  refuse plan file (replace source "Index Note \"of\"" "Index Note \"missing_index\""))
let retype_contract ()=with_plan ~old_source:retype_old ~new_source:retype_new ~migration_source:retype_migration(fun _ plan file source ->
 let c=accept plan file source in
 require_public_ok file source;
 check bool "physical old Retype storage is explicit" true (Compile.string_contains source "Storage Note \"metadata\"");
 check int "exact Retype operations" 8 (List.length(Contract.operations c));
 let e=List.hd(Contract.settled c).entities in
 check (list string) "fresh codec column survives" ["id";"metadata__v2"] (List.map(fun(c:R.column)->c.name)e.columns);
 check bool "retired reverse obligations removed" true (e.reverse_writes=[]);
 refuse plan file (replace source "Storage Note \"metadata\"" "Column Note metadata");
 refuse plan file (replace source "Storage Note \"metadata\"" "Storage Note \"metadata__v2\""))
let discovery_guards ()=with_plan(fun root _ file source ->
 let abi=match Migration_abi.current()with Ok a->Migration_abi.id a|Error e->fail e.message in
 let discover()=match Migration_history_sources.discover ~compiler_abi:abi ~project_root:root ~family:"Schema.Work" with Ok h->h|Error e->fail e.message in
 let h=discover() in
 check int "contract is discovered" 1 (List.length(Migration_history_sources.contracts h));
 Sys.remove file;
 (match Migration_history_sources.verify_unchanged h with Ok _->fail "removed contract accepted"|Error _->());
 let without=discover() in write file source;
 (match Migration_history_sources.verify_unchanged without with Ok _->fail "new contract accepted after capture"|Error _->());
 let weird=Filename.concat(Filename.dirname file)"v2-CONTRACT.tesl" in Unix.rename file weird;
 (match Migration_history_sources.discover ~compiler_abi:abi ~project_root:root ~family:"Schema.Work"with Ok _->fail "noncanonical contract silently accepted"|Error _->());
 Unix.rename weird file)
let source_identity_guards ()=with_plan(fun root plan file source ->
 let c=accept plan file source in
 Source_input.with_pinned_files [file,source] (fun () ->
  write file(source^"\n# underlying edited source\n");
  (match Contract.revalidate c with Ok _->fail "old pins hid source edit"|Error _->()));
 write file source;
 let old=Filename.concat root "schema/work/v1.tesl" in
 let bytes=Source_input.read old in write old(bytes^"\nfn unrelated() -> String = \"changed\"\n");
 (match Contract.revalidate c with Ok _->fail "old schema drift accepted"|Error _->());
 write old bytes;
 ignore(get(Contract.revalidate c)))
let record_literal_errors () =
 let parse expression=Parser.parse_module "record-literal.tesl" ("module Example exposing []\nvalue = " ^ expression ^ "\n") in
 List.iter(fun expression -> match parse expression with Ok _ -> () | Err e -> fail e.msg)
  ["{ a: 1 }";"{ \"a\": 1 }";"{ a: { b: 1 } }"];
 List.iter(fun expression -> match parse expression with Ok _ -> fail("malformed final field accepted: " ^ expression) | Err _ -> ())
  ["{ a: 1, a: }";"{ a: 1, unknown }";"{ a: 1, \"unknown\" }";
   "{ a: 1, \"a\": }";"{ a: { b: 1, b: } }"]
let frozen_contract_closure ()=with_plan(fun root _ file contract_source ->
 let abi=match Migration_abi.current () with Ok a->Migration_abi.id a | Error e->fail e.message in
 let start ()=match Migration_generate.start ~compiler_abi:abi ~project_root:root ~family:"Schema.Work" ~version:2 ~documents:[] with
  | Ok p->p | Error errors->fail(String.concat "\n" (List.map(fun(e:Migration_generate.error)->e.message)errors)) in
 let preview=start () in
 List.iter(fun(e:Migration_manifest.edit)->write e.path e.after)(Migration_manifest.edits preview.manifest);
 let edge=Filename.concat root "migrations/work/v2.tesl" in
 let source=Source_input.read edge in
 let seal=match get(Migration_closure.read ~file:edge source) with Some x->x | None->fail "missing completed source seal" in
 check bool "Contract is sealed without importing it into the row function graph" true
  (List.mem_assoc "Schema.Work.Migrate.V2Contract" (Migration_closure.sources seal));
 let verify ()=Migration_closure.verify ~project_root:root ~root_file:edge ~source seal in
 ignore(get(verify ()));
 let refused ()=match verify () with Ok _->fail "frozen Contract mutation accepted" | Error es->
  check bool "integrity diagnostic" true(List.exists(fun(e:S.error)->e.code="MIG013")es) in
 write file(contract_source ^ "\n# edited frozen Contract\n");refused();
 Sys.remove file;refused();write file contract_source;ignore(get(verify ())));
 with_plan(fun root _ file source ->
  (* An absent companion is frozen too. The source command must run before the
     next revision, rather than silently append authority to completed history. *)
  Sys.remove file;
  let current=Filename.concat root "schema/work/v-current.tesl" in
  let frozen=Filename.concat root "schema/work/v2.tesl" in
  write frozen(replace(Source_input.read current) "VCurrent" "V2");
  let edge=Filename.concat root "migrations/work/v2.tesl" in
  let edge_source=replace(Source_input.read edge) "VCurrent" "V2" in
  write edge edge_source;
  let captured=get(Migration_closure.capture ~project_root:root ~root_file:edge ~source:edge_source) in
  let sealed=get(Migration_closure.attach ~file:edge ~source:edge_source captured) in
  write edge sealed;
  let located=Option.get(get(Migration_closure.read ~file:edge sealed)) in
  ignore(get(Migration_closure.verify ~project_root:root ~root_file:edge ~source:sealed located));
  write file source;
  match Migration_closure.verify ~project_root:root ~root_file:edge ~source:sealed located with
  | Ok _->fail "late-created frozen Contract accepted"
  | Error es->check bool "constructive preparation order" true
    (List.exists(fun(e:S.error)->Compile.string_contains e.message "before starting")es))
let native_contract_fixture ?old_source ?new_source ?migration_source ?(expected_preparations=0) expected_operations ()=with_plan ?old_source ?new_source ?migration_source(fun root _ file source ->
 let appfile=Filename.concat root "app.tesl" in write appfile app;
 require_public_ok file source;
 let artifacts=match Compile.compile_row_source_artifacts ~storage:true ~physical:true appfile app with
  | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail(String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.message)ds)) in
 let artifact path=(List.find(fun(a:Emit_go.artifact)->a.path=path)artifacts).contents in
 check bool "complete contract artifact emitted" true (Compile.string_contains (artifact "row-contract-history.json") "compiled-row-contract-history");
 let out=Filename.temp_dir "tesl-contract-native-" "" in
 Fun.protect ~finally:(fun () -> remove out) (fun () ->
  List.iter(fun(a:Emit_go.artifact)->write(Filename.concat out a.path)a.contents)artifacts;
  write(Filename.concat out "internal/teslrt/contract_generated_test.go") (replace (replace {|package teslrt
import("testing";"strings";"encoding/hex";"fmt";"crypto/sha256")
func TestActualCompiledContract(t *testing.T){
 c:=compiledRowHistories["Schema.Work"]
 if c==nil {t.Fatal("missing actual compiled owner")}
 contract:=compiledRowContracts[c][2]
 if contract==nil || contract.compiled!=c || contract.window.compiled!=c || contract.settled.compiled!=c {t.Fatal("missing exact checked contract binding")}
 if !contract.settled.settled || len(contract.settled.windows)!=0 || len(contract.operations)!=EXPECTED_OPERATIONS || contract.preparationCount!=EXPECTED_PREPARATIONS {t.Fatal("incomplete settled contract")}
 for _,e:=range contract.settled.entities {if e.insertGeneration!=e.generation || len(e.aliases)!=0 || len(e.reverseWrites)!=0 {t.Fatal("retired storage obligation survived")}}
 for _,dropFirst:=range []bool{false,true} {
 r:=&pgMigrationWireReader{}
 doc:=pgRowDocument(r,contract.contract,contract.hash,"contract")
 if r.err!=nil {t.Fatal(r.err)}
 if dropFirst {doc.children[9].children=doc.children[9].children[1:]} else {doc.children[9].children=doc.children[9].children[:len(doc.children[9].children)-1]}
 raw:=pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"),pgRowAtom("1"),pgRowAtom("contract"),doc))
 encoded,hash:=hex.EncodeToString([]byte(raw)),fmt.Sprintf("%x",sha256.Sum256([]byte(raw)))
 if got,err:=pgParseRowContract(encoded,hash,contract.window,contract.settled);err==nil || got!=nil || !strings.Contains(err.Error(),"operation inventory") {t.Fatal("freshly rehashed omitted required operation accepted",dropFirst,err)}
 }
 for start,op:=range contract.operations {
 if op.children[0].value!="add-not-null-check" {continue}
 for _,attack:=range []string{"omit-add","omit-validate","omit-set","omit-drop","swap-validation","replace-name","replace-column"} {
 r:=&pgMigrationWireReader{};doc:=pgRowDocument(r,contract.contract,contract.hash,"contract");if r.err!=nil {t.Fatal(r.err)}
 ops:=doc.children[9].children
 switch attack {
 case "omit-add","omit-validate","omit-set","omit-drop":
 offsets:=map[string]int{"omit-add":0,"omit-validate":1,"omit-set":2,"omit-drop":3};i:=start+offsets[attack]
 doc.children[9].children=append(ops[:i],ops[i+1:]...)
 case "swap-validation": ops[start],ops[start+1]=ops[start+1],ops[start]
 case "replace-name","replace-column":
 field:=1;if attack=="replace-column" {field=2}
 // Change every occurrence consistently; tuple agreement alone cannot grant authority.
 for _,pair:=range [][2]int{{0,3},{1,2},{1,3},{3,2}} {ops[start+pair[0]].children[pair[1]].children[field].value="wrong_but_consistent"}
 }
 raw:=pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"),pgRowAtom("1"),pgRowAtom("contract"),doc))
 encoded,hash:=hex.EncodeToString([]byte(raw)),fmt.Sprintf("%x",sha256.Sum256([]byte(raw)))
 if got,err:=pgParseRowContract(encoded,hash,contract.window,contract.settled);err==nil || got!=nil {t.Fatal("freshly rehashed staged proof substitution accepted",start,attack,err)}
 }
 }
}
|} "EXPECTED_OPERATIONS" (string_of_int expected_operations)) "EXPECTED_PREPARATIONS" (string_of_int expected_preparations));
  (* Build and execute from the generated project with every Tesl source absent. *)
  let hidden=ref [] in
  let rec hide path=if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then Array.iter(fun n->hide(Filename.concat path n))(Sys.readdir path)
   else if Filename.check_suffix path ".tesl" then (hidden:=(path,Source_input.read path)::!hidden;Sys.remove path) in
  hide root;
  Fun.protect ~finally:(fun () -> List.iter(fun(p,s)->write p s)!hidden) (fun () ->
   let log=Filename.concat out "native.log" in
   let status=Sys.command(Printf.sprintf "cd %s && timeout 180s go test -p 1 -race -timeout=120s -count=1 ./... > %s 2>&1" (Filename.quote out)(Filename.quote log)) in
   if status<>0 then fail(Source_input.read log))))
let native_contract=native_contract_fixture 12
let native_rename_contract=native_contract_fixture ~old_source:rename_old ~new_source:rename_new ~migration_source:rename_migration ~expected_preparations:1 13
let native_retype_contract=native_contract_fixture ~old_source:retype_old ~new_source:retype_new ~migration_source:retype_migration ~expected_preparations:1 8
let native_quoted_contract=native_contract_fixture
 ~new_source:(schema "Schema.Work.VCurrent" ", user: Int")
 ~migration_source:(replace (migration 11) "count:" "user:") 12
let staged_checks contract =
 let rec read found = function
  | [] -> List.rev found
  | C.Seq [C.Bytes "add-not-null-check";C.Bytes entity;C.Seq [C.Bytes "absent"];
       (C.Seq [C.Bytes "not-null-check";C.Bytes name;C.Bytes physical;C.Bytes "false"] as unvalidated)]
    ::C.Seq [C.Bytes "validate-not-null-check";C.Bytes e2;q0;
       (C.Seq [C.Bytes "not-null-check";C.Bytes n2;C.Bytes p2;C.Bytes "true"] as validated)]
    ::C.Seq [C.Bytes "set-not-null";C.Bytes e3;C.Seq before;C.Seq after]
    ::C.Seq [C.Bytes "drop-not-null-check";C.Bytes e4;q1;C.Seq [C.Bytes "absent"]]::rest ->
    check (list string) "all stages bind the same entity" [entity;entity;entity] [e2;e3;e4];
    check string "same checked proof name" name n2;
    check string "same physical column" physical p2;
    check bool "validation requires the exact NOT VALID predecessor" true (q0=unvalidated);
    check bool "proof survives SET until its own drop operation" true (q1=validated);
    (match before,after with
     | C.Bytes p::scalar::C.Seq[C.Bytes "bool";C.Bytes "true"]::before_rest,
       C.Bytes p'::scalar'::C.Seq[C.Bytes "bool";C.Bytes "false"]::after_rest ->
       check (list string) "SET uses exact current physical field" [physical;physical] [p;p'];
       check bool "tightening preserves all other column descriptors" true
        (scalar=scalar' && before_rest=after_rest)
     | _->fail "staged SET changed more than nullability");
    check int "bounded deterministic SQL identifier" 56 (String.length name);
    check bool "name is compiler-derived hexadecimal" true
     (Str.string_match (Str.regexp "tesl_nn_[0-9a-f]+$") name 0);
    read ((entity,physical,name)::found) rest
  | C.Seq(C.Bytes tag::_)::rest when
      List.mem tag ["drop-index";"drop-invalidation";"drop-column";
       "relax-retired-nullability";"set-insert-generation"] -> read found rest
  | _ -> fail "nullability operation is missing, reordered or outside its four-stage group"
 in read [] (Contract.operations contract)
let staged_exact ()=with_plan(fun _ plan file source ->
 let contract=accept plan file source in
 let stages=staged_checks contract in
 check (list(pair string string)) "one staged proof per required new field"
  ["Note","count";"Task","count"] (List.map(fun(e,p,_)->e,p) stages);
 check int "entity-local names cannot alias" 2
  (List.length(List.sort_uniq compare(List.map(fun(_,_,n)->n)stages)));
 check string "derived stages add no user steps" source (get(Contract.source ~plan ~version:2));
 check bool "canonical receipt contains every derived stage" true
  (match Contract.canonical contract with C.Seq fields -> List.nth fields 9=C.Seq(Contract.operations contract) | _->false);
 refuse plan file (replace source "NotNull Note count" "NotNull Note count, NotNull Note count");
 refuse plan file (replace source "NotNull Note count" "AddNotNullCheck Note count"))
let staged_identity ()=
 let first=with_plan(fun _ plan file source ->
  let first=staged_checks(accept plan file source) in
  let second=staged_checks(get(Contract.check ~plan ~namespace:"other" ~file ~source)) in
  List.iter2(fun(e,p,a)(e',p',b)->check bool "namespace changes exact check identity" true
   (e=e'&&p=p'&&a<>b))first second;
  let reordered=replace source "NotNull Note count, NotNull Task count"
   "NotNull Task count, NotNull Note count" in
  check bool "source ordering cannot change check names" true
   (first=staged_checks(accept plan file reordered));first) in
 with_plan ~migration_source:(migration 12)(fun _ plan file source ->
  let changed=staged_checks(accept plan file source) in
  List.iter2(fun(e,p,a)(e',p',b)->check bool "changed checked behavior rebinds every entity proof" true
   (e=e'&&p=p'&&a<>b))first changed)
let staged_physical_fields ()=
 let fresh=schema "Schema.Work.VCurrent" ", count: Int, scoreValue: Int, optional: Maybe Int"
  |> fun s->replace s "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Prelude" in
 let edge=migration 11 |> fun s->replace s "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
  |> fun s->replace s "count: 7" "count: 7, scoreValue: 4, optional: Nothing"
  |> fun s->replace s "count: 11" "count: 11, scoreValue: 4, optional: Nothing" in
 with_plan ~new_source:fresh ~migration_source:edge(fun _ plan file source ->
  require_public_ok file source;
  let stages=staged_checks(accept plan file source) in
  check (list(pair string string)) "physical field is exact; nullable field needs no proof"
   ["Note","count";"Note","score_value";"Task","count";"Task","score_value"]
   (List.map(fun(e,p,_)->e,p)stages);
  check int "all field and entity identities are distinct" 4
   (List.length(List.sort_uniq compare(List.map(fun(_,_,n)->n)stages)));
  check bool "source authority still uses the logical field" true
   (Compile.string_contains source "NotNull Note scoreValue");
  refuse plan file (replace source "NotNull Note scoreValue" "NotNull Note score_value");
  refuse plan file (replace source "NotNull Note scoreValue" "NotNull Note optional"))
let ()=run "Checked source contracts" ["contract",[
 test_case "complete checked artifact and settled descriptions" `Quick positive;
 test_case "omitted duplicate foreign and unsupported authority" `Quick omissions;
 test_case "contextual source cannot hide runtime computations" `Quick runtime_shapes;
 test_case "source publication drift" `Quick drift;
 test_case "public standalone and implicit application diagnostics" `Quick public_contract;
 test_case "relative Contract paths preserve canonical ownership and overlays" `Quick relative_contract_paths;
 test_case "guarded source program preserves exact contract owner" `Quick program_capture;
 test_case "guarded contract source preview and command" `Quick preview_contract;
 test_case "Rename exact columns and index association" `Quick rename_contract;
 test_case "Retype authorizes old physical storage" `Quick retype_contract;
 test_case "all retired required columns prepare before settled switching" `Quick global_preparation_prefix;
 test_case "quoted explicit SQL index name" `Quick quoted_index_contract;
 test_case "contract discovery removal addition and canonical names" `Quick discovery_guards;
 test_case "pinned source and checked schema drift" `Quick source_identity_guards;
 test_case "ordinary record literals retain final field errors" `Quick record_literal_errors;
 test_case "next revision freezes Contract presence and bytes" `Quick frozen_contract_closure;
 test_case "four exact nullability stages preserve source authority" `Quick staged_exact;
 test_case "staged proof names bind namespace entity and checked behavior" `Quick staged_identity;
 test_case "staged proofs use physical fields and omit nullable carriers" `Quick staged_physical_fields;
 test_case "actual emitted source-absent native contract binding" `Quick native_contract;
 test_case "actual Rename Contract native exact storage inventory" `Quick native_rename_contract;
 test_case "actual Retype Contract native frozen codec storage" `Quick native_retype_contract;
 test_case "actual staged check uses quoted physical storage" `Quick native_quoted_contract]]
