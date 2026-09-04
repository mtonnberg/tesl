(** Compile-time validation of `Tesl.Regex` pattern literals.

    Tesl's regex surface is deliberately *not* "whatever the host engine
    accepts".  A pattern is a piece of the program, so it is checked when the
    program is checked:

      1. {b Patterns are literals.}  Every `Regex.*` function takes its pattern
         as argument 1, and that argument MUST be a string literal written at
         the call site ([VREGEX002]).  There is no dynamic-pattern entry point
         anywhere in the surface, so a pattern can never come from request data
         — which is what makes rule 3 an actual guarantee rather than advice.
         The idiom is to name the *predicate* (`fn isSlug(s) = Regex.matches …`),
         not the pattern.

      2. {b Patterns are parsed and checked here.}  A malformed pattern, or one
         that uses a construct outside Tesl's subset of `pregexp`
         (lookaround, inline flags, lazy quantifiers, backreferences, …), is a
         compile error ([VREGEX001]) with the offset inside the pattern — not a
         runtime raise on the unlucky request.

      3. {b Exponential backtracking is rejected} ([VREGEX003]).  Racket's
         matcher backtracks, so an ambiguous quantified group is audit gap L6
         (resource exhaustion) with a two-line proof of concept.  The rules
         below reject every pattern whose repetition is not provably
         unambiguous.  (Polynomial ambiguity from *adjacent* quantifiers is
         partly caught here and otherwise bounded by the runtime deadline in
         `tesl/regex.rkt` — see roadmap/completed/string_regex.md.)

      4. {b Capture groups always participate} ([VREGEX004]).  A capturing group
         may not be quantified, may not sit inside a quantified group, and may
         not sit inside an alternation branch.  Consequently every capturing
         group of an accepted pattern captures a string on every successful
         match — which is exactly what makes `Regex.captures : … -> Maybe
         (List String)` total and honest, with no `Maybe` per group and no
         "" standing in for "did not participate".

    THE SUBSET (accepted syntax)

      literal chars, `.`
      character classes `[...]`, `[^...]` with `a-z` ranges
      escapes: `\d \D \w \W \s \S` (classes), `\b \B` (word boundaries),
               and `\` before any of  . * + ? ( ) [ ] {{ }} | ^ $ - /
      anchors `^` `$`
      groups `( … )` (capturing) and `(?: … )` (non-capturing)
      alternation `|`
      quantifiers `? * + {{n}} {{n,}} {{n,m}}`

    Deliberately NOT in the subset: backreferences (`\1`), lookaround
    (`(?= (?! (?<= (?<!`), inline flags (`(?i:`), lazy/possessive quantifiers
    (`*?`, `*+`), POSIX bracket classes (`[:alpha:]`), and the escapes
    `\n \t \r \\` (Tesl string literals already process those escapes — see
    LANGUAGE-SPEC.md §8.5 — so spelling them inside a pattern is ambiguous;
    use `\s` or a character class).

    All four codes are registered in {!Error_codes}; the diagnostics are
    produced by {!module_diagnostics} and rendered by [Compile]. *)

(* ── Character sets: sorted, disjoint, inclusive code-point ranges ────────── *)

type cset = (int * int) list

let uni_max = 0x10FFFF

let cs_norm (l : cset) : cset =
  let l = List.sort (fun (a, _) (b, _) -> compare a b) l in
  let rec merge = function
    | [] -> []
    | [ x ] -> [ x ]
    | (a1, b1) :: (a2, b2) :: rest ->
      if a2 <= b1 + 1 then merge ((a1, max b1 b2) :: rest)
      else (a1, b1) :: merge ((a2, b2) :: rest)
  in
  merge l

let cs_union (a : cset) (b : cset) : cset = cs_norm (a @ b)

let cs_complement (l : cset) : cset =
  let l = cs_norm l in
  let rec go prev = function
    | [] -> if prev <= uni_max then [ (prev, uni_max) ] else []
    | (a, b) :: rest ->
      let head = if prev <= a - 1 then [ (prev, a - 1) ] else [] in
      head @ go (b + 1) rest
  in
  go 0 l

let cs_intersects (a : cset) (b : cset) : bool =
  List.exists (fun (a1, b1) -> List.exists (fun (a2, b2) -> a1 <= b2 && a2 <= b1) b) a

let cs_char (c : char) : cset = [ (Char.code c, Char.code c) ]
let cs_code (n : int) : cset = [ (n, n) ]

let cs_digit = [ (Char.code '0', Char.code '9') ]

let cs_word =
  cs_norm
    [ (Char.code '0', Char.code '9');
      (Char.code 'A', Char.code 'Z');
      (Char.code 'a', Char.code 'z');
      (Char.code '_', Char.code '_') ]

let cs_space = cs_norm [ (9, 13); (32, 32) ]

(* `.` matches any character except a newline (pregexp's default). *)
let cs_dot = cs_complement (cs_code 10)

(* ── Pattern AST ──────────────────────────────────────────────────────────── *)

type quant = { qmin : int; qmax : int option (* None = unbounded *) }

type atom =
  | AChars of cset
      (** one character drawn from a set: a literal, `.`, `[…]`, `\d`, … *)
  | AAnchor  (** zero-width: `^`, `$`, `\b`, `\B` *)
  | AGroup of { capturing : bool; body : alt }

and piece = { patom : atom; pquant : quant option; poff : int }
and pseq = piece list
and alt = pseq list

(* ── Rejections ───────────────────────────────────────────────────────────── *)

type reject = { code : string; message : string; offset : int }

exception Rej of reject

let rej code offset message = raise (Rej { code; message; offset })
let bad off msg = rej "VREGEX001" off msg
let unsafe off msg = rej "VREGEX003" off msg
let capture_rule off msg = rej "VREGEX004" off msg

(* ── Limits ───────────────────────────────────────────────────────────────── *)

let max_pattern_length = 512
let max_capture_groups = 20
let max_repeat_bound = 1000

(* ── Parser ───────────────────────────────────────────────────────────────── *)

let is_meta = function
  | '|' | '(' | ')' | '[' | ']' | '{' | '}' | '.' | '*' | '+' | '?' | '^' | '$'
  | '\\' -> true
  | _ -> false

(** Escapes legal both inside and outside a character class that denote a set
    of characters.  Returns [None] for escapes that are not class-shaped. *)
let class_escape (c : char) : cset option =
  match c with
  | 'd' -> Some cs_digit
  | 'D' -> Some (cs_complement cs_digit)
  | 'w' -> Some cs_word
  | 'W' -> Some (cs_complement cs_word)
  | 's' -> Some cs_space
  | 'S' -> Some (cs_complement cs_space)
  | '.' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|' | '^' | '$'
  | '-' | '/' | '"' ->
    Some (cs_char c)
  | _ -> None

let escape_advice = function
  | 'n' | 't' | 'r' ->
    "`\\n`/`\\t`/`\\r` are not part of Tesl's regex subset — a Tesl string \
     literal already turns those into real characters (LANGUAGE-SPEC.md \
     §8.5), so the pattern would be ambiguous. Use `\\s` or a character class."
  | '\\' ->
    "a literal backslash is not part of Tesl's regex subset (Tesl string \
     literals process `\\\\` themselves, so the pattern would be ambiguous)."
  | c when c >= '0' && c <= '9' ->
    "backreferences are not part of Tesl's regex subset: matching one forces \
     unbounded backtracking. Repeat the character class instead."
  | 'A' | 'Z' | 'z' | 'p' | 'P' ->
    "this escape is not part of Tesl's regex subset. Use `^`/`$` for anchors \
     and an explicit character class for character categories."
  | _ ->
    "unknown escape. Tesl's regex subset allows `\\d \\D \\w \\W \\s \\S \\b \
     \\B` and a backslash before any of  . * + ? ( ) [ ] { } | ^ $ - /"

let parse_pattern (p : string) : alt =
  let n = String.length p in
  let i = ref 0 in
  let captures = ref 0 in
  let peek () = if !i < n then Some p.[!i] else None in

  let parse_int () =
    let start = !i in
    while !i < n && p.[!i] >= '0' && p.[!i] <= '9' do incr i done;
    if !i = start then None
    else
      let s = String.sub p start (!i - start) in
      (* Bounded by max_repeat_bound below; parse defensively regardless. *)
      match int_of_string_opt s with
      | Some v -> Some v
      | None -> bad start "repetition bound is too large"
  in

  (* `{` … `}` after an atom.  Called with [!i] on the `{`. *)
  let parse_brace_quant () : quant =
    let start = !i in
    incr i;
    let lo =
      match parse_int () with
      | Some v -> v
      | None ->
        bad start
          "`{` starts a repetition like `{2}` or `{2,5}`; write `\\{` for a \
           literal brace"
    in
    let q =
      match peek () with
      | Some '}' ->
        incr i;
        { qmin = lo; qmax = Some lo }
      | Some ',' ->
        incr i;
        (match peek () with
         | Some '}' ->
           incr i;
           { qmin = lo; qmax = None }
         | _ ->
           let hi =
             match parse_int () with
             | Some v -> v
             | None -> bad start "expected a repetition bound after `,`"
           in
           (match peek () with
            | Some '}' -> incr i
            | _ -> bad start "unterminated repetition — expected `}`");
           if hi < lo then
             bad start
               (Printf.sprintf "repetition `{%d,%d}` has its bounds reversed" lo
                  hi);
           { qmin = lo; qmax = Some hi })
      | _ -> bad start "unterminated repetition — expected `}` or `,`"
    in
    (match q with
     | { qmin; qmax = Some hi } when qmin > max_repeat_bound || hi > max_repeat_bound ->
       bad start
         (Printf.sprintf "repetition bound above the %d limit" max_repeat_bound)
     | { qmin; _ } when qmin > max_repeat_bound ->
       bad start
         (Printf.sprintf "repetition bound above the %d limit" max_repeat_bound)
     | _ -> ());
    q
  in

  (* A character class `[ … ]`.  Called with [!i] on the `[`. *)
  let parse_class () : cset =
    let start = !i in
    incr i;
    let negated =
      match peek () with
      | Some '^' ->
        incr i;
        true
      | _ -> false
    in
    let acc = ref [] in
    let count = ref 0 in
    (* Reads one class member; returns its set and, when it is a single plain
       character, that character's code (so `a-z` ranges can be formed). *)
    let read_member () : cset * int option =
      match peek () with
      | None -> bad start "unterminated character class — expected `]`"
      | Some '\\' ->
        let esc_off = !i in
        incr i;
        (match peek () with
         | None -> bad esc_off "trailing backslash in character class"
         | Some c ->
           incr i;
           (match class_escape c with
            | Some set ->
              let single =
                match set with [ (a, b) ] when a = b -> Some a | _ -> None
              in
              (set, single)
            | None -> bad esc_off (escape_advice c)))
      | Some '[' when !i + 1 < n && p.[!i + 1] = ':' ->
        bad !i
          "POSIX bracket classes (`[:alpha:]`) are not part of Tesl's regex \
           subset. Spell the range out, e.g. `[a-zA-Z]`."
      | Some c ->
        incr i;
        (cs_char c, Some (Char.code c))
    in
    let rec loop () =
      match peek () with
      | None -> bad start "unterminated character class — expected `]`"
      | Some ']' ->
        incr i;
        if !count = 0 then bad start "empty character class"
      | Some _ ->
        let off = !i in
        let set, single = read_member () in
        incr count;
        (* A `-` between two plain characters forms a range; a `-` immediately
           before `]` is a literal. *)
        (match (single, peek ()) with
         | Some lo, Some '-' when !i + 1 < n && p.[!i + 1] <> ']' ->
           incr i;
           let _, hi_single = read_member () in
           (match hi_single with
            | Some hi ->
              if hi < lo then
                bad off "character range has its endpoints reversed"
              else acc := (lo, hi) :: !acc
            | None ->
              bad off
                "a character range endpoint must be a plain character, not a \
                 class escape")
         | _ -> acc := set @ !acc);
        loop ()
    in
    loop ();
    let set = cs_norm !acc in
    if negated then cs_complement set else set
  in

  let rec parse_alt () : alt =
    let first = parse_seq () in
    let branches = ref [ first ] in
    while peek () = Some '|' do
      incr i;
      branches := parse_seq () :: !branches
    done;
    List.rev !branches

  and parse_seq () : pseq =
    let acc = ref [] in
    let continue_ = ref true in
    while !continue_ do
      match peek () with
      | None | Some '|' | Some ')' -> continue_ := false
      | Some _ ->
        let off = !i in
        let a = parse_atom () in
        let q = parse_quant_opt off a in
        acc := { patom = a; pquant = q; poff = off } :: !acc
    done;
    List.rev !acc

  and parse_quant_opt (atom_off : int) (a : atom) : quant option =
    let q =
      match peek () with
      | Some '*' ->
        incr i;
        Some { qmin = 0; qmax = None }
      | Some '+' ->
        incr i;
        Some { qmin = 1; qmax = None }
      | Some '?' ->
        incr i;
        Some { qmin = 0; qmax = Some 1 }
      | Some '{' -> Some (parse_brace_quant ())
      | _ -> None
    in
    (match q with
     | None -> ()
     | Some _ ->
       (match peek () with
        | Some ('?' | '+') ->
          bad !i
            "lazy (`*?`) and possessive (`*+`) quantifiers are not part of \
             Tesl's regex subset"
        | Some '*' -> bad !i "a quantifier cannot be quantified again"
        | Some '{' -> bad !i "a quantifier cannot be quantified again"
        | _ -> ());
       (match a with
        | AAnchor ->
          bad atom_off "an anchor (`^`, `$`, `\\b`) cannot be quantified"
        | _ -> ()));
    q

  and parse_atom () : atom =
    let off = !i in
    match peek () with
    | None -> bad off "unexpected end of pattern"
    | Some '(' ->
      incr i;
      let capturing =
        match peek () with
        | Some '?' ->
          if !i + 1 < n && p.[!i + 1] = ':' then (
            i := !i + 2;
            false)
          else
            bad off
              "`(?…)` extended groups (lookaround, inline flags, named groups) \
               are not part of Tesl's regex subset; `(?: … )` is the \
               non-capturing group"
        | _ ->
          incr captures;
          if !captures > max_capture_groups then
            bad off
              (Printf.sprintf "a pattern may have at most %d capture groups"
                 max_capture_groups);
          true
      in
      let body = parse_alt () in
      (match peek () with
       | Some ')' -> incr i
       | _ -> bad off "unterminated group — expected `)`");
      AGroup { capturing; body }
    | Some ')' -> bad off "unmatched `)` — write `\\)` for a literal parenthesis"
    | Some '[' -> AChars (parse_class ())
    | Some ']' -> bad off "unmatched `]` — write `\\]` for a literal bracket"
    | Some '.' ->
      incr i;
      AChars cs_dot
    | Some '^' | Some '$' ->
      incr i;
      AAnchor
    | Some '*' | Some '+' | Some '?' ->
      bad off "a quantifier here has nothing to repeat"
    | Some '{' -> ignore (parse_brace_quant ()); bad off "a repetition here has nothing to repeat"
    | Some '}' -> bad off "unmatched `}` — write `\\}` for a literal brace"
    | Some '\\' ->
      incr i;
      (match peek () with
       | None -> bad off "trailing backslash"
       | Some ('b' | 'B') ->
         incr i;
         AAnchor
       | Some c -> (
         incr i;
         match class_escape c with
         | Some set -> AChars set
         | None -> bad off (escape_advice c)))
    | Some c ->
      if is_meta c then bad off "unexpected metacharacter"
      else (
        incr i;
        AChars (cs_char c))
  in

  if n = 0 then bad 0 "an empty pattern matches every string";
  if n > max_pattern_length then
    bad 0
      (Printf.sprintf "regex pattern is longer than the %d-character limit"
         max_pattern_length);
  let a = parse_alt () in
  (match peek () with
   | None -> ()
   | Some ')' -> bad !i "unmatched `)` — write `\\)` for a literal parenthesis"
   | Some c -> bad !i (Printf.sprintf "unexpected `%c`" c));
  a

(* ── Structural predicates over the parsed pattern ────────────────────────── *)

let rec alt_nullable (a : alt) : bool = List.exists seq_nullable a

and seq_nullable (s : pseq) : bool = List.for_all piece_nullable s

and piece_nullable (pc : piece) : bool =
  match pc.pquant with
  | Some { qmin = 0; _ } -> true
  | _ -> atom_nullable pc.patom

and atom_nullable = function
  | AChars _ -> false
  | AAnchor -> true
  | AGroup { body; _ } -> alt_nullable body

let rec alt_has_quantifier (a : alt) : bool =
  List.exists (List.exists piece_has_quantifier) a

and piece_has_quantifier (pc : piece) : bool =
  pc.pquant <> None
  || match pc.patom with
     | AGroup { body; _ } -> alt_has_quantifier body
     | _ -> false

(* A group can only occur as the ATOM of a piece, so a shallow test over a
   sequence's pieces already decides "does this sequence contain a group". *)
let piece_has_group (pc : piece) : bool =
  match pc.patom with AGroup _ -> true | _ -> false

let rec alt_has_capture (a : alt) : bool =
  List.exists (List.exists piece_has_capture) a

and piece_has_capture (pc : piece) : bool =
  match pc.patom with
  | AGroup { capturing; body } -> capturing || alt_has_capture body
  | _ -> false

(** Every single-character atom reachable in [a], flattened. *)
let rec alt_char_atoms (a : alt) : cset list =
  List.concat_map (List.concat_map piece_char_atoms) a

and piece_char_atoms (pc : piece) : cset list =
  match pc.patom with
  | AChars cs -> [ cs ]
  | AAnchor -> []
  | AGroup { body; _ } -> alt_char_atoms body

(* ── Safety rules ─────────────────────────────────────────────────────────── *)

(** Maximum number of repetitions a quantifier can perform ([None] = unbounded).
    A quantifier that repeats at most once introduces no repetition ambiguity,
    so it is exempt from the backtracking rules. *)
let repeats_more_than_once (q : quant) : bool =
  match q.qmax with None -> true | Some m -> m > 1

(** The "distinguished separator" test.  A quantified group whose body contains
    its own quantifier is safe when the body starts with a fixed single
    character that cannot be consumed by anything else in the body: each
    iteration then begins at a forced position, so the decomposition of the
    input is unique and the matcher cannot backtrack across iterations.
    This is what makes the ubiquitous `(?:-[a-z0-9]+)*` / `(?:\.[a-z]+)+`
    idiom legal while `(a+)+` and `(?:aa+)+` stay rejected. *)
let has_distinguished_prefix (body : pseq) : bool =
  match body with
  | [] -> false
  | first :: rest ->
    (match (first.pquant, first.patom) with
     | None, AChars lead ->
       (* No nested group: keep the character-set reasoning exact. *)
       (not (List.exists piece_has_group rest))
       && (not (piece_has_group first))
       && List.for_all
            (fun cs -> not (cs_intersects lead cs))
            (List.concat_map piece_char_atoms rest)
     | _ -> false)

let rec check_alt (a : alt) : unit =
  (* VREGEX004: a capture inside an alternation branch may not participate. *)
  if List.length a > 1 then
    List.iter
      (fun branch ->
        List.iter
          (fun pc ->
            if piece_has_capture pc then
              capture_rule pc.poff
                "a capture group inside an alternation may not participate in \
                 a successful match, so its captured text would be undefined. \
                 Make it non-capturing (`(?: … )`), or lift the group outside \
                 the alternation.")
          branch)
      a;
  List.iter (List.iter check_piece) a

and check_piece (pc : piece) : unit =
  (match pc.patom with AGroup { body; _ } -> check_alt body | _ -> ());
  match (pc.pquant, pc.patom) with
  | None, _ -> ()
  | Some q, AGroup { capturing; body } ->
    (* Backtracking first: for `(a+)+` the exponential blowup is the headline,
       and the capture rule below would otherwise mask it. *)
    if repeats_more_than_once q then (
      if alt_nullable body then
        unsafe pc.poff
          "this group can match the empty string and is repeated, so the \
           matcher can loop over it without consuming input. Move the inner \
           `*`/`?` outside the group.";
      if List.length body > 1 then
        unsafe pc.poff
          "a repeated group containing `|` is ambiguous: the matcher must try \
           every combination of branches, which is exponential in the input \
           length. Use a character class (`[ab]*`) or restructure the pattern.";
      match body with
      | [ single ] ->
        if List.exists piece_has_quantifier single
           && not (has_distinguished_prefix single)
        then
          unsafe pc.poff
            "a repeated group whose body also repeats is ambiguous: the same \
             input can be split across iterations in exponentially many ways \
             (the `(a+)+` shape). Either drop one of the two quantifiers, or \
             start the group with a fixed separator character that cannot \
             appear in the rest of the group (as in `(?:-[a-z0-9]+)*`)."
      | _ -> ());
    (* VREGEX004: a capture under a quantifier is not uniquely determined. *)
    if capturing then
      capture_rule pc.poff
        "a quantified capture group captures only its last repetition (and \
         nothing at all when it repeats zero times), so its captured text \
         would be undefined. Make it non-capturing (`(?: … )`).";
    if repeats_more_than_once q && alt_has_capture body then
      capture_rule pc.poff
        "a capture group inside a repeated group captures only the last \
         repetition, so its captured text would be undefined. Make it \
         non-capturing (`(?: … )`)."
  | Some _, _ -> ()

(** Adjacent unbounded quantifiers over overlapping character sets (`\d+[0-9]*`)
    give the matcher a quadratic number of splits.  Rejected where it is
    syntactically obvious; anything subtler is bounded by the runtime deadline. *)
let rec check_adjacent (a : alt) : unit =
  List.iter
    (fun branch ->
      let rec pairs = function
        | x :: (y :: _ as rest) ->
          (match ((x.pquant, x.patom), (y.pquant, y.patom)) with
           | (Some qx, AChars cx), (Some qy, AChars cy)
             when repeats_more_than_once qx && repeats_more_than_once qy
                  && cs_intersects cx cy ->
             unsafe y.poff
               "two neighbouring repetitions accept the same characters, so \
                the matcher must try every way of splitting the input between \
                them. Merge them into one repetition."
           | _ -> ());
          pairs rest
        | _ -> ()
      in
      pairs branch;
      List.iter
        (fun pc ->
          match pc.patom with AGroup { body; _ } -> check_adjacent body | _ -> ())
        branch)
    a

let validate_pattern (p : string) : (unit, reject) result =
  match
    let a = parse_pattern p in
    check_alt a;
    check_adjacent a
  with
  | () -> Ok ()
  | exception Rej r -> Error r

(** Number of capturing groups in an already-valid pattern (0 when it does not
    parse — callers only ask about patterns that passed {!validate_pattern}). *)
let capture_count (p : string) : int =
  match parse_pattern p with
  | a ->
    let rec count_alt a = List.fold_left (fun acc s -> acc + count_seq s) 0 a
    and count_seq s = List.fold_left (fun acc pc -> acc + count_piece pc) 0 s
    and count_piece pc =
      match pc.patom with
      | AGroup { capturing; body } ->
        (if capturing then 1 else 0) + count_alt body
      | _ -> 0
    in
    count_alt a
  | exception Rej _ -> 0

(* ── The `Tesl.Regex` surface ─────────────────────────────────────────────── *)

(** Every `Tesl.Regex` function, with the 0-based index of its pattern
    argument.  The pattern is argument 0 everywhere — that uniformity is what
    lets the literal rule be stated (and enforced) in one sentence. *)
let regex_functions : (string * int) list =
  [ ("Regex.matches", 0);
    ("Regex.find", 0);
    ("Regex.findAll", 0);
    ("Regex.captures", 0);
    ("Regex.replace", 0);
    ("Regex.split", 0) ]

let is_regex_function (name : string) : bool = List.mem_assoc name regex_functions

let regex_function_arity (name : string) : int =
  if name = "Regex.replace" then 3 else 2

(** The runtime (emitted Racket) names of the same functions, for the emitter's
    fail-closed backstop. *)
let is_regex_runtime_name (racket_name : string) : bool =
  List.exists
    (fun (n, _) ->
      racket_name = "tesl_import_" ^ String.concat "_" (String.split_on_char '.' n))
    regex_functions

(** The literal pattern text of [e], when it is one.

    A Tesl string containing `$` lexes as an interpolation even when it has no
    `${…}` hole (see [Lexer.process_string_content]), so `"^ab$"` arrives as a
    single-[ILiteral] [LInterp].  That is still a literal — and `$` is the end
    anchor, so refusing it would make anchored patterns unwritable. Anything
    with a real hole, or any non-literal expression, is [None]. *)
let literal_pattern_of_expr (e : Ast.expr) : string option =
  match e with
  | Ast.ELit { lit = Ast.LString s; _ } -> Some s
  | Ast.ELit { lit = Ast.LInterp [ Ast.ILiteral s ]; _ } -> Some s
  | Ast.ELit { lit = Ast.LInterp []; _ } -> Some ""
  | _ -> None

let not_a_literal_message (fn_name : string) : string =
  Printf.sprintf
    "`%s` needs its pattern written as a string literal at the call site. Tesl \
     validates regex patterns when it compiles the program — rejecting \
     malformed ones and ones that can backtrack catastrophically — which is \
     only possible when the pattern is part of the program. There is no \
     dynamic-pattern form on purpose: a pattern taken from a request is a \
     resource-exhaustion hole. Name the predicate instead of the pattern, e.g. \
     `fn isSlug(s: String) -> Bool = Regex.matches(\"^[a-z0-9-]+$\", s)`."
    fn_name

(* ── The AST pass ─────────────────────────────────────────────────────────── *)

open Ast

(** The qualified stdlib name a call head denotes, if any.  Covers the three
    spellings a `Module.fn` head can take in the AST. *)
let call_head_name (e : expr) : string option =
  match e with
  | EField { obj = EConstructor { name = m; args = []; _ }; field; _ } ->
    Some (m ^ "." ^ field)
  | EField { obj = EVar { name = m; _ }; field; _ } -> Some (m ^ "." ^ field)
  | EVar { name; _ } when String.contains name '.' -> Some name
  | _ -> None

let rec flatten_app (acc : expr list) (e : expr) : expr * expr list =
  match e with EApp { fn; arg; _ } -> flatten_app (arg :: acc) fn | _ -> (e, acc)

(** Check one expression node (not its children — the caller recurses). *)
let check_call (acc : (Location.loc * string * string) list ref) (e : expr) : unit =
  match e with
  | EApp _ ->
    let head, args = flatten_app [] e in
    (match call_head_name head with
     | Some name when is_regex_function name ->
       let idx = List.assoc name regex_functions in
       (match List.nth_opt args idx with
        | None -> ()  (* arity error; the type checker reports it *)
        | Some pat_expr ->
          let loc = Parser.expr_loc pat_expr in
          (match literal_pattern_of_expr pat_expr with
           | None -> acc := (loc, "VREGEX002", not_a_literal_message name) :: !acc
           | Some p ->
             (match validate_pattern p with
              | Ok () -> ()
              | Error r ->
                let msg =
                  Printf.sprintf "regex pattern rejected at offset %d: %s"
                    r.offset r.message
                in
                acc := (loc, r.code, msg) :: !acc)))
     | _ -> ())
  | _ -> ()

(** Regex operations are application-site-sensitive: allowing one to escape as
    an ordinary function value would let an indirect caller supply a dynamic
    pattern and bypass every check above.  Record only heads of saturated direct
    calls; every other reference is rejected by [module_diagnostics]. *)
let allowed_direct_reference (e : expr) : Location.loc option =
  match e with
  | EApp _ ->
    let head, args = flatten_app [] e in
    (match call_head_name head with
     | Some name
       when is_regex_function name && List.length args = regex_function_arity name ->
       Some (Parser.expr_loc head)
     | _ -> None)
  | _ -> None

let module_diagnostics (m : module_form) : (Location.loc * string * string) list =
  let acc = ref [] in
  let visit_expr e =
    let allowed = ref [] in
    Ast_visitor.iter
      (fun node ->
        Option.iter (fun loc -> allowed := loc :: !allowed)
          (allowed_direct_reference node))
      e;
    Ast_visitor.iter
      (fun node ->
        check_call acc node;
        match call_head_name node with
        | Some name
          when is_regex_function name
               && not (List.exists (( = ) (Parser.expr_loc node)) !allowed) ->
          acc :=
            ( Parser.expr_loc node,
              "VREGEX002",
              not_a_literal_message name
              ^ " Regex functions cannot be stored, passed, or returned as values." )
            :: !acc
        | _ -> ())
      e
  in
  let rec visit_test_stmt = function
    | TsLetProof { value; _ } -> visit_expr value
    | TsLet { value; _ } -> visit_expr value
    | TsExpect { left; right; _ } ->
      visit_expr left;
      Option.iter visit_expr right
    | TsExpectFail { fn; arg; _ } ->
      visit_expr fn;
      visit_expr arg
    | TsExpectHasProof { fn; arg; _ } ->
      visit_expr fn;
      visit_expr arg
    | TsProperty { body; _ } -> visit_expr body
    | TsIf { cond; then_stmts; else_stmts; _ } ->
      visit_expr cond;
      List.iter visit_test_stmt then_stmts;
      List.iter visit_test_stmt else_stmts
    | TsCase { scrut; arms; _ } ->
      visit_expr scrut;
      List.iter (fun arm -> List.iter visit_test_stmt arm.ts_body) arms
    | TsExpr { e; _ } -> visit_expr e
  in
  List.iter
    (function
      | DFunc fd -> visit_expr fd.body
      | DConst c -> visit_expr c.value
      | DTest test -> List.iter visit_test_stmt test.stmts
      | DApiTest test ->
        List.iter visit_expr test.seed_stmts;
        List.iter visit_test_stmt test.stmts
      | DLoadTest test ->
        List.iter visit_expr test.seed_stmts;
        List.iter visit_test_stmt test.request_stmts
      | DType _ | DRecord _ | DEntity _ | DFact _ | DCodec _ | DDatabase _
      | DCapability _ | DQueue _ | DChannel _ | DWorkers _ | DCache _ | DAgent _
      | DEmail _ | DCapture _ | DApi _ | DServer _ ->
        ())
    m.decls;
  List.rev !acc
