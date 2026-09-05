open Ast
module C = Migration_canonical
module Nodes = Hashtbl.Make(struct type t = expr let equal a b = a == b let hash = Hashtbl.hash end)
type range = { start_byte : int; end_byte : int }
type error = { message : string }
type t = { file : string; source : string; ast : module_form; tokens : Lexer.full_token array;
           lines : string array; offsets : int array; nodes : unit Nodes.t }
exception Invalid of string
let reject message = raise (Invalid message)
let protect f = try Ok (f ()) with
  | Invalid message | Failure message | Invalid_argument message -> Error {message}
let module_ t = t.ast
let source t = t.source
let read ~file ~source = protect (fun () ->
  let ast = match Parser.parse_module file source with Ok m -> m | Err e -> reject e.msg in
  let lines = String.split_on_char '\n' source |> Array.of_list in
  let offsets = Array.make (Array.length lines) 0 in
  for i = 1 to Array.length lines - 1 do offsets.(i) <- offsets.(i-1) + String.length lines.(i-1) + 1 done;
  let nodes = Nodes.create 32 in
  List.iter (Ast_visitor.iter (fun expression -> Nodes.replace nodes expression ())) (Frontend_check.module_expression_roots ast);
  {file;source;ast;tokens=Array.of_list (Lexer.tokenize file source);lines;offsets;nodes})
let node name values = C.Seq (C.Bytes name :: values)
exception Unsupported
let supported = function Ok x -> x | Error _ -> raise Unsupported
let rec shape rename expression =
  let rec call args = function
    | EApp {fn;arg;_} -> call (arg :: args) fn
    | EConstructor {name;args=initial;_} -> node "constructor" [C.Bytes (rename name);C.Seq (List.map (shape rename) (initial @ args))]
    | fn -> node "application" [shape rename fn;C.Seq (List.map (shape rename) args)] in
  match expression with
  | ELit {lit;_} -> (match lit with
    | LInt n -> supported (C.integer (string_of_int n))
    | LBigInt n -> supported (C.integer n)
    | LFloat n -> supported (C.float n)
    | LBool b -> C.bool b | LString s -> C.string s | LInterp _ -> raise Unsupported)
  | EVar {name;_} -> node "variable" [C.Bytes (rename name)]
  | EField {obj;field;_} -> node "field" [shape rename obj;C.Bytes field]
  | EApp _ | EConstructor _ -> call [] expression
  | EUnop {op;arg;_} -> node (match op with UNeg -> "negative" | UNot -> "not") [shape rename arg]
  | ERecord {fields;type_hint;_} -> node "record" [
      (match type_hint with None -> node "untyped" [] | Some name -> node "typed" [C.Bytes (rename name)]);
      C.Seq (List.map (fun (name,value) -> node "field" [C.Bytes name;shape rename value]) fields)]
  | EList {elems;_} -> node "list" (List.map (shape rename) elems)
  | EBinop _ | EIf _ | ECase _ | ELet _ | ELetProof _ | EOk _ | EFail _ | ETelemetry _ | EEnqueue _
  | EPublish _ | EStartWorkers _ | ECacheGet _ | ECacheSet _ | ECacheDelete _ | ECacheInvalidate _
  | ESendEmail _ | EStartEmailWorker _ | EWithDatabase _ | EWithCapabilities _ | EWithTransaction _
  | EServe _ | ELambda _ | ESqlQuery _ -> raise Unsupported
let fingerprint ~previous ~current expression =
  let root name = match String.split_on_char '.' name with
    | [family;version] when Migration_source.valid_family family && Migration_source.valid_revision version -> Some family
    | _ -> None in
  if previous = current || root previous = None || root previous <> root current then None else
  let rename name =
    let role prefix label = if name = prefix then Some label
      else if String.starts_with ~prefix:(prefix ^ ".") name then
        Some (label ^ String.sub name (String.length prefix) (String.length name - String.length prefix)) else None in
    match role previous "@from",role current "@to" with Some name,_ | _,Some name -> name | _ -> name in
  try Some (Migration_hash.digest (C.encode (node "migration-generated-node-v1" [shape rename expression])))
  with Unsupported -> None
let layout = function Token.INDENT | Token.DEDENT | Token.NEWLINE | Token.EOF -> true | _ -> false
let offset t (token : Lexer.full_token) =
  if token.line < 0 || token.line >= Array.length t.lines then reject "token is outside the source";
  let line = t.lines.(token.line) in
  let bytes = ref 0 and columns = ref 0 in
  while !bytes < String.length line && (line.[!bytes] = ' ' || line.[!bytes] = '\t') do
    columns := !columns + (if line.[!bytes] = '\t' then 8 else 1); incr bytes
  done;
  let column = !bytes + token.col - !columns in
  if column < 0 || column > String.length line then reject "token column is outside the source";
  t.offsets.(token.line) + column
let token_end t token =
  let first = offset t token in
  let limit = t.offsets.(token.Lexer.line) + String.length t.lines.(token.line) in
  let scan predicate =
    let i = ref first in
    while !i < limit && predicate t.source.[!i] do incr i done;
    if !i = first then reject "empty token range"; !i in
  match token.Lexer.tok with
  | Token.IDENT name | Token.UIDENT name -> first + String.length name
  | Token.INT _ | Token.BIGINT _ -> scan (function '0'..'9' -> true | _ -> false)
  | Token.FLOAT _ -> scan (function '0'..'9' | '.' -> true | _ -> false)
  | Token.TRUE -> first + 4 | Token.FALSE -> first + 5
  | Token.RBRACKET | Token.RBRACE | Token.RPAREN -> first + 1
  | Token.STRING _ ->
    if t.source.[first] <> '"' then reject "string token does not start with a quote";
    let rec closing i =
      if i >= limit then reject "unterminated source string";
      match t.source.[i] with '"' -> i + 1 | '\\' -> closing (i+2) | _ -> closing (i+1) in
    closing (first+1)
  | _ -> reject "unsupported migration data token boundary"
let first_token t expression =
  if not (Nodes.mem t.nodes expression) then reject "expression does not belong to this source view";
  let loc = Checker.expr_loc expression in
  let first = ref None in
  Array.iteri (fun i (token : Lexer.full_token) ->
    if !first = None && token.line = loc.start.line && token.col = loc.start.col && not (layout token.tok) then first := Some i) t.tokens;
  match !first with Some i -> i | None -> reject "expression has no source token"
let range t expression = protect (fun () ->
  let first = first_token t expression in
  let expected = try shape Fun.id expression with Unsupported -> reject "unsupported migration data expression" in
  let stream = Parser.make_stream t.file (Array.to_list t.tokens) in
  stream.pos <- first; stream.migration_record_keys <- true;
  let parsed = match Parser.parse_expr stream with Ok expr -> expr | Err e -> reject e.msg in
  let actual = try shape Fun.id parsed with Unsupported -> reject "unsupported reparsed expression" in
  if expected <> actual then reject "source range does not reproduce its parsed expression";
  let last = ref (stream.pos - 1) in
  while !last >= first && layout t.tokens.(!last).tok do decr last done;
  if !last < first then reject "expression consumed no source tokens";
  {start_byte=offset t t.tokens.(first);end_byte=token_end t t.tokens.(!last)})
let collection_members = function
  | ERecord {fields;type_hint=None;_} ->
    if List.length (List.sort_uniq String.compare (List.map fst fields)) <> List.length fields then
      reject "duplicate collection field";
    List.map (fun (key,value) -> Some key,value) fields
  | EList {elems;_} -> List.map (fun value -> None,value) elems
  | _ -> reject "expected a literal untyped record or list"
let members t expression = protect (fun () ->
  ignore (first_token t expression); collection_members expression)
let collection_range t expression = protect (fun () ->
  let first = first_token t expression in
  ignore (collection_members expression);
  let opening = match expression with ERecord _ -> Token.LBRACE | _ -> Token.LBRACKET in
  if t.tokens.(first).tok <> opening then reject "collection has no opening delimiter";
  let rec closing i stack =
    if i >= Array.length t.tokens then reject "unterminated collection";
    let stack = match t.tokens.(i).tok with
      | Token.LBRACE -> Token.RBRACE :: stack
      | Token.LBRACKET -> Token.RBRACKET :: stack
      | Token.LPAREN -> Token.RPAREN :: stack
      | (Token.RBRACE | Token.RBRACKET | Token.RPAREN) as token ->
        (match stack with expected :: rest when token = expected -> rest
         | _ -> reject "unbalanced collection delimiters")
      | _ -> stack in
    if stack = [] then i else closing (i+1) stack in
  let last = closing first [] in
  {start_byte=offset t t.tokens.(first);end_byte=token_end t t.tokens.(last)})
let member_range t ~collection expression = protect (fun () ->
  ignore (first_token t collection);
  let key = match List.filter (fun (_,value) -> value == expression) (collection_members collection) with
    | [key,_] -> key | _ -> reject "expression is not a direct member of this collection" in
  let value_range = match range t expression with Ok r -> r | Error e -> reject e.message in
  match key with
  | None -> value_range
  | Some key ->
    let rec previous i =
      if i < 0 then reject "missing record field tokens";
      if layout t.tokens.(i).tok then previous (i-1) else i in
    let colon = previous (first_token t expression - 1) in
    if t.tokens.(colon).tok <> Token.COLON then reject "record member has no colon separator";
    let last = previous (colon-1) in
    let rec name i = match t.tokens.(i).tok with
      | Token.UIDENT part when i >= 2 && t.tokens.(i-1).tok = Token.DOT ->
        let first,prefix = name (i-2) in first,prefix ^ "." ^ part
      | Token.UIDENT part | Token.IDENT part | Token.STRING part -> i,part
      | Token.EMAIL -> i,"email" | Token.SMTP -> i,"smtp" | Token.SCHEMA -> i,"schema"
      | Token.DATABASE -> i,"database" | Token.BACKEND -> i,"backend" | Token.API -> i,"api"
      | Token.TELEMETRY -> i,"telemetry"
      | _ -> reject "unsupported record field key" in
    let first,actual = name last in
    if actual <> key then reject "record key tokens do not match the parsed field";
    let first = offset t t.tokens.(first) in
    let bounds = match collection_range t collection with Ok r -> r | Error e -> reject e.message in
    if first <= bounds.start_byte || value_range.end_byte >= bounds.end_byte then reject "member is outside its collection";
    {value_range with start_byte=first})
let text t range = String.sub t.source range.start_byte (range.end_byte-range.start_byte)
let replace t edits = protect (fun () ->
  let edits = List.sort (fun (a,_) (b,_) -> compare (a.start_byte,a.end_byte) (b.start_byte,b.end_byte)) edits in
  let output = Buffer.create (String.length t.source) and position = ref 0 and previous = ref None in
  List.iter (fun (range,replacement) ->
    if range.start_byte < !position || range.end_byte < range.start_byte || range.end_byte > String.length t.source then
      reject "overlapping or out-of-bounds source edits";
    if range.start_byte = range.end_byte && !previous = Some range then reject "duplicate insertion point";
    Buffer.add_substring output t.source !position (range.start_byte - !position);
    Buffer.add_string output replacement; position := range.end_byte; previous := Some range) edits;
  Buffer.add_substring output t.source !position (String.length t.source - !position);
  let source = Buffer.contents output in
  (match Parser.parse_module t.file source with Ok _ -> () | Err e -> reject e.msg);
  source)
