open Alcotest
module G = Migration_generate
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let contains = Compile.string_contains
let inspect path source = ignore (Compile.agent_context_result_source path source)
let save path source = write path source; inspect path source
let errors ds = List.filter (fun (d : Compile.diagnostic) -> d.severity="error") ds
let describe ds = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.file ^ ": " ^ d.code ^ ": " ^ d.message) ds)
let check_source ?skip_dep_body file source = Compile.check_source ?skip_dep_body file source |> errors
let accepts file source = let ds = check_source file source in if ds <> [] then fail (describe ds)
let refuses ?skip_dep_body code file source =
  let ds = check_source ?skip_dep_body file source in
  if not (List.exists (fun (d : Compile.diagnostic) -> d.code=code) ds) then fail ("missing " ^ code ^ "\n" ^ describe ds); ds
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e : G.error) -> e.message) es))
let schema = {|module NotesSchema.VCurrent exposing []
import NotesSchema.VCurrent.Notes
|}
let child = {|module NotesSchema.VCurrent.Notes exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, title: String }
|}
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database {
  schema: NotesSchema.VCurrent
  migrations: NotesSchema.Migrate
  backend: Memory
}
|}
let start root family version =
  let context = Result.get_ok (Migration_abi.current ()) in
  let p = get (G.start_with_compatibility
    ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility context))
    ~compiler_abi:(Migration_abi.id context) ~project_root:root ~family ~version ~documents:[]) in
  (match M.verify_disk p.manifest with Ok () -> () | Error _ -> fail "stale fixture");
  List.iter (fun (e : M.edit) -> save e.path e.after) (M.edits p.manifest)
let with_project ?(versions=1) f =
  let root = Filename.temp_file "tesl-migration-application-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    save (path "tesl.toml") "";
    save (path "schema/notes/v-current/notes.tesl") child;
    save (path "schema/notes/v-current.tesl") schema;
    save (path "app.tesl") app;
    for version=1 to versions do start root "NotesSchema" version done;
    accepts (path "app.tesl") app;
    f root path)
let migration path = path "migrations/notes/v2.tesl"
let hole source = replace "entities: {}" "entities: { Notes.Note: todo \"choose row adaptation\" }" source
let add_import import source = replace "import Tesl.Migration" ("import " ^ import ^ "\nimport Tesl.Migration") source
let current_hole () = with_project (fun _ path ->
  let file = migration path in save file (hole (read file));
  let ds = refuses "MIG003" (path "app.tesl") app in
  check (list string) "one focused error" ["MIG003"] (List.map (fun (d : Compile.diagnostic) -> d.code) ds);
  check string "diagnostic belongs to migration" file (List.hd ds).file;
  check bool "agent API refuses" false (Compile.agent_context_result_source (path "app.tesl") app).ok;
  match Compile.compile_go_source (path "app.tesl") app with
  | Compile.GoFailure ds -> check bool "emission refuses unresolved migration" true (List.exists (fun (d : Compile.diagnostic) -> d.code="MIG003") ds)
  | Compile.GoSuccess _ -> fail "unresolved migration emitted application")
let completed_hole () = with_project ~versions:2 (fun _ path ->
  save (migration path) (hole (read (migration path)));
  ignore (refuses "MIG013" (path "app.tesl") app))
let missing_current () = with_project (fun _ path ->
  Sys.remove (migration path); ignore (refuses "MIG001" (path "app.tesl") app))
let missing_completed () = with_project ~versions:2 (fun _ path ->
  Sys.remove (migration path); ignore (refuses "MIG020" (path "app.tesl") app))
let missing_schema () = with_project ~versions:2 (fun _ path ->
  Sys.remove (path "schema/notes/v1.tesl"); ignore (refuses "MIG020" (path "app.tesl") app))
let no_history_yet () = with_project ~versions:0 (fun _ path -> accepts (path "app.tesl") app)
let unsealed () = with_project (fun _ path ->
  let file = migration path in
  let source = read file in
  let offset = Str.search_forward (Str.regexp_string "module NotesSchema.Migrate.V2") source 0 in
  let bare = String.sub source offset (String.length source-offset) in
  save file bare; accepts file bare;
  ignore (refuses "MIG013" (path "app.tesl") app))
let explicit_import () = with_project (fun _ path ->
  save (migration path) (hole (read (migration path)));
  let source = replace "import NotesSchema.VCurrent" "import NotesSchema.Migrate.V2\nimport NotesSchema.VCurrent" app in
  let ds = refuses "MIG003" (path "app.tesl") source in
  check int "explicit edge is checked once" 1 (List.length ds))
let imported_owner () = with_project (fun _ path ->
  save (path "connection.tesl") (replace "module App" "module Connection" app);
  let source = "module App exposing []\nimport Connection\n" in save (path "app.tesl") source;
  save (migration path) (hole (read (migration path)));
  ignore (refuses "MIG003" (path "app.tesl") source))
let multiple_families () = with_project (fun root path ->
  save (path "schema/audit/v-current.tesl") (replace "NotesSchema" "AuditSchema" schema);
  save (path "schema/audit/v-current/notes.tesl") (replace "NotesSchema" "AuditSchema" child);
  start root "AuditSchema" 1;
  save (path "audit-connection.tesl") (app |> replace "NotesSchema" "AuditSchema" |> replace "module App" "module AuditConnection");
  let source = replace "import Tesl.Database" "import AuditConnection\nimport Tesl.Database" app in
  save (path "app.tesl") source;
  let audit = path "migrations/audit/v2.tesl" in
  save audit (hole (read audit)); save (migration path) (hole (read (migration path)));
  let ds = refuses "MIG003" (path "app.tesl") source in
  check (list string) "both families checked" [audit;migration path]
    (List.map (fun (d : Compile.diagnostic) -> d.file) ds |> List.sort String.compare))
let helper_type () = with_project (fun _ path ->
  let helper = path "migrations/notes/v2/helper.tesl" in
  save helper "module NotesSchema.Migrate.V2.Helper exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = \"broken\"\n";
  save (migration path) (add_import "NotesSchema.Migrate.V2.Helper" (read (migration path)));
  let ds = refuses "T001" (path "app.tesl") app in
  check bool "private helper body anchored" true (List.exists (fun (d : Compile.diagnostic) -> d.file=helper) ds))
let helper_proof () = with_project (fun _ path ->
  let source = {|module NotesSchema.Migrate.V2.Helper exposing [make]
import Tesl.Prelude exposing [String]
fact Good (s: String)
record Value { text: String ::: Good text }
fn make(raw: String) -> Value = Value { text: raw }
|} in
  save (path "migrations/notes/v2/helper.tesl") source;
  save (migration path) (add_import "NotesSchema.Migrate.V2.Helper" (read (migration path)));
  let ds = check_source (path "app.tesl") app in
  check bool ("proof checker runs: " ^ describe ds) true
    (List.exists (fun (d : Compile.diagnostic) -> contains d.message "proof") ds))
let helper_effect () = with_project (fun _ path ->
  let source = {|module NotesSchema.Migrate.V2.Helper exposing [readValue]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env]
import Tesl.Maybe exposing [Maybe(..)]
fn hidden(key: String) -> String requires [] =
  case env key of
    Something value -> value
    Nothing -> ""
fn readValue(key: String) -> String requires [] = hidden key
|} in
  save (path "migrations/notes/v2/helper.tesl") source;
  save (migration path) (add_import "NotesSchema.Migrate.V2.Helper" (read (migration path)));
  let ds = check_source (path "app.tesl") app in
  check bool ("capability checker runs: " ^ describe ds) true
    (List.exists (fun (d : Compile.diagnostic) -> d.code="MIG020" && contains d.message "effectful") ds))
let shared_helper () = with_project ~versions:2 (fun _ path ->
  save (path "migrations/notes/shared.tesl") "module NotesSchema.Migrate.Shared exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = \"broken\"\n";
  List.iter (fun file -> save file (add_import "NotesSchema.Migrate.Shared" (read file))) [migration path;path "migrations/notes/v3.tesl"];
  let ds = refuses "T001" (path "app.tesl") app in
  check int "shared invalid helper body checked once" 1 (List.length (List.filter (fun (d : Compile.diagnostic) -> d.file=path "migrations/notes/shared.tesl" && d.code="T001") ds)))
let malformed () = with_project (fun _ path ->
  save (migration path) (read (migration path) ^ "\nfn broken(\n");
  ignore (refuses "MIG020" (path "app.tesl") app))
let unsaved () = with_project (fun root path ->
  let file = migration path and entry = path "app.tesl" in let original = read (migration path) in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    Source_input.with_overlays ~project_root:root [file,hole original] (fun () ->
      ignore (refuses "MIG003" entry app);
      check string "does not save migration buffer" original (read file));
    accepts entry app;
    save file (hole original);
    Source_input.with_overlays ~project_root:root [file,original] (fun () -> accepts entry app);
    ignore (refuses "MIG003" entry app)))
let batch_skipping () = with_project (fun _ path ->
  let file = migration path in save file (hole (read file));
  let skip_dep_body path = path=file in
  check int "batch can check migration separately" 0 (List.length (check_source ~skip_dep_body (path "app.tesl") app));
  ignore (refuses "MIG003" file (read file)))
let no_runtime_names () = with_project (fun _ path ->
  let file = migration path in
  save file (read file |> add_import "Tesl.Prelude exposing [Int]" |> replace "exposing [migration]" "exposing [migration, answer]" |> fun source -> source ^ "\nfn answer() -> Int = 42\n");
  accepts (path "app.tesl") app;
  ignore (refuses "T001" (path "app.tesl") (replace "import Tesl.Database" "import Tesl.Prelude exposing [Int]\nimport Tesl.Database" app ^ "\nfn illegal() -> Int = answer()\n")))
let implicit_and_explicit_helper () = with_project (fun _ path ->
  let helper = path "migrations/notes/shared.tesl" in
  save helper "module NotesSchema.Migrate.Shared exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = \"broken\"\n";
  save (migration path) (add_import "NotesSchema.Migrate.Shared" (read (migration path)));
  let source = replace "import Tesl.Database" "import NotesSchema.Migrate.Shared\nimport Tesl.Database" app in
  let ds = refuses "T001" (path "app.tesl") source in
  check int "ordinary and implicit imports share body diagnostics" 1
    (List.length (List.filter (fun (d : Compile.diagnostic) -> d.file=helper && d.code="T001") ds)))
let unsaved_owner () = with_project (fun _ path ->
  save (path "app.tesl") "module App exposing []\n";
  save (migration path) (hole (read (migration path)));
  ignore (refuses "MIG003" (path "app.tesl") app);
  accepts (path "app.tesl") (read (path "app.tesl")))
let malformed_private () = with_project (fun _ path ->
  save (path "migrations/notes/v2/helper.tesl") "module broken = @@@";
  save (migration path) (add_import "NotesSchema.Migrate.V2.Helper" (read (migration path)));
  let ds = refuses "MIG020" (path "app.tesl") app in
  check bool "parse error retains private source" true
    (List.exists (fun (d : Compile.diagnostic) -> d.file=path "migrations/notes/v2/helper.tesl") ds))
let stale_seals () = with_project (fun _ path ->
  let file = path "schema/notes/v1/notes.tesl" in
  save file (read file ^ "# frozen source edited\n");
  ignore (refuses "MIG013" (path "app.tesl") app))
let persistent_session () = with_project (fun _ path ->
  (* The editor owner sends a fresh whole-project snapshot when implicit history
     changes, even though the entry bytes and its ordinary imports are identical. *)
  let request_read, request_write = Unix.pipe () in
  let response_read, response_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
    Unix.close request_write; Unix.close response_read;
    let input = Unix.in_channel_of_descr request_read and output = Unix.out_channel_of_descr response_write in
    (try Workspace_session.run input output; close_in input; close_out output; Unix._exit 0
     with _ -> Unix._exit 1)
  | pid ->
    Unix.close request_read; Unix.close response_write;
    let output = Unix.out_channel_of_descr request_write and input = Unix.in_channel_of_descr response_read in
    Fun.protect ~finally:(fun () ->
      close_out_noerr output; close_in_noerr input;
      match snd (Unix.waitpid [] pid) with Unix.WEXITED 0 -> () | _ -> fail "query session failed") (fun () ->
      ignore (Workspace_session.read_frame input Workspace_session.max_response);
      let query snapshot =
        List.iter (Workspace_session.write_frame output) [snapshot;"--agent-context-json";path "app.tesl";"";""];
        Workspace_session.read_frame input Workspace_session.max_response in
      let ok response = contains response "\"exit_code\":0" in
      let good = query "before" in check bool ("initial session: " ^ good) true (ok good);
      let file = migration path in let original = read file in
      save file (hole original);
      let bad = query "after" in check bool ("migration-only snapshot change: " ^ bad) true
        (not (ok bad) && contains bad "MIG003");
      let cached = query "after" in check bool "repeated query retains refusal" true (not (ok cached) && contains cached "MIG003");
      save file original;
      let restored = query "restored" in check bool ("restored snapshot: " ^ restored) true (ok restored)))
let ordinary_application_types () = with_project (fun _ path ->
  let source = replace "import Tesl.Database"
    "import Tesl.Units exposing [Length, Length.meters]\nimport Tesl.Money exposing [Money, Money.usd]\nimport Tesl.Database" app ^
    "\nfn distance() -> Length = Length.meters 2.0\nfn price() -> Money = Money.usd 1050\n" in
  accepts (path "app.tesl") source;
  (match Compile.compile_go_source (path "app.tesl") source with
   | Compile.GoFailure ds -> fail (describe ds)
   | Compile.GoSuccess _ -> ());
  let bad = replace "Length.meters 2.0" "\"bad\"" source in
  let ds = refuses "T001" (path "app.tesl") bad in
  check bool "unit type remains readable" true (List.exists (fun (d : Compile.diagnostic) -> contains d.message "Length") ds);
  check bool "internal unit names do not leak" false (List.exists (fun (d : Compile.diagnostic) -> contains d.message "§Q[") ds))
let () = run "Application migration dependencies" ["declared history", List.map (fun (name,f) -> test_case name `Quick f)
  ["current holes block every application build",current_hole;"completed holes block current application",completed_hole;
   "missing current migration",missing_current;"missing completed edge",missing_completed;"missing frozen schema",missing_schema;
   "initial schema needs no migration",no_history_yet;"applications require recorded schema seals",unsealed;
   "explicit imports do not duplicate errors",explicit_import;"imported connection owner",imported_owner;
   "independent database families",multiple_families;"private helper type errors",helper_type;"private helper proof errors",helper_proof;
   "transitive helper capability errors",helper_effect;"shared helper body checked once",shared_helper;
   "malformed history blocks",malformed;"unsaved migration and retained caches",unsaved;
   "batch dependency skipping",batch_skipping;"checking dependencies introduce no names",no_runtime_names;
   "shared explicit and implicit helper",implicit_and_explicit_helper;"unsaved connection declaration",unsaved_owner;
   "malformed private migration helper",malformed_private;"edited frozen schema seal",stale_seals;
   "editor session notices implicit history changes",persistent_session;
   "ordinary application unit and money semantics",ordinary_application_types]]
