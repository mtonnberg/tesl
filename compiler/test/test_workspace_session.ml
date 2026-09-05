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

let () = run "Workspace session" ["protocol and retention", List.map (fun (name, test) -> test_case name `Quick test)
  ["binary/Unicode framing", frame_roundtrip;
   "oversized frame", (fun () -> bad_frame "\255\255\255\255");
   "truncated length", (fun () -> bad_frame "\000\000");
   "truncated body", (fun () -> bad_frame "\000\000\000\004ab");
   "one-shot bypass", cache_disabled; "entry bounds and revisions", cache_lifecycle;
   "result byte bounds", cache_weight; "shared checked metadata", shared_metadata;
   "truncated request", malformed_request; "error recovery", query_recovery]]
