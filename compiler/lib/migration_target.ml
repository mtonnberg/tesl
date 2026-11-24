include Migration_selection
module M = Migration_manifest
module G = Migration_generate
let generated result = Result.map_error (List.map (fun (e:G.error) ->
 {loc=Location.dummy_loc e.path;message=e.message;candidates=[]})) result
let manifest result = Result.map_error (List.map (fun (e:M.error) ->
 {loc=Location.dummy_loc e.path;message=e.message;candidates=[]})) result
(* The selected connection's static PostgreSQL namespace: the records Start
   stores in a checkpoint are computed for it. *)
let namespace t =
 let s = selection t in
 let static config = match List.assoc_opt "namespace" (Desugar.config_record_fields config) with
  | Some (Ast.ELit {lit=Ast.LString name;_}) -> Some name | _ -> None in
 match Parser.parse_module s.database_file (Source_input.read s.database_file) with
 | Parser.Ok m -> List.find_map (function
   | Ast.DDatabase d when d.name=s.database_name || m.module_name ^ "." ^ d.name=s.database_name ->
     Option.bind d.config_expr (fun config ->
       match List.assoc_opt "backend" (Desugar.config_record_fields config) with
       | Some backend -> (match Migration_form.application backend with
         | "Postgres",[config] -> static config
         | _ -> None)
       | None -> None)
   | _ -> None) m.decls
 | Parser.Err _ -> None
 | exception (Sys_error _ | Unix.Unix_error _) -> None
let start t ~documents =
 Result.bind (verify t ~documents) (fun () ->
  Result.bind (generated (Emit_fragment.with_entry (selection t).entry_file @@ fun () -> G.start_scoped ~flat_history:(flat_history t) ~namespace:(namespace t) ~stored_value_compatibility:(stored_value_compatibility t)
    ~compiler_abi:(compiler_abi t) ~project_root:(project_root t)
    ~family:(selection t).family ~version:(selection t).current_version ~documents)) (fun preview ->
   Result.map (fun source_manifest -> {preview with G.manifest=source_manifest})
    (manifest (M.combine (source_guard t) preview.manifest ~documents))))
let refresh t ~documents =
 Result.bind (verify t ~documents) (fun () ->
  Result.bind (generated (G.refresh_scoped ~flat_history:(flat_history t) ~choice:None ~stored_value_compatibility:(stored_value_compatibility t)
    ~compiler_abi:(compiler_abi t) ~project_root:(project_root t)
    ~family:(selection t).family ~version:(selection t).current_version ~documents)) (fun preview ->
   Result.map (fun source_manifest -> {preview with G.manifest=source_manifest})
    (manifest (M.combine (source_guard t) preview.manifest ~documents))))
let refresh_choice t ~choice ~documents =
 Result.bind (verify t ~documents) (fun () ->
  Result.bind (generated (G.refresh_scoped ~flat_history:(flat_history t) ~choice:(Some choice) ~stored_value_compatibility:(stored_value_compatibility t)
    ~compiler_abi:(compiler_abi t) ~project_root:(project_root t)
    ~family:(selection t).family ~version:(selection t).current_version ~documents)) (fun preview ->
   Result.map (fun source_manifest -> {preview with G.manifest=source_manifest})
    (manifest (M.combine (source_guard t) preview.manifest ~documents))))
