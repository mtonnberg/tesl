module M = Migration_manifest
module D = Migration_source_diagnostics
module S = Migration_sparse
module Paths = Set.Make(String)
(* [fresh]: the guards were verified when the token was published and nothing
   has used it since; the first [with_captured] need not verify them again. *)
type t = { guard:M.t; files:(string * string) list; fresh:bool ref; token:Source_input.view_token }
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
(* [quick]: an intermediate check within the command (see M.verify_disk); the
   default full check is the one a publication relies on. *)
let revalidate ?quick t = protect(fun()->Source_input.without_pinned_files(fun()->
 ignore(guard(M.verify_source ?quick t.guard ~documents:[]));ignore(guard(M.verify_disk ?quick t.guard))))
let rec capture ~history ~project_root ~inputs = protect(fun()->
 (* Under a frozen history scope the union is one scoped manifest created at the
    end from the same observations; otherwise each step's manifest is merged. *)
 let accumulator=ref(if history<>None then None else
  Some(guard(M.start_combine (guard(M.create ~project_root ~reads:[] ~directories:[] ~imports:[] ~documents:[] ~writes:[])) ~documents:[]))) in
 let all_reads=ref [] and all_dirs=ref [] and all_imports=ref [] in
 (* Under a scope, a frozen source (inside a history tree and not the current
    revision's) is guarded by the scope's walks with every other file of the
    trees: it is neither guarded on its own nor traversed. *)
 let frozen=match history with
  | None -> (fun _ -> false)
  | Some (h:M.history) -> fun path -> not (h.keep path) &&
     List.exists (fun tree -> String.starts_with ~prefix:(tree ^ Filename.dir_sep) path) h.history_trees in
 let frozen_seen=ref Paths.empty in
 let seen=ref Paths.empty and directories=ref Paths.empty and files=Hashtbl.create 32 in
 let observed=M.observations () in
 let extend ~reads ~dirs ~imports =
  let next=guard(M.create_observed observed ~project_root ~reads ~directories:dirs ~imports ~documents:[] ~writes:[]) in
  (* Keep each original observation. Rechecking the growing union here makes
     graph discovery quadratic; the final union checks every captured source,
     disk, directory and import guard before publishing the token. *)
  (match !accumulator with
   | Some union -> accumulator:=Some(guard(M.add_to_combine union next))
   | None -> all_reads:=List.rev_append reads !all_reads;all_dirs:=List.rev_append dirs !all_dirs;
     all_imports:=List.rev_append imports !all_imports);
  guard(M.source_files next) in
 let module_path root name = match Validation_common.schema_module_relative_path name with
  | Some path -> Filename.concat root path
  | None -> reject root "source integrity metadata contains an invalid module path" in
 let rec visit path =
  if frozen path then frozen_seen:=Paths.add path !frozen_seen else
  if not(Paths.mem path !seen) then begin
   seen:=Paths.add path !seen;
   let captured=extend ~reads:[path] ~dirs:[] ~imports:[] in
   List.iter(fun(file,bytes)->
    Hashtbl.replace files file bytes;
    (* Every read is guarded before its bytes select more inputs. Combining
       manifests preserves those observations instead of recapturing them. *)
    let imports=match Migration_closure.imports ~file bytes with
     | Error _ -> [] (* the ordinary diagnostic preserves malformed-source detail *)
     | Ok imports -> List.filter_map(fun name->
        if String.starts_with ~prefix:"Tesl." name then None else Some(file,name))imports in
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
 List.iter(fun(path,_)->visit path)inputs;
 let manifest=match !accumulator with
  | Some union -> Some(guard(M.finish_combine union))
  | None ->
    let union=guard(M.create_observed_scoped history observed ~project_root ~reads:(!all_reads @ Paths.elements !frozen_seen)
      ~directories:!all_dirs ~imports:!all_imports ~documents:[] ~writes:[]) in
    match guard(M.frozen_sources union) with
    | None -> None
    | Some sources ->
      (* With the frozen sources that keep their own guards (import targets of
         the current revision). *)
      List.iter(fun(file,bytes)->Hashtbl.replace files file bytes)(sources @ guard(M.source_files union));
      (* As finish_combine: every guard of the union is verified before publishing. *)
      guard(M.verify_source union ~documents:[]);guard(M.verify_disk ~quick:true union);Some union in
 match manifest with
 | None ->
   (* The scope did not hold (a symbolic link or special file in a tree, or a
      tree parent that could hide an import): every file is guarded alone. *)
   (match capture ~history:None ~project_root ~inputs with Ok t -> t | Error errors -> raise (Invalid errors))
 | Some manifest ->
 List.iter(fun(path,bytes)->
   if Hashtbl.find_opt files path<>Some bytes then reject path "source changed before integrity discovery")inputs;
 (* finish_combine has just verified every source, disk, directory and import
    guard of the union. *)
 {guard=manifest;files=Hashtbl.to_seq files |> List.of_seq |> List.sort compare;fresh=ref (not (Source_input.has_pinned_files ()));token=Source_input.view_token ()})
let with_captured t f = protect(fun()->
 if !(t.fresh) then t.fresh := false
 else (match revalidate ~quick:true t with Ok()->()|Error errors->raise(Invalid errors));
 let project_root=Option.value(Source_input.project_root()) ~default:(M.project_root t.guard) in
 (* The files were read in the capture's view; freezing them there observes
    exactly what that view does. *)
 let equivalent=Source_input.same_view t.token in
 let result=Source_input.with_overlays ~project_root t.files(fun()->Source_input.with_pinned_files t.files (fun () ->
   if equivalent then Source_input.with_equivalent_view t.token f else f ())) in
 (* Leave the owned snapshot before checking the caller's current source view. *)
 (match revalidate ~quick:true t with Ok()->()|Error errors->raise(Invalid errors));result)
