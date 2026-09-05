(** Source integrity and same-compiler semantic validation are separate judgments.
    These records are committed source metadata, not authenticated database state
    or authority to transport proofs between compiler ABIs. *)
module I = Migration_inventory
module C = Migration_canonical

type error_kind = Invalid_record | Invalid_layout | Missing_source | Changed_source
  | Invalid_schema | Abi_mismatch | Semantic_mismatch
type error = {kind : error_kind; loc : Location.loc; message : string}
type t = {root_module : string; compiler_abi : string; snapshot_digest : string;
          sources : (string * string) list}
type source_check = {seal : t; project_root : string; root_file : string;
                     source_inputs : (string * string) list}

let root_module seal = seal.root_module
let compiler_abi seal = seal.compiler_abi
let snapshot_digest seal = seal.snapshot_digest
let sources seal = seal.sources
let source_inputs checked = checked.source_inputs

exception Invalid of error
let reject kind path message = raise (Invalid {kind;loc=Location.dummy_loc path;message})
let protect anchor f = try Ok (f ()) with
  | Invalid error -> Error error
  | Sys_error message | Failure message | Invalid_argument message ->
    Error {kind=Invalid_layout;loc=Location.dummy_loc anchor;message}
  | Unix.Unix_error (error, operation, path) ->
    Error {kind=(if error = Unix.ENOENT then Missing_source else Invalid_layout);
      loc=Location.dummy_loc path;
      message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}

let hex source =
  let digits = "0123456789abcdef" in
  String.init (2 * String.length source) (fun i ->
    let value = Char.code source.[i / 2] in
    digits.[if i mod 2 = 0 then value lsr 4 else value land 15])
let unhex source =
  let digit = function '0'..'9' as c -> Char.code c - 48
    | 'a'..'f' as c -> Char.code c - 87 | _ -> -1 in
  if String.length source mod 2 <> 0 || not (String.for_all (fun c -> digit c >= 0) source) then None
  else Some (String.init (String.length source / 2) (fun i ->
    Char.chr (16 * digit source.[2 * i] + digit source.[2 * i + 1])))
let digest_valid s = String.length s = 64 &&
  String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) s

let validate seal =
  let invalid message = reject Invalid_record seal.root_module message in
  (match String.split_on_char '.' seal.root_module with
   | [family; revision] when Migration_source.valid_family family && Migration_source.valid_revision revision -> ()
   | _ -> invalid "a snapshot seal must name a canonical schema revision root");
  if String.trim seal.compiler_abi = "" then invalid "snapshot seal requires a compiler ABI";
  if not (digest_valid seal.snapshot_digest) then invalid "invalid snapshot semantic digest";
  if not (List.mem_assoc seal.root_module seal.sources) then invalid "snapshot seal omits its root source";
  let names = List.map fst seal.sources in
  if List.sort_uniq compare names <> List.sort compare names then invalid "duplicate snapshot source";
  List.iter (fun (name,digest) ->
    if not (Migration_schema.within seal.root_module name) ||
       Validation_common.schema_module_relative_path name = None then
      invalid ("snapshot source escapes its owning revision: " ^ name);
    if not (digest_valid digest) then invalid ("invalid source digest for " ^ name)) seal.sources

let encode seal =
  "# tesl:snapshot-seal:v1 " ^ seal.root_module ^ " " ^ hex seal.compiler_abi ^ " " ^ seal.snapshot_digest ^ "\n" ^
  String.concat "" (List.map (fun (name,digest) -> "# tesl:snapshot-source " ^ name ^ " " ^ digest ^ "\n") seal.sources) ^
  "# tesl:snapshot-end\n"

let decode text = protect "<snapshot-seal>" (fun () ->
  let bad () = reject Invalid_record "<snapshot-seal>" "malformed snapshot seal; regenerate it from checked source" in
  let lines = String.split_on_char '\n' text |> List.map (fun line ->
    if String.ends_with ~suffix:"\r" line then String.sub line 0 (String.length line - 1) else line) in
  match lines with
  | first :: rest ->
    let root_module,compiler_abi,snapshot_digest = match String.split_on_char ' ' first with
      | ["#";"tesl:snapshot-seal:v1";root;abi;digest] ->
        let abi = match unhex abi with Some abi -> abi | None -> bad () in root,abi,digest
      | _ -> bad () in
    let rec entries result = function
      | ["# tesl:snapshot-end";""] -> List.rev result
      | line :: rest ->
        (match String.split_on_char ' ' line with
         | ["#";"tesl:snapshot-source";name;digest] -> entries ((name,digest) :: result) rest
         | _ -> bad ())
      | [] -> bad () in
    let sources = entries [] rest in
    let seal = {root_module;compiler_abi;snapshot_digest;sources} in
    validate seal;
    if sources <> List.sort compare sources then
      reject Invalid_record root_module "snapshot sources must use canonical module order";
    seal
  | [] -> bad ())

let path_for root name = match Validation_common.schema_module_relative_path name with
  | Some relative -> Filename.concat root relative
  | None -> reject Invalid_record name "invalid snapshot module path"
let regular path =
  if Source_input.kind path <> Unix.S_REG || Source_input.realpath path <> path then
    reject Invalid_layout path "snapshot seal input must be a canonical regular file"

let verify_sources ~project_root seal = protect project_root (fun () ->
  validate seal;
  let project_root = Source_input.realpath project_root in
  let root_file = path_for project_root seal.root_module in
  let source_inputs = List.map (fun (name,digest) -> path_for project_root name,digest) seal.sources in
  let read path expected =
    regular path;
    let contents = Source_input.read path in
    if Migration_hash.digest contents <> expected then
      reject Changed_source path ("snapshot source differs from its recorded bytes: " ^ path);
    contents in
  let parsed = List.map (fun (name,digest) ->
    let path = path_for project_root name in
    let contents = read path digest in
    let m = match Parser.parse_module path contents with
      | Parser.Ok m -> m
      | Parser.Err error -> raise (Invalid {kind=Invalid_schema;loc=error.loc;message=error.msg}) in
    if m.Ast.module_name <> name then reject Invalid_schema path ("snapshot source must declare " ^ name);
    name,m) seal.sources in
  let visited = Hashtbl.create 16 in
  let resolutions = ref [] in
  let rec visit name =
    if not (Hashtbl.mem visited name) then begin
      Hashtbl.add visited name ();
      let m = match List.assoc_opt name parsed with
        | Some m -> m
        | None -> reject Invalid_record root_file ("snapshot seal omits imported source " ^ name) in
      List.iter (fun (import : Ast.import_decl) ->
        if String.starts_with ~prefix:"Tesl." import.module_name then ()
        else if not (Migration_schema.within seal.root_module import.module_name) then
          reject Invalid_schema m.source_file ("snapshot import escapes its revision: " ^ import.module_name)
        else begin
          let expected = path_for project_root import.module_name in
          let actual = Validation_common.resolve_local_import_path m.source_file import.module_name in
          if actual <> expected then reject Invalid_layout m.source_file
            ("snapshot import no longer resolves to its canonical source: " ^ import.module_name);
          resolutions := (m.source_file,import.module_name,expected) :: !resolutions;
          visit import.module_name
        end) m.imports
    end in
  visit seal.root_module;
  List.iter (fun (name,_) -> if not (Hashtbl.mem visited name) then
    reject Invalid_record (path_for project_root name) ("snapshot seal includes unowned source " ^ name)) seal.sources;
  List.iter (fun (path,digest) -> ignore (read path digest)) source_inputs;
  List.iter (fun (source,name,expected) ->
    if Validation_common.resolve_local_import_path source name <> expected then
      reject Changed_source source ("snapshot import resolution changed: " ^ name)) !resolutions;
  {seal;project_root;root_file;source_inputs})

let create ~project_root inventory = protect project_root (fun () ->
  let root = Source_input.realpath project_root in
  let inputs = I.source_inputs inventory in
  let sources = I.module_names inventory |> List.map (fun name ->
    let path = path_for root name in
    match List.assoc_opt path inputs with
    | Some digest -> name,digest
    | None -> reject Invalid_layout path "inventory does not use the canonical snapshot source path")
    |> List.sort compare in
  if List.length sources <> List.length inputs then
    reject Invalid_record root "inventory and snapshot source sets differ";
  let seal = {root_module=I.root_module inventory;compiler_abi=I.compiler_abi inventory;
    snapshot_digest=C.digest C.Snapshot (I.snapshot inventory);sources} in
  (match verify_sources ~project_root:root seal with Ok _ -> () | Error error -> raise (Invalid error));
  seal)

let verify_semantics ~compiler_abi checked = protect checked.root_file (fun () ->
  (* Recheck bytes before making an ABI judgment, so an actual edit remains
     identifiable even when the caller also changed compiler. Never reconstruct
     an old semantic hash by labelling a new compiler with the old ABI. *)
  (match verify_sources ~project_root:checked.project_root checked.seal with
   | Ok _ -> () | Error error -> raise (Invalid error));
  if compiler_abi <> checked.seal.compiler_abi then reject Abi_mismatch checked.root_file
    "snapshot source is unchanged, but semantic comparison requires its recorded compiler ABI";
  let inventory = match I.load ~compiler_abi ~root_file:checked.root_file with
    | Ok inventory -> inventory
    | Error error -> raise (Invalid {kind=Invalid_schema;loc=error.loc;message=error.message}) in
  if C.digest C.Snapshot (I.snapshot inventory) <> checked.seal.snapshot_digest then
    reject Semantic_mismatch checked.root_file "snapshot semantic digest differs under the recorded compiler ABI";
  (match verify_sources ~project_root:checked.project_root checked.seal with
   | Ok _ -> () | Error error -> raise (Invalid error));
  inventory)
