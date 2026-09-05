module S = Migration_source_syntax
module P = Migration_provenance
type desired = { id : string; key : string option; body : string }
type result = { source : string; protected : string list }
exception Invalid of string
let reject message = raise (Invalid message)
let get = function Ok x -> x | Error (e : S.error) -> reject e.message
let valid_id id = id <> "" && String.for_all (function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' | '.' | ':' | '/' -> true | _ -> false) id
let valid_key key = key <> "" && String.for_all (function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '.' -> true | _ -> false) key
let unique what values = if List.length (List.sort_uniq compare values) <> List.length values then reject ("duplicate " ^ what)
let fragment ~previous ~current body =
  let source = "module Generated.Migrate.V2 exposing [migration]\nimport Tesl.Migration exposing [Migration]\n" ^
    "migration = Migration { entities: { Generated: " ^ body ^ "\n} }\n" in
  let view = get (S.read ~file:"<migration-generated-fragment>" ~source) in
  let expression = match (S.module_ view).decls with
    | [Ast.DConst c] -> (match Migration_form.application c.value with
      | "Migration",[Ast.ERecord {fields=["entities",Ast.ERecord {fields=["Generated",value];_}];_}] -> value
      | _ -> reject "generated body escaped its expression")
    | _ -> reject "generated body escaped its declaration" in
  let range = get (S.range view expression) in
  if S.text view range <> String.trim body then reject "generated body contains surrounding source";
  ignore (get (P.annotate view ~previous ~current ["fragment",expression]));
  match S.fingerprint ~previous ~current expression with Some fp -> fp | None -> reject "unsupported generated body"
let reconcile view ~collection ~previous ~current ~existing ~desired =
  try
    let members = get (S.members view collection) in
    let bounds = get (S.collection_range view collection) in
    let is_record = match collection with Ast.ERecord _ -> true | _ -> false in
    unique "existing identity" (List.map fst existing);
    unique "desired identity" (List.map (fun d -> d.id) desired);
    if List.exists (fun (id,_) -> not (valid_id id)) existing then reject "invalid existing identity";
    if List.length existing <> List.length members || List.exists (fun (_,value) ->
      List.length (List.filter (fun (_,e) -> e == value) existing) <> 1) members then
      reject "existing identities must cover each direct member exactly once";
    List.iter (fun d ->
      if not (valid_id d.id) then reject "invalid desired identity";
      match d.key with
      | Some key when is_record && valid_key key -> ()
      | None when not is_record -> ()
      | _ -> reject "desired key does not match the collection") desired;
    if is_record then unique "desired record key" (List.map (fun d -> d.key) desired);
    let desired = List.map (fun d -> d,fragment ~previous ~current d.body) desired in
    let edits = ref [] and protected = ref [] in
    let source = S.source view in
    List.iter (fun (id,value) ->
      let key = fst (List.find (fun (_,e) -> e == value) members) in
      let wanted = List.find_opt (fun (d,_) -> d.id = id) desired in
      Option.iter (fun (d,_) -> if d.key <> key then reject "record key changed under an existing identity") wanted;
      match P.editable_member view ~collection ~previous ~current ~id value with
      | None -> protected := id :: !protected
      | Some owned -> (match wanted with
        | None -> edits := (owned,"") :: !edits
        | Some (d,hash) when S.fingerprint ~previous ~current value <> Some hash ->
          let value_range = get (S.range view value) in
          let prefix = String.sub source owned.start_byte (value_range.start_byte-owned.start_byte) in
          let between = String.sub source value_range.end_byte (owned.end_byte-value_range.end_byte) in
          let comma = if String.contains between ',' then "," else "" in
          edits := (owned,prefix ^ d.body ^ comma ^ " # @tesl-gen " ^ id ^ " " ^ hash) :: !edits
        | Some _ -> ())) existing;
    let added = List.filter (fun (d,_) -> not (List.mem_assoc d.id existing)) desired in
    List.iter (fun (d,_) -> if is_record && List.exists (fun (key,_) -> key = d.key) members then
      reject "new identity collides with an existing record key") added;
    if added <> [] then begin
      let closing = bounds.end_byte - 1 in
      let line_start = match String.rindex_from_opt source closing '\n' with Some i -> i+1 | None -> 0 in
      let whitespace c = c = ' ' || c = '\t' in
      let indent_end = ref line_start in
      while !indent_end < closing && whitespace source.[!indent_end] do incr indent_end done;
      let indent = String.sub source line_start (!indent_end-line_start) in
      let own_line = !indent_end = closing in
      let newline = if String.contains source '\r' then "\r\n" else "\n" in
      let render (d,hash) = indent ^ "  " ^
        (match d.key with None -> "" | Some key -> "\"" ^ key ^ "\": ") ^
        d.body ^ ", # @tesl-gen " ^ d.id ^ " " ^ hash in
      let text = (if own_line then "" else newline) ^ String.concat newline (List.map render added) ^ newline ^ indent in
      edits := ({S.start_byte=(if own_line then line_start else closing);end_byte=closing},text) :: !edits
    end;
    {source=get (S.replace view !edits);protected=List.rev !protected} |> Result.ok
  with Invalid message | Failure message | Invalid_argument message -> Error {S.message}
