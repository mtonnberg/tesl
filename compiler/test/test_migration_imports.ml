open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then begin
    mkdir (Filename.dirname path); Unix.mkdir path 0o700
  end

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_project f =
  let root = Filename.temp_file "tesl-schema-import-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative text =
      let path = Filename.concat root relative in
      mkdir (Filename.dirname path);
      Out_channel.with_open_text path (fun channel -> output_string channel text);
      path
    in
    ignore (write "tesl.toml" "");
    f root write)

let layout () =
  let check_path name expected =
    check (option string) name expected (Validation_common.schema_module_relative_path name)
  in
  List.iter (fun (name, path) -> check_path name (Some path)) [
    "NotesSchema.VCurrent", "schema/notes/v-current.tesl";
    "NotesSchema.V7", "schema/notes/v7.tesl";
    "NotesSchema.VCurrent.Note", "schema/notes/v-current/note.tesl";
    "NotesSchema.V8.Shared.Types", "schema/notes/v8/shared/types.tesl";
    "NotesSchema.Migrate.V8", "migrations/notes/v8.tesl";
    "ShopSchema.Migrate.V10", "migrations/shop/v10.tesl";
    "NotesSchema.V2147483646", "schema/notes/v2147483646.tesl";
  ];
  List.iter (fun name -> check_path name None) [
    "NotesSchema.V0"; "NotesSchema.V01"; "NotesSchema.VCurrent/../../Secrets";
    "NotesSchema.V2147483647"; "NotesSchema.V999999999999999999999999";
    "NotesSchema..VCurrent"; "NotesSchema.VCurrent."; "NotesSchema.vCurrent";
    "NotesSchema.Other"; "Schema.VCurrent"; "Tesl.Prelude"; "Ordinary";
  ]

let resolution () = with_project (fun root write ->
  let live = write "schema/notes/v-current.tesl" "" in
  let child = write "schema/notes/v-current/note.tesl" "" in
  let migration = write "migrations/notes/v8.tesl" "" in
  let resolve source name = Validation_common.resolve_local_import_path source name in
  check string "from entry" live (resolve (Filename.concat root "app.tesl") "NotesSchema.VCurrent");
  check string "from child" live (resolve child "NotesSchema.VCurrent");
  check string "child from migration" child (resolve migration "NotesSchema.VCurrent.Note");
  check string "migration from schema" migration (resolve live "NotesSchema.Migrate.V8");
  let flat = write "NotesSchema.VCurrent.tesl" "" in
  check string "legacy flat precedence" flat (resolve (Filename.concat root "app.tesl") "NotesSchema.VCurrent");
  ignore (write "nested/tesl.toml" "");
  let missing = resolve (Filename.concat root "nested/app.tesl") "NotesSchema.VCurrent" in
  check bool "nested project cannot capture parent schema" false (Sys.file_exists missing);
  check string "missing path is inside target project"
    (Filename.concat root "nested/schema/notes/v-current.tesl") missing)

let whole_project () = with_project (fun root write ->
  ignore (write "schema/notes/v-current/shared.tesl" {|module NotesSchema.VCurrent.Shared exposing [double]
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int = n * 2
|});
  ignore (write "schema/notes/v-current.tesl" {|module NotesSchema.VCurrent exposing [value, Count, make, size, Box, Choice(..)]
import Tesl.Prelude exposing [Int, String]
import Tesl.String exposing [String.fromInt, String.length]
import NotesSchema.VCurrent.Shared exposing [double]
type Count = String
record Box { count: Count }
type Choice
  = Chosen Count
  | Empty
fn value(n: Int) -> Int = double n
fn make(n: Int) -> Count = Count (String.fromInt n)
fn size(n: Count) -> Int = String.length n.value
|});
  ignore (write "schema/notes/v7.tesl" {|module NotesSchema.V7 exposing [value, Count, make, size, Box, Choice(..)]
import Tesl.Prelude exposing [Int]
type Count = Int
record Box { count: Count }
type Choice
  = Chosen Count
  | Empty
fn value(n: Int) -> Int = n
fn make(n: Int) -> Count = Count n
fn size(n: Count) -> Int = n.value
|});
  ignore (write "migrations/notes/v8.tesl" {|module NotesSchema.Migrate.V8 exposing [combined, separate, nested, oldChoice, newChoice, optionalChoice]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.V7
import NotesSchema.VCurrent
fn combined(n: Int) -> Int = NotesSchema.V7.value n + NotesSchema.VCurrent.value n
fn separate(n: Int) -> Int =
  let before: NotesSchema.V7.Count = NotesSchema.V7.make n
  let after: NotesSchema.VCurrent.Count = NotesSchema.VCurrent.make n
  NotesSchema.V7.size before + NotesSchema.VCurrent.size after
fn nested(n: Int) -> Int =
  let old: NotesSchema.V7.Box = NotesSchema.V7.Box { count: NotesSchema.V7.Count n }
  let new: NotesSchema.VCurrent.Box = NotesSchema.VCurrent.Box { count: NotesSchema.VCurrent.make n }
  let choice: NotesSchema.V7.Choice = NotesSchema.V7.Chosen old.count
  NotesSchema.V7.size old.count + NotesSchema.VCurrent.size new.count
fn oldChoice(choice: NotesSchema.V7.Choice) -> Int =
  case choice of
    NotesSchema.V7.Chosen count -> NotesSchema.V7.size count
    NotesSchema.V7.Empty -> 0
fn newChoice(choice: NotesSchema.VCurrent.Choice) -> Int =
  case choice of
    NotesSchema.VCurrent.Chosen count -> NotesSchema.VCurrent.size count
    NotesSchema.VCurrent.Empty -> 0
fn optionalChoice(choice: Maybe NotesSchema.V7.Choice) -> Int =
  case choice of
    Something (NotesSchema.V7.Chosen count) -> NotesSchema.V7.size count
    Something NotesSchema.V7.Empty -> 0
    Nothing -> -1
|});
  let entry = write "app.tesl" {|module App exposing [result]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import NotesSchema.Migrate.V8
import NotesSchema.V7
import NotesSchema.VCurrent
fn result(n: Int) -> Int = NotesSchema.Migrate.V8.combined n
test "full schema import closure" {
  expect result 7 == 21
  expect NotesSchema.Migrate.V8.separate 7 == 8
  expect NotesSchema.Migrate.V8.nested 7 == 8
  expect NotesSchema.Migrate.V8.oldChoice (NotesSchema.V7.Chosen (NotesSchema.V7.Count 17)) == 17
  expect NotesSchema.Migrate.V8.oldChoice NotesSchema.V7.Empty == 0
  expect NotesSchema.Migrate.V8.newChoice (NotesSchema.VCurrent.Chosen (NotesSchema.VCurrent.make 17)) == 2
  expect NotesSchema.Migrate.V8.newChoice NotesSchema.VCurrent.Empty == 0
  expect NotesSchema.Migrate.V8.optionalChoice (Something (NotesSchema.V7.Chosen (NotesSchema.V7.Count 17))) == 17
  expect NotesSchema.Migrate.V8.optionalChoice (Something NotesSchema.V7.Empty) == 0
  expect NotesSchema.Migrate.V8.optionalChoice Nothing == -1
}
|} in
  match Compile.compile_go_file entry with
  | Compile.GoFailure diagnostics ->
    failf "schema import project rejected: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    let packages = artifacts |> List.filter (fun (a : Emit_go.artifact) ->
      Filename.check_suffix a.path "/module.go") in
    check int "all five local modules emitted" 5 (List.length packages);
    let output = Filename.concat root "emitted" in
    mkdir output;
    List.iter (fun (a : Emit_go.artifact) ->
      let path = Filename.concat output a.path in
      mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun out -> output_string out a.contents)) artifacts;
    let log = Filename.concat root "go-test.log" in
    let command = Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 ./... > %s 2>&1"
      (Filename.quote output) (Filename.quote log) in
    let status = Sys.command command in
    if status <> 0 then failf "emitted version-qualified calls failed (%d): %s" status
      (In_channel.with_open_text log In_channel.input_all))

let nominal_refusals () = with_project (fun _root write ->
  List.iter (fun (module_name, path) ->
    ignore (write path (Printf.sprintf {|module %s exposing [Count, make, Box, Choice(..)]
import Tesl.Prelude exposing [Int]

type Count = Int
type Private = Int
record Box { count: Count }
type Choice
  = Chosen Count
  | Empty
fn make(n: Int) -> Count = Count n
fn hidden(n: Int) -> Int = n
|} module_name))) [
    "NotesSchema.V7", "schema/notes/v7.tesl";
    "NotesSchema.VCurrent", "schema/notes/v-current.tesl";
  ];
  let entry_for body = write "migrations/notes/v8.tesl" ({|module NotesSchema.Migrate.V8 exposing []
import Tesl.Prelude exposing [Int]
import NotesSchema.V7
import NotesSchema.VCurrent
|} ^ body) in
  let valid = entry_for "fn valid(n: Int) -> NotesSchema.V7.Count = NotesSchema.V7.make n\n" in
  (match Compile.compile_go_file valid with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure diagnostics -> failf "negative-test dependencies must compile: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  let reject body =
    let entry = entry_for body in
    let errors = Compile.check_file entry |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
    check bool "negative fixture is syntactically valid" true
      (match Parser.parse_module entry (In_channel.with_open_text entry In_channel.input_all) with
       | Ok _ -> true | Err _ -> false);
    check bool "frontend refuses before emission" true (errors <> []);
    match Compile.compile_go_file entry with
    | Compile.GoFailure _ -> ()
    | Compile.GoSuccess _ -> fail "invalid version identity emitted"
  in
  reject "fn forged(old: NotesSchema.V7.Count) -> NotesSchema.VCurrent.Count = old\n";
  reject "fn privateCall(n: Int) -> Int = NotesSchema.V7.hidden n\n";
  reject "fn privateType(n: NotesSchema.V7.Private) -> NotesSchema.V7.Private = n\n";
  reject "fn privateBareType(n: Private) -> Private = n\n";
  reject "fn unexposedBareType(n: Count) -> Count = n\n";
  reject "fn imaginaryType(n: Ghost.Type) -> Ghost.Type = n\n";
  reject "fn forgedField(old: NotesSchema.V7.Box) -> NotesSchema.VCurrent.Count = old.count\n";
  reject "fn forgedConstructor(n: NotesSchema.V7.Count) -> NotesSchema.VCurrent.Choice = NotesSchema.V7.Chosen n\n";
  reject "fn wrongVersionPattern(choice: NotesSchema.V7.Choice) -> Int =\n  case choice of\n    NotesSchema.VCurrent.Chosen count -> 1\n    _ -> 0\n";
  reject "fn missingCase(choice: NotesSchema.V7.Choice) -> Int =\n  case choice of\n    NotesSchema.V7.Chosen count -> 1\n";
  reject "fn wrongPatternArity(choice: NotesSchema.V7.Choice) -> Int =\n  case choice of\n    NotesSchema.V7.Chosen a b -> 1\n    _ -> 0\n";
  reject "fn missingPatternPayload(choice: NotesSchema.V7.Choice) -> Int =\n  case choice of\n    NotesSchema.V7.Chosen -> 1\n    _ -> 0\n")

let private_constants () = with_project (fun _root write ->
  ignore (write "ordinary.tesl" {|module Ordinary exposing [visible]
import Tesl.Prelude exposing [Int]
hiddenValue = 42
fn visible(n: Int) -> Int = n + 7
|});
  let header = "module App exposing []\nimport Tesl.Prelude exposing [Int]\nimport Ordinary\n" in
  let valid = write "app.tesl" (header ^ "fn valid(n: Int) -> Int = Ordinary.visible n\n") in
  (match Compile.compile_go_file valid with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure diagnostics -> failf "ordinary constant fixture rejected: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  List.iter (fun value ->
    let entry = write "app.tesl" (header ^ "fn bad(n: Int) -> Int = " ^ value ^ " + n\n") in
    check bool "unexported constant rejected before emission" true
      (List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") (Compile.check_file entry));
    match Compile.compile_go_file entry with
    | Compile.GoFailure _ -> () | Compile.GoSuccess _ -> fail "private constant leaked"
  ) ["Ordinary.hiddenValue"; "hiddenValue"])

let header_recovery () =
  let source = "module NotesSchema.VCurrent.Note exposing []\nimport Tesl.Prelude exposing [Int]\nfn valid(n: Int) -> Int = n\nfn broken(\n" in
  match Parser.parse_module_recover "<schema-buffer>" source with
  | Some m -> check string "dotted header survives syntax error"
      "NotesSchema.VCurrent.Note" m.module_name
  | None -> fail "editor recovery lost schema module"

let schema_contents () = with_project (fun _root write ->
  let entry = write "app.tesl" {|module App exposing [Db]
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent exposing [Note]
database Db = Database { entities: [Note], backend: Memory }
|} in
  let header = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Env exposing [envRead, requireEnv]
|} in
  let entity = {|entity Note table "notes" primaryKey id { id: String, title: String }
fn pure(n: Int) -> Int = n + 1
|} in
  let check_source source =
    let path = write "schema/notes/v-current.tesl" source in
    (match Parser.parse_module path source with
     | Ok _ -> () | Err e -> failf "invalid test fixture: %s" e.msg);
    Checker.clear_import_parse_cache ();
    path, Compile.check_file entry
  in
  let _, diagnostics = check_source (header ^ entity) in
  check int "pure schema accepted" 0 (List.length (List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics));
  List.iter (fun body ->
    let path, diagnostics = check_source (header ^ body ^ "\n" ^ entity) in
    if not (List.exists (fun (d : Compile.diagnostic) -> d.file = path &&
        String.starts_with ~prefix:"schema modules cannot contain" d.message) diagnostics) then
      failf "no schema-content diagnostic for %s: %s" body
        (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.file ^ ": " ^ d.message) diagnostics));
    let standalone = Compile.check_file path in
    check bool "schema rules apply before an application binds a database" true
      (List.exists (fun (d : Compile.diagnostic) -> d.file = path &&
        String.starts_with ~prefix:"schema modules cannot contain" d.message) standalone);
    match Compile.compile_go_file entry with
    | Compile.GoFailure _ -> () | Compile.GoSuccess _ -> fail "forbidden schema emitted") [
    "database Hidden = Database { entities: [Note], backend: Memory }\n";
    "handler get bad(n: Int) -> Int = n\n";
    "main() -> Unit = Unit\n";
    "capability unsafe\n";
    "fn bad() -> String requires [envRead] = requireEnv \"SECRET\"\n";
    "fn bad() -> String = requireEnv \"SECRET\"\n";
    "setting = \"application-only\"\n";
    "test \"not part of history\" { expect 1 == 1 }\n";
  ];
  let path, _ = check_source (header ^ entity) in
  let unsaved = header ^ "handler get draft(n: Int) -> Int = n\n" ^ entity in
  let overlay_diagnostics = Compile.check_source path unsaved in
  check bool "unsaved schema body is checked instead of the clean disk copy" true
    (List.exists (fun (d : Compile.diagnostic) -> d.file = path &&
      String.starts_with ~prefix:"schema modules cannot contain" d.message) overlay_diagnostics);
  let snapshot = Compile.agent_context_source path unsaved in
  check bool "agent-context exposes the schema boundary in an unsaved buffer" true
    (try ignore (Str.search_forward (Str.regexp_string "schema modules cannot contain") snapshot 0); true
     with Not_found -> false);
  ignore (write "schema/notes/v-current/hidden.tesl" {|module NotesSchema.VCurrent.Hidden exposing []
import Tesl.Database exposing [Database, Memory]
database Hidden = Database { entities: [], backend: Memory }
|});
  let hidden_source = header ^ "import NotesSchema.VCurrent.Hidden\n" ^ entity in
  let _, diagnostics = check_source hidden_source in
  check bool "unexported child still checked" true (List.exists (fun (d : Compile.diagnostic) ->
    Filename.check_suffix d.file "hidden.tesl" && String.starts_with ~prefix:"schema modules cannot contain" d.message) diagnostics);
  ignore (write "operations.tesl" {|module Operations exposing [pure]
import Tesl.Prelude exposing [Int]
fn pure(n: Int) -> Int = n
|});
  let _, diagnostics = check_source (header ^ "import Operations\n" ^ entity) in
  check bool "even a pure application import is outside frozen ownership" true
    (List.exists (fun (d : Compile.diagnostic) ->
      String.starts_with ~prefix:"schema module `NotesSchema.VCurrent` may import only" d.message) diagnostics))

let migration_contents () = with_project (fun _root write ->
  let path = "migrations/notes/v8.tesl" in
  let header = {|module NotesSchema.Migrate.V8 exposing [pure]
import Tesl.Prelude exposing [String, Int, Unit]
import Tesl.Database exposing [Database, Memory]
import Tesl.Env exposing [envRead, requireEnv]
|} in
  let pure_fn = "fn pure(n: Int) -> Int = n + 1\n" in
  let pure = "migrationFixture = 7\n" ^ pure_fn in
  let entry = write "app.tesl" {|module App exposing [result]
import Tesl.Prelude exposing [Int]
import NotesSchema.Migrate.V8 exposing [pure]
fn result(n: Int) -> Int = pure n
|} in
  let check source =
    let file = write path source in
    (match Parser.parse_module file source with Ok _ -> () | Err e -> failf "invalid migration fixture: %s" e.msg);
    Checker.clear_import_parse_cache ();
    file, Compile.check_file file in
  let _, valid = check (header ^ pure) in
  Alcotest.check int "pure migration helpers and constants are allowed" 0
    (List.length (List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") valid));
  let boundary diagnostics = List.exists (fun (d : Compile.diagnostic) ->
    String.starts_with ~prefix:"migration modules cannot contain" d.message) diagnostics in
  List.iter (fun body ->
    let _, diagnostics = check (header ^ body ^ "\n" ^ pure_fn) in
    Alcotest.check bool "standalone migration rejects application contents" true (boundary diagnostics);
    Alcotest.check bool "application import also rejects them" true (boundary (Compile.check_file entry));
    match Compile.compile_go_file entry with
    | Compile.GoFailure _ -> () | Compile.GoSuccess _ -> fail "effectful migration was emitted") [
    "database Db = Database { entities: [], backend: Memory }\n";
    "handler get bad(n: Int) -> Int = n\n";
    "main() -> Unit = Unit\n";
    "capability unsafe\n";
    "fn bad() -> String requires [envRead] = requireEnv \"SETTING\"\n";
    "setting = requireEnv \"SETTING\"\n";
    "entity Note table \"notes\" primaryKey id { id: String }\n";
    "test \"history cannot run application tests\" { expect 1 == 1 }\n";
  ];
  let file, _ = check (header ^ pure) in
  let draft = header ^ "handler get draft(n: Int) -> Int = n\n\n" ^ pure_fn in
  Alcotest.check bool "unsaved migration buffer is checked" true (boundary (Compile.check_source file draft));
  ignore (write "operations.tesl" "module Operations exposing []\n");
  let _, diagnostics = check (header ^ "import Operations\n" ^ pure) in
  Alcotest.check bool "application imports cannot enter frozen migration closure" true
    (List.exists (fun (d : Compile.diagnostic) -> String.starts_with ~prefix:"migration module `" d.message) diagnostics))

let schema_ownership () = with_project (fun _root write ->
  List.iter (fun (module_name, path, entity) ->
    ignore (write path (Printf.sprintf {|module %s exposing [%s]
import Tesl.Prelude exposing [String]
entity %s table "%s" primaryKey id { id: String }
|} module_name entity entity (String.lowercase_ascii entity)))) [
    "NotesSchema.VCurrent.Notes", "schema/notes/v-current/notes.tesl", "Note";
    "NotesSchema.VCurrent.Memos", "schema/notes/v-current/memos.tesl", "Memo";
    "OtherSchema.VCurrent", "schema/other/v-current.tesl", "Other";
    "NotesSchema.V7", "schema/notes/v7.tesl", "Historic";
  ];
  let header = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent.Notes exposing [Note]
import NotesSchema.VCurrent.Memos exposing [Memo]
import OtherSchema.VCurrent exposing [Other]
import NotesSchema.V7 exposing [Historic]
|} in
  let db name entities = Printf.sprintf "database %s = Database { entities: [%s], backend: Memory }\n" name entities in
  let check_source imports body =
    let source = header ^ imports ^ body in
    let entry = write "app.tesl" source in
    Checker.clear_import_parse_cache ();
    (match Parser.parse_module entry source with Ok _ -> () | Err e -> failf "invalid ownership fixture: %s" e.msg);
    entry, source, Compile.check_file entry in
  let errors diagnostics = List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics in
  let reject imports body fragment =
    let entry, _, diagnostics = check_source imports body in
    check bool "ownership is rejected by the frontend" true
      (List.exists (fun (d : Compile.diagnostic) ->
        try ignore (Str.search_forward (Str.regexp_string fragment) d.message 0); true with Not_found -> false) (errors diagnostics));
    match Compile.compile_go_file entry with
    | Compile.GoFailure _ -> () | Compile.GoSuccess _ -> fail "invalid database ownership emitted" in
  let entry, original, diagnostics = check_source "" (db "NotesDb" "Note, Memo" ^ db "OtherDb" "Other") in
  check int "different families have independent connection owners" 0 (List.length (errors diagnostics));
  (match Compile.compile_go_file entry with
   | Compile.GoSuccess _ -> () | Compile.GoFailure diagnostics -> failf "valid ownership did not emit: %s"
       (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics)));
  let draft = original ^ db "Duplicate" "NotesSchema.VCurrent.Memos.Memo" in
  check bool "unsaved duplicate is checked from the entry overlay" true
    (List.exists (fun (d : Compile.diagnostic) -> String.starts_with ~prefix:"schema family `" d.message)
       (Compile.check_source entry draft));
  check bool "agent-context also reports the unsaved owner" true
    (try ignore (Str.search_forward (Str.regexp_string "belongs to two databases") (Compile.agent_context_source entry draft) 0); true
     with Not_found -> false);
  let new_entry = Filename.concat (Filename.dirname entry) "new-app.tesl" in
  check bool "new unsaved application has no backing file" false (Sys.file_exists new_entry);
  check bool "new unsaved application still checks imported ownership" true
    (List.exists (fun (d : Compile.diagnostic) -> String.starts_with ~prefix:"schema family `" d.message)
       (Compile.check_source new_entry draft));
  reject "" (db "First" "Note" ^ db "Second" "Memo") "belongs to two databases";
  reject "" (db "Mixed" "Note, Other") "cannot combine schema families";
  reject "" (db "Old" "Historic") "cannot bind historical schema";
  ignore (write "connections.tesl" ({|module Connections exposing [ImportedDb]
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent.Memos exposing [Memo]
|} ^ db "ImportedDb" "Memo"));
  reject "import Connections\n" (db "LocalDb" "Note") "belongs to two databases";
  let _, _, restored = check_source "" (db "Only" "Note, Memo") in
  check int "a rejected overlay does not contaminate later checks" 0 (List.length (errors restored));
  let local = write "local.tesl" ({|module Local exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import NotesSchema.V7
import NotesSchema.VCurrent.Notes
entity Historic table "local_history" primaryKey id { id: String }
entity Note table "local_notes" primaryKey id { id: String }
|} ^ db "LegacyDb" "Historic, Note" ^ db "SchemaDb" "NotesSchema.VCurrent.Notes.Note") in
  check int "local entities are not mistaken for qualified-only imports" 0
    (List.length (errors (Compile.check_file local))))

let module_reference_binding () = with_project (fun _root write ->
  let parse path text = match Parser.parse_module path text with
    | Ok m -> m | Err e -> failf "fixture parse: %s" e.msg in
  ignore (write "schema/notes/v-current.tesl" {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent.Left
import NotesSchema.VCurrent.Right
entity Note table "notes" primaryKey id { id: String }
|});
  List.iter (fun name -> ignore (write ("schema/notes/v-current/" ^ String.lowercase_ascii name ^ ".tesl")
    ("module NotesSchema.VCurrent." ^ name ^ " exposing []\nimport NotesSchema.VCurrent.Hidden\n"))) ["Left"; "Right"];
  let hidden = {|module NotesSchema.VCurrent.Hidden exposing []
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent
entity Secret table "hidden_notes" primaryKey id { id: String }
|} in
  let hidden_path = write "schema/notes/v-current/hidden.tesl" hidden in
  let app schema migrations extra imported =
    let text = "module App exposing []\n" ^ imported ^ "\ndatabase Db = Database { schema: " ^ schema
      ^ "\n migrations: " ^ migrations ^ "\n backend: Memory\n" ^ extra ^ "\n}\n" in
    let path = write "app.tesl" text in
    parse path text in
  let source () = app "NotesSchema.VCurrent" "NotesSchema.Migrate" "" "import NotesSchema.VCurrent" in
  let resolve ?modules m =
    let db = List.find_map (function Ast.DDatabase d -> Some d | _ -> None) m.Ast.decls |> Option.get in
    Migration_schema.resolve_binding ?modules m db in
  let binding = match resolve (source ()) with
    | Ok (Some b) -> b | _ -> fail "schema module binding was not resolved" in
  check (list string) "private diamond/cyclic closure contributes each entity once"
    ["NotesSchema.VCurrent.Hidden.Secret"; "NotesSchema.VCurrent.Note"] (List.map fst binding.members);
  List.iter (fun (schema, migrations, extra, imported) ->
    check bool "invalid contextual reference is refused" true
      (Result.is_error (resolve (app schema migrations extra imported)))) [
    "NotesSchema.V7", "NotesSchema.Migrate", "", "import NotesSchema.VCurrent";
    "NotesSchema.VCurrent.Hidden", "NotesSchema.Migrate", "", "import NotesSchema.VCurrent.Hidden";
    "NotesSchema.VCurrent", "OtherSchema.Migrate", "", "import NotesSchema.VCurrent";
    "NotesSchema.VCurrent", "NotesSchema.Migrate.V8", "", "import NotesSchema.VCurrent";
    "NotesSchema.VCurrent", "NotesSchema.Migrate", "entities: []", "import NotesSchema.VCurrent";
    "NotesSchema.VCurrent", "NotesSchema.Migrate", "", "";
  ];
  let refuse_child text reason =
    ignore (write "schema/notes/v-current/hidden.tesl" text);
    match resolve (source ()) with
    | Error errors -> check bool reason true
        (List.exists (fun (e : Validation_common.validation_error) ->
           try ignore (Str.search_forward (Str.regexp_string reason) e.message 0); true with Not_found -> false) errors)
    | _ -> failf "schema binding accepted %s" reason in
  refuse_child (hidden ^ "\ndatabase Bad = Database { entities: [], backend: Memory }\n") "database declarations";
  refuse_child (Str.global_replace (Str.regexp_string "import Tesl.Prelude")
    "import OtherSchema.VCurrent\nimport Tesl.Prelude" hidden) "outside its ownership closure";
  refuse_child (Str.global_replace (Str.regexp_string "hidden_notes") "notes" hidden) "same physical table";
  ignore (write "schema/notes/v-current/hidden.tesl" hidden);
  let overlay = parse hidden_path (Str.global_replace (Str.regexp_string "hidden_notes") "overlay_notes" hidden) in
  (match resolve ~modules:[overlay] (source ()) with
   | Ok (Some b) -> check (list string) "parsed overlays override disk" ["overlay_notes"; "notes"]
       (List.map (fun (_, (e : Ast.entity_form)) -> e.table) b.members)
   | _ -> fail "schema overlay failed");
  let renamed = parse hidden_path "module OtherSchema.VCurrent exposing []\n" in
  check bool "renamed overlay cannot fall back to stale disk" true
    (Result.is_error (resolve ~modules:[renamed] (source ())));
  Sys.remove hidden_path;
  check bool "missing private child is not silently omitted" true (Result.is_error (resolve (source ()))))

let module_reference_compilation () = with_project (fun root write ->
  let schema = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent.Hidden
entity Note table "notes" primaryKey id { id: String }
entity Secret table "root_secrets" primaryKey id { id: String }
|} in
  ignore (write "schema/notes/v-current.tesl" schema);
  let child cycle = "module NotesSchema.VCurrent.Hidden exposing []\nimport Tesl.Prelude exposing [String]\n"
    ^ (if cycle then "import NotesSchema.VCurrent\n" else "")
    ^ "entity Secret table \"hidden_notes\" primaryKey id { id: String }\n" in
  let source = {|module App exposing [Db]
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent exposing [Note]
database Db = Database {
  schema: NotesSchema.VCurrent
  migrations: NotesSchema.Migrate
  backend: Postgres (PostgresConfig {
    namespace: "owned_notes"
    dbName: "unused"
    user: "unused"
    password: "unused"
    connection: TcpConnection { host: "localhost", port: 5432 }
  })
}
record Secret { value: Int }
fn localValue() -> Int =
  let local = Secret { value: 42 }
  local.value
fn readNote() -> String requires [dbRead Note] =
  case selectOne n from Note where n.id == "public" of
    Something n -> n.id
    Nothing -> "missing"
test "schema ownership preserves local types and ordinary entity queries" requires [dbRead Note, dbWrite Note] {
  expect localValue() == 42
  let _ = insert Note { id: "public" }
  expect readNote() == "public"
}
|} in
  let entry = write "app.tesl" source in
  List.iter (fun cycle ->
    ignore (write "schema/notes/v-current/hidden.tesl" (child cycle));
    let diags = Compile.check_file entry in
    if diags <> [] then failf "module-reference check failed: %s" (Compile.diagnostics_to_json diags);
    match Compile.compile_go_file entry with
    | Compile.GoFailure diagnostics -> failf "module-reference emission failed: %s" (Compile.diagnostics_to_json diagnostics)
    | Compile.GoSuccess artifacts ->
      let output = Filename.concat root (if cycle then "cyclic" else "acyclic") in
      List.iter (fun (a : Emit_go.artifact) ->
        let path = Filename.concat output a.path in mkdir (Filename.dirname path);
        Out_channel.with_open_bin path (fun channel -> output_string channel a.contents)) artifacts;
      let metadata = Filename.concat output "internal/teslmodapp/ownership_test.go" in
      Out_channel.with_open_text metadata (fun channel -> output_string channel {|package teslmodapp
import "testing"
func TestPrivateSchemaCatalog(t *testing.T) {
  if DbDatabase.Config.Schema != "owned_notes" { t.Fatal("physical namespace was lost") }
  got := map[string]int{}
  for _, table := range DbDatabase.Tables { got[table.Name]++ }
  if len(got)!=3 || got["notes"]!=1 || got["root_secrets"]!=1 || got["hidden_notes"]!=1 {
    t.Fatalf("private/duplicate schema membership was lost: %v", got)
  }
}
|});
      let log = Filename.concat output "go-test.log" in
      let status = Sys.command (Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 ./... > %s 2>&1"
        (Filename.quote output) (Filename.quote log)) in
      if status <> 0 then failf "module-reference runtime failed: %s" (In_channel.with_open_text log In_channel.input_all)
  ) [false; true];
  List.iter (fun body ->
    let entry = write "app.tesl" (source ^ body) in
    let diags = Compile.check_file entry in
    check bool "ownership does not expose private terms, types or a module value" true
      (List.exists (fun (d : Compile.diagnostic) -> d.severity = "error") diags)) [
    "\nfn hidden() -> NotesSchema.VCurrent.Secret = NotesSchema.VCurrent.Secret { id: \"bad\" }\n";
    "\nfn hidden() -> NotesSchema.VCurrent.Hidden.Secret = NotesSchema.VCurrent.Hidden.Secret { id: \"bad\" }\n";
    "\nfn moduleValue() -> Int = NotesSchema.VCurrent\n";
  ])

let module_reference_configuration () = with_project (fun _root write ->
  let root_source = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent.Hidden
entity Note table "notes" primaryKey id { id: String }
entity Secret table "secrets" primaryKey id { id: String }
|} in
  ignore (write "schema/notes/v-current.tesl" root_source);
  ignore (write "schema/notes/v-current/hidden.tesl" {|module NotesSchema.VCurrent.Hidden exposing [Hidden]
import Tesl.Prelude exposing [String]
entity Hidden table "hidden" primaryKey id { id: String }
|});
  let header = {|module App exposing [Db]
import Tesl.Prelude exposing [Int]
import Tesl.Env exposing [envRead]
import Tesl.Database exposing [Database, Memory, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent exposing [Note]
|} in
  let postgres namespace = "Postgres (PostgresConfig { " ^ namespace ^ {|
dbName: "unused", user: "unused", password: "unused"
connection: TcpConnection { host: "localhost", port: 5432 }
})|} in
  let db fields backend = "database Db = Database { " ^ fields ^ "\n backend: " ^ backend ^ "\n}\n" in
  let fields = "schema: NotesSchema.VCurrent\nmigrations: NotesSchema.Migrate" in
  let errors diagnostics = List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics in
  let check_config label source expected =
    let entry = write "app.tesl" source in
    let diagnostics = errors (Compile.check_file entry) in
    (match expected with
     | None -> if diagnostics <> [] then failf "%s: %s" label (Compile.diagnostics_to_json diagnostics)
     | Some fragment ->
       check bool label true (List.exists (fun (d : Compile.diagnostic) ->
         try ignore (Str.search_forward (Str.regexp_string fragment) d.message 0); true
         with Not_found -> false) diagnostics));
    entry in
  ignore (check_config "memory ownership" (header ^ db fields "Memory") None);
  ignore (check_config "63-byte physical namespace" (header ^ db fields (postgres ("namespace: \"" ^ String.make 63 'a' ^ "\""))) None);
  List.iter (fun (label, fields, backend, message) ->
    ignore (check_config label (header ^ db fields backend) (Some message))) [
    "missing migrations", "schema: NotesSchema.VCurrent", "Memory", "requires `migrations:";
    "string migrations", "schema: NotesSchema.VCurrent\nmigrations: \"NotesSchema.Migrate\"", "Memory", "module prefix";
    "function reference", "schema: choose()\nmigrations: NotesSchema.Migrate", "Memory", "schema module reference";
    "missing namespace", fields, postgres "", "PostgresConfig.namespace";
    "empty namespace", fields, postgres "namespace: \"\"", "PostgresConfig.namespace";
    "dynamic namespace", fields, postgres "namespace: env \"PGSCHEMA\"", "PostgresConfig.namespace";
    "long namespace", fields, postgres ("namespace: \"" ^ String.make 64 'a' ^ "\""), "PostgresConfig.namespace";
    "legacy entities required", "schema: \"legacy\"", postgres "", "missing required field `entities`";
    "legacy migrations refused", "schema: \"legacy\"\nentities: [Note]\nmigrations: NotesSchema.Migrate", postgres "", "cannot also specify";
    "legacy namespace refused", "schema: \"legacy\"\nentities: [Note]", postgres "namespace: \"second\"", "cannot also specify";
  ];
  (* Config references must obey source visibility even though codegen's lowered
     ownership projection can intentionally name every private member. *)
  List.iter (fun entity ->
    ignore (check_config ("legacy invisible entity " ^ entity)
      (header ^ db ("entities: [" ^ entity ^ "]") "Memory") (Some "unknown entity"))) [
    "Secret"; "NotesSchema.VCurrent.Secret"; "NotesSchema.VCurrent.Hidden.Hidden"; "Missing";
  ];
  let qualified_header = Str.global_replace (Str.regexp_string "exposing [Note]\n") "\n" header in
  ignore (check_config "qualified-only import cannot become bare config name"
    (qualified_header ^ db "entities: [Note]" "Memory") (Some "unknown entity"));
  ignore (check_config "qualified public entity remains supported"
    (qualified_header ^ db "entities: [NotesSchema.VCurrent.Note]" "Memory") None);
  ignore (write "schema/notes/v-current.tesl" "module NotesSchema.VCurrent exposing []\n");
  let empty_header = Str.global_replace (Str.regexp_string "exposing [Note]\n") "exposing []\n" header in
  let empty_source = empty_header ^ db fields "Memory" in
  let entry = check_config "empty schema closure is valid" empty_source None in
  (match Compile.compile_go_file entry with
   | Compile.GoSuccess _ -> ()
   | Compile.GoFailure diagnostics -> failf "empty ownership did not emit: %s" (Compile.diagnostics_to_json diagnostics)))

let module_reference_entrypoints () = with_project (fun root write ->
  let schema_source = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String }
entity Private table "private_notes" primaryKey id { id: String }
|} in
  let schema_file = write "schema/notes/v-current.tesl" schema_source in
  let source = {|module App exposing [Db, main]
import Tesl.Prelude exposing [List]
import Tesl.Database exposing [Database, Memory]
import Tesl.DB exposing [dbRead]
import Tesl.App exposing [App]
import NotesSchema.VCurrent exposing [Note]
database Db = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
handler get listNotes() -> List Note requires [dbRead Note] = select n from Note
api Notes { get "/notes" -> List Note }
server NotesServer for Notes { listNotes }
main() -> App requires [dbRead Note] = App { database: Db, api: NotesServer, port: 8080 }
|} in
  let entry = Filename.concat root "app.tesl" in
  let parse path text = match Parser.parse_module path text with
    | Ok m -> m | Err e -> failf "entrypoint fixture: %s" e.msg in
  let artifacts = function
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure diagnostics -> failf "entrypoint rejected valid module ownership: %s" (Compile.diagnostics_to_json diagnostics) in
  let compare_artifacts message expected actual =
    let contents artifacts = List.map (fun (a : Emit_go.artifact) -> a.path, a.contents) artifacts |> List.sort compare in
    check (list (pair string string)) message (contents expected) (contents actual) in
  let unsaved = artifacts (Compile.compile_go_source entry source) in
  ignore (write "app.tesl" "module App exposing []\n");
  let overlay = artifacts (Compile.compile_go_source ~path:entry entry source) in
  compare_artifacts "source graph uses the overlay's imports, not stale disk" unsaved overlay;
  ignore (write "app.tesl" source);
  let saved = artifacts (Compile.compile_go_file entry) in
  compare_artifacts "new unsaved and saved applications emit the same complete graph" saved unsaved;
  let m = parse entry source and schema = parse schema_file schema_source in
  (match Emit_go.compile_project ~entry:m [m; schema] with
   | Ok direct -> compare_artifacts "direct project API resolves raw module ownership" saved direct
   | Error errors -> failf "direct project API failed: %s" (String.concat "; " (List.map (fun (e : Emit_go.emit_error) -> e.message) errors)));
  check bool "single-module API refuses unresolved ownership" true (Result.is_error (Emit_go.compile_module m));
  let wrong = Str.global_replace (Str.regexp_string "requires [dbRead Note] = App")
    "requires [dbRead Unowned] = App" source in
  check bool "main cannot grant an entity outside its schema" true
    (List.exists (fun (d : Compile.diagnostic) ->
      try ignore (Str.search_forward (Str.regexp_string "not in the database selected") d.message 0); true
      with Not_found -> false) (Compile.check_source entry wrong));
  let missing = Str.global_replace (Str.regexp_string "import NotesSchema.VCurrent exposing [Note]\n") "" source in
  check bool "unsaved module reference does not inherit a disk import" true
    (List.exists (fun (d : Compile.diagnostic) ->
      try ignore (Str.search_forward (Str.regexp_string "must be imported directly") d.message 0); true
      with Not_found -> false) (Compile.check_source entry missing)))

let source_rewrite () =
  let rewrite before after source =
    match Migration_source.rewrite_version ~family:"NotesSchema" ~before ~after source with
    | Ok value -> value | Error message -> failf "source rewrite: %s" message in
  let source = {|# NotesSchema.VCurrent is documentation, not a reference.
module NotesSchema.VCurrent.Shared exposing [render]
import Tesl.Prelude exposing [Int, String]
import NotesSchema.VCurrent.Helpers
fn render(n: Int) -> String =
  "å NotesSchema.VCurrent\n\t\"quoted\" ${NotesSchema.VCurrent.Helpers.value n} ${OtherSchema.VCurrent.value n}"
|} in
  let expected = {|# NotesSchema.VCurrent is documentation, not a reference.
module NotesSchema.V8.Shared exposing [render]
import Tesl.Prelude exposing [Int, String]
import NotesSchema.V8.Helpers
fn render(n: Int) -> String =
  "å NotesSchema.VCurrent\n\t\"quoted\" ${NotesSchema.V8.Helpers.value n} ${OtherSchema.VCurrent.value n}"
|} in
  check string "only owned reference segments change, including interpolations" expected
    (rewrite "VCurrent" "V8" source);
  check string "rewrite is idempotent" expected (rewrite "VCurrent" "V8" expected);
  check string "inverse preserves every other byte" source (rewrite "V8" "VCurrent" expected);
  let references = "\tNotesSchema . VCurrent.f + NotesSchema.VCurrentExtra.f + Wrapper.NotesSchema.VCurrent.f\r\n\t\tNotesSchema.VCurrent.g\r\n" in
  check string "tabs, CRLF, exact segment and prefix boundaries"
    "\tNotesSchema . V12.f + NotesSchema.VCurrentExtra.f + Wrapper.NotesSchema.VCurrent.f\r\n\t\tNotesSchema.V12.g\r\n"
    (rewrite "VCurrent" "V12" references);
  check string "literal strings inside interpolated expressions are not references"
    {|"${NotesSchema.V8.label \"NotesSchema.VCurrent\"}"|}
    (rewrite "VCurrent" "V8" {|"${NotesSchema.VCurrent.label \"NotesSchema.VCurrent\"}"|});
  List.iter (fun after ->
    check bool "invalid target refused" true
      (Result.is_error (Migration_source.rewrite_version ~family:"NotesSchema" ~before:"VCurrent" ~after source)))
    ["V0"; "V01"; "V2147483647"; "V999999999999999999999"; "V8/../Other"; "V"; "Current"];
  check bool "unterminated interpolation refused without a partial result" true
    (Result.is_error (Migration_source.rewrite_version ~family:"NotesSchema" ~before:"VCurrent" ~after:"V8"
       {|module NotesSchema.VCurrent exposing []
label = "${NotesSchema.VCurrent.value"
|}));
  for version = 1 to 100 do
    let target = "V" ^ string_of_int version in
    check string "version renaming round trip" source
      (rewrite target "VCurrent" (rewrite "VCurrent" target source))
  done

let freeze_closure () = with_project (fun root write ->
  let live = write "schema/notes/v-current.tesl" {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent.Hidden
entity Note table "notes" primaryKey id { id: String }
|} in
  let child = write "schema/notes/v-current/hidden.tesl" {|module NotesSchema.VCurrent.Hidden exposing []
import Tesl.Prelude exposing [String]
import NotesSchema.VCurrent
entity PrivateRow table "private_rows" primaryKey id { id: String }
|} in
  let freeze () = Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:7 in
  let copies = match freeze () with Ok copies -> copies | Error message -> fail message in
  check int "complete cyclic closure, including unexported entities" 2 (List.length copies);
  check bool "preview creates no snapshot" false (Sys.file_exists (Filename.concat root "schema/notes/v7.tesl"));
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    let before = In_channel.with_open_bin copy.source_path In_channel.input_all in
    check string "source precondition binds exact input bytes" (Migration_hash.digest before) copy.source_digest;
    check bool "only owned source files copied" true (List.mem copy.source_path [live; child]);
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun out -> output_string out copy.contents)) copies;
  (match freeze () with
   | Ok copies -> check int "idempotent freeze emits no edits" 0 (List.length copies)
   | Error message -> fail message);
  let frozen_child = Filename.concat root "schema/notes/v7/hidden.tesl" in
  let before = In_channel.with_open_bin frozen_child In_channel.input_all in
  Out_channel.with_open_bin frozen_child (fun out -> output_string out (before ^ "# edited history\n"));
  check bool "differing history is never overwritten" true (Result.is_error (freeze ()));
  check string "refusal preserves existing bytes" (before ^ "# edited history\n")
    (In_channel.with_open_bin frozen_child In_channel.input_all);
  Sys.remove frozen_child;
  ignore (write "schema/notes/v-current/hidden.tesl" {|module Incorrect exposing []
|});
  check bool "module header must match the owned path" true (Result.is_error (freeze ())))

let freeze_boundaries () = with_project (fun root write ->
  let live = "schema/notes/v-current.tesl" in
  let freeze () = Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:8 in
  List.iter (fun family ->
    check bool "nested or malformed family refused by rewrite" true
      (Result.is_error (Migration_source.rewrite_version ~family ~before:"VCurrent" ~after:"V8" ""));
    check bool "nested or malformed family refused by freeze" true
      (Result.is_error (Migration_source.freeze_closure ~project_root:root ~family ~version:8)))
    ["NotesSchema.V7"; "NotesSchema.Migrate"; "NotesSchema/Other"; "notesSchema"; "Schema"; ""];
  ignore (write live "module NotesSchema.VCurrent exposing []\nimport Application\n");
  check bool "application imports refused" true (Result.is_error (freeze ()));
  ignore (write live "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Missing\n");
  check bool "missing closure member refused" true (Result.is_error (freeze ()));
  ignore (write live "module NotesSchema.VCurrent exposing []\nimport Tesl.Database exposing [Database, Memory]\ndatabase Db = Database { entities: [], backend: Memory }\n");
  check bool "connection config refused" true (Result.is_error (freeze ()));
  ignore (write live "module NotesSchema.VCurrent exposing []\n");
  let outside = write "application.tesl" "module NotesSchema.VCurrent exposing []\n" in
  Sys.remove (Filename.concat root live);
  Unix.symlink outside (Filename.concat root live);
  check bool "input symlink cannot capture application source" true (Result.is_error (freeze ()));
  Sys.remove (Filename.concat root live);
  ignore (write live "module NotesSchema.VCurrent exposing []\n");
  Unix.symlink outside (Filename.concat root "schema/notes/v8.tesl");
  check bool "output symlink is not overwritten or treated as existing history" true (Result.is_error (freeze ()));
  Sys.remove (Filename.concat root "schema/notes/v8.tesl");
  ignore (write live "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Hidden\n");
  ignore (write "schema/notes/v-current/hidden.tesl" "module NotesSchema.VCurrent.Hidden exposing []\n");
  let parent = Filename.concat root "schema/notes/v8" in
  Unix.symlink (Filename.concat root "not-created") parent;
  check bool "dangling output directory symlink is refused before a manifest" true (Result.is_error (freeze ()));
  check bool "preview did not follow or create dangling destination" false (Sys.file_exists (Filename.concat root "not-created"));
  Sys.remove parent;
  Unix.symlink (Filename.concat root "schema/notes/v-current") parent;
  check bool "existing directory symlink cannot turn history into live sources" true (Result.is_error (freeze ()));
  check string "refusal preserves source" "module NotesSchema.VCurrent.Hidden exposing []\n"
    (In_channel.with_open_bin (Filename.concat root "schema/notes/v-current/hidden.tesl") In_channel.input_all))

let () = run "migration-imports" ["source layout", [
  test_case "canonical paths and invalid names" `Quick layout;
  test_case "ancestor resolution, legacy precedence, project isolation" `Quick resolution;
  test_case "compiler loads the complete local schema closure" `Quick whole_project;
  test_case "same representation does not merge nominal identities or exports" `Quick nominal_refusals;
  test_case "qualified imports do not expose private application constants" `Quick private_constants;
  test_case "dotted module headers in editor recovery" `Quick header_recovery;
  test_case "database-selected schema closure excludes application code" `Quick schema_contents;
  test_case "migration modules exclude application code and entity ownership" `Quick migration_contents;
  test_case "schema families have one application connection owner" `Quick schema_ownership;
  test_case "module references select private cyclic ownership with overlays" `Quick module_reference_binding;
  test_case "module references compile private tables without exposing names" `Quick module_reference_compilation;
  test_case "module configuration and legacy entity visibility" `Quick module_reference_configuration;
  test_case "module ownership through source, project and main entrypoints" `Quick module_reference_entrypoints;
  test_case "frozen-copy rewrite preserves source bytes and literal text" `Quick source_rewrite;
  test_case "freeze previews the whole closure and preserves existing history" `Quick freeze_closure;
  test_case "freeze rejects content, missing sources and path escapes" `Quick freeze_boundaries;
]]
