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
let combine_selection () = with_project (fun root path ->
  let app = path "app.tesl" and helper = path "helper.tesl" in
  write app "module App exposing []\nimport Helper\n";
  write helper "module Helper exposing []\n";
  let selection = proposal ~reads:[app] ~imports:[app,"Helper"] root [] in
  let schema = path "schema/notes/v-current.tesl" in
  let output = path "migrations/notes/v2.tesl" in
  let generation = proposal ~reads:[schema] root [output,"generated"] in
  let combined = get (M.combine selection generation ~documents:[]) in
  let together = proposal ~reads:[app;schema] ~imports:[app,"Helper"] root [output,"generated"] in
  check string "union retains all original guards" (M.to_json together) (M.to_json combined);
  check string "independent composition is commutative" (M.to_json combined)
    (M.to_json (get (M.combine generation selection ~documents:[])));
  check string "equal operations are idempotent" (M.to_json combined)
    (M.to_json (get (M.combine combined combined ~documents:[])));
  check bool "combined preview creates no file" false (Sys.file_exists output);
  write app "module App exposing []\n# database selection changed\n";
  refuse (fun () -> M.verify_source combined ~documents:[]);
  refuse (fun () -> M.verify_disk combined))
let combine_stale () = with_project (fun root path ->
  let app = path "app.tesl" in write app "old database";
  let selected = proposal ~reads:[app] root [] in
  write app "different database";
  let generated = proposal root [path "migrations/notes/v2.tesl","generated"] in
  refuse (fun () -> M.combine selected generated ~documents:[]);
  let recaptured = proposal ~reads:[app] root [] in
  refuse (fun () -> M.combine selected recaptured ~documents:[]))
let combine_conflicts () = with_project (fun root path ->
  let output = path "migrations/notes/v2.tesl" in
  let a = proposal root [output,"first"] and b = proposal root [output,"second"] in
  refuse (fun () -> M.combine a b ~documents:[]);
  let a = proposal root [path "parent.tesl","file"] in
  let b = proposal root [path "parent.tesl/child.tesl","child"] in
  refuse (fun () -> M.combine a b ~documents:[]);
  with_project (fun other _ ->
    let b = proposal other [] in refuse (fun () -> M.combine a b ~documents:[])))
let combine_versions () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let old = [{M.path=file;version=3}] and fresh = [{M.path=file;version=4}] in
  let a = proposal ~documents:old root [] in
  let b = proposal ~documents:fresh root [] in
  refuse (fun () -> M.combine a b ~documents:fresh);
  refuse (fun () -> M.combine a a ~documents:fresh);
  refuse (fun () -> M.combine a a ~documents:[]);
  let combined = get (M.combine a a ~documents:old) in
  get (M.verify_source combined ~documents:old))
let combine_disk_buffer () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let saved = read file and buffer = "unsaved selected source" in
  Source_input.with_overlays ~project_root:root [file,buffer] (fun () ->
    let a = proposal ~reads:[file] root [] in
    write file (saved ^ "# later saved write\n");
    let b = proposal ~reads:[file] root [] in
    refuse (fun () -> M.combine a b ~documents:[]);
    write file saved;
    let b = proposal root [path "migrations/notes/v2.tesl","generated"] in
    let combined = get (M.combine a b ~documents:[]) in
    unchanged combined;
    check bool "source and disk hashes remain different" true
      (contains (M.to_json combined) (Migration_hash.digest buffer) && contains (M.to_json combined) (Migration_hash.digest saved))))
let combine_discovery () = with_project (fun root path ->
  mkdir (path "discovery");
  let a = proposal ~directories:[path "discovery"] root [] in
  write (path "discovery/entry.tesl") "new candidate";
  let b = proposal ~directories:[path "discovery"] root [] in
  refuse (fun () -> M.combine a b ~documents:[]);
  let app = path "app.tesl" in write app "module App exposing []\nimport Helper\n";
  write (path "Helper.tesl") "module Helper exposing []\n";
  let a = proposal ~imports:[app,"Helper"] root [] in
  Source_input.with_overlays ~project_root:root [path "helper.tesl","module Helper exposing []\n"] (fun () ->
    let b = proposal ~imports:[app,"Helper"] root [] in
    refuse (fun () -> M.combine a b ~documents:[])))
let compilation_bytes () = with_project (fun root path ->
 let app=path "schema/notes/v-current.tesl" in
 let source=read app in
 let manifest=proposal ~reads:[app] root [] in
 check bool "captured exact source bytes" true (List.mem (app,source) (get (M.source_files manifest)));
 write app (source ^ "# changed\n");
 refuse (fun () -> M.source_files manifest);
 Source_input.with_overlays ~project_root:root [app,source] (fun () ->
  check bool "source capture respects the original unsaved view" true
   (List.mem (app,source) (get (M.source_files manifest)));
  refuse (fun () -> M.verify_disk manifest)))
let batch_identity () = with_project (fun root path ->
  let files = List.init 12 (fun i -> path (Printf.sprintf "helper%d.tesl" i)) in
  List.iter (fun file -> write file "module Helper exposing []\n") files;
  let parts = List.map (fun file -> proposal ~reads:[file] root []) files in
  let repeated = List.fold_left (fun all next -> get (M.combine all next ~documents:[]))
      (List.hd parts) (List.tl parts) in
  let batch = get (M.combine_many (parts @ List.rev parts) ~documents:[]) in
  check string "batch retains byte-identical guards" (M.to_json repeated) (M.to_json batch);
  check string "batch retains byte-identical digest" (M.digest repeated) (M.digest batch);
  unchanged batch)

let batch_early_stale () = with_project (fun root path ->
  let early = path "early.tesl" and late = path "late.tesl" in
  write early "early bytes"; write late "late bytes";
  let a = proposal ~reads:[early] root [] in
  write early "other bytes";
  let b = proposal ~reads:[late] root [] in
  refuse (fun () -> M.combine_many [a;b;b] ~documents:[]);
  let recaptured = proposal ~reads:[early] root [] in
  refuse (fun () -> M.combine_many [a;b;recaptured] ~documents:[]);
  Source_input.with_overlays ~project_root:root [early,"early bytes"] (fun () ->
    let b = proposal ~reads:[late] root [] in
    refuse (fun () -> M.combine_many [a;b;b] ~documents:[])))

let batch_late_conflicts () = with_project (fun root path ->
  let file = path "schema/notes/v-current.tesl" in
  let a = proposal root [file,"first"] and b = proposal root [] in
  let c = proposal root [file,"second"] in
  refuse (fun () -> M.combine_many [a;b;c] ~documents:[]);
  let old = [{M.path=file;version=1}] and fresh = [{M.path=file;version=2}] in
  let a = proposal ~documents:old root [] and b = proposal ~documents:fresh root [] in
  refuse (fun () -> M.combine_many [a;a;b] ~documents:old);
  refuse (fun () -> M.combine_many [] ~documents:[]))

let batch_alias () = with_project (fun root path ->
  let early = path "early.tesl" and target = path "target.tesl" in
  write early "same bytes"; write target "same bytes";
  let a = proposal ~reads:[early] root [] and b = proposal ~reads:[target] root [] in
  Sys.remove early; Unix.symlink target early;
  refuse (fun () -> M.combine_many [a;b;b] ~documents:[]))

let captured_graph () = with_project (fun root path ->
  let leaves = List.init 16 (fun i -> Printf.sprintf "Leaf%d" i) in
  List.iter (fun name -> write (path (String.lowercase_ascii name ^ ".tesl"))
    ("module " ^ name ^ " exposing []\n")) leaves;
  let source = "module App exposing []\n" ^ String.concat ""
    (List.map (fun name -> "import " ^ name ^ "\n") leaves) in
  let app = path "app.tesl" in write app source;
  let capture () = match Migration_source_integrity.capture ~history:None ~project_root:root ~inputs:[app,source] with
    | Ok token -> token | Error _ -> fail "valid graph refused" in
  let token = capture () in
  (match Migration_source_integrity.with_captured token (fun () -> Source_input.read app) with
   | Ok actual -> check string "captured graph is readable" source actual
   | Error _ -> fail "unchanged graph refused");
  let leaf = path "leaf0.tesl" in
  write leaf "module Leaf0 exposing []\n# edited\n";
  (match Migration_source_integrity.revalidate token with Error (_::_) -> () | _ -> fail "early helper edit accepted");
  let token = capture () in
  write (path "leaf17.tesl") "module Leaf17 exposing []\n";
  (match Migration_source_integrity.revalidate token with Error (_::_) -> () | _ -> fail "new directory member accepted"))

let incremental_identity () = with_project (fun root path ->
  let files = List.init 24 (fun i -> path (Printf.sprintf "part%d.tesl" i)) in
  List.iter (fun file -> write file "captured bytes") files;
  let parts = List.map (fun file -> proposal ~reads:[file] root []) files in
  let accumulator = List.fold_left (fun accumulator part -> get (M.add_to_combine accumulator part))
    (get (M.start_combine (List.hd parts) ~documents:[])) (List.tl parts) in
  let combined = get (M.finish_combine accumulator) in
  check string "incremental union has exact batch identity"
    (M.to_json (get (M.combine_many parts ~documents:[]))) (M.to_json combined);
  write (List.hd files) "changed earliest input";
  refuse (fun () -> M.finish_combine accumulator);
  let fresh = proposal ~reads:[List.hd files] root [] in
  refuse (fun () -> M.add_to_combine accumulator fresh))


(* The frozen history scope. The layout and digest match the Go applier's
   vector (internal/sourceedit/history_test.go). *)
let history_layout path =
  List.iter (fun (name,contents) -> write (path name) contents)
    ["schema/s/v-current.tesl","cur";"schema/s/v1.tesl","one";"schema/s/sub/x.tesl","x";
     "migrations/s/v2.tesl","m2";"migrations/s/v1.checkpoint","c1";"migrations/s/v2.checkpoint","c2";
     "migrations/s/v3.tesl","m3"]
let history_scope path = {M.history_trees=[path "migrations/s";path "schema/s"];
  keep=(fun file -> file = path "schema/s/v-current.tesl" || file = path "migrations/s/v3.tesl")}
let history_reads path = List.map path ["schema/s/v-current.tesl";"schema/s/v1.tesl";"schema/s/sub/x.tesl";
  "migrations/s/v2.tesl";"migrations/s/v3.tesl"]
let scoped ?(imports=[]) root path =
  get (M.create_scoped (Some (history_scope path)) ~project_root:root ~reads:(history_reads path)
    ~directories:[] ~imports ~documents:[] ~writes:[])
let history_vector () = with_project (fun root path ->
  history_layout path;
  let t = scoped root path in
  let json = M.to_json t in
  check bool "version 2" true (contains json "{\"version\":2,");
  check bool "one digest for the frozen files" true
    (contains json "\"sourceHash\":\"a55a135c5d39d75aeb9fa491a9186a5af7d26ed8c7017ecaeedc06d8a73ae733\",\"diskHash\":\"a55a135c5d39d75aeb9fa491a9186a5af7d26ed8c7017ecaeedc06d8a73ae733\"");
  check bool "frozen files lose their own guards" false (contains json (path "schema/s/v1.tesl"));
  check bool "current files keep theirs" true (contains json ("{\"path\":\"" ^ path "migrations/s/v3.tesl" ^ "\",\"sourceHash\""));
  unchanged t)
let history_changes () =
  let refused name change = with_project (fun root path ->
    history_layout path;
    let t = scoped root path in
    change path;
    match M.verify_disk t with
    | Error (_::_) -> ()
    | _ -> fail (name ^ " accepted")) in
  refused "edited frozen source" (fun path -> write (path "schema/s/v1.tesl") "ONE");
  refused "edited nested module" (fun path -> write (path "schema/s/sub/x.tesl") "y");
  refused "added file" (fun path -> write (path "schema/s/sub/y.tesl") "");
  refused "removed file" (fun path -> Sys.remove (path "migrations/s/v2.tesl"));
  refused "added directory" (fun path -> mkdir (path "schema/s/v1"));
  refused "edited newest checkpoint" (fun path -> write (path "migrations/s/v2.checkpoint") "C2");
  refused "removed older checkpoint" (fun path -> Sys.remove (path "migrations/s/v1.checkpoint"));
  refused "symbolic link" (fun path -> Unix.symlink "v1.tesl" (path "schema/s/alias.tesl"));
  refused "edited current source" (fun path -> write (path "migrations/s/v3.tesl") "M3");
  with_project (fun root path ->
    history_layout path;
    let t = scoped root path in
    write (path "migrations/s/v1.checkpoint") "older";
    unchanged t)
let history_fallback () = with_project (fun root path ->
  history_layout path;
  Unix.symlink "v1.tesl" (path "schema/s/alias.tesl");
  let t = scoped root path in
  let json = M.to_json t in
  check bool "an unobservable tree keeps per-file guards" true
    (contains json "\"history\":[]" && contains json (path "schema/s/v1.tesl"));
  unchanged t)
let history_imports () = with_project (fun root path ->
  history_layout path;
  let frozen = path "migrations/s/v2.tesl" and current = path "schema/s/v-current.tesl" in
  let t = scoped ~imports:[frozen,"Schema.S.V1";current,"Schema.S.V1"] root path in
  let json = M.to_json t in
  check bool "an import between frozen sources is part of the tree" false (contains json ("\"source\":\"" ^ frozen));
  check bool "a current source's import keeps its guard" true (contains json ("\"source\":\"" ^ current));
  check bool "and its target keeps a file guard" true (contains json ("{\"path\":\"" ^ path "schema/s/v1.tesl" ^ "\",\"sourceHash\""));
  unchanged t;
  (* A parent entry that could begin a deeper candidate keeps every import guard. *)
  mkdir (path "migrations/schema");
  let shadowed = scoped ~imports:[frozen,"Schema.S.V1"] root path in
  check bool "shadowing parent keeps the import guard" true (contains (M.to_json shadowed) ("\"source\":\"" ^ frozen)))
let history_combine () = with_project (fun root path ->
  history_layout path;
  let t = scoped root path in
  let frozen = path "schema/s/v1.tesl" in
  let other = proposal ~reads:[frozen] root [] in
  let combined = get (M.combine t other ~documents:[]) in
  check bool "a separately guarded frozen file is excluded" true
    (contains (M.to_json combined) ("\"excluded\":[\"" ^ path "migrations/s/v3.tesl" ^ "\",\"" ^ path "schema/s/v-current.tesl" ^ "\",\"" ^ frozen ^ "\"]"));
  unchanged combined;
  write frozen "ONE";
  let changed = proposal ~reads:[frozen] root [] in
  refuse (fun () -> M.combine t changed ~documents:[]);
  write frozen "one";
  let again = scoped root path in
  write (path "schema/s/sub/x.tesl") "y";
  refuse (fun () -> M.combine again (scoped root path) ~documents:[]))
(* A compilation takes the bytes of the frozen sources a scope covers from the
   walk that hashed them, and a capture can take every frozen source at once. *)
let history_sources () = with_project (fun root path ->
  history_layout path;
  let t = scoped root path in
  let pairs = list (pair string string) in
  check pairs "covered reads keep their exact bytes"
    (List.sort compare (List.map (fun name -> path name, read (path name)) ["schema/s/v-current.tesl";"schema/s/v1.tesl";
       "schema/s/sub/x.tesl";"migrations/s/v2.tesl";"migrations/s/v3.tesl"]))
    (get (M.source_files t));
  check (option pairs) "every frozen source of the trees"
    (Some (List.map (fun name -> path name, read (path name)) ["migrations/s/v2.tesl";"schema/s/sub/x.tesl";"schema/s/v1.tesl"]))
    (Option.map (List.sort compare) (get (M.frozen_sources t)));
  check (option pairs) "no scope, no frozen sources" None (get (M.frozen_sources (proposal ~reads:[path "schema/s/v1.tesl"] root [])));
  write (path "schema/s/v1.tesl") "ONE";
  refuse (fun () -> M.source_files t);
  write (path "schema/s/v1.tesl") "one";
  mkdir (path "migrations/schema");
  check (option pairs) "a shadowing parent keeps imports guarded one by one" None (get (M.frozen_sources (scoped root path))))
(* An intermediate source check reuses a scope's source walk verified in the
   identical view; the disk check of the same pass still reads the trees. *)
let history_quick () = with_project (fun root path ->
  history_layout path;
  Source_input.with_scope_path_memo (fun () ->
    let t = scoped root path in
    get (M.verify_source t ~documents:[]);
    get (M.verify_disk t);
    write (path "schema/s/v1.tesl") "ONE";
    get (M.verify_source ~quick:true t ~documents:[]);
    refuse (fun () -> M.verify_disk ~quick:true t);
    refuse (fun () -> M.verify_disk t));
  (* Another view walks again. *)
  write (path "schema/s/v1.tesl") "one";
  Source_input.with_scope_path_memo (fun () ->
    let t = scoped root path in
    get (M.verify_source t ~documents:[]);
    Source_input.with_overlays ~project_root:root [path "schema/s/v1.tesl","ONE"] (fun () ->
      refuse (fun () -> M.verify_source ~quick:true t ~documents:[]))))
(* One disk pass over two manifests of the same trees observes each entry once;
   an edit made before the pass is refused by both. *)
let history_pass () = with_project (fun root path ->
  history_layout path;
  let a = scoped root path and b = scoped root path in
  M.with_pass (fun () -> get (M.verify_disk a); get (M.verify_disk b));
  write (path "schema/s/v1.tesl") "ONE";
  M.with_pass (fun () -> refuse (fun () -> M.verify_disk a); refuse (fun () -> M.verify_disk b)))
let family_scope () = with_project (fun root path ->
  let h = M.family_history ~project_root:root ~family:"Schema.Notes" ~current_version:2 in
  check (list string) "trees" [path "schema/notes";path "migrations/notes"] h.history_trees;
  List.iter (fun (name,expected) -> check bool name expected (h.keep (path name)))
    ["schema/notes/v-current.tesl",true;"schema/notes/v-current/x.tesl",true;"schema/notes/v1.tesl",false;
     "migrations/notes/v2.tesl",true;"migrations/notes/v2-contract.tesl",true;"migrations/notes/v2.checkpoint",true;
     "migrations/notes/v2/helper.tesl",true;"migrations/notes/v21.tesl",false;"migrations/notes/v1.checkpoint",false;
     "app.tesl",true])

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
   "separate disk and proposed import resolution",virtual_import_resolution;
   "combine target and generation without recapturing inputs",combine_selection;
   "changed selection cannot be blessed by another preview",combine_stale;
   "competing edits, path conflicts and different roots",combine_conflicts;
   "composition retains document-version guards",combine_versions;
   "composition keeps disk and unsaved source distinct",combine_disk_buffer;
   "composition retains discovery and import resolution",combine_discovery;
   "compilation captures exact original source bytes",compilation_bytes;
   "batch composition preserves complete manifest identity",batch_identity;
   "batch refuses early stale and recaptured source",batch_early_stale;
   "batch refuses late edit and document conflicts",batch_late_conflicts;
   "batch refuses a replaced path alias",batch_alias;
   "batched graph capture guards helpers and membership",captured_graph;
   "incremental composition preserves original observations",incremental_identity;
   "frozen history digest vector",history_vector;
   "frozen history refuses changed, added and removed entries",history_changes;
   "unobservable history keeps per-file guards",history_fallback;
   "imports between frozen sources",history_imports;
   "composition keeps the frozen history observations",history_combine;
   "family history scope",family_scope;
   "frozen sources come from the scope's walk",history_sources;
   "an intermediate source check leaves frozen edits to the disk check",history_quick;
   "one disk pass over manifests of the same trees",history_pass]]
