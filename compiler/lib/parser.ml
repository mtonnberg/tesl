(** Recursive descent parser for Tesl.

    Consumes the token stream produced by [Lexer.tokenize] and builds the
    typed [Ast.module_form].  Every public function returns an error value
    rather than raising an exception so callers can accumulate diagnostics. *)

open Ast
open Location
open Token

(* ── Error type ─────────────────────────────────────────────────────────── *)

type parse_error = {
  msg : string;
  loc : loc;
}

type 'a result = Ok of 'a | Err of parse_error

(* ── Token stream ────────────────────────────────────────────────────────── *)

type stream = {
  tokens : Lexer.full_token array;
  mutable pos : int;
  filename : string;
  mutable allow_test_multiline_request_continuations : bool;
  (* Captures the pack proof from the last `(T ? P)` parsed in type position.
     Set by parse_type_atom when it encounters `? P` inside parentheses;
     read by parse_return_spec_no_arrow to create proof-carrying return specs
     for generic wrappers like `Either X (T ? P)` or `Custom L (T ? P)`. *)
  mutable last_type_pack_proof : Ast.proof_expr option;
}

let make_stream filename tokens =
  { tokens = Array.of_list tokens; pos = 0; filename;
    allow_test_multiline_request_continuations = false;
    last_type_pack_proof = None }

let peek s =
  if s.pos < Array.length s.tokens then s.tokens.(s.pos).tok
  else EOF

let peek2 s =
  if s.pos + 1 < Array.length s.tokens then s.tokens.(s.pos + 1).tok
  else EOF

(** True when the token at [offset] is immediately adjacent (no whitespace) to
    the token at [offset - 1].  Used to distinguish  [f -3]  (argument)  from
    [x - 3]  (binary subtraction): the minus is adjacent to the digit only in
    the negative-literal case. *)
let adjacent s offset =
  if offset < 1 || offset >= Array.length s.tokens then false
  else
    let prev = s.tokens.(offset - 1) in
    let curr = s.tokens.(offset) in
    prev.Lexer.line = curr.Lexer.line &&
    prev.Lexer.col + 1 = curr.Lexer.col

let current_loc s =
  if s.pos < Array.length s.tokens then
    let t = s.tokens.(s.pos) in
    make_loc s.filename t.line t.col t.line (t.col + 1)
  else dummy_loc s.filename

(* Location of the most recently consumed token — the precise END of a
   just-parsed form (current_loc would give the NEXT token instead, which for a
   statement ending at end-of-line points past the statement). *)
let last_consumed_loc s =
  if s.pos > 0 && s.pos - 1 < Array.length s.tokens then
    let t = s.tokens.(s.pos - 1) in
    make_loc s.filename t.line t.col t.line (t.col + 1)
  else dummy_loc s.filename

let advance s =
  if s.pos < Array.length s.tokens then s.pos <- s.pos + 1

let consume s =
  let t = if s.pos < Array.length s.tokens then s.tokens.(s.pos) else
    { tok = EOF; line = 0; col = 0 }
  in
  advance s; t

let tok_loc s tok_record =
  make_loc s.filename tok_record.Lexer.line tok_record.Lexer.col
    tok_record.Lexer.line (tok_record.Lexer.col + 1)

let err s msg = Err { msg; loc = current_loc s }

let tok_to_string t =
  let buf = Buffer.create 16 in
  let fmt = Format.formatter_of_buffer buf in
  Token.pp fmt t;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let expect s tok =
  if peek s = tok then (advance s; Ok ())
  else err s (Printf.sprintf "expected %s but got %s"
                (tok_to_string tok) (tok_to_string (peek s)))

let expect_ident s =
  match peek s with
  | IDENT n -> advance s; Ok n
  (* Allow lowercase keywords as identifiers in binding positions.
     `test` is especially important: users often write helper fns named `test`.
     `ok` and `fail` can appear as parameter names in lambdas like fn(ok: Bool, ...). *)
  | TEST  -> advance s; Ok "test"
  | SEED  -> advance s; Ok "seed"
  | VIA   -> advance s; Ok "via"
  | FOR   -> advance s; Ok "for"
  | USING -> advance s; Ok "using"
  | MAIN  -> advance s; Ok "main"
  | OF    -> advance s; Ok "of"
  | OK    -> advance s; Ok "ok"
  | FAIL  -> advance s; Ok "fail"
  (* Allow "email" and "smtp" as parameter/binding names — they're common identifiers *)
  | EMAIL -> advance s; Ok "email"
  | SMTP  -> advance s; Ok "smtp"
  | t -> err s (Printf.sprintf "expected identifier, got %s" (tok_to_string t))

let expect_uident s =
  match peek s with
  | UIDENT n -> advance s; Ok n
  | t -> err s (Printf.sprintf "expected uppercase identifier, got %s" (tok_to_string t))

(* Accept either an IDENT or UIDENT — used where a codec name can be a
   user-defined type (uppercase) like IssueStatus or a primitive like stringCodec. *)
let expect_codec_name s =
  match peek s with
  | IDENT n  -> advance s; Ok n
  | UIDENT n -> advance s; Ok n
  | t -> err s (Printf.sprintf "expected codec name, got %s" (tok_to_string t))

let expect_string s =
  match peek s with
  | STRING str -> advance s; Ok str
  | t -> err s (Printf.sprintf "expected string literal, got %s" (tok_to_string t))

let expect_int s =
  match peek s with
  | INT n -> advance s; Ok n
  | t -> err s (Printf.sprintf "expected integer, got %s" (tok_to_string t))

(** Skip all NEWLINE tokens (used in expression contexts). *)
let skip_newlines s =
  while peek s = NEWLINE do advance s done

(** Skip NEWLINE, INDENT, and DEDENT tokens.
    Used inside brace-delimited blocks where layout is not semantic. *)
let skip_layout s =
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | NEWLINE | INDENT | DEDENT -> advance s
    | _ -> continue_ := false
  done

(** Skip NEWLINE tokens, return how many were skipped. *)
let skip_newlines_count s =
  let n = ref 0 in
  while peek s = NEWLINE do advance s; incr n done;
  !n

let with_test_multiline_request_continuations s f =
  let saved = s.allow_test_multiline_request_continuations in
  s.allow_test_multiline_request_continuations <- true;
  let result = f s in
  s.allow_test_multiline_request_continuations <- saved;
  result

let is_test_request_modifier_ident = function
  | "cookie" | "headers" | "header" | "query" | "body" -> true
  | _ -> false

(* ── Monadic helpers ─────────────────────────────────────────────────────── *)

let ( let* ) r f = match r with Ok x -> f x | Err e -> Err e
let ( >>= ) = ( let* )
let return x = Ok x

let map_result f = function Ok x -> Ok (f x) | Err e -> Err e

(** Get the identifier string for any token, treating keywords as their text.
    This is needed for import/export lists where keywords appear as names. *)
let token_as_ident = function
  | IDENT n | UIDENT n -> Some n
  | FN -> Some "fn" | HANDLER -> Some "handler" | CHECK -> Some "check"
  | AUTH -> Some "auth" | CAPTURE -> Some "capture" | CAPTURER -> Some "capturer" | TYPE -> Some "type"
  | FACT -> Some "fact" | RECORD -> Some "record" | ENTITY -> Some "entity" | TABLE -> Some "table"
  | DATABASE -> Some "database" | API -> Some "api" | SERVER -> Some "server"
  | QUEUE -> Some "queue" | CHANNEL -> Some "channel" | WORKERS -> Some "workers" | CACHE -> Some "cache"
  | EMAIL -> Some "email" | SMTP -> Some "smtp" | AGENT -> Some "agent"
  | CAPABILITY -> Some "capability" | CASE -> Some "case" | OF -> Some "of"
  | LET -> Some "let" | IF -> Some "if" | THEN -> Some "then" | ELSE -> Some "else"
  | OK -> Some "ok" | FAIL -> Some "fail" | REQUIRES -> Some "requires"
  | USING -> Some "using" | CONST -> Some "const" | MAIN -> Some "main"
  | WORKER -> Some "worker" | TEST -> Some "test" | PROPERTY -> Some "property"
  | EXPECT -> Some "expect" | SEED -> Some "seed" | VIA -> Some "via"
  | TO_JSON -> Some "toJson" | FROM_JSON -> Some "fromJson"
  | BACKEND -> Some "backend" | SCHEMA -> Some "schema"
  | SUBSCRIBE -> Some "subscribe" | PUBLISH -> Some "publish" | SSE -> Some "sse"
  | TELEMETRY -> Some "telemetry" | NULL -> Some "null"
  | NOTHING -> Some "Nothing" | SOMETHING -> Some "Something"
  | POSIX_MILLIS -> Some "PosixMillis"
  | FORGET_FACT -> Some "forgetFact" | DETACH_FACT -> Some "detachFact"
  | EXTRACT_FACT -> Some "extractFact" | ATTACH_FACT -> Some "attachFact"
  | ESTABLISH -> Some "establish" | IMPLIES -> Some "implies"
  | FOR -> Some "for"
  | _ -> None

(** Parse a comma-separated list inside brackets (non-empty). *)
let parse_bracketed_list parse_item s =
  let* _ = expect s LBRACKET in
  skip_layout s;
  let items = ref [] in
  let rec loop () =
    if peek s = RBRACKET then return ()
    else begin
      let* item = parse_item s in
      items := item :: !items;
      skip_layout s;
      if peek s = COMMA then begin advance s; skip_layout s; loop () end
      else return ()
    end
  in
  let* _ = loop () in
  let* _ = expect s RBRACKET in
  return (List.rev !items)

let parse_parenthesized_list parse_item s =
  let* _ = expect s LPAREN in
  skip_layout s;
  let items = ref [] in
  let rec loop () =
    if peek s = RPAREN then return ()
    else begin
      let* item = parse_item s in
      items := item :: !items;
      skip_layout s;
      if peek s = COMMA then begin advance s; skip_layout s; loop () end
      else return ()
    end
  in
  let* _ = loop () in
  let* _ = expect s RPAREN in
  return (List.rev !items)

(* ── Capability rows ──────────────────────────────────────────────────────
   A capability row is the `requires` payload: `[a, b]`, a bare `c`, or a
   parenthesized concatenation `([time] ++ c ++ c2)`.  It flattens to a plain
   name list; whether a name is a row *variable* or a concrete capability is
   decided later by the checker (a name is a variable iff it is bound by a
   parameter's arrow-type `requires`).  `cacheCap X` / `email` keep their special
   spellings, matching the bracketed form.  The per-cache capability is spelled
   `cacheCap <Name>` (NOT `cache <Name>`) so it doesn't collide with the `cache`
   declaration keyword — `cacheCap` is an ordinary identifier here. *)
let parse_cap_name s =
  match peek s with
  | IDENT "cacheCap" ->
    advance s;
    (match peek s with
     | UIDENT cache_name -> advance s; return ("cacheCap " ^ cache_name)
     | _ -> return "cacheCap")
  | IDENT n -> advance s; return n
  | EMAIL -> advance s; return "email"
  | t -> err s (Printf.sprintf "expected capability name, got %s" (tok_to_string t))

let rec parse_cap_term s =
  match peek s with
  | LBRACKET -> parse_bracketed_list parse_cap_name s
  | LPAREN ->
    advance s;
    let* r = parse_cap_row s in
    let* _ = expect s RPAREN in
    return r
  | _ -> let* n = parse_cap_name s in return [n]
and parse_cap_row s =
  let* first = parse_cap_term s in
  let rec loop acc =
    if peek s = PLUS_PLUS then begin
      advance s;
      let* more = parse_cap_term s in
      loop (acc @ more)
    end else
      return acc
  in
  loop first

(** `requires <cap-row>`, or [] when absent.  Used both for declaration
    `requires` clauses and for capability rows on parenthesized function types
    `(A -> B requires c)`. *)
let parse_requires s =
  if peek s = REQUIRES then begin
    advance s;
    parse_cap_row s
  end else
    return []

(** Try to parse something; backtrack on failure. *)
let try_parse s f =
  let saved = s.pos in
  match f s with
  | Ok x -> Ok (Some x)
  | Err _ -> s.pos <- saved; Ok None

(* ── Proof expressions ────────────────────────────────────────────────────── *)

(** Parse a proof predicate application: [ValidPort port] or [P x && Q x].
    We parse the first atomic part, then check for &&. *)
let rec parse_proof_expr s =
  let* left = parse_proof_atom s in
  if peek s = DOUBLE_AMP then begin
    advance s;
    let* right = parse_proof_expr s in
    let loc = span (match left with PredApp p -> p.loc | PredAnd p -> p.loc)
                   (match right with PredApp p -> p.loc | PredAnd p -> p.loc) in
    return (PredAnd { left; right; loc })
  end else
    return left

and parse_proof_atom s =
  match peek s with
  | LPAREN ->
    advance s;
    let* proof = parse_proof_expr s in
    let* _ = expect s RPAREN in
    return proof
  | _ ->
    (* Proof atom: PredicateName followed by zero or more argument names *)
    let loc0 = current_loc s in
    let* pred_name = match peek s with
      | UIDENT n -> advance s; Ok n
      | IDENT n  -> advance s; Ok n
      | _ ->
        (* Allow keyword tokens as proof predicate names *)
        (match token_as_ident (peek s) with
         | Some n -> advance s; Ok n
         | None -> err s (Printf.sprintf "expected proof predicate, got %s" (tok_to_string (peek s))))
    in
    (* Collect argument names (identifiers, possibly raw *x, or parenthesized) *)
    let args = ref [] in
    let continue_ = ref true in
    while !continue_ do
      match peek s with
      | LPAREN ->
        (* Consume parenthesized arg like (Id == id) as opaque string *)
        advance s;
        let depth = ref 1 in
        let buf = Buffer.create 16 in
        Buffer.add_char buf '(';
        while !depth > 0 && peek s <> EOF do
          (match peek s with
           | LPAREN -> incr depth; Buffer.add_char buf '('
           | RPAREN -> decr depth;
             if !depth > 0 then Buffer.add_char buf ')'
           | t -> Buffer.add_string buf (tok_to_string t); Buffer.add_char buf ' ');
          advance s
        done;
        (* Trim trailing space before closing paren *)
        let s_buf = Buffer.contents buf in
        let s_buf = if String.length s_buf > 0 && s_buf.[String.length s_buf - 1] = ' '
                    then String.sub s_buf 0 (String.length s_buf - 1) else s_buf in
        Buffer.clear buf; Buffer.add_string buf s_buf;
        Buffer.add_char buf ')';
        args := Buffer.contents buf :: !args
      | EMAIL ->
        (* Allow "email" as a proof argument (e.g., ValidEmail email) *)
        advance s;
        args := "email" :: !args
      | SMTP ->
        (* Allow "smtp" as a proof argument *)
        advance s;
        args := "smtp" :: !args
      | IDENT n when peek s <> DOUBLE_AMP && peek s <> PROOF_ANNOT
                  && peek s <> COMMA && peek s <> RBRACKET
                  && peek s <> RPAREN && peek s <> NEWLINE
                  && peek s <> ARROW && peek s <> EQ
                  && peek s <> LBRACE
                  && peek s <> USING && peek s <> VIA
                  ->
        advance s;
        (* Consume optional dotted path continuation: x.field.field → "x.field.field" *)
        let name = ref n in
        while peek s = DOT do
          advance s;
          (match peek s with
           | IDENT part | UIDENT part -> advance s; name := !name ^ "." ^ part
           | _ -> ())
        done;
        args := !name :: !args
      | UIDENT n when peek s <> DOUBLE_AMP && peek s <> PROOF_ANNOT
                   && peek s <> COMMA && peek s <> RBRACKET
                   && peek s <> RPAREN && peek s <> NEWLINE
                   && peek s <> ARROW && peek s <> EQ
                   && peek s <> LBRACE ->
        advance s;
        let name = ref n in
        while peek s = DOT do
          advance s;
          (match peek s with
           | IDENT part | UIDENT part -> advance s; name := !name ^ "." ^ part
           | _ -> ())
        done;
        args := !name :: !args
      (* Integer and string literals as proof arguments (per spec §9.1).
         Examples: `HasMin 100 n`, `HasName "http" port` *)
      | INT n ->
        advance s;
        args := string_of_int n :: !args
      | BIGINT bs ->
        (* A9/HM-1: huge integer proof argument — canonical string identity. *)
        advance s;
        args := bs :: !args
      | FLOAT f ->
        advance s;
        (* S15: float proof args use the collision-free identity key, matching the
           proof-SUBJECT identity in Validation_common.subject_of_expr. *)
        args := Float_fmt.identity_key f :: !args
      | STRING str ->
        advance s;
        (* Store string as a quoted opaque argument so proof predicates
           round-trip and the validator can match on string content. *)
        args := ("\"" ^ str ^ "\"") :: !args
      | MINUS when (match peek2 s with INT _ | BIGINT _ | FLOAT _ -> true | _ -> false) ->
        (* Negative numeric literals: -100, -3.14, -99999999999999999999999 *)
        advance s;
        (match peek s with
         | INT n  -> advance s; args := ("-" ^ string_of_int n)  :: !args
         | BIGINT bs -> advance s; args := ("-" ^ bs) :: !args
         | FLOAT f -> advance s; args := Float_fmt.identity_key (-. f) :: !args
         | _ -> continue_ := false)
      | _ -> continue_ := false
    done;
    let loc = span loc0 (current_loc s) in
    return (PredApp { pred = pred_name; args = List.rev !args; loc })

(* ── Type expressions ─────────────────────────────────────────────────────── *)

(** Convert a proof_expr to a type_expr so proof conjunctions can appear
    inside type argument position, e.g. [Fact (ValidPort y && IsPositive y)].
    PredAnd is encoded as [TApp (TApp (TName "&&") left_ty) right_ty]. *)
let rec proof_expr_to_type_expr (p : proof_expr) : type_expr =
  match p with
  | PredApp { pred; args; loc } ->
    let head = TName { name = pred; loc } in
    List.fold_left
      (fun h arg -> TApp { head = h; arg = TName { name = arg; loc }; loc })
      head args
  | PredAnd { left; right; loc } ->
    let l = proof_expr_to_type_expr left in
    let r = proof_expr_to_type_expr right in
    TApp { head = TApp { head = TName { name = "&&"; loc }; arg = l; loc }; arg = r; loc }

let skip_erased_type_pack_suffix s =
  if peek s = QUESTION then begin
    advance s;
    (* Capture the entity proof for later use by return spec detection *)
    let entity_proof = match peek s with
      | PROOF_ANNOT | RPAREN | COMMA | NEWLINE | INDENT -> None
      | _ ->
        (match parse_proof_expr s with
         | Ok p ->
           let rec expand = function
             | PredApp { pred; args = []; loc } -> PredApp { pred; args = ["_entity"]; loc }
             | PredAnd { left; right; loc } ->
               PredAnd { left = expand left; right = expand right; loc }
             | other -> other
           in
           Some (expand p)
         | Err _ -> None)
    in
    s.last_type_pack_proof <- entity_proof;
    if peek s = PROOF_ANNOT then begin
      advance s;
      ignore (parse_proof_expr s)
    end
  end

let rec parse_type_expr s =
  (* func type: A -> B  (right assoc) *)
  let* left = parse_type_app s in
  if peek s = ARROW then begin
    advance s;
    let* right = parse_type_expr s in
    let loc = span (type_loc left) (type_loc right) in
    return (TFun { dom = left; cod = right; caps = []; loc })
  end else
    return left

and parse_type_app s =
  (* Left-assoc type application: List Int, Maybe T, Dict K V *)
  let* head = parse_type_atom s in
  let rec loop head =
    let continue_with_type_arg () =
      let saved = s.pos in
      match try_parse s parse_type_atom with
      | Ok (Some arg) ->
        let loc = span (type_loc head) (type_loc arg) in
        loop (TApp { head; arg; loc })
      | _ ->
        s.pos <- saved;
        return head
    in
    match peek s with
    | UIDENT _ ->
      (* Type-level application: List Int, Maybe T — only uppercase names *)
      continue_with_type_arg ()
    | IDENT "where" ->
      (* `where` ends a type (proof refinement: `T where P`) and so must terminate
         type application.  (Captures use the `using`/`via` keyword tokens, which the
         type parser already stops on; `with` no longer follows a type since inline
         capture codecs moved to `using`.) *)
      return head
    | IDENT _ ->
      (* Lowercase: only a type arg if NOT followed by ':' (field label check) *)
      if peek2 s = COLON then
        return head   (* it's a field label like "radius:", not a type arg *)
      else
        continue_with_type_arg ()
    | LPAREN ->
      continue_with_type_arg ()
    | _ when (match token_as_ident (peek s) with
              | Some n ->
                n <> "where"
                && String.length n > 0
                && n.[0] >= 'A' && n.[0] <= 'Z'
              | None -> false) ->
      (* Keyword-like type names such as PosixMillis must still be accepted as args. *)
      continue_with_type_arg ()
    | _ -> return head
  in
  loop head

and parse_type_atom s =
  let loc0 = current_loc s in
  match peek s with
  | UIDENT n ->
    advance s;
    (* Handle qualified type names: Module.TypeName *)
    let name = ref n in
    while peek s = DOT && (match peek2 s with UIDENT _ -> true | _ -> false) do
      advance s;  (* consume . *)
      (match peek s with UIDENT part -> advance s; name := !name ^ "." ^ part | _ -> ())
    done;
    let loc = span loc0 (current_loc s) in
    return (TName { name = !name; loc })
  | IDENT n ->
    advance s;
    let loc = span loc0 (current_loc s) in
    return (TVar { name = n; loc })
  | LPAREN ->
    advance s;
    (* Try type expression first. If && remains (proof conjunction in type position,
       e.g. Fact (ValidPort y && IsPositive y)), fall back to proof expr parsing.
       Only fall back for && — other remaining tokens mean normal parse failure. *)
    let saved = s.pos in
    (match parse_type_expr s with
     | Ok ty ->
       skip_erased_type_pack_suffix s;
       (* Capability row on a parenthesized function type: `(A -> B requires c)`.
          Only recognized inside parens, so it never collides with a declaration's
          own `requires` clause. *)
       let* ty =
         if peek s = REQUIRES then
           let* caps = parse_requires s in
           return (match ty with
                   | TFun r -> TFun { r with caps = r.caps @ caps }
                   | _ -> ty)
         else return ty
       in
       (match peek s with
        | RPAREN ->
          advance s;  (* consume ) *)
          return ty
        | COMMA ->
          (* Tuple type: (T1, T2, ...) *)
          let elems = ref [ty] in
          let failed = ref false in
          while peek s = COMMA && not !failed do
            advance s;  (* consume , *)
            (match parse_type_expr s with
             | Ok t ->
               skip_erased_type_pack_suffix s;
               elems := t :: !elems
             | Err _ -> failed := true)
          done;
          if !failed then
            err s "expected type expression in tuple"
          else begin
            let* _ = expect s RPAREN in
            let loc = span loc0 (current_loc s) in
            return (TTuple { elems = List.rev !elems; loc })
          end
        | DOUBLE_AMP ->
          (* Proof conjunction in type position: re-parse as proof expression *)
          s.pos <- saved;
          (match parse_proof_expr s with
           | Ok proof ->
             let* _ = expect s RPAREN in
             return (proof_expr_to_type_expr proof)
           | Err _ ->
             s.pos <- saved;
             let* ty = parse_type_expr s in
             let* _ = expect s RPAREN in
             return ty)
        | _ ->
          (* type_expr succeeded but left extra tokens — the content may be a GDP proof
             application with integer/string args like (NamedPort "http" port).
             Backtrack and try parse_proof_expr. *)
          s.pos <- saved;
          (match parse_proof_expr s with
           | Ok proof ->
             let* _ = expect s RPAREN in
             return (proof_expr_to_type_expr proof)
           | Err _ ->
             (* Neither works cleanly — emit the normal error *)
             let* _ = expect s RPAREN in
             return (TName { name = "<error>"; loc = loc0 })))
     | Err _ ->
       (* parse_type_expr failed — try as a proof expression (GDP application with
          integer/string literal args: (HasMin 100 n), (ValidPort 8080), etc.) *)
       s.pos <- saved;
       (match parse_proof_expr s with
        | Ok proof ->
          let* _ = expect s RPAREN in
          return (proof_expr_to_type_expr proof)
        | Err _ ->
          (* Neither type nor proof — re-run type parse to surface the right error *)
          s.pos <- saved;
          let* ty = parse_type_expr s in
          let* _ = expect s RPAREN in
          return ty))
  | _ ->
    (* Try treating keywords as type names (PosixMillis, etc.) *)
    (match token_as_ident (peek s) with
     | Some n ->
       advance s;
       let loc = span loc0 (current_loc s) in
       return (TName { name = n; loc })
     | None ->
       err s (Printf.sprintf "expected type, got %s" (tok_to_string (peek s))))

and type_loc = function
  | TName u -> u.loc | TVar i -> i.loc
  | TApp a  -> a.loc | TFun f -> f.loc | TTuple t -> t.loc

let list_or_set_elem_ty (ty : type_expr) =
  match ty with
  | TApp { head = TName { name = "List"; _ }; arg = elem_ty; _ } -> Some (`List, elem_ty)
  | TApp { head = TName { name = "Set"; _ }; arg = elem_ty; _ } -> Some (`Set, elem_ty)
  | _ -> None

let dict_key_val_ty (ty : type_expr) =
  match ty with
  | TApp { head = TApp { head = TName { name = "Dict"; _ }; arg = key_ty; _ }; arg = val_ty; _ } ->
    Some (key_ty, val_ty)
  | _ -> None

(* ── Bindings / parameters ────────────────────────────────────────────────── *)

(** Parse a single parameter: [name : Type] or [name : Type ::: Proof]. *)
let parse_binding_with_type_parser parse_type s =
  let loc0 = current_loc s in
  let* name = expect_ident s in
  let* _  = expect s COLON in
  let* ty = parse_type s in
  (* The `?` named-pack operator is a RETURN-type construct only.  In a binding
     position (parameter, capture, auth binding) it was previously skipped
     SILENTLY — the proof was dropped with no diagnostic, so `n: Int ? Positive`
     quietly became a plain `n: Int` with no proof obligation (a footgun).  Fail
     closed with a helpful message pointing at `:::`. *)
  if peek s = QUESTION then
    err s (Printf.sprintf
      "the `?` named-pack operator is only valid in a return type; to require a \
       proof on parameter `%s`, use `:::` instead (e.g. `%s: <Type> ::: <Proof> %s`)"
      name name name)
  else
  let* proof_ann =
    if peek s = PROOF_ANNOT then begin
      advance s;
      let* p = parse_proof_expr s in
      return (Some p)
    end else
      return None
  in
  let loc = span loc0 (current_loc s) in
  return { name; type_expr = ty; proof_ann; loc }

let parse_binding s =
  parse_binding_with_type_parser parse_type_expr s

let parse_api_body_binding s =
  (* Route bodies should stop before the endpoint return arrow.
     Function-typed HTTP bodies are not part of the public Tesl API surface,
     so we intentionally parse only the non-arrow type grammar here. *)
  parse_binding_with_type_parser parse_type_app s

(** Parse parameter list: [(name: Type, name: Type ::: Proof)]. *)
let parse_params s =
  let* _ = expect s LPAREN in
  let params = ref [] in
  let rec loop () =
    skip_layout s;  (* allow multi-line param lists *)
    if peek s = RPAREN then return ()
    else begin
      let* b = parse_binding s in
      params := b :: !params;
      skip_layout s;
      if peek s = COMMA then begin advance s; loop () end
      else return ()
    end
  in
  let* _ = loop () in
  skip_layout s;
  let* _ = expect s RPAREN in
  return (List.rev !params)

(* ── Return specifications ───────────────────────────────────────────────── *)

(** Parse [-> ReturnSpec].  Called after the parameter list. *)
let rec parse_return_spec s =
  let loc0 = current_loc s in
  let* _ = expect s ARROW in
  (* Multiple shapes:
     1. -> T                              plain
     2. -> name: T ::: Proof             attached binding
     3. -> T ? ProofName                 named-pack
     4. -> List T ::: ForAll Proof       forall
     5. -> Maybe (List T ::: ForAll P)   maybe-forall
     6. -> exists name: T => RetSpec     exists
  *)
  match peek s with
  | IDENT "exists" ->
    advance s;
    let* b = parse_binding s in
    let* _ = expect s FAT_ARROW in
    let* body = parse_return_spec_no_arrow s in
    let loc = span loc0 (current_loc s) in
    return (RetExists { binding = b; body; loc })
  | IDENT name when peek2 s = COLON ->
    (* name: Type ::: Proof — attached binding *)
    advance s;  (* consume name *)
    advance s;  (* consume : *)
    let* ty = parse_type_expr s in
    let* proof_ann =
      if peek s = PROOF_ANNOT then begin
        advance s;
        let* p = parse_proof_expr s in
        return (Some p)
      end else return None
    in
    let loc = span loc0 (current_loc s) in
    (match proof_ann with
     | Some proof ->
       return (RetAttached {
         binding = { name; type_expr = ty; proof_ann = Some proof; loc };
         loc })
     | None ->
       return (RetPlain { ty; loc }))
  | _ ->
    parse_return_spec_no_arrow s

and parse_return_spec_no_arrow s =
  let loc0 = current_loc s in
  (* Skip newlines/indents before the return type (for multi-line return specs) *)
  skip_newlines s;
  if peek s = INDENT then advance s;
  if peek s = IDENT "exists" then begin
    advance s;
    let* b = parse_binding s in
    let* _ = expect s FAT_ARROW in
    let* body = parse_return_spec_no_arrow s in
    let loc = span loc0 (current_loc s) in
    return (RetExists { binding = b; body; loc })
  end else
  (* Check for name: Type ::: Proof attached binding *)
  if (match peek s with IDENT _ | EMAIL | SMTP -> true | _ -> false) && peek2 s = COLON then begin
    let name = match peek s with IDENT n -> n | EMAIL -> "email" | SMTP -> "smtp" | _ -> "_" in
    advance s;  (* consume name *)
    advance s;  (* consume : *)
    let* ty = parse_type_expr s in
    let* proof_ann =
      if peek s = PROOF_ANNOT then begin
        advance s;
        (match parse_proof_expr s with Ok p -> return (Some p) | Err _ -> return None)
      end else return None
    in
    let loc = span loc0 (current_loc s) in
    match proof_ann with
    | Some proof ->
      return (RetAttached {
        binding = { name; type_expr = ty; proof_ann = Some proof; loc };
        loc })
    | None ->
      return (RetPlain { ty; loc })
  end else
  (* Check for Maybe (List T ::: ForAll P) or Maybe (name: T ::: P) *)
  (match peek s with
  | UIDENT "Maybe" ->
    advance s;
    (* Look ahead: is next a parenthesized list/set forall? *)
    let saved = s.pos in
    (match parse_maybe_forall s with
     | Ok spec -> return spec
     | Err _ ->
       s.pos <- saved;
       (* Fall through to plain type — handle complex parenthesized types *)
       if peek s = LPAREN then begin
         (* Try to parse (name: Type ::: Proof) or (Type) patterns *)
         let saved2 = s.pos in
         advance s;  (* consume ( *)
         match peek s with
         | IDENT bname when peek2 s = COLON ->
           advance s;  (* consume name *)
           advance s;  (* consume : *)
           (* Parse the type *)
           (match parse_type_expr s with
            | Ok t ->
              (* Check for ::: Proof annotation *)
              let proof_ann =
                if peek s = PROOF_ANNOT then begin
                  advance s;
                  match parse_proof_expr s with Ok p -> Some p | Err _ -> None
                end else None
              in
              if peek s = RPAREN then advance s;
              let loc = span loc0 (current_loc s) in
              (match proof_ann with
               | Some proof ->
                 (* -> Maybe (name: T ::: P) — RetMaybeAttached *)
                 let binding = { name = bname; type_expr = t; proof_ann = Some proof; loc } in
                 return (RetMaybeAttached { outer_ty = None; binding; loc })
               | None ->
                 (* -> Maybe (name: T) — strip name, treat as plain Maybe T *)
                 return (RetPlain { ty = TApp { head = TName { name = "Maybe"; loc }; arg = t; loc }; loc }))
            | Err _ ->
              s.pos <- saved2;
              advance s;
              let depth = ref 1 in
              while !depth > 0 && peek s <> EOF do
                (match peek s with LPAREN -> incr depth | RPAREN -> decr depth | _ -> ());
                advance s
              done;
              let loc = span loc0 (current_loc s) in
              return (RetPlain { ty = TName { name = "MaybeComplex"; loc }; loc }))
         | _ ->
           (* Try (Type ? Proof) form — RetMaybeAttached with synthetic _entity binder *)
           (match parse_type_expr s with
            | Ok t ->
              (* Check for `? P` named-pack suffix: `Maybe (T ? P)` *)
              if peek s = QUESTION then begin
                advance s;  (* consume ? *)
                let entity_proof_opt =
                  match parse_proof_expr s with
                  | Ok p ->
                    (* Expand entity proof: add _entity as the subject arg *)
                    let rec expand = function
                      | PredApp { pred; args = []; loc } ->
                        PredApp { pred; args = ["_entity"]; loc }
                      | PredAnd { left; right; loc } ->
                        PredAnd { left = expand left; right = expand right; loc }
                      | other -> other
                    in
                    Some (expand p)
                  | Err _ -> None
                in
                (* Consume optional ::: other_proof *)
                let _ =
                  if peek s = PROOF_ANNOT then begin
                    advance s;
                    ignore (parse_proof_expr s)
                  end
                in
                if peek s = RPAREN then advance s;
                let loc = span loc0 (current_loc s) in
                (match entity_proof_opt with
                 | Some proof ->
                   (* -> Maybe (T ? P)  →  RetMaybeAttached with _entity binder *)
                   let binding = { name = "_entity"; type_expr = t; proof_ann = Some proof; loc } in
                   return (RetMaybeAttached { outer_ty = None; binding; loc })
                 | None ->
                   return (RetPlain { ty = TApp { head = TName { name = "Maybe"; loc }; arg = t; loc }; loc }))
              end else begin
                skip_erased_type_pack_suffix s;
                if peek s = RPAREN then advance s;
                let loc = span loc0 (current_loc s) in
                return (RetPlain { ty = TApp { head = TName { name = "Maybe"; loc }; arg = t; loc }; loc })
              end
            | Err _ ->
              s.pos <- saved2;
              advance s;
              let depth = ref 1 in
              while !depth > 0 && peek s <> EOF do
                (match peek s with LPAREN -> incr depth | RPAREN -> decr depth | _ -> ());
                advance s
              done;
              let loc = span loc0 (current_loc s) in
              return (RetPlain { ty = TName { name = "MaybeComplex"; loc }; loc }))
       end else
         match parse_type_app_ret s with
         | Ok t ->
           let loc = span loc0 (current_loc s) in
           return (RetPlain { ty = TApp { head = TName { name = "Maybe"; loc }; arg = t; loc }; loc })
         | Err _ ->
           let loc = span loc0 (current_loc s) in
           return (RetPlain { ty = TName { name = "Unit"; loc }; loc }))
  | QUESTION ->
    err s "legacy return-pack syntax `-> ?Type ::: ...` has been removed; write `-> Type ? ...` instead"
  | _ ->
    (* Handle parenthesized named-pack: (Type ? Proof) ::: OtherProof
       Try to parse (Type ? EntityProof) first; if the parens contain ?,
       extract the named-pack and then check for ::: sidecar proof. *)
    if peek s = LPAREN then begin
      let saved_paren = s.pos in
      advance s;  (* consume ( *)
      match parse_type_expr s with
      | Ok inner_ty when peek s = QUESTION ->
        advance s;  (* consume ? *)
        let* entity_proof =
          match peek s with
          | RPAREN -> return None
          | _ ->
            let* p = parse_proof_expr s in
            return (Some p)
        in
        if peek s = RPAREN then advance s;
        let* other_proof =
          if peek s = PROOF_ANNOT then begin
            advance s;
            let* p = parse_proof_expr s in
            return (Some p)
          end else
            return None
        in
        return (RetNamedPack { ty = inner_ty; entity_proof; other_proof; loc = span loc0 (current_loc s) })
      | _ ->
        (* Not a (Type ? Proof) pattern — backtrack and parse normally *)
        s.pos <- saved_paren;
        let* ty = parse_type_expr s in
        let loc = span loc0 (current_loc s) in
        if peek s = QUESTION then begin
          advance s;
          let* entity_proof =
            match peek s with
            | PROOF_ANNOT | REQUIRES | EQ | NEWLINE | INDENT -> return None
            | _ ->
              let* p = parse_proof_expr s in
              return (Some p)
          in
          let* other_proof =
            if peek s = PROOF_ANNOT then begin
              advance s;
              let* p = parse_proof_expr s in
              return (Some p)
            end else
              return None
          in
          return (RetNamedPack { ty; entity_proof; other_proof; loc = span loc0 (current_loc s) })
        end
        else if peek s = PROOF_ANNOT then begin
          advance s;
          let* p = parse_proof_expr s in
          let binding = { name = "_entity"; type_expr = ty; proof_ann = Some p; loc } in
          return (RetAttached { binding; loc })
        end
        else
          return (RetPlain { ty; loc })
    end else
    let* ty = parse_type_expr s in
    let loc = span loc0 (current_loc s) in
    (* Check if a type argument carried a ? P pack (e.g. Either String (Int ? IsPositive)).
       skip_erased_type_pack_suffix captures the proof in last_type_pack_proof.
       When set and no outer ? or ::: follow, create a proof-carrying return spec. *)
    let captured_pack_proof = s.last_type_pack_proof in
    s.last_type_pack_proof <- None;
    (* Check for ? EntityProofs [::: OtherProofs] (named-pack / forall shorthand) *)
    if peek s = QUESTION then begin
      advance s;
      match peek s with
      | IDENT "ForAll" | UIDENT "ForAll" ->
        advance s;
        let* proof = parse_proof_atom s in
        let loc = span loc0 (current_loc s) in
        (match list_or_set_elem_ty ty with
         | Some (`List, elem_ty) -> return (RetForAll { elem_ty; proof; loc })
         | Some (`Set, elem_ty) -> return (RetSetForAll { elem_ty; proof; loc })
         | None -> err s "`ForAll` in return type `?` annotation is only valid for `List` or `Set`")
      | IDENT "ForAllValues" | UIDENT "ForAllValues" ->
        advance s;
        let* proof = parse_proof_atom s in
        let loc = span loc0 (current_loc s) in
        (match dict_key_val_ty ty with
         | Some (key_ty, val_ty) -> return (RetForAllDictValues { key_ty; val_ty; proof; loc })
         | None -> err s "`ForAllValues` in return type `?` annotation is only valid for `Dict`")
      | IDENT "ForAllKeys" | UIDENT "ForAllKeys" ->
        advance s;
        let* proof = parse_proof_atom s in
        let loc = span loc0 (current_loc s) in
        (match dict_key_val_ty ty with
         | Some (key_ty, val_ty) -> return (RetForAllDictKeys { key_ty; val_ty; proof; loc })
         | None -> err s "`ForAllKeys` in return type `?` annotation is only valid for `Dict`")
      | _ ->
        let* entity_proof =
          match peek s with
          | PROOF_ANNOT | REQUIRES | EQ | NEWLINE | INDENT -> return None
          | _ ->
            let* p = parse_proof_expr s in
            return (Some p)
        in
        let* other_proof =
          if peek s = PROOF_ANNOT then begin
            advance s;
            let* p = parse_proof_expr s in
            return (Some p)
          end else
            return None
        in
        return (RetNamedPack { ty; entity_proof; other_proof; loc = span loc0 (current_loc s) })
    end
    (* Check for ::: ForAll P *)
    else if peek s = PROOF_ANNOT then begin
      advance s;
      (* Try to parse ForAll/MaybeForAll *)
      (match peek s with
       | IDENT "ForAll" | UIDENT "ForAll" ->
         advance s;
         let* proof = parse_proof_atom s in
         let loc = span loc0 (current_loc s) in
         (match list_or_set_elem_ty ty with
          | Some (`List, elem_ty) -> return (RetForAll { elem_ty; proof; loc })
          | Some (`Set, elem_ty) -> return (RetSetForAll { elem_ty; proof; loc })
          | None -> err s "`ForAll` in return type `:::` annotation is only valid for `List` or `Set`")
       | IDENT "ForAllValues" | UIDENT "ForAllValues" ->
         advance s;
         let* proof = parse_proof_atom s in
         let loc = span loc0 (current_loc s) in
         (match dict_key_val_ty ty with
          | Some (key_ty, val_ty) -> return (RetForAllDictValues { key_ty; val_ty; proof; loc })
          | None -> err s "`ForAllValues` in return type `:::` annotation is only valid for `Dict`")
       | IDENT "ForAllKeys" | UIDENT "ForAllKeys" ->
         advance s;
         let* proof = parse_proof_atom s in
         let loc = span loc0 (current_loc s) in
         (match dict_key_val_ty ty with
          | Some (key_ty, val_ty) -> return (RetForAllDictKeys { key_ty; val_ty; proof; loc })
          | None -> err s "`ForAllKeys` in return type `:::` annotation is only valid for `Dict`")
       | _ ->
         (* R51_E01 — preserve `Type ::: Proof` as an attached return binding
            so the existential-proof enforcer can see the declared proof. *)
         let* proof = parse_proof_expr s in
         let loc = span loc0 (current_loc s) in
         let binding = { name = "_entity"; type_expr = ty; proof_ann = Some proof; loc } in
         return (RetAttached { binding; loc }))
    end else
      (match captured_pack_proof with
       | Some proof ->
         (* General wrapper (Either/CustomADT) with packed inner proof *)
         let binding = { name = "_entity"; type_expr = ty; proof_ann = Some proof; loc } in
         return (RetMaybeAttached { outer_ty = Some ty; binding; loc })
       | None ->
         return (RetPlain { ty; loc })))

and parse_maybe_forall s =
  (* Maybe (List T ::: ForAll P) or Maybe (Set T ::: ForAll P) *)
  let loc0 = current_loc s in
  let* _ = expect s LPAREN in
  let* container = expect_uident s in
  let* elem_ty = parse_type_atom s in
  let* _ = expect s PROOF_ANNOT in
  let* _ = match peek s with
    | IDENT "ForAll" | UIDENT "ForAll" -> advance s; Ok ()
    | t -> err s (Printf.sprintf "expected ForAll, got %s" (tok_to_string t))
  in
  let* proof = parse_proof_atom s in
  let* _ = expect s RPAREN in
  let loc = span loc0 (current_loc s) in
  if container = "List" then
    return (RetMaybeForAll { elem_ty; proof; loc })
  else if container = "Set" then
    return (RetMaybeSetForAll { elem_ty; proof; loc })
  else
    err s (Printf.sprintf "expected List or Set in Maybe-ForAll, got %s" container)

and parse_type_app_ret s =
  (* For use after "Maybe " — parse the next type atom *)
  parse_type_atom s

(* ── Capabilities ──────────────────────────────────────────────────────────
   `parse_requires` and the capability-row grammar are defined earlier (before
   the type parser) so parenthesized function types `(A -> B requires c)` can
   reuse them. *)

let is_statement_starter_ident = function
  | "with" | "exists" | "publish" | "enqueue"
  | "startWorkers" | "startDeadWorkers" | "serve" | "set"
  | "startEmailWorker" -> true
  | _ -> false

(* ── Expressions ─────────────────────────────────────────────────────────── *)

(** The expression parser handles the full expression grammar.

    Precedence (low to high):
    1. Control: if/then/else, case/of, let, ok, fail
    2. Logic: &&
    3. Comparison: ==, !=, <, <=, >, >=
    4. Additive: +, -
    5. Multiplicative: *, /
    6. Unary: -, !
    7. Application: f x y (left-assoc)
    8. Atom: literal, var, *name, (expr), record, list, constructor
*)

let rec parse_expr s =
  match peek s with
  | IF     -> parse_if s
  | CASE   -> parse_case s
  | LET    -> parse_let s
  | OK     -> parse_ok s
  | FAIL   -> parse_fail s
  | TELEMETRY -> parse_telemetry s
  | IDENT "exists" -> parse_exists_expr s
  | IDENT "startEmailWorker" -> parse_start_email_worker_stmt s
  | _      -> parse_pipe_right s

and parse_exists_expr s =
  (* exists name => expr — existential package construction *)
  let loc0 = current_loc s in
  advance s;  (* consume "exists" *)
  let witness = match peek s with
    | IDENT n -> advance s; n
    | _ -> "_"
  in
  if peek s = FAT_ARROW then advance s;
  let* body = parse_body_or_inline s in
  let loc = span loc0 (current_loc s) in
  return (EApp { fn = EVar { name = "make-witness"; loc };
                 arg = EApp { fn = EVar { name = witness; loc };
                              arg = body; loc };
                 loc })

and parse_if s =
  let loc0 = current_loc s in
  let* _ = expect s IF in
  let* cond = parse_logic s in
  (* 'then' can be on the same line or after NEWLINE *)
  skip_newlines s;
  let then_loc = current_loc s in
  let* _ = expect s THEN in
  let* then_ = parse_body_require_indent s then_loc "then" in
  skip_newlines s;
  let else_loc = current_loc s in
  let* _ = expect s ELSE in
  (* After 'else', allow 'if' for else-if chains or indented body *)
  skip_newlines s;
  let* else_ =
    if peek s = IF then
      parse_if s
    else
      parse_body_require_indent s else_loc "else"
  in
  let loc = span loc0 (current_loc s) in
  return (EIf { cond; then_; else_; loc })

(** Parse a body that MUST be indented (multi-line). *)
and parse_body_require_indent s _kw_loc kw_name =
  skip_newlines s;
  if peek s = INDENT then begin
    advance s;  (* consume INDENT *)
    let* e = parse_stmt_seq s in
    skip_newlines s;
    if peek s = DEDENT then advance s;  (* consume DEDENT *)
    return e
  end else
    err s (Printf.sprintf "the `%s` body must be on an indented new line. Single-line `if cond then a else b` is not supported — put `then` and `else` on their own indented lines:\n    if cond then\n        a\n    else\n        b" kw_name)

(** Parse a body that may be on the same line OR indented on next line. *)
and parse_body_or_inline s =
  skip_newlines s;
  if peek s = INDENT then begin
    advance s;  (* consume INDENT *)
    let* e = parse_stmt_seq s in
    skip_newlines s;
    if peek s = DEDENT then advance s;  (* consume DEDENT *)
    return e
  end else
    parse_expr s

and parse_case s =
  let loc0 = current_loc s in
  let* _ = expect s CASE in
  (* R51_X02 — scrutinee accepts full logical/comparison expressions so that
     `case x > 0 of` works without wrapping in parens. We stop short of
     `parse_pipe_right` (pipelines are unambiguously unrelated to `case`
     heads) to avoid surprising captures of trailing `|>`. *)
  let* scrut = parse_logic s in
  let* _ = expect s OF in
  skip_newlines s;
  (* Arms must follow — either indented or at same level in braces *)
  (match expect s INDENT with
   | Err _ -> err s "case expression must have at least one arm; add an indented arm: `  Pattern -> expression`"
   | Ok () -> Ok ()) |> (fun r -> match r with Err e -> Err e | Ok () ->
  let* arms = parse_case_arms s in
  if arms = [] then
    err s "case expression must have at least one arm; add an indented arm: `  Pattern -> expression`"
  else begin
    if peek s = DEDENT then advance s;
    let loc = span loc0 (current_loc s) in
    return (ECase { scrut; arms; loc })
  end)

and parse_case_arms s =
  let arms = ref [] in
  let continue_ = ref true in
  while !continue_ && peek s <> DEDENT && peek s <> EOF do
    skip_newlines s;
    if peek s = DEDENT || peek s = EOF then continue_ := false
    else begin
      match parse_case_arm_group s with
      | Ok new_arms -> arms := List.rev_append new_arms !arms; skip_newlines s
      | Err _ -> continue_ := false
    end
  done;
  return (List.rev !arms)

and parse_case_arm_group s =
  let loc0 = current_loc s in
  let* first_pat = parse_pattern s in
  (* Parse optional 'where' guard clause.
     We collect the guard tokens into a sub-stream that ends with EOF instead
     of ARROW, so function application (f x) is not mis-terminated by the
     `->` stop-token check in parse_app.  The main stream advances past all
     collected tokens, leaving it positioned at the ARROW arm separator. *)
  let guard =
    if (match peek s with IDENT "where" -> true | _ -> false) then begin
      advance s;  (* consume 'where' *)
      (* Collect tokens up to the first unparenthesised ARROW (case arm `->`)
         or a layout sentinel (NEWLINE / DEDENT / EOF). *)
      let depth = ref 0 in
      let guard_tokens = ref [] in
      let done_ = ref false in
      while not !done_ do
        let tok = peek s in
        (match tok with
         | LPAREN | LBRACKET | LBRACE -> incr depth
         | RPAREN | RBRACKET | RBRACE -> (if !depth > 0 then decr depth)
         | ARROW when !depth = 0 -> done_ := true
         | NEWLINE | DEDENT | EOF    -> done_ := true
         | _ -> ());
        if not !done_ then begin
          guard_tokens := s.tokens.(s.pos) :: !guard_tokens;
          advance s
        end
      done;
      (* Parse the collected token slice as an expression.  The sub-stream
         terminates with EOF, so parse_app does not see ARROW as a stop token
         and correctly parses function application like `f x` or `f a b`. *)
      let gtoks = List.rev !guard_tokens in
      if gtoks = [] then None
      else begin
        let last = List.nth gtoks (List.length gtoks - 1) in
        let eof_sentinel = { Lexer.tok = EOF; line = last.line; col = last.col + 1 } in
        let sub = make_stream s.filename (gtoks @ [eof_sentinel]) in
        match parse_expr sub with
        | Ok guard_expr -> Some guard_expr
        | Err _ -> None
      end
    end else
      None
  in
  let* _ = expect s ARROW in
  let rec collect_patterns acc =
    let saved = s.pos in
    skip_newlines s;
    match try_parse s (fun s ->
      let* pat = parse_pattern s in
      (* Skip guard if present when collecting fallback patterns *)
      if (match peek s with IDENT "where" -> true | _ -> false) then begin
        advance s;
        while peek s <> ARROW && peek s <> NEWLINE && peek s <> DEDENT && peek s <> EOF do
          advance s
        done
      end;
      let* _ = expect s ARROW in
      return pat
    ) with
    | Ok (Some pat) -> collect_patterns (pat :: acc)
    | _ ->
      s.pos <- saved;
      let* body = parse_body_or_inline s in
      let loc = span loc0 (current_loc s) in
      let patterns = List.rev acc in
      return (List.map (fun pattern -> { pattern; guard; body; loc }) patterns)
  in
  collect_patterns [first_pat]

and parse_pattern s =
  let loc0 = current_loc s in
  match peek s with
  | UNDERSCORE ->
    advance s; return PWild
  | NOTHING ->
    advance s; return (PNullary { ctor = "Nothing"; loc = current_loc s })
  | SOMETHING ->
    advance s;
    (* Something userId — "userId" binds to the 'value field; Something _ — explicit discard
       Something (NestedCtor x) — nested sub-pattern;
       Something 0 / Something "hi" — nested literal pattern;
       Something Nothing / Something UIDENT — bare nested nullary constructor
         (spec §12 case grammar). Previously required parentheses — see R51_X01. *)
    let fields = match peek s with
      | IDENT n   -> advance s; [("value", PVar n)]
      | UNDERSCORE -> advance s; [("value", PWild)]
      | INT n ->
        let lloc = current_loc s in
        advance s; [("value", PLit { value = LInt n; loc = lloc })]
      | BIGINT bs ->
        let lloc = current_loc s in
        advance s; [("value", PLit { value = LBigInt bs; loc = lloc })]
      | STRING str ->
        let lloc = current_loc s in
        advance s; [("value", PLit { value = LString str; loc = lloc })]
      | LPAREN ->
        advance s;
        (match parse_pattern s with
         | Ok sub_pat -> (if peek s = RPAREN then advance s); [("value", sub_pat)]
         | Err _ -> [])
      | NOTHING ->
        let lloc = current_loc s in
        advance s; [("value", PNullary { ctor = "Nothing"; loc = lloc })]
      | UIDENT nested ->
        let lloc = current_loc s in
        advance s; [("value", PNullary { ctor = nested; loc = lloc })]
      | MINUS ->
        (* Negative integer literal: Something -1 *)
        let lloc = current_loc s in
        advance s;
        (match peek s with
         | INT n ->
           let loc2 = span lloc (current_loc s) in
           advance s; [("value", PLit { value = LInt (-n); loc = loc2 })]
         | BIGINT bs ->
           let loc2 = span lloc (current_loc s) in
           advance s; [("value", PLit { value = LBigInt ("-" ^ bs); loc = loc2 })]
         | _ -> [])
      | _ -> []
    in
    let loc = span loc0 (current_loc s) in
    if fields = [] then return (PNullary { ctor = "Something"; loc })
    else return (PCon { ctor = "Something"; fields; loc })
  | UIDENT ctor ->
    advance s;
    (* Collect labeled field bindings: FieldName or { field = var, ... } *)
    let fields = ref [] in
    let continue_ = ref true in
    (* Check for brace-enclosed pattern: Left { field = var, ... } *)
    if peek s = LBRACE then begin
      advance s;  (* consume { *)
      while !continue_ && peek s <> RBRACE && peek s <> EOF do
        skip_layout s;
        if peek s = RBRACE || peek s = EOF then
          continue_ := false
        else
          (match peek s with
           | IDENT fname ->
             advance s;
             (match peek s with
              | EQ ->
                advance s;
                (* After = : accept any pattern (allows nested constructors) *)
                (match parse_pattern s with
                 | Ok sub_pat ->
                   fields := (fname, sub_pat) :: !fields;
                   if peek s = COMMA then advance s
                 | Err _ -> continue_ := false)
              | _ ->
                (* Just label: treat as label = PVar label *)
                fields := (fname, PVar fname) :: !fields;
                if peek s = COMMA then advance s)
           | UNDERSCORE ->
             advance s;
             fields := ("_", PWild) :: !fields;
             if peek s = COMMA then advance s
           | _ -> continue_ := false)
      done;
      if peek s = RBRACE then advance s  (* consume } *)
    end else begin
      while !continue_ do
        match peek s with
        | IDENT n when n <> "where" && peek s <> ARROW && peek s <> NEWLINE && peek s <> DEDENT ->
          advance s;
          fields := (n, PVar n) :: !fields
        | UNDERSCORE ->
          advance s;
          fields := ("_", PWild) :: !fields
        | LPAREN ->
          (* Parenthesised sub-pattern: Wrap (Something n) *)
          advance s;
          let pos = List.length !fields in
          (match parse_pattern s with
           | Ok sub_pat ->
             (if peek s = RPAREN then advance s);
             fields := (Printf.sprintf "_pos%d" pos, sub_pat) :: !fields
           | Err _ -> continue_ := false)
        | UIDENT nested_ctor ->
          (* Bare UIDENT in field position: a nullary nested constructor *)
          advance s;
          let pos = List.length !fields in
          fields := (Printf.sprintf "_pos%d" pos, PNullary { ctor = nested_ctor; loc = current_loc s }) :: !fields
        | NOTHING ->
          (* Bare Nothing in field position: nullary Maybe constructor *)
          advance s;
          let pos = List.length !fields in
          fields := (Printf.sprintf "_pos%d" pos, PNullary { ctor = "Nothing"; loc = current_loc s }) :: !fields
        | INT n ->
          (* Nested integer literal pattern: Something 0 *)
          let lloc = current_loc s in
          advance s;
          let pos = List.length !fields in
          fields := (Printf.sprintf "_pos%d" pos, PLit { value = LInt n; loc = lloc }) :: !fields
        | BIGINT bs ->
          (* Nested huge integer literal pattern: Something 99999999999999999999999 *)
          let lloc = current_loc s in
          advance s;
          let pos = List.length !fields in
          fields := (Printf.sprintf "_pos%d" pos, PLit { value = LBigInt bs; loc = lloc }) :: !fields
        | MINUS ->
          (* Nested negative integer literal pattern: Something -1 *)
          let lloc = current_loc s in
          advance s;
          (match peek s with
           | INT n ->
             advance s;
             let pos = List.length !fields in
             fields := (Printf.sprintf "_pos%d" pos, PLit { value = LInt (-n); loc = lloc }) :: !fields
           | BIGINT bs ->
             advance s;
             let pos = List.length !fields in
             fields := (Printf.sprintf "_pos%d" pos, PLit { value = LBigInt ("-" ^ bs); loc = lloc }) :: !fields
           | _ -> continue_ := false)
        | STRING str ->
          (* Nested string literal pattern: Something "hello" *)
          let lloc = current_loc s in
          advance s;
          let pos = List.length !fields in
          fields := (Printf.sprintf "_pos%d" pos, PLit { value = LString str; loc = lloc }) :: !fields
        | _ -> continue_ := false
      done
    end;
    let loc = span loc0 (current_loc s) in
    if !fields = [] then
      return (PNullary { ctor; loc })
    else
      return (PCon { ctor; fields = List.rev !fields; loc })
  | IDENT n ->
    advance s; return (PVar n)
  | STRING str ->
    let loc = span loc0 (current_loc s) in
    advance s; return (PLit { value = LString str; loc })
  | INT n ->
    let loc = span loc0 (current_loc s) in
    advance s; return (PLit { value = LInt n; loc })
  | BIGINT bs ->
    let loc = span loc0 (current_loc s) in
    advance s; return (PLit { value = LBigInt bs; loc })
  | MINUS ->
    (* Negative integer literal in pattern: -42 *)
    advance s;
    (match peek s with
     | INT n ->
       let loc = span loc0 (current_loc s) in
       advance s; return (PLit { value = LInt (-n); loc })
     | BIGINT bs ->
       let loc = span loc0 (current_loc s) in
       advance s; return (PLit { value = LBigInt ("-" ^ bs); loc })
     | t ->
       err s (Printf.sprintf "expected integer after `-` in pattern, got %s" (tok_to_string t)))
  | t ->
    err s (Printf.sprintf "expected pattern, got %s" (tok_to_string t))

and record_hint_of_declared_type = function
  | Some (TName { name; _ }) -> Some name
  | _ -> None

and apply_declared_type_record_hint value declared_type =
  match value, record_hint_of_declared_type declared_type with
  | ERecord { fields; type_hint = None; loc }, Some hint ->
    ERecord { fields; type_hint = Some hint; loc }
  | _ -> value

and parse_let s =
  let loc0 = current_loc s in
  let* _ = expect s LET in
  (* Handle proof decomposition: let (x ::: p && q) = expr.
     Track each slot's position in the && conjunction so we can bind
     each proof name to its positional conjunct (left/right), instead of
     aliasing every name to the full proof set.  Underscores count as slots
     but are not bound. *)
  let proof_binding = ref None in           (* (position, name) for the outer binder *)
  let extra_proof_binders = ref [] in       (* (position, name) list for inner ELetProofs *)
  let proof_arity = ref 1 in                (* total number of && slots *)
  let binding_name =
    if peek s = LPAREN then begin
      advance s;
      let name = ref "_" in
      (match peek s with
       | IDENT n -> advance s; name := n
       | UNDERSCORE -> advance s
       | _ -> ());
      if peek s = PROOF_ANNOT then begin
        advance s;
        let named = ref [] in
        let slot_count = ref 0 in
        let record_slot name_opt =
          (match name_opt with
           | Some n -> named := (!slot_count, n) :: !named
           | None -> ());
          incr slot_count
        in
        let at_end () =
          let t = peek s in
          t = RPAREN || t = EOF || t = EQ
        in
        let consume_slot () =
          match peek s with
          | IDENT p when p <> "_" -> advance s; record_slot (Some p); true
          | IDENT "_" | UNDERSCORE -> advance s; record_slot None; true
          | _ -> false
        in
        if not (at_end ()) then begin
          ignore (consume_slot ());
          while peek s = DOUBLE_AMP do
            advance s;
            ignore (consume_slot ())
          done;
          (* Tolerantly skip any unexpected trailing tokens. *)
          while not (at_end ()) do advance s done
        end;
        proof_arity := !slot_count;
        let slots = List.rev !named in
        (match slots with
         | [] -> ()
         | first :: rest ->
           proof_binding := Some first;
           extra_proof_binders := rest)
      end else begin
        while peek s <> RPAREN && peek s <> EOF && peek s <> EQ do advance s done
      end;
      if peek s = RPAREN then advance s;
      !name
    end else begin
      match peek s with
      | IDENT n -> advance s; n
      | UNDERSCORE -> advance s; "_"
      (* Allow keyword tokens as let binding names *)
      | EMAIL -> advance s; "email"
      | SMTP  -> advance s; "smtp"
      | _ -> "_"
    end
  in
  let* declared_type, declared_proof =
    if peek s = COLON then begin
      advance s;
      let* declared_type = parse_type_expr s in
      let* declared_proof =
        if peek s = PROOF_ANNOT then begin
          advance s;
          let* proof = parse_proof_expr s in
          return (Some proof)
        end else
          return None
      in
      return (Some declared_type, declared_proof)
    end else
      return (None, None)
  in
  let* _ = expect s EQ in
  let* value = parse_expr s in
  (* Users must write TypeName { field: val } explicitly — no auto-promotion from let annotation *)
  skip_newlines s;
  let* body = parse_expr s in
  let loc = span loc0 (current_loc s) in
  match !proof_binding with
  | Some (first_pos, pname) ->
    let arity = !proof_arity in
    let idx_for pos = if arity <= 1 then None else Some (pos, arity) in
    let body_with_extras = List.fold_right (fun (pos, extra_name) acc_body ->
      ELetProof { value_name = "_"; proof_name = extra_name;
                  proof_index = idx_for pos;
                  value; body = acc_body; loc }
    ) !extra_proof_binders body in
    return (ELetProof { value_name = binding_name; proof_name = pname;
                         proof_index = idx_for first_pos;
                         value; body = body_with_extras; loc })
  | None ->
    return (ELet {
      name = binding_name;
      declared_type;
      declared_proof;
      value;
      body;
      loc;
    })

and parse_ok s =
  let loc0 = current_loc s in
  let* _ = expect s OK in
  let* value = parse_app s in
  let* _ = expect s PROOF_ANNOT in
  let* proof = parse_proof_expr s in
  let loc = span loc0 (current_loc s) in
  return (EOk { value; proof; loc })

and parse_stringish_expr s =
  let loc0 = current_loc s in
  match peek s with
  | STRING str ->
    advance s;
    return (ELit { lit = LString str; loc = loc0 })
  | INTERP raw ->
    advance s;
    let segs = parse_interp_string raw loc0 in
    return (ELit { lit = LInterp segs; loc = loc0 })
  | t -> err s (Printf.sprintf "expected string literal or interpolation, got %s" (tok_to_string t))

and parse_via_checker_chain s =
  let rec checker_names = function
    | EVar { name; _ } -> Some [name]
    | EBinop { op = BAnd; left; right; _ } ->
      (match checker_names left, checker_names right with
       | Some left_names, Some right_names -> Some (left_names @ right_names)
       | _ -> None)
    | _ -> None
  in
  match peek s with
  | IDENT _ ->
    let* name = expect_ident s in
    return [name]
  | LPAREN ->
    let* _ = expect s LPAREN in
    let* chain = parse_expr s in
    let* _ = expect s RPAREN in
    (match checker_names chain with
     | Some names -> return names
     | None -> err s "expected `via (<checkA> && <checkB> ...)` or `via <checkFn>`")
  | t -> err s (Printf.sprintf "expected checker name after `via`, got %s" (tok_to_string t))

and parse_fail s =
  let loc0 = current_loc s in
  let* _ = expect s FAIL in
  let* status = expect_int s in
  let* msg = parse_stringish_expr s in
  let loc = span loc0 (current_loc s) in
  return (EFail { status; message = msg; loc })

and parse_telemetry s =
  let loc0 = current_loc s in
  let* _ = expect s TELEMETRY in
  let* name = expect_string s in
  let* _ = expect s LBRACE in
  skip_newlines s;
  let fields = ref [] in
  (* A telemetry field written with `:` instead of `=` (`user.id: v`) was previously
     SILENTLY dropped — its value expression discarded from the emitted code.  A
     missing `=` is now a parse error (captured here, returned after the loop). *)
  let field_err = ref None in
  while peek s <> RBRACE && peek s <> EOF && !field_err = None do
    skip_newlines s;
    if peek s = RBRACE then ()
    else begin
      (* Telemetry fields can be dotted: user.id = val, action.name = val *)
      (* Collect the full key (possibly dotted) *)
      let key_parts = ref [] in
      let continue_key = ref true in
      while !continue_key do
        (match peek s with
         | IDENT n -> advance s; key_parts := n :: !key_parts
         | DOT -> advance s  (* consume dots in dotted keys *)
         | _ -> continue_key := false)
      done;
      let fname = String.concat "." (List.rev !key_parts) in
      if fname = "" then advance s  (* no key found, advance to prevent loop *)
      else begin
        (match expect s EQ with
         | Ok () ->
           (match parse_expr s with
            | Ok v ->
              fields := (fname, v) :: !fields;
              skip_newlines s;
              if peek s = COMMA then advance s
            | Err _ -> ())
         | Err _ ->
           (* EQ missing (e.g. `user.id: v` with a `:`) — a parse error, not a
              silent drop.  Capture the diagnostic at the offending token and stop. *)
           field_err := Some (err s (Printf.sprintf
             "telemetry field `%s` must be written `%s = <expr>` (with `=`, not `:`)"
             fname fname)))
      end;
      ignore ()
    end
  done;
  match !field_err with
  | Some e -> e
  | None ->
    if peek s = RBRACE then advance s;
    let loc = span loc0 (current_loc s) in
    return (ETelemetry { name; fields = List.rev !fields; loc })

and parse_pipe_right s =
  (* |> (pipe-right): f |> g = g f, left-associative, lower precedence than &&
     Also handles expr ::: proof (proof attachment in expression position) *)
  let* left = parse_logic s in
  (* Check for ::: proof attachment: expr ::: proof *)
  let* left =
    if peek s = PROOF_ANNOT then begin
      advance s;
      (match parse_proof_expr s with
       | Ok proof ->
         let loc = expr_loc left in
         return (EOk { value = left; proof; loc })
       | Err _ -> return left)
    end else return left
  in
  let rec loop left =
    (* Allow |> and <| as continuation operators at the start of a new line.
       Save position so we can backtrack if the newlines aren't followed by a pipe op. *)
    let saved = s.pos in
    skip_layout s;
    if peek s = PIPE_RIGHT then begin
      advance s;
      let* fn = parse_logic s in
      (* x |> f → f x *)
      let loc = expr_loc fn in
      let app = EApp { fn; arg = left; loc } in
      loop app
    end else if peek s = PIPE_LEFT then begin
      (* f <| x → f x, right-associative *)
      advance s;
      let* arg = parse_pipe_right s in
      let loc = span (expr_loc left) (expr_loc arg) in
      return (EApp { fn = left; arg; loc })
    end else begin
      s.pos <- saved;
      return left
    end
  in
  loop left

and parse_logic s =
  let* left = parse_comparison s in
  match peek s with
  | DOUBLE_AMP ->
    advance s;
    let* right = parse_logic s in
    let loc = span (expr_loc left) (expr_loc right) in
    return (EBinop { op = BAnd; left; right; loc })
  | DOUBLE_PIPE ->
    (* || — logical OR (booleans only, not proofs) *)
    advance s;
    let* right = parse_logic s in
    let loc = span (expr_loc left) (expr_loc right) in
    return (EBinop { op = BOr; left; right; loc })
  | _ -> return left

and parse_comparison s =
  let* left = parse_additive s in
  match peek s with
  | EQ_EQ | NEQ | LT | LE | GT | GE as op_tok ->
    advance s;
    let op = match op_tok with
      | EQ_EQ -> BEq | NEQ -> BNeq | LT -> BLt | LE -> BLe
      | GT -> BGt | GE -> BGe | _ -> assert false
    in
    let* right = parse_additive s in
    let loc = span (expr_loc left) (expr_loc right) in
    return (EBinop { op; left; right; loc })
  | _ -> return left

and parse_additive s =
  let* left = parse_multiplicative s in
  let rec loop left =
    match peek s with
    | PLUS ->
      advance s;
      let* right = parse_multiplicative s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BAdd; left; right; loc })
    | MINUS ->
      advance s;
      let* right = parse_multiplicative s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BSub; left; right; loc })
    | PLUS_PLUS ->
      advance s;
      let* right = parse_multiplicative s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BConcat; left; right; loc })
    | _ -> return left
  in
  loop left

and parse_multiplicative s =
  let* left = parse_unary s in
  let rec loop left =
    match peek s with
    | STAR ->
      advance s;
      let* right = parse_unary s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BMul; left; right; loc })
    | SLASH ->
      advance s;
      let* right = parse_unary s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BDiv; left; right; loc })
    | PERCENT ->
      advance s;
      let* right = parse_unary s in
      let loc = span (expr_loc left) (expr_loc right) in
      loop (EBinop { op = BMod; left; right; loc })
    | _ -> return left
  in
  loop left

and parse_unary s =
  let loc0 = current_loc s in
  match peek s with
  | MINUS ->
    advance s;
    (* A9/HM-1: a negated out-of-native-range magnitude (e.g. -4611686018427387904
       = -2^62, or any huge literal) is folded into a signed LBigInt string here, so
       downstream code never sees EUnop(UNeg, LBigInt _). *)
    (match peek s with
     | BIGINT bs ->
       advance s;
       return (ELit { lit = LBigInt ("-" ^ bs); loc = loc0 })
     | _ ->
       let* arg = parse_app s in
       let loc = span loc0 (expr_loc arg) in
       return (EUnop { op = UNeg; arg; loc }))
  | BANG ->
    advance s;
    let* arg = parse_app s in
    let loc = span loc0 (expr_loc arg) in
    return (EUnop { op = UNot; arg; loc })
  | _ ->
    parse_app s

and parse_app s =
  (* Left-associative function application: f x y z *)
  let* fn = parse_postfix s in
  (* Detect Cache.get/set/delete/invalidate as special cache operations.
     When we see Cache.get/set/delete/invalidate, parse the rest as a cache op. *)
  match fn with
  | EField { obj = EConstructor { name = "Cache"; _ }; field; loc = loc0 }
    when List.mem field ["get"; "set"; "delete"; "invalidate"] ->
    let* cache_name = expect_uident s in
    (* Parse the key as a parenthesized atom: (expr).
       Cache.get CacheName (key) — the key is always in parens. *)
    let* key = parse_atom s in
    (match field with
     | "get" ->
       let loc = span loc0 (current_loc s) in
       return (ECacheGet { cache_name; key; loc })
     | "delete" ->
       let loc = span loc0 (current_loc s) in
       return (ECacheDelete { cache_name; key; loc })
     | "invalidate" ->
       let loc = span loc0 (current_loc s) in
       return (ECacheInvalidate { cache_name; prefix = key; loc })
     | "set" ->
       let* value = parse_postfix s in
       let ttl =
         match peek s with
         | INT _ | LPAREN ->
           (match try_parse s parse_postfix with
            | Ok (Some e) -> Some e
            | _ -> None)
         | _ -> None
       in
       let loc = span loc0 (current_loc s) in
       return (ECacheSet { cache_name; key; value; ttl; loc })
     | _ -> err s "impossible cache operation")
  (* Detect Email.send as a special email operation. *)
  | EField { obj = EConstructor { name = "Email"; _ }; field = "send"; loc = loc0 } ->
    let* email_name = expect_uident s in
    (* Parse: Email.send EmailName { to: expr subject: expr body: EmailBodyExpr } *)
    let* _ = expect s LBRACE in
    skip_layout s;
    let to_ref = ref None in
    let subject_ref = ref None in
    let body_ref = ref None in
    while peek s <> RBRACE && peek s <> EOF do
      skip_layout s;
      (match peek s with
       | IDENT "to" ->
         advance s;
         if peek s = COLON then advance s;
         (match parse_postfix s with Ok e -> to_ref := Some e | Err _ -> ())
       | IDENT "subject" ->
         advance s;
         if peek s = COLON then advance s;
         (match parse_postfix s with Ok e -> subject_ref := Some e | Err _ -> ())
       | IDENT "body" ->
         advance s;
         if peek s = COLON then advance s;
         (* Parse EmailBody constructor: TextBody expr | HtmlBody expr | RichBody expr expr *)
         (match peek s with
          | UIDENT "TextBody" ->
            let loc_b = current_loc s in
            advance s;
            (match parse_postfix s with
             | Ok arg ->
               let loc_e = span loc_b (current_loc s) in
               body_ref := Some (EConstructor { name = "TextBody"; args = [arg]; loc = loc_e })
             | Err _ -> ())
          | UIDENT "HtmlBody" ->
            let loc_b = current_loc s in
            advance s;
            (match parse_postfix s with
             | Ok arg ->
               let loc_e = span loc_b (current_loc s) in
               body_ref := Some (EConstructor { name = "HtmlBody"; args = [arg]; loc = loc_e })
             | Err _ -> ())
          | UIDENT "RichBody" ->
            let loc_b = current_loc s in
            advance s;
            (match parse_postfix s with
             | Ok arg1 ->
               (match parse_postfix s with
                | Ok arg2 ->
                  let loc_e = span loc_b (current_loc s) in
                  body_ref := Some (EConstructor { name = "RichBody"; args = [arg1; arg2]; loc = loc_e })
                | Err _ -> ())
             | Err _ -> ())
          | _ ->
            (* Fallback: accept any expression for forward compatibility *)
            (match parse_expr s with Ok e -> body_ref := Some e | Err _ -> ()))
       | RBRACE | EOF -> ()
       | _ -> advance s
      );
      skip_layout s
    done;
    let* _ = expect s RBRACE in
    let loc = span loc0 (current_loc s) in
    (match !to_ref, !subject_ref, !body_ref with
     | Some to_, Some subject, Some body ->
       return (ESendEmail { email_name; to_; subject; body; loc })
     | _ -> err s "Email.send requires `to`, `subject`, and `body` fields")
  | fn ->
  let rec loop in_test_request_continuation fn =
    (* ctor_multiline: true when the initial fn is a bare EConstructor.
       Enables indented argument continuation for multi-line constructor
       applications like:
           Node
             (Node Leaf 1 Leaf)
             2
             (Node Leaf 3 Leaf)
       Only constructors get this — function calls and SQL-style statements
       (update … where … set …) must never consume indented clauses. *)
    let ctor_multiline =
      not s.allow_test_multiline_request_continuations &&
      (match fn with EConstructor _ -> true | _ -> false)
    in
    let rec maybe_continue_across_layout in_test_request_continuation =
      if not s.allow_test_multiline_request_continuations then begin
        if in_test_request_continuation then begin
          (* We entered a constructor-multiline INDENT block — continue until DEDENT *)
          let skipped = skip_newlines_count s in
          if skipped = 0 then `Continue true
          else match peek s with
            | DEDENT -> advance s; `Stop
            | _ -> maybe_continue_across_layout true
        end else if ctor_multiline then begin
          (* Constructor application: allow entry into the next INDENT block *)
          let saved = s.pos in
          let skipped = skip_newlines_count s in
          if skipped = 0 then `Continue false
          else match peek s with
            | INDENT -> advance s; maybe_continue_across_layout true
            | _ -> s.pos <- saved; `Continue false
        end else
          `Continue false  (* plain function call: same-line args only *)
      end else
        (* Test-request context: full INDENT/DEDENT continuation logic *)
        let saved = s.pos in
        let skipped_newlines = skip_newlines_count s in
        if skipped_newlines = 0 then
          `Continue in_test_request_continuation
        else if in_test_request_continuation then
          (match peek s with
           | DEDENT -> advance s; `Stop
           | _ -> maybe_continue_across_layout true)
        else
          match peek s with
          | INDENT ->
            advance s;
            maybe_continue_across_layout true
          | IDENT name when is_test_request_modifier_ident name ->
            `Continue false
          | _ ->
            s.pos <- saved;
            `Stop
    in
    match maybe_continue_across_layout in_test_request_continuation with
    | `Stop -> return fn
    | `Continue in_test_request_continuation ->
    (* An argument can only start with an atom *)
    match peek s with
    | INT _ | BIGINT _ | FLOAT _ | STRING _ | INTERP _ | TRUE | FALSE
    | NOTHING | SOMETHING | LPAREN | LBRACE | LBRACKET ->
      (* Don't consume if it looks like it starts a new statement / operator *)
      (match try_parse s (fun s ->
         let saved = s.pos in
         (* Parse an argument: use parse_postfix so x.field works as an arg *)
         match parse_postfix s with
         | Ok e ->
           let starts_statement = match e with
             | EVar { name; _ } -> is_statement_starter_ident name
             | _ -> false
           in
           (* PROOF_ANNOT (:::) only blocks consumption for simple vars (EVar) —
              parenthesized exprs like (f x) are always complete args even before ::: *)
           let is_simple_var = match e with EVar _ -> true | _ -> false in
           (* Check: is this really an application argument? *)
           (match peek s with
            | COLON | EQ | ARROW -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | PROOF_ANNOT when is_simple_var ->
              s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | _ when starts_statement -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | _ -> Ok e)
         | Err e -> Err e) with
       | Ok (Some arg) ->
         let loc = span (expr_loc fn) (expr_loc arg) in
         loop in_test_request_continuation (EApp { fn; arg; loc })
       | Ok None | Err _ -> return fn)
    | IDENT name when is_statement_starter_ident name ->
      return fn
    | IDENT _ | UIDENT _
    (* Allow keyword-as-identifier tokens as function application arguments.
       These are contextual/block keywords that are also natural local-variable
       names (e.g. `seed` for seed rows, `table`/`schema` in DB code); without
       this, `insertMany seed in Order` would stop consuming args at `seed`,
       leaving `insertMany` bare ("unknown name: insertMany"). *)
    | EMAIL | SMTP | SEED | TABLE | SCHEMA | BACKEND ->
      (* Don't consume if it looks like it starts a new statement / operator *)
      (match try_parse s (fun s ->
         let saved = s.pos in
         (* Parse an argument: use parse_postfix so x.field works as an arg *)
         match parse_postfix s with
         | Ok e ->
           let starts_statement = match e with
             | EVar { name; _ } -> is_statement_starter_ident name
             | _ -> false
           in
           (* Check: is this really an application argument?
              Note: PROOF_ANNOT (:::) is intentionally NOT blocked here.
              In `f n ::: p`, `n` IS an argument to `f`; the `:::` attaches
              to the result `(f n)` — handled by parse_pipe_right at the outer
              level. Blocking IDENT args before `:::` caused `check f n ::: p`
              to fail: `n` was not consumed, leaving `check f` with a missing
              argument and creating a spurious bare-check ELet. *)
           (match peek s with
            | COLON | EQ | ARROW -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | _ when starts_statement -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | _ -> Ok e)
         | Err e -> Err e) with
       | Ok (Some arg) ->
         let loc = span (expr_loc fn) (expr_loc arg) in
         loop in_test_request_continuation (EApp { fn; arg; loc })
       | Ok None | Err _ -> return fn)
    | MINUS when (match peek2 s with INT _ | BIGINT _ | FLOAT _ -> true | _ -> false) &&
                 (* Only treat as negative literal when '-' is immediately adjacent to the
                    digit (no whitespace): `f -3` parses as f(-3), but `x - 3` is subtraction.
                    This lets plain variables like `n` participate in arithmetic without `*`. *)
                 adjacent s (s.pos + 1) ->
      (* MINUS immediately followed by a number (no space): negative literal argument.
         Still reject when the context makes binary subtraction unambiguous. *)
      (match try_parse s (fun s ->
         let saved = s.pos in
         match parse_postfix s with
         | Ok e ->
           let fn_is_bare_literal = match fn with
             | ELit { lit = LInt _ | LFloat _ | LBool _; _ } -> true
             | _ -> false
           in
           (match peek s with
            | COLON | EQ | ARROW | PROOF_ANNOT -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | PLUS | MINUS | STAR | SLASH | PERCENT -> s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | NEWLINE | DEDENT | EOF when fn_is_bare_literal ->
              s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | RBRACE | RBRACKET | RPAREN | COMMA when fn_is_bare_literal ->
              s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | EQ_EQ | NEQ | LT | LE | GT | GE when fn_is_bare_literal ->
              s.pos <- saved; Err { msg = ""; loc = dummy_loc "" }
            | _ -> Ok e)
         | Err e -> Err e) with
       | Ok (Some arg) ->
         let loc = span (expr_loc fn) (expr_loc arg) in
         loop in_test_request_continuation (EApp { fn; arg; loc })
       | Ok None | Err _ -> return fn)
    | _ -> return fn
  in
  loop false fn

and parse_postfix s =
  (* Parse atom, then handle .field chains *)
  let* e = parse_atom s in
  let rec loop e =
    if peek s = DOT then begin
      let loc0 = current_loc s in
      advance s;
      match peek s with
      | IDENT field ->
        advance s;
        let loc = span loc0 (current_loc s) in
        loop (EField { obj = e; field; loc })
      (* Allow keyword tokens as field names (e.g. req.email, config.smtp) *)
      | EMAIL ->
        advance s;
        let loc = span loc0 (current_loc s) in
        loop (EField { obj = e; field = "email"; loc })
      | SMTP ->
        advance s;
        let loc = span loc0 (current_loc s) in
        loop (EField { obj = e; field = "smtp"; loc })
      | _ ->
        return e  (* '.' not followed by ident — back off *)
    end else
      return e
  in
  loop e

and parse_atom s =
  let loc0 = current_loc s in
  match peek s with
  | INT n ->
    advance s;
    return (ELit { lit = LInt n; loc = loc0 })
  | BIGINT bs ->
    (* A9/HM-1: out-of-native-range magnitude carried as a canonical string. *)
    advance s;
    return (ELit { lit = LBigInt bs; loc = loc0 })
  | FLOAT f ->
    advance s;
    return (ELit { lit = LFloat f; loc = loc0 })
  | MINUS ->
    (* Negative literal in atom position: -3, -1.5 — common in function args *)
    let saved = s.pos in
    advance s;
    (match peek s with
     | INT n  -> advance s; return (ELit { lit = LInt (-n); loc = loc0 })
     | BIGINT bs -> advance s; return (ELit { lit = LBigInt ("-" ^ bs); loc = loc0 })
     | FLOAT f -> advance s; return (ELit { lit = LFloat (-.f); loc = loc0 })
     | _ -> s.pos <- saved; err s "expected expression")
  | TRUE ->
    advance s;
    return (ELit { lit = LBool true; loc = loc0 })
  | FALSE ->
    advance s;
    return (ELit { lit = LBool false; loc = loc0 })
  | NULL ->
    advance s;
    return (ELit { lit = LBool false; loc = loc0 })  (* treat as false/nothing *)
  | STRING str ->
    advance s;
    return (ELit { lit = LString str; loc = loc0 })
  | INTERP raw ->
    advance s;
    let segs = parse_interp_string raw loc0 in
    return (ELit { lit = LInterp segs; loc = loc0 })
  | NOTHING ->
    advance s;
    return (EConstructor { name = "Nothing"; args = []; loc = loc0 })
  | SOMETHING ->
    advance s;
    (* If followed by <|, return zero-arg constructor so parse_pipe_right handles the operator *)
    if peek s = PIPE_LEFT then
      return (EConstructor { name = "Something"; args = []; loc = loc0 })
    else begin
      let* arg = parse_atom s in
      let loc = span loc0 (expr_loc arg) in
      return (EConstructor { name = "Something"; args = [arg]; loc })
    end
  | IDENT n ->
    advance s;
    let loc = span loc0 (current_loc s) in
    return (EVar { name = n; loc })
  | UIDENT n ->
    advance s;
    let loc = span loc0 (current_loc s) in
    return (EConstructor { name = n; args = []; loc })
  | LPAREN ->
    advance s;
    (* Check for unit () — zero-arg function call marker *)
    if peek s = RPAREN then begin
      advance s;
      let loc = span loc0 (current_loc s) in
      return (EList { elems = []; loc })  (* () = empty list = unit marker *)
    end else begin
      let* e = parse_expr s in
      let* _ = expect s RPAREN in
      return e
    end
  | FN ->
    (* Anonymous lambda in expression position: fn(params) -> body *)
    parse_lambda_expr s
  | LBRACE ->
    parse_record_literal s
  | LBRACKET ->
    parse_list_literal s
  | _ ->
    (* Try treating keywords as identifier expressions (forgetFact, detachFact, etc.) *)
    (match token_as_ident (peek s) with
     | Some n when n <> "fn" && n <> "handler" && n <> "auth"
                && n <> "type" && n <> "record" && n <> "entity" && n <> "module"
                && n <> "import" && n <> "server" && n <> "api" && n <> "codec"
                && n <> "capability" && n <> "database" ->
       let loc = current_loc s in
       advance s;
       (* Check if it's an uppercase name → constructor *)
       if String.length n > 0 && n.[0] >= 'A' && n.[0] <= 'Z' then
         return (EConstructor { name = n; args = []; loc })
       else
         return (EVar { name = n; loc })
     | _ ->
       err s (Printf.sprintf "expected expression, got %s" (tok_to_string (peek s))))

and parse_record_literal s =
  let loc0 = current_loc s in
  let* _ = expect s LBRACE in
  skip_layout s;
  (* Check for record update syntax: { base | field = val, ... }
     vs plain literal: { field: val, ... } *)
  let base = ref None in
  if (match peek s with IDENT _ -> true | _ -> false) && peek2 s = PIPE then begin
    (* Record update: { r | ... } *)
    (match peek s with
     | IDENT n -> advance s; advance s;  (* consume name and | *)
       base := Some (EVar { name = n; loc = current_loc s })
     | _ -> ())
  end;
  skip_layout s;
  let fields = ref [] in
  let continue_ = ref true in
  while !continue_ && peek s <> RBRACE && peek s <> EOF do
    skip_layout s;
    if peek s = RBRACE then continue_ := false
    else begin
      match peek s with
      | STRING fname | INTERP fname ->
        (* String key in JSON-style literal: { "fieldName": value } *)
        advance s;
        let sep_ok = match peek s with
          | COLON -> advance s; true | _ -> false
        in
        if sep_ok then begin
          match parse_expr s with
          | Ok v ->
            fields := (fname, v) :: !fields;
            skip_layout s;
            (match peek s with COMMA -> advance s; skip_layout s | _ -> ())
          | Err _ -> continue_ := false
        end else continue_ := false
      | IDENT _
      (* Allow keyword tokens as record field names (e.g. email, smtp, and the
         config-block field keywords schema/database/backend/api). *)
      | EMAIL | SMTP | SCHEMA | DATABASE | BACKEND | API ->
        let fname = match peek s with
          | IDENT n -> n | EMAIL -> "email" | SMTP -> "smtp"
          | SCHEMA -> "schema" | DATABASE -> "database" | BACKEND -> "backend"
          | API -> "api"
          | _ -> "_"
        in
        advance s;
        (* Field separator: either ':' (new record) or '=' (record update) *)
        let sep_ok = match peek s with
          | COLON -> advance s; true
          | EQ -> advance s; true
          | _ -> false
        in
        if sep_ok then begin
          match parse_expr s with
          | Ok v ->
            fields := (fname, v) :: !fields;
            skip_newlines s;
            (match peek s with
             | COMMA -> advance s; skip_layout s
             | _ -> ())
          | Err e -> continue_ := false; ignore e
        end else
          continue_ := false
      | _ -> continue_ := false
    end
  done;
  skip_layout s;
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  let record_expr = ERecord { fields = List.rev !fields; type_hint = None; loc } in
  (* For record update, wrap with struct-copy or similar — emit as hash update *)
  match !base with
  | None -> return record_expr
  | Some base_expr ->
    (* Record update: create hash that copies base and overrides specified fields *)
    let fields_list = List.rev !fields in
    let override_list = List.map (fun (k, v) ->
      (ELit { lit = LString k; loc }, v)) fields_list in
    let _ = override_list in
    (* Represent as a special record-update expression — use ERecord with a note.
       The emitter will handle this by generating (hash-set* base 'field val ...) *)
    return (EApp { fn = EVar { name = "#record-update#"; loc };
                   arg = ERecord { fields = ("__base__", base_expr) :: fields_list; type_hint = None; loc };
                   loc })

and parse_list_literal s =
  let loc0 = current_loc s in
  let* _ = expect s LBRACKET in
  (* skip_layout (not skip_newlines): the lexer emits INDENT/DEDENT around an
     indented list body and brackets do NOT suppress layout, so a multi-line
     `[ … ]` (as the manual writes `jobs:`/`entities:`) inserts an INDENT after
     the `[` that a NEWLINE-only skip would trip over ("expected } but got …"). *)
  skip_layout s;
  let elems = ref [] in
  let parse_err = ref None in
  while !parse_err = None && peek s <> RBRACKET && peek s <> EOF do
    skip_layout s;
    if peek s = RBRACKET then ()
    else begin
      match parse_expr s with
      | Ok e ->
        elems := e :: !elems;
        skip_layout s;
        if peek s = COMMA then advance s
      | Err e ->
        (* A list element failed to parse. Advance one token to avoid an
           infinite loop (the parser is stuck at the offending token), then
           propagate the error so the caller gets a diagnostic. *)
        advance s;
        parse_err := Some e
    end
  done;
  (match !parse_err with Some e -> Err e | None ->
  let* _ = expect s RBRACKET in
  let loc = span loc0 (current_loc s) in
  return (EList { elems = List.rev !elems; loc }))

(** Parse an interpolated string into segments.
    Input: raw string content WITHOUT outer quotes, WITH ${...} markers.
    Example: "Hello, ${name}! Count: ${*n}" *)
and parse_interp_string raw _loc =
  let n = String.length raw in
  let segs = ref [] in
  let buf = Buffer.create 32 in
  let i = ref 0 in
  while !i < n do
    if raw.[!i] = '$' && !i + 1 < n && raw.[!i + 1] = '{' then begin
      (* Flush literal segment *)
      if Buffer.length buf > 0 then begin
        segs := ILiteral (Buffer.contents buf) :: !segs;
        Buffer.clear buf
      end;
      (* Find closing } *)
      let j = ref (!i + 2) in
      while !j < n && raw.[!j] <> '}' do incr j done;
      let inner = String.sub raw (!i + 2) (!j - !i - 2) in
      (* Parse the inner expression *)
      let inner_tokens = Lexer.tokenize "<interp>" inner in
      let inner_stream = make_stream "<interp>" inner_tokens in
      (match parse_expr inner_stream with
       | Ok e -> segs := IExpr e :: !segs
       | Err _ ->
         (* Fallback: emit as variable reference *)
         let e = EVar { name = String.trim inner; loc = dummy_loc "<interp>" } in
         segs := IExpr e :: !segs);
      i := !j + 1
    end else begin
      Buffer.add_char buf raw.[!i];
      incr i
    end
  done;
  if Buffer.length buf > 0 then
    segs := ILiteral (Buffer.contents buf) :: !segs;
  List.rev !segs

and parse_lambda_expr s =
  (* Anonymous lambda: fn(x: T, y: T) -> body
     Used in expression position, e.g. List.map (fn(x: Int) -> *x + 1) xs *)
  let loc0 = current_loc s in
  let* _ = expect s FN in
  let* params = parse_params s in
  let* _ = expect s ARROW in
  let* body = parse_body_or_inline s in
  let loc = span loc0 (current_loc s) in
  return (ELambda { params; body; loc })

and expr_loc = function
  | ELit e -> e.loc | EVar e -> e.loc
  | EField e -> e.loc | EApp e -> e.loc | EBinop e -> e.loc
  | EUnop e -> e.loc | EIf e -> e.loc | ECase e -> e.loc
  | ELet e -> e.loc | ELetProof e -> e.loc | ERecord e -> e.loc | EList e -> e.loc
  | EOk e -> e.loc | EFail e -> e.loc | ETelemetry e -> e.loc
  | EEnqueue e -> e.loc | EPublish e -> e.loc | EStartWorkers e -> e.loc
  | EWithDatabase e -> e.loc | EWithCapabilities e -> e.loc | EWithTransaction e -> e.loc | EServe e -> e.loc
  | EConstructor e -> e.loc | ELambda e -> e.loc
  | ECacheGet e -> e.loc | ECacheSet e -> e.loc | ECacheDelete e -> e.loc | ECacheInvalidate e -> e.loc
  | ESendEmail e -> e.loc | EStartEmailWorker e -> e.loc
  | ERuntimeCall e -> e.loc

(* ── Top-level parsers ────────────────────────────────────────────────────── *)

(** Parse a sequence of statements as nested let/do bindings.
    Handles: let x = v, runtime statements, bare expressions, and final expression.
    Returns the combined expression. *)
and hint_expr_type type_name = function
  | ERecord { fields; type_hint = None; loc } ->
    ERecord { fields; type_hint = Some type_name; loc }
  | other -> other

and parse_publish_stmt s =
  let loc0 = current_loc s in
  let* _ =
    match peek s with
    | PUBLISH | IDENT "publish" -> advance s; return ()
    | t -> err s (Printf.sprintf "expected publish statement, got %s" (tok_to_string t))
  in
  let* channel_name = expect_uident s in
  let* _ = expect s LPAREN in
  let* key =
    if peek s = RPAREN then return None
    else
      let* e = parse_expr s in
      return (Some e)
  in
  let* _ = expect s RPAREN in
  let* event_ctor = expect_uident s in
  let* payload =
    match peek s with
    | LBRACE ->
      let* e = parse_expr s in
      return (Some (hint_expr_type event_ctor e))
    | _ -> return None
  in
  let loc = span loc0 (current_loc s) in
  return (EPublish { channel_name; key; event_ctor; payload; loc })

and parse_enqueue_stmt s =
  let loc0 = current_loc s in
  let* _ =
    match peek s with
    | IDENT "enqueue" -> advance s; return ()
    | t -> err s (Printf.sprintf "expected enqueue statement, got %s" (tok_to_string t))
  in
  let* job_type = expect_uident s in
  let* payload = parse_expr s in
  let loc = span loc0 (current_loc s) in
  return (EEnqueue { job_type; payload = hint_expr_type job_type payload; loc })

and parse_start_email_worker_stmt s =
  let loc0 = current_loc s in
  let* _ =
    match peek s with
    | IDENT "startEmailWorker" -> advance s; return ()
    | t -> err s (Printf.sprintf "expected startEmailWorker, got %s" (tok_to_string t))
  in
  let* email_name = expect_uident s in
  let loc = span loc0 (current_loc s) in
  return (EStartEmailWorker { email_name; loc })

and parse_with_stmt s =
  (* `with database X { … }` — bind a named database for the block body.  (The
     `database` keyword is intentionally retained here: dropping it would collide with
     the `database X = Database { … }` declaration keyword.  `with transaction` was
     migrated to the bare `transaction { … }` form — see [parse_transaction_block].) *)
  let loc0 = current_loc s in
  let* _ =
    match peek s with
    | IDENT "with" -> advance s; return ()
    | t -> err s (Printf.sprintf "expected with block, got %s" (tok_to_string t))
  in
  match peek s with
  | DATABASE ->
    advance s;
    let* database_name = expect_uident s in
    let* _ = expect s LBRACE in
    skip_newlines s;
    if peek s = INDENT then advance s;
    let* body = parse_stmt_seq s in
    skip_layout s;
    let* _ = expect s RBRACE in
    let loc = span loc0 (current_loc s) in
    return (EWithDatabase { database_name; body; loc })
  | t -> err s (Printf.sprintf "expected `database` after `with`, got %s" (tok_to_string t))

and parse_transaction_block s =
  (* `transaction { … }` — wrap multiple writes in one atomic transaction.  (Formerly
     spelled `with transaction { … }`; the `with` was dropped in the with-keyword
     cleanup since `transaction` is unambiguous on its own.) *)
  let loc0 = current_loc s in
  let* _ =
    match peek s with
    | IDENT "transaction" -> advance s; return ()
    | t -> err s (Printf.sprintf "expected transaction block, got %s" (tok_to_string t))
  in
  let* _ = expect s LBRACE in
  skip_newlines s;
  if peek s = INDENT then advance s;
  let* body = parse_stmt_seq s in
  skip_layout s;
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  return (EWithTransaction { body; loc })

and continue_stmt_seq s e =
  skip_newlines s;
  match peek s with
  | DEDENT | EOF | RBRACE -> return e
  | _ ->
    let loc = expr_loc e in
    let* body = parse_stmt_seq s in
    return (ELet { name = "_"; declared_type = None; declared_proof = None; value = e; body; loc })

(* Check if an expression is (or contains) a SQL select/selectOne/selectCount/selectSum *)
and is_select_expr e =
  let rec head = function
    | EApp { fn; _ } -> head fn
    | EBinop { left; _ } -> head left
    | other -> other
  in
  match head e with
  | EVar { name = "select" | "selectOne" | "selectCount" | "selectSum" | "selectMax" | "selectMin"
                | "selectCountBy" | "selectSumBy"; _ } -> true
  | _ -> false

(* Merge a continuation expression (SQL modifier on a new line) into the base select expression.
   - EApp-style modifiers (order, limit, offset, groupBy, innerJoin):
     flatten and append atoms as individual EApp args to the select expression.
   - EBinop-style continuations (where field == value on a new line):
     flatten the left EApp chain and merge with select, keeping the comparison operator. *)
and merge_sql_continuation select_e continuation =
  let dummy = Location.dummy_loc "" in
  let rec get_atoms acc = function
    | EApp { fn; arg; _ } -> get_atoms (arg :: acc) fn
    | head -> head :: acc
  in
  match continuation with
  | EBinop { op = BAnd; left; right; loc } ->
    (* Compound AND: merge left side (e.g. "where p.x >= lo") with select_e first,
       then wrap result in BAnd with the right side (e.g. "p.x <= hi").
       This preserves the structure expected by collect_sql_clauses/extract_select_query. *)
    (match merge_sql_continuation select_e left with
     | Some merged_left -> Some (EBinop { op = BAnd; left = merged_left; right; loc })
     | None -> None)
  | EBinop { op; left; right; loc } ->
    (* Simple comparison or || OR: flatten left's EApp atoms and merge with select *)
    let atoms = get_atoms [] left in
    let merged_left = List.fold_left
      (fun fn arg -> EApp { fn; arg; loc = dummy }) select_e atoms in
    Some (EBinop { op; left = merged_left; right; loc })
  | EApp _ ->
    (* order/limit/offset/groupBy/innerJoin/where-predicate: flatten and append atoms *)
    let atoms = get_atoms [] continuation in
    let combined = List.fold_left
      (fun fn arg -> EApp { fn; arg; loc = dummy }) select_e atoms in
    Some combined
  | _ -> None

(* After parsing a SQL select expression, consume any SQL modifier continuations
   on subsequent lines (at the same indentation level) and merge them in.
   SQL modifier continuations start with: order, limit, offset, groupBy, innerJoin, where. *)
and consume_sql_modifiers select_e s =
  if not (is_select_expr select_e) then select_e
  else begin
    (* Skip newlines so that SQL modifier continuations on the *next* line are found.
       It is safe to consume them here because continue_stmt_seq also calls skip_newlines. *)
    skip_newlines s;
    let is_sql_modifier_kw = function
      | IDENT ("order" | "limit" | "offset" | "groupBy" | "innerJoin" | "where") -> true
      | _ -> false
    in
    match peek s with
    | IDENT ("order" | "limit" | "offset" | "groupBy" | "innerJoin" | "where") ->
      (match parse_expr s with
       | Ok continuation ->
         let merged = match merge_sql_continuation select_e continuation with
           | Some merged -> merged
           | None -> select_e
         in
         consume_sql_modifiers merged s
       | Err _ -> select_e)
    | INDENT when is_sql_modifier_kw (peek2 s) ->
      (* SQL modifiers on a deeper-indented block: consume INDENT, parse all
         modifiers inside the block (same as same-level case), then consume DEDENT. *)
      advance s;  (* consume INDENT *)
      let merged = consume_sql_modifiers select_e s in
      if peek s = DEDENT then advance s;  (* consume matching DEDENT *)
      merged
    | _ -> select_e
  end

and parse_stmt_seq s =
  skip_newlines s;
  match peek s with
  | DEDENT | EOF | RBRACE -> err s "empty sequence"
  | LET ->
    let* e = parse_let_in_seq s in
    (* If parse_let_in_seq used the INDENT arm (update/delete continuation block),
       its body only covers the indent block. Continue parsing sibling statements. *)
    continue_stmt_seq s e
  | PUBLISH | IDENT "publish" ->
    let* e = parse_publish_stmt s in
    continue_stmt_seq s e
  | IDENT "enqueue" ->
    let* e = parse_enqueue_stmt s in
    continue_stmt_seq s e
  | IDENT "startEmailWorker" ->
    let* e = parse_start_email_worker_stmt s in
    continue_stmt_seq s e
  | IDENT "transaction" when peek2 s = LBRACE ->
    let* e = parse_transaction_block s in
    continue_stmt_seq s e
  | IDENT "with" when peek2 s = DATABASE ->
    let* e = parse_with_stmt s in
    continue_stmt_seq s e
  | IDENT "set" ->
    let loc0 = current_loc s in
    advance s;
    let set_var = EVar { name = "set"; loc = loc0 } in
    let* field_expr = parse_expr s in
    let* e =
      if peek s = EQ then begin
        advance s;
        match parse_expr s with
        | Ok rhs ->
          let set_call_loc = span loc0 (expr_loc field_expr) in
          let loc = span loc0 (expr_loc rhs) in
          let set_call = EApp { fn = set_var; arg = field_expr; loc = set_call_loc } in
          return (EApp { fn = set_call; arg = rhs; loc })
        | Err _ -> return set_var
      end else
        return set_var
    in
    continue_stmt_seq s e
  | _ ->
    let* e = parse_expr s in
    let* e =
      (* Preserve SQL-style assignment tails when a field/value pair appears as a standalone statement. *)
      if peek s = EQ then begin
        advance s;  (* consume = *)
        match parse_expr s with
        | Ok rhs ->
          let loc = span (expr_loc e) (expr_loc rhs) in
          return (EApp { fn = e; arg = rhs; loc })
        | Err _ -> return e
      end else
        return e
    in
    skip_newlines s;
    (* Merge any SQL modifier continuations on subsequent lines into the select expression *)
    let e = consume_sql_modifiers e s in
    skip_newlines s;
    (match peek s with
     | DEDENT | EOF | RBRACE -> return e
     | INDENT ->
       advance s;
       let loc = expr_loc e in
       let* body = parse_stmt_seq s in
       skip_newlines s;
       if peek s = DEDENT then advance s;
       let continued = ELet { name = "_"; declared_type = None; declared_proof = None; value = e; body; loc } in
       continue_stmt_seq s continued
     | _ ->
       let loc = expr_loc e in
       let* body = parse_stmt_seq s in
       return (ELet { name = "_"; declared_type = None; declared_proof = None; value = e; body; loc }))

and parse_let_in_seq s =
  (* Parse let x = v, then parse the rest of the sequence as the body *)
  let loc0 = current_loc s in
  let* _ = expect s LET in
  (* Detect let (x ::: p && q) = y proof decompose pattern.
     Track slot positions so each named proof binds to its positional
     conjunct instead of aliasing every name to the full proof set. *)
  let proof_binding = ref None in
  let extra_proof_binders = ref [] in
  let proof_arity = ref 1 in
  let binding_name =
    if peek s = LPAREN then begin
      advance s;
      let name = ref "_" in
      (match peek s with
       | IDENT n -> advance s; name := n
       | UNDERSCORE -> advance s
       | _ -> ());
      (* Decompose pattern slots separated by && — underscores count as slots
         but are not bound. *)
      if peek s = PROOF_ANNOT then begin
        advance s;
        let named = ref [] in
        let slot_count = ref 0 in
        let record_slot name_opt =
          (match name_opt with
           | Some n -> named := (!slot_count, n) :: !named
           | None -> ());
          incr slot_count
        in
        let at_end () =
          let t = peek s in
          t = RPAREN || t = EOF || t = EQ
        in
        let consume_slot () =
          match peek s with
          | IDENT p when p <> "_" -> advance s; record_slot (Some p); true
          | IDENT "_" | UNDERSCORE -> advance s; record_slot None; true
          | _ -> false
        in
        if not (at_end ()) then begin
          ignore (consume_slot ());
          while peek s = DOUBLE_AMP do
            advance s;
            ignore (consume_slot ())
          done;
          while not (at_end ()) do advance s done
        end;
        proof_arity := !slot_count;
        let slots = List.rev !named in
        (match slots with
         | [] -> ()
         | first :: rest ->
           proof_binding := Some first;
           extra_proof_binders := rest)
      end else begin
        while peek s <> RPAREN && peek s <> EOF && peek s <> EQ do advance s done
      end;
      if peek s = RPAREN then advance s;
      !name
    end else
      match peek s with
      | IDENT n -> advance s; n
      | UNDERSCORE -> advance s; "_"
      (* Allow keyword tokens as let binding names *)
      | EMAIL -> advance s; "email"
      | SMTP  -> advance s; "smtp"
      | _ -> "_"
  in
  let* declared_type, declared_proof =
    if peek s = COLON then begin
      advance s;
      let* declared_type = parse_type_expr s in
      let* declared_proof =
        if peek s = PROOF_ANNOT then begin
          advance s;
          let* proof = parse_proof_expr s in
          return (Some proof)
        end else
          return None
      in
      return (Some declared_type, declared_proof)
    end else
      return (None, None)
  in
  let* _ = expect s EQ in
  let* value = parse_expr s in
  (* Users must write TypeName { field: val } explicitly *)
  let _ = declared_type in
  (* Allow SQL modifier continuations (where/set/order/limit/…) on subsequent indented
     lines when the let-bound value is a SQL query or update expression. *)
  let value = consume_sql_modifiers value s in
  skip_newlines s;
  let loc = span loc0 (current_loc s) in
  (* The body is the rest of the sequence — if empty (DEDENT/EOF), preserve the let
     for named bindings so annotations are still enforced. *)
  let* body =
    match peek s with
    | DEDENT | EOF | RBRACE when binding_name <> "_" ->
      return (EVar { name = binding_name; loc = current_loc s })
    | DEDENT | EOF | RBRACE -> return value
    | INDENT ->
      (* SQL update/delete continuations (where, set) may appear in a deeper-indented
         block. Consume INDENT, parse the block as the let body, then consume DEDENT. *)
      advance s;
      let* body = parse_stmt_seq s in
      skip_newlines s;
      if peek s = DEDENT then advance s;
      return body
    | _ -> parse_stmt_seq s
  in
  match !proof_binding with
  | Some (first_pos, pname) ->
    let arity = !proof_arity in
    let idx_for pos = if arity <= 1 then None else Some (pos, arity) in
    let body_with_extras = List.fold_right (fun (pos, extra_name) acc_body ->
      ELetProof { value_name = "_"; proof_name = extra_name;
                  proof_index = idx_for pos;
                  value = value; body = acc_body; loc }
    ) !extra_proof_binders body in
    return (ELetProof { value_name = binding_name; proof_name = pname;
                         proof_index = idx_for first_pos;
                         value; body = body_with_extras; loc })
  | None ->
    return (ELet {
      name = binding_name;
      declared_type;
      declared_proof;
      value;
      body;
      loc;
    })

(** Parse the function/handler body.
    Three cases:
    1. INDENT block: `= \n  expr` — parse until DEDENT
    2. Same-level sequence: already inside an indent block, parse until DEDENT
    3. Inline: `= expr` on same line *)
let parse_func_body s =
  skip_newlines s;
  (* Skip any DEDENT tokens from multi-line parameter lists before the body *)
  while peek s = DEDENT do advance s done;
  skip_newlines s;
  if peek s = INDENT then begin
    (* Case 1: explicit indent block *)
    advance s;
    let* e = parse_stmt_seq s in
    skip_newlines s;
    if peek s = DEDENT then advance s;
    return e
  end else if peek s = EOF then
    (* Empty body — shouldn't happen, but handle gracefully *)
    err s "expected function body"
  else begin
    (* Case 2/3: body may be inline or a multi-statement sequence at current level.
       Parse a sequence until DEDENT/EOF, treating each line as a statement. *)
    if (match peek s with
        | PUBLISH | IDENT "publish"
        | IDENT "enqueue" | IDENT "startWorkers" | IDENT "startDeadWorkers"
        | IDENT "serve" | IDENT "with" | IDENT "startEmailWorker" -> true
        (* A bare `transaction { … }` body (formerly `with transaction`) must route to
           the statement-sequence parser too — otherwise an un-indented body (e.g. after
           a multi-line handler header) is mis-parsed as a plain expression. *)
        | IDENT "transaction" -> peek2 s = LBRACE
        | _ -> false) then
      parse_stmt_seq s
    else
    let* first = parse_expr s in
    skip_newlines s;
    (* Merge SQL modifier continuations (order, limit, etc.) from subsequent lines *)
    let first = consume_sql_modifiers first s in
    skip_newlines s;
    match peek s with
    | DEDENT | EOF -> return first
    | LET | CASE | IF | OK | FAIL | PUBLISH ->
      (* More statements follow at same level — build sequence *)
      let loc = expr_loc first in
      let* rest = parse_stmt_seq s in
      return (ELet { name = "_"; declared_type = None; declared_proof = None; value = first; body = rest; loc })
    | IDENT _ | UIDENT _ | STRING _ | INTERP _ | INT _ | BIGINT _ | FLOAT _
    | NOTHING | SOMETHING | LPAREN | LBRACE | LBRACKET | TRUE | FALSE
    | MINUS ->
      (* Could be more statements at same level — try to parse as sequence *)
      let loc = expr_loc first in
      let* rest = parse_stmt_seq s in
      return (ELet { name = "_"; declared_type = None; declared_proof = None; value = first; body = rest; loc })
    | INDENT ->
      (* More indented block follows (multi-line SQL etc.) — consume and parse *)
      advance s;
      let* rest = parse_stmt_seq s in
      skip_newlines s;
      if peek s = DEDENT then advance s;
      let loc = expr_loc first in
      return (ELet { name = "_"; declared_type = None; declared_proof = None; value = first; body = rest; loc })
    | _ -> return first
  end

(** Parse [fn name(params) -> RetSpec = body]. *)
let parse_fn_decl_named kind name loc0 s =
  let* params = parse_params s in
  (* optional 'requires [...]' — for handlers, before or after return type *)
  let* caps_before = parse_requires s in
  (* The return spec may be on the next line after INDENT or DEDENT.
     After multi-line params: NEWLINE DEDENT -> Type
     After inline params: NEWLINE INDENT -> Type *)
  skip_newlines s;
  while peek s = DEDENT do advance s done;
  skip_newlines s;
  let indent_before_return = peek s = INDENT && peek2 s = ARROW in
  if indent_before_return then advance s;
  (* Return spec is optional for workers and some other forms *)
  let* return_spec =
    let saved = s.pos in
    match parse_return_spec s with
    | Ok rs -> return rs
    | Err e when s.pos > saved ->
      (* Tokens were consumed — this is a semantic error in the return spec, not
         a missing return spec. Propagate the error. *)
      Err e
    | Err _ ->
      (* No return spec (no '->' was consumed) — workers/deadWorkers implicitly
         return their job payload type; other forms default to Unit. *)
      s.pos <- saved;
      let loc = current_loc s in
      let default_ret =
        match kind, params with
        | (WorkerKind | DeadWorkerKind), first_param :: _ -> RetPlain { ty = first_param.type_expr; loc }
        | _ -> RetPlain { ty = TName { name = "Unit"; loc }; loc }
      in
      return default_ret
  in
  (* skip NEWLINE/DEDENT that may precede 'requires' or '=' on continuation line.
     Track whether we consumed an additional INDENT so we can consume DEDENT after body. *)
  skip_newlines s;
  (* Consume DEDENTs from multi-line return specs (e.g., exists ... =>\n  Body) *)
  while peek s = DEDENT do advance s done;
  skip_newlines s;
  let consumed_decl_indent = peek s = INDENT && not indent_before_return in
  if consumed_decl_indent then advance s;
  let* caps_after = parse_requires s in
  let capabilities = caps_before @ caps_after in
  (* skip any remaining NEWLINE before = (still at same indent level) *)
  skip_newlines s;
  let* _ = expect s EQ in
  let* body =
    if consumed_decl_indent then begin
      skip_newlines s;
      if peek s = INDENT then
        parse_func_body s
      else
        parse_stmt_seq s
    end else
      parse_func_body s
  in
  (* Propagate return type hints to top-level record literals in the body. *)
  let rec return_type_hint_of = function
    | RetPlain { ty = TName { name = tname; _ }; _ } -> Some tname
    | RetAttached { binding = { type_expr = TName { name = tname; _ }; _ }; _ } -> Some tname
    | RetNamedPack { ty = TName { name = tname; _ }; _ } -> Some tname
    | RetExists { body; _ } -> return_type_hint_of body
    | _ -> None
  in
  let return_type_hint = return_type_hint_of return_spec in
  (* Propagate return type hint through ELet/EOk chains to innermost ERecord *)
  let rec propagate_return_hint e th =
    match e with
    | ERecord { fields; type_hint = None; loc = rloc } ->
      ERecord { fields; type_hint = Some th; loc = rloc }
    | EIf { cond; then_; else_; loc } ->
      EIf { cond; then_ = propagate_return_hint then_ th; else_ = propagate_return_hint else_ th; loc }
    | ECase { scrut; arms; loc } ->
      ECase {
        scrut;
        arms = List.map (fun (arm : case_arm) -> { arm with body = propagate_return_hint arm.body th }) arms;
        loc;
      }
    | ELet { name; declared_type; declared_proof; value; body; loc } ->
      ELet { name; declared_type; declared_proof; value; body = propagate_return_hint body th; loc }
    | ELetProof { value_name; proof_name; proof_index; value; body; loc } ->
      ELetProof { value_name; proof_name; proof_index; value; body = propagate_return_hint body th; loc }
    | EOk { value; proof; loc } ->
      EOk { value = propagate_return_hint value th; proof; loc }
    | EWithDatabase { database_name; body; loc } ->
      EWithDatabase { database_name; body = propagate_return_hint body th; loc }
    | EWithCapabilities { capabilities; body; loc } ->
      EWithCapabilities { capabilities; body = propagate_return_hint body th; loc }
    | EWithTransaction { body; loc } ->
      EWithTransaction { body = propagate_return_hint body th; loc }
    | _ -> e
  in
  let body' = match return_type_hint with
    | Some th -> propagate_return_hint body th
    | None -> body
  in
  (* if we consumed an INDENT for the declaration continuation, consume DEDENT now *)
  skip_newlines s;
  if (consumed_decl_indent || indent_before_return) && peek s = DEDENT then advance s;
  let loc = span loc0 (current_loc s) in
  return { kind; name; params; return_spec; capabilities; body = body'; loc;
           desugared_from = None; doc = None }

(* Read the function name, then parse the rest of the declaration. The decl's
   loc must start at the name (callers consumed the keyword), matching the
   pre-refactor behaviour relied on by go-to-definition / occurrences. *)
let parse_fn_decl kind s =
  let loc0 = current_loc s in
  let* name = expect_ident s in
  parse_fn_decl_named kind name loc0 s

let parse_field_defs s =
  let* _ = expect s LBRACE in
  skip_layout s;
  let fields = ref [] in
  let continue_ = ref true in
  while !continue_ && peek s <> RBRACE && peek s <> EOF do
    skip_layout s;
    if peek s = RBRACE then continue_ := false
    else begin
      let loc0 = current_loc s in
      match expect_ident s with
      | Ok fname ->
        (match expect s COLON with
         | Ok () ->
           (match parse_type_expr s with
            | Ok ty ->
              (* optional proof annotation *)
              let proof_ann, checker =
                if peek s = PROOF_ANNOT then begin
                  advance s;
                  match parse_proof_expr s with
                  | Ok p -> Some p, None
                  | Err _ -> None, None
                end else None, None
              in
              (* optional @db(type) *)
              let db_type =
                if peek s = AT then begin
                  advance s;
                  match peek s with
                  | IDENT "db" ->
                    advance s;
                    if peek s = LPAREN then begin
                      advance s;
                      match peek s with
                      | IDENT t -> advance s; if peek s = RPAREN then advance s; Some t
                      | _ -> None
                    end else None
                  | _ -> None
                end else None
              in
              let loc = span loc0 (current_loc s) in
              fields := { name = fname; type_expr = ty; proof_ann; checker; db_type; loc } :: !fields;
              skip_layout s;
              if peek s = COMMA then (advance s; skip_layout s)
            | Err _ -> continue_ := false)
         | Err _ -> continue_ := false)
      | Err _ -> continue_ := false
    end
  done;
  skip_layout s;
  let* _ = expect s RBRACE in
  return (List.rev !fields)

(** Parse a record declaration. *)
let parse_record_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* fields = parse_field_defs s in
  (* optional invariant annotation: } ::: Proof field1 field2 [via checkerFn] *)
  let* invariant =
    if peek s = PROOF_ANNOT then begin
      advance s;
      (match parse_proof_expr s with
       | Ok proof_text ->
         let checker_name =
           if peek s = VIA then begin
             advance s;
             match expect_ident s with Ok n -> Some n | Err _ -> None
           end else None
         in
         let loc = current_loc s in
         return (Some { proof_text; checker_name; loc })
       | Err _ -> return None)
    end else
      return None
  in
  let loc = span loc0 (current_loc s) in
  return { name; fields; invariant; loc }

(** Parse an entity declaration. *)
let parse_entity_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* _ = expect s TABLE in
  let* table = expect_string s in
  let* _ = expect s PRIMARY_KEY in
  let* pk = expect_ident s in
  let* fields = parse_field_defs s in
  let loc = span loc0 (current_loc s) in
  return { name; table; primary_key = pk; fields; loc }

(** Parse a type declaration: newtype, type alias, or ADT. *)
let rec parse_type_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  skip_newlines s;
  (* Parse optional type parameters: lowercase identifiers before = *)
  let params = ref [] in
  while (match peek s with IDENT p -> p.[0] >= 'a' && p.[0] <= 'z' | _ -> false) do
    (match peek s with
     | IDENT p -> advance s; params := !params @ [p]
     | _ -> ())
  done;
  let params = !params in
  skip_newlines s;
  match peek s with
  | EQ ->
    advance s;
    skip_newlines s;
    (* Either newtype (single variant) or ADT (pipe-separated) *)
    (match peek s with
     | PIPE ->
       (* ADT with first variant preceded by | *)
       advance s;
       parse_adt_variants s name params loc0
     | INDENT ->
       (* ADT variants on indented lines after `= \n  | ...` *)
       advance s;
       let* variants = parse_adt_variants_indented s in
       if peek s = DEDENT then advance s;
       let loc = span loc0 (current_loc s) in
       return (TypeAdt { name; params; variants; loc })
     | UIDENT first_ctor ->
       (* Could be newtype, ADT, or transparent alias *)
       let saved = s.pos in
       advance s;
       if peek s = PIPE then begin
         (* Check if the pipe is on the same line — reject single-line ADT *)
         let pipe_line = (if s.pos < Array.length s.tokens then s.tokens.(s.pos).line else 0) in
         let ctor_line = (if saved < Array.length s.tokens then s.tokens.(saved).line else 0) in
         if pipe_line = ctor_line then
           err s "ADT variants must be on separate lines. Use:\n\n  type Name =\n    | Variant1\n    | Variant2"
         else begin
           (* ADT: Type = Ctor1 \n| Ctor2 ... *)
           let first_var = { ctor = first_ctor; fields = []; loc = current_loc s } in
           parse_adt_more_variants s [first_var] name params loc0
         end
       end else if (match peek s with IDENT _ | UIDENT _ | INT _ -> true | _ -> false) then begin
         (* ADT variant with fields: Ctor field:Type *)
         s.pos <- saved;
         parse_adt_variants s name params loc0
       end else begin
         (* Newtype: type UserId = String *)
         s.pos <- saved;
         let* base = parse_type_expr s in
         let loc = span loc0 (current_loc s) in
         return (TypeNewtype { name; base_type = base; loc })
       end
     | IDENT _ ->
       (* §7.11 (review 2026-07): a single non-ADT base is a NOMINAL newtype
          (tagged at runtime), UNIFORMLY — not a transparent alias — whether the
          base is a named type (`String`), a type variable (`a`), or a
          tuple/parenthesized type.  Previously tvar/tuple/paren bases became
          transparent aliases, so §7.11's runtime nominal-tag guarantee (and the
          `type Name = BaseType` "nominal, not transparent" wording) held only for
          uppercase-named bases.  This makes the runtime encoding match the spec. *)
       let* base = parse_type_expr s in
       let loc = span loc0 (current_loc s) in
       return (TypeNewtype { name; base_type = base; loc })
     | _ ->
       let* base = parse_type_expr s in
       let loc = span loc0 (current_loc s) in
       return (TypeNewtype { name; base_type = base; loc }))
  | NEWLINE | INDENT ->
    skip_newlines s;
    (* ADT with variants each on separate indented lines *)
    if peek s = INDENT then begin
      advance s;
      let* variants = parse_adt_variants_indented s in
      if peek s = DEDENT then advance s;
      let loc = span loc0 (current_loc s) in
      return (TypeAdt { name; params; variants; loc })
    end else
      err s "expected = or indented ADT variants"
  | _ ->
    err s (Printf.sprintf "expected = after type name, got %s" (tok_to_string (peek s)))

and parse_adt_variants s name params loc0 =
  skip_newlines s;
  let* variants = parse_adt_variants_flat s in
  let loc = span loc0 (current_loc s) in
  return (TypeAdt { name; params; variants; loc })

and parse_adt_variants_flat s =
  (* Variants separated by | at same indent level.
     Consume leading | if present (for the case after first variant is already parsed). *)
  let variants = ref [] in
  let continue_ = ref true in
  (* If we're called right after a first variant was already consumed,
     the current token might be PIPE. Consume it to start this variant. *)
  if peek s = PIPE then (advance s; skip_newlines s);
  while !continue_ do
    skip_newlines s;
    match peek s with
    | UIDENT ctor ->
      let loc0 = current_loc s in
      advance s;
      (* Parse labeled fields: [fieldname:Type ...] *)
      let fields = ref [] in
      let continue2 = ref true in
      while !continue2 do
        match peek s with
        | LBRACE ->
          (* Brace-enclosed field list: { field1: Type1, field2: Type2 } *)
          advance s;  (* consume { *)
          let brace_continue = ref true in
          while !brace_continue && peek s <> RBRACE && peek s <> EOF do
            skip_layout s;
            if peek s = RBRACE || peek s = EOF then
              brace_continue := false
            else
              (match peek s with
               | IDENT fname when peek2 s = COLON ->
                 let floc = current_loc s in
                 advance s; advance s;  (* consume fname and : *)
                 (match parse_type_expr s with
                  | Ok ty ->
                    let proof_ann =
                      if peek s = PROOF_ANNOT then begin
                        advance s;
                        match parse_proof_expr s with
                        | Ok p -> Some p
                        | Err _ -> None
                      end else None
                    in
                    let fd = { name = fname; type_expr = ty; proof_ann;
                               checker = None; db_type = None; loc = floc } in
                    fields := fd :: !fields;
                    if peek s = COMMA then advance s
                  | Err _ -> brace_continue := false)
               | _ -> brace_continue := false)
          done;
          if peek s = RBRACE then advance s;  (* consume } *)
          continue2 := false
        | LPAREN ->
          (* Parenthesized labeled field: (fname: Type [::: Proof]) *)
          let floc = current_loc s in
          let saved = s.pos in
          advance s;  (* consume ( *)
          (match peek s with
           | IDENT fname when peek2 s = COLON ->
             advance s; advance s;  (* consume fname and : *)
             (match parse_type_expr s with
              | Ok ty ->
                let proof_ann =
                  if peek s = PROOF_ANNOT then begin
                    advance s;
                    match parse_proof_expr s with
                    | Ok p -> Some p
                    | Err _ -> None
                  end else None
                in
                if peek s = RPAREN then begin
                  advance s;
                  let fd = { name = fname; type_expr = ty; proof_ann;
                             checker = None; db_type = None; loc = floc } in
                  fields := fd :: !fields
                end else begin
                  s.pos <- saved; continue2 := false
                end
              | Err _ -> s.pos <- saved; continue2 := false)
           | _ -> s.pos <- saved; continue2 := false)
        | IDENT fname when peek2 s = COLON ->
          let floc = current_loc s in
          advance s;
          advance s;  (* consume : *)
          (match parse_type_expr s with
           | Ok ty ->
             let proof_ann =
               if peek s = PROOF_ANNOT then begin
                 advance s;
                 match parse_proof_expr s with
                 | Ok p -> Some p
                 | Err _ -> None
               end else None
             in
             let fd = { name = fname; type_expr = ty; proof_ann;
                        checker = None; db_type = None; loc = floc } in
             fields := fd :: !fields
           | Err _ -> continue2 := false)
        | PIPE | NEWLINE | INDENT | DEDENT | EOF | RBRACE -> continue2 := false
        | _ -> continue2 := false
      done;
      let loc = span loc0 (current_loc s) in
      variants := { ctor; fields = List.rev !fields; loc } :: !variants;
      if peek s = PIPE then begin advance s; skip_newlines s end
      else continue_ := false
    | _ -> continue_ := false
  done;
  return (List.rev !variants)

and parse_adt_more_variants s acc name params loc0 =
  (* Continue parsing | Ctor ... variants after first one already in acc *)
  let* more = parse_adt_variants_flat s in
  let variants = acc @ more in
  let loc = span loc0 (current_loc s) in
  return (TypeAdt { name; params; variants; loc })

and parse_adt_variants_indented s =
  (* ADT variants each on a separate line (indented).
     Tesl syntax:
       = Ctor1          <- first variant preceded by =
       | Ctor2          <- subsequent variants preceded by |
  *)
  let variants = ref [] in
  let continue_ = ref true in
  (* The first variant may be preceded by = *)
  skip_newlines s;
  if peek s = EQ then advance s;  (* consume leading = *)
  while !continue_ && peek s <> DEDENT && peek s <> EOF do
    skip_newlines s;
    if peek s = DEDENT || peek s = EOF then continue_ := false
    else if peek s = PIPE then begin
      advance s;
      (match parse_adt_variant_line s with
       | Ok v -> variants := v :: !variants
       | Err _ -> continue_ := false)
    end else begin
      match peek s with
      | UIDENT _ ->
        (match parse_adt_variant_line s with
         | Ok v -> variants := v :: !variants
         | Err _ -> continue_ := false)
      | _ -> continue_ := false
    end
  done;
  return (List.rev !variants)

and parse_adt_variant_line s =
  let loc0 = current_loc s in
  let* ctor = expect_uident s in
  let fields = ref [] in
  let continue_ = ref true in
  while !continue_ do
    match peek s with
    | LBRACE ->
      (* Brace-enclosed field list: { field1: Type1, field2: Type2 } *)
      advance s;  (* consume { *)
      let brace_continue = ref true in
      while !brace_continue && peek s <> RBRACE && peek s <> EOF do
        skip_layout s;
        if peek s = RBRACE || peek s = EOF then
          brace_continue := false
        else
          (match peek s with
           | IDENT fname when peek2 s = COLON ->
             let floc = current_loc s in
             advance s; advance s;  (* consume fname and : *)
             (match parse_type_expr s with
              | Ok ty ->
                let proof_ann =
                  if peek s = PROOF_ANNOT then begin
                    advance s;
                    match parse_proof_expr s with
                    | Ok p -> Some p
                    | Err _ -> None
                  end else None
                in
                fields := { name = fname; type_expr = ty; proof_ann;
                            checker = None; db_type = None; loc = floc } :: !fields;
                if peek s = COMMA then advance s
              | Err _ -> brace_continue := false)
           | _ -> brace_continue := false)
      done;
      if peek s = RBRACE then advance s;  (* consume } *)
      continue_ := false
    | IDENT fname when peek2 s = COLON ->
      (* Labeled field: fname: Type *)
      let floc = current_loc s in
      advance s; advance s;
      (match parse_type_expr s with
       | Ok ty ->
         let proof_ann =
           if peek s = PROOF_ANNOT then begin
             advance s;
             match parse_proof_expr s with
             | Ok p -> Some p
             | Err _ -> None
           end else None
         in
         fields := { name = fname; type_expr = ty; proof_ann;
                     checker = None; db_type = None; loc = floc } :: !fields
       | Err _ -> continue_ := false)
    | LPAREN ->
      (* Could be:
         1. Parenthesized labeled field:  (fname: Type [::: Proof])
         2. Positional (unlabeled) field: (complex-type-expr)
         Try labeled first. *)
      let floc = current_loc s in
      let saved = s.pos in
      advance s;  (* consume ( *)
      (match peek s with
       | IDENT fname when peek2 s = COLON ->
         advance s; advance s;  (* consume fname and : *)
         (match parse_type_expr s with
          | Ok ty ->
            let proof_ann =
              if peek s = PROOF_ANNOT then begin
                advance s;
                match parse_proof_expr s with
                | Ok p -> Some p
                | Err _ -> None
              end else None
            in
            if peek s = RPAREN then begin
              advance s;  (* consume ) *)
              fields := { name = fname; type_expr = ty; proof_ann;
                          checker = None; db_type = None; loc = floc } :: !fields
            end else begin
              s.pos <- saved;
              (* Fall through to positional *)
              (match parse_type_expr s with
               | Ok ty2 ->
                 let pos = List.length !fields in
                 let label = if pos = 0 then "value" else Printf.sprintf "value%d" (pos + 1) in
                 fields := { name = label; type_expr = ty2; proof_ann = None;
                             checker = None; db_type = None; loc = floc } :: !fields
               | Err _ -> continue_ := false)
            end
          | Err _ ->
            s.pos <- saved;
            (match parse_type_expr s with
             | Ok ty ->
               let pos = List.length !fields in
               let label = if pos = 0 then "value" else Printf.sprintf "value%d" (pos + 1) in
               fields := { name = label; type_expr = ty; proof_ann = None;
                           checker = None; db_type = None; loc = floc } :: !fields
             | Err _ -> continue_ := false))
       | _ ->
         s.pos <- saved;
         (match parse_type_expr s with
          | Ok ty ->
            let pos = List.length !fields in
            let label = if pos = 0 then "value" else Printf.sprintf "value%d" (pos + 1) in
            fields := { name = label; type_expr = ty; proof_ann = None;
                        checker = None; db_type = None; loc = floc } :: !fields
          | Err _ -> continue_ := false))
    | UIDENT _ ->
      (* Positional (unlabeled) field: each bare TypeName is ONE field.
         Use parse_type_atom (not parse_type_expr) so that adjacent UIDENTs
         like `B Int Int` produce two separate Int fields rather than one
         TApp(Int,Int) field. Parameterised types need parentheses: B (List Int) Int. *)
      let floc = current_loc s in
      (match parse_type_atom s with
       | Ok ty ->
         let pos = List.length !fields in
         let label = if pos = 0 then "value" else Printf.sprintf "value%d" (pos + 1) in
         fields := { name = label; type_expr = ty; proof_ann = None;
                     checker = None; db_type = None; loc = floc } :: !fields
       | Err _ -> continue_ := false)
    | NEWLINE | DEDENT | EOF | PIPE -> continue_ := false
    | _ -> continue_ := false
  done;
  let loc = span loc0 (current_loc s) in
  return { ctor; fields = List.rev !fields; loc }

(** Parse a capability declaration. *)
let parse_capability_form s =
  let loc0 = current_loc s in
  let* name = expect_ident s in
  let* implies =
    if peek s = IMPLIES then begin
      advance s;
      let caps = ref [] in
      let continue_ = ref true in
      (* Parse the implied-capability list with the SAME [parse_cap_name] the
         `requires [...]` list uses, so the two never diverge. That parser accepts
         plain idents, the `email` keyword token (EMAIL), and `cacheCap <Name>` —
         all of which are valid capabilities. Doing it by hand here previously
         missed `email` (`capability X implies email` misparsed the leftover
         `email` as an `email …` declaration) and `cacheCap`. *)
      while !continue_ do
        match peek s with
        | IDENT _ | EMAIL ->
          (match parse_cap_name s with
           | Ok n -> caps := n :: !caps;
             if peek s = COMMA then advance s else continue_ := false
           | Err _ -> continue_ := false)
        | _ -> continue_ := false
      done;
      return (List.rev !caps)
    end else
      return []
  in
  let loc = span loc0 (current_loc s) in
  return { name; implies; loc }

(** Parse a fact declaration: `fact PredicateName` or `fact PredicateName (params...)`
    Supports multiple parameter groups: `fact Pred (a: T) (b: T) (c: T)` as well as
    a single group with comma-separated params: `fact Pred (a: T, b: T)`.
    Both styles produce the same flat [params] list. *)
let parse_fact_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  (* Collect params from all consecutive (…) groups *)
  let all_params = ref [] in
  while peek s = LPAREN do
    (match parse_params s with
     | Ok group -> all_params := !all_params @ group
     | Err _    -> ())
  done;
  let loc = span loc0 (current_loc s) in
  return Ast.{ name; params = !all_params; loc }


let parse_codec_form s name type_name =
  let loc0 = current_loc s in
  let* _ = expect s LBRACE in
  skip_layout s;
  let to_json = ref ToJsonForbidden in
  let from_json = ref FromJsonForbidden in
  (* Track which JSON directions were stated EXPLICITLY.  Omitting a direction
     used to silently default to *_forbidden, which masked real bugs (e.g. a
     response type with only `toJson` would still be treated as decode-forbidden,
     and a type with neither was silently non-serializable).  Require both. *)
  let to_set = ref false in
  let from_set = ref false in
  while peek s <> RBRACE && peek s <> EOF do
    skip_layout s;
    (match peek s with
     | TO_JSON ->
       advance s;
       to_set := true;
       if peek s = LBRACE then begin
         advance s; skip_layout s;
         let entries = ref [] in
         while peek s <> RBRACE && peek s <> EOF do
           skip_layout s;
           if peek s = RBRACE then ()
           else begin
             let entry_loc0 = current_loc s in
             let saved = s.pos in
             (match expect_ident s with
             | Ok fname ->
               (match expect s ARROW with
                | Ok () ->
                  (match expect_string s with
                   | Ok jkey ->
                     (match expect s WITH_CODEC with
                      | Ok () ->
                        (match expect_codec_name s with
                         | Ok cname ->
                           let e = { field_name = fname; json_key = jkey; codec = cname; loc = span entry_loc0 (current_loc s) } in
                           entries := e :: !entries;
                           skip_layout s;
                           if peek s = COMMA then advance s
                         | Err _ -> s.pos <- saved; advance s)
                      | Err _ -> s.pos <- saved; advance s)
                   | Err _ -> s.pos <- saved; advance s)
                | Err _ -> s.pos <- saved; advance s)
             | Err _ -> advance s)
           end
         done;
         if peek s = RBRACE then advance s;
         to_json := ToJsonFields (List.rev !entries)
       end
     | TO_JSON_FORBIDDEN ->
       advance s;
       to_set := true;
       to_json := ToJsonForbidden
     | FROM_JSON ->
       advance s;
       from_set := true;
       (* fromJson [ { field <- "key" with_codec c via checker, ... }, ... ] *)
       if peek s = LBRACKET then begin
         advance s; skip_layout s;
         let alts = ref [] in
         while peek s <> RBRACKET && peek s <> EOF do
           skip_layout s;
           if peek s = LBRACE then begin
             advance s; skip_layout s;
             let entries = ref [] in
             while peek s <> RBRACE && peek s <> EOF do
               skip_layout s;
               if peek s = RBRACE then ()
               else begin
                 let entry_loc0 = current_loc s in
                 match peek s with
                 | VIA ->
                   (* Cross-field checker: via checkerFn *)
                   let checker_loc0 = current_loc s in
                   advance s;
                   (match expect_ident s with
                    | Ok checker ->
                      let e = DecodeCrossCheck { checker; loc = span checker_loc0 (current_loc s) } in
                      entries := e :: !entries;
                      skip_layout s;
                      if peek s = COMMA then advance s
                    | Err _ -> ())
                 | RBRACE | EOF -> ()
                 | _ ->
                   (* Decode field: name may be a reserved-keyword token (e.g. `email`
                      lexes to EMAIL) — bind via the keyword-tolerant `expect_ident`
                      so such fields are NOT silently dropped. `via` is handled above,
                      so expect_ident here never mis-consumes a cross-field checker. *)
                   let saved = s.pos in
                   (match expect_ident s with
                    | Ok fname ->
                      (* Tolerate a stray `:` after the field name (a config-block
                         habit: `username: <- "username"`).  The codec mapping syntax
                         is `field <- "key"`; without this the `:` fell through to the
                         "skip unknown" arm below, silently dropping the ENTIRE mapping
                         and emitting an empty decoder — i.e. a runtime body-validation
                         400 with no compile-time signal. *)
                      (if peek s = COLON then advance s);
                      (match peek s with
                       | BACKARROW ->
                         advance s;
                         (match peek s with
                          (* `field <- default <literal>`: the field is populated
                             from a constant at construction, not decoded from JSON.
                             Without this branch the whole entry was silently
                             dropped (expect_string failed on `default`), yielding a
                             decoder that omits the field — an incomplete record that
                             traps at the boundary. *)
                          | IDENT "default" ->
                            advance s;
                            (match parse_expr s with
                             | Ok lit_e ->
                               let racket = (match lit_e with
                                 | ELit { lit = LInt n; _ } -> Some (string_of_int n)
                                 | ELit { lit = LBool b; _ } -> Some (if b then "#t" else "#f")
                                 | ELit { lit = LString str; _ } -> Some (Printf.sprintf "%S" str)
                                 | ELit { lit = LFloat f; _ } -> Some (Float_fmt.to_faithful_literal f)
                                 | _ -> None) in
                               (match racket with
                                | Some default_expr ->
                                  let e = DecodeDefault { field_name = fname; default_expr;
                                    loc = span entry_loc0 (current_loc s) } in
                                  entries := e :: !entries;
                                  skip_layout s;
                                  if peek s = COMMA then advance s
                                | None -> ())
                             | Err _ -> ())
                          | _ ->
                         (match expect_string s with
                          | Ok jkey ->
                            (match expect s WITH_CODEC with
                             | Ok () ->
                               (match expect_codec_name s with
                                | Ok cname ->
                                  let via_fns = ref [] in
                                  if peek s = VIA then begin
                                    advance s;
                                    match parse_via_checker_chain s with
                                    | Ok names -> via_fns := names
                                    | Err _ -> ()
                                  end;
                                  let e = DecodeField { field_name = fname; json_key = jkey;
                                    codec = cname; via = !via_fns; loc = span entry_loc0 (current_loc s) } in
                                  entries := e :: !entries;
                                  skip_layout s;
                                  if peek s = COMMA then advance s
                                | Err _ -> ())
                             | Err _ -> ())
                          | Err _ -> ()))
                       | _ -> advance s (* skip unknown *))
                    | Err _ ->
                      (* Not an identifier/keyword name — skip one token to make progress. *)
                      s.pos <- saved; advance s)
               end
             done;
             if peek s = RBRACE then advance s;
             (* Check for } via checker — outer cross-check after the alt block *)
             skip_layout s;
             let alt_entries = ref (List.rev !entries) in
             if peek s = VIA then begin
               let checker_loc0 = current_loc s in
               advance s;
               (match expect_ident s with
                | Ok checker ->
                  alt_entries := !alt_entries @ [DecodeCrossCheck { checker; loc = span checker_loc0 (current_loc s) }]
                | Err _ -> ())
             end;
             alts := !alt_entries :: !alts;
             skip_layout s;
             if peek s = COMMA then advance s
           end else
            if peek s <> RBRACKET && peek s <> EOF then advance s (* skip *)
         done;
         if peek s = RBRACKET then advance s;
         from_json := FromJsonAlts (List.rev !alts)
       end
     | FROM_JSON_FORBIDDEN ->
       advance s;
       from_set := true;
       from_json := FromJsonForbidden
     | ADT_JSON ->
       advance s;
       to_set := true;
       from_set := true;
       to_json := ToJsonAdt;
       from_json := FromJsonAdt
     | NEWLINE -> advance s
     | RBRACE | EOF -> () | _ -> advance s  (* skip unknown tokens in codec *)
    );
    skip_layout s
  done;
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  if not !to_set || not !from_set then
    let missing =
      match !to_set, !from_set with
      | false, false -> "both toJson and fromJson"
      | false, _     -> "toJson"
      | _, false     -> "fromJson"
      | _            -> ""
    in
    Err { msg = Printf.sprintf
            "codec `%s` must declare both JSON directions explicitly; missing %s. \
             Add `toJson { … }` or `toJson_forbidden`, and `fromJson [ … ]` or \
             `fromJson_forbidden` (or use `adtJson` for an ADT type)."
            name missing;
          loc = loc0 }
  else
    return { name; type_name; to_json = !to_json; from_json = !from_json; loc }

(** Parse a database declaration: `database NAME = Database { … }`. *)
let parse_database_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  (* Typed-record syntax: `database NAME = Database { … }`. The RHS is an
     ordinary record-construction expression; the config checker validates it
     and the desugar pass fills the structured fields below. *)
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return { name; backend = ""; schema = ""; entities = []; postgres = [];
           config_expr = Some (hint_expr_type type_name body); loc }

(** Parse a queue block. *)
let parse_queue_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  (* App pass: `queue NAME requires [caps] = Queue { … }` — the workers folded
     into the queue inherit these capabilities. *)
  let* reqs = parse_requires s in
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return { name; database = ""; jobs = []; max_attempts = None;
           backoff = None; initial_delay = None;
           capabilities = reqs; number_of_workers = None;
           config_expr = Some (hint_expr_type type_name body); loc }

(** Parse a cache block:
      cache UserProfileCache {
        database: MainDB
        defaultTtl: 3600
        valueType: UserProfile
      } *)
let parse_cache_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  (* Typed-record syntax: `cache NAME = Cache { … }`. *)
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return { name; database = ""; value_type = TName { name = "Unit"; loc = dummy_loc "" };
           default_ttl = None;
           config_expr = Some (hint_expr_type type_name body); loc }

(** Parse an agent block:
      agent SupportAgent requires [supportAi] = Agent {
        provider:     anthropic
        model:        "claude-opus-4-8"
        apiKey:       env "ANTHROPIC_API_KEY"
        systemPrompt: "You are a concise support agent."
        tools:        [lookupOrder, refundOrder]
        maxTokens:    1500
      }
    Everything is left in [config_expr]; {!Desugar.desugar_agent_config} lifts the
    structured fields the emitter reads (same pattern as queue/cache/email). *)
let parse_agent_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* reqs = parse_requires s in
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return { Ast.name; capabilities = reqs;
           provider = ""; model = ""; api_key = ""; endpoint = "";
           system_prompt = ""; max_tokens = 0; tools = [];
           config_expr = Some (hint_expr_type type_name body); loc }

(** Parse an email declaration:
      email AppEmail = Email {
        database: MainDB
        smtp: SmtpConfig { host: env "SMTP_HOST", port: 587, ... }
      } *)
let parse_email_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return ({ Ast.name; database = "";
            smtp = { Ast.host = ""; port = 587; username = ""; password = ""; tls = true };
            config_expr = Some (hint_expr_type type_name body); loc }
          : Ast.email_form)

(** Parse a channel block. *)
let parse_channel_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  (* Optional key params: Channel(key: Type, ...) *)
  let key_params_from_decl =
    if peek s = LPAREN then begin
      match parse_params s with
      | Ok ps -> ps
      | Err _ -> []
    end else []
  in
  let* _ = expect s EQ in
  let* type_name = expect_uident s in
  let* body = parse_record_literal s in
  let loc = span loc0 (current_loc s) in
  return { name; key_params = key_params_from_decl; database = "";
           payload = TName { name = "String"; loc = loc0 };
           config_expr = Some (hint_expr_type type_name body); loc }

(** Parse capture declaration. *)
let parse_capture_form s =
  let loc0 = current_loc s in
  let* name = expect_ident s in
  let* _ = expect s COLON in
  (* Two forms:
     1. capture captureVar: varName: Type using codec [via checker]
     2. capture captureVar: Type::: Proof [varName] using codec via checker — abbreviated *)
  let binding_saved = s.pos in
  let* binding =
    match try_parse s parse_binding with
    | Ok (Some b) -> return b
    | _ ->
      (* Abbreviated form: use capture name as binding var *)
      s.pos <- binding_saved;
      let* ty = parse_type_expr s in
      let* proof_ann =
        if peek s = PROOF_ANNOT then begin
          advance s;
          (match parse_proof_expr s with Ok p -> return (Some p) | Err _ -> return None)
        end else return None
      in
      let rec abbreviated_binding_name default = function
        | PredApp { args = []; _ } -> default
        | PredApp { args; _ } -> List.hd (List.rev args)
        | PredAnd { left; right; _ } ->
          let right_name = abbreviated_binding_name default right in
          if right_name <> default then right_name
          else abbreviated_binding_name default left
      in
      let binding_name = ref name in
      (match proof_ann with
       | Some p -> binding_name := abbreviated_binding_name name p
       | None -> ());
      (* Use optional trailing identifier as the capture binder name. *)
      if (match peek s with IDENT _ -> true | _ -> false) &&
         peek s <> USING && peek s <> VIA then
        (match expect_ident s with
         | Ok n -> binding_name := n
         | Err _ -> ());
      let loc = span loc0 (current_loc s) in
      return { name = !binding_name; type_expr = ty; proof_ann; loc }
  in
  (* Optional via checker before using *)
  let checker = ref None in
  if peek s = VIA then begin
    advance s;
    (match expect_ident s with Ok n -> checker := Some n | Err _ -> ())
  end;
  let* parser_name =
    if peek s = USING then begin
      advance s;
      (match expect_ident s with Ok n -> return n | Err _ -> return "stringCodec")
    end else return "stringCodec"
  in
  if peek s = VIA then begin
    advance s;
    (match expect_ident s with Ok n -> checker := Some n | Err _ -> ())
  end;
  let loc = span loc0 (current_loc s) in
  return { name; binding; parser = parser_name; checker = !checker; loc }

(** Parse the api block. *)
let parse_api_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* _ = expect s LBRACE in
  skip_layout s;
  let endpoints = ref [] in
  let ep_counter = ref 0 in
  (* GDP-AUTH-DROP (2026-07 fresh review, HIGH): a malformed/incomplete endpoint
     `auth` clause (e.g. missing the trailing `via <fn>`) must NOT be silently
     dropped — doing so leaves the endpoint's [auth] field = None, which turns a
     would-be protected endpoint into a fully public one with zero diagnostics.
     Any such failure is recorded here and fails the parse fail-closed. *)
  let ep_parse_err : parse_error option ref = ref None in
  while peek s <> RBRACE && peek s <> EOF do
    skip_layout s;
    if peek s = RBRACE then ()
    else begin
      let ep_loc0 = current_loc s in
      let method_ = match peek s with
        | IDENT "get"    -> advance s; Some GET
        | IDENT "post"   -> advance s; Some POST
        | IDENT "put"    -> advance s; Some PUT
        | IDENT "delete" -> advance s; Some DELETE
        | IDENT "patch"  -> advance s; Some PATCH
        | IDENT "sse" | SSE -> advance s; Some SSE  (* SSE stream *)
        | _              -> advance s; None
      in
      match method_ with
      | None -> ()  (* skip unknown *)
      | Some method_ ->
        incr ep_counter;
        match expect_string s with
        | Err _ -> ()
        | Ok path ->
          let auth : api_auth option ref = ref None in
          let body : binding option ref = ref None in
          let body_wire = ref None in
          let body_dec = ref None in
          let body_via_ = ref None in
          let resp_wire = ref None in
          let resp_enc = ref None in
          let captures : api_capture list ref = ref [] in
          let return_spec = ref (RetPlain { ty = TName { name = "Unit"; loc = ep_loc0 }; loc = ep_loc0 }) in
          let subscribes = ref [] in
          let subscribe_key = ref None in
          let continue_ = ref true in
          let return_seen = ref false in
          let clause_after_return = ref false in
          while !continue_ do
            skip_layout s;
            (* After `->` has been seen, any further endpoint clause keyword is a
               structural error — flag it and skip the keyword token; the clause
               arguments will be consumed by subsequent `| _ -> advance s` iterations. *)
            if !return_seen then begin
              match peek s with
              | AUTH | CAPTURE | SUBSCRIBE ->
                advance s; clause_after_return := true
              | IDENT ("body" | "response") ->
                advance s; clause_after_return := true
              | ARROW ->
                advance s; clause_after_return := true;
                (* Consume the spurious return spec so its tokens don't confuse things *)
                (match parse_return_spec_no_arrow s with _ -> ())
              | IDENT ("get" | "post" | "put" | "delete" | "patch" | "sse") | SSE ->
                continue_ := false
              | NEWLINE -> advance s
              | RBRACE | EOF -> continue_ := false
              | _ -> advance s
            end else
            (match peek s with
             | AUTH ->
               advance s;
               (match parse_binding s with
                | Ok b ->
                  (match expect s VIA with
                   | Ok () ->
                     (match expect_ident s with
                      | Ok vfn -> auth := Some { binding = b; via_fn = vfn }
                      | Err e ->
                        if !ep_parse_err = None then ep_parse_err := Some e)
                   | Err _ ->
                     if !ep_parse_err = None then
                       ep_parse_err := Some {
                         msg = "auth clause requires `via <authFunction>` \
                                (e.g. `auth user: User ::: Authenticated user via cookieAuth`)";
                         loc = current_loc s })
                | Err e ->
                  if !ep_parse_err = None then ep_parse_err := Some e)
             | IDENT "body" ->
               advance s;
               (match parse_api_body_binding s with
                | Ok b ->
                  body := Some b;
                  if peek s = VIA then begin
                    advance s;
                    (match expect_ident s with
                     | Ok vfn -> body_via_ := Some vfn
                     | Err _ -> ())
                  end
                | Err _ -> ())
             | IDENT "response" ->
               advance s;
               (* response WireResponseType via encoderFn *)
               (match peek s with
                | UIDENT wire ->
                  advance s;
                  resp_wire := Some wire;
                  if peek s = VIA then begin
                    advance s;
                    (match expect_ident s with
                     | Ok enc -> resp_enc := Some enc
                     | Err _ -> ())
                  end
                | _ -> ())
             | CAPTURE ->
               advance s;
               (match parse_binding s with
                | Ok b ->
                  (match peek s with
                   (* Inline form: `capture x: T using <codec> [via <check>]` — no
                      separate `capturer` declaration needed. (`using`/`via` are real
                      keyword tokens, so the type parser terminates on them naturally.) *)
                   | USING ->
                     advance s;
                     (match expect_ident s with
                      | Ok codec ->
                        let chk =
                          if peek s = VIA then begin
                            advance s;
                            (match expect_ident s with Ok c -> Some c | Err _ -> None)
                          end else None
                        in
                        captures := !captures @
                          [{ binding = b; via_fn = ""; inline_codec = Some codec; inline_check = chk }]
                      | Err _ -> ())
                   (* Reference form: `capture x: T via <capturer>`. *)
                   | VIA ->
                     advance s;
                     (match expect_ident s with
                      | Ok vfn -> captures := !captures @
                          [{ binding = b; via_fn = vfn; inline_codec = None; inline_check = None }]
                      | Err _ -> ())
                   | _ -> ())
                | Err _ -> ())
             | SUBSCRIBE ->
                advance s;
                (match peek s with
                 | UIDENT ch | IDENT ch ->
                   advance s; subscribes := ch :: !subscribes;
                   (* Record the channel-key argument `subscribe Ch(arg)` so the
                      emitter can pick which `:param` segment carries the key
                      (it need not be the last segment).  Parens optional: a
                      channel with no key parameter is `subscribe Ch`. *)
                   (match peek s with
                    | LPAREN ->
                      advance s;
                      (match peek s with
                       | IDENT arg | UIDENT arg ->
                         advance s;
                         if !subscribe_key = None then subscribe_key := Some arg;
                         (match peek s with RPAREN -> advance s | _ -> ())
                       | RPAREN -> advance s
                       | _ -> ())
                    | _ -> ())
                 | _ -> ())
             | ARROW ->
               advance s;
               (match parse_return_spec_no_arrow s with
                | Ok rs -> return_spec := rs
                | Err _ -> ());
               return_seen := true
             | IDENT ("get" | "post" | "put" | "delete" | "patch" | "sse") | SSE ->
               continue_ := false
             | NEWLINE -> advance s
             | RBRACE | EOF -> continue_ := false
             | _ -> advance s  (* skip *)
            )
          done;
          let ep_loc = span ep_loc0 (current_loc s) in
          (* S6a: SSE endpoints stream a channel and cannot hold a body/response;
             everything else is an HTTP request/response endpoint. For SSE we do NOT
             carry any body/response/return VALUE (so emit can never use one), but we
             record which such clauses were written so validation can reject them
             with a clear message instead of silently dropping them. *)
          let kind =
            if method_ = SSE then
              let illegal_clauses =
                (if !body <> None then ["body"] else [])
                @ (if !resp_wire <> None || !resp_enc <> None then ["response"] else [])
                @ (if !return_seen then ["-> ReturnType"] else [])
              in
              Sse { subscribes = !subscribes; subscribe_key = !subscribe_key; illegal_clauses }
            else Http {
              body = !body;
              body_wire_type = !body_wire; body_decoder = !body_dec;
              body_via = !body_via_; response_wire_type = !resp_wire;
              response_encoder = !resp_enc;
              return_spec = !return_spec;
              has_explicit_return = !return_seen;
              has_clause_after_return = !clause_after_return;
            }
          in
          let ep = {
            name = Printf.sprintf "endpoint_%d" !ep_counter;
            method_; path; auth = !auth; captures = !captures; loc = ep_loc; kind;
          } in
          endpoints := ep :: !endpoints
    end;
    skip_layout s
  done;
  (match !ep_parse_err with
   | Some e -> Err e
   | None ->
     let* _ = expect s RBRACE in
     let loc = span loc0 (current_loc s) in
     return { name; endpoints = List.rev !endpoints; loc })

let rec abbreviated_binding_name default = function
  | PredApp { args = []; _ } -> default
  | PredApp { args; _ } -> List.hd (List.rev args)
  | PredAnd { left; right; _ } ->
    let right_name = abbreviated_binding_name default right in
    if right_name <> default then right_name
    else abbreviated_binding_name default left

(** Parse server block. *)
let parse_server_form s =
  let loc0 = current_loc s in
  let* name = expect_uident s in
  let* _ = expect s FOR in
  let* api_name = expect_uident s in
  let* _ = expect s LBRACE in
  skip_layout s;
  let bindings = ref [] in
  while peek s <> RBRACE && peek s <> EOF do
    skip_layout s;
    if peek s = RBRACE then ()
    else begin
      match expect_ident s with
      | Ok ep_name ->
        (match expect s EQ with
         | Ok () ->
           (match expect_ident s with
            | Ok handler_fn ->
              bindings := (ep_name, handler_fn) :: !bindings;
              skip_layout s
            | Err _ -> ())
         | Err _ -> ())
      | Err _ -> advance s
    end
  done;
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  return { name; api_name; bindings = List.rev !bindings; loc }

(** Parse workers block. *)
(** Parse a test body: sequence of let/expect/expectFail statements. *)
let parse_property_param s =
  let loc0 = current_loc s in
  let* binding = parse_binding s in
  let where_clause = ref None in
  let generator = ref None in
  let rec loop () =
    match peek s with
    | IDENT "where" ->
      advance s;
      let* e = parse_expr s in
      where_clause := Some e;
      loop ()
    | VIA | IDENT "via" ->
      advance s;
      (match expect_ident s with Ok n -> generator := Some n | Err _ -> ());
      return ()
    | _ -> return ()
  in
  let* _ = loop () in
  let loc = span loc0 (current_loc s) in
  return { binding; where_clause = !where_clause; generator = !generator; loc }

let rec parse_test_stmt_block_or_inline s =
  skip_newlines s;
  if peek s = INDENT then begin
    advance s;
    skip_newlines s;
    let* stmts = parse_test_body_until_with_skip s skip_newlines (fun tok -> tok = DEDENT || tok = EOF) in
    skip_newlines s;
    if peek s = DEDENT then advance s;
    return stmts
  end else
    parse_test_stmt_items s

and parse_test_expr_with_indented_args s =
  with_test_multiline_request_continuations s parse_expr

and parse_test_expect_left s =
  (* Use parse_additive so that `expect a ++ b == c` and `expect x + y == z`
     work without parentheses around the left operand.  parse_comparison is
     deliberately excluded here: the expect statement owns the comparison
     operator (`==` / `!=` / `<` etc.) at the statement level. *)
  with_test_multiline_request_continuations s parse_additive

and parse_test_stmt_items s =
  let loc0 = current_loc s in
  match peek s with
  | LET ->
    advance s;
    (* Check for proof destructuring: let (x ::: p) = ... or let (_ ::: p && q) = ... *)
    if peek s = LPAREN then begin
      advance s;
      let binding_name = match peek s with
        | UNDERSCORE -> advance s; "_"
        | IDENT n -> advance s; n
        | _ -> "_"
      in
      if peek s = PROOF_ANNOT then begin
        advance s;
        (* Collect all non-underscore IDENT tokens as proof names *)
        let all_names = ref [] in
        while peek s <> RPAREN && peek s <> EOF do
          (match peek s with
           | IDENT p when p <> "_" -> all_names := p :: !all_names
           | _ -> ());
          advance s
        done;
        if peek s = RPAREN then advance s;
        let proof_names = List.rev !all_names in
        (match expect s EQ with
         | Ok () ->
           (match parse_test_expr_with_indented_args s with
            | Ok v ->
              return [TsLetProof {
                value_name = binding_name;
                proof_names;
                value = v;
                loc = span loc0 (current_loc s);
              }]
            | Err _ -> return [])
         | Err _ -> return [])
      end else begin
        (* Not a proof pattern — skip to ) and fall through *)
        while peek s <> RPAREN && peek s <> EOF do advance s done;
        if peek s = RPAREN then advance s;
        (match expect s EQ with
         | Ok () ->
           (match parse_test_expr_with_indented_args s with
            | Ok v -> return [TsLet { name = binding_name; declared_type = None; value = v; declared_proof = None; loc = span loc0 (current_loc s) }]
            | Err _ -> return [])
         | Err _ -> return [])
      end
    end else
    let name_result = match peek s with
      | UNDERSCORE -> advance s; Ok "_"
      | _ -> expect_ident s
    in
    (match name_result with
     | Ok name ->
       let declared_type_ref = ref None in
       let declared_proof_ref = ref None in
       if peek s = COLON then begin
         advance s;
         (match parse_type_expr s with
          | Ok declared_type -> declared_type_ref := Some declared_type
          | Err _ -> ());
         if peek s = PROOF_ANNOT then begin
           advance s;
           (match parse_proof_expr s with
            | Ok proof -> declared_proof_ref := Some proof
            | Err _ -> ());
         end
       end;
       (match expect s EQ with
        | Ok () ->
           (match parse_test_expr_with_indented_args s with
           | Ok v ->
             let v' = v in (* TypeName { } required explicitly *)
             return [TsLet {
               name;
               declared_type = !declared_type_ref;
               value = v';
               declared_proof = !declared_proof_ref;
               loc = span loc0 (current_loc s);
             }]
           | Err _ -> return [])
        | Err _ -> return [])
     | Err _ -> return [])
  | EXPECT | IDENT "expect" ->
    advance s;
    (match parse_test_expect_left s with
     | Ok left ->
       let stmt =
         match peek s with
         | EQ_EQ ->
           advance s;
           (match parse_expr s with
            | Ok right -> TsExpect { left; right = Some right; loc = span loc0 (current_loc s) }
            | Err _ -> TsExpect { left; right = None; loc = span loc0 (current_loc s) })
         | (NEQ | LT | LE | GT | GE) as cmp_tok ->
           advance s;
           (match parse_expr s with
            | Ok right ->
              let op = match cmp_tok with
                | NEQ -> BNeq | LT -> BLt | LE -> BLe | GT -> BGt | GE -> BGe
                | _ -> failwith "unreachable comparator"
              in
              let cmp = EBinop { op; left; right; loc = span (expr_loc left) (expr_loc right) } in
              TsExpect { left = cmp; right = None; loc = span loc0 (current_loc s) }
            | Err _ -> TsExpect { left; right = None; loc = span loc0 (current_loc s) })
         | _ -> TsExpect { left; right = None; loc = span loc0 (current_loc s) }
       in
       return [stmt]
     | Err _ -> return [])
  | EXPECT_FAIL | IDENT "expectFail" ->
    advance s;
    (match parse_atom s with
     | Ok fn ->
       let args = ref [] in
       let continue_ = ref true in
       while !continue_ do
         match peek s with
         | NEWLINE | DEDENT | EOF | RBRACE | ELSE -> continue_ := false
         | _ ->
           (match parse_atom s with
            | Ok a -> args := a :: !args
            | Err _ -> continue_ := false)
       done;
       let full_arg = match List.rev !args with
         | [] -> EList { elems = []; loc = current_loc s }
         | first :: rest ->
           List.fold_left (fun acc a ->
             let l = current_loc s in
             EApp { fn = acc; arg = a; loc = l }
           ) first rest
       in
       return [TsExpectFail { fn; arg = full_arg; loc = span loc0 (current_loc s) }]
     | Err _ -> return [])
  | EXPECT_HAS_PROOF | IDENT "expectHasProof" ->
    advance s;
    (match parse_atom s with
     | Ok fn ->
       (match parse_atom s with
        | Ok arg ->
          let proof_name = match peek s with
            | UIDENT n -> advance s; n
            | IDENT n -> advance s; n
            | _ -> "Unknown"
          in
          return [TsExpectHasProof { fn; arg; proof_name; loc = span loc0 (current_loc s) }]
        | Err _ -> return [])
     | Err _ -> return [])
  | PROPERTY ->
    advance s;
    (match expect_string s with
     | Ok description ->
       (match parse_parenthesized_list parse_property_param s with
        | Ok params ->
          (match expect s LBRACE with
           | Ok () ->
             skip_layout s;
             (match parse_expr s with
              | Ok body ->
                skip_layout s;
                (match expect s RBRACE with
                 | Ok () ->
                   let loc = span loc0 (current_loc s) in
                   return [TsProperty { description; params; body; loc }]
                 | Err _ -> return [])
              | Err _ -> return [])
           | Err _ -> return [])
        | Err _ -> return [])
     | Err _ -> return [])
  | IF | IDENT "if" ->
    advance s;
    let* cond = parse_logic s in
    skip_newlines s;
    let* _ =
      match peek s with
      | THEN | IDENT "then" -> advance s; return ()
      | _ -> expect s THEN
    in
    let* then_stmts = parse_test_stmt_block_or_inline s in
    skip_newlines s;
    let* _ =
      match peek s with
      | ELSE | IDENT "else" -> advance s; return ()
      | _ -> expect s ELSE
    in
    let* else_stmts = parse_test_stmt_block_or_inline s in
    let loc = span loc0 (current_loc s) in
    return [TsIf { cond; then_stmts; else_stmts; loc }]
  | CASE | IDENT "case" ->
    advance s;
    (match parse_app s with
     | Ok scrut ->
       (match expect s OF with
        | Ok () ->
          skip_newlines s;
          (match expect s INDENT with
           | Ok () ->
             let arms = ref [] in
             let continue_ = ref true in
             while !continue_ && peek s <> DEDENT && peek s <> EOF do
               skip_newlines s;
               if peek s = DEDENT || peek s = EOF then continue_ := false
               else begin
                 let arm_loc0 = current_loc s in
                 match parse_pattern s with
                 | Ok pat ->
                   let guard = if (match peek s with IDENT "where" -> true | _ -> false) then begin
                     advance s;
                     match parse_logic s with Ok g -> Some g | Err _ -> None
                   end else None in
                   (match expect s ARROW with
                    | Ok () ->
                       (* Skip newline between -> and the arm body (before INDENT) *)
                       (match peek s with NEWLINE -> advance s | _ -> ());
                      let body = match peek s with
                        | LBRACE ->
                          advance s; skip_layout s;
                          let stmts = match parse_test_body_until_with_skip s skip_layout
                                              (fun tok -> tok = RBRACE || tok = EOF) with
                            | Ok ss -> ss | Err _ -> []
                          in
                          skip_layout s;
                          if peek s = RBRACE then advance s;
                          stmts
                        | INDENT ->
                          advance s;
                          let stmts = match parse_test_body_until_with_skip s skip_layout
                                              (fun tok -> tok = DEDENT || tok = EOF) with
                            | Ok ss -> ss | Err _ -> []
                          in
                          if peek s = DEDENT then advance s;
                          stmts
                        | _ ->
                          (* single-statement arm on same line *)
                          (match parse_test_stmt_items s with
                           | Ok ss -> ss | Err _ -> [])
                      in
                      let arm_loc = span arm_loc0 (current_loc s) in
                      arms := { Ast.ts_pattern = pat; ts_guard = guard; ts_body = body; ts_loc = arm_loc } :: !arms;
                      skip_newlines s
                    | Err _ -> continue_ := false)
                 | Err _ -> continue_ := false
               end
             done;
             if peek s = DEDENT then advance s;
             let loc = span loc0 (current_loc s) in
             return [TsCase { scrut; arms = List.rev !arms; loc }]
           | Err _ -> return [])
        | Err _ -> return [])
     | Err _ -> return [])
  | IDENT "with" when peek2 s = DATABASE || (match peek2 s with IDENT _ -> true | _ -> false) ->
    advance s;
    while peek s <> LBRACE && peek s <> EOF && peek s <> NEWLINE do advance s done;
    if peek s = LBRACE then begin
      advance s; skip_layout s;
      let* nested = parse_test_body_until_with_skip s skip_layout (fun tok -> tok = RBRACE || tok = EOF) in
      skip_layout s;
      if peek s = RBRACE then advance s;
      return nested
    end else
      return []
  (* SQL write statements (`update`/`delete`) carry indented `where … set … = …`
     continuation clauses.  The test-body expression parser runs with
     `allow_test_multiline_request_continuations` on (for api-test request
     modifiers like `.cookie`/`.headers`), which mis-consumes those indented SQL
     clauses and chokes on the `=`.  Parse these statements the same way function
     bodies do instead: head with the flag OFF, then the indented continuation
     block as a `parse_stmt_seq` (mirrors parse_stmt_seq's INDENT arm). *)
  | IDENT ("update" | "delete") ->
    let saved = s.allow_test_multiline_request_continuations in
    s.allow_test_multiline_request_continuations <- false;
    let result =
      match parse_expr s with
      | Ok e ->
        skip_newlines s;
        (match peek s with
         | INDENT ->
           advance s;
           (match parse_stmt_seq s with
            | Ok body ->
              skip_newlines s;
              if peek s = DEDENT then advance s;
              let combined = ELet { name = "_"; declared_type = None;
                                    declared_proof = None; value = e; body;
                                    loc = expr_loc e } in
              return [TsExpr { e = combined; loc = expr_loc combined }]
            | Err _ -> return [TsExpr { e; loc = expr_loc e }])
         | _ -> return [TsExpr { e; loc = expr_loc e }])
      | Err _ -> return []
    in
    s.allow_test_multiline_request_continuations <- saved;
    result
  | _ ->
    (match parse_test_expr_with_indented_args s with
     | Ok e -> return [TsExpr { e; loc = expr_loc e }]
     | Err _ -> return [])

and parse_test_body_until_with_skip s skip_ws is_stop =
  let stmts = ref [] in
  let continue_ = ref true in
  while !continue_ && not (is_stop (peek s)) do
    skip_ws s;
    if is_stop (peek s) || peek s = EOF then continue_ := false
    else begin
      let pos_before = s.pos in
      (match parse_test_stmt_items s with
       | Ok (_ :: _ as items) -> stmts := List.rev_append items !stmts
       | Ok [] ->
         (* Nothing was parsed and no tokens were consumed — stop to
            avoid an infinite loop on an unrecognised token. *)
         if s.pos = pos_before then continue_ := false
       | Err _ -> continue_ := false);
      skip_ws s
    end
  done;
  return (List.rev !stmts)

and parse_test_body s =
  parse_test_body_until_with_skip s skip_layout (fun tok -> tok = RBRACE || tok = EOF)

let parse_test_form s =
  let loc0 = current_loc s in
  let* desc = expect_string s in
  (* Optional test-header clauses, accepted in any order until the body `{`:
       with N runs / runs N   — property-test repetition count
       with database X        — bind a named database for the test body (else in-memory)
       requires [..]          — capabilities the test runs with *)
  let runs = ref None in
  let test_db = ref None in
  let caps = ref [] in
  let continue_header = ref true in
  while !continue_header do
    begin match peek s with
    | IDENT "with" when peek2 s = DATABASE ->
      advance s; advance s;  (* `with database` *)
      (match expect_uident s with Ok db -> test_db := Some db | Err _ -> ())
    | IDENT "with" ->
      advance s;  (* `with N runs` *)
      (match expect_int s with Ok n -> runs := Some n | Err _ -> ());
      if peek s = IDENT "runs" then advance s
    | IDENT "runs" ->
      advance s;  (* `runs N` *)
      (match expect_int s with Ok n -> runs := Some n | Err _ -> ())
    | REQUIRES ->
      (match parse_requires s with
       | Ok cs -> caps := !caps @ cs
       | Err _ -> continue_header := false)
    | _ -> continue_header := false
    end
  done;
  let* _ = expect s LBRACE in
  skip_layout s;
  let* stmts = parse_test_body s in
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  return { description = desc; stmts; runs = !runs; capabilities = !caps;
           database = !test_db; loc }

let parse_api_test_form s =
  let loc0 = current_loc s in
  let* desc = expect_string s in
  let* _ = expect s FOR in
  let* server_name = expect_uident s in
  (* Optional requires [...] before { *)
  let* caps = parse_requires s in
  let* _ = expect s LBRACE in
  skip_layout s;
  (* optional seed block *)
  let seed_stmts = ref [] in
  (if peek s = SEED then begin
    advance s;
    if peek s = LBRACE then advance s;
    skip_layout s;
    while peek s <> RBRACE && peek s <> EOF do
      skip_layout s;
      if peek s = RBRACE then ()
      else begin
        match parse_expr s with
        | Ok e -> seed_stmts := e :: !seed_stmts
        | Err _ -> advance s
      end;
      skip_layout s
    done;
    if peek s = RBRACE then advance s
  end);
  skip_layout s;
  let* stmts = parse_test_body s in
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  return { description = desc; server_name; seed_stmts = List.rev !seed_stmts;
           stmts; capabilities = caps; loc }

(** Parse a load-test block.  Syntax:
    load-test "name" for Server
      rate 200rps
      duration 30s
      [baseline "label"]
      requires [...] { seed? request assert* } *)
let parse_load_test_form s =
  let loc0 = current_loc s in
  let* desc = expect_string s in
  let* _ = expect s FOR in
  let* server_name = expect_uident s in
  skip_layout s;
  (* rate Nrps *)
  let rate = ref 0 in
  let duration = ref 0 in
  let baseline = ref None in
  (* Parse header keywords before { *)
  let rec parse_header () =
    skip_layout s;
    match peek s with
    | IDENT "rate" ->
      advance s;
      (match peek s with
       | INT n ->
         advance s;
         (match peek s with
          | IDENT "rps" -> advance s; rate := n
          | _ -> rate := n);
         parse_header ()
       | _ -> err s "expected integer after 'rate'")
    | IDENT "duration" ->
      advance s;
      (match peek s with
       | INT n ->
         advance s;
         (match peek s with
          | IDENT "s" -> advance s; duration := n
          | _ -> duration := n);
         parse_header ()
       | _ -> err s "expected integer after 'duration'")
    | IDENT "baseline" ->
      advance s;
      (match peek s with
       | STRING bl -> advance s; baseline := Some bl; parse_header ()
       | _ -> err s "expected string after 'baseline'")
    | _ -> Ok ()
  in
  let* () = parse_header () in
  let* caps = parse_requires s in
  let* _ = expect s LBRACE in
  skip_layout s;
  (* optional seed block *)
  let seed_stmts = ref [] in
  (if peek s = SEED then begin
    advance s;
    if peek s = LBRACE then advance s;
    skip_layout s;
    while peek s <> RBRACE && peek s <> EOF do
      skip_layout s;
      if peek s = RBRACE then ()
      else begin
        match parse_expr s with
        | Ok e -> seed_stmts := e :: !seed_stmts
        | Err _ -> advance s
      end;
      skip_layout s
    done;
    if peek s = RBRACE then advance s
  end);
  skip_layout s;
  (* Parse request statements (test stmts until assert or }) *)
  let* request_stmts = parse_test_body_until_with_skip s skip_layout
    (fun tok -> tok = RBRACE || tok = EOF || tok = IDENT "assert") in
  skip_layout s;
  (* Parse assert statements *)
  let assertions = ref [] in
  let parse_metric () =
    match peek s with
    | IDENT "p50" -> advance s; Ok LtP50
    | IDENT "p95" -> advance s; Ok LtP95
    | IDENT "p99" ->
      advance s;
      (match peek s with
       | DOT ->
         advance s;
         (match peek s with
          | INT 9 -> advance s; Ok LtP999
          | _ -> Ok LtP99)
       | _ -> Ok LtP99)
    | IDENT "errorRate" -> advance s; Ok LtErrorRate
    | IDENT "throughput" -> advance s; Ok LtThroughput
    | t -> err s (Printf.sprintf "expected metric (p50, p95, p99, p99.9, errorRate, throughput), got %s" (tok_to_string t))
  in
  let parse_cmp_op () =
    match peek s with
    | LT -> advance s; Ok BLt
    | LE -> advance s; Ok BLe
    | GT -> advance s; Ok BGt
    | GE -> advance s; Ok BGe
    | t -> err s (Printf.sprintf "expected comparison operator, got %s" (tok_to_string t))
  in
  let parse_value_with_unit () =
    match peek s with
    | INT n ->
      advance s;
      let v = float_of_int n in
      (match peek s with
       | IDENT "ms"  -> advance s; Ok (v, "ms")
       | IDENT "rps" -> advance s; Ok (v, "rps")
       | _ -> Ok (v, ""))
    | FLOAT f ->
      advance s;
      (match peek s with
       | IDENT "ms"  -> advance s; Ok (f, "ms")
       | IDENT "rps" -> advance s; Ok (f, "rps")
       | _ -> Ok (f, ""))
    | t -> err s (Printf.sprintf "expected number, got %s" (tok_to_string t))
  in
  while peek s = IDENT "assert" do
    advance s;
    skip_layout s;
    (match peek s with
     | IDENT "regressionVsBaseline" ->
       advance s;
       (match parse_metric () with
        | Ok metric ->
          (match parse_cmp_op () with
           | Ok _ ->
             (match parse_value_with_unit () with
              | Ok (ratio, _) ->
                assertions := LtAssertRegression { metric; ratio } :: !assertions
              | Err _ -> ())
           | Err _ -> ())
        | Err _ -> ())
     | _ ->
       (match parse_metric () with
        | Ok metric ->
          (match parse_cmp_op () with
           | Ok op ->
             (match parse_value_with_unit () with
              | Ok (value, unit) ->
                assertions := LtAssertMetric { metric; op; value; unit } :: !assertions
              | Err _ -> ())
           | Err _ -> ())
        | Err _ -> ()));
    skip_layout s
  done;
  let* _ = expect s RBRACE in
  let loc = span loc0 (current_loc s) in
  return { description = desc; server_name; rate = !rate; duration = !duration;
           baseline = !baseline; seed_stmts = List.rev !seed_stmts; request_stmts;
           assertions = List.rev !assertions; capabilities = caps; loc }

(** Parse a const declaration. *)
let parse_const_form s =
  let loc0 = current_loc s in
  let* name = expect_ident s in
  let* _ = expect s EQ in
  let* value = parse_expr s in
  let loc = span loc0 (current_loc s) in
  return { name; value; loc }

(* ── Module-level ─────────────────────────────────────────────────────────── *)

(** Parse the module header: [module Name exposing [a, b, C(..)]]. *)
let parse_module_header s =
  skip_layout s;
  (* Handle #lang tesl *)
  if peek s = HASH_LANG then begin
    advance s;
    if peek s = TESL then advance s
  end;
  skip_layout s;
  let* _ = expect s MODULE in
  let* name = expect_uident s in
  let* _ = expect s EXPOSING in
  let* items = parse_bracketed_list (fun s ->
    match token_as_ident (peek s) with
    | Some n ->
      advance s;
      if peek s = LPAREN then begin
        advance s;
        if peek s = DOTDOT then advance s;
        if peek s = RPAREN then advance s;
        return (ExportAdt n)
      end else
        return (ExportName n)
    | None ->
      err s (Printf.sprintf "expected export name, got %s" (tok_to_string (peek s)))
  ) s in
  skip_layout s;
  return (name, items)

(** Parse import declarations. *)
let rec parse_imports s acc =
  skip_layout s;
  if peek s = IMPORT then begin
    let import_kw_loc = current_loc s in
    advance s;
    (* Module name may be dotted: Tesl.Dict, Tesl.Maybe, etc. *)
    let* module_name = parse_module_path s in
    let* names =
      if peek s = EXPOSING then begin
        advance s;
        (* Wildcard import `exposing *` is not supported *)
        if peek s = STAR then
          (advance s;
           err s "wildcard imports are not supported; list explicit names or use Module.function qualified access")
        else
        let* items = parse_bracketed_list (fun s ->
          (* Import names may be qualified: Dict.lookup, String.length, etc.
             Or ADT exports with constructors: Maybe(..) *)
          (* Import names can be keywords used as identifiers: PosixMillis, telemetry, etc. *)
          match token_as_ident (peek s) with
          | Some n ->
            advance s;
            (* Check for qualified name: Module.name *)
            let name = ref n in
            if peek s = DOT then begin
              advance s;
              (match token_as_ident (peek s) with
               | Some part -> advance s; name := !name ^ "." ^ part
               | None -> ())
            end;
            if peek s = LPAREN then begin
              advance s;
              if peek s = DOTDOT then advance s;
              if peek s = RPAREN then advance s;
              name := !name ^ "(..)"
            end;
            return !name
          | None ->
            err s (Printf.sprintf "expected import name, got %s" (tok_to_string (peek s)))
        ) s in
        return (ImportExposing items)
      end else
        return ImportAll
    in
    (* Span the whole statement: `import` keyword through the last token of the
       exposing list (or module path) — multi-line exposing lists included.
       This is what W050 positions and the LSP import quickfix edits anchor on. *)
    let stop_loc = last_consumed_loc s in
    let loc = make_loc s.filename
        import_kw_loc.start.line import_kw_loc.start.col
        stop_loc.stop.line stop_loc.stop.col in
    let decl = { module_name; names; loc } in
    skip_layout s;
    parse_imports s (decl :: acc)
  end else
    return (List.rev acc)

and parse_module_path s =
  (* Parse dotted module name like Tesl.Dict or just Foo *)
  let* first = expect_uident s in
  let parts = ref [first] in
  while peek s = DOT && (match peek2 s with UIDENT _ -> true | _ -> false) do
    advance s;
    (match peek s with
     | UIDENT n -> advance s; parts := n :: !parts
     | _ -> ())
  done;
  return (String.concat "." (List.rev !parts))

(** Parse all top-level declarations. *)
let rec parse_top_decls s acc =
  skip_layout s;
  if peek s = EOF then return (List.rev acc)
  else begin
    let* decl = parse_top_decl s in
    skip_layout s;
    parse_top_decls s (decl :: acc)
  end

and parse_top_decl s =
  skip_layout s;
  let loc0 = current_loc s in
  match peek s with
  | FN ->
    advance s;
    let* fd = parse_fn_decl FnKind s in
    return (DFunc fd)
  | HANDLER ->
    advance s;
    let* fd = parse_fn_decl HandlerKind s in
    return (DFunc fd)
  | CHECK ->
    advance s;
    let* fd = parse_fn_decl CheckKind s in
    return (DFunc fd)
  | AUTH ->
    advance s;
    let* fd = parse_fn_decl AuthKind s in
    return (DFunc fd)
  | ESTABLISH ->
    advance s;
    let* fd = parse_fn_decl EstablishKind s in
    return (DFunc fd)
  | WORKER ->
    advance s;
    let* fd = parse_fn_decl WorkerKind s in
    return (DFunc fd)
  | DEAD_WORKER ->
    advance s;
    let* fd = parse_fn_decl DeadWorkerKind s in
    return (DFunc fd)
  | MAIN ->
    let main_loc = current_loc s in
    advance s;
    (* App-style entry point: `main() -> App requires [...] = App { … }`.
       `main` is already consumed, so parse the rest with the name pre-set. *)
    let* fd = parse_fn_decl_named MainKind "main" main_loc s in
    return (DFunc fd)
  | RECORD ->
    advance s;
    let* r = parse_record_form s in
    return (DRecord r)
  | ENTITY ->
    advance s;
    let* e = parse_entity_form s in
    return (DEntity e)
  | TYPE ->
    advance s;
    let* t = parse_type_form s in
    return (DType t)
  | CODEC ->
    advance s;
    let* name = expect_uident s in
    let* cf = parse_codec_form s name name in
    return (DCodec cf)
  | DATABASE ->
    advance s;
    let* d = parse_database_form s in
    return (DDatabase d)
  | CAPABILITY ->
    advance s;
    let* c = parse_capability_form s in
    return (DCapability c)
  | FACT ->
    advance s;
    let* f = parse_fact_form s in
    return (DFact f)
  | CONST ->
    err s "`const` is not part of the Tesl language. Top-level immutability is the default; use `let` bindings inside functions or define a `fn` instead."
  | CACHE ->
    advance s;
    let* c = parse_cache_form s in
    return (DCache c)
  | IDENT "agent" when (match peek2 s with UIDENT _ -> true | _ -> false) ->
    (* `agent` is a CONTEXTUAL keyword: a block-starter only when a top-level
       declaration begins `agent <Name>`.  Everywhere else it is an ordinary
       identifier, so the AI library can bind `let agent = …` freely. *)
    advance s;
    let* a = parse_agent_form s in
    return (DAgent a)
  | EMAIL ->
    advance s;
    let* e = parse_email_form s in
    return (DEmail e)
  | QUEUE ->
    advance s;
    let* q = parse_queue_form s in
    return (DQueue q)
  | CHANNEL ->
    advance s;
    let* c = parse_channel_form s in
    return (DChannel c)
  (* A top-level capture declaration is spelled `capturer` (the `capture` keyword
     is reserved for the API-endpoint clause, avoiding the overloaded term).
     `capture` is still accepted here for back-compat. *)
  | CAPTURE | CAPTURER ->
    advance s;
    let* c = parse_capture_form s in
    return (DCapture c)
  | API ->
    advance s;
    let* a = parse_api_form s in
    return (DApi a)
  | SERVER ->
    advance s;
    let* sv = parse_server_form s in
    return (DServer sv)
  | TEST ->
    advance s;
    let* t = parse_test_form s in
    return (DTest t)
  | API_TEST ->
    advance s;
    let* t = parse_api_test_form s in
    return (DApiTest t)
  | LOAD_TEST ->
    advance s;
    let* t = parse_load_test_form s in
    return (DLoadTest t)
  | PROPERTY ->
    advance s;
    (* Parse like a test for now *)
    let* t = parse_test_form s in
    return (DTest t)
  | IDENT _ when peek2 s = EQ ->
    (* Bare name = value — treat as const declaration *)
    let* c = parse_const_form s in
    return (DConst c)
  | IMPORT ->
    err s "import declarations must appear before all type and function definitions; move this import to the top of the file, after the module header"
  | t ->
    err s (Printf.sprintf "unexpected token at top level: %s (pos %d)" (tok_to_string t) s.pos)
    |> (function
        | Err e ->
          (* Recovery: skip until next top-level keyword or EOF *)
          let rec skip_to_top () =
            match peek s with
            | FN | HANDLER | CHECK | AUTH | RECORD | ENTITY | TYPE | CODEC
            | DATABASE | CAPABILITY | FACT | CONST | QUEUE | CHANNEL
            | CAPTURE | CAPTURER | API | SERVER | TEST | API_TEST | LOAD_TEST | CACHE | EMAIL
            | PROPERTY | MAIN | WORKER | DEAD_WORKER | ESTABLISH | EOF -> ()
            | _ -> advance s; skip_to_top ()
          in
          skip_to_top ();
          (* Return a dummy node to allow parsing to continue *)
          Err e
        | ok -> ok)

  |> (fun r ->
      let _ = loc0 in r)

(* ── Main entry point ────────────────────────────────────────────────────── *)

let parse_expr_snippet filename source =
  let tokens = Lexer.tokenize filename source in
  let s = make_stream filename tokens in
  skip_layout s;
  parse_expr s

let extract_doctest_decls filename source =
  let starts_with prefix s =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix
  in
  let trim_prefix prefix s =
    let plen = String.length prefix in
    String.trim (String.sub s plen (String.length s - plen))
  in
  let fn_name_of_line line =
    let trimmed = String.trim line in
    if starts_with "fn " trimmed then
      let rest = String.sub trimmed 3 (String.length trimmed - 3) in
      let rec take i =
        if i >= String.length rest then i
        else match rest.[i] with
          | '(' | ' ' | '	' -> i
          | _ -> take (i + 1)
      in
      let len = take 0 in
      if len = 0 then None else Some (String.sub rest 0 len)
    else
      None
  in
  let lines = String.split_on_char '
' source in
  let pending = ref [] in
  let current_expr = ref None in
  let decls = ref [] in
  let flush fn_name =
    let pairs = List.rev !pending in
    pending := [];
    current_expr := None;
    let stmts = List.filter_map (fun (expr_text, expected_text) ->
      match parse_expr_snippet filename expr_text, parse_expr_snippet filename expected_text with
      | Ok left, Ok right -> Some (TsExpect { left; right = Some right; loc = expr_loc left })
      | _ -> None
    ) pairs in
    if stmts <> [] then
      decls := DTest {
        description = "doctest: " ^ fn_name;
        stmts;
        runs = None;
        capabilities = [];
        database = None;
        loc = dummy_loc filename;
      } :: !decls
  in
  List.iter (fun line ->
    let trimmed = String.trim line in
    if starts_with "#>" trimmed then
      current_expr := Some (trim_prefix "#>" trimmed)
    else if starts_with "#=" trimmed then
      match !current_expr with
      | Some expr_text ->
        pending := (expr_text, trim_prefix "#=" trimmed) :: !pending;
        current_expr := None
      | None -> ()
    else
      match fn_name_of_line line with
      | Some fn_name when !pending <> [] -> flush fn_name
      | _ -> ()
  ) lines;
  List.rev !decls

(* Harvest the contiguous leading `#` comment block directly above each top-level
   `fn`/`handler` and attach it as that declaration's [doc] — the description used
   when the function is exposed as an agent/MCP tool.  A blank line (or any
   non-comment) between the comment and the declaration detaches it, and doctest
   marker lines (`#>` / `#=`) are not prose, so they act as a boundary. *)
let attach_doc_comments source decls =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let n = Array.length lines in
  let trimmed i = if i >= 0 && i < n then String.trim lines.(i) else "" in
  let body i =
    let t = trimmed i in
    if String.length t >= 1 && t.[0] = '#'
    then String.trim (String.sub t 1 (String.length t - 1)) else "" in
  let is_doc_comment i =
    let t = trimmed i in
    String.length t > 0 && t.[0] = '#'
    && (let b = body i in not (String.length b > 0 && (b.[0] = '>' || b.[0] = '=')))
    && body i <> "lang tesl" in
  (* A declaration's reported [loc.start.line] anchors to the line just above the
     `fn`/`handler` keyword, so the contiguous comment block ends at index
     [start_line - 1] (0-based). *)
  let doc_above start_line =
    let rec gather i acc =
      if i >= 0 && is_doc_comment i then gather (i - 1) (body i :: acc) else acc in
    match gather (start_line - 1) [] |> List.filter (fun s -> s <> "") with
    | [] -> None
    | parts -> Some (String.concat " " parts)
  in
  List.map (function
    | DFunc (fd : func_decl) when fd.doc = None ->
      DFunc { fd with doc = doc_above fd.loc.start.line }
    | d -> d) decls

let rec parse_module filename source =
  let tokens = Lexer.tokenize filename source in
  let s = make_stream filename tokens in

  skip_layout s;

  (* Handle #lang tesl header *)
  if peek s = HASH_LANG then begin
    advance s;
    if peek s = TESL then advance s
  end;

  skip_layout s;

  let* (module_name, exports) = parse_module_header_body s in
  let* imports = parse_imports s [] in
  let* decls = parse_top_decls s [] in
  let doctest_decls = extract_doctest_decls filename source in
  let decls = attach_doc_comments source decls in

  return { module_name; exports; imports; decls = decls @ doctest_decls; source_file = filename }

and parse_module_header_body s =
  let* _ = (match peek s with
    | MODULE  -> advance s; Ok ()
    | t -> err s (Printf.sprintf "expected `module` keyword, got %s" (tok_to_string t))) in
  let* name = expect_uident s in
  let* _ = expect s EXPOSING in
  let* items = parse_bracketed_list (fun s ->
    match token_as_ident (peek s) with
    | Some n ->
      advance s;
      if peek s = LPAREN then begin
        advance s;
        if peek s = DOTDOT then advance s;
        if peek s = RPAREN then advance s;
        return (ExportAdt n)
      end else
        return (ExportName n)
    | None ->
      err s (Printf.sprintf "expected export name, got %s" (tok_to_string (peek s)))
  ) s in
  skip_layout s;
  return (name, items)

(* ── Resilient (recovering) module parse ──────────────────────────────────── *)

(** True for tokens that begin a top-level declaration (the same set used by
    [parse_top_decl]'s recovery [skip_to_top]).  Recovery resynchronises to
    one of these so the next declaration can be attempted. *)
let starts_top_decl = function
  | FN | HANDLER | CHECK | AUTH | RECORD | ENTITY | TYPE | CODEC
  | DATABASE | CAPABILITY | FACT | CONST | QUEUE | CHANNEL
  | CAPTURE | CAPTURER | API | SERVER | TEST | API_TEST | LOAD_TEST | CACHE | EMAIL
  | PROPERTY | MAIN | WORKER | DEAD_WORKER | ESTABLISH -> true
  | _ -> false

(** Best-effort top-level declaration loop: collects every declaration that
    parses, and on a parse error resynchronises to the next top-level keyword
    (or EOF) and keeps going, instead of aborting the whole module.  Always
    makes forward progress so it cannot loop. *)
let rec parse_top_decls_recover s acc =
  skip_layout s;
  if peek s = EOF then List.rev acc
  else begin
    let before = s.pos in
    match parse_top_decl s with
    | Ok decl ->
      skip_layout s;
      (* Defensive: if the sub-parser made no progress, force one token of
         advance so we cannot spin forever. *)
      if s.pos = before then advance s;
      parse_top_decls_recover s (decl :: acc)
    | Err _ ->
      (* A mid-declaration error may leave the stream anywhere; resynchronise
         to the next top-level keyword.  [parse_top_decl]'s own recovery only
         fires for the unknown-leading-token case, so we always skip here. *)
      if s.pos = before then advance s;
      while peek s <> EOF && not (starts_top_decl (peek s)) do
        advance s
      done;
      parse_top_decls_recover s acc
  end

(** Like [parse_module] but degrades to a partial module on parse errors: the
    successfully-parsed declarations are returned even when later declarations
    are syntactically broken.  Used by the editor/LSP semantic snapshot so a
    mid-edit buffer still yields useful structure.  The header must parse for a
    result to be produced ([None] otherwise). *)
let parse_module_recover filename source : Ast.module_form option =
  let tokens = Lexer.tokenize filename source in
  let s = make_stream filename tokens in
  skip_layout s;
  if peek s = HASH_LANG then begin
    advance s;
    if peek s = TESL then advance s
  end;
  skip_layout s;
  match parse_module_header_body s with
  | Err _ -> None
  | Ok (module_name, exports) ->
    (* Imports are best-effort: if they fail, recover into declaration parsing
       so a broken import line does not blank the whole snapshot. *)
    let imports =
      match parse_imports s [] with
      | Ok imps -> imps
      | Err _ -> []
    in
    let decls = parse_top_decls_recover s [] in
    let doctest_decls = extract_doctest_decls filename source in
    Some { module_name; exports; imports;
           decls = decls @ doctest_decls; source_file = filename }
