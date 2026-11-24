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

(* Inside [with_path_memo], the canonical spelling of a directory is computed
   once: an entry that is not a symlink (nor "." or "..") resolves to its
   parent's canonical spelling plus its own name, exactly as realpath answers.
   A memo lives only for one bounded judgment (one discovery or one trust
   decision); the final source guards run outside it. *)
type path_table = (string, (string, Unix.error) result) Hashtbl.t
let path_memo : path_table option ref = ref None
(* Inside [with_scope_path_memo], each source view (by its identity, see
   [view_token] below) keeps one table for the whole scope. *)
let scope_memo_active = ref false
(* Set below, once views have identities: the current view's scope table. *)
let scope_table : (unit -> path_table) ref = ref (fun () -> Hashtbl.create 1)
let with_path_memo f = match !path_memo with
  | Some _ -> f ()
  | None when !scope_memo_active -> f ()
  | None ->
    path_memo := Some (Hashtbl.create 64);
    Fun.protect ~finally:(fun () -> path_memo := None) f
(* Inside [with_scope_path_memo] (one compilation), disk answers are also
   memoized: a file's bytes, an lstat and a directory listing are read from
   disk once per compilation and then shared by every source view (overlays and
   pinned resources still take precedence). An edit made on disk while the
   compilation runs is therefore not seen by its intermediate judgments; the
   final guards observe disk anew ([with_fresh_path_memo], and the manifest's
   direct disk verification) before anything is written or reported as
   checked. *)
let fresh_depth = ref 0
let reset_presence = ref (fun () -> ())
let presence_changed = ref (fun () -> false)
let disk_bytes : (string, (string, exn) result) Hashtbl.t = Hashtbl.create 256
let disk_text : (string, (string, exn) result) Hashtbl.t = Hashtbl.create 16
let disk_lstat : (string, (Unix.stats, exn) result) Hashtbl.t = Hashtbl.create 256
let disk_listing : (string, (string array, exn) result) Hashtbl.t = Hashtbl.create 16
let disk_memo_active () = !scope_memo_active && !fresh_depth = 0
let memo_disk table f path =
  if not (disk_memo_active ()) then f path else
  let result = match Hashtbl.find_opt table path with
    | Some result -> result
    | None ->
      let result = try Ok (f path) with (Sys_error _ | Unix.Unix_error _) as error -> Error error in
      Hashtbl.replace table path result; result in
  match result with Ok value -> value | Error error -> raise error
let lstat = memo_disk disk_lstat Unix.lstat
(* Counts the resets of the disk memo: answers memoized in one epoch are
   constant until the next reset. *)
let disk_epoch = ref 0
(* Forget every memoized disk answer: the next observation reads disk anew. *)
let reset_disk_memo () =
  incr disk_epoch;
  Hashtbl.reset disk_bytes; Hashtbl.reset disk_text; Hashtbl.reset disk_lstat; Hashtbl.reset disk_listing;
  !reset_presence ()
(* Whether any memoized disk answer differs from what disk answers now. A
   command that publishes a result computed from memoized answers calls this
   (its final guard) and, when it reports a change, forgets them and computes
   again. *)
let disk_changed () =
  let fresh f path = try Ok (f path) with (Sys_error _ | Unix.Unix_error _) as error -> Error error in
  let same_error a b = Printexc.to_string a = Printexc.to_string b in
  let differs table f equal =
    Hashtbl.fold (fun path recorded changed -> changed ||
      match recorded, fresh f path with
      | Ok a, Ok b -> not (equal a b)
      | Error a, Error b -> not (same_error a b)
      | _ -> true) table false in
  let stat_equal (a : Unix.stats) (b : Unix.stats) =
    a.st_kind = b.st_kind && a.st_ino = b.st_ino && a.st_dev = b.st_dev && a.st_size = b.st_size in
  differs disk_bytes (fun path -> In_channel.with_open_bin path In_channel.input_all) String.equal ||
  differs disk_text (fun path -> In_channel.with_open_text path In_channel.input_all) String.equal ||
  differs disk_lstat Unix.lstat stat_equal ||
  (* Listings are compared on the entries the compiler can read (sources,
     checkpoints and extensionless directories); unrelated files appearing in a
     shared directory (a temporary directory, an editor's swap files) do not
     invalidate the answer. *)
  let relevant names = Array.to_list names |> List.filter (fun name ->
    Filename.check_suffix name ".tesl" || Filename.check_suffix name ".checkpoint" ||
    not (String.contains name '.')) |> List.sort String.compare in
  differs disk_listing Sys.readdir (fun a b -> relevant a = relevant b) ||
  !presence_changed ()
let with_fresh_path_memo f =
  let previous = !path_memo in
  path_memo := Some (Hashtbl.create 64);
  incr fresh_depth;
  Fun.protect ~finally:(fun () -> decr fresh_depth; path_memo := previous) f
let scope_resets : (unit -> unit) list ref = ref [reset_disk_memo]
let in_scope () = !scope_memo_active
let memoizing () = disk_memo_active ()
let on_scope_exit reset = scope_resets := reset :: !scope_resets
let with_scope_path_memo f =
  if !scope_memo_active then f () else begin
    scope_memo_active := true;
    Fun.protect ~finally:(fun () -> scope_memo_active := false; List.iter (fun reset -> reset ()) !scope_resets) f
  end
let active_table () = match !path_memo with
  | Some table -> Some table
  | None -> if !scope_memo_active then Some (!scope_table ()) else None
(* A path whose own lstat fails cannot resolve either: realpath reports the
   same error for it. *)
let rec real path = match active_table () with
  | None -> Unix.realpath path
  | Some memo ->
    let resolved = match Hashtbl.find_opt memo path with
      | Some resolved -> resolved
      | None ->
        let name = Filename.basename path and parent = Filename.dirname path in
        let resolved =
          (* On Windows a component can be an 8.3 short name (RUNNER~1) that
             realpath expands, so parent-plus-name is not realpath's answer
             there: resolve the whole path. *)
          (* A filesystem root is its own canonical spelling (realpath "/" = "/");
             the browser's virtual filesystem has no entry for it to resolve. *)
          if parent = path && not (Filename.is_relative path) && not Sys.win32 then Ok path
          else if Sys.win32 || Filename.is_relative path || parent = path || name = "." || name = ".." || name = "" then
            (try Ok (Unix.realpath path) with Unix.Unix_error (error, _, _) -> Error error)
          else match lstat path with
            | { Unix.st_kind = Unix.S_LNK; _ } -> (try Ok (Unix.realpath path) with Unix.Unix_error (error, _, _) -> Error error)
            | _ -> (match real parent with
                | resolved_parent -> Ok (Filename.concat resolved_parent name)
                | exception Unix.Unix_error _ -> (try Ok (Unix.realpath path) with Unix.Unix_error (error, _, _) -> Error error))
            | exception Unix.Unix_error (error, _, _) -> Error error in
        Hashtbl.replace memo path resolved; resolved in
    match resolved with
    | Ok resolved -> resolved
    | Error error -> raise (Unix.Unix_error (error, "realpath", path))

(* realpath also handles aliases of existing paths. For a proposed file, resolve
   its nearest existing ancestor before appending missing components. Do not
   collapse '..' before resolving symlinks: that changes filesystem semantics. *)
let rec proposed_path path =
  try real path with
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
  match lstat path with
  | info when info.Unix.st_kind = Unix.S_DIR && real path = path -> ()
  | _ -> invalid path "parent must be a canonical directory"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname path in
    if parent = path then invalid path "missing filesystem root";
    validate_parent parent

let validate_file path =
  let checked () =
    validate_parent (Filename.dirname path);
    match lstat path with
    | info when info.Unix.st_kind = Unix.S_REG && real path = path -> ()
    | _ -> invalid path "input must be a canonical regular file"
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> () in
  (* An existing regular file whose real path is its own spelling has a
     canonical directory parent; anything else takes the full check, which
     also reports which part failed. *)
  match lstat path with
  | info when info.Unix.st_kind = Unix.S_REG && real path = path -> ()
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

(* A copy: callers may sort the array they receive. *)
let listing path = Array.copy (memo_disk disk_listing Sys.readdir path)

type entry = File of string | Directory
(* Set below: records that a lookup went through another spelling. *)
let observe_alias = ref (fun () -> ())

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
        (match lstat path with
         | info -> info.Unix.st_kind <> Unix.S_LNK
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
         | exception Unix.Unix_error _ -> false) in
      if not (Names.mem name view.basenames) && unaliased () then None else
      let canonical = try proposed_path path with Unix.Unix_error _ | Sys_error _ -> path in
      if canonical = path then None else (!observe_alias (); lookup canonical)

let find path =
  (* Pinned compiler resources are immutable input bytes, independently of the
     application's overlay root. Their resolver is fixed by the caller too. *)
  match Paths.find_opt path !pinned_files with
  | Some contents -> Some (File contents)
  | None -> find_project path

(* What a judgment observed of the filesystem through this module, with the
   answer it got (see [recording]). An exception is kept as its text. *)
type observation =
  | Read of string * string
  | Exists of string * bool
  | Kind of string * string
  | Real of string * string
  | Listing of string * string
  (* An observation that [same_reads] may not take as unchanged on its own: made
     while disk answers were not memoized, or through an aliased spelling. *)
  | Unindexed
let recorders : observation list ref list ref = ref []
let observe make = if !recorders <> [] then begin
    let observation = make () in
    let indexed = disk_memo_active () in
    List.iter (fun recorder -> recorder := observation :: (if indexed then !recorder else Unindexed :: !recorder)) !recorders end
let () = observe_alias := (fun () -> List.iter (fun recorder -> recorder := Unindexed :: !recorder) !recorders)
let outcome f = match f () with
  | value -> Ok value
  | exception (Sys_error _ | Unix.Unix_error _ | Invalid_argument _ as error) -> Error error
let answer show = function Ok value -> "=" ^ show value | Error error -> "!" ^ Printexc.to_string error
let recorded show path make f =
  let result = outcome f in
  observe (fun () -> make path (answer show result));
  match result with Ok value -> value | Error error -> raise error
let read_using disk path =
  let contents = match find path with
    | Some (File contents) -> contents
    | Some Directory -> raise (Sys_error (path ^ ": is a directory"))
    | None -> disk path in
  observe (fun () -> Read (path, contents));
  contents
let read = read_using (memo_disk disk_bytes (fun path -> In_channel.with_open_bin path In_channel.input_all))
let read_text = read_using (memo_disk disk_text (fun path -> In_channel.with_open_text path In_channel.input_all))
(* Disk existence answers share the canonical-spelling memo (see [real]). *)
let disk_presence : (string, (bool, exn) result) Hashtbl.t = Hashtbl.create 256
let () = reset_presence := (fun () -> Hashtbl.reset disk_presence);
  presence_changed := (fun () -> Hashtbl.fold (fun path recorded changed -> changed ||
    recorded <> Ok (Sys.file_exists path)) disk_presence false)
let disk_exists path = match active_table () with
  | None -> Sys.file_exists path
  | Some _ when disk_memo_active () -> memo_disk disk_presence Sys.file_exists path
  | Some memo ->
    let key = "\001" ^ path in
    match Hashtbl.find_opt memo key with
    | Some (Ok answer) -> answer = "1"
    | _ -> let answer = Sys.file_exists path in Hashtbl.replace memo key (Ok (if answer then "1" else "0")); answer
let exists path =
  let answer = match find path with Some _ -> true | None -> disk_exists path in
  observe (fun () -> Exists (path, answer)); answer
let is_directory path = match find path with
  | Some Directory -> true | Some (File _) -> false | None -> Sys.is_directory path
let kind_name = function
  | Unix.S_REG -> "reg" | Unix.S_DIR -> "dir" | Unix.S_CHR -> "chr" | Unix.S_BLK -> "blk"
  | Unix.S_LNK -> "lnk" | Unix.S_FIFO -> "fifo" | Unix.S_SOCK -> "sock"
let rec kind path = recorded kind_name path (fun path answer -> Kind (path, answer)) (fun () -> kind_unrecorded path)
and kind_unrecorded path = match find path with
  | None -> (lstat path).Unix.st_kind
  | Some entry ->
    let virtual_kind = match entry with Directory -> Unix.S_DIR | File _ -> Unix.S_REG in
    (* This operation has lstat semantics. Reading a symlink alias may resolve
       a buffer, but that must never turn a symlink into a regular freeze target. *)
    (match lstat path with
     | info when info.Unix.st_kind = Unix.S_LNK -> Unix.S_LNK
     | _ -> virtual_kind
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> virtual_kind)
let realpath path = recorded Fun.id path (fun path answer -> Real (path, answer)) (fun () ->
  match find path with
  | Some _ -> proposed_path path | None -> real path)

let rec readdir path = recorded (fun names -> String.concat "\000" (Array.to_list names)) path
    (fun path answer -> Listing (path, answer)) (fun () -> readdir_unrecorded path)
and readdir_unrecorded path = match !active, find path with
  | None, _ | Some _, None -> listing path
  | Some _, Some (File _) -> raise (Sys_error (path ^ ": not a directory"))
  | Some view, Some Directory ->
    let canonical = proposed_path path in
    let disk =
      match lstat canonical with
      | _ -> listing path
      | exception Unix.Unix_error (Unix.ENOENT, _, _) when Names.mem canonical view.directories -> [||] in
    let names = Array.fold_left (fun set name -> Names.add name set) Names.empty disk in
    Names.union names (Option.value ~default:Names.empty (Paths.find_opt canonical view.children))
    |> Names.elements |> Array.of_list

module Disk = struct
  let lstat = lstat
  let read = memo_disk disk_bytes (fun path -> In_channel.with_open_bin path In_channel.input_all)
  let readdir = listing
  let exists path = if disk_memo_active () then memo_disk disk_presence Sys.file_exists path else Sys.file_exists path
  (* The memo holds one spelling table per source view; disk spellings do not
     depend on the view, so the table of no view is used. *)
  let realpath path = if disk_memo_active () then real path else Unix.realpath path
end

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
(* With the disk-memo epoch it was taken in: the same view in a later epoch may
   observe other disk bytes. *)
type view_token = view option * string Paths.t * int
let raw_token () : view_token = (!active, !pinned_files, !disk_epoch)
(* Scopes that only freeze bytes the enclosing view already supplied observe
   what that view observes; each such scope's token is declared equivalent to
   the enclosing one (see [with_equivalent_view]), so judgments verified there
   are reused instead of verified again. *)
let equivalents : (view_token * view_token) list ref = ref []
let same_raw ((v1, p1, e1) : view_token) ((v2, p2, e2) : view_token) = v1 == v2 && p1 == p2 && e1 = e2
let canonical_token token =
  match List.find_opt (fun (alias, _) -> same_raw alias token) !equivalents with
  | Some (_, canonical) -> canonical | None -> token
let view_token () : view_token = canonical_token (raw_token ())
let scope_tables : (view_token * path_table) list ref = ref []
let () =
  scope_resets := (fun () -> scope_tables := []) :: !scope_resets;
  scope_table := (fun () ->
    let token = view_token () in
    match List.find_opt (fun (t, _) -> same_raw t token) !scope_tables with
    | Some (_, table) -> table
    | None ->
      let table = Hashtbl.create 256 in
      scope_tables := (token, table) :: List.filteri (fun i _ -> i < 7) !scope_tables;
      table)
let same_view token = same_raw (canonical_token token) (view_token ())
(* Answers derived only from observations of one source view (for example an
   import's resolved path), memoized per view for the compilation scope while
   disk answers are memoized; outside that, always computed. A memoized answer
   replays its observations to every judgment recording them (see [recording]). *)
let view_memos : (view_token * (string, string * observation list) Hashtbl.t) list ref = ref []
let () = scope_resets := (fun () -> view_memos := []) :: !scope_resets
let same_reads_in : (view_token -> observation list -> bool) ref = ref (fun _ _ -> false)
let memo_in_view key compute =
  if not (disk_memo_active ()) || !path_memo <> None then compute () else
  let token = view_token () in
  let table = match List.find_opt (fun (t, _) -> same_raw t token) !view_memos with
    | Some (_, table) -> table
    | None ->
      let table = Hashtbl.create 256 in
      view_memos := (token, table) :: List.filteri (fun i _ -> i < 15) !view_memos;
      table in
  (* An answer of another view holds here when its observations do. *)
  let elsewhere () = List.find_map (fun (other, table) ->
    if same_raw other token then None else
    match Hashtbl.find_opt table key with
    | Some (_, observations) as found when !same_reads_in other observations -> found
    | _ -> None) !view_memos in
  match (match Hashtbl.find_opt table key with Some _ as found -> found | None ->
    let found = elsewhere () in Option.iter (Hashtbl.replace table key) found; found) with
  | Some (answer, observations) ->
    (* A judgment recording its observations sees the ones this answer made. *)
    List.iter (fun recorder -> recorder := List.rev_append observations !recorder) !recorders;
    answer
  | None ->
    let recorder = ref [] in
    recorders := recorder :: !recorders;
    let answer = Fun.protect ~finally:(fun () -> recorders := List.filter (fun r -> r != recorder) !recorders) compute in
    Hashtbl.replace table key (answer, List.rev !recorder); answer

let with_equivalent_view parent f =
  let token = raw_token () in
  if same_raw token parent then f () else begin
    let previous = !equivalents in
    equivalents := (token, canonical_token parent) :: previous;
    Fun.protect ~finally:(fun () -> equivalents := previous) f
  end

let recorded_answer show f = answer show (outcome f)
(* Run [f] without recording its observations into the judgments recording
   around it (a recording started inside [f] still sees its own). *)
let unrecorded f =
  let saved = !recorders in
  recorders := [];
  Fun.protect ~finally:(fun () -> recorders := saved) f
let recording f =
  let recorder = ref [] in
  recorders := recorder :: !recorders;
  let result = Fun.protect ~finally:(fun () -> recorders := List.filter (fun r -> r != recorder) !recorders) f in
  result, List.rev !recorder

(* Whether a judgment whose only filesystem observations through this module
   were [observations] observes the same inputs in the current view: every
   observation, repeated now, gets the same answer (equal bytes for a read). *)
let replay = function
    | Read (path, bytes) ->
      (match read path with
       | current -> current == bytes || String.equal current bytes
       | exception (Sys_error _ | Unix.Unix_error _ | Invalid_argument _) -> false)
    | Exists (path, answer) -> exists path = answer
    | Kind (path, answer) -> recorded_answer kind_name (fun () -> kind path) = answer
    | Real (path, answer) -> recorded_answer Fun.id (fun () -> realpath path) = answer
    | Listing (path, answer) ->
      recorded_answer (fun names -> String.concat "\000" (Array.to_list names)) (fun () -> readdir path) = answer
    | Unindexed -> true

(* The paths whose answers can differ between the view of [token] and the
   current one, within one disk-memo epoch: every file the two views supply
   differently (a view file whose bytes equal the regular file on disk supplies
   nothing new), every directory only one of them creates, and their ancestors;
   with the final names of those paths (a lookup of another spelling of them
   may resolve to them). *)
let view_difference ((view, pinned, _) : view_token) =
  let files = function None -> Paths.empty | Some v -> v.files in
  let directories = function None -> Names.empty | Some v -> v.directories in
  let disk_regular path bytes =
    (match lstat path with { Unix.st_kind = Unix.S_REG; _ } -> true | _ -> false | exception Unix.Unix_error _ -> false) &&
    (match memo_disk disk_bytes (fun path -> In_channel.with_open_bin path In_channel.input_all) path with
     | disk -> String.equal disk bytes | exception (Sys_error _ | Unix.Unix_error _) -> false) in
  (* A pinned resource shadows a view file of the same path: it supplies
     nothing new only where neither view has a file. *)
  let differing ~transparent a b =
    Paths.merge (fun path x y -> match x, y with
      | Some x, Some y when x == y || String.equal x y -> None
      | Some x, None | None, Some x when transparent path && disk_regular path x -> None
      | None, None -> None
      | _ -> Some ()) a b in
  let unshadowed path = not (Paths.mem path (files view) || Paths.mem path (files !active)) in
  let changed = Paths.union (fun _ () () -> Some ()) (differing ~transparent:(fun _ -> true) (files view) (files !active))
    (differing ~transparent:unshadowed pinned !pinned_files) in
  let paths = Paths.fold (fun path () set -> Names.add path set) changed Names.empty
    |> Names.union (Names.diff (directories view) (directories !active))
    |> Names.union (Names.diff (directories !active) (directories view)) in
  let rec ancestors path set =
    let parent = Filename.dirname path in
    if parent = path || Names.mem parent set then set else ancestors parent (Names.add parent set) in
  let all = Names.fold ancestors paths paths in
  all, Names.map Filename.basename paths

(* Few distinct pairs of views meet within one command. *)
let differences : (view_token * view_token * (Names.t * Names.t)) list ref = ref []
let () = scope_resets := (fun () -> differences := []) :: !scope_resets
let view_difference token =
  let current = raw_token () in
  match List.find_opt (fun (t, c, _) -> same_raw t token && same_raw c current) !differences with
  | Some (_, _, difference) -> difference
  | None ->
    let difference = view_difference token in
    differences := (token, current, difference) :: List.filteri (fun i _ -> i < 15) !differences;
    difference

let same_reads token observations =
  let (_, _, epoch) = token in
  if epoch = !disk_epoch && disk_memo_active () && not (List.mem Unindexed observations) then begin
    (* Every observation held in [token]'s view in this epoch; only those the
       views can answer differently are asked again. *)
    let paths, names = view_difference token in
    if Names.is_empty paths then true else
    let affected path = Names.mem path paths || Names.mem (Filename.basename path) names in
    List.for_all (fun observation -> match observation with
      | Read (path, _) | Exists (path, _) | Kind (path, _) | Real (path, _) | Listing (path, _) ->
        not (affected path) || replay observation
      | Unindexed -> true) observations
  end else List.for_all replay observations

let () = same_reads_in := same_reads

let has_pinned_files () = not (Paths.is_empty !pinned_files)
