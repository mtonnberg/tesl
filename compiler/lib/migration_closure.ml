(** Raw source integrity for a completed migration and its private helper closure.
    The root hashes its exact bytes with only this metadata block removed, avoiding
    self-reference. Schema source is covered independently by Migration_header.
    These records are not execution authority or semantic compatibility evidence. *)
module E = Migration_sparse
module V = Validation_common
module Schema = Migration_schema
module Input = Source_input
module Hash = Migration_hash

(* [checkpoint] is the SHA-256 of the root's generated v<n>.checkpoint, when one
   was written. It sits inside this block, so the root digest never covers it. *)
type t = {root:string;sources:(string * string) list;checkpoint:string option}
type located = {seal:t;start_offset:int;end_offset:int;loc:Location.loc}
exception Invalid of E.error list
let reject file message = raise (Invalid [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}])
let protect file f = try Ok (f ()) with
  | Invalid errors -> Error errors
  | Sys_error message | Invalid_argument message | Failure message ->
    Error [{E.code="MIG013";loc=Location.dummy_loc file;message;related=[]}]
  | Unix.Unix_error (error,operation,path) ->
    Error [{E.code="MIG013";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let valid_root name = match V.schema_module_parts name with
  | Some (family,"Migrate",[version]) when Migration_source.valid_family family &&
      Migration_source.valid_revision version && version <> "VCurrent" && version <> "V1" -> true
  | _ -> false
let family name = match V.schema_module_parts name with
  | Some (family,_,_) -> family | None -> reject name "invalid frozen migration family"
let path root name = match V.schema_module_relative_path name with
  | Some relative -> Filename.concat root relative
  | None -> reject root ("invalid frozen migration module: " ^ name)
let valid_hash value = String.length value=64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
let opening = "# tesl:frozen-migration:v1 "
let closing = "# tesl:frozen-migration:end"
let member = "# tesl:frozen-source "
let checkpoint_member = "# tesl:frozen-checkpoint "
let reserved line = List.exists (fun prefix -> String.starts_with ~prefix (String.trim line))
  ["# tesl:frozen-migration";"# tesl:frozen-source";"# tesl:frozen-checkpoint"]
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
    let checkpoint = ref None in
    let rec entries result = function
      | [] -> malformed ()
      | line::rest when line.text=closing -> List.rev result,line,rest
      | line::(next::_ as rest) when String.starts_with ~prefix:checkpoint_member line.text && next.text=closing && !checkpoint=None ->
        let value = String.sub line.text (String.length checkpoint_member) (String.length line.text - String.length checkpoint_member) in
        if not (valid_hash value) then malformed ();
        checkpoint := Some value; entries result rest
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
    Some {seal={root;sources;checkpoint= !checkpoint};start_offset=first.offset;end_offset=last.stop;loc=Location.dummy_loc file}
(* A pure function of the file name and bytes: decoded once (see
   Migration_header.read). *)
let read_memo : (located option, E.error list) result Hash.Text_table.t = Hash.Text_table.create 64
let read ~file source = match Hash.Text_table.find_opt read_memo (file,source) with
  | Some result -> result
  | None ->
    let result = protect file (fun () -> read_raw ~file source) in
    if Hash.Text_table.length read_memo >= 4096 then Hash.Text_table.reset read_memo;
    Hash.Text_table.replace read_memo (file,source) result; result
let remove source located = String.sub source 0 located.start_offset ^ String.sub source located.end_offset (String.length source-located.end_offset)
let without ~file source = match read ~file source with
  | Ok None -> source | Ok (Some located) -> remove source located | Error errors -> raise (Invalid errors)
let encode seal = opening ^ seal.root ^ "\n" ^
  String.concat "" (List.map (fun (name,digest) -> member ^ name ^ " " ^ digest ^ "\n") seal.sources) ^
  Option.fold ~none:"" ~some:(fun digest -> checkpoint_member ^ digest ^ "\n") seal.checkpoint ^ closing ^ "\n"
let checkpoint_file root_file = Filename.chop_suffix root_file ".tesl" ^ ".checkpoint"
let root located = located.seal.root
let checkpoint located = located.seal.checkpoint
let with_checkpoint seal digest = {seal with checkpoint=digest}
let sources located = located.seal.sources
let mentions_file ~project_root ~file located = List.exists (fun (name,_) -> path project_root name=file) located.seal.sources
let regular file =
  if Input.kind file <> Unix.S_REG || Input.realpath file <> file then
    reject file "frozen migration sources must be canonical regular files"
(* Facts of [contents] (a root's bytes without its frozen-source block, as its
   seal hashes them): recorded ones, else a parse. *)
type parsed = Recorded of Migration_module_facts.t | Parsed of Ast.module_form
let parsed_facts = function Recorded facts -> facts | Parsed m -> Migration_module_facts.of_module m
let lookup file contents =
  match Migration_module_facts.find (Hash.digest contents) with
  | Some facts -> Ok (Recorded facts)
  | None -> match Parser.parse_module file contents with
    | Ok m -> Ok (Parsed m) | Err error -> Error error
let facts file contents = Result.map parsed_facts (lookup file contents)
let source_facts ~file source = match without ~file source with
  | bytes -> lookup file bytes
  | exception Invalid _ -> lookup file source
let imports ~file source = Result.map (fun parsed -> (parsed_facts parsed).Migration_module_facts.imports) (source_facts ~file source)
let without_block ~file source = try Some (without ~file source) with Invalid _ -> None
let collect ~project_root ~root_file ~source =
  let parse file contents = match facts file contents with
    | Ok m -> m | Error (error : Parser.parse_error) -> reject file error.msg in
  let entry = parse root_file (without ~file:root_file source) in
  let root = entry.Migration_module_facts.module_name in
  if not (valid_root root) || path project_root root <> root_file then
    reject root_file "frozen migration root must use its canonical versioned path";
  let found = Hashtbl.create 16 in
  let rec visit name file contents =
    if not (Hashtbl.mem found name) then begin
      regular file;
      let bytes = if name=root then without ~file contents else contents in
      let m = parse file bytes in
      if m.module_name <> name then reject file ("frozen migration source must declare " ^ name);
      Hashtbl.add found name (Hash.digest bytes);
      List.iter (fun imported ->
        if String.starts_with ~prefix:"Tesl." imported then ()
        else if Schema.migration_family imported=Some (family root) then begin
          let expected = path project_root imported in
          if V.resolve_local_import_path file imported <> expected then
            reject file ("frozen migration import changed resolution: " ^ imported);
          if not (Hashtbl.mem found imported) then begin
            regular expected; visit imported expected (Input.read expected)
          end
        end else match Schema.schema_prefix imported with
          | Some prefix when String.starts_with ~prefix:(family root ^ ".V") prefix && not (String.ends_with ~suffix:".VCurrent" prefix) -> ()
          | _ -> reject file ("completed migration import escapes frozen ownership: " ^ imported)
      ) m.imports
    end in
  visit root root_file source;
  (* A Contract is a contextual companion, not a function imported by the row
     transform. Freeze its presence and raw dependency closure with the completed
     migration so later creation, removal, or edits cannot alter reviewed history. *)
  let companion = root ^ "Contract" in
  let companion_file = path project_root companion in
  if Input.exists companion_file then
    visit companion companion_file (Input.read companion_file);
  {root;sources=Hashtbl.to_seq found |> List.of_seq |> List.sort compare;checkpoint=None}
let capture ~project_root ~root_file ~source = protect root_file (fun () ->
  collect ~project_root ~root_file ~source)
let attach ~file ~source seal = protect file (fun () ->
  let body = without ~file source in
  if List.assoc_opt seal.root seal.sources <> Some (Hash.digest body) then
    reject file "migration root changed after its closure was captured";
  Migration_source.source_fragment ~source:body (encode seal) ^ body)
let verify ~project_root ~root_file ~source located = protect root_file (fun () ->
  (* Compare raw bytes before parsing helpers. Even an edit that no longer parses
     is an integrity failure, not permission to replace a completed source. *)
  if path project_root located.seal.root <> root_file then reject root_file "frozen migration seal names a different root";
  List.iter (fun (name,digest) ->
    let file = path project_root name in regular file;
    let contents = if file=root_file then without ~file source else Input.read file in
    if Hash.digest contents <> digest then reject file "recorded frozen migration source changed; restore it and make a forward revision") located.seal.sources;
  Option.iter (fun digest ->
    let file = checkpoint_file root_file in
    regular file;
    let bytes = Input.read file in
    if Hash.digest bytes <> digest then
      reject file "recorded migration checkpoint changed; restore it, or run the full-history check to find which bytes differ";
    (* Verified: its recorded parse facts may replace parses below. *)
    Migration_module_facts.load_checkpoint bytes) located.seal.checkpoint;
  let actual = collect ~project_root ~root_file ~source in
  if {actual with checkpoint=located.seal.checkpoint} <> located.seal then reject root_file "frozen migration source or Contract companion closure changed; restore it and prepare the Contract before starting the next revision")
