open Alcotest
module M = Migration_manifest
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let read path = In_channel.with_open_bin path In_channel.input_all
let with_project f =
  let root = Filename.temp_file "tesl-migration-manifest-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    write (path "schema/notes/v-current.tesl") "module NotesSchema.VCurrent exposing []\n";
    f root path)
let get = function Ok value -> value | Error errors ->
  fail (String.concat "\n" (List.map (fun (e : M.error) -> e.path ^ ": " ^ e.message) errors))
let refuse f = match f () with Error (_::_) -> () | Error [] -> fail "empty error" | Ok _ -> fail "stale or invalid proposal accepted"
let proposal ?(reads=[]) ?(directories=[]) ?(documents=[]) ?(imports=[]) root writes =
  get (M.create ~project_root:root ~reads ~directories ~imports ~documents ~writes)
let contains source needle = try ignore (Str.search_forward (Str.regexp_string needle) source 0); true with Not_found -> false
let unchanged t = get (M.verify_source t ~documents:[]); get (M.verify_disk t)

let no_writes () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let original = read file in
  let created = path "migrations/notes/v2.tesl" in
  let t = proposal root [file,original ^ "# preview\n";created,"module NotesSchema.Migrate.V2 exposing []\n"] in
  check int "replacement and creation" 2 (List.length (M.edits t));
  check string "source bytes not changed" original (read file);
  check bool "no proposed output directory created" false (Sys.file_exists (path "migrations"));
  unchanged t;
  check bool "new source has no predecessor" true ((List.find (fun (e : M.edit) -> e.path = created) (M.edits t)).before = None))
let byte_edits () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let before = "a\000\255\r\n" in write file before;
  let t = proposal root [file,"å\r\n\000\254"] in
  let edit = List.hd (M.edits t) in
  check (option string) "exact old bytes" (Some before) edit.before;
  let json = M.to_json t in
  check bool "wire JSON is UTF-8 even for arbitrary source bytes" true (String.is_valid_utf_8 json);
  check bool "raw source encoding is explicit" true (contains json "\"beforeHex\":\"6100ff0d0a\"");
  check bool "replacement hex" true (contains json "\"afterHex\":\"c3a50d0a00fe\"");
  unchanged t)
let noops () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let t = proposal root [file,read file] in
  check int "equal bytes produce no edit" 0 (List.length (M.edits t));
  write file (read file ^ "# later\n"); refuse (fun () -> M.verify_disk t))
let dependency_bytes () = with_project (fun root path ->
  let dependency = path "schema/notes/v-current/private.tesl" in
  let output = path "migrations/notes/v2.tesl" in
  write dependency "private bytes\r\n";
  let t = proposal ~reads:[dependency] root [output,"proposal"] in
  write dependency "private bytes\n";
  refuse (fun () -> M.verify_source t ~documents:[]); refuse (fun () -> M.verify_disk t);
  write dependency "private bytes\r\n"; unchanged t)
let saved_vs_buffer () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let saved = read file in
  let document = {M.path=file;version=7} in
  let buffer = saved ^ "# unsaved\n" in
  let t = Source_input.with_overlays ~project_root:root [file,buffer] (fun () ->
    let t = proposal ~documents:[document] root [file,buffer ^ "# generated\n"] in
    get (M.verify_source t ~documents:[document]); get (M.verify_disk t);
    check (option string) "inverse edit uses buffer bytes" (Some buffer) (List.hd (M.edits t)).before;
    check bool "disk and source hashes are distinct" true
      (contains (M.to_json t) ("\"sourceHash\":\"" ^ Migration_hash.digest buffer ^ "\",\"diskHash\":\"" ^ Migration_hash.digest saved ^ "\""));
    t) in
  get (M.verify_disk t);
  refuse (fun () -> M.verify_source t ~documents:[document]);
  Source_input.with_overlays ~project_root:root [file,buffer] (fun () -> get (M.verify_source t ~documents:[document]));
  check string "buffer never saved" saved (read file))
let disk_change_under_buffer () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  Source_input.with_overlays ~project_root:root [file,"buffer"] (fun () ->
    let t = proposal ~reads:[file] root [] in
    write file "external edit";
    get (M.verify_source t ~documents:[]);
    refuse (fun () -> M.verify_disk t)))
let virtual_creation () = with_project (fun root path ->
  let file = path "schema/notes/v-current/private.tesl" in
  let document = {M.path=file;version=0} in
  Source_input.with_overlays ~project_root:root [file,"unsaved new source"] (fun () ->
    let t = proposal ~documents:[document] root [file,"generated new source"] in
    get (M.verify_source t ~documents:[document]); get (M.verify_disk t);
    check (option string) "virtual creation still replaces editor bytes" (Some "unsaved new source") (List.hd (M.edits t)).before;
    check bool "parent directory not created" false (Sys.file_exists (Filename.dirname file));
    write file "created concurrently";
    refuse (fun () -> M.verify_disk t)))
let editor_versions () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let doc version = {M.path=file;version} in
  let t = proposal ~documents:[doc 7] root [] in
  get (M.verify_source t ~documents:[doc 7]);
  refuse (fun () -> M.verify_source t ~documents:[doc 8]);
  refuse (fun () -> M.verify_source t ~documents:[]);
  refuse (fun () -> M.verify_source t ~documents:[doc 7;{M.path=path "other.tesl";version=1}]);
  refuse (fun () -> M.verify_source t ~documents:[doc 7;doc 7]);
  let negative = proposal ~documents:[doc (-1)] root [] in
  get (M.verify_source negative ~documents:[doc (-1)]);
  refuse (fun () -> M.create ~project_root:root ~reads:[] ~directories:[] ~imports:[] ~documents:[doc 2147483648] ~writes:[]))
let directory_membership () = with_project (fun root path ->
  let directory = path "migrations/notes" in mkdir directory;
  let t = proposal ~directories:[directory] root [] in
  let new_root = Filename.concat directory "v4.tesl" in
  write new_root "new revision";
  refuse (fun () -> M.verify_source t ~documents:[]); refuse (fun () -> M.verify_disk t);
  Sys.remove new_root; unchanged t;
  let names = path "schema/notes" in
  let t = proposal ~reads:[path "schema/notes/v-current.tesl"] root [] in
  write (Filename.concat names "NotesSchema.VCurrent.tesl") "shadow";
  refuse (fun () -> M.verify_disk t))
let missing_directory () = with_project (fun root path ->
  let directory = path "migrations/notes" in
  let t = proposal ~directories:[directory] root [] in
  mkdir directory;
  refuse (fun () -> M.verify_disk t))
let create_conflict () = with_project (fun root path ->
  let file = path "migrations/notes/v2.tesl" in
  let t = proposal root [file,"proposed"] in
  write file "concurrent";
  refuse (fun () -> M.verify_source t ~documents:[]); refuse (fun () -> M.verify_disk t);
  check string "conflict leaves concurrent bytes" "concurrent" (read file))
let invalid_paths () = with_project (fun root path ->
  let create file = M.create ~project_root:root ~reads:[] ~directories:[] ~imports:[] ~documents:[] ~writes:[file,"x"] in
  List.iter (fun file -> refuse (fun () -> create file))
    ["relative.tesl";path "../escape.tesl";root ^ "-sibling/test.tesl";path "schema/./notes/new.tesl";
     path "schema/notes/new.txt";path "bad-\255.tesl"];
  let file = path "same.tesl" in
  refuse (fun () -> M.create ~project_root:root ~reads:[] ~directories:[] ~imports:[] ~documents:[] ~writes:[file,"a";file,"b"]);
  refuse (fun () -> M.create ~project_root:root ~reads:[] ~directories:[] ~imports:[] ~documents:[]
    ~writes:[file,"a";Filename.concat file "child.tesl","b"]))
let symlinks_and_specials () = with_project (fun root path ->
  let source = path "schema/notes/v-current.tesl" in
  let alias = path "alias.tesl" in Unix.symlink source alias;
  let create reads writes = M.create ~project_root:root ~reads ~directories:[] ~imports:[] ~documents:[] ~writes in
  refuse (fun () -> create [alias] []);
  refuse (fun () -> create [] [alias,"x"]);
  let fifo = path "pipe.tesl" in Unix.mkfifo fifo 0o600;
  refuse (fun () -> create [fifo] []);
  refuse (fun () -> create [] [fifo,"x"]);
  Unix.symlink (path "schema/notes") (path "alias-dir");
  refuse (fun () -> create [] [path "alias-dir/new.tesl","x"]))
let replaced_parent () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let t = proposal root [file,"new"] in
  Unix.rename (path "schema/notes") (path "moved");
  Unix.symlink (path "moved") (path "schema/notes");
  refuse (fun () -> M.verify_source t ~documents:[]); refuse (fun () -> M.verify_disk t))
let deterministic () = with_project (fun root path ->
  let a = path "schema/notes/v-current.tesl" and b = path "migrations/notes/v2.tesl" in
  let writes = [a,"current";b,"migration"] in
  let t1 = proposal ~reads:[a;b;a] root writes in
  let t2 = proposal ~reads:[b;a] root (List.rev writes) in
  check string "stable serialization" (M.to_json t1) (M.to_json t2);
  check string "stable artifact identity" (M.digest t1) (M.digest t2);
  let t3 = proposal root [a,"different";b,"migration"] in
  check bool "replacement bytes bound into artifact" false (M.digest t1 = M.digest t3))
let arbitrary_directory_bytes () = with_project (fun root path ->
  write (path "unrelated-\255.txt") "x";
  let t = proposal root [] in
  unchanged t;
  check bool "directory membership hashes keep JSON valid" true (String.is_valid_utf_8 (M.to_json t));
  Sys.remove (path "unrelated-\255.txt"); refuse (fun () -> M.verify_disk t))
let checked_freeze () = with_project (fun root path ->
  let current = path "schema/notes/v-current.tesl" in
  let source = "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Private\n" in
  let private_file = path "schema/notes/v-current/private.tesl" in
  let private_source = "module NotesSchema.VCurrent.Private exposing []\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n" in
  write current source; write private_file private_source;
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
    | Ok copies -> copies | Error message -> fail message in
  let reads = List.map (fun (c : Migration_source.frozen_copy) -> c.source_path) copies in
  let writes = List.map (fun (c : Migration_source.frozen_copy) -> c.target_path,c.contents) copies in
  let t = proposal ~reads root writes in
  Source_input.with_overlays ~project_root:root (M.overlays t) (fun () ->
    let inventory = Migration_inventory.load ~compiler_abi:"fixture" ~root_file:(path "schema/notes/v1.tesl") in
    match inventory with
    | Ok inventory -> check int "frozen private entity is checked" 1 (List.length (Migration_inventory.stored_entities inventory))
    | Error error -> fail error.message);
  unchanged t;
  check bool "checked frozen files remain virtual" false (Sys.file_exists (path "schema/notes/v1.tesl"));
  write private_file (private_source ^ "# changed after validation\n");
  refuse (fun () -> M.verify_disk t))
let outer_scope () = with_project (fun root path ->
  Source_input.with_overlays ~project_root:(Filename.dirname root) [] (fun () ->
    let t = proposal root [path "schema/notes/v1.tesl","frozen"] in unchanged t))
let import_retarget () = with_project (fun root path ->
  let source = path "app.tesl" in write source "module App exposing []\nimport Helper\n";
  let fallback = path "Helper.tesl" in write fallback "module Helper exposing []\n";
  mkdir (path "elsewhere");
  let shadow = path "helper.tesl" and target = path "elsewhere/new.tesl" in
  Unix.symlink target shadow;
  let t = proposal ~imports:[source,"Helper"] root [] in
  unchanged t;
  (* No name changes in either guarded parent, and the old dependency is intact.
     Making an existing dangling candidate resolve still changes the import. *)
  write target "module Helper exposing []\n";
  refuse (fun () -> M.verify_source t ~documents:[]);
  refuse (fun () -> M.verify_disk t))
let virtual_import_resolution () = with_project (fun root path ->
  let source = path "app.tesl" in write source "module App exposing []\nimport Helper\n";
  let fallback = path "Helper.tesl" in write fallback "module Helper exposing []\n";
  let proposed = path "helper.tesl" in
  let t = Source_input.with_overlays ~project_root:root [proposed,"module Helper exposing []\n"] (fun () ->
    let t = proposal ~imports:[source,"Helper"] root [] in
    unchanged t;
    let json = M.to_json t in
    check bool "source import selects proposed file" true (contains json ("\"sourceResolved\":\"" ^ proposed ^ "\""));
    check bool "saved import keeps disk fallback" true (contains json ("\"diskResolved\":\"" ^ fallback ^ "\"")); t) in
  get (M.verify_disk t);
  refuse (fun () -> M.verify_source t ~documents:[]))
let () = run "Migration source manifests" ["guarded proposals", List.map (fun (name,f) -> test_case name `Quick f)
  ["preview never writes sources or directories",no_writes;
   "arbitrary source bytes survive JSON transport",byte_edits;"no-op writes retain guards",noops;
   "private dependency byte changes",dependency_bytes;"saved versus editor source identity",saved_vs_buffer;
   "disk changes beneath an unchanged buffer",disk_change_under_buffer;"virtual new files",virtual_creation;
   "document set and signed versions",editor_versions;"discovery and import-shadow membership",directory_membership;
   "absent and empty directories differ",missing_directory;"concurrent output creation",create_conflict;
   "invalid and conflicting output paths",invalid_paths;"symlinks and special files",symlinks_and_specials;
   "replaced parent directory",replaced_parent;"deterministic complete identity",deterministic;
   "non-UTF8 directory entries are hashable",arbitrary_directory_bytes;
   "checked private schema freeze remains virtual",checked_freeze;"nested source view",outer_scope;
   "dangling candidate becoming an import",import_retarget;
   "separate disk and proposed import resolution",virtual_import_resolution]]
