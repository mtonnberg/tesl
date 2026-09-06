open Alcotest
module C = Migration_closure
module G = Migration_generate
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let replace a b = Str.global_replace (Str.regexp_string a) b
let inspect file source = ignore (Compile.agent_context_result_source file source)
let save file source = write file source; inspect file source
let get = function Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e : Migration_sparse.error) -> e.message) es))
let refused = function Error (_::_ as es) -> es | _ -> fail "changed or invalid closure accepted"
let refuse value = ignore (refused value)
let root_name = "NotesSchema.Migrate.V2"
let helper_name = "NotesSchema.Migrate.Shared"
let schema = "module NotesSchema.VCurrent exposing []\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
let start root version =
  let p = match G.start ~compiler_abi:"fixture-ABI" ~project_root:root ~family:"NotesSchema" ~version ~documents:[] with
    | Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e : G.error) -> e.message) es)) in
  List.iter (fun (e : M.edit) -> write e.path e.after) (M.edits p.manifest);
  List.iter (fun (e : M.edit) -> inspect e.path e.after) (M.edits p.manifest)
let with_project ?(prepare=fun _ _ _ _ -> ()) f =
  let root = Filename.temp_file "tesl-migration-closure-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") ""; save (path "schema/notes/v-current.tesl") schema;
    start root 1;
    let file = path "migrations/notes/v2.tesl" and helper = path "migrations/notes/shared.tesl" in
    save helper "module NotesSchema.Migrate.Shared exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n";
    save file (replace "import Tesl.Migration" "import NotesSchema.Migrate.Shared\nimport Tesl.Migration" (read file));
    prepare root path file helper;
    start root 2;
    let seal = get (C.capture ~project_root:root ~root_file:file ~source:(read file)) in
    let source = get (C.attach ~file ~source:(read file) seal) in save file source;
    let located = get (C.read ~file source) |> Option.get in
    get (C.verify ~project_root:root ~root_file:file ~source located);
    f root path file helper located)
let verify root file located = C.verify ~project_root:root ~root_file:file ~source:(read file) located
let exact () = with_project (fun root path file helper located ->
  check string "root identity" root_name (C.root located);
  check (list string) "private closure excludes separate schemas" [helper_name;root_name] (List.map fst (C.sources located));
  check string "helper raw bytes" (Migration_hash.digest (read helper)) (List.assoc helper_name (C.sources located));
  let seal = get (C.capture ~project_root:root ~root_file:file ~source:(read file)) in
  check string "capture/attach is stable" (read file) (get (C.attach ~file ~source:(read file) seal));
  check bool "helper path included" true (C.mentions_file ~project_root:root ~file:helper located);
  check bool "schema is independently sealed" false (C.mentions_file ~project_root:root ~file:(path "schema/notes/v1.tesl") located))
let changed_helper () = with_project (fun root _ file helper located ->
  let original = read helper in
  List.iter (fun source -> save helper source;
    let es = refused (verify root file located) in
    check string "actual changed input" helper (List.hd es).loc.file)
    [replace "42" "43" original; original ^ "# comment only\n"; "module broken = @@@";
     replace "module NotesSchema.Migrate.Shared" "module Different" original])
let changed_root () = with_project (fun root _ file _ located ->
  save file (read file ^ "# root comment edited\n"); refuse (verify root file located))
let changed_schema_metadata () = with_project (fun root _ file _ located ->
  let source = read file in
  let from = "# tesl:snapshot-source NotesSchema.V1 " in
  let at = Str.search_forward (Str.regexp_string from) source 0 + String.length from in
  let source = String.sub source 0 at ^ (if source.[at]='0' then "1" else "0") ^ String.sub source (at+1) (String.length source-at-1) in
  save file source; refuse (verify root file located))
let removed_helper () = with_project (fun root _ file helper located ->
  Sys.remove helper; refuse (verify root file located))
let special_helper () = with_project (fun root path file helper located ->
  let saved = read helper in Sys.remove helper;
  let target = path "other.tesl" in write target saved; Unix.symlink target helper;
  refuse (verify root file located);
  Sys.remove helper; Unix.mkfifo helper 0o600;
  refuse (verify root file located);
  (* Capture must check kind before trying to read a newly imported FIFO. *)
  refuse (C.capture ~project_root:root ~root_file:file ~source:(read file)))
let stale_attach () = with_project (fun root _ file _ _ ->
  let seal = get (C.capture ~project_root:root ~root_file:file ~source:(read file)) in
  refuse (C.attach ~file ~source:(read file ^ "# newer edit\n") seal))
let unsaved_helper () = with_project (fun root _ file helper located ->
  let original = read helper in
  Source_input.with_overlays ~project_root:root [helper,replace "42" "43" original] (fun () ->
    inspect helper (Source_input.read helper); refuse (verify root file located));
  get (verify root file located); check string "buffer never saved" original (read helper))
let unsaved_root () = with_project (fun root _ file _ located ->
  let original = read file in let changed = original ^ "# unsaved root\n" in
  Source_input.with_overlays ~project_root:root [file,changed] (fun () ->
    inspect file changed; refuse (C.verify ~project_root:root ~root_file:file ~source:changed located));
  get (verify root file located))
let incomplete_metadata () = with_project (fun _ _ file _ _ ->
  let original = read file in
  List.iter (fun source -> refuse (C.read ~file source))
    [replace "# tesl:frozen-migration:v1" "# tesl:frozen-migration:v2" original;
     replace "# tesl:frozen-migration:end\n" "" original;
     "# tesl:frozen-source incomplete\n" ^ original;
     original |> replace "# tesl:frozen-migration:end" ("# tesl:frozen-source " ^ helper_name ^ " " ^ String.make 64 '0' ^ "\n# tesl:frozen-migration:end");
     replace "# tesl:frozen-migration:end" " # tesl:frozen-migration:end" original])
let header_spelling () = with_project (fun root _ file _ located ->
  (* Line endings in metadata are transport spelling; body bytes remain exact. *)
  let original = read file in
  let stop = Str.search_forward (Str.regexp_string "# tesl:frozen-migration:end\n") original 0 + String.length "# tesl:frozen-migration:end\n" in
  let header = String.sub original 0 stop |> replace "\n" "\r\n" in
  let source = header ^ String.sub original stop (String.length original-stop) in
  let parsed = get (C.read ~file source) |> Option.get in
  check (list (pair string string)) "CRLF metadata decodes identically" (C.sources located) (C.sources parsed);
  get (C.verify ~project_root:root ~root_file:file ~source parsed);
  check bool "CRLF metadata passes the actual compiler" true (Compile.agent_context_result_source file source).ok)
let wrong_root () = with_project (fun root path file _ located ->
  let alias = path "migrations/notes/v3.tesl" in
  refuse (C.verify ~project_root:root ~root_file:alias ~source:(read file) located))
let capture_current () = with_project (fun root path _ _ _ ->
  let file = path "migrations/notes/v3.tesl" in
  refuse (C.capture ~project_root:root ~root_file:file ~source:(read file)))
let cyclic_private () = with_project (fun root path file helper _ ->
  let other = path "migrations/notes/other.tesl" in
  save other "module NotesSchema.Migrate.Other exposing []\nimport NotesSchema.Migrate.Shared\n";
  save helper (replace "import Tesl.Prelude" "import NotesSchema.Migrate.Other\nimport Tesl.Prelude" (read helper));
  let seal = get (C.capture ~project_root:root ~root_file:file ~source:(read file)) in
  let source = get (C.attach ~file ~source:(read file) seal) in save file source;
  let located = get (C.read ~file source) |> Option.get in
  check int "cycle reaches each helper once" 3 (List.length (C.sources located));
  get (verify root file located))
let import_resolution () = with_project (fun root path file _ located ->
  let alternate = path "migrations/notes/NotesSchema.Migrate.Shared.tesl" in
  save alternate (read (path "migrations/notes/shared.tesl"));
  refuse (verify root file located))
let errors file source = Compile.check_source file source |> List.filter (fun (d : Compile.diagnostic) -> d.severity="error")
let code code file source =
  let ds = errors file source in
  if not (List.exists (fun (d : Compile.diagnostic) -> d.code=code) ds) then
    fail ("missing " ^ code ^ " in " ^ String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) ds)); ds
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
|}
let queries_and_app () = with_project (fun _ path file helper _ ->
  save (path "app.tesl") app;
  save helper (replace "42" "43" (read helper));
  List.iter (fun queried -> ignore (code "MIG013" queried (read queried))) [file;helper;path "app.tesl"];
  match Compile.compile_go_source (path "app.tesl") app with
  | Compile.GoFailure ds -> check bool "application emission refuses changed helper" true
      (List.exists (fun (d : Compile.diagnostic) -> d.code="MIG013") ds)
  | Compile.GoSuccess _ -> fail "edited completed migration emitted an application")
let helper_importer () = with_project (fun _ path _ helper _ ->
  let source = "module App exposing []\nimport NotesSchema.Migrate.Shared\n" in
  save (path "app.tesl") source;
  save helper (replace "42" "43" (read helper));
  ignore (code "MIG013" (path "app.tesl") source))
let unsaved_direct_query () = with_project (fun _ _ _ helper _ ->
  let original = read helper in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    ignore (code "MIG013" helper (replace "42" "43" original));
    check string "no save while checking helper buffer" original (read helper);
    check int "saved original still valid" 0 (List.length (errors helper original))))
let broken_queries () = with_project (fun _ _ file helper _ ->
  List.iter (fun (queried,source) ->
    let context = Compile.agent_context_result_source queried source in
    check bool "agent query fails" false context.ok;
    check bool "parse path retains frozen source failure" true (Compile.string_contains context.json "MIG013");
    ignore (code "E000" queried source))
    [file,read file ^ "\nfn broken(\n";helper,"module broken = @@@"])
let removed_metadata () = with_project (fun _ _ file _ _ ->
  let original = read file in
  let body_at = Str.search_forward (Str.regexp_string "module NotesSchema.Migrate.V2") original 0 in
  ignore (code "MIG013" file (String.sub original body_at (String.length original-body_at)));
  let header_at = Str.search_forward (Str.regexp_string "# tesl:migration-history:v1") original 0 in
  ignore (code "MIG013" file (String.sub original header_at (String.length original-header_at))))
let generation_refuses () = with_project (fun root _ _ helper _ ->
  save helper (replace "42" "43" (read helper));
  let failed = function Error (_::_) -> () | _ -> fail "edited completed helper allowed generation" in
  failed (G.start ~compiler_abi:"fixture-ABI" ~project_root:root ~family:"NotesSchema" ~version:3 ~documents:[]);
  failed (G.refresh ~compiler_abi:"fixture-ABI" ~project_root:root ~family:"NotesSchema" ~version:3 ~documents:[]))
let wrong_metadata_query () = with_project (fun _ _ file helper _ ->
  save file (replace "# tesl:frozen-migration:v1 NotesSchema.Migrate.V2" "# tesl:frozen-migration:v1 NotesSchema.Migrate.V3" (read file));
  ignore (code "MIG013" helper (read helper)))
let relative_query () = with_project (fun root _ file helper _ ->
  let cwd = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Unix.chdir cwd) (fun () ->
    Unix.chdir root;
    check int "relative completed root" 0 (List.length (errors "migrations/notes/v2.tesl" (read file)));
    check int "relative private helper" 0 (List.length (errors "migrations/notes/shared.tesl" (read helper)))))
let unsaved_restored_root () = with_project (fun _ _ file _ _ ->
  let original = read file in
  save file (original ^ "\nfn broken(\n");
  check int "valid unsaved root wins over malformed saved bytes" 0 (List.length (errors file original)))
let deep_private () =
  let prepare _ path _ helper =
    save (path "migrations/notes/shared/inner.tesl")
      "module NotesSchema.Migrate.Shared.Inner exposing []\nimport Tesl.Prelude exposing [Int]\nfn hidden() -> Int = 7\n";
    save helper (replace "import Tesl.Prelude" "import NotesSchema.Migrate.Shared.Inner\nimport Tesl.Prelude" (read helper)) in
  with_project ~prepare (fun _ path file _ located ->
    check int "deep unexported source is sealed" 3 (List.length (C.sources located));
    let deep = path "migrations/notes/shared/inner.tesl" in
    save deep (replace "= 7" "= 8" (read deep));
    ignore (code "MIG013" deep (read deep));
    ignore (code "MIG013" file (read file)))
let omitted_member () = with_project (fun root _ file helper located ->
  let line = "# tesl:frozen-source " ^ helper_name ^ " " ^ List.assoc helper_name (C.sources located) ^ "\n" in
  let source = replace line "" (read file) in
  save file source;
  let changed = get (C.read ~file source) |> Option.get in
  refuse (verify root file changed);
  ignore (code "MIG013" helper (read helper));
  save helper (replace "42" "43" (read helper));
  ignore (code "MIG013" helper (read helper)))
let missing_seal_private_query () = with_project (fun _ _ file helper _ ->
  let source = read file in
  let start = Str.search_forward (Str.regexp_string "module NotesSchema.Migrate.V2") source 0 in
  save file (String.sub source start (String.length source-start));
  ignore (code "MIG013" helper (read helper)))
let () = run "Frozen migration closure" ["raw source integrity",List.map (fun (name,f) -> test_case name `Quick f)
  ["complete private closure and stable self-exclusion",exact;"valid and invalid helper edits",changed_helper;
   "root comments remain source",changed_root;"schema metadata is included in root digest",changed_schema_metadata;
   "missing helper",removed_helper;"symlink and FIFO helper refusal",special_helper;"stale root cannot be sealed",stale_attach;
   "unsaved helper bytes",unsaved_helper;"unsaved root bytes",unsaved_root;"malformed and duplicate metadata",incomplete_metadata;
   "metadata CRLF transport",header_spelling;"metadata cannot name another root",wrong_root;"current references cannot be frozen",capture_current;
   "cyclic helper closure",cyclic_private;"import shadowing changes resolution",import_resolution;
   "direct queries and application emission",queries_and_app;"importing only the private helper",helper_importer;
   "unsaved direct helper query",unsaved_direct_query;"parse failures keep integrity diagnostics",broken_queries;
   "deleting recorded metadata still refuses",removed_metadata;"start and refresh refuse changed helpers",generation_refuses;
   "metadata path mismatch in direct queries",wrong_metadata_query;"relative root and helper queries",relative_query;
   "restored unsaved root overrides malformed disk",unsaved_restored_root;"nested unexported helpers stay sealed",deep_private;
   "removing a metadata member cannot hide a helper",omitted_member;"missing metadata blocks private queries",missing_seal_private_query]]
