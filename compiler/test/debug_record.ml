let () =
  let src = "handler f(\n    user: String,\n    req: String)\n  -> String\n" in
  let toks = Lexer.tokenize "P" src in
  List.iter (fun t ->
    let buf = Buffer.create 10 in
    let fmt = Format.formatter_of_buffer buf in
    Token.pp fmt t.Lexer.tok;
    Format.pp_print_flush fmt ();
    Printf.printf "L%d:C%d %s\n" t.Lexer.line t.Lexer.col (Buffer.contents buf)
  ) toks
