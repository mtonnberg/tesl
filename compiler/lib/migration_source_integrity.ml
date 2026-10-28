module M = Migration_manifest
module D = Migration_source_diagnostics
module S = Migration_sparse
module Paths = Set.Make(String)
type t = { guard:M.t; files:(string * string) list }
exception Invalid of S.error list
let reject path message = raise (Invalid [{S.code="MIG013";loc=Location.dummy_loc path;message;related=[]}])
let guard = function Ok value -> value | Error errors ->
 raise (Invalid (List.map(fun(e:M.error)->{S.code="MIG013";loc=Location.dummy_loc e.path;message=e.message;related=[]})errors))
let protect f = try Ok(f()) with
 | Invalid errors -> Error errors
 | Sys_error message | Invalid_argument message | Failure message ->
   Error [{S.code="MIG013";loc=Location.dummy_loc "<source integrity>";message;related=[]}]
 | Unix.Unix_error(error,operation,path) ->
   Error [{S.code="MIG013";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let revalidate t = protect(fun()->Source_input.without_pinned_files(fun()->
 ignore(guard(M.verify_source t.guard ~documents:[]));ignore(guard(M.verify_disk t.guard))))
let capture ~project_root ~inputs = protect(fun()->
 let manifest=ref(guard(M.create ~project_root ~reads:[] ~directories:[] ~imports:[] ~documents:[] ~writes:[])) in
 let seen=ref Paths.empty and directories=ref Paths.empty and files=Hashtbl.create 32 in
 let extend ~reads ~dirs ~imports =
  let next=guard(M.create ~project_root ~reads ~directories:dirs ~imports ~documents:[] ~writes:[]) in
  manifest:=guard(M.combine !manifest next ~documents:[]);
  guard(M.source_files next) in
 let module_path root name = match Validation_common.schema_module_relative_path name with
  | Some path -> Filename.concat root path
  | None -> reject root "source integrity metadata contains an invalid module path" in
 let rec visit path =
  if not(Paths.mem path !seen) then begin
   seen:=Paths.add path !seen;
   let captured=extend ~reads:[path] ~dirs:[] ~imports:[] in
   List.iter(fun(file,bytes)->
    Hashtbl.replace files file bytes;
    (* Every read is guarded before its bytes select more inputs. Combining
       manifests preserves those observations instead of recapturing them. *)
    let imports=match Parser.parse_module file bytes with
     | Err _ -> [] (* the ordinary diagnostic preserves malformed-source detail *)
     | Ok m -> List.filter_map(fun(i:Ast.import_decl)->
        if String.starts_with ~prefix:"Tesl." i.module_name then None else Some(file,i.module_name))m.imports in
    let imported=extend ~reads:[] ~dirs:[] ~imports in
    List.iter(fun(child,_)->if child<>file then visit child)imported;
    let scopes=D.owned_scopes "schema" file @ D.owned_scopes "migrations" file |> List.sort_uniq compare in
    List.iter(fun(root,folder)->discover root folder)scopes;
    List.iter(fun(root,_)->
      (match Migration_header.read ~file bytes with
       | Ok(Some header)->let old,fresh=Migration_header.recorded_seals header in
         List.iter(fun seal->List.iter(fun(name,_)->visit(module_path root name))(Migration_seal.sources seal))[old;fresh]
       | Ok None | Error _ -> ());
      (match Migration_closure.read ~file bytes with
       | Ok(Some closure)->List.iter(fun(name,_)->visit(module_path root name))(Migration_closure.sources closure)
       | Ok None | Error _ -> ())) (D.owned_scopes "migrations" file)
   )captured
  end
 and discover root folder =
  let directory=Filename.concat root(Filename.concat "migrations" folder) in
  if not(Paths.mem directory !directories) then begin
   directories:=Paths.add directory !directories;
   ignore(extend ~reads:[] ~dirs:[directory] ~imports:[]);
   let names=if Source_input.exists directory then Source_input.readdir directory else [||] in
   Array.iter(fun name->
    let file=Filename.concat directory name in
    if D.is_migration_root file then begin
     (* The existence of the frozen schema controls whether metadata is required. *)
     let frozen=Filename.concat root(Filename.concat "schema"(Filename.concat folder name)) in
     visit frozen;visit file;
     let stem=Filename.chop_suffix name ".tesl" in
     visit(Filename.concat directory(stem ^ "-contract.tesl"))
    end)names
  end in
 List.iter(fun(path,bytes)->visit path;
   if Hashtbl.find_opt files path<>Some bytes then reject path "source changed before integrity discovery")inputs;
 let token={guard= !manifest;files=Hashtbl.to_seq files |> List.of_seq |> List.sort compare} in
 (match revalidate token with Ok()->()|Error errors->raise(Invalid errors));token)
let with_captured t f = protect(fun()->
 (match revalidate t with Ok()->()|Error errors->raise(Invalid errors));
 let project_root=Option.value(Source_input.project_root()) ~default:(M.project_root t.guard) in
 let result=Source_input.with_overlays ~project_root t.files(fun()->Source_input.with_pinned_files t.files f) in
 (* Leave the owned snapshot before checking the caller's current source view. *)
 (match revalidate t with Ok()->()|Error errors->raise(Invalid errors));result)
