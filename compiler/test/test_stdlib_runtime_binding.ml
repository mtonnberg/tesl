(** Durable seam test: every stdlib name resolves to a real runtime binding.

    Closes the `env-builtins-import-soundness` / stdlib-surface-drift CLASS
    (roadmap/completed/stdlib_binding_existence_seam_test.md).  A stdlib name lives
    in several hand-maintained tables (the {!Type_system.tesl_module_exports}
    import allowlist, {!Type_system.stdlib_env}, the runtime `.rkt` `provide`
    lists); a name present in the checker tables but missing a runtime provide
    TYPE-CHECKS and then crashes at Racket load ("identifier not provided" /
    "cannot open module file") — invisible to the gate unless an example
    happens to import it.  Past instances: emailCap, randomFloat, generateId,
    Dict.delete, newId, mapCheck (all 2026-07-06); `import Tesl.Crypto`
    crash-on-load (2026-07-07, found by writing this test).

    The seam being pinned, mirroring emit_racket.ml [emit_requires]:
      `import M exposing [n]` emits `(only-in <module_path_table[M]> n …)` for
      every expanded name that is not compile-time-only
      ({!Emit_racket.config_only_import_names}), so:
        (1) every module the checker accepts must have a path row, and every
            path row must point to a file that exists;
        (2) every importable name must be `provide`d — VERBATIM, dotted names
            included — by that file at phase 0.
    Tesl.Json is the one deliberate exception: its codec names are lowered
    inline and emit_requires skips the module wholesale (no path row).

    The actual provide set comes from Racket itself (`module->exports`), not a
    grep of `provide` forms, so re-exports (`all-from-out`, `struct-out`, the
    list.rkt→list-prim/list-derived shim chain) are counted correctly.

    Racket absent on PATH → the racket-backed cases SELF-SKIP with an explicit
    line (same convention as ci.sh's optional-dependency phases; the
    authoritative gate always has racket).  The pure-OCaml table/file checks
    always run. *)

open Alcotest

module SS = Set.Make (String)

(* ── Repo root (same walk as test_racket_discover.ml) ─────────────────────── *)

let is_repo_root d =
  Sys.file_exists (Filename.concat d "compile-examples.sh")
  && Sys.file_exists (Filename.concat d "tesl")

let rec up_to_root dir n =
  if n > 12 then None
  else if is_repo_root dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else up_to_root parent (n + 1)

let repo_root =
  let starts =
    [ (try Sys.getenv "TESL_REPO_ROOT" with Not_found -> "");
      Sys.getcwd ();
      (try Filename.dirname (Unix.realpath Sys.executable_name)
       with _ -> Filename.dirname Sys.executable_name) ]
  in
  let rec pick = function
    | [] -> None
    | s :: rest ->
      if s <> "" && is_repo_root s then Some s
      else match up_to_root (if s = "" then Sys.getcwd () else s) 0 with
        | Some d -> Some d
        | None -> pick rest
  in
  match pick starts with
  | Some d -> d
  | None -> failwith "could not locate repo root (compile-examples.sh + tesl/); set TESL_REPO_ROOT"

(* ── The expected surface, derived from the compiler's own tables ─────────── *)

let strip_dotdot s =
  let n = String.length s in
  if n > 4 && String.sub s (n - 4) 4 = "(..)" then String.sub s 0 (n - 4) else s

let config_only = SS.of_list Emit_racket.config_only_import_names

(** Modules whose imports never emit a require (names lowered inline). *)
let inline_modules = [ "Tesl.Json" ]

(** (tesl_module, rkt_path, name) for every name an `import … exposing`
    will bind from a runtime module — the exact set emit_requires requires. *)
let expected_bindings () : (string * string * string) list =
  let of_module m names =
    match Hashtbl.find_opt Emit_racket.module_path_table m with
    | None -> []  (* separately reported by the path-row test *)
    | Some path ->
      Emit_racket.expand_import_names (List.map strip_dotdot names)
      |> List.filter (fun n -> not (SS.mem n config_only))
      |> List.map (fun n -> (m, path, n))
  in
  let export_rows =
    Type_system.tesl_module_exports
    |> List.filter (fun (m, _) -> not (List.mem m inline_modules))
    |> List.concat_map (fun (m, names) -> of_module m names)
  in
  (* Bare gated names whose home module has no export list (Tesl.Telemetry,
     Tesl.Agent, Tesl.Queue, Tesl.Id): `import M exposing [n]` requires n the
     same way, so they need the same runtime provide. *)
  let bare_rows =
    Type_system.stdlib_bare_home_module
    |> List.concat_map (fun (n, m) ->
         if List.mem m inline_modules then [] else of_module m [n])
  in
  List.sort_uniq compare (export_rows @ bare_rows)

(* ── OCaml-only checks: path rows exist, files exist ──────────────────────── *)

let test_every_export_module_has_path_row () =
  let missing =
    Type_system.tesl_module_exports
    |> List.filter_map (fun (m, _) ->
         if List.mem m inline_modules then None
         else if Hashtbl.mem Emit_racket.module_path_table m then None
         else Some m)
  in
  if missing <> [] then
    fail (Printf.sprintf
      "Modules with an export list in tesl_module_exports but NO row in \
       emit_racket.ml module_path_table (their imports would emit a garbage \
       local require):\n  %s"
      (String.concat "\n  " missing))

let test_every_known_module_has_path_row () =
  let missing =
    Type_system.tesl_known_module_names
    |> List.filter (fun m ->
         not (List.mem m inline_modules)
         && not (Hashtbl.mem Emit_racket.module_path_table m))
  in
  if missing <> [] then
    fail (Printf.sprintf
      "Modules in tesl_known_module_names (importable) but NO row in \
       module_path_table:\n  %s"
      (String.concat "\n  " missing))

let test_every_path_row_file_exists () =
  let missing =
    Hashtbl.fold (fun m path acc ->
      let full = Filename.concat repo_root path in
      if Sys.file_exists full then acc
      else Printf.sprintf "%s -> %s" m path :: acc
    ) Emit_racket.module_path_table []
    |> List.sort_uniq String.compare
  in
  if missing <> [] then
    fail (Printf.sprintf
      "module_path_table rows whose runtime .rkt file does NOT exist \
       (`import M` typechecks then crashes at Racket load with \"cannot open \
       module file\" — the 2026-07-07 Tesl.Crypto bug):\n  %s"
      (String.concat "\n  " missing))

(* ── Racket-backed check: importable names ⊆ real phase-0 provides ────────── *)

let racket_available () = Sys.command "racket -e '(void)' >/dev/null 2>&1" = 0

let dump_script = {racket|#lang racket/base
;; usage: racket <script> <rkt-path> ...
;; prints "<path>\t<name>" for every phase-0 export (variables AND syntax)
(for ([p (in-vector (current-command-line-arguments))])
  (define mp `(file ,(path->string (path->complete-path p))))
  (dynamic-require mp (void)) ; declare (compile) without instantiating
  (define-values (vals stxs) (module->exports mp))
  (for* ([tbl (in-list (list vals stxs))]
         [ph (in-list tbl)]
         #:when (equal? (car ph) 0)
         [exp (in-list (cdr ph))])
    (printf "~a\t~a\n" p (car exp))))
|racket}

(** path (repo-relative) → set of phase-0 provided names, via module->exports. *)
let real_provides (paths : string list) : (string, SS.t) Hashtbl.t =
  let script = Filename.temp_file "tesl-dump-provides" ".rkt" in
  Out_channel.with_open_text script (fun oc -> output_string oc dump_script);
  let cmd =
    String.concat " "
      ("racket" :: Filename.quote script
       :: List.map (fun p -> Filename.quote (Filename.concat repo_root p)) paths)
  in
  let ic = Unix.open_process_in cmd in
  let table : (string, SS.t) Hashtbl.t = Hashtbl.create 64 in
  (try
     while true do
       let line = input_line ic in
       match String.index_opt line '\t' with
       | None -> ()
       | Some i ->
         let abs = String.sub line 0 i in
         let name = String.sub line (i + 1) (String.length line - i - 1) in
         (* map absolute path back to the repo-relative path we asked about *)
         let rel =
           let prefix = repo_root ^ "/" in
           let pl = String.length prefix in
           if String.length abs > pl && String.sub abs 0 pl = prefix
           then String.sub abs pl (String.length abs - pl)
           else abs
         in
         let cur = Option.value (Hashtbl.find_opt table rel) ~default:SS.empty in
         Hashtbl.replace table rel (SS.add name cur)
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  Sys.remove script;
  (match status with
   | Unix.WEXITED 0 -> ()
   | _ ->
     fail "racket module->exports dump failed — a stdlib .rkt does not even \
           compile (run the printed command by hand to see the load error)");
  table

let test_every_importable_name_is_provided () =
  if not (racket_available ()) then
    print_endline
      "SKIP - racket not on PATH; provide-existence check self-skips \
       (the authoritative gate ./ci.sh runs with racket available)"
  else begin
    let expected = expected_bindings () in
    let paths =
      expected |> List.map (fun (_, p, _) -> p) |> List.sort_uniq String.compare
    in
    let provides = real_provides paths in
    (* sanity: the dump parsed — an empty provide set for a real module means
       the parser or script regressed, not that the module provides nothing *)
    List.iter (fun p ->
      match Hashtbl.find_opt provides p with
      | Some s when not (SS.is_empty s) -> ()
      | _ -> fail (Printf.sprintf
          "module->exports dump returned NO provides for %s — dump script or \
           parse regressed" p)
    ) paths;
    let missing =
      List.filter_map (fun (m, path, name) ->
        let have = Option.value (Hashtbl.find_opt provides path) ~default:SS.empty in
        if SS.mem name have then None
        else Some (Printf.sprintf "%-14s %-22s %s" m path name)
      ) expected
    in
    if missing <> [] then
      fail (Printf.sprintf
        "%d importable stdlib name(s) with NO runtime provide — importing them \
         typechecks, then the generated Racket fails to load (the Dict.delete \
         / emailCap bug class).  Fix: add the provide to the .rkt, or if the \
         name is compile-time-only add it to \
         Emit_racket.config_only_import_names.\n  MODULE         PATH                   NAME\n  %s"
        (List.length missing) (String.concat "\n  " missing))
  end

(* ── Test runner ──────────────────────────────────────────────────────────── *)

let () =
  run "Stdlib-Runtime-Binding" [
    "module-files", [
      test_case "every exported module has a module_path_table row" `Quick
        test_every_export_module_has_path_row;
      test_case "every known (importable) module has a module_path_table row" `Quick
        test_every_known_module_has_path_row;
      test_case "every module_path_table .rkt file exists on disk" `Quick
        test_every_path_row_file_exists;
    ];
    "provide-existence", [
      test_case "every importable stdlib name has a real phase-0 provide" `Quick
        test_every_importable_name_is_provided;
    ];
  ]
