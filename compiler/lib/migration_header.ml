module S = Migration_seal
module E = Migration_sparse
type t = {previous:S.t;current:S.t}
type located = {header:t;loc:Location.loc;start_offset:int;end_offset:int}
type checked = {located:located;project_root:string}
exception Invalid of E.error list
let reject ?(code="MIG013") ?(related=[]) loc message =
  raise (Invalid [{E.code;loc;message;related}])
let protect f = try Ok (f ()) with Invalid errors -> Error errors
let opening = "# tesl:migration-history:v1"
let closing = "# tesl:migration-history:end"
let seal_end = "# tesl:snapshot-end"
let seals checked = checked.located.header.previous,checked.located.header.current
let recorded_seals located = located.header.previous,located.header.current
let roots located = S.root_module located.header.previous,S.root_module located.header.current
let mentions_file ~project_root ~file located =
  List.exists (fun seal -> List.exists (fun (name,_) ->
    match Validation_common.schema_module_relative_path name with
    | Some relative -> Filename.concat project_root relative = file
    | None -> false) (S.sources seal)) [located.header.previous;located.header.current]
let version root = match String.split_on_char '.' root with
  | [family;revision] when Migration_source.valid_family family && Migration_source.valid_revision revision ->
    Some (family, if revision = "VCurrent" then None else Some (int_of_string (String.sub revision 1 (String.length revision - 1))))
  | _ -> None
let validate loc header =
  match version (S.root_module header.previous),version (S.root_module header.current) with
  | Some (family,Some previous),Some (other,current)
      when family = other && previous < 2147483646 &&
           (current = None || current = Some (previous + 1)) -> family,previous + 1
  | _ -> reject loc "migration history seals must name adjacent schema revisions in one family, with a frozen predecessor"
let module_name located =
  let family,target = validate located.loc located.header in
  Printf.sprintf "%s.Migrate.V%d" family target
let create ~previous ~current = protect (fun () ->
  let header = {previous;current} in ignore (validate (Location.dummy_loc "<migration-header>") header); header)
let encode header = opening ^ "\n# tesl:migration-from\n" ^ S.encode header.previous ^
  "# tesl:migration-to\n" ^ S.encode header.current ^ closing ^ "\n"

type line = {text:string;offset:int;stop:int;number:int}
let lines source =
  let offset = ref 0 in
  String.split_on_char '\n' source |> List.mapi (fun number text ->
    let start = !offset in
    offset := min (String.length source) (start + String.length text + 1);
    let text = if String.ends_with ~suffix:"\r" text then String.sub text 0 (String.length text - 1) else text in
    {text;offset=start;stop= !offset;number})
let reserved text =
  let text = String.trim text in
  List.exists (fun prefix -> String.starts_with ~prefix text)
    ["# tesl:migration-";"# tesl:snapshot-"]

let read ~file source = protect (fun () ->
  let rec prefix = function
    | line :: rest when String.trim line.text = "" || String.starts_with ~prefix:"#" (String.trim line.text) -> line :: prefix rest
    | _ -> [] in
  let comments = prefix (lines source) in
  let candidates = List.filter (fun line -> reserved line.text) comments in
  match candidates with
  | [] -> None
  | first :: _ ->
    let loc = Location.make_loc file first.number 0 first.number (String.length first.text) in
    let malformed () = reject loc "malformed migration history header; retain both complete snapshot seals" in
    let block = List.filter (fun line -> line.offset >= first.offset) comments in
    let expect text = function line::rest when line.text = text -> rest | _ -> malformed () in
    let snapshot remaining =
      let rec take acc = function
        | [] -> malformed ()
        | line :: rest ->
          let acc = line.text :: acc in
          if line.text = seal_end then String.concat "\n" (List.rev acc) ^ "\n",rest
          else take acc rest in
      let encoded,rest = take [] remaining in
      match S.decode encoded with
      | Ok seal -> seal,rest
      | Error error -> reject loc ("invalid snapshot seal in migration header: " ^ error.message) in
    let rest = expect opening block |> expect "# tesl:migration-from" in
    let previous,rest = snapshot rest in
    let current,rest = snapshot (expect "# tesl:migration-to" rest) in
    let last,rest = match rest with line::rest when line.text = closing -> line,rest | _ -> malformed () in
    if List.exists (fun line -> reserved line.text) rest then
      reject loc "duplicate or trailing migration history metadata";
    if last.stop = String.length source && not (String.ends_with ~suffix:"\n" source) then malformed ();
    let header = {previous;current} in
    ignore (validate loc header);
    Some {header;loc;start_offset=first.offset;end_offset=last.stop})

let replace ~file ~source header = match read ~file source with
  | Error _ as error -> error
  | Ok None -> Ok (encode header ^ source)
  | Ok (Some previous) -> Ok (String.sub source 0 previous.start_offset ^ encode header ^
      String.sub source previous.end_offset (String.length source - previous.end_offset))

let verify_unchanged checked = protect (fun () ->
  List.iter (fun (role,seal) ->
    match S.verify_sources ~project_root:checked.project_root seal with
    | Ok _ -> ()
    | Error error ->
      let current = String.ends_with ~suffix:".VCurrent" (S.root_module seal) in
      let changed_input = match error.S.kind with
        | S.Changed_source | S.Missing_source | S.Invalid_layout -> true
        | S.Invalid_record | S.Invalid_schema | S.Abi_mismatch | S.Semantic_mismatch -> false in
      let code = if current && changed_input then "MIG001" else "MIG013" in
      let instruction = if code = "MIG001" then
        "schema changed since this migration was generated; refresh this revision if it is undeployed, or start the next revision from the deployed source"
        else "recorded frozen schema source or history metadata changed; restore the recorded source and make a forward revision" in
      reject ~code ~related:[error.loc, role ^ " schema source"] checked.located.loc
        (instruction ^ "\n" ^ error.message))
    ["previous",checked.located.header.previous;"target",checked.located.header.current])

let verify ~project_root ~migration_module ~previous ~current located = protect (fun () ->
  let family,target = validate located.loc located.header in
  if migration_module <> Printf.sprintf "%s.Migrate.V%d" family target ||
     previous <> S.root_module located.header.previous || current <> S.root_module located.header.current then
    reject located.loc "migration history header does not match this module's adjacent from/to schema references";
  let checked = {located;project_root} in
  (match verify_unchanged checked with Ok () -> () | Error errors -> raise (Invalid errors));
  checked)
