open Alcotest
open Migration_history_sources

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-history-sources-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let module_path name = Option.get (Validation_common.schema_module_relative_path name)
let header name = "module " ^ name ^ " exposing []\n"
let import name = "import " ^ name ^ " exposing []\n"
let replace before after = Str.global_replace (Str.regexp_string before) after
let prelude = "import Tesl.Prelude exposing [Int, String]\n"
let child name = header name ^ prelude ^
  "entity Note table \"notes\" primaryKey id { id: String, value: Int }\n"
let schema ?(family="NotesSchema") write revision =
  let name = family ^ "." ^ revision in
  ignore (write (module_path (name ^ ".Notes")) (child (name ^ ".Notes")));
  write (module_path name) (header name ^ import (name ^ ".Notes"))
let migration ?(target="VCurrent") write version =
  let name = "NotesSchema.Migrate.V" ^ string_of_int version in
  write (module_path name) (header name ^
    import ("NotesSchema.V" ^ string_of_int (version - 1)) ^
    import ("NotesSchema." ^ target))
let initial write = ignore (schema write "VCurrent")
let chain write =
  List.iter (fun revision -> ignore (schema write revision)) ["V1"; "V2"; "VCurrent"];
  ignore (migration ~target:"V2" write 2); ignore (migration write 3)
let discover ?(family="NotesSchema") root =
  discover ~compiler_abi:"test-compiler-1" ~project_root:root ~family
let get = function Ok value -> value | Error error -> fail error.message
let expect_error kind message result = match result with
  | Ok _ -> fail ("unexpected successful discovery: " ^ message)
  | Error error ->
    check bool ("error kind: " ^ error.message) true (kind = error.kind);
    check bool ("message: " ^ error.message) true
      (try ignore (Str.search_forward (Str.regexp_string message) error.message 0); true with Not_found -> false)
let rec files root =
  Sys.readdir root |> Array.to_list |> List.concat_map (fun name ->
    let path = Filename.concat root name in
    if Sys.is_directory path then files path
    else [path, In_channel.with_open_bin path In_channel.input_all]) |> List.sort compare

let first_revision () = with_project (fun root write ->
  initial write;
  let before = files root in let history = get (discover root) in
  check int "new family starts at one" 1 (current history).version;
  check int "no frozen roots" 0 (List.length (frozen history));
  check int "no completed migrations" 0 (List.length (completed_migrations history));
  check bool "no migration needed for adoption" true (current_migration history = None);
  check int "root and private child are guarded" 2 (List.length (source_inputs history));
  check (list (pair string string)) "discovery never writes" before (files root))

let consecutive_history () = with_project (fun root write ->
  chain write;
  let before = files root in let history = get (discover root) in
  check int "current follows frozen history" 3 (current history).version;
  check (list int) "ordered frozen schemas" [1; 2]
    (List.map (fun (schema : schema) -> schema.version) (frozen history));
  check (list int) "ordered completed migrations" [2]
    (List.map (fun (source : migration_source) -> source.version) (completed_migrations history));
  check int "current migration" 3 (Option.get (current_migration history)).version;
  check int "complete inputs" 8 (List.length (source_inputs history));
  List.iter (fun (path, digest) -> check string path
    (Migration_hash.digest (List.assoc path before)) digest) (source_inputs history);
  check (list (pair string string)) "successful history is read only" before (files root);
  Sys.remove (Filename.concat root "migrations/notes/v3.tesl");
  check bool "generator may create missing current migration" true
    (current_migration (get (discover root)) = None))

let numbering () =
  List.iter (fun name -> with_project (fun root write ->
    initial write;
    ignore (write ("schema/notes/" ^ name ^ ".tesl") "");
    expect_error Invalid_layout "versions must" (discover root)))
    ["v0"; "v01"; "v2147483647"; "v999999999999999999999999999999"; "V1"];
  with_project (fun root write ->
    initial write; ignore (write "schema/notes/v1.TESL" "");
    expect_error Invalid_layout "versions must" (discover root));
  with_project (fun root write ->
    initial write; ignore (schema write "V2147483646");
    expect_error Invalid_layout "reserved boot-fence" (discover root));
  List.iter (fun version -> with_project (fun root write ->
    initial write; ignore (migration write version);
    expect_error Invalid_layout "no consecutive" (discover root))) [1; 2; 99]

let missing_history () =
  List.iter (fun (relative, message) -> with_project (fun root write ->
    chain write; Sys.remove (Filename.concat root relative);
    expect_error Missing_source message (discover root)))
    ["schema/notes/v1.tesl", "missing frozen schema V1";
     "migrations/notes/v2.tesl", "missing completed migration V2";
     "schema/notes/v-current.tesl", "v-current.tesl";
     "schema/notes/v2/notes.tesl", "v2/notes.tesl"];
  with_project (fun root write ->
    chain write; ignore (schema write "V4");
    expect_error Missing_source "missing frozen schema V3" (discover root))

let wrong_headers () =
  List.iter (fun (relative, name) -> with_project (fun root write ->
    chain write; ignore (write relative (header name));
    expect_error Invalid_layout "must declare" (discover root)))
    ["schema/notes/v-current.tesl", "OtherSchema.VCurrent";
     "schema/notes/v1.tesl", "NotesSchema.VCurrent";
     "schema/notes/v2/notes.tesl", "NotesSchema.V2.Other";
     "migrations/notes/v2.tesl", "NotesSchema.Migrate.V3"]

let schema_errors () =
  List.iter (fun source -> with_project (fun root write ->
    initial write;
    ignore (write "schema/notes/v-current/notes.tesl" source);
    match discover root with
    | Error {kind=Invalid_source; _} -> ()
    | Error error -> fail ("wrong error classification: " ^ error.message)
    | Ok _ -> fail "invalid private schema accepted"))
    [child "NotesSchema.VCurrent.Notes" ^ "fn bad() -> Int = \"no\"\n";
     child "NotesSchema.VCurrent.Notes" ^ "handler get bad() -> Int = 1\n";
     header "NotesSchema.VCurrent.Notes" ^ "record Broken {\n";
     header "NotesSchema.VCurrent.Notes" ^ import "NotesSchema.V1"]

let migration_helpers () = with_project (fun root write ->
  chain write;
  let root_name = "NotesSchema.Migrate.V3" in
  let helper = "NotesSchema.Migrate.V3.Helper" and shared = "NotesSchema.Migrate.Shared" in
  let source = header root_name ^ import helper ^ import shared in
  ignore (write (module_path root_name) source);
  ignore (write (module_path helper) (header helper ^ import shared));
  let shared_path = write (module_path shared) (header shared ^ import helper ^ prelude ^ "fn value() -> Int = 1\n") in
  let before = get (discover root) in
  check int "diamond and cycle guard each helper once" 10 (List.length (source_inputs before));
  let old_digest = List.assoc shared_path (source_inputs before) in
  ignore (write (module_path shared) (header shared ^ import helper ^ prelude ^ "fn value() -> Int = 2\n"));
  let after = get (discover root) in
  check bool "private helper edit changes source guard" true (old_digest <> List.assoc shared_path (source_inputs after));
  check string "root itself unchanged" source (Option.get (current_migration after)).contents)

let migration_boundaries () =
  List.iter (fun (source, message) -> with_project (fun root write ->
    chain write;
    let name = "NotesSchema.Migrate.V3.Helper" in
    ignore (write "migrations/notes/v3.tesl" (header "NotesSchema.Migrate.V3" ^ import name));
    ignore (write (module_path name) (header name ^ source));
    expect_error Invalid_source message (discover root)))
    [prelude ^ "handler get bad() -> Int = 1\n", "cannot contain";
     "database D = Database { entities: [], backend: Memory }\n", "cannot contain";
     import "Application", "outside frozen ownership";
     import "OtherSchema.VCurrent", "outside frozen ownership";
     import "NotesSchema.V1.Unowned", "outside the discovered ownership"];
  with_project (fun root write ->
    chain write;
    ignore (write "migrations/notes/v3.tesl" (header "NotesSchema.Migrate.V3" ^ import "NotesSchema.Migrate.Missing"));
    expect_error Missing_source "missing.tesl" (discover root))

let canonical_files () =
  List.iter (fun relative -> with_project (fun root write ->
    chain write;
    let path = Filename.concat root relative in
    let saved = path ^ ".original" in
    Unix.rename path saved; Unix.symlink saved path;
    expect_error Invalid_layout "canonical regular" (discover root)))
    ["schema/notes/v-current.tesl"; "schema/notes/v1.tesl";
     "schema/notes/v-current/notes.tesl"; "migrations/notes/v2.tesl"];
  List.iter (fun relative -> with_project (fun root write ->
    chain write;
    let path = Filename.concat root relative in
    Sys.remove path; Unix.mkfifo path 0o600;
    expect_error Invalid_layout "canonical regular" (discover root)))
    ["schema/notes/v-current.tesl"; "schema/notes/v-current/notes.tesl";
     "migrations/notes/v2.tesl"]

let canonical_directories () =
  List.iter (fun relative -> with_project (fun root write ->
    chain write;
    let path = Filename.concat root relative in
    let saved = path ^ ".original" in
    Unix.rename path saved; Unix.symlink saved path;
    expect_error Invalid_layout "canonical" (discover root)))
    ["schema"; "schema/notes"; "schema/notes/v-current"; "migrations"; "migrations/notes"];
  with_project (fun root write ->
    initial write; mkdir (Filename.concat root "elsewhere");
    Unix.symlink (Filename.concat root "elsewhere") (Filename.concat root "migrations");
    expect_error Invalid_layout "canonical" (discover root))

let import_shadowing () =
  List.iter (fun filename -> with_project (fun root write ->
    initial write;
    ignore (write ("schema/notes/" ^ filename) (child "NotesSchema.VCurrent.Notes"));
    expect_error Invalid_layout "canonical module path" (discover root)))
    ["notes-schema.-v-current.-notes.tesl"; "NotesSchema.VCurrent.Notes.tesl"]

let isolated_families () = with_project (fun root write ->
  chain write; ignore (schema ~family:"BillingSchema" write "VCurrent");
  let notes = get (discover root) and billing = get (discover ~family:"BillingSchema" root) in
  check int "notes current" 3 (current notes).version;
  check int "billing independent" 1 (current billing).version;
  check bool "read sets are disjoint" true
    (List.for_all (fun (path, _) -> not (List.mem_assoc path (source_inputs notes))) (source_inputs billing));
  List.iter (fun family -> expect_error Invalid_layout "invalid schema family" (discover ~family root))
    ["Notes"; "NotesSchema.V1"; "../NotesSchema"; "/NotesSchema"])

let byte_guards () = with_project (fun root write ->
  initial write;
  let before = get (discover root) in
  let path = Filename.concat root "schema/notes/v-current/notes.tesl" in
  let source = In_channel.with_open_bin path In_channel.input_all in
  ignore (write "schema/notes/v-current/notes.tesl" ("# unchanged meaning å 🌱\r\n" ^ replace "\n" "\r\n" source));
  let after = get (discover root) in
  check bool "raw source precondition detects comments and CRLF" true
    (List.assoc path (source_inputs before) <> List.assoc path (source_inputs after));
  check bool "semantic snapshot stays equal" true
    (Migration_inventory.snapshot (current before).inventory = Migration_inventory.snapshot (current after).inventory))

let discovery_scope () = with_project (fun root write ->
  chain write;
  (* Amendments need their own elaboration; unrelated files are not revisions. *)
  List.iter (fun name -> ignore (write ("migrations/notes/" ^ name) "not a revision root"))
    ["v3-contract.tesl"; "v3-repair-1.tesl"; "tests.tesl"; "v3.tesl.bak"];
  ignore (write "schema/notes/notes.txt" "unrelated");
  check int "non-revision files do not allocate versions" 3 (current (get (discover root))).version;
  (* Discovery does not misrepresent parsed migration code as type-checked code. *)
  ignore (write "migrations/notes/v3.tesl" (header "NotesSchema.Migrate.V3" ^ prelude ^ "fn bad() -> Int = \"no\"\n"));
  ignore (get (discover root)))

let stale_inputs () =
  List.iter (fun relative -> with_project (fun root write ->
    chain write;
    let history = get (discover root) in
    ignore (write relative "# changed\n");
    expect_error Changed_source "source changed" (verify_unchanged history)))
    ["schema/notes/v-current.tesl"; "schema/notes/v2.tesl";
     "schema/notes/v1/notes.tesl"; "migrations/notes/v3.tesl"];
  List.iter (fun relative -> with_project (fun root write ->
    chain write;
    let history = get (discover root) in
    ignore (write relative "");
    expect_error Changed_source "directory changed" (verify_unchanged history)))
    ["schema/notes/v3.tesl"; "migrations/notes/v4.tesl"];
  with_project (fun root write ->
    initial write; ignore (schema write "V1");
    let history = get (discover root) in
    ignore (migration write 2);
    expect_error Changed_source "directory changed" (verify_unchanged history));
  with_project (fun root write ->
    initial write;
    let history = get (discover root) in
    ignore (write "schema/notes/NotesSchema.VCurrent.Notes.tesl" (child "NotesSchema.VCurrent.Notes"));
    expect_error Changed_source "import resolution changed" (verify_unchanged history));
  with_project (fun root write ->
    chain write;
    let history = get (discover root) in
    Sys.remove (Filename.concat root "schema/notes/v1/notes.tesl");
    expect_error Missing_source "notes.tesl" (verify_unchanged history));
  with_project (fun root write ->
    initial write;
    let history = get (discover root) in
    ignore (get (verify_unchanged history));
    ignore (write "README.md" "unrelated source does not stale a preview");
    ignore (get (verify_unchanged history)))

let () = run "migration history source discovery" ["history", List.map (fun (name, test) ->
  test_case name `Quick test) [
    "first revision", first_revision;
    "consecutive source chain", consecutive_history;
    "numbering and overflow", numbering;
    "missing source history", missing_history;
    "exact module headers", wrong_headers;
    "checked private schema", schema_errors;
    "transitive migration helpers", migration_helpers;
    "migration ownership", migration_boundaries;
    "canonical regular inputs", canonical_files;
    "canonical directories", canonical_directories;
    "import shadowing", import_shadowing;
    "family isolation", isolated_families;
    "raw bytes versus meaning", byte_guards;
    "discovery boundary", discovery_scope;
    "stale source and directory guards", stale_inputs;
  ]]
