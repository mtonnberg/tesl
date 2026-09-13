module S = Migration_source_syntax
type ownership = Generated | User_owned | Unmarked
let valid_id id = id <> "" && String.for_all (function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' | '.' | ':' | '/' -> true | _ -> false) id
let valid_digest hash = String.length hash = 64 && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) hash
let tail source (range : S.range) =
  let stop = match String.index_from_opt source range.end_byte '\n' with Some i -> i | None -> String.length source in
  let stop = if stop > range.end_byte && source.[stop-1] = '\r' then stop-1 else stop in
  let skip i =
    let i = ref i in while !i < stop && (source.[!i] = ' ' || source.[!i] = '\t') do incr i done; !i in
  let first = skip range.end_byte in
  let first = if first < stop && source.[first] = ',' then skip (first+1) else first in
  first,stop,String.sub source first (stop-first)
let internal_comment text =
  let rec scan i in_string =
    if i >= String.length text then false else
    match text.[i],in_string with
    | '\\',true -> scan (i+2) true
    | '"',_ -> scan (i+1) (not in_string)
    | '#',false -> true
    | _ -> scan (i+1) in_string in
  scan 0 false
let marker text = match String.split_on_char ' ' text with
  | ["#";"@tesl-gen";id;hash] when valid_id id && valid_digest hash -> Some (id,hash)
  | _ -> None
let ownership view ~previous ~current ~id expression =
  match S.range view expression, S.fingerprint ~previous ~current expression with
  | Ok range,Some hash when valid_id id ->
    let _,_,text = tail (S.source view) range in
    (match marker text with
     | Some (recorded_id,recorded_hash) when id = recorded_id && hash = recorded_hash &&
          not (internal_comment (S.text view range)) -> Generated
     | Some _ -> User_owned
     | None when String.starts_with ~prefix:"# @tesl-gen" text -> User_owned
     | None -> Unmarked)
  | _ -> User_owned
let editable_member view ~collection ~previous ~current ~id expression =
  match ownership view ~previous ~current ~id expression, S.member_range view ~collection expression,
        S.range view expression with
  | Generated,Ok member,Ok value when not (internal_comment (S.text view member)) ->
    let _,stop,_ = tail (S.source view) value in
    Some {member with S.end_byte=stop}
  | _ -> None
let annotate view ~previous ~current nodes =
  let fail message = Error {S.message} in
  let rec collect seen edits = function
    | [] -> S.replace view edits
    | (id,expression) :: rest ->
      if not (valid_id id) then fail "invalid generated-node identity"
      else if List.mem id seen then fail "duplicate generated-node identity"
      else match S.range view expression,S.fingerprint ~previous ~current expression with
        | Error error,_ -> Error error
        | _,None -> fail "unsupported generated-node fingerprint"
        | Ok range,Some hash ->
          let first,_,text = tail (S.source view) range in
          if internal_comment (S.text view range) then fail "comments inside generated data remain user-owned"
          else if text = "" then
            let point = {S.start_byte=first;end_byte=first} in
            collect (id::seen) ((point," # @tesl-gen " ^ id ^ " " ^ hash)::edits) rest
          else if ownership view ~previous ~current ~id expression = Generated then
            collect (id::seen) edits rest
          else fail "annotation would overwrite code, a comment or an edited generated node" in
  collect [] [] nodes
