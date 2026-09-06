open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let replace a b = Str.global_replace (Str.regexp_string a) b
let old = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, owner: String, title: String, count: Int }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, convert, oldNote]
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
  Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", author: "writer", title: "hello" }
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
let refuses code path s = let ds=errors path s in
  if not (List.exists (fun (d:Compile.diagnostic) -> d.code=code) ds) then fail ("missing " ^ code ^ ":\n" ^ describe ds)
let checked path s = accepts path s; match Parser.parse_module path s with
  | Err e -> fail e.msg
  | Ok m -> match D.check ~compiler_abi:"transform-source-test" ~source:s m with
    | Ok (Some d) -> d | Ok None -> fail "missing declaration"
    | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let basic () = project (fun _ _ path ->
  let d=checked path source in
  let transforms=Option.get (D.transforms d) in
  check int "one exact row binding" 1 (List.length (T.rows transforms));
  let row=List.hd (T.rows transforms) in
  check string "declaration identity" "Schema.Notes.Migrate.V2.convert" (Option.get row.function_binding).identity;
  check string "retained owner" "Schema.Notes.V1.Note" row.mapping.previous.entity_name;
  check string "target owner" "Schema.Notes.VCurrent.Note" row.mapping.current.entity_name;
  check int "representative source fixture" 1 (List.length row.fixtures);
  check int "no additive adapter fabricated" 0 (List.length (Migration_additive.entities (D.additive d)));
  check int "complete input closure" 3 (List.length (T.source_inputs transforms));
  let formatted=Formatter.format_source source in
  accepts path formatted;
  check string "idempotent format" formatted (Formatter.format_source formatted))
let signature () = project (fun _ _ path ->
  List.iter (fun (a,b) -> refuses "MIG021" path (replace a b source))
    ["old: Schema.Notes.V1.Note", "old: Schema.Notes.VCurrent.Note";
     "Migrated Schema.Notes.VCurrent.Note", "Migrated Schema.Notes.V1.Note";
     "old: Schema.Notes.V1.Note", "old: a";
     "old: Schema.Notes.V1.Note", "old: Schema.Notes.V1.Note, extra: String";
     "Migrate convert", "Migrate missing";
     "Migrate convert", "Migrate (fn (old: Schema.Notes.V1.Note) -> Reject \"no\")"])
let identities () = project (fun _ _ path ->
  List.iter (fun expression -> refuses "MIG017" path (replace "owner: old.author" ("owner: " ^ expression) source))
    ["old.title";"\"changed\"";"old.author ++ \"\""];
  List.iter (fun expression -> refuses "MIG018" path (replace "title: old.title" ("title: " ^ expression) source))
    ["old.author";"\"changed\"";"old.title ++ \"\""];
  refuses "MIG018" path (replace "  Row (" "  let old = oldNote()\n  Row (" source);
  refuses "MIG017" path (replace "  Row (" "  let alias = old.author\n  Row (" source |> replace "owner: old.author" "owner: alias");
  refuses "MIG018" path (replace "  Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })"
    "  let row = Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 }\n  Row row" source))
let branches () = project (fun _ _ path ->
  let row="Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })" in
  accepts path (replace ("  " ^ row) ("  if old.title == \"\" then\n    Reject \"empty\"\n  else\n    " ^ row) source);
  refuses "MIG017" path (replace ("  " ^ row) ("  if old.title == \"\" then\n    " ^ replace "old.author" "old.title" row ^ "\n  else\n    " ^ row) source);
  refuses "MIG018" path (replace ("  " ^ row) ("  case old.title of\n    old -> " ^ row) source);
  refuses "MIG018" path (replace ("  " ^ row) "  converted old" source ^
    "\nfn converted(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =\n  " ^ row ^ "\n"))
let fixtures () = project (fun _ _ path ->
  refuses "MIG003" path (replace "fixtures: [oldNote]" "fixtures: []" source);
  refuses "MIG021" path (replace "fn oldNote() -> Schema.Notes.V1.Note" "fn oldNote(input: String) -> Schema.Notes.V1.Note" source);
  refuses "MIG023" path (replace "fixtures: [oldNote]" "fixtures: [oldNote, oldNote]" source);
  refuses "MIG021" path (replace "fixtures: [oldNote]" "fixtures: [convert]" source))
let runtime_guard () = project (fun _ _ path ->
  let d=checked path source in let before,after=S.inventories (D.coverage d) in
  List.iter (fun initial_version -> match Migration_expansion.generate ~initial_version ~schemas:[before;after] ~edges:[d] with
    | Ok _ -> fail "a transform escaped into an additive expansion"
    | Error errors -> check bool "explicit executor refusal at every installation origin" true
        (List.exists (fun (e:S.error) -> e.code="MIG016" && Compile.string_contains e.message "transformation executor") errors)) [1;2])
let derived () = project ~after:(replace ", count: Int" "" fresh) (fun _ _ path ->
  let s=source |> replace "Migrate convert [Rename author owner]" "Derived [Rename author owner]"
    |> replace "fixtures: [oldNote]" "fixtures: []" |> replace ", count: 7" "" in
  let d=checked path s in
  check bool "derived has no fabricated user callback" true ((List.hd (T.rows (Option.get (D.transforms d)))).function_binding=None);
  refuses "MIG022" path (replace "Rename author owner" "Rename title owner" s);
  refuses "MIG023" path (replace "Rename author owner" "Rename author owner, Rename author owner" s))
let without_test = String.split_on_char '\n' source |> fun lines ->
  let rec take = function [] -> [] | line::_ when String.starts_with ~prefix:"test " line -> [] | line::tail -> line::take tail in
  String.concat "\n" (take lines) ^ "\n"
let proof_schema = {|module Schema.Notes.VCurrent exposing [Note, NonEmpty, tryTitle]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
  if value != "" then
    Something (value ::: NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id {
  id: String
  owner: String
  title: String
  count: Int
  checkedTitle: String ::: NonEmpty checkedTitle
}
|}
let proof_source = without_test
  |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
  |> replace "  Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })"
    {|  case Schema.Notes.VCurrent.tryTitle old.title of
    Nothing -> Reject "empty title"
    Something validated -> Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7, checkedTitle: validated })|}
let proof_tests = {|test "proved new field accepts Unicode" {
  let old = Schema.Notes.V1.Note { id: "one", author: "writer", title: "å🙂" }
  case convert old of
    Row row -> expect row.checkedTitle == "å🙂"
    Reject reason -> expect False
}
test "invalid new field rejects without a row" {
  let old = Schema.Notes.V1.Note { id: "two", author: "writer", title: "" }
  case convert old of
    Row row -> expect False
    Reject reason -> expect reason == "empty title"
}
|}
let proof_checked () = project ~after:proof_schema (fun _ _ path ->
  ignore (checked path proof_source);
  List.iter (fun expression ->
    let ds=errors path (replace "checkedTitle: validated" ("checkedTitle: " ^ expression) proof_source) in
    check bool ("unproven new field rejected: " ^ expression) true (ds<>[]))
    ["old.title";"old.author";"validated ++ \"\""];
  ())
let imports () = project (fun _ save path ->
  let first=Str.search_forward (Str.regexp_string "fn convert") without_test 0 in
  let declarations=String.sub without_test first (String.length without_test-first) in
  let helper={|module Schema.Notes.Migrate.Helpers exposing [convert, oldNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
|} ^ declarations in
  ignore (save "migrations/notes/helpers.tesl" helper);
  let declaration=String.sub without_test 0 first |> replace "exposing [migration, convert, oldNote]" "exposing [migration]" in
  List.iter (fun (imp,fn,fixture) ->
    let s=declaration |> replace "import Schema.Notes.V1" (imp ^ "\nimport Schema.Notes.V1")
      |> replace "Migrate convert" ("Migrate " ^ fn) |> replace "fixtures: [oldNote]" ("fixtures: [" ^ fixture ^ "]") in
    let d=checked path s in
    let row=List.hd (T.rows (Option.get (D.transforms d))) in
    check string "direct owner, independent of spelling" "Schema.Notes.Migrate.Helpers.convert" (Option.get row.function_binding).identity;
    check int "owned helper is pinned" 4 (List.length (T.source_inputs (Option.get (D.transforms d)))))
    ["import Schema.Notes.Migrate.Helpers", "Schema.Notes.Migrate.Helpers.convert", "Schema.Notes.Migrate.Helpers.oldNote";
     "import Schema.Notes.Migrate.Helpers exposing [convert, oldNote]", "convert", "oldNote"];
  let prefixed=declaration |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Helpers\nimport Schema.Notes.V1"
    |> replace "Migrate convert" "Migrate Schema.Notes.Migrate.Helpers.convert"
    |> replace "fixtures: [oldNote]" "fixtures: [Schema.Notes.Migrate.Helpers.oldNote]" in
  ignore (save "migrations/notes/helpers.tesl" (replace "exposing [convert, oldNote]" "exposing [oldNote]" helper));
  refuses "MIG021" path prefixed;
  ignore (save "migrations/notes/helpers.tesl" helper);
  refuses "MIG021" path (replace "Schema.Notes.Migrate.Helpers.convert" "convert" prefixed);
  let foreign=replace "Schema.Notes.Migrate.Helpers" "Outside.Helpers" helper in
  ignore (save "outside/helpers.tesl" foreign);
  refuses "MIG010" path (replace "Schema.Notes.Migrate.Helpers" "Outside.Helpers" prefixed);
  (* A helper's own import scope, not the caller's short names, owns its parameter. *)
  ignore (save "schema/notes/v1/other.tesl" {|module Schema.Notes.V1.Other exposing [Note]
import Tesl.Prelude exposing [String]
record Note { id: String, author: String, title: String }
|});
  let wrong=helper |> replace "import Schema.Notes.V1" "import Schema.Notes.V1.Other exposing [Note]\nimport Schema.Notes.V1"
    |> replace "old: Schema.Notes.V1.Note" "old: Note" in
  ignore (save "migrations/notes/helpers.tesl" wrong);
  refuses "MIG021" path prefixed)
let purity () = project (fun _ _ path ->
  refuses "MIG021" path (replace "count: 7" "count: (fail 400 \"no\")" without_test);
  let checked_helper={|check unsafe(value: Int) -> Int =
  if value >= 0 then
    value
  else
    fail 400 "negative"
|} in
  refuses "MIG021" path (replace "count: 7" "count: unsafe 7" without_test ^ checked_helper);
  refuses "MIG021" path (replace "count: 7" "count: hidden()" without_test ^ checked_helper ^
    "fn hidden() -> Int = unsafe 7\n");
  refuses "MIG021" path (replace "count: 7" "count: hidden" without_test ^ checked_helper ^ "hidden = unsafe 7\n");
  refuses "MIG010" path (replace "fn convert(old:" "handler convert(old:" without_test);
  refuses "MIG010" path (replace "-> Migrated Schema.Notes.VCurrent.Note =" "-> Migrated Schema.Notes.VCurrent.Note requires [random] =" without_test);
  accepts path (replace "count: 7" "count: computed old.title" without_test ^
    "fn computed(value: String) -> Int =\n  if value == \"\" then\n    0\n  else\n    7\n"))
let primitive_failure () = project (fun _ save path ->
  let imported=without_test |> replace "import Tesl.Prelude"
    "import Tesl.Int exposing [Int.nonNegative, Int.nonZero]\nimport Tesl.Prelude" in
  List.iter (fun expression -> refuses "MIG021" path
    (replace "count: 7" ("count: " ^ expression) imported))
    ["check Int.nonNegative (-1)"; "check Int.nonZero 0"; "Int.nonNegative (-1)"; "Int.nonZero 0"];
  refuses "MIG021" path (imported |> replace "  Row (" "  let alias = Int.nonNegative\n  Row ("
    |> replace "count: 7" "count: alias (-1)");
  refuses "MIG021" path (replace "count: 7" "count: stored" imported ^ "stored = check Int.nonNegative (-1)\n");
  refuses "MIG021" path (replace "count: 7" "count: hidden()" imported ^
    "fn hidden() -> Int = check Int.nonZero 0\n");
  refuses "MIG021" path (imported |> replace "  Row (" "  let action = fn (n: Int) -> check Int.nonZero n\n  Row ("
    |> replace "count: 7" "count: action 0");
  ignore (save "migrations/notes/int.tesl" {|module Schema.Notes.Migrate.Int exposing [computed, nonNegative]
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero]
fn computed() -> Int = check Int.nonZero 0
fn nonNegative(value: Int) -> Int = value
|});
  let helper=imported |> replace "import Schema.Notes.V1"
    "import Schema.Notes.Migrate.Int exposing [nonNegative]\nimport Schema.Notes.V1" in
  refuses "MIG021" path (replace "count: 7" "count: Schema.Notes.Migrate.Int.computed()" helper);
  (* An owned function with the same leaf spelling is not a stdlib primitive;
     its unused sibling's HTTP boundary is not in this executable closure. *)
  accepts path (replace "count: 7" "count: Schema.Notes.Migrate.Int.nonNegative (-1)" helper);
  accepts path (replace "count: 7" "count: nonNegative (-1)" helper))

let rules () = project (fun _ _ path ->
  List.iter (fun (rule,code) -> refuses code path (replace "Rename author owner" rule without_test))
    ["Rename author owner, Rename author owner","MIG023";
     "Rename author owner, Default owner \"x\"","MIG023";
     "Rename title owner","MIG022";
     "Rename author title","MIG022";
     "Rename id owner","MIG009";
     "Rename Schema.Notes.V1.Note owner","MIG022";
     "Rename author","MIG022";
     "Rename author owner 1","MIG022"];
  List.iter (fun number ->
    let s=without_test |> replace "Rename author owner" ("Rename author owner, Default count (" ^ number ^ ")")
      |> replace "count: 7" ("count: " ^ number) in
    accepts path s;
    refuses "MIG018" path (replace ("count: " ^ number) "count: 2" s))
    ["-1";"-1606938044258990275541962092341162602522202993782792835301376"];
  refuses "MIG022" path (replace "Rename author owner" "Rename author owner, Default count True" without_test);
  List.iter (fun marker -> refuses "MIG020" path (without_test ^ "fn escaped() -> Int = " ^ marker ^ "\n"))
    ["Migrate convert []";"Derived []";"Rename author owner"];
  refuses "T001" path (replace "Entity(..)" "Entity" without_test);
  refuses "T001" path (replace "Rule(..)" "Rule" without_test))
let contextual_fields () =
  List.iter (fun (previous,current) ->
    project ~before:(replace "author" previous old) ~after:(replace "owner" current fresh) (fun _ _ path ->
      let s=without_test |> replace "author" previous |> replace "owner" current in
      accepts path s;
      let f=Formatter.format_source s in accepts path f; check string "contextual field formatting" f (Formatter.format_source f)))
    ["select","enqueue"]
let proof_strengthening () = project ~after:(replace "  title: String\n" "  title: String ::: NonEmpty title\n" proof_schema) (fun _ _ path ->
  refuses "MIG022" path proof_source)

let public_backend_guard () = project (fun root save path ->
  let context=Result.get_ok (Migration_abi.current ()) in
  let load file = match Migration_inventory.load_with_compatibility
      ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility context))
      ~compiler_abi:(Migration_abi.id context) ~root_file:file with
    | Ok inventory -> inventory | Error error -> fail error.message in
  let seal inventory = match Migration_seal.create ~project_root:root inventory with
    | Ok seal -> seal | Error error -> fail error.message in
  let previous=load (Filename.concat root "schema/notes/v1.tesl") |> seal in
  let current=load (Filename.concat root "schema/notes/v-current.tesl") |> seal in
  let header=match Migration_header.create ~previous ~current with
    | Ok header -> header | Error _ -> fail "could not create checked source seals" in
  let sealed=Migration_header.encode header ^ source in
  ignore (save "migrations/notes/v2.tesl" sealed);
  accepts path sealed;
  let app={|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent
database Main = Database {
  schema: Schema.Notes.VCurrent
  migrations: Schema.Notes.Migrate
  backend: Postgres (PostgresConfig { dbName: "source-only", user: "source-only", password: "source-only", namespace: "notes", connection: TcpConnection { host: "127.0.0.1", port: 5432 } })
}
|} in
  let file=save "app.tesl" app in
  accepts file app;
  List.iter (fun debug -> match Compile.compile_go_source ~debug file app with
    | Compile.GoSuccess _ -> fail "public binary emitted a partially executable transform history"
    | Compile.GoFailure errors -> check bool ("actual sealed app refuses at execution boundary: " ^ describe errors) true
        (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG016" && Compile.string_contains d.message "transformation executor") errors)) [false;true])
let source_identity () = project (fun root save path ->
  let parsed=match Parser.parse_module path without_test with Ok m -> m | Err e -> fail e.msg in
  let original=List.find_map (function Ast.DFunc f when f.name="convert" -> Some f | _ -> None) parsed.decls |> Option.get in
  let d=match D.check ~compiler_abi:"test" ~source:without_test parsed with
    | Ok (Some d) -> d | _ -> fail "could not check original parsed AST" in
  let binding=Option.get (List.hd (T.rows (Option.get (D.transforms d)))).function_binding in
  check bool "row descriptor retains original declaration pointer" true (binding.declaration == original);
  check bool "row descriptor retains original expression pointer" true (binding.declaration.body == original.body);
  (* Exact supplied root buffers and imported source overlays are both honored;
     neither can accidentally reuse previously checked saved bytes. *)
  ignore (save "migrations/notes/v2.tesl" (replace "owner: old.author" "owner: old.title" without_test));
  ignore (checked path without_test);
  refuses "MIG017" path (Source_input.read path);
  let current=Filename.concat root "schema/notes/v-current.tesl" in
  Source_input.with_overlays ~project_root:root [current,replace "count: Int" "count: String" fresh] (fun () ->
    refuses "T001" path without_test);
  ignore (checked path without_test);
  refuses "T001" path (replace "count: 7" "count: \"seven\"" without_test))

let root_buffer_dependency () = project (fun root save path ->
  ignore (save "migrations/notes/helper.tesl" {|module Schema.Notes.Migrate.Helper exposing [computed]
import Tesl.Prelude exposing [Int]
import Schema.Notes.Migrate.V2
fn computed() -> Int = Schema.Notes.Migrate.V2.computed()
|});
  let original=without_test |> replace "exposing [migration, convert, oldNote]" "exposing [migration, convert, oldNote, computed]"
    |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Helper\nimport Schema.Notes.V1"
    |> replace "count: 7" "count: Schema.Notes.Migrate.Helper.computed()" in
  let original=original ^ "fn computed() -> Int = 7\n" in
  let changed=original |> replace "fn computed() -> Int = 7" "fn computed() -> String = \"wrong saved signature\"" in
  ignore (save "migrations/notes/v2.tesl" changed);
  let parsed source=match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
  (match D.check ~compiler_abi:"test" ~source:original (parsed original) with
   | Ok (Some _) -> ()
   | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors))
   | _ -> fail "missing transformation");
  (* Swapping saved and supplied source cannot validate the wrong dependency. *)
  ignore (save "migrations/notes/v2.tesl" original);
  (match D.check ~compiler_abi:"test" ~source:changed (parsed changed) with
   | Error errors -> check bool "helper sees actual supplied signature" true
       (List.exists (fun (e:S.error) -> e.code="T001") errors)
   | Ok _ -> fail "helper checked against the saved root instead of the supplied root");
  ignore root)

let same_fact_source schema =
  schema |> replace "exposing [Note]" "exposing [Note, ValidTitle, titleProof]"
  |> replace "entity Note" {|fact ValidTitle (value: String)
establish titleProof(value: String) -> Fact (ValidTitle value) = ValidTitle value
entity Note|}
  |> replace "title: String" "title: String ::: ValidTitle title"
let same_fact_copy_source = without_test
  |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.ValidTitle Schema.Notes.VCurrent.ValidTitle]"
  |> replace "fn oldNote() -> Schema.Notes.V1.Note =" "fn oldNote() -> Schema.Notes.V1.Note =\n  let title = \"hello\"\n  let proof = Schema.Notes.V1.titleProof title"
  |> replace "title: \"hello\"" "title: title ::: proof"
let same_fact_copy_boundary () =
  project ~before:(same_fact_source old) ~after:(same_fact_source fresh) (fun _ _ path ->
    let ds=errors path same_fact_copy_source in
    check bool ("cross-version proof copy currently refuses: " ^ describe ds) true (ds<>[]);
    check bool ("only the expected proof-ownership refusal remains: " ^ describe ds) true
      (List.for_all (fun (d:Compile.diagnostic) -> d.code="V001" && Compile.string_contains d.message "Schema.Notes.VCurrent.ValidTitle") ds);
    check bool ("the remaining boundary is ordinary proof ownership: " ^ describe ds) true
      (List.exists (fun (d:Compile.diagnostic) -> Compile.string_contains d.message "ValidTitle") ds))

let native_project ~after ~source = project ~after (fun root save path ->
  if Sys.command "go version >/dev/null 2>&1"<>0 then skip ();
  ignore (save "migrations/notes/v2.tesl" source);
  let artifacts=match Compile.compile_go_file path with
    | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  List.iter (fun (a:Emit_go.artifact) -> ignore (save ("out/" ^ a.path) a.contents)) artifacts;
  List.iter (fun name -> remove (Filename.concat root name)) ["schema";"migrations";"tesl.toml"];
  let command=Printf.sprintf "cd %s && GOMAXPROCS=2 go test -race -p 1 -count=1 -timeout=60s -v ./... 2>&1" (Filename.quote (Filename.concat root "out")) in
  let channel=Unix.open_process_in command in let output=In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> check bool "the source test actually executed" true (Compile.string_contains output "--- PASS:")
  | _ -> fail output)
let native () = native_project ~after:fresh ~source
let proof_native () = native_project ~after:proof_schema ~source:(proof_source ^ proof_tests)
let () = run "Transforming declarations" ["checked source",List.map (fun (name,f) -> test_case name `Quick f)
  ["original AST and exact mapping",basic;"exact nominal function signature",signature;
   "rename and unchanged projections",identities;"every successful return path",branches;
   "representative owned fixtures",fixtures;"all installation origins refuse execution",runtime_guard;
   "Derived owns its identity adapter",derived;"actual emitted pure function test",native;
   "optional new-field proof",proof_checked;"direct imports retain owner",imports;"pure owned executable closure",purity;
   "contextual rule validation",rules;"contextual field spellings",contextual_fields;
   "existing proof cannot strengthen by identity",proof_strengthening;"actual optional proof and rejection execution",proof_native;
   "public binary generation refuses sealed transforms",public_backend_guard;
   "physical AST and unsaved source identity",source_identity;
   "stdlib HTTP checks cannot escape result boundary",primitive_failure;
   "dependency checking uses supplied root source",root_buffer_dependency;
   "Same does not yet bridge proof ownership",same_fact_copy_boundary]]
