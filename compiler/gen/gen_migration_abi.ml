(** Fingerprint the actual build inputs supplied by Dune, never a Git revision
    or a mutable source checkout looked up after the compiler has been built.
    Documentation snapshots cannot affect language semantics and are excluded.
    The runtime implementation and selected lifted stdlib are composed at use. *)
let documentation = ["embedded_docs.ml";"stdlib_docs.ml";"stdlib_docs_entries.ml"]
let () =
  let files = Array.to_list Sys.argv |> List.tl |> List.filter (fun path ->
    not (List.mem (Filename.basename path) documentation)) in
  let inputs = List.map (fun path ->
    Filename.basename path,Migration_hash.digest (In_channel.with_open_bin path In_channel.input_all)) files
    |> List.sort compare in
  if List.map fst inputs <> List.sort_uniq String.compare (List.map fst inputs) then
    failwith "duplicate compiler ABI input names";
  if not (List.mem_assoc "checker.ml" inputs && List.mem_assoc "emit_go.ml" inputs && List.mem_assoc "lexer.ml" inputs) then
    failwith "incomplete compiler ABI source dependencies";
  List.iter (fun name -> if not (List.mem_assoc name inputs) then
    failwith ("incomplete staged-index ABI dependency: " ^ name))
    ["ast.ml";"parser.ml";"validation_structural.ml";"migration_ir.ml";
     "migration_inventory.ml";"migration_inventory.mli";"migration_storage.ml";
     "migration_sparse.ml";"migration_row_history.ml";"migration_expansion.ml";"migration_schema.ml"];
  print_endline "(** Generated from Dune build dependencies; no source checkout is required at runtime. *)";
  Printf.printf "let ocaml_version = %S\n" Sys.ocaml_version;
  print_endline "let compiler_sources = [";
  List.iter (fun (name,digest) -> Printf.printf "  (%S,%S);\n" name digest) inputs;
  print_endline "]"
