open Alcotest
module A = Migration_abi
let get = function Ok x -> x | Error (e : A.error) -> fail (e.path ^ ": " ^ e.message)
let refuse = function Error e -> e | Ok _ -> fail "invalid ABI resources accepted"
let read file = In_channel.with_open_bin file In_channel.input_all
let write file source = Out_channel.with_open_bin file (fun out -> output_string out source)
let rec remove path = if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let with_directory f =
  let directory = Filename.temp_file "tesl-compiler-abi-" ".dir" in Sys.remove directory; Unix.mkdir directory 0o700;
  Fun.protect ~finally:(fun () -> remove directory) (fun () -> f directory)
let with_env directory f =
  let previous = Sys.getenv_opt "TESL_STDLIB_DIR" in
  Unix.putenv "TESL_STDLIB_DIR" directory;
  Fun.protect ~finally:(fun () -> Unix.putenv "TESL_STDLIB_DIR" (Option.value previous ~default:"")) f
let originals () = List.map (fun (name,base) ->
  let file = match Validation_common.lifted_stdlib_source_path name with Some file -> file | None -> fail name in
  base,read file) Validation_common.lifted_stdlib_sources
let populate directory sources = List.iter (fun (name,source) -> write (Filename.concat directory name) source) sources
let with_sources f =
  let sources = originals () in
  with_directory (fun root -> populate root sources; with_env root (fun () -> f root sources))
let stable () =
  let first = get (A.current ()) and second = get (A.current ()) in
  check string "same build and resources" (A.id first) (A.id second);
  check string "stable stored-value contract" (A.stored_value_compatibility first) (A.stored_value_compatibility second);
  check bool "strict stored-value contract format" true (A.valid_stored_value_compatibility (A.stored_value_compatibility first));
  check bool "source ABI is not a compatibility contract" false (A.valid_stored_value_compatibility (A.id first));
  check bool "versioned actual-build tag" true (String.starts_with ~prefix:"tesl-source-abi-v1:" (A.id first));
  check int "fixed SHA-256 suffix" (String.length "tesl-source-abi-v1:" + 64) (String.length (A.id first));
  check int "all lifted sources guarded" (List.length Validation_common.lifted_stdlib_sources) (List.length (A.source_inputs first));
  get (A.verify first)
let relocated () =
  let original = get (A.current ()) and sources = originals () in
  with_directory (fun root -> populate root sources;
    with_env root (fun () ->
      let relocated = get (A.current ()) in
      check string "resource installation path is not semantics" (A.id original) (A.id relocated);
      check string "compatibility is independent of resource installation path"
        (A.stored_value_compatibility original) (A.stored_value_compatibility relocated)))
let changed_source () = with_sources (fun root sources ->
  let before = get (A.current ()) in
  List.iter (fun (name,source) ->
    let file = Filename.concat root name in
    write file (source ^ "\n# source ABI regression\n");
    ignore (Compile.agent_context_result_source file (read file));
    check bool "each lifted source contributes" false (A.id before=A.id (get (A.current ())));
    check bool "every lifted source contributes to stored-value compatibility" false
      (A.stored_value_compatibility before=A.stored_value_compatibility (get (A.current ())));
    ignore (refuse (A.verify before));
    write file source;
    ignore (Compile.agent_context_result_source file source);
    get (A.verify before)) sources)
let guarded_hashes () = with_sources (fun _ _ ->
  let snapshot = get (A.current ()) in
  List.iter (fun (file,digest) -> check string file (Migration_hash.digest (read file)) digest) (A.source_inputs snapshot))
let extra_source () = with_sources (fun root _ ->
  let before = get (A.current ()) in
  let extra = Filename.concat root "future-library.tesl" in
  write extra "module Tesl.FutureLibrary exposing []\n";
  ignore (Compile.agent_context_result_source extra (read extra));
  ignore (refuse (A.verify before));
  Sys.remove extra; get (A.verify before))
let missing_sources () = with_sources (fun root sources ->
  List.iter (fun (name,source) ->
    let file = Filename.concat root name in Sys.remove file;
    let error = refuse (A.current ()) in
    check string "missing required resource is named" name error.path;
    write file source; ignore (get (A.current ()))) sources)
let non_source_data () = with_sources (fun root _ ->
  let before = get (A.current ()) in
  write (Filename.concat root "README.md") "documentation is not a stdlib source";
  check string "non-source resources do not change ABI" (A.id before) (A.id (get (A.current ()))))
let source_views () = with_sources (fun root sources ->
  let name,source = List.hd sources in let file = Filename.concat root name in
  let snapshot = get (A.current ()) in
  Source_input.with_overlays ~project_root:root [file,source ^ "\n# unsaved stdlib\n"] (fun () ->
    ignore (Compile.agent_context_result_source file (Source_input.read file));
    check bool "ABI reflects executing source view" false (A.id snapshot=A.id (get (A.current ())));
    ignore (refuse (A.verify snapshot));
    check string "snapshot does not save the stdlib" source (read file));
  get (A.verify snapshot))
let retained_cache () = with_sources (fun root sources ->
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled false) (fun () ->
    let before = get (A.current ()) in
    let name,source = List.hd sources in let file = Filename.concat root name in
    write file (source ^ "\n# cached session change\n");
    ignore (Compile.agent_context_result_source file (read file));
    ignore (refuse (A.verify before));
    write file source; get (A.verify before)))
let aliases () = with_sources (fun root sources ->
  let name,source = List.hd sources in let file = Filename.concat root name in
  let before = get (A.current ()) in
  let target = Filename.concat root "source-bytes" in
  write target source; Sys.remove file; Unix.symlink target file;
  check string "regular symlink resource has the same bytes" (A.id before) (A.id (get (A.current ())));
  write target (source ^ "\n# changed symlink target\n");
  ignore (refuse (A.verify before)))
let special_file () = with_sources (fun root _ ->
  let file = Filename.concat root "blocked.tesl" in Unix.mkfifo file 0o600;
  let error = refuse (A.current ()) in
  check bool "FIFO is refused without reading" true (Compile.string_contains error.message "regular"))
let missing_directory () = with_directory (fun root ->
  with_env (Filename.concat root "missing") (fun () -> ignore (refuse (A.current ()))))
let build_sources () =
  let repo = match Sys.getenv_opt "TESL_REPO_ROOT" with Some root -> root | None -> fail "TESL_REPO_ROOT missing" in
  let inputs = Migration_build_snapshot.compiler_sources in
  check bool "compiler semantics are bound" true (List.mem_assoc "checker.ml" inputs && List.mem_assoc "emit_go.ml" inputs && List.mem_assoc "proof_checker.ml" inputs);
  check bool "identity computation is itself bound" true (List.mem_assoc "migration_abi.ml" inputs);
  List.iter (fun name -> check bool (name ^ " is documentation only") false (List.mem_assoc name inputs))
    ["embedded_docs.ml";"stdlib_docs.ml";"stdlib_docs_entries.ml"];
  check bool "generated fingerprint cannot hash itself" false (List.mem_assoc "migration_build_snapshot.ml" inputs);
  List.iter (fun (name,digest) ->
    let file = if name="dune-project" then Filename.concat repo "compiler/dune-project"
      else if name="main.ml" then Filename.concat repo "compiler/bin/main.ml"
      else if name="gen_migration_abi.ml" then Filename.concat repo "compiler/gen/gen_migration_abi.ml"
      else if name="lexer.ml" then Filename.concat repo "compiler/_build/default/lib/lexer.ml"
      else Filename.concat repo ("compiler/lib/" ^ name) in
    check string ("built bytes: " ^ name) (Migration_hash.digest (read file)) digest) inputs
let replace a b = Str.global_replace (Str.regexp_string a) b
let with_program f = with_sources (fun root _ ->
  let project = Filename.concat root "application" in Unix.mkdir project 0o700;
  let file = Filename.concat project "snapshot-test.tesl" in
  let source = "module SnapshotTest exposing []\nimport Tesl.Prelude exposing [Int]\nimport Tesl.List exposing [List.length]\nfn size() -> Int = List.length [1, 2]\n" in
  write file source;
  let query () = (Compile.agent_context_result_source file source).ok in
  check bool "baseline uses valid stdlib signature" true (query ());
  let list = Filename.concat root "list.tesl" in
  let original = read list in
  let changed = replace "fn length(xs: List a) -> Int =" "fn length(xs: List a) -> String =" original in
  f root project list original changed query)
let snapshot_rejects_change () = with_program (fun _ _ file _ changed query ->
  let snapshot = get (A.current ()) in
  ignore (refuse (A.with_snapshot snapshot (fun () ->
    write file changed;
    check bool "generation continues against the captured signature" true (query ());
    ignore (refuse (A.verify snapshot));
    42)));
  check bool "outside the snapshot the actual changed signature is visible" false (query ()))
let snapshot_aba () = with_program (fun _ _ file original changed query ->
  let snapshot = get (A.current ()) in
  let result = get (A.with_snapshot snapshot (fun () ->
    write file changed; check bool "temporary source change cannot enter judgment" true (query ());
    write file original; check bool "same immutable source after restoration" true (query ());
    42)) in
  check int "verified consistent generation result" 42 result;
  check bool "ordinary checker restored" true (query ()))
let snapshot_stale () = with_program (fun _ _ file _ changed _ ->
  let snapshot = get (A.current ()) in write file changed;
  let called = ref false in
  ignore (refuse (A.with_snapshot snapshot (fun () -> called:=true)));
  check bool "stale ABI does not begin generation" false !called)
let snapshot_exception () = with_program (fun _ _ file _ changed query ->
  let snapshot = get (A.current ()) in
  let raised = try ignore (A.with_snapshot snapshot (fun () -> write file changed; raise Exit)); false with Exit -> true in
  check bool "callback exception propagated" true raised;
  check bool "resource scope restored after exception" false (query ());
  ignore (refuse (A.verify snapshot)))
let project_view () = with_program (fun _ project _ _ _ query ->
  let snapshot = get (A.current ()) in
  let before = Sys.readdir project |> Array.to_list |> List.sort compare in
  Source_input.with_overlays ~project_root:project [] (fun () ->
    get (A.with_snapshot snapshot (fun () ->
      check (option string) "application root is retained" (Some project) (Source_input.project_root ());
      check (list string) "no virtual resource directories added" before
        (Source_input.readdir project |> Array.to_list |> List.sort compare);
      check bool "stdlib outside application root is pinned" true (query ())))))
let nested_edit_refuses () = with_program (fun root _ file _ changed _ ->
  let snapshot = get (A.current ()) in
  get (A.with_snapshot snapshot (fun () ->
    let refused = try Source_input.with_overlays ~project_root:root [file,changed] (fun () -> ()); false
      with Invalid_argument _ -> true in
    check bool "nested source edit cannot replace pinned compiler semantics" true refused)))
let snapshot_resolution () = with_program (fun root _ file _ changed query ->
  let snapshot = get (A.current ()) in
  ignore (refuse (A.with_snapshot snapshot (fun () ->
    let target = Filename.concat root "new-source" in write target changed;
    Sys.remove file; Unix.symlink target file;
    check bool "captured module resolution survives resource retargeting" true (query ())))))
let nested_abi_refuses () = with_program (fun root _ _ _ changed _ ->
  let snapshot = get (A.current ()) in
  let other = Filename.concat root "other-stdlib" in Unix.mkdir other 0o700;
  populate other (originals ()); write (Filename.concat other "list.tesl") changed;
  get (A.with_snapshot snapshot (fun () ->
    with_env other (fun () ->
      let different = get (A.current ()) in
      check bool "fixture has different semantics identity" false (A.id snapshot=A.id different);
      let called = ref false in
      ignore (refuse (A.with_snapshot different (fun () -> called:=true)));
      check bool "nested generation cannot mix another ABI" false !called))))
let () = run "Compiler migration ABI" ["build and active sources",List.map (fun (name,f) -> test_case name `Quick f)
  ["stable actual identity",stable;"relocated stdlib resources",relocated;"each lifted source changes ABI",changed_source;
   "guarded input hashes",guarded_hashes;"additional source participates",extra_source;"missing required sources refuse",missing_sources;
   "documentation is not a source input",non_source_data;"unsaved stdlib source view",source_views;"retained sessions re-read sources",retained_cache;
   "regular resource symlink semantics",aliases;"FIFO resources refuse",special_file;"missing resource directory",missing_directory;
   "fingerprint matches compiler build inputs",build_sources;
   "generation pins sources and refuses changed resources",snapshot_rejects_change;"ABA changes cannot mix checking inputs",snapshot_aba;
   "stale snapshot never starts",snapshot_stale;"callback exception restores resources",snapshot_exception;
   "resource snapshot preserves application view",project_view;"nested resource edits refuse",nested_edit_refuses;
   "resource resolution remains fixed",snapshot_resolution;"nested different ABI refuses",nested_abi_refuses]]
