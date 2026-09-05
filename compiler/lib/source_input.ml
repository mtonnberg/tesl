module Paths = Map.Make (String)
module Names = Set.Make (String)

type view = { root : string; files : string Paths.t; directories : Names.t }
let active : view option ref = ref None
let project_root () = Option.map (fun view -> view.root) !active

let invalid path reason = invalid_arg ("source overlay " ^ path ^ ": " ^ reason)
let within root path =
  let prefix = if Filename.dirname root = root then root else root ^ Filename.dir_sep in
  String.starts_with ~prefix path && path <> root

(* realpath also handles aliases of existing paths. For a proposed file, resolve
   its nearest existing ancestor before appending missing components. Do not
   collapse '..' before resolving symlinks: that changes filesystem semantics. *)
let rec proposed_path path =
  try Unix.realpath path with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if parent = path then raise (Sys_error ("unresolvable source path: " ^ path));
    let parent = proposed_path parent in
    match Filename.basename path with
    | "." -> parent
    | ".." -> Filename.dirname parent
    | name -> Filename.concat parent name

let canonical_path = proposed_path

let rec validate_parent path =
  match Unix.lstat path with
  | info when info.Unix.st_kind = Unix.S_DIR && Unix.realpath path = path -> ()
  | _ -> invalid path "parent must be a canonical directory"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if parent = path then invalid path "missing filesystem root";
    validate_parent parent

let validate_file path =
  validate_parent (Filename.dirname path);
  match Unix.lstat path with
  | info when info.Unix.st_kind = Unix.S_REG && Unix.realpath path = path -> ()
  | _ -> invalid path "input must be a canonical regular file"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let directories root files =
  Paths.fold (fun path _ result ->
    let rec add path result =
      if Paths.mem path files then invalid path "path is both a file and a parent directory";
      let result = Names.add path result in
      if path = root then result else add (Filename.dirname path) result in
    add (Filename.dirname path) result) files Names.empty

let with_overlays ~project_root inputs f =
  let root = Unix.realpath project_root in
  if (Unix.stat root).Unix.st_kind <> Unix.S_DIR then invalid root "project must be a directory";
  let previous = !active in
  let base = match previous with
    | None -> Paths.empty
    | Some view when view.root = root -> view.files
    | Some _ -> invalid root "nested views must belong to the same project" in
  let seen = ref Names.empty in
  let files = List.fold_left (fun files (path, contents) ->
    if Filename.is_relative path || not (within root path) ||
       not (Filename.check_suffix path ".tesl") || String.contains path '\000' then
      invalid path "expected an absolute .tesl path inside the project";
    validate_file path;
    if proposed_path path <> path then invalid path "path must use its canonical spelling";
    if Names.mem path !seen then invalid path "duplicate input";
    seen := Names.add path !seen;
    Paths.add path contents files) base inputs in
  let view = {root; files; directories=directories root files} in
  Query_cache.clear ();
  active := Some view;
  Fun.protect ~finally:(fun () -> active := previous; Query_cache.clear ()) f

type entry = File of string | Directory

let find path = match !active with
  | None -> None
  | Some view ->
    let lookup path = match Paths.find_opt path view.files with
      | Some contents -> validate_file path; Some (File contents)
      | None when Names.mem path view.directories -> validate_parent path; Some Directory
      | None -> None in
    (* Check the exact spelling first so replacing a view's source/parent with a
       symlink cannot silently fall through to reading its new target. *)
    match lookup path with
    | Some _ as found -> found
    | None ->
      let canonical = try proposed_path path with Unix.Unix_error _ | Sys_error _ -> path in
      if canonical = path then None else lookup canonical

let read_using disk path = match find path with
  | Some (File contents) -> contents
  | Some Directory -> raise (Sys_error (path ^ ": is a directory"))
  | None -> disk path
let read = read_using (fun path -> In_channel.with_open_bin path In_channel.input_all)
let read_text = read_using (fun path -> In_channel.with_open_text path In_channel.input_all)
let exists path = match find path with Some _ -> true | None -> Sys.file_exists path
let is_directory path = match find path with
  | Some Directory -> true | Some (File _) -> false | None -> Sys.is_directory path
let kind path = match find path with
  | None -> (Unix.lstat path).Unix.st_kind
  | Some entry ->
    let virtual_kind = match entry with Directory -> Unix.S_DIR | File _ -> Unix.S_REG in
    (* This operation has lstat semantics. Reading a symlink alias may resolve
       a buffer, but that must never turn a symlink into a regular freeze target. *)
    (match Unix.lstat path with
     | info when info.Unix.st_kind = Unix.S_LNK -> Unix.S_LNK
     | _ -> virtual_kind
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> virtual_kind)
let realpath path = match find path with
  | Some _ -> proposed_path path | None -> Unix.realpath path

let readdir path = match !active, find path with
  | None, _ | Some _, None -> Sys.readdir path
  | Some _, Some (File _) -> raise (Sys_error (path ^ ": not a directory"))
  | Some view, Some Directory ->
    let canonical = proposed_path path in
    let disk =
      match Unix.lstat canonical with
      | _ -> Sys.readdir path
      | exception Unix.Unix_error (Unix.ENOENT, _, _) when Names.mem canonical view.directories -> [||] in
    let names = Array.fold_left (fun set name -> Names.add name set) Names.empty disk in
    let add_child child names =
      if Filename.dirname child = canonical then Names.add (Filename.basename child) names else names in
    let names = Paths.fold (fun child _ names -> add_child child names) view.files names in
    Names.fold add_child view.directories names |> Names.elements |> Array.of_list
