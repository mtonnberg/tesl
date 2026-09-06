(** Raw source integrity for a completed migration and its private helper closure.
    The root hashes its exact bytes with only this metadata block removed, avoiding
    self-reference. Schema source is covered independently by Migration_header.
    These records are not execution authority or semantic compatibility evidence. *)
module E = Migration_sparse
module V = Validation_common
module Schema = Migration_schema
module Input = Source_input
module Hash = Migration_hash

type t = {root:string;sources:(string * string) list}
type located = {seal:t;start_offset:int;end_offset:int;loc:Location.loc}
exception Invalid of E.error list
let reject file message = raise (Invalid [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}])
let protect file f = try Ok (f ()) with
  | Invalid errors -> Error errors
  | Sys_error message | Invalid_argument message | Failure message ->
    Error [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}]
  | Unix.Unix_error (error,operation,path) ->
    Error [{E.code="MIG013";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let valid_root name = match String.split_on_char '.' name with
  | [family;"Migrate";version] when Migration_source.valid_family family &&
      Migration_source.valid_revision version && version <> "VCurrent" && version <> "V1" -> true
  | _ -> false
let family name = List.hd (String.split_on_char '.' name)
let path root name = match V.schema_module_relative_path name with
  | Some relative -> Filename.concat root relative
  | None -> reject root ("invalid frozen migration module: " ^ name)
let valid_hash value = String.length value=64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
let opening = "# tesl:frozen-migration:v1 "
let closing = "# tesl:frozen-migration:end"
let member = "# tesl:frozen-source "
let reserved line = List.exists (fun prefix -> String.starts_with ~prefix (String.trim line))
  ["# tesl:frozen-migration";"# tesl:frozen-source"]
type line = {text:string;offset:int;stop:int}
let lines source =
  let offset = ref 0 in String.split_on_char '\n' source |> List.map (fun text ->
    let start = !offset in offset := min (String.length source) (start + String.length text + 1);
    let text = if String.ends_with ~suffix:"\r" text then String.sub text 0 (String.length text-1) else text in
    {text;offset=start;stop= !offset})
let read_raw ~file source =
  let rec prefix = function
    | line::rest when String.trim line.text="" || String.starts_with ~prefix:"#" (String.trim line.text) -> line::prefix rest
    | _ -> [] in
  let comments = prefix (lines source) in
  match List.find_opt (fun line -> reserved line.text) comments with
  | None -> None
  | Some first ->
    let malformed () = reject file "malformed frozen migration closure metadata" in
    if not (String.starts_with ~prefix:opening first.text) then malformed ();
    let root = String.sub first.text (String.length opening) (String.length first.text - String.length opening) in
    if not (valid_root root) then malformed ();
    let rec entries result = function
      | [] -> malformed ()
      | line::rest when line.text=closing -> List.rev result,line,rest
      | line::rest when String.starts_with ~prefix:member line.text ->
        let value = String.sub line.text (String.length member) (String.length line.text - String.length member) in
        (match String.split_on_char ' ' value with
         | [name;digest] when Schema.migration_family name=Some (family root) && valid_hash digest -> entries ((name,digest)::result) rest
         | _ -> malformed ())
      | _ -> malformed () in
    let remaining = List.filter (fun line -> line.offset > first.offset) comments in
    let sources,last,rest = entries [] remaining in
    if sources=[] || List.map fst sources <> List.sort_uniq String.compare (List.map fst sources) || not (List.mem_assoc root sources) then malformed ();
    if List.exists (fun line -> reserved line.text) rest then malformed ();
    if last.stop=String.length source && not (String.ends_with ~suffix:"\n" source) then malformed ();
    Some {seal={root;sources};start_offset=first.offset;end_offset=last.stop;loc=Location.dummy_loc file}
let read ~file source = protect file (fun () -> read_raw ~file source)
let remove source located = String.sub source 0 located.start_offset ^ String.sub source located.end_offset (String.length source-located.end_offset)
let without ~file source = match read_raw ~file source with None -> source | Some located -> remove source located
let encode seal = opening ^ seal.root ^ "\n" ^
  String.concat "" (List.map (fun (name,digest) -> member ^ name ^ " " ^ digest ^ "\n") seal.sources) ^ closing ^ "\n"
let root located = located.seal.root
let sources located = located.seal.sources
let mentions_file ~project_root ~file located = List.exists (fun (name,_) -> path project_root name=file) located.seal.sources
let regular file =
  if Input.kind file <> Unix.S_REG || Input.realpath file <> file then
    reject file "frozen migration sources must be canonical regular files"
let collect ~project_root ~root_file ~source =
  let parse file contents = match Parser.parse_module file contents with
    | Ok m -> m | Err error -> reject file error.msg in
  let entry = parse root_file source in
  let root = entry.Ast.module_name in
  if not (valid_root root) || path project_root root <> root_file then
    reject root_file "frozen migration root must use its canonical versioned path";
  let found = Hashtbl.create 16 in
  let rec visit name file contents =
    if not (Hashtbl.mem found name) then begin
      regular file;
      let m = parse file contents in
      if m.Ast.module_name <> name then reject file ("frozen migration source must declare " ^ name);
      let bytes = if name=root then without ~file contents else contents in
      Hashtbl.add found name (Hash.digest bytes);
      List.iter (fun (imp : Ast.import_decl) ->
        if String.starts_with ~prefix:"Tesl." imp.module_name then ()
        else if Schema.migration_family imp.module_name=Some (family root) then begin
          let expected = path project_root imp.module_name in
          if V.resolve_local_import_path file imp.module_name <> expected then
            reject file ("frozen migration import changed resolution: " ^ imp.module_name);
          if not (Hashtbl.mem found imp.module_name) then begin
            regular expected; visit imp.module_name expected (Input.read expected)
          end
        end else match Schema.schema_prefix imp.module_name with
          | Some prefix when String.starts_with ~prefix:(family root ^ ".V") prefix && not (String.ends_with ~suffix:".VCurrent" prefix) -> ()
          | _ -> reject file ("completed migration import escapes frozen ownership: " ^ imp.module_name)
      ) m.imports
    end in
  visit root root_file source;
  {root;sources=Hashtbl.to_seq found |> List.of_seq |> List.sort compare}
let capture ~project_root ~root_file ~source = protect root_file (fun () ->
  collect ~project_root ~root_file ~source)
let attach ~file ~source seal = protect file (fun () ->
  let body = without ~file source in
  if List.assoc_opt seal.root seal.sources <> Some (Hash.digest body) then
    reject file "migration root changed after its closure was captured";
  encode seal ^ body)
let verify ~project_root ~root_file ~source located = protect root_file (fun () ->
  (* Compare raw bytes before parsing helpers. Even an edit that no longer parses
     is an integrity failure, not permission to replace a completed source. *)
  if path project_root located.seal.root <> root_file then reject root_file "frozen migration seal names a different root";
  List.iter (fun (name,digest) ->
    let file = path project_root name in regular file;
    let contents = if file=root_file then without ~file source else Input.read file in
    if Hash.digest contents <> digest then reject file "recorded frozen migration source changed; restore it and make a forward revision") located.seal.sources;
  let actual = collect ~project_root ~root_file ~source in
  if actual <> located.seal then reject root_file "frozen migration import closure changed")
