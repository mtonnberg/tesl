open Alcotest

let with_files f =
  let input = Filename.temp_file "tesl-session-input-" "" in
  let output = Filename.temp_file "tesl-session-output-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove input; Sys.remove output;
    Query_cache.set_enabled false) (fun () -> f input output)

let frame_roundtrip () = with_files (fun path _ ->
  let values = [""; "hello\000world"; "räksmörgås 😀\r\n"] in
  Out_channel.with_open_bin path (fun out -> List.iter (Workspace_session.write_frame out) values);
  In_channel.with_open_bin path (fun input ->
    List.iter (fun expected -> check string "exact bytes" expected (Workspace_session.read_frame input 100)) values))

let bad_frame data = with_files (fun path _ ->
  Out_channel.with_open_bin path (fun out -> output_string out data);
  let rejected = In_channel.with_open_bin path (fun input ->
    try ignore (Workspace_session.read_frame input 20); false with _ -> true) in
  check bool "malformed frame rejected" true rejected)

let cache_disabled () =
  Query_cache.set_enabled false;
  let calls = ref 0 in
  let cached = Query_cache.memo ~limit:2 ~max_weight:10 ~weight:String.length (fun key -> incr calls; key) in
  ignore (cached "same"); ignore (cached "same");
  check int "one-shot does not cache" 2 !calls

let cache_lifecycle () =
  Query_cache.set_enabled true;
  let calls = ref 0 in
  let cached = Query_cache.memo ~limit:2 ~max_weight:10 ~weight:String.length (fun key -> incr calls; key) in
  List.iter (fun key -> ignore (cached key)) ["a"; "a"; "b"; "c"; "a"];
  check int "entry limit evicts" 4 !calls;
  Query_cache.clear (); ignore (cached "a");
  check int "revision invalidates" 5 !calls;
  Query_cache.set_enabled false

let cache_weight () =
  Query_cache.set_enabled true;
  let calls = ref 0 in
  let cached = Query_cache.memo ~limit:20 ~max_weight:10 ~weight:(fun _ -> 0)
    ~value_weight:String.length (fun key -> incr calls; key) in
  List.iter (fun key -> ignore (cached key)) ["12345678901"; "12345678901"; "123456"; "abcdef"; "123456"];
  check int "response byte limit" 5 !calls;
  Query_cache.set_enabled false

let shared_metadata () =
  let source = "module Cache exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\n" in
  let path = Filename.concat (Sys.getcwd ()) "cache.tesl" in
  Query_cache.set_enabled false;
  let fresh = Compile.type_at_source path source 2 28 in
  Query_cache.set_enabled true;
  let first = Compile.type_at_source path source 2 28 in
  let misses = !Query_cache.misses in
  let second = Compile.type_at_source path source 2 29 in
  check bool "fresh equivalence" true (first = fresh);
  check bool "neighbor shares metadata" true (second <> None);
  check int "no additional parse/check" misses !Query_cache.misses;
  Query_cache.set_enabled false

let malformed_request () = with_files (fun input output ->
  Out_channel.with_open_bin input (fun out -> Workspace_session.write_frame out "revision");
  let rejected = In_channel.with_open_bin input (fun input ->
    Out_channel.with_open_bin output (fun output ->
      try Workspace_session.run input output; false with _ -> true)) in
  check bool "truncated request rejected" true rejected;
  check bool "caches disabled on failure" false !Query_cache.enabled)

let query_recovery () = with_files (fun input output ->
  let source_file = Filename.temp_file "tesl-session-" ".tesl" in
  Fun.protect ~finally:(fun () -> Sys.remove source_file) (fun () ->
    Out_channel.with_open_bin source_file (fun out -> output_string out "module Session exposing []\n");
    let request flag = ["revision"; flag; source_file; ""; ""] in
    Out_channel.with_open_bin input (fun out ->
      List.iter (Workspace_session.write_frame out) (request "unsupported" @ request "--check-json"));
    In_channel.with_open_bin input (fun input -> Out_channel.with_open_bin output (fun output -> Workspace_session.run input output));
    In_channel.with_open_bin output (fun input ->
      ignore (Workspace_session.read_frame input 4096);
      let failed = Workspace_session.read_frame input Workspace_session.max_response in
      let good = Workspace_session.read_frame input Workspace_session.max_response in
      check bool "failure explicit" true (String.contains failed 'I');
      check bool "next request succeeds" true (try ignore (Str.search_forward (Str.regexp_string "\"error\":null") good 0); true with Not_found -> false))))

let snapshot_cache_classes () =
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    let retained_calls = ref 0 and snapshot_calls = ref 0 in
    let retained = Query_cache.memo ~retain_across_snapshots:true ~limit:2 ~max_weight:10
      ~weight:String.length (fun value -> incr retained_calls; value) in
    let snapshot = Query_cache.memo ~limit:2 ~max_weight:10
      ~weight:String.length (fun value -> incr snapshot_calls; value) in
    ignore (retained "a"); ignore (snapshot "a");
    Query_cache.advance_snapshot ();
    ignore (retained "a"); ignore (snapshot "a");
    check int "source keyed answer retained" 1 !retained_calls;
    check int "path keyed answer discarded" 2 !snapshot_calls;
    Query_cache.clear ();
    ignore (retained "a");
    check int "session reset discards both" 2 !retained_calls)

let with_project f =
  let root = Filename.temp_file "tesl-incremental-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let write name source = Out_channel.with_open_bin (Filename.concat root name) (fun out -> output_string out source) in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () ->
    Query_cache.set_enabled false; Checker.clear_import_parse_cache ();
    Array.iter (fun name -> Sys.remove (Filename.concat root name)) (Sys.readdir root); Unix.rmdir root)
    (fun () -> f root write)

let leaf = "module Leaf exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value(n: Int) -> Int = n\n"
let main_source = "module Main exposing [use]\nimport Tesl.Prelude exposing [Int]\nimport Leaf exposing [value]\nfn use(n: Int) -> Int = value n\n"
let ast root source =
  match Compile.parse_module (Filename.concat root "main.tesl") source with
  | Parser.Ok m -> m | Parser.Err _ -> fail "fixture did not parse"
let metadata m = Checker.check_module_with_metadata m
let check_fresh m retained =
  let fresh = Checker.check_module_with_metadata_uncached m in
  check bool "retained result equals cold checker" true (retained = fresh)

let unrelated_module_retained () = with_project (fun root write ->
  write "leaf.tesl" leaf;
  let m = ast root main_source in
  let first = metadata m in
  write "other.tesl" "module Other exposing []\n";
  Query_cache.advance_snapshot ();
  let second = metadata m in
  check bool "unrelated change reuses checked metadata" true (first == second);
  check bool "entry parse retained too" true (m == ast root main_source);
  check_fresh m second)

let direct_import_transitions () = with_project (fun root write ->
  write "leaf.tesl" leaf;
  let m = ast root main_source in
  let first = metadata m in
  let path = Filename.concat root "leaf.tesl" in
  let state = Unix.stat path in
  (* Same length and restored timestamps still invalidate semantic inputs. *)
  write "leaf.tesl" (String.sub leaf 0 (String.length leaf - 2) ^ "0\n");
  Unix.utimes path state.Unix.st_atime state.Unix.st_mtime;
  Query_cache.advance_snapshot ();
  let edited = metadata m in
  check bool "same-sized import edit rechecks" false (first == edited);
  check_fresh m edited;
  List.iter (fun source ->
    (match source with None -> Sys.remove path | Some source -> write "leaf.tesl" source);
    Query_cache.advance_snapshot ();
    check_fresh m (metadata m))
    [Some "module Leaf exposing ["; Some leaf; None; Some leaf])

let transitive_import_invalidates () = with_project (fun root write ->
  write "leaf.tesl" leaf;
  write "middle.tesl" "module Middle exposing [relay]\nimport Tesl.Prelude exposing [Int]\nimport Leaf exposing [value]\nfn relay(n: Int) -> Int = value n\n";
  let source = "module Main exposing [use]\nimport Tesl.Prelude exposing [Int]\nimport Middle exposing [relay]\nfn use(n: Int) -> Int = relay n\n" in
  let m = ast root source in
  let first = metadata m in
  write "leaf.tesl" "module Leaf exposing [value]\nimport Tesl.Prelude exposing [String]\nfn value(n: String) -> String = n\n";
  Query_cache.advance_snapshot ();
  let changed = metadata m in
  check bool "grandchild change rechecks caller" false (first == changed);
  check_fresh m changed)

let import_resolution_precedence () = with_project (fun root write ->
  write "Leaf.tesl" leaf;
  let m = ast root main_source in
  let original = metadata m in
  write "leaf.tesl" "module Leaf exposing []\n";
  Query_cache.advance_snapshot ();
  let replaced = metadata m in
  check bool "new preferred spelling rechecks" false (original == replaced);
  check_fresh m replaced;
  Sys.remove (Filename.concat root "leaf.tesl");
  Query_cache.advance_snapshot ();
  check_fresh m (metadata m))

let source_identity_not_just_dependency_identity () = with_project (fun root write ->
  write "leaf.tesl" leaf;
  let before = ast root main_source in
  let first = metadata before in
  let source = "module Main exposing [use]\nimport Tesl.Prelude exposing [Int, String]\nimport Leaf exposing [value]\nfn use(n: String) -> Int = value n\n" in
  let after = ast root source in
  Query_cache.advance_snapshot ();
  let result = metadata after in
  check bool "changed entry cannot reuse metadata" false (first == result);
  check_fresh after result;
  let _, _, _, _, _, _, errors = result in
  check bool "new type error is reported" true (errors <> []))

let bounded_and_cyclic_inputs () = with_project (fun root write ->
  write "leaf.tesl" "module Leaf exposing []\nimport Main\n";
  write "main.tesl" "module Main exposing []\nimport Leaf\n";
  let m = ast root "module Main exposing []\nimport Leaf\n" in
  check bool "cyclic graph scan terminates" true (Checker.module_semantic_inputs m <> None);
  write "leaf.tesl" (String.make (1024 * 1024 + 1) ' ');
  check bool "oversized dependency disables semantic caching" true (Checker.module_semantic_inputs m = None))

let () = run "Workspace session" ["protocol and retention", List.map (fun (name, test) -> test_case name `Quick test)
  ["binary/Unicode framing", frame_roundtrip;
   "oversized frame", (fun () -> bad_frame "\255\255\255\255");
   "truncated length", (fun () -> bad_frame "\000\000");
   "truncated body", (fun () -> bad_frame "\000\000\000\004ab");
   "one-shot bypass", cache_disabled; "entry bounds and revisions", cache_lifecycle;
   "result byte bounds", cache_weight; "shared checked metadata", shared_metadata;
   "truncated request", malformed_request; "error recovery", query_recovery;
   "snapshot and semantic cache lifetimes", snapshot_cache_classes;
   "unrelated checked modules retained", unrelated_module_retained;
   "direct import edit delete repair", direct_import_transitions;
   "transitive dependency edit", transitive_import_invalidates;
   "import resolution precedence", import_resolution_precedence;
   "entry source identity", source_identity_not_just_dependency_identity;
   "bounded cyclic dependency scan", bounded_and_cyclic_inputs]]
