{
(* Tesl lexer - produces tokens including INDENT/DEDENT for
   indentation-sensitive constructs (function bodies, case arms).

   The main entry point is Lexer.tokenize, which returns a full token
   stream with INDENT/DEDENT/NEWLINE tokens. *)

open Token

(* Keyword table *)

let keywords : (string, Token.t) Hashtbl.t =
  let h = Hashtbl.create 64 in
  List.iter (fun (k, v) -> Hashtbl.add h k v) [
    "module",      MODULE;
    "exposing",    EXPOSING;
    "import",      IMPORT;
    "fn",          FN;
    "handler",     HANDLER;
    "check",       CHECK;
    "auth",        AUTH;
    "capture",     CAPTURE;
    "establish",   ESTABLISH;
    "fact",        FACT;
    "type",        TYPE;
    "record",      RECORD;
    "entity",      ENTITY;
    "table",       TABLE;
    "primaryKey",  PRIMARY_KEY;
    "codec",       CODEC;
    "database",    DATABASE;
    "backend",     BACKEND;
    "schema",      SCHEMA;
    "api",         API;
    "server",      SERVER;
    "for",         FOR;
    "queue",       QUEUE;
    "channel",     CHANNEL;
    "workers",     WORKERS;
    "deadWorkers", DEAD_WORKERS;
    "capability",  CAPABILITY;
    "implies",     IMPLIES;
    "case",        CASE;
    "of",          OF;
    "let",         LET;
    "if",          IF;
    "then",        THEN;
    "else",        ELSE;
    "ok",          OK;
    "fail",        FAIL;
    "requires",    REQUIRES;
    "using",       USING;
    "const",       CONST;
    "main",        MAIN;
    "worker",      WORKER;
    "deadWorker",  DEAD_WORKER;
    "test",        TEST;
    "property",    PROPERTY;
    "expect",      EXPECT;
    "expectFail",  EXPECT_FAIL;
    "expectHasProof", EXPECT_HAS_PROOF;
    "seed",        SEED;
    "with_codec",  WITH_CODEC;
    "via",         VIA;
    "toJson",      TO_JSON;
    "fromJson",    FROM_JSON;
    "toJson_forbidden",   TO_JSON_FORBIDDEN;
    "fromJson_forbidden", FROM_JSON_FORBIDDEN;
    "adtJson",     ADT_JSON;
    "inject",      INJECT;
    "subscribe",   SUBSCRIBE;
    "publish",     PUBLISH;
    "sse",         SSE;
    "telemetry",   TELEMETRY;
    "null",        NULL;
    "Nothing",     NOTHING;
    "Something",   SOMETHING;
    "PosixMillis", POSIX_MILLIS;
    "forgetFact",  FORGET_FACT;
    "detachFact",  DETACH_FACT;
    "extractFact", EXTRACT_FACT;
    "attachFact",  ATTACH_FACT;
    "true",        TRUE;
    "false",       FALSE;
    "tesl",        TESL;
  ];
  h

let lookup_ident s =
  match Hashtbl.find_opt keywords s with
  | Some tok -> tok
  | None ->
    if String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'
    then UIDENT s
    else IDENT s

(* String scanning buffer *)
let string_buf : Buffer.t = Buffer.create 64

let process_string_content raw =
  if String.contains raw '$' then INTERP raw
  else begin
    let buf = Buffer.create (String.length raw) in
    let i = ref 0 in
    while !i < String.length raw do
      if raw.[!i] = '\\' && !i + 1 < String.length raw then begin
        (match raw.[!i + 1] with
        | 'n'  -> Buffer.add_char buf '\n'
        | 't'  -> Buffer.add_char buf '\t'
        | 'r'  -> Buffer.add_char buf '\r'
        | '\\' -> Buffer.add_char buf '\\'
        | '"'  -> Buffer.add_char buf '"'
        | c    -> Buffer.add_char buf '\\'; Buffer.add_char buf c);
        i := !i + 2
      end else begin
        Buffer.add_char buf raw.[!i];
        i := !i + 1
      end
    done;
    STRING (Buffer.contents buf)
  end

let get_pos lexbuf =
  let p = Lexing.lexeme_start_p lexbuf in
  (p.pos_lnum - 1, p.pos_cnum - p.pos_bol)

type positioned = Token.t * int * int
}

(* Lexer rules *)

let digit   = ['0'-'9']
let alpha   = ['a'-'z' 'A'-'Z']
let ident_c = alpha | digit | '_'
let lower   = ['a'-'z']
let upper   = ['A'-'Z']

(* Tokenize a single logical line - returns list of (token, line, col) *)
rule token_line acc = parse
  | [' ' '\t']+         { token_line acc lexbuf }
  | '\n' | '\r' | eof   { List.rev acc }
  | '#' [^ '\n']* '\n'? { List.rev acc }
  | "api-test"          { let (l,c) = get_pos lexbuf in
                          token_line ((API_TEST,l,c)::acc) lexbuf }
  | "load-test"         { let (l,c) = get_pos lexbuf in
                          token_line ((LOAD_TEST,l,c)::acc) lexbuf }
  | digit+ '.' digit+
      { let (l,c) = get_pos lexbuf in
        let f = float_of_string (Lexing.lexeme lexbuf) in
        token_line ((FLOAT f,l,c)::acc) lexbuf }
  | digit+
      { let (l,c) = get_pos lexbuf in
        let s = Lexing.lexeme lexbuf in
        (* Parse as Int64 first to handle the boundary value 2^62 = 4611686018427387904,
           which is the absolute value of OCaml min_int and only valid as -2^62 in Tesl. *)
        let n64 = (try Int64.of_string s
                   with Failure _ ->
                     failwith (Printf.sprintf
                       "integer literal `%s` at line %d col %d is out of range; \
                        Tesl Int is a 63-bit fixnum (range: -2^62 to 2^62-1)"
                       s l c))
        in
        (* 2^62 = 4611686018427387904: only valid under unary minus as -2^62.
           We use the sentinel value min_int to signal this to the parser. *)
        let min_int_boundary64 = Int64.of_string "4611686018427387904" in
        let max_int64 = Int64.of_int max_int in
        let n =
          if Int64.compare n64 min_int_boundary64 = 0 then
            min_int  (* sentinel: must appear under unary minus *)
          else if Int64.compare n64 max_int64 <= 0 && Int64.compare n64 0L >= 0 then
            Int64.to_int n64
          else
            failwith (Printf.sprintf
              "integer literal `%s` at line %d col %d is out of range; \
               Tesl Int is a 63-bit fixnum (max positive value: %d = 2^62-1)"
              s l c max_int)
        in
        token_line ((INT n,l,c)::acc) lexbuf }
  | '"'
      { let (l,c) = get_pos lexbuf in
        Buffer.clear string_buf;
        let raw = scan_string lexbuf in
        let tok = process_string_content raw in
        token_line ((tok,l,c)::acc) lexbuf }
  | '_' ident_c+
      { let (l,c) = get_pos lexbuf in
        let s = Lexing.lexeme lexbuf in
        let tok = lookup_ident s in
        token_line ((tok,l,c)::acc) lexbuf }
  | '_'
      { let (l,c) = get_pos lexbuf in token_line ((UNDERSCORE,l,c)::acc) lexbuf }
  | lower ident_c*
      { let (l,c) = get_pos lexbuf in
        let s = Lexing.lexeme lexbuf in
        let tok = lookup_ident s in
        token_line ((tok,l,c)::acc) lexbuf }
  | upper ident_c*
      { let (l,c) = get_pos lexbuf in
        let s = Lexing.lexeme lexbuf in
        let tok = lookup_ident s in
        token_line ((tok,l,c)::acc) lexbuf }
  | ":::"     { let (l,c) = get_pos lexbuf in token_line ((PROOF_ANNOT,l,c)::acc) lexbuf }
  | "::"      { let (l,c) = get_pos lexbuf in token_line ((DOUBLE_COLON,l,c)::acc) lexbuf }
  | ":"       { let (l,c) = get_pos lexbuf in token_line ((COLON,l,c)::acc) lexbuf }
  | "=>"      { let (l,c) = get_pos lexbuf in token_line ((FAT_ARROW,l,c)::acc) lexbuf }
  | "=="      { let (l,c) = get_pos lexbuf in token_line ((EQ_EQ,l,c)::acc) lexbuf }
  | "="       { let (l,c) = get_pos lexbuf in token_line ((EQ,l,c)::acc) lexbuf }
  | "!="      { let (l,c) = get_pos lexbuf in token_line ((NEQ,l,c)::acc) lexbuf }
  | "!"       { let (l,c) = get_pos lexbuf in token_line ((BANG,l,c)::acc) lexbuf }
  | "<="      { let (l,c) = get_pos lexbuf in token_line ((LE,l,c)::acc) lexbuf }
  | "<-"      { let (l,c) = get_pos lexbuf in token_line ((BACKARROW,l,c)::acc) lexbuf }
  | "<"       { let (l,c) = get_pos lexbuf in token_line ((LT,l,c)::acc) lexbuf }
  | ">="      { let (l,c) = get_pos lexbuf in token_line ((GE,l,c)::acc) lexbuf }
  | ">"       { let (l,c) = get_pos lexbuf in token_line ((GT,l,c)::acc) lexbuf }
  | "->"      { let (l,c) = get_pos lexbuf in token_line ((ARROW,l,c)::acc) lexbuf }
  | "-"       { let (l,c) = get_pos lexbuf in token_line ((MINUS,l,c)::acc) lexbuf }
  | "++"      { let (l,c) = get_pos lexbuf in token_line ((PLUS_PLUS,l,c)::acc) lexbuf }
  | "+"       { let (l,c) = get_pos lexbuf in token_line ((PLUS,l,c)::acc) lexbuf }
  | "*"       { let (l,c) = get_pos lexbuf in token_line ((STAR,l,c)::acc) lexbuf }
  | "/"       { let (l,c) = get_pos lexbuf in token_line ((SLASH,l,c)::acc) lexbuf }
  | "%"       { let (l,c) = get_pos lexbuf in token_line ((PERCENT,l,c)::acc) lexbuf }
  | "&&"      { let (l,c) = get_pos lexbuf in token_line ((DOUBLE_AMP,l,c)::acc) lexbuf }
  | "&"       { let (l,c) = get_pos lexbuf in token_line ((AMP,l,c)::acc) lexbuf }
  | "||"      { let (l,c) = get_pos lexbuf in token_line ((DOUBLE_PIPE,l,c)::acc) lexbuf }
  | "|>"      { let (l,c) = get_pos lexbuf in token_line ((PIPE_RIGHT,l,c)::acc) lexbuf }
  | "|"       { let (l,c) = get_pos lexbuf in token_line ((PIPE,l,c)::acc) lexbuf }
  | "<|"      { let (l,c) = get_pos lexbuf in token_line ((PIPE_LEFT,l,c)::acc) lexbuf }
  | "?"       { let (l,c) = get_pos lexbuf in token_line ((QUESTION,l,c)::acc) lexbuf }
  | "@"       { let (l,c) = get_pos lexbuf in token_line ((AT,l,c)::acc) lexbuf }
  | ".."      { let (l,c) = get_pos lexbuf in token_line ((DOTDOT,l,c)::acc) lexbuf }
  | "."       { let (l,c) = get_pos lexbuf in token_line ((DOT,l,c)::acc) lexbuf }
  | ","       { let (l,c) = get_pos lexbuf in token_line ((COMMA,l,c)::acc) lexbuf }
  | "{"       { let (l,c) = get_pos lexbuf in token_line ((LBRACE,l,c)::acc) lexbuf }
  | "}"       { let (l,c) = get_pos lexbuf in token_line ((RBRACE,l,c)::acc) lexbuf }
  | "("       { let (l,c) = get_pos lexbuf in token_line ((LPAREN,l,c)::acc) lexbuf }
  | ")"       { let (l,c) = get_pos lexbuf in token_line ((RPAREN,l,c)::acc) lexbuf }
  | "["       { let (l,c) = get_pos lexbuf in token_line ((LBRACKET,l,c)::acc) lexbuf }
  | "]"       { let (l,c) = get_pos lexbuf in token_line ((RBRACKET,l,c)::acc) lexbuf }
  (* underscore alone handled above in identifier rules *)
  | _ as c    { failwith (Printf.sprintf "unexpected character: %C" c) }
  | eof       { List.rev acc }

(* Scan inside a double-quoted string - returns raw content *)
and scan_string = parse
  | '"'       { Buffer.contents string_buf }
  | "\\n"     { Buffer.add_char string_buf '\n'; scan_string lexbuf }
  | "\\t"     { Buffer.add_char string_buf '\t'; scan_string lexbuf }
  | "\\r"     { Buffer.add_char string_buf '\r'; scan_string lexbuf }
  | "\\\\"    { Buffer.add_char string_buf '\\'; scan_string lexbuf }
  | "\\\""    { Buffer.add_char string_buf '"';  scan_string lexbuf }
  (* R51_X04 — reject unknown escape sequences. Previously any
     backslash-char not listed above was silently kept as two characters.
     The spec lists exactly the five escapes handled above as supported. *)
  | '\\' (_ as c)
      { failwith (Printf.sprintf "invalid string escape: backslash %c" c) }
  | [^ '"' '\\' '\n']+
      { Buffer.add_string string_buf (Lexing.lexeme lexbuf); scan_string lexbuf }
  | '\n'      { failwith "unterminated string literal" }
  | eof       { failwith "unterminated string literal at EOF" }
  | _ as c    { Buffer.add_char string_buf c; scan_string lexbuf }

{
(* Full-file tokenizer *)

type full_token = {
  tok  : Token.t;
  line : int;
  col  : int;
}

let tokenize (filename : string) (source : string) : full_token list =
  let lines = String.split_on_char '\n' source in
  let result : full_token list ref = ref [] in
  let emit tok line col = result := { tok; line; col } :: !result in

  let indent_stack = ref [0] in
  let line_num = ref 0 in

  List.iter (fun raw_line ->
    let lnum = !line_num in
    incr line_num;

    let trimmed = String.trim raw_line in

    (* Skip blank lines *)
    if trimmed = "" then ()
    (* Handle #lang line - emit special tokens, don't track indentation *)
    else if String.length trimmed >= 5 && String.sub trimmed 0 5 = "#lang" then begin
      emit HASH_LANG lnum 0;
      (* rest of line after "#lang " *)
      let rest = String.trim (String.sub trimmed 5 (String.length trimmed - 5)) in
      if rest <> "" then begin
        let lb = Lexing.from_string rest in
        Lexing.set_position lb {
          Lexing.pos_fname = filename;
          pos_lnum = lnum + 1; pos_bol = 0; pos_cnum = 0
        };
        let toks = token_line [] lb in
        List.iter (fun (tok, _l, c) -> emit tok lnum (6 + c)) toks
      end;
      emit NEWLINE lnum (String.length raw_line)
    end
    (* Skip comment-only lines *)
    else if String.length trimmed > 0 && trimmed.[0] = '#' then ()
    else begin
      (* Count leading spaces *)
      let indent = ref 0 in
      let i = ref 0 in
      while !i < String.length raw_line &&
            (raw_line.[!i] = ' ' || raw_line.[!i] = '\t') do
        (if raw_line.[!i] = '\t' then indent := !indent + 8
         else indent := !indent + 1);
        incr i
      done;
      let col0 = !indent in
      let cur_indent = col0 in

      (* Emit INDENT/DEDENT based on level change *)
      let top = List.hd !indent_stack in
      if cur_indent > top then begin
        indent_stack := cur_indent :: !indent_stack;
        emit INDENT lnum 0
      end else if cur_indent < top then begin
        let rec pop () =
          match !indent_stack with
          | [] | [_] -> ()
          | _ :: rest ->
            let next_top = List.hd rest in
            emit DEDENT lnum 0;
            indent_stack := rest;
            if next_top > cur_indent then pop ()
        in
        pop ()
      end;

      (* Tokenize content of this line *)
      let content = String.sub raw_line !i (String.length raw_line - !i) in
      let lexbuf = Lexing.from_string content in
      Lexing.set_position lexbuf {
        Lexing.pos_fname = filename;
        pos_lnum = lnum + 1;
        pos_bol  = 0;
        pos_cnum = 0;
      };
      let toks = token_line [] lexbuf in

      List.iter (fun (tok, _l, c) ->
        emit tok lnum (col0 + c)
      ) toks;

      if toks <> [] then
        emit NEWLINE lnum (String.length raw_line)
    end
  ) lines;

  (* Close remaining indentation levels *)
  let rec pop_all () =
    match !indent_stack with
    | [] | [_] -> ()
    | _ :: rest ->
      emit DEDENT !line_num 0;
      indent_stack := rest;
      pop_all ()
  in
  pop_all ();

  emit EOF !line_num 0;

  List.rev !result
}
