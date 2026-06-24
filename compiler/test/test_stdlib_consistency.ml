(** Stdlib data-structure consistency tests.

    These tests guard against the class of bugs where a new stdlib function or
    ADT is added to one table but the parallel tables are not updated.  A
    failure here means a developer has extended the stdlib somewhere but
    forgotten to update a dependent table.

    Tables that must stay in sync:

      type_system.ml  │  tesl_module_exports        – canonical export lists
                      │  stdlib_env                 – type-checker environment
      checker.ml      │  stdlib_module_of_prefix    – prefix → Tesl.X mapping
                      │                               needed by check_stdlib_fn_import_scope
      validation.ml   │  stdlib_adt_ctors           – ADT constructor sets
                      │                               needed by imported_plain_exposed_ctor_entries
      emit_racket.ml  │  module_path_table          – Racket file paths
                      │  adt_constructors           – ADT expansion for require generation

    When you add a new stdlib function:
      1. Add it to stdlib_env in type_system.ml
      2. Add it to tesl_module_exports in type_system.ml
      3. If its module prefix is new, add it to stdlib_module_of_prefix in checker.ml

    When you add a new stdlib ADT:
      1. Add its constructors to stdlib_adt_ctors in validation.ml
      2. Add it to adt_constructors in emit_racket.ml
      3. Ensure its module is in tesl_module_exports

    When you add a new stdlib module:
      1. Add it to module_path_table in emit_racket.ml
      2. Add it to tesl_known_module_names in type_system.ml
      3. If it exports qualified names (Module.func style), add its prefix to
         stdlib_module_of_prefix in checker.ml  *)

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let has_dotdot s =
  let n = String.length s in
  n > 4 && String.sub s (n - 4) 4 = "(..)"

let strip_dotdot s =
  if has_dotdot s then String.sub s 0 (String.length s - 4) else s

let qualified_prefix name =
  match String.index_opt name '.' with
  | Some i -> Some (String.sub name 0 i)
  | None -> None

(** All distinct module prefixes from qualified exports in tesl_module_exports.
    E.g. "List.head" → "List", "Dict.lookup" → "Dict", "Tuple2.first" → "Tuple2". *)
let all_export_prefixes () =
  Type_system.tesl_module_exports
  |> List.concat_map snd
  |> List.filter_map qualified_prefix
  |> List.sort_uniq String.compare

(** All module prefixes registered in checker's stdlib_module_of_prefix. *)
let registered_prefixes () =
  List.map fst Checker.stdlib_module_of_prefix
  |> List.sort_uniq String.compare

(* ── Test: every qualified export prefix is registered ──────────────────── *)

let test_every_export_prefix_is_registered () =
  let covered = registered_prefixes () in
  let missing =
    all_export_prefixes ()
    |> List.filter (fun prefix -> not (List.mem prefix covered))
  in
  if missing <> [] then
    fail (Printf.sprintf
      "Qualified exports in tesl_module_exports have module prefixes that are \
       not in stdlib_module_of_prefix in checker.ml.  Add entries for: %s\n\
       See check_stdlib_fn_import_scope in checker.ml."
      (String.concat ", " (List.map (fun p -> Printf.sprintf {|("%s", "Tesl.X")|} p) missing)))

(* ── Test: every registered prefix maps to a known Tesl module ──────────── *)

let test_every_registered_prefix_maps_to_known_module () =
  let known = Type_system.tesl_known_module_names in
  List.iter (fun (prefix, tesl_module) ->
    if not (List.mem tesl_module known) then
      fail (Printf.sprintf
        "stdlib_module_of_prefix in checker.ml maps prefix %S to %S, \
         but %S is not in tesl_known_module_names in type_system.ml."
        prefix tesl_module tesl_module)
  ) Checker.stdlib_module_of_prefix

(* ── Test: stdlib_adt_ctors is consistent with tesl_module_exports ────────── *)

let test_stdlib_adt_ctors_consistent_with_exports () =
  List.iter (fun (module_name, (type_name, ctors)) ->
    (* The module must appear in tesl_module_exports *)
    match List.assoc_opt module_name Type_system.tesl_module_exports with
    | None ->
      fail (Printf.sprintf
        "validation.ml stdlib_adt_ctors references module %S, \
         but that module has no entry in type_system.ml tesl_module_exports. \
         Add it there (or move to the internal-modules comment)."
        module_name)
    | Some exports ->
      (* The type name itself must be an export *)
      if not (List.mem type_name exports) then
        fail (Printf.sprintf
          "validation.ml stdlib_adt_ctors: type %S from %S is not listed in \
           tesl_module_exports[%S].  Add %S to the export list."
          type_name module_name module_name type_name);
      (* Every listed constructor must also be an export *)
      List.iter (fun ctor ->
        if not (List.mem ctor exports) then
          fail (Printf.sprintf
            "validation.ml stdlib_adt_ctors: constructor %S of %S.%S is not in \
             tesl_module_exports[%S].  Add %S to the export list, or remove it \
             from stdlib_adt_ctors."
            ctor module_name type_name module_name ctor)
      ) ctors
  ) Validation.stdlib_adt_ctors

(* ── Test: every stdlib function in stdlib_env with a qualified name is in
         tesl_module_exports ──────────────────────────────────────────────── *)

let test_every_stdlib_env_fn_is_in_exports () =
  let all_exports =
    Type_system.tesl_module_exports
    |> List.concat_map snd
    |> List.map strip_dotdot
  in
  let missing =
    Type_system.make_stdlib_env ()
    |> List.filter_map (fun (name, _) ->
         if String.contains name '.' then
           (* Only check if the prefix is a known stdlib module prefix *)
           (match qualified_prefix name with
            | Some prefix
              when List.mem_assoc prefix Checker.stdlib_module_of_prefix ->
                if not (List.mem name all_exports) then Some name
                else None
            | _ -> None)
         else None)
    |> List.sort_uniq String.compare
  in
  if missing <> [] then
    fail (Printf.sprintf
      "The following qualified functions are in stdlib_env in type_system.ml \
       but are not listed in tesl_module_exports.  Add them to the export list \
       so they can be validated by check_stdlib_fn_import_scope:\n  %s"
      (String.concat "\n  " missing))

(* ── Test: emit_racket adt_constructors is a subset of stdlib_adt_ctors ──── *)

let test_adt_constructors_subset_of_stdlib_adt_ctors () =
  (* emit_racket.adt_constructors maps ADT type names to their constructors.
     validation.stdlib_adt_ctors maps Tesl modules to (type_name, ctors).
     Every type in adt_constructors that belongs to a known Tesl stdlib ADT module
     should appear in stdlib_adt_ctors so conflicts are caught at compile time. *)
  let adt_ctors_type_names =
    Validation.stdlib_adt_ctors
    |> List.map (fun (_, (type_name, _)) -> type_name)
  in
  Hashtbl.iter (fun type_name _ctors ->
    (* Only care about names that are in tesl_module_exports somewhere *)
    let in_exports = Type_system.tesl_module_exports
      |> List.exists (fun (_, exports) -> List.mem type_name exports)
    in
    if in_exports && not (List.mem type_name adt_ctors_type_names) then
      fail (Printf.sprintf
        "emit_racket.ml adt_constructors has entry for ADT type %S which appears \
         in tesl_module_exports, but validation.ml stdlib_adt_ctors does not have \
         an entry for it.  Add it to stdlib_adt_ctors so local constructor \
         conflicts are detected at compile time."
        type_name)
  ) Emit_racket.adt_constructors

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Stdlib-Consistency" [
    "prefix-coverage", [
      test_case "every qualified export prefix is in stdlib_module_of_prefix" `Quick
        test_every_export_prefix_is_registered;
      test_case "every registered prefix maps to a known Tesl module" `Quick
        test_every_registered_prefix_maps_to_known_module;
    ];
    "adt-coverage", [
      test_case "stdlib_adt_ctors entries are consistent with tesl_module_exports" `Quick
        test_stdlib_adt_ctors_consistent_with_exports;
      test_case "emit_racket adt_constructors ADTs are covered by stdlib_adt_ctors" `Quick
        test_adt_constructors_subset_of_stdlib_adt_ctors;
    ];
    "env-coverage", [
      test_case "every qualified stdlib_env entry appears in tesl_module_exports" `Quick
        test_every_stdlib_env_fn_is_in_exports;
    ];
  ]
