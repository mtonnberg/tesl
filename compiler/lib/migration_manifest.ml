module Paths = Map.Make(String)
type document = { path : string; version : int }
type edit = { path : string; before : string option; after : string; document_version : int option }
type error = { path : string; message : string }
type file_guard = { file : string; source_digest : string option; disk_digest : string option }
type directory_guard = { directory : string; source_names : string list option; disk_names : string list option }
type import_guard = { source : string; name : string; source_path : string; disk_path : string }
(* One observation of a frozen history tree: every entry below each tree root, in
   lstat terms: a directory, a regular file with its bytes' digest, or a regular
   file whose bytes the history digest leaves out ([Present]: excluded, or an
   older checkpoint). Any other kind (a symbolic link, a device) cannot be
   observed this way. *)
type entry = Dir | File of string | Present
type walk = { tree : string; entries : (string * entry) list option (* None: the tree is absent *) }
(* The frozen part of a family's history as one precondition: [excluded] paths
   carry their own file or directory guard instead (the current revision, the
   outputs, open documents). [source_walk]/[disk_walk] are complete walks in each view;
   only their non-excluded entries are hashed. *)
type history_guard = { trees : string list; excluded : string list; source_walk : walk list; disk_walk : walk list }
type history = { history_trees : string list; keep : string -> bool }
type t = { root : string; documents : document list; edits : edit list;
           files : file_guard list; directories : directory_guard list; imports : import_guard list;
           history : history_guard list }
exception Invalid of error
let reject path message = raise (Invalid {path;message})
let protect f = try Ok (f ()) with
  | Invalid error -> Error [error]
  | Sys_error message | Failure message | Invalid_argument message -> Error [{path="";message}]
  | Unix.Unix_error (error,operation,path) -> Error [{path;message=operation ^ ": " ^ Unix.error_message error}]
let hash = Migration_hash.digest
let project_root t = t.root
let edits t = t.edits
let overlays t = List.map (fun (edit : edit) -> edit.path,edit.after) t.edits
let optional f = try Some (f ()) with Unix.Unix_error (Unix.ENOENT,_,_) -> None
let canonical root path =
  if not (String.is_valid_utf_8 path) then reject "" "manifest paths must be valid UTF-8";
  let prefix = if Filename.dirname root = root then root else root ^ Filename.dir_sep in
  if Filename.is_relative path || (path <> root && not (String.starts_with ~prefix path)) ||
     Source_input.canonical_path path <> path then
    reject path "manifest paths must be absolute, canonical and inside the project"
(* Disk answers are shared with the compilation's memo (Source_input.Disk);
   a final guard observes disk anew (see [verify_files]). *)
let kind ~disk path = if disk then (Source_input.Disk.lstat path).Unix.st_kind else Source_input.kind path
let file_bytes ~disk path =
  match optional (fun () -> kind ~disk path) with
  | None -> None
  | Some Unix.S_REG -> Some (if disk then Source_input.Disk.read path else Source_input.read path)
  | Some _ -> reject path "manifest source must be a regular file"
let names ~disk path =
  match optional (fun () -> kind ~disk path) with
  | None -> None
  | Some Unix.S_DIR ->
    Some ((if disk then Source_input.Disk.readdir path else Source_input.readdir path) |> Array.to_list |> List.sort String.compare)
  | Some _ -> reject path "manifest directory must be a directory"
let normalized_documents root documents =
  let seen = Hashtbl.create 8 in
  List.iter (fun (document : document) ->
    canonical root document.path;
    if Int64.of_int document.version < -2147483648L || Int64.of_int document.version > 2147483647L then
      reject document.path "document versions must be signed 32-bit integers";
    if Hashtbl.mem seen document.path then reject document.path "duplicate document version";
    Hashtbl.add seen document.path ()) documents;
  List.sort (fun (a : document) b -> String.compare a.path b.path) documents
let validate_root root =
  if not (String.is_valid_utf_8 root) || Filename.is_relative root || Source_input.canonical_path root <> root ||
     Source_input.Disk.realpath root <> root || (Source_input.Disk.lstat root).Unix.st_kind <> Unix.S_DIR then
    reject root "manifest project root must be an existing canonical directory"
let resolve ~disk source name =
  if disk then Validation_common.resolve_local_import_path_with ~exists:Source_input.Disk.exists ~realpath:Source_input.Disk.realpath source name
  else Validation_common.resolve_local_import_path source name

(* Frozen history trees. A walk observes every entry below a tree root in lstat
   terms; a symbolic link or special file refuses the observation, so a walk is
   determined by bytes, names and kinds inside the tree alone. Entry identities
   are project-relative with '/' separators on every platform. *)
exception Unobservable of string
let relative root path =
  let prefix = if Filename.dirname root = root then root else root ^ Filename.dir_sep in
  let rel = if path = root then "" else String.sub path (String.length prefix) (String.length path - String.length prefix) in
  if Sys.win32 then String.map (function '\\' -> '/' | c -> c) rel else rel
let inside_tree tree path = String.starts_with ~prefix:(tree ^ Filename.dir_sep) path
module Path_set = Set.Make(String)
(* "v<N>.checkpoint": a generated revision checkpoint. *)
let checkpoint_version path =
  let name = Filename.basename path in
  let n = String.length name in
  if n > 12 && name.[0] = 'v' && Filename.check_suffix name ".checkpoint" then
    let digits = String.sub name 1 (n - 12) in
    if digits.[0] <> '0' && String.length digits <= 9 && String.for_all (function '0'..'9' -> true | _ -> false) digits
    then Some (int_of_string digits) else None
  else None
let newest_checkpoint paths =
  List.fold_left (fun newest path -> match checkpoint_version path, newest with
    | Some n, Some m when n <= m -> newest | Some n, _ -> Some n | None, _ -> newest) None paths
(* One walk of every tree: the kinds of all entries, then the digests of the
   non-excluded regular files. Of the checkpoints only the newest non-excluded
   one is hashed (the one a resumed history reads); an older checkpoint's digest
   is sealed in its frozen migration root, and the walk records its presence. *)
let walk_all ~disk ~digest ~excluded trees =
  let collect tree =
    match optional (fun () -> kind ~disk tree) with
    | None -> None
    | Some Unix.S_DIR ->
      let entries = ref [] in
      let rec visit directory =
        match names ~disk directory with
        | None -> raise (Unobservable directory)
        | Some names -> List.iter (fun name ->
          let path = Filename.concat directory name in
          match kind ~disk path with
          | Unix.S_DIR -> entries := (path,true) :: !entries; visit path
          | Unix.S_REG -> entries := (path,false) :: !entries
          | _ -> raise (Unobservable path)
          | exception Unix.Unix_error (Unix.ENOENT,_,_) -> raise (Unobservable path)) names in
      visit tree; Some (List.rev !entries)
    | Some _ -> raise (Unobservable tree) in
  let collected = List.map (fun tree -> tree,collect tree) trees in
  let newest = newest_checkpoint (List.concat_map (fun (_,entries) ->
    List.filter_map (fun (path,dir) -> if dir || Path_set.mem path excluded then None else Some path)
      (Option.value entries ~default:[])) collected) in
  List.map (fun (tree,entries) -> {tree;entries=Option.map (List.map (fun (path,dir) ->
    if dir then path,Dir
    else if Path_set.mem path excluded then path,Present
    else match checkpoint_version path with
      | Some n when Some n <> newest -> path,Present
      | _ -> path,File (digest path))) entries}) collected
let plain_digest ~disk path =
  hash (if disk then Source_input.Disk.read path else Source_input.read path)
(* The hashed form of one view: every non-excluded entry, sorted by identity. *)
let history_lines root excluded walks =
  let excluded = Path_set.of_list excluded in
  let kept = List.map (fun w -> w,Option.map (List.filter (fun (path,_) -> not (Path_set.mem path excluded))) w.entries) walks in
  let newest = newest_checkpoint (List.concat_map (fun (_,entries) ->
    List.filter_map (fun (path,entry) -> if entry = Dir then None else Some path) (Option.value entries ~default:[])) kept) in
  List.concat_map (fun (w,entries) ->
    let body = match entries with
      | None -> ["absent"]
      | Some entries -> List.map (fun (path,entry) ->
          let rel = relative root path in
          rel,(match entry,checkpoint_version path with
            | Dir,_ -> "d\000" ^ rel
            | (File _ | Present),Some n when Some n <> newest -> "c\000" ^ rel
            | File digest,_ -> "f\000" ^ rel ^ "\000" ^ digest
            | Present,_ -> reject path "the frozen history scope no longer observes these bytes")) entries
        |> List.sort (fun (a,_) (b,_) -> String.compare a b) |> List.map snd in
    ("tree\000" ^ relative root w.tree) :: body @ ["end"]) kept
let history_digest root excluded walks =
  hash ("tesl-frozen-history-v1\000" ^ String.concat "" (List.map (fun line -> line ^ "\000") (history_lines root excluded walks)))
(* The first differing entry, for a precise refusal. *)
let history_difference root excluded expected actual =
  let rec first = function
    | a :: rest, b :: rest' when a = b -> first (rest,rest')
    | a :: _, b :: _ -> Some (min a b)
    | a :: _, [] | [], a :: _ -> Some a
    | [], [] -> None in
  match first (history_lines root excluded expected, history_lines root excluded actual) with
  | None -> None
  | Some line -> Some (match String.split_on_char '\000' line with
    | ("d" | "f" | "c" | "tree") :: rel :: _ -> rel | _ -> String.concat "/" (List.map (fun w -> relative root w.tree) expected))
let lookup walks path = List.find_map (fun w ->
  if inside_tree w.tree path then Some (Option.bind w.entries (List.assoc_opt path)) else None) walks |> Option.join
let children walks path = List.concat_map (fun w -> match w.entries with
  | Some entries when path = w.tree || inside_tree w.tree path ->
    List.filter_map (fun (entry,_) -> if Filename.dirname entry = path then Some (Filename.basename entry) else None) entries
  | _ -> []) walks |> List.sort String.compare
(* Each excluded path's own guard must agree with what the walk of the same view
   observed there; otherwise excluding it would drop an original observation. *)
let consistent_history t =
  let files = List.fold_left (fun map g -> Paths.add g.file g map) Paths.empty t.files in
  let directories = List.fold_left (fun map g -> Paths.add g.directory g map) Paths.empty t.directories in
  List.iter (fun h ->
    List.iter (fun (walks,digest,listing) ->
      List.iter (fun path ->
        let entry = lookup walks path in
        Option.iter (fun g -> if (match entry, digest g with
            | Some (File d), Some actual -> d <> actual
            | Some Present, Some _ | None, None -> false
            | _ -> true)
          then reject path "conflicting history precondition") (Paths.find_opt path files);
        Option.iter (fun g -> if listing g <> (match entry with Some Dir -> Some (children walks path) | None -> None | Some (File _ | Present) -> Some [""])
          then reject path "conflicting history precondition") (Paths.find_opt path directories)) h.excluded)
      [h.source_walk,(fun g -> g.source_digest),(fun g -> g.source_names);
       h.disk_walk,(fun g -> g.disk_digest),(fun g -> g.disk_names)]) t.history
(* Exclude every path that has its own guard: the file and directory guards and
   the history then never describe one path twice. *)
let with_exclusions t =
  let guarded = List.map (fun g -> g.file) t.files @ List.map (fun g -> g.directory) t.directories in
  let history = List.map (fun h ->
    let own = List.filter (fun path -> List.exists (fun tree -> inside_tree tree path) h.trees) guarded in
    {h with excluded=List.sort_uniq String.compare (h.excluded @ own)}) t.history in
  let t = {t with history} in consistent_history t; t

let family_history ~project_root ~family ~current_version =
  let tree name = match Validation_common.schema_module_relative_path (family ^ name) with
    | Some relative -> Filename.dirname (Filename.concat project_root relative)
    | None -> invalid_arg ("not a schema family: " ^ family) in
  let schema = tree ".VCurrent" and migrations = tree ".Migrate.V2" in
  let first tree path =
    let rest = String.sub path (String.length tree + 1) (String.length path - String.length tree - 1) in
    match String.index_opt rest Filename.dir_sep.[0] with Some i -> String.sub rest 0 i | None -> rest in
  let revision = "v" ^ string_of_int current_version in
  let keep path =
    if inside_tree schema path then List.mem (first schema path) ["v-current.tesl";"v-current"]
    else if inside_tree migrations path then
      List.mem (first migrations path) [revision ^ ".tesl";revision ^ "-contract.tesl";revision ^ ".checkpoint";revision]
    else true in
  {history_trees=[schema;migrations];keep}

(* Disk evidence of the passes already made within one compilation (Source_input
   scope): for each file, the lstat identity under which its bytes had a digest;
   each directory's listing under its lstat identity; each import resolution
   found on disk. A quick pass (an intermediate check of a command) accepts a
   file or directory whose lstat identity is unchanged and an import already
   resolved to its expected path; a full pass (the default, and every final guard)
   reads, hashes, lists and resolves everything anew. *)
type identity = int * int * int * float * float * Unix.file_kind
let identity (s : Unix.stats) : identity = s.st_dev,s.st_ino,s.st_size,s.st_mtime,s.st_ctime,s.st_kind
let seen_files : (string, identity * string) Hashtbl.t = Hashtbl.create 64
let seen_names : (string, identity * string list) Hashtbl.t = Hashtbl.create 16
let seen_imports : (string * string, string) Hashtbl.t = Hashtbl.create 64
let () = Source_input.on_scope_exit (fun () ->
  Hashtbl.reset seen_files; Hashtbl.reset seen_names; Hashtbl.reset seen_imports)
let remember table key value = if Source_input.in_scope () then Hashtbl.replace table key value

(* One disk pass observes each path once: import resolution probes the same
   ancestors for many imports. *)
let disk_pass () =
  let exists = Hashtbl.create 64 and real = Hashtbl.create 16 in
  let memo table f path = match Hashtbl.find_opt table path with
    | Some (Ok v) -> v | Some (Error e) -> raise e
    | None -> let r = try Ok (f path) with e -> Error e in Hashtbl.replace table path r;
      (match r with Ok v -> v | Error e -> raise e) in
  fun source name -> Validation_common.resolve_local_import_path_with
    ~exists:(memo exists Source_input.Disk.exists) ~realpath:(memo real Source_input.Disk.realpath) source name

(* One verification pass resolves each directory's canonical spelling once
   (Source_input.with_path_memo); every file is still read and hashed. A disk
   pass resolves anew, so it observes a directory replaced during the command. *)
let verify_files ?(quick=false) t disk = (if disk then Source_input.with_fresh_path_memo else Source_input.with_path_memo) @@ fun () ->
  let quick = quick && disk && Source_input.in_scope () in
  validate_root t.root;
  let resolve_disk = disk_pass () in
  List.iter (fun guard ->
    let expected = if disk then guard.disk_path else guard.source_path in
    let key = guard.source,guard.name in
    if not (quick && Hashtbl.find_opt seen_imports key = Some expected) then begin
      let resolved = if disk then resolve_disk guard.source guard.name else resolve ~disk guard.source guard.name in
      if resolved <> expected then
        reject guard.source ("import resolution changed since preview: " ^ guard.name);
      if disk then remember seen_imports key resolved
    end) t.imports;
  let observed path = match Unix.lstat path with
    | stats -> Some (identity stats) | exception Unix.Unix_error _ -> None in
  List.iter (fun guard ->
    canonical t.root guard.file;
    let expected = if disk then guard.disk_digest else guard.source_digest in
    let before = if disk then observed guard.file else None in
    let unchanged = quick && (match before, expected, Hashtbl.find_opt seen_files guard.file with
      | Some now, Some digest, Some (recorded, recorded_digest) -> now = recorded && digest = recorded_digest
      | _ -> false) in
    if not unchanged then begin
      let actual = Option.map hash (file_bytes ~disk guard.file) in
      if actual <> expected then
        reject guard.file (if disk then "saved source changed since preview" else "source view changed since preview");
      (* Recorded only when the file kept one identity around its read. *)
      match before, actual with
      | Some id, Some digest when disk && observed guard.file = before -> remember seen_files guard.file (id,digest)
      | _ -> ()
    end) t.files;
  List.iter (fun guard ->
    canonical t.root guard.directory;
    let expected = if disk then guard.disk_names else guard.source_names in
    let before = if disk then observed guard.directory else None in
    let unchanged = quick && (match before, expected, Hashtbl.find_opt seen_names guard.directory with
      | Some now, Some names, Some (recorded, recorded_names) -> now = recorded && names = recorded_names
      | _ -> false) in
    if not unchanged then begin
      let actual = names ~disk guard.directory in
      if actual <> expected then
        reject guard.directory (if disk then "saved directory membership changed since preview" else "source directory membership changed since preview");
      match before, actual with
      | Some id, Some names when disk && observed guard.directory = before -> remember seen_names guard.directory (id,names)
      | _ -> ()
    end) t.directories;
  (* One pass over each frozen history tree. A quick pass reuses a file digest
     only under an unchanged lstat identity, as for file guards. *)
  let digest path =
    if not disk then plain_digest ~disk path else
    let before = observed path in
    match before, Hashtbl.find_opt seen_files path with
    | Some now, Some (recorded,digest) when quick && now = recorded -> digest
    | _ ->
      let digest = plain_digest ~disk path in
      (match before with Some id when observed path = before -> remember seen_files path (id,digest) | _ -> ());
      digest in
  List.iter (fun h ->
    let expected = if disk then h.disk_walk else h.source_walk in
    let changed detail = reject (List.hd h.trees)
      ((if disk then "saved frozen history changed since preview: " else "source frozen history changed since preview: ") ^ detail) in
    match walk_all ~disk ~digest ~excluded:(Path_set.of_list h.excluded) h.trees with
    | actual ->
      if history_digest t.root h.excluded actual <> history_digest t.root h.excluded expected then
        changed (Option.value (history_difference t.root h.excluded expected actual) ~default:"")
    | exception Unobservable path -> changed (relative t.root path ^ " is not a regular file or directory")) t.history
let verify_source t ~documents = protect (fun () ->
  let documents = normalized_documents t.root documents in
  if documents <> t.documents then reject t.root "open document set or version changed since preview";
  verify_files t false)
let verify_disk ?quick t = protect (fun () -> verify_files ?quick t true)
let source_files t = protect (fun () ->
  List.filter_map (fun guard ->
    canonical t.root guard.file;
    let source = file_bytes ~disk:false guard.file in
    if Option.map hash source <> guard.source_digest then
      reject guard.file "source changed before capturing compilation bytes";
    Option.map (fun source -> guard.file,source) source) t.files)
(* Observations shared by the manifests of one capture: each file and directory
   is read once, and every later manifest records that original observation.
   The capture's final union rechecks every guard against fresh reads. *)
type observations = { observed_files : (bool * string, string option) Hashtbl.t;
  observed_names : (bool * string, string list option) Hashtbl.t;
  observed_roots : (string, unit) Hashtbl.t;
  (* One disk pass for every manifest of the set (each path probed once). *)
  observed_resolver : (string -> string -> string) Lazy.t }
let observations () = { observed_files=Hashtbl.create 64; observed_names=Hashtbl.create 16;
  observed_roots=Hashtbl.create 1; observed_resolver=lazy (disk_pass ()) }
let create_with ~history ~observed ~project_root:root ~reads ~directories ~imports ~documents ~writes = protect (fun () -> Source_input.with_path_memo @@ fun () ->
  let memo table compute key = match observed with
    | None -> compute key
    | Some o -> let table = table o in
      match Hashtbl.find_opt table key with
      | Some value -> value
      | None -> let value = compute key in Hashtbl.replace table key value; value in
  let file_bytes ~disk path = memo (fun o -> o.observed_files) (fun (disk,path) -> file_bytes ~disk path) (disk,path) in
  let names ~disk path = memo (fun o -> o.observed_names) (fun (disk,path) -> names ~disk path) (disk,path) in
  (* Manifests sharing one observation set validate their common root once. *)
  (match observed with
   | Some o when Hashtbl.mem o.observed_roots root -> ()
   | Some o -> validate_root root; Hashtbl.replace o.observed_roots root ()
   | None -> validate_root root);
  let resolve_disk = match observed with Some o -> Lazy.force o.observed_resolver | None -> disk_pass () in
  let documents = normalized_documents root documents in
  let imports = List.sort_uniq compare imports |> List.map (fun (source,name) ->
    canonical root source;
    if not (String.is_valid_utf_8 name) then reject source "import names must be valid UTF-8";
    {source;name;source_path=resolve ~disk:false source name;disk_path=resolve_disk source name}) in
  let writes = List.fold_left (fun map (path,source) ->
    canonical root path;
    (* Generated revision checkpoints are written beside their migration root. *)
    if not (Filename.check_suffix path ".tesl" || Filename.check_suffix path ".checkpoint") then
      reject path "migration source edits must target .tesl files or generated .checkpoint files";
    if Paths.mem path map then reject path "duplicate output path";
    Paths.add path source map) Paths.empty writes in
  let overlay_root = Option.value (Source_input.project_root ()) ~default:root in
  (* Validates the proposed output paths in a source view; no writes, no view. *)
  if not (Paths.is_empty writes) then
    Source_input.with_overlays ~project_root:overlay_root (Paths.bindings writes) (fun () -> ());
  let paths = reads @ List.map fst (Paths.bindings writes) @ List.map (fun (d : document) -> d.path) documents @
    List.concat_map (fun g -> [g.source;g.source_path;g.disk_path]) imports
    |> List.sort_uniq String.compare in
  (* A frozen history scope replaces the file guards of its frozen sources, and
     the import guards among them, with one walk of each tree per view. *)
  let build scope =
    let paths,imports,trees = match scope with
      | None -> paths,imports,[]
      | Some (h,trees) ->
        let inside path = List.exists (fun tree -> inside_tree tree path) trees in
        let documented = List.fold_left (fun set (d : document) -> Path_set.add d.path set) Path_set.empty documents in
        let primary path = not (inside path) || h.keep path || Paths.mem path writes || Path_set.mem path documented in
        let regular ~disk path = match kind ~disk path with
          | Unix.S_REG -> true | _ -> false | exception Unix.Unix_error _ -> false in
        (* Resolution from a tree probes only that tree, then the tree's parent
           (its guarded listing), then the project root, where an existing
           candidate ends the search. A parent entry that can begin a module path
           ("schema", "migrations") could hide a deeper candidate from that
           listing; then every import keeps its own guard. *)
        let unshadowed = List.for_all (fun tree -> List.for_all (fun disk ->
          match names ~disk (Filename.dirname tree) with
          | None -> true
          | Some entries -> not (List.mem "schema" entries || List.mem "migrations" entries)) [false;true]) trees in
        let covered g = unshadowed && inside g.source && not (primary g.source) &&
          inside g.source_path && inside g.disk_path && regular ~disk:false g.source_path && regular ~disk:true g.disk_path in
        let kept = List.filter (fun g -> not (covered g)) imports in
        let endpoints = List.fold_left (fun set g -> Path_set.add g.source (Path_set.add g.source_path (Path_set.add g.disk_path set))) Path_set.empty kept in
        List.filter (fun path -> primary path || Path_set.mem path endpoints) paths,kept,trees in
    let directories = directories @ trees in
    let files,edits = List.fold_left (fun (files,edits) path ->
      canonical root path;
      let source = file_bytes ~disk:false path and saved = file_bytes ~disk:true path in
      let guard = {file=path;source_digest=Option.map hash source;disk_digest=Option.map hash saved} in
      let edits = match Paths.find_opt path writes with
        | Some after when source <> Some after ->
          let document_version = List.find_opt (fun (d : document) -> d.path = path) documents |> Option.map (fun d -> d.version) in
          {path;before=source;after;document_version} :: edits
        | _ -> edits in
      guard :: files,edits) ([],[]) paths in
    let rec parents directory acc =
      canonical root directory;
      if directory = root then directory :: acc else parents (Filename.dirname directory) (directory :: acc) in
    let directories = List.concat_map (fun path -> parents (Filename.dirname path) []) paths @
      List.concat_map (fun directory -> parents directory []) directories @ [root]
      |> List.sort_uniq String.compare
      |> List.map (fun directory -> {directory;source_names=names ~disk:false directory;disk_names=names ~disk:true directory}) in
    let history = match trees with
      | [] -> []
      | trees ->
        let excluded = List.map (fun g -> g.file) files @ List.map (fun g -> g.directory) directories
          |> List.filter (fun path -> List.exists (fun tree -> inside_tree tree path) trees) |> List.sort_uniq String.compare in
        let digest ~disk path = match observed with
          | None -> plain_digest ~disk path
          | Some _ -> (match file_bytes ~disk path with Some bytes -> hash bytes | None -> raise (Unobservable path)) in
        let excluded_set = Path_set.of_list excluded in
        let walk ~disk = walk_all ~disk ~digest:(digest ~disk) ~excluded:excluded_set trees in
        [{trees;excluded;source_walk=walk ~disk:false;disk_walk=walk ~disk:true}] in
    {root;documents;edits=List.rev edits;files=List.rev files;directories;imports;history} in
  let scope = Option.map (fun h ->
    let trees = List.sort_uniq String.compare h.history_trees in
    List.iter (fun tree ->
      canonical root tree;
      if tree = root || List.exists (fun other -> other <> tree && (inside_tree other tree || inside_tree tree other)) trees then
        reject tree "history trees must be distinct directories inside the project") trees;
    h,trees) history in
  (* A symbolic link or special file inside a tree cannot be observed by a walk:
     then every input keeps its own guard. *)
  let t = match build scope with
    | t -> t
    | exception Unobservable _ when scope <> None -> build None in
  let t = with_exclusions t in
  (* Catch a changed earlier input before publishing the proposal. Apply must
     check again; this is a precondition snapshot, not a filesystem transaction. *)
  if observed=None then (verify_files t false; verify_files ~quick:true t true); t)
let create = create_with ~history:None ~observed:None
let create_observed observed = create_with ~history:None ~observed:(Some observed)
let create_scoped history = create_with ~history ~observed:None
let create_observed_scoped history observed = create_with ~history ~observed:(Some observed)

(** Combine independently computed operations without taking a new snapshot of
    their inputs. Re-capturing after target selection could bless changed source
    while retaining the old selection. Conflicting preconditions must refuse. *)
module Import_paths = Map.Make(struct type t = string * string let compare = compare end)
type accumulator = {
  combine_root : string;
  combine_documents : document list;
  combine_files : file_guard Paths.t;
  combine_directories : directory_guard Paths.t;
  combine_imports : import_guard Import_paths.t;
  combine_edits : edit Paths.t;
  combine_history : history_guard list;
}

(* Deduplicate original observations as they arrive, including repeated directory
   listings. No input is recaptured or replaced by a later observation. *)
let merge_observations accumulator (manifest : t) =
  if manifest.root <> accumulator.combine_root then
    reject manifest.root "cannot combine manifests from different projects";
  if manifest.documents <> accumulator.combine_documents then
    reject manifest.root "open document set or version changed between previews";
  let add_paths label key location observations entries =
    List.fold_left (fun entries observation ->
      Paths.update (key observation) (function
        | None -> Some observation
        | Some previous when previous = observation -> Some previous
        | Some _ -> reject (location observation) ("conflicting " ^ label ^ " between previews")) entries
    ) entries observations in
  let combine_files = add_paths "source precondition" (fun g -> g.file) (fun g -> g.file)
      manifest.files accumulator.combine_files in
  let combine_directories = add_paths "directory precondition" (fun g -> g.directory) (fun g -> g.directory)
      manifest.directories accumulator.combine_directories in
  let combine_imports = List.fold_left (fun entries guard ->
    Import_paths.update (guard.source,guard.name) (function
      | None -> Some guard
      | Some previous when previous = guard -> Some previous
      | Some _ -> reject guard.source "conflicting import precondition between previews") entries
    ) accumulator.combine_imports manifest.imports in
  let combine_edits = add_paths "source edit" (fun (e : edit) -> e.path) (fun e -> e.path)
      manifest.edits accumulator.combine_edits in
  (* The same trees must carry the same walks; their exclusions are united and
     rechecked against those walks when the union is finished. *)
  let combine_history = List.fold_left (fun histories (h : history_guard) ->
    let overlaps (other : history_guard) = List.exists (fun a -> List.exists (fun b ->
      a = b || inside_tree a b || inside_tree b a) other.trees) h.trees in
    match List.partition (fun (other : history_guard) -> other.trees = h.trees) histories with
    | [previous],rest when previous.source_walk = h.source_walk && previous.disk_walk = h.disk_walk ->
      {previous with excluded=List.sort_uniq String.compare (previous.excluded @ h.excluded)} :: rest
    | [],_ when not (List.exists overlaps histories) -> h :: histories
    | _ -> reject (List.hd h.trees) "conflicting history precondition between previews") accumulator.combine_history manifest.history in
  {accumulator with combine_files;combine_directories;combine_imports;combine_edits;combine_history}

let initial_observations (first : t) ~documents =
  let documents = normalized_documents first.root documents in
  merge_observations {
    combine_root=first.root;combine_documents=documents;
    combine_files=Paths.empty;combine_directories=Paths.empty;
    combine_imports=Import_paths.empty;combine_edits=Paths.empty;combine_history=[]
  } first

let verify_observations accumulator =
  let combined = {
    root=accumulator.combine_root;documents=accumulator.combine_documents;
    files=List.map snd (Paths.bindings accumulator.combine_files);
    directories=List.map snd (Paths.bindings accumulator.combine_directories);
    imports=List.map snd (Import_paths.bindings accumulator.combine_imports);
    edits=List.map snd (Paths.bindings accumulator.combine_edits);
    history=List.sort (fun (a : history_guard) b -> compare a.trees b.trees) accumulator.combine_history
  } |> with_exclusions in
  let overlay_root = Option.value (Source_input.project_root ()) ~default:combined.root in
  Source_input.with_overlays ~project_root:overlay_root (overlays combined) (fun () -> ());
  verify_files combined false; verify_files ~quick:true combined true;
  combined

let start_combine first ~documents = protect (fun () -> initial_observations first ~documents)
let add_to_combine accumulator manifest = protect (fun () -> merge_observations accumulator manifest)
let finish_combine accumulator = protect (fun () -> verify_observations accumulator)
let combine_many manifests ~documents = protect (fun () ->
  match manifests with
  | [] -> reject "" "cannot combine an empty manifest list"
  | first :: rest -> verify_observations
    (List.fold_left merge_observations (initial_observations first ~documents) rest))
let combine left right ~documents = combine_many [left;right] ~documents

(* Kept independent of Compile so compiler-owned generators can use manifests
   without introducing a compilation pipeline dependency cycle. *)
let quote value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter (function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | c when Char.code c < 0x20 -> Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buffer c) value;
  Buffer.add_char buffer '"'; Buffer.contents buffer
let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"
let object_ xs = "{" ^ String.concat "," (List.map (fun (k,v) -> quote k ^ ":" ^ v) xs) ^ "}"
let nullable f = function None -> "null" | Some x -> f x
let hex bytes =
  let result = Bytes.create (String.length bytes * 2) in
  String.iteri (fun i c ->
    let n = Char.code c in
    Bytes.set result (2*i) "0123456789abcdef".[n lsr 4];
    Bytes.set result (2*i+1) "0123456789abcdef".[n land 15]) bytes;
  Bytes.unsafe_to_string result
let directory_hash names = hash ("tesl-directory-v1\000" ^ String.concat "\000" names ^ "\000")
let to_json t = object_ [
  "version","2"; "projectRoot",quote t.root;
  "documents",array (fun (d : document) -> object_ ["path",quote d.path;"version",string_of_int d.version]) t.documents;
  "imports",array (fun g -> object_ ["source",quote g.source;"module",quote g.name;
    "sourceResolved",quote g.source_path;"diskResolved",quote g.disk_path]) t.imports;
  "inputs",array (fun g -> object_ ["path",quote g.file;"sourceHash",nullable quote g.source_digest;"diskHash",nullable quote g.disk_digest]) t.files;
  "directories",array (fun g -> object_ ["path",quote g.directory;"sourceHash",nullable (fun names -> quote (directory_hash names)) g.source_names;
    "diskHash",nullable (fun names -> quote (directory_hash names)) g.disk_names]) t.directories;
  "history",array (fun h -> object_ ["trees",array quote h.trees;"excluded",array quote h.excluded;
    "sourceHash",quote (history_digest t.root h.excluded h.source_walk);
    "diskHash",quote (history_digest t.root h.excluded h.disk_walk)]) t.history;
  "edits",array (fun (e : edit) -> object_ ["path",quote e.path;"beforeHex",nullable (fun bytes -> quote (hex bytes)) e.before;
    "afterHex",quote (hex e.after);"documentVersion",nullable string_of_int e.document_version]) t.edits]
let digest t = hash (to_json t)
