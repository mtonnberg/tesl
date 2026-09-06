module Input = Source_input
module Hash = Migration_hash
module V = Validation_common
module Build = Migration_build_snapshot
type error = {path:string;message:string}
type resource = {name:string;path:string;source:string;digest:string}
type t = {id:string;resources:resource list}
exception Invalid of error
let reject path message = raise (Invalid {path;message})
let id t = t.id
let source_inputs t = List.map (fun r -> r.path,r.digest) t.resources |> List.sort compare
let frame values = String.concat "" (List.map (fun value -> string_of_int (String.length value) ^ ":" ^ value) values)
let component label values = frame (label :: List.map (fun (name,value) -> frame [name;value]) (List.sort compare values))
let compiled = lazy (
  if Embedded_go_runtime.files=[] then reject "<compiler>" "migration source commands require an embedded execution runtime";
  component "compiler" (("ocaml-version",Build.ocaml_version)::Build.compiler_sources),
  component "embedded-go-runtime" (List.map (fun (name,source) -> name,Hash.digest source) Embedded_go_runtime.files))
let current () =
  try
    let compiler,runtime = Lazy.force compiled in
    let chosen = Hashtbl.create 8 in
    List.iter (fun directory ->
      if Input.exists directory then begin
        if Input.kind (Input.realpath directory) <> Unix.S_DIR then reject directory "stdlib resource directory is not a directory";
        Input.readdir directory |> Array.to_list |> List.sort String.compare |> List.iter (fun name ->
          if Filename.check_suffix name ".tesl" && not (Hashtbl.mem chosen name) then begin
            let file = Filename.concat directory name in
            let resolved = Input.realpath file in
            if Input.kind resolved <> Unix.S_REG then reject file "stdlib ABI inputs must resolve to regular files";
            let source = Input.read resolved in
            Hashtbl.add chosen name {name;path=resolved;source;digest=Hash.digest source}
          end)
      end) (V.stdlib_source_directories ());
    List.iter (fun (_,name) -> if not (Hashtbl.mem chosen name) then
      reject name "a required lifted stdlib source is unavailable for the compiler ABI") V.lifted_stdlib_sources;
    let resources = Hashtbl.to_seq chosen |> List.of_seq |> List.sort compare |> List.map snd in
    let stdlib = component "lifted-stdlib" (List.map (fun r -> r.name,r.digest) resources) in
    let id = "tesl-source-abi-v1:" ^ Hash.digest (frame ["migration-compiler";compiler;runtime;stdlib]) in
    Ok {id;resources}
  with
  | Invalid error -> Error error
  | Sys_error message | Invalid_argument message | Failure message -> Error {path="<compiler>";message}
  | Unix.Unix_error (error,operation,path) -> Error {path;message=operation ^ ": " ^ Unix.error_message error}
let verify expected = match Input.without_pinned_files current with
  | Error error -> Error error
  | Ok actual when actual.id=expected.id -> Ok ()
  | Ok _ -> Error {path="<compiler>";message="compiler or lifted stdlib ABI changed after source generation began"}

let active_snapshot : string option ref = ref None
let with_snapshot snapshot f =
  match !active_snapshot with
  | Some id when id <> snapshot.id -> Error {path="<compiler>";message="nested generation cannot change the compiler ABI"}
  | _ -> match verify snapshot with
  | Error _ as error -> error
  | Ok () ->
    let previous = !active_snapshot in
    active_snapshot := Some snapshot.id;
    let result = Fun.protect ~finally:(fun () -> active_snapshot := previous) (fun () ->
      Input.with_pinned_files (List.map (fun r -> r.path,r.source) snapshot.resources) (fun () ->
        V.with_fixed_stdlib_sources (List.map (fun r -> r.name,r.path) snapshot.resources) f)) in
    match verify snapshot with
    | Error _ as error -> error
    | Ok () -> Ok result
