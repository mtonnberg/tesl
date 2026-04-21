let () =
  let src = {|#lang tesl
module Foo exposing []
database DB {
  postgres {
    database "mydb"
  }
}
|} in
  let toks = Lexer.tokenize "<test>" src in
  Printf.printf "=== TOKENS ===\n";
  List.iter (fun t ->
    let buf = Buffer.create 10 in
    let fmt = Format.formatter_of_buffer buf in
    Token.pp fmt t.Lexer.tok;
    Format.pp_print_flush fmt ();
    Printf.printf "  L%d:C%d %s\n" t.Lexer.line t.Lexer.col (Buffer.contents buf)
  ) toks;
  Printf.printf "\n=== PARSE ===\n";
  match Parser.parse_module "<test>" src with
  | Ok m -> Printf.printf "OK: module=%s, decls=%d\n" m.module_name (List.length m.decls)
  | Err e -> Printf.printf "ERR: %s at L%d:C%d\n" e.msg (e.loc.start.line+1) (e.loc.start.col+1)
