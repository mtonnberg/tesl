(** Loaded separately, on first search: the documentation catalog never makes
    the checker or ordinary editor startup heavier. Semantics are native OCaml. *)
open Js_of_ocaml

let () =
  Js.Unsafe.set Js.Unsafe.global "teslSearch"
    (Js.wrap_callback (fun query -> Js.string (Builtin_search.search_json (Js.to_string query))));
  Js.Unsafe.set Js.Unsafe.global "teslCatalog"
    (Js.wrap_callback (fun () -> Js.string (Builtin_search.catalog_json ())))
