open Alcotest

let write path source = Out_channel.with_open_bin path (fun out -> output_string out source)
let with_file f =
  let path = Filename.temp_file "tesl-import-cache-" ".tesl" in
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists path then Sys.remove path;
    Checker.clear_import_parse_cache ()) (fun () -> f path)
let module_name path = match Checker.parse_local_import_module path with
  | Some (Parser.Ok m) -> m.Ast.module_name
  | _ -> fail "expected parsed import"
let source name = "module " ^ name ^ " exposing []\n"

let unchanged () = with_file (fun path ->
  write path (source "First");
  let first = Checker.parse_local_import_module path in
  let second = Checker.parse_local_import_module path in
  check bool "cached AST reused" true (Option.get first == Option.get second))

let same_size_edit () = with_file (fun path ->
  write path (source "First");
  check string "original" "First" (module_name path);
  let stat = Unix.stat path in
  write path (source "Other");
  Unix.utimes path stat.Unix.st_atime stat.Unix.st_mtime;
  check string "same mtime and size edit visible" "Other" (module_name path))

let deletion_recreation () = with_file (fun path ->
  write path (source "First");
  ignore (module_name path);
  Sys.remove path;
  check bool "deleted import absent" true (Checker.parse_local_import_module path = None);
  write path (source "Other");
  check string "recreated import visible" "Other" (module_name path))

let missing_created () = with_file (fun path ->
  Sys.remove path;
  ignore (Checker.parse_local_import_module path);
  write path (source "New");
  check string "newly created import visible" "New" (module_name path))

let broken_repaired () = with_file (fun path ->
  write path "module Broken exposing [";
  check bool "parse error" true (match Checker.parse_local_import_module path with Some (Parser.Err _) -> true | _ -> false);
  write path (source "Fixed");
  check string "repaired import visible" "Fixed" (module_name path))

let bounded () = with_file (fun path ->
  let paths = List.init 300 (fun i -> path ^ string_of_int i ^ ".tesl") in
  Fun.protect ~finally:(fun () -> List.iter (fun path -> if Sys.file_exists path then Sys.remove path) paths) (fun () ->
    List.iteri (fun i path ->
      write path (source ("Module" ^ string_of_int i));
      check string "distinct module visible" ("Module" ^ string_of_int i) (module_name path)) paths;
    check bool "cache bounded" true (Hashtbl.length Checker.import_parse_cache <= 256);
    check string "evicted module still queryable" "Module0" (module_name (List.hd paths))))

let () = run "Import cache revisions" ["snapshot", List.map (fun (name, f) -> test_case name `Quick f)
  ["reuse unchanged AST", unchanged; "same-size edit", same_size_edit;
   "deletion and recreation", deletion_recreation; "missing then created", missing_created;
   "broken then repaired", broken_repaired; "bounded revision churn", bounded]]
