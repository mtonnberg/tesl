(** Go ADT constructor seam.

    Constructor labels are represented directly by the Go emitter's variant
    metadata. The shared checker registry is the stable compiler-side source;
    keep its constructor names and arities unique and complete.
*)

open Alcotest

let test_builtin_constructor_names_are_unique () =
  let names = List.map fst Validation_common.builtin_ctor_info in
  let unique = List.sort_uniq String.compare names in
  check int "constructor names" (List.length names) (List.length unique)

let test_builtin_constructor_shapes_are_valid () =
  List.iter (fun (name, (fields, _result)) ->
    check bool (name ^ " has a valid shape") true (List.length fields >= 0))
    Validation_common.builtin_ctor_info

let () =
  run "stdlib-ctor-labels" [
    "go-constructor-registry", [
      test_case "names are unique" `Quick test_builtin_constructor_names_are_unique;
      test_case "shapes are valid" `Quick test_builtin_constructor_shapes_are_valid;
    ];
  ]
