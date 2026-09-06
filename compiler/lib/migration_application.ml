(** A database's declared history is a checking dependency even when the app has
    no ordinary import of its migration modules. These checks introduce no names
    into the application and do not authorize execution or persisted proofs. *)
open Ast
module F = Frontend_check
module H = Migration_history_sources
module D = Migration_declaration
module Header = Migration_header
(* Comparison under the running frontend only; this does not identify a build
   or attest compatibility with any persisted execution ABI. *)
let comparison_abi = "compiler-local-unsealed-comparison"
let failure code loc message related = D.diagnostics_of_errors
  [{Migration_sparse.code;loc;message;related}]
let roots (m : module_form) = List.filter_map (function
  | DDatabase d ->
    let fields = match d.config_expr with None -> [] | Some e -> Desugar.config_record_fields e in
    (match List.assoc_opt "schema" fields,List.assoc_opt "migrations" fields with
     | Some (EConstructor {name=root;args=[];_}),Some (EConstructor {name=prefix;args=[];_}) ->
       (match Validation_common.schema_module_parts root with
        | Some (family,"VCurrent",[]) when Migration_source.valid_family family && prefix=family ^ ".Migrate" &&
            List.exists (fun (i : import_decl) -> i.module_name=root) m.imports -> Some (d,root,family)
        | _ -> None)
     | _ -> None)
  | _ -> None) m.decls
let make ?(skip_dep_body=fun _ -> false) (entry : module_form) =
  let explicit = lazy (
    let graph = F.build_local_import_graph ~entry entry.source_file in
    Hashtbl.fold (fun path _ paths -> path :: paths) graph []) in
  let families = Hashtbl.create 4 and checked = Hashtbl.create 16 in
  let skip path = skip_dep_body path || List.mem path (Lazy.force explicit) || Hashtbl.mem checked path in
  let check_declaration source (m : module_form) =
    Hashtbl.replace checked (F.canonical_import_path m.source_file) ();
    D.diagnostics source m in
  let check_history (m : module_form) (d : database_form) root family =
    let current_file = Validation_common.resolve_local_import_path m.source_file root in
    let project_root = Filename.dirname (Filename.dirname (Filename.dirname current_file)) in
    let key = project_root,family in
    if Hashtbl.mem families key then [] else begin
      Hashtbl.add families key ();
      match H.discover ~compiler_abi:comparison_abi ~project_root ~family with
      | Error error -> failure "MIG020" error.loc error.message [d.loc,"database declaring this migration history"]
      | Ok history ->
        let current = H.current history in
        let modules = List.filter_map (fun path -> if path=F.canonical_import_path entry.source_file then Some entry else F.parse_module_file path) (Lazy.force explicit) in
        let queue_diags = D.diagnostics_of_errors (Migration_queue.application_bindings
          ~modules ~database_module:m ~database:d current.inventory) in
        let missing = if current.version > 1 && H.current_migration history = None then
          failure "MIG001" d.loc
            (Printf.sprintf "database `%s` requires its current %s.Migrate.V%d migration before the application can compile"
              d.name family current.version) [Location.dummy_loc current.root_file,"current schema"]
          else [] in
        let edges = H.completed_migrations history @ Option.to_list (H.current_migration history) in
        let queue_history_diags = if Migration_inventory.queue_contracts current.inventory=[] then [] else
          List.concat_map (fun (edge:H.migration_source) ->
            match Header.read ~file:edge.path edge.contents with
            | Ok (Some header) ->
              let previous,target = Header.recorded_seals header in
              if Migration_seal.queue_inventory_complete previous && Migration_seal.queue_inventory_complete target then []
              else failure "MIG028" (Location.dummy_loc edge.path)
                "this queue-bearing application has legacy history with an unknown payload inventory; a later empty snapshot cannot establish absence in earlier deployed revisions" []
            | _ -> []) edges in
        queue_diags @ queue_history_diags @ missing @ List.concat_map (fun (edge : H.migration_source) ->
          let seals = match Header.read ~file:edge.path edge.contents with
            | Error errors -> D.diagnostics_of_errors errors
            | Ok None -> failure "MIG013" (Location.dummy_loc edge.path)
                "an application migration requires both recorded schema source seals; generate the undeployed revision before building"
                [d.loc,"database declaring this migration history"]
            | Ok (Some _) -> [] in
          if skip edge.path then seals else begin
            Hashtbl.add checked edge.path ();
            match Parser.parse_module edge.path edge.contents with
            | Err error -> seals @ [F.diag_of_parse_error error]
            | Ok migration ->
              seals @ F.check_module ~additional:check_declaration ~skip_dep_body:skip edge.contents migration
          end) edges
    end in
  fun source (m : module_form) ->
    let aliases = Units_catalog.snapshot_active_aliases () in
    let money = !(Units_catalog.money_rate_aliases_active) in
    Fun.protect ~finally:(fun () ->
      Units_catalog.set_active_aliases aliases; Units_catalog.money_rate_aliases_active := money)
      (fun () -> D.diagnostics source m @
        List.concat_map (fun (d,root,family) -> check_history m d root family) (roots m))
