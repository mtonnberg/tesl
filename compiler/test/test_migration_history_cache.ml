(* Compilation-scoped reuse of frozen migration-history analysis must be
   invisible: a cached compile emits exactly the bytes and diagnostics of an
   uncached one, and any change to a key input (frozen revision bytes, stdlib
   bytes, ABI label) recomputes, including a now-failing result. *)
open Alcotest

let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let read p = In_channel.with_open_bin p In_channel.input_all
let write p s = Out_channel.with_open_bin p (fun out -> output_string out s)
let repo_root () = Validation_common.stdlib_repo_root ()
let copy_tree src dst =
  if Sys.command (Filename.quote_command "cp" ["-R"; src; dst]) <> 0 then fail ("copy " ^ src)

let with_temp f =
  let root = Filename.temp_file "tesl-history-cache-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

(* The 13-revision example, copied so tampering never touches the checkout. *)
let with_example f = with_temp (fun root ->
  let project = Filename.concat root "example" in
  copy_tree (Filename.concat (repo_root ()) "example/db-migration-example") project;
  f project)

let with_cache enabled f =
  let previous = Sys.getenv_opt "TESL_HISTORY_CACHE" in
  Unix.putenv "TESL_HISTORY_CACHE" (if enabled then "1" else "0");
  Fun.protect ~finally:(fun () -> Unix.putenv "TESL_HISTORY_CACHE" (Option.value previous ~default:"1")) f

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:"")) f

let render_artifacts = function
  | Compile.GoSuccess xs ->
    "ok\n" ^ String.concat "" (List.map (fun (a:Emit_go.artifact) ->
      Printf.sprintf "== %s %d\n%s\n" a.path (String.length a.contents) a.contents) xs)
  | Compile.GoFailure ds ->
    "failed\n" ^ String.concat "\n" (List.map (fun (d:Compile.diagnostic) ->
      Printf.sprintf "%s:%d:%d %s %s" d.file d.start_line d.start_col d.code d.message) ds)
let render_diags ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) ->
  Printf.sprintf "%s:%d:%d %s %s %s" d.file d.start_line d.start_col d.severity d.code d.message) ds)

let emit file = Compile.compile_go_source ~path:file file (read file)
let check_file file =
  let source = read file in
  match Parser.parse_module file source with
  | Parser.Ok m -> Compile.check_module source m
  | Parser.Err e -> fail e.msg
let errors ds = List.filter (fun (d:Compile.diagnostic) -> d.severity="error") ds

let plan_hits () = (Migration_contract.plan_cache_stats ()).hits
let plan_misses () = (Migration_contract.plan_cache_stats ()).misses

let warm_emit_is_cold_emit () = with_example (fun project ->
  let app = Filename.concat project "todo-app.tesl" in
  let cold = with_cache false (fun () -> render_artifacts (emit app)) in
  let hits = plan_hits () in
  let warm = with_cache true (fun () -> render_artifacts (emit app)) in
  check bool "cached emission reused the checked plan" true (plan_hits () > hits);
  check bool "the example emits" true (String.starts_with ~prefix:"ok\n" cold);
  check string "cached emission is byte-identical" cold warm;
  let again = with_cache true (fun () -> render_artifacts (emit app)) in
  check string "a second cached emission is byte-identical" cold again)

let warm_check_is_cold_check () = with_example (fun project ->
  let files = ["todo-app.tesl"; "migrations/todo/v10-contract.tesl"; "migrations/todo/v13.tesl";
    "migrations/todo/v12-contract.tesl"] in
  List.iter (fun name ->
    let file = Filename.concat project name in
    let cold = with_cache false (fun () -> render_diags (check_file file)) in
    let warm = with_cache true (fun () -> render_diags (check_file file)) in
    check string ("cached diagnostics for " ^ name) cold warm) files)

(* Inside ONE compilation scope (the widest reuse), warm the plan, then change a
   frozen revision byte. The hit guard must refuse the entry and the integrity
   failure must surface exactly as an uncached check reports it. *)
let contract_diags project =
  let file = Filename.concat project "migrations/todo/v12-contract.tesl" in
  let source = read file in
  match Parser.parse_module file source with
  | Parser.Ok m -> Migration_contract.diagnostics source m
  | Parser.Err e -> fail e.msg

let tamper_frozen_revision name edit () = with_example (fun project ->
  with_cache true (fun () ->
    Migration_program.with_compilation_cache (fun () ->
      check string "clean history checks" "" (render_diags (errors (contract_diags project)));
      let misses = plan_misses () in
      ignore (contract_diags project);
      check int "unchanged history is a hit" misses (plan_misses ());
      let file = Filename.concat project name in
      write file (edit (read file));
      let warm = render_diags (contract_diags project) in
      check bool "tampered revision is a miss" true (plan_misses () > misses);
      check bool ("tampered " ^ name ^ " is rejected with a warm cache") true (warm <> "");
      let cold = with_cache false (fun () -> render_diags (contract_diags project)) in
      check string "warm rejection equals the uncached rejection" cold warm)))

let append_comment source = source ^ "\n# tampered\n"
let flip_byte source =
  let marker = "module " in
  let i = Str.search_forward (Str.regexp_string marker) source 0 + String.length marker in
  String.mapi (fun j c -> if j = i then Char.lowercase_ascii c else c) source

let tamper_full_emit () = with_example (fun project ->
  let app = Filename.concat project "todo-app.tesl" in
  ignore (with_cache true (fun () -> emit app));
  let file = Filename.concat project "schema/todo/v6.tesl" in
  write file (append_comment (read file));
  let warm = with_cache true (fun () -> render_artifacts (emit app)) in
  let cold = with_cache false (fun () -> render_artifacts (emit app)) in
  check bool "tampered frozen schema fails emission" true (String.starts_with ~prefix:"failed\n" warm);
  check bool "the integrity diagnostic fires" true (Compile.string_contains warm "MIG013");
  check string "warm failure equals cold failure" cold warm)

(* Stdlib bytes are part of the actual compiler ABI in the key. *)
let stdlib_change_is_a_miss () = with_example (fun project ->
  with_temp (fun stdlib_root ->
    let stdlib = Filename.concat stdlib_root "tesl" in
    let source = List.find Sys.file_exists (List.map (fun d -> d)
      (Validation_common.stdlib_source_directories ())) in
    copy_tree source stdlib;
    with_env "TESL_STDLIB_DIR" stdlib (fun () ->
      with_cache true (fun () ->
        Migration_program.with_compilation_cache (fun () ->
          let before = render_diags (contract_diags project) in
          let misses = plan_misses () in
          ignore (contract_diags project);
          check int "same stdlib is a hit" misses (plan_misses ());
          let file = Filename.concat stdlib "list.tesl" in
          write file (append_comment (read file));
          let after = render_diags (contract_diags project) in
          check bool "changed stdlib bytes are a miss" true (plan_misses () > misses);
          let cold = with_cache false (fun () -> render_diags (contract_diags project)) in
          check string "recomputed result equals the uncached result" cold after;
          ignore before)))))

(* The caller's ABI label is part of the key. *)
let abi_label_is_a_miss () = with_example (fun project ->
  let file = Filename.concat project "migrations/todo/v12-contract.tesl" in
  let source = read file in
  let m = match Parser.parse_module file source with Parser.Ok m -> m | Parser.Err e -> fail e.msg in
  let run abi = match Migration_contract.check_module ~compiler_abi:abi ~source m with
    | Ok (Some c) -> Migration_contract.digest c
    | Ok None -> fail "contract expected"
    | Error es -> String.concat "\n" (List.map (fun (e:Migration_sparse.error) -> e.code ^ e.message) es) in
  with_cache true (fun () -> Migration_program.with_compilation_cache (fun () ->
    let real = Migration_abi.id (Result.get_ok (Migration_abi.current ())) in
    let a = run real in
    let misses = plan_misses () in
    ignore (run real);
    check int "same label is a hit" misses (plan_misses ());
    let b = run "compiler-local-unsealed-comparison" in
    check bool "another ABI label is a miss" true (plan_misses () > misses);
    let cold_b = with_cache false (fun () -> run "compiler-local-unsealed-comparison") in
    check string "recomputed result equals the uncached result" cold_b b;
    check bool "the real ABI checks the contract" false (String.starts_with ~prefix:"MIG" a);
    ignore b))
  ;
  (* Fully outside any compilation scope: no reuse of any kind. *)
  let real = Migration_abi.id (Result.get_ok (Migration_abi.current ())) in
  let fresh label = with_cache false (fun () -> run label) in
  let warm label = with_cache true (fun () -> Migration_program.with_compilation_cache (fun () ->
    ignore (run real); run label)) in
  check string "label switch inside a warm scope equals a fresh check"
    (fresh "compiler-local-unsealed-comparison") (warm "compiler-local-unsealed-comparison"))

let () = run "Migration history analysis cache" [
  "identity", [
    test_case "warm emission equals cold emission (13 revisions)" `Slow warm_emit_is_cold_emit;
    test_case "warm diagnostics equal cold diagnostics" `Slow warm_check_is_cold_check;
  ];
  "invalidation", [
    test_case "frozen schema byte" `Slow (tamper_frozen_revision "schema/todo/v4.tesl" append_comment);
    test_case "frozen migration byte" `Slow (tamper_frozen_revision "migrations/todo/v5.tesl" flip_byte);
    test_case "frozen schema byte fails a warm emission" `Slow tamper_full_emit;
    test_case "stdlib byte" `Slow stdlib_change_is_a_miss;
    test_case "ABI label" `Slow abi_label_is_a_miss;
  ]]
