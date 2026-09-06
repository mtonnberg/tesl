module P = Migration_preview
module T = Migration_target
module M = Migration_manifest
type response = { stdout : string; stderr : string; exit_code : int }
let usage = {|Usage: tesl migrate generate <entry.tesl> --manifest-json [--database D] [--new-revision]
       [--project-root DIR] [--overlay FILE VERSION CONTENTS_FILE ...]
       tesl migrate plan <entry.tesl> [--database D] [--initial-version N] [--project-root DIR]

Return a guarded source preview without writing files or connecting to a database.
Generation refreshes an existing revision; --new-revision freezes the current one.
The JSON reports complete application diagnostics and whether the proposal compiles.
Editor overlays require --project-root and one saved contents file per open document.
Use the native tesl CLI for guarded source writes and interrupted-source recovery.
plan reports PostgreSQL expansion and retained storage across the checked history.
--initial-version selects the first installed revision (default 1), not the current floor.
Database execution is not yet available.
|}
exception Invalid of P.error list
exception Plan_invalid of Migration_sparse.error list
let reject path message = raise (Invalid [{P.loc=Location.dummy_loc path;message;candidates=[]}])
let target = function Ok x -> x | Error errors -> raise (Invalid (List.map (fun (e : T.error) ->
  {P.loc=e.loc;message=e.message;candidates=e.candidates}) errors))
let preview = function Ok x -> x | Error errors -> raise (Invalid errors)
(* Accept normal shell spellings such as ./app.tesl, while checking every path
   component before normalising. realpath alone would hide a selected symlink,
   including an alias followed by .. that later returns to the original tree. *)
let path spelling =
  if spelling="" || String.contains spelling '\000' || not (String.is_valid_utf_8 spelling) then
    reject "" "source paths must be nonempty UTF-8 without NUL";
  let absolute = if Filename.is_relative spelling then Filename.concat (Sys.getcwd ()) spelling else spelling in
  let rec walk file =
    let parent = Filename.dirname file in
    if parent=file then file else
    let parent = walk parent in
    (match Source_input.kind parent with Unix.S_DIR -> () | _ -> reject parent "source parent must be a directory");
    let name = Filename.basename file in
    if name="." then parent else if name=".." then Filename.dirname parent else
    let result = Filename.concat parent name in
    (match Source_input.kind result with
     | Unix.S_LNK -> reject result "migration source selection does not follow symbolic links"
     | _ -> ()
     | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ());
    result in
  walk absolute
type options = {entry:string;database:string option;new_revision:bool;root:string option;plan:bool;initial_version:int;
                overlays:(string * int * string) list}
let parse args =
  let entry = ref None and database = ref None and root = ref None and initial_version = ref None in
  let new_revision = ref false and json = ref false and overlays = ref [] in
  let set flag cell value =
    if !cell<>None then reject "" ("duplicate " ^ flag);
    if value="" || String.starts_with ~prefix:"--" value then reject "" (flag ^ " requires a value");
    cell := Some value in
  let flag name cell = if !cell then reject "" ("duplicate " ^ name); cell := true in
  let rec loop = function
    | [] -> ()
    | "--manifest-json" :: rest -> flag "--manifest-json" json; loop rest
    | "--new-revision" :: rest -> flag "--new-revision" new_revision; loop rest
    | "--database" :: value :: rest -> set "--database" database value; loop rest
    | "--project-root" :: value :: rest -> set "--project-root" root value; loop rest
    | "--initial-version" :: value :: rest -> set "--initial-version" initial_version value; loop rest
    | "--overlay" :: file :: version :: contents :: rest ->
      let version = match Int64.of_string_opt version with
        | Some n when n >= -2147483648L && n <= 2147483647L -> Int64.to_int n
        | _ -> reject file "overlay version must be a signed 32-bit integer" in
      overlays := (file,version,contents) :: !overlays; loop rest
    | "--" :: [file] -> set "entry file" entry file
    | arg :: _ when String.starts_with ~prefix:"-" arg -> reject "" ("unknown or incomplete migration option: " ^ arg)
    | file :: rest -> set "entry file" entry file; loop rest in
  let plan = match args with
   | "generate" :: rest -> loop rest; false
   | "plan" :: rest -> loop rest; true
   | _ -> reject "" "expected migration verb generate or plan" in
  if plan && (!json || !new_revision) then reject "" "plan does not accept --manifest-json or --new-revision";
  if not plan && !initial_version<>None then reject "" "--initial-version applies only to plan";
  let initial_version = match !initial_version with
    | None -> 1
    | Some value -> (match int_of_string_opt value with
      | Some n when n>=1 && n<=2147483646 && string_of_int n=value -> n
      | _ -> reject "" "--initial-version must be a canonical decimal integer between 1 and 2147483646") in
  if not plan && not !json then reject "" "this compiler endpoint returns previews; use the native tesl CLI for source writes, or --manifest-json for a non-mutating preview";
  if !overlays<>[] && !root=None then reject "" "editor overlays require an explicit --project-root";
  let entry = match !entry with Some file -> file | None -> reject "" "an explicit application entry file is required" in
  {entry;database = !database;new_revision = !new_revision;root = !root;plan;initial_version;overlays=List.rev !overlays}
let generate opts =
  let root = Option.map path opts.root in
  let overlays = List.map (fun (file,version,contents) ->
    let contents = path contents in
    if (Unix.lstat contents).Unix.st_kind <> Unix.S_REG then reject contents "overlay contents must be a regular file";
    file,version,In_channel.with_open_bin contents In_channel.input_all) opts.overlays in
  (* Canonical proposed paths may have missing ancestors. Source_input validates
     the existing parents and rejects aliases before installing any overlay. *)
  let overlay_path file =
    let absolute = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
    if Source_input.canonical_path absolute <> absolute then reject absolute "overlay paths must use their absolute canonical spelling";
    absolute in
  let overlays = List.map (fun (file,version,source) -> overlay_path file,version,source) overlays in
  let documents = List.map (fun (file,version,_) -> {M.path=file;version}) overlays in
  let run () =
    let entry_file = path opts.entry in
    let project_root = match root with Some root -> root | None -> target (T.infer_project_root ~entry_file ~database:opts.database) in
    let stdout = if opts.plan then
      match Migration_plan.generate ~project_root ~entry_file ~database:opts.database ~initial_version:opts.initial_version ~documents with
       | Ok p -> Migration_plan.to_json p
       | Error errors -> raise (Plan_invalid errors)
     else P.to_json (preview (P.generate ~project_root ~entry_file ~database:opts.database ~new_revision:opts.new_revision ~documents)) in
    {stdout=stdout ^ "\n";stderr="";exit_code=0} in
  match root with
  | Some root -> Source_input.with_overlays ~project_root:root
      (List.map (fun (file,_,source) -> file,source) overlays) run
  | None -> run ()
let run args =
  if args=["--help"] || args=["-h"] || args=["generate";"--help"] || args=["plan";"--help"] then
    {stdout=usage;stderr="";exit_code=0}
  else
    let result = try Ok (generate (parse args)) with
      | Plan_invalid errors -> Ok {stdout=Migration_plan.errors_to_json errors ^ "\n";stderr="";exit_code=1}
      | Invalid errors -> Error errors
      | Sys_error message | Failure message | Invalid_argument message ->
        Error [{P.loc=Location.dummy_loc "";message;candidates=[]}]
      | Unix.Unix_error (error,operation,path) ->
        Error [{P.loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;candidates=[]}] in
    match result with
    | Ok response -> response
    | Error errors ->
      let stdout = if (match args with "plan" :: _ -> true | _ -> false) then Migration_plan.errors_to_json
        (List.map (fun (e : P.error) -> {Migration_sparse.code="MIG020";loc=e.loc;message=e.message;related=[]}) errors)
        else P.errors_to_json errors in
      {stdout=stdout ^ "\n";stderr="";exit_code=1}
