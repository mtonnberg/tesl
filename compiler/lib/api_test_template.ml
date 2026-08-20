open Ast

type part =
  | Literal of string
  | Expr of expr

let parse_expr expr_text =
  let text = String.trim expr_text in
  if text = "" then None
  else
    match Lexer.tokenize "<api-test-template>" text with
    | exception _ -> None
    | tokens ->
      let stream = Parser.make_stream "<api-test-template>" tokens in
      (match Parser.parse_expr stream with
       | Ok expression ->
         let rec layout_only () =
           match Parser.peek stream with
           | Token.EOF -> true
           | Token.NEWLINE | Token.INDENT | Token.DEDENT ->
             Parser.advance stream; layout_only ()
           | _ -> false
         in
         if layout_only () then Some expression else None
       | Err _ -> None)

let parse content =
  let len = String.length content in
  let parts = ref [] in
  let cursor = ref 0 in
  while !cursor < len do
    match String.index_from_opt content !cursor '{' with
    | None ->
      if !cursor < len then
        parts := Literal (String.sub content !cursor (len - !cursor)) :: !parts;
      cursor := len
    | Some open_brace ->
      if open_brace > !cursor then
        parts := Literal (String.sub content !cursor (open_brace - !cursor)) :: !parts;
      (match String.index_from_opt content (open_brace + 1) '}' with
       | None ->
         parts := Literal (String.sub content open_brace (len - open_brace)) :: !parts;
         cursor := len
       | Some close_brace ->
         let expr_text = String.sub content (open_brace + 1)
             (close_brace - open_brace - 1) in
         (match parse_expr expr_text with
          | Some expression -> parts := Expr expression :: !parts
          | None ->
            parts := Literal
                (String.sub content open_brace (close_brace - open_brace + 1))
                :: !parts);
         cursor := close_brace + 1)
  done;
  List.rev !parts
