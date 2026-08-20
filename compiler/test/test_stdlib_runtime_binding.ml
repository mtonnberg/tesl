(** Go stdlib surface seam.

    The old backend-specific provide/path test is replaced by compiler-owned
    checks. Runtime export coverage is exercised by [test_go_stdlib_export_seam];
    this test keeps the source-of-truth module inventory internally consistent.
*)

open Alcotest

module SS = Set.Make (String)

let test_module_exports_are_unique () =
  List.iter (fun (module_name, exports) ->
    let unique = SS.of_list exports in
    check int module_name (List.length exports) (SS.cardinal unique);
    check bool (module_name ^ " has exports") true (exports <> []))
    Type_system.tesl_module_exports

let test_known_modules_are_exported () =
  let exported =
    Type_system.tesl_module_exports
    |> List.map fst
    |> SS.of_list
  in
  List.iter (fun module_name ->
    check bool (module_name ^ " is exported") true (SS.mem module_name exported))
    Type_system.tesl_known_module_names

let () =
  run "Go-Stdlib-Surface" [
    "inventory", [
      test_case "exports are unique and non-empty" `Quick test_module_exports_are_unique;
      test_case "known modules have export inventories" `Quick test_known_modules_are_exported;
    ];
  ]
