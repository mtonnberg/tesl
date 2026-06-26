(** Token types for the Tesl lexer. *)

type t =
  (* ── Structure ──────────────────────────────────────────────────────────── *)
  | INDENT               (** indentation increased *)
  | DEDENT               (** indentation decreased *)
  | NEWLINE              (** end of logical line *)
  (* ── Literals ───────────────────────────────────────────────────────────── *)
  | INT     of int
  | FLOAT   of float
  | STRING  of string    (** plain string, escapes already resolved *)
  | INTERP  of string    (** raw interpolated-string source, e.g. "hi ${x}!" *)
  | TRUE
  | FALSE
  (* ── Identifiers ────────────────────────────────────────────────────────── *)
  | IDENT   of string    (** lowercase identifier *)
  | UIDENT  of string    (** uppercase identifier / constructor / type name *)
  (* ── Keywords ───────────────────────────────────────────────────────────── *)
  | HASH_LANG            (** #lang *)
  | TESL                 (** tesl — after #lang *)
  | MODULE
  | LIBRARY  (** library keyword — explicit library module declaration *)
  | EXPOSING
  | IMPORT
  | FN
  | HANDLER
  | CHECK
  | AUTH
  | CAPTURE
  | ESTABLISH
  | FACT
  | TYPE
  | RECORD
  | ENTITY
  | TABLE
  | PRIMARY_KEY
  | CODEC
  | DATABASE
  | BACKEND
  | SCHEMA
  | API
  | SERVER
  | FOR
  | QUEUE
  | CHANNEL
  | WORKERS
  | DEAD_WORKERS         (** deadWorkers *)
  | CACHE                (** cache *)
  | EMAIL                (** email *)
  | SMTP                 (** smtp *)
  | CAPABILITY
  | IMPLIES
  | CASE
  | OF
  | LET
  | IF
  | THEN
  | ELSE
  | OK
  | FAIL
  | REQUIRES
  | USING
  | CONST
  | MAIN
  | WORKER
  | DEAD_WORKER          (** deadWorker *)
  | TEST
  | API_TEST             (** api-test *)
  | LOAD_TEST            (** load-test *)
  | PROPERTY
  | EXPECT
  | EXPECT_FAIL          (** expectFail *)
  | EXPECT_HAS_PROOF     (** expectHasProof *)
  | SEED
  | WITH_CODEC           (** with_codec *)
  | VIA
  | TO_JSON              (** toJson *)
  | FROM_JSON            (** fromJson *)
  | TO_JSON_FORBIDDEN    (** toJson_forbidden *)
  | FROM_JSON_FORBIDDEN  (** fromJson_forbidden *)
  | ADT_JSON             (** adtJson *)
  | INJECT
  | SUBSCRIBE
  | PUBLISH
  | SSE
  | TELEMETRY
  | NULL
  | NOTHING
  | SOMETHING
  | POSIX_MILLIS
  | FORGET_FACT          (** forgetFact *)
  | DETACH_FACT          (** detachFact *)
  | EXTRACT_FACT         (** extractFact *)
  | ATTACH_FACT          (** attachFact *)
  (* ── Punctuation / operators ─────────────────────────────────────────────── *)
  | ARROW                (** -> *)
  | FAT_ARROW            (** => *)
  | PROOF_ANNOT          (** ::: *)
  | COLON                (** : *)
  | DOUBLE_COLON         (** :: *)
  | EQ                   (** = *)
  | EQ_EQ                (** == *)
  | NEQ                  (** != *)
  | LT                   (** < *)
  | LE                   (** <= *)
  | GT                   (** > *)
  | GE                   (** >= *)
  | COMMA
  | DOT
  | STAR                 (** * — raw access and multiplication *)
  | SLASH                (** / *)
  | PERCENT              (** % — modulo *)
  | PLUS
  | PLUS_PLUS            (** ++ — string concatenation *)
  | MINUS
  | BANG                 (** ! *)
  | DOUBLE_AMP           (** && *)
  | AMP                  (** & — single ampersand *)
  | PIPE                 (** | *)
  | DOUBLE_PIPE          (** || — logical OR *)
  | PIPE_RIGHT           (** |> — pipe operator *)
  | PIPE_LEFT            (** <| — reverse pipe operator *)
  | QUESTION             (** ? — named-pack return spec *)
  | AT                   (** @ — db annotation *)
  | BACKARROW            (** <- — codec fromJson *)
  | LBRACE
  | RBRACE
  | LPAREN
  | RPAREN
  | LBRACKET
  | RBRACKET
  | UNDERSCORE           (** _ *)
  | DOTDOT               (** .. — used in Color(..) exports *)
  (* ── End of input ────────────────────────────────────────────────────────── *)
  | EOF

let pp fmt t =
  let s = match t with
    | INDENT -> "INDENT" | DEDENT -> "DEDENT" | NEWLINE -> "NEWLINE"
    | INT n -> string_of_int n | FLOAT f -> string_of_float f
    | STRING s -> Printf.sprintf "%S" s | INTERP s -> Printf.sprintf "INTERP(%S)" s
    | TRUE -> "true" | FALSE -> "false"
    | IDENT s -> s | UIDENT s -> s
    | HASH_LANG -> "#lang" | TESL -> "tesl"
    | MODULE -> "module" | LIBRARY -> "library" | EXPOSING -> "exposing" | IMPORT -> "import"
    | FN -> "fn" | HANDLER -> "handler" | CHECK -> "check" | AUTH -> "auth"
    | CAPTURE -> "capture" | ESTABLISH -> "establish" | FACT -> "fact"
    | TYPE -> "type" | RECORD -> "record" | ENTITY -> "entity"
    | TABLE -> "table" | PRIMARY_KEY -> "primaryKey"
    | CODEC -> "codec" | DATABASE -> "database" | BACKEND -> "backend"
    | SCHEMA -> "schema" | API -> "api" | SERVER -> "server"
    | FOR -> "for" | QUEUE -> "queue" | CHANNEL -> "channel"
    | WORKERS -> "workers" | DEAD_WORKERS -> "deadWorkers" | CACHE -> "cache"
    | EMAIL -> "email" | SMTP -> "smtp"
    | CAPABILITY -> "capability" | IMPLIES -> "implies"
    | CASE -> "case" | OF -> "of" | LET -> "let" | IF -> "if"
    | THEN -> "then" | ELSE -> "else" | OK -> "ok" | FAIL -> "fail"
    | REQUIRES -> "requires" | USING -> "using" | CONST -> "const"
    | MAIN -> "main" | WORKER -> "worker" | DEAD_WORKER -> "deadWorker"
    | TEST -> "test" | API_TEST -> "api-test" | LOAD_TEST -> "load-test"
    | PROPERTY -> "property"
    | EXPECT -> "expect" | EXPECT_FAIL -> "expectFail"
    | EXPECT_HAS_PROOF -> "expectHasProof" | SEED -> "seed"
    | WITH_CODEC -> "with_codec" | VIA -> "via"
    | TO_JSON -> "toJson" | FROM_JSON -> "fromJson"
    | TO_JSON_FORBIDDEN -> "toJson_forbidden"
    | FROM_JSON_FORBIDDEN -> "fromJson_forbidden"
    | ADT_JSON -> "adtJson" | INJECT -> "inject"
    | SUBSCRIBE -> "subscribe" | PUBLISH -> "publish"
    | SSE -> "sse" | TELEMETRY -> "telemetry"
    | NULL -> "null" | NOTHING -> "Nothing" | SOMETHING -> "Something"
    | POSIX_MILLIS -> "PosixMillis"
    | FORGET_FACT -> "forgetFact" | DETACH_FACT -> "detachFact"
    | EXTRACT_FACT -> "extractFact" | ATTACH_FACT -> "attachFact"
    | ARROW -> "->" | FAT_ARROW -> "=>"
    | PROOF_ANNOT -> ":::" | COLON -> ":" | DOUBLE_COLON -> "::"
    | EQ -> "=" | EQ_EQ -> "==" | NEQ -> "!=" | LT -> "<" | LE -> "<="
    | GT -> ">" | GE -> ">="
    | COMMA -> "," | DOT -> "." | STAR -> "*" | SLASH -> "/" | PERCENT -> "%" | PLUS -> "+" | PLUS_PLUS -> "++"
    | MINUS -> "-" | BANG -> "!" | DOUBLE_AMP -> "&&" | AMP -> "&"
    | PIPE -> "|" | DOUBLE_PIPE -> "||" | PIPE_RIGHT -> "|>" | PIPE_LEFT -> "<|" | QUESTION -> "?" | AT -> "@" | BACKARROW -> "<-"
    | LBRACE -> "{" | RBRACE -> "}" | LPAREN -> "(" | RPAREN -> ")"
    | LBRACKET -> "[" | RBRACKET -> "]"
    | UNDERSCORE -> "_" | DOTDOT -> ".." | EOF -> "EOF"
  in
  Format.pp_print_string fmt s
