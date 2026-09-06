include Migration_selection
module M = Migration_manifest
module G = Migration_generate
let generated result = Result.map_error (List.map (fun (e:G.error) ->
 {loc=Location.dummy_loc e.path;message=e.message;candidates=[]})) result
let manifest result = Result.map_error (List.map (fun (e:M.error) ->
 {loc=Location.dummy_loc e.path;message=e.message;candidates=[]})) result
let start t ~documents =
 Result.bind (verify t ~documents) (fun () ->
  Result.bind (generated (G.start_with_compatibility ~stored_value_compatibility:(stored_value_compatibility t)
    ~compiler_abi:(compiler_abi t) ~project_root:(project_root t)
    ~family:(selection t).family ~version:(selection t).current_version ~documents)) (fun preview ->
   Result.map (fun source_manifest -> {preview with G.manifest=source_manifest})
    (manifest (M.combine (source_guard t) preview.manifest ~documents))))
let refresh t ~documents =
 Result.bind (verify t ~documents) (fun () ->
  Result.bind (generated (G.refresh_with_compatibility ~stored_value_compatibility:(stored_value_compatibility t)
    ~compiler_abi:(compiler_abi t) ~project_root:(project_root t)
    ~family:(selection t).family ~version:(selection t).current_version ~documents)) (fun preview ->
   Result.map (fun source_manifest -> {preview with G.manifest=source_manifest})
    (manifest (M.combine (source_guard t) preview.manifest ~documents))))
