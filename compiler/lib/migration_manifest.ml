module Paths = Map.Make(String)
type document = { path : string; version : int }
type edit = { path : string; before : string option; after : string; document_version : int option }
type error = { path : string; message : string }
type file_guard = { file : string; source_digest : string option; disk_digest : string option }
type directory_guard = { directory : string; source_names : string list option; disk_names : string list option }
type import_guard = { source : string; name : string; source_path : string; disk_path : string }
type t = { root : string; documents : document list; edits : edit list;
           files : file_guard list; directories : directory_guard list; imports : import_guard list }
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
let kind ~disk path = if disk then (Unix.lstat path).Unix.st_kind else Source_input.kind path
let file_bytes ~disk path =
  match optional (fun () -> kind ~disk path) with
  | None -> None
  | Some Unix.S_REG -> Some (if disk then In_channel.with_open_bin path In_channel.input_all else Source_input.read path)
  | Some _ -> reject path "manifest source must be a regular file"
let names ~disk path =
  match optional (fun () -> kind ~disk path) with
  | None -> None
  | Some Unix.S_DIR ->
    Some ((if disk then Sys.readdir path else Source_input.readdir path) |> Array.to_list |> List.sort String.compare)
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
     Unix.realpath root <> root || (Unix.lstat root).Unix.st_kind <> Unix.S_DIR then
    reject root "manifest project root must be an existing canonical directory"
let resolve ~disk source name =
  if disk then Validation_common.resolve_local_import_path_with ~exists:Sys.file_exists ~realpath:Unix.realpath source name
  else Validation_common.resolve_local_import_path source name
let verify_files t disk =
  validate_root t.root;
  List.iter (fun guard ->
    let expected = if disk then guard.disk_path else guard.source_path in
    if resolve ~disk guard.source guard.name <> expected then
      reject guard.source ("import resolution changed since preview: " ^ guard.name)) t.imports;
  List.iter (fun guard ->
    canonical t.root guard.file;
    let expected = if disk then guard.disk_digest else guard.source_digest in
    if Option.map hash (file_bytes ~disk guard.file) <> expected then
      reject guard.file (if disk then "saved source changed since preview" else "source view changed since preview")) t.files;
  List.iter (fun guard ->
    canonical t.root guard.directory;
    let expected = if disk then guard.disk_names else guard.source_names in
    if names ~disk guard.directory <> expected then
      reject guard.directory (if disk then "saved directory membership changed since preview" else "source directory membership changed since preview")) t.directories
let verify_source t ~documents = protect (fun () ->
  let documents = normalized_documents t.root documents in
  if documents <> t.documents then reject t.root "open document set or version changed since preview";
  verify_files t false)
let verify_disk t = protect (fun () -> verify_files t true)
let create ~project_root:root ~reads ~directories ~imports ~documents ~writes = protect (fun () ->
  validate_root root;
  let documents = normalized_documents root documents in
  let imports = List.sort_uniq compare imports |> List.map (fun (source,name) ->
    canonical root source;
    if not (String.is_valid_utf_8 name) then reject source "import names must be valid UTF-8";
    {source;name;source_path=resolve ~disk:false source name;disk_path=resolve ~disk:true source name}) in
  let writes = List.fold_left (fun map (path,source) ->
    canonical root path;
    if not (Filename.check_suffix path ".tesl") then reject path "migration source edits must target .tesl files";
    if Paths.mem path map then reject path "duplicate output path";
    Paths.add path source map) Paths.empty writes in
  let overlay_root = Option.value (Source_input.project_root ()) ~default:root in
  Source_input.with_overlays ~project_root:overlay_root (Paths.bindings writes) (fun () -> ());
  let paths = reads @ List.map fst (Paths.bindings writes) @ List.map (fun (d : document) -> d.path) documents @
    List.concat_map (fun g -> [g.source;g.source_path;g.disk_path]) imports
    |> List.sort_uniq String.compare in
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
  let t = {root;documents;edits=List.rev edits;files=List.rev files;directories;imports} in
  (* Catch a changed earlier input before publishing the proposal. Apply must
     check again; this is a precondition snapshot, not a filesystem transaction. *)
  verify_files t false; verify_files t true; t)

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
  "version","1"; "projectRoot",quote t.root;
  "documents",array (fun (d : document) -> object_ ["path",quote d.path;"version",string_of_int d.version]) t.documents;
  "imports",array (fun g -> object_ ["source",quote g.source;"module",quote g.name;
    "sourceResolved",quote g.source_path;"diskResolved",quote g.disk_path]) t.imports;
  "inputs",array (fun g -> object_ ["path",quote g.file;"sourceHash",nullable quote g.source_digest;"diskHash",nullable quote g.disk_digest]) t.files;
  "directories",array (fun g -> object_ ["path",quote g.directory;"sourceHash",nullable (fun names -> quote (directory_hash names)) g.source_names;
    "diskHash",nullable (fun names -> quote (directory_hash names)) g.disk_names]) t.directories;
  "edits",array (fun (e : edit) -> object_ ["path",quote e.path;"beforeHex",nullable (fun bytes -> quote (hex bytes)) e.before;
    "afterHex",quote (hex e.after);"documentVersion",nullable string_of_int e.document_version]) t.edits]
let digest t = hash (to_json t)
