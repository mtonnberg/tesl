module Paths = Map.Make (String)
module Names = Set.Make (String)

type view = { root : string; files : string Paths.t; directories : Names.t;
              basenames : Names.t (* final components of every file and directory entry *);
              children : Names.t Paths.t (* each directory's file and directory entries, by name *) }
let active : view option ref = ref None
let pinned_files : string Paths.t ref = ref Paths.empty
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
  let checked () =
    validate_parent (Filename.dirname path);
    match Unix.lstat path with
    | info when info.Unix.st_kind = Unix.S_REG && Unix.realpath path = path -> ()
    | _ -> invalid path "input must be a canonical regular file"
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> () in
  (* An existing regular file whose real path is its own spelling has a
     canonical directory parent; anything else takes the full check, which
     also reports which part failed. *)
  match Unix.lstat path with
  | info when info.Unix.st_kind = Unix.S_REG && Unix.realpath path = path -> ()
  | _ | exception Unix.Unix_error _ -> checked ()

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
       not (Filename.check_suffix path ".tesl" || Filename.check_suffix path ".checkpoint") ||
       String.contains path '\000' then
      invalid path "expected an absolute .tesl or .checkpoint path inside the project";
    validate_file path;
    if proposed_path path <> path then invalid path "path must use its canonical spelling";
    (match Paths.find_opt path !pinned_files with
     | Some pinned when pinned <> contents -> invalid path "cannot change a pinned compiler resource in a nested source view"
     | _ -> ());
    if Names.mem path !seen then invalid path "duplicate input";
    seen := Names.add path !seen;
    Paths.add path contents files) base inputs in
  let directories = directories root files in
  let basenames = Names.union
    (Paths.fold (fun path _ names -> Names.add (Filename.basename path) names) files Names.empty)
    (Names.map Filename.basename directories) in
  let children =
    let add path children =
      let parent = Filename.dirname path in
      Paths.update parent (fun names ->
        Some (Names.add (Filename.basename path) (Option.value ~default:Names.empty names))) children in
    Names.fold add directories (Paths.fold (fun path _ children -> add path children) files Paths.empty) in
  let view = {root; files; directories; basenames; children} in
  Query_cache.clear ();
  active := Some view;
  Fun.protect ~finally:(fun () -> active := previous; Query_cache.clear ()) f

type entry = File of string | Directory

let find_project path = match !active with
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
      (* The canonical spelling keeps the final component unless that component
         is itself a symlink (or "." / ".."). When it is not, and no view entry
         has this final name, the canonical lookup below cannot match: skip the
         realpath walk. Import resolution probes many absent paths. *)
      let name = Filename.basename path in
      let unaliased () = name <> "." && name <> ".." &&
        (match Unix.lstat path with
         | info -> info.Unix.st_kind <> Unix.S_LNK
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
         | exception Unix.Unix_error _ -> false) in
      if not (Names.mem name view.basenames) && unaliased () then None else
      let canonical = try proposed_path path with Unix.Unix_error _ | Sys_error _ -> path in
      if canonical = path then None else lookup canonical

let find path =
  (* Pinned compiler resources are immutable input bytes, independently of the
     application's overlay root. Their resolver is fixed by the caller too. *)
  match Paths.find_opt path !pinned_files with
  | Some contents -> Some (File contents)
  | None -> find_project path

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
    Names.union names (Option.value ~default:Names.empty (Paths.find_opt canonical view.children))
    |> Names.elements |> Array.of_list

let with_pinned_files inputs f =
  let previous = !pinned_files and seen = ref Names.empty in
  let next = List.fold_left (fun files (path,contents) ->
    if Filename.is_relative path || not (Filename.check_suffix path ".tesl") ||
       String.contains path '\000' || canonical_path path <> path then
      invalid path "compiler resources require canonical absolute .tesl paths";
    if kind path <> Unix.S_REG then invalid path "compiler resource must be a regular input file";
    if Names.mem path !seen then invalid path "duplicate compiler resource";
    seen := Names.add path !seen;
    (match Paths.find_opt path files with
     | Some previous when previous <> contents -> invalid path "nested compiler resource snapshots disagree"
     | _ -> ());
    Paths.add path contents files) previous inputs in
  Query_cache.clear (); pinned_files := next;
  Fun.protect ~finally:(fun () -> pinned_files := previous; Query_cache.clear ()) f

let without_pinned_files f =
  let previous = !pinned_files in
  if Paths.is_empty previous then f () else begin
    Query_cache.clear (); pinned_files := Paths.empty;
    Fun.protect ~finally:(fun () -> pinned_files := previous; Query_cache.clear ()) f
  end

(* The identity of the active source view: the overlay and the pinned resources.
   Views are immutable, so physical equality means "nothing a view supplies has
   changed since the token was taken". It says nothing about unpinned disk bytes. *)
type view_token = view option * string Paths.t
let view_token () : view_token = (!active, !pinned_files)
let same_view ((view, pinned) : view_token) = view == !active && pinned == !pinned_files
