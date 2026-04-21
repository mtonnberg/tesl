(** Tesl source formatter.

    Phase 1 -- Line-level cleanup:
      - Tabs replaced with 2 spaces
      - Trailing whitespace stripped
      - Consecutive blank lines collapsed to a single blank line
      - File ends with exactly one newline

    Phase 2 -- Token-aware formatting (string/comment-safe):
      - Comment normalization: #foo becomes # foo (except #lang, #!)
      - Proof annotation spacing: triple-colon gets surrounding spaces
      - Arrow spacing: dash-greater gets surrounding spaces
      - Pipe spacing: pipe-greater gets surrounding spaces
      - Comparison operators: ==, !=, <=, >= get surrounding spaces
      - Standalone equals gets surrounding spaces
      - ADT separator pipe gets surrounding spaces
      - Comma spacing: comma followed by space
      - Type annotation colon: name:Type becomes name: Type
      - Import header: exposing followed by bracket gets a space

    Preserved:
      - Indentation (leading whitespace is never changed)
      - String literal contents
      - String interpolation contents
      - Expression structure and line breaks

    Known limitations (documented, not yet handled):
      - Arithmetic operator spacing -- ambiguous with dereference
      - Record/type definition alignment and wrapping
      - Maximum line length enforcement
      - Multiline expression indentation
      - Block-level blank line rules (e.g. blank line between functions)
*)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

type scan_state = InCode | InStr | InInterp of int

let is_ws c = c = ' ' || c = '\t'

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c = '_' || c = '\''

let starts_with s prefix =
  let pl = String.length prefix in
  String.length s >= pl && String.sub s 0 pl = prefix

let leading_ws_count s =
  let len = String.length s in
  let i = ref 0 in
  while !i < len && is_ws s.[!i] do incr i done;
  !i

(* ── Phase 1: Line-level cleanup ─────────────────────────────────────── *)

let fix_line line =
  let buf = Buffer.create (String.length line + 4) in
  String.iter (fun c ->
    if c = '\t' then Buffer.add_string buf "  "
    else Buffer.add_char buf c
  ) line;
  let s = Buffer.contents buf in
  let i = ref (String.length s - 1) in
  while !i >= 0 && (s.[!i] = ' ' || s.[!i] = '\r') do decr i done;
  if !i < 0 then "" else String.sub s 0 (!i + 1)

let cleanup_lines (src : string) : string list =
  let lines = String.split_on_char '\n' src in
  let fixed = List.map fix_line lines in
  let collapsed =
    List.fold_right (fun line (acc, prev_blank) ->
      let is_blank = String.trim line = "" in
      if is_blank && prev_blank then (acc, true)
      else (line :: acc, is_blank)
    ) fixed ([], false) |> fst
  in
  let rev = List.rev collapsed in
  let rec drop = function
    | [] -> []
    | x :: rest -> if String.trim x = "" then drop rest else x :: rest
  in
  List.rev (drop rev)

(* ── Phase 2: Token-aware formatting ─────────────────────────────────── *)

(** Format a single line with string/comment awareness.
    Preserves leading whitespace (indentation). Applies spacing
    rules only to code regions. *)
let format_line_tokens (line : string) : string =
  let len = String.length line in
  if len = 0 then line
  else
  let ws_count = leading_ws_count line in
  let indent = String.sub line 0 ws_count in
  let rest = String.sub line ws_count (len - ws_count) in
  let rest_len = String.length rest in
  if rest_len = 0 then indent
  else
  let buf = Buffer.create (len + 16) in
  let state = ref InCode in
  let last_nonws = ref ' ' in
  let last_emitted = ref ' ' in
  let i = ref 0 in

  let emit c =
    Buffer.add_char buf c;
    last_emitted := c;
    if not (is_ws c) then last_nonws := c
  in
  let emit_s s =
    Buffer.add_string buf s;
    let sl = String.length s in
    if sl > 0 then begin
      last_emitted := s.[sl - 1];
      let found = ref false in
      for j = sl - 1 downto 0 do
        if not !found && not (is_ws s.[j]) then
          (last_nonws := s.[j]; found := true)
      done
    end
  in
  let ensure_space_before () =
    if Buffer.length buf > 0 && !last_emitted <> ' ' then
      (Buffer.add_char buf ' '; last_emitted := ' ')
  in
  let skip_ws () =
    while !i < rest_len && is_ws rest.[!i] do incr i done
  in
  let peek off =
    let j = !i + off in
    if j >= 0 && j < rest_len then Some rest.[j] else None
  in

  while !i < rest_len do
    let c = rest.[!i] in
    match !state with

    (* ── Inside string literal ──────────────────────────────────────── *)
    | InStr ->
      if c = '\\' && !i + 1 < rest_len then begin
        emit c; emit rest.[!i + 1]; i := !i + 2
      end
      else if c = '"' then
        (emit c; state := InCode; incr i)
      else if c = '$' && peek 1 = Some '{' then
        (emit_s "${"; state := InInterp 1; i := !i + 2)
      else
        (emit c; incr i)

    (* ── Inside string interpolation (pass through) ─────────────────── *)
    | InInterp depth ->
      if c = '{' then
        (emit c; state := InInterp (depth + 1); incr i)
      else if c = '}' then begin
        emit c;
        (if depth <= 1 then state := InStr
         else state := InInterp (depth - 1));
        incr i
      end
      else (emit c; incr i)

    (* ── Code region ────────────────────────────────────────────────── *)
    | InCode ->

      (* String literal start *)
      if c = '"' then
        (emit c; state := InStr; incr i)

      (* Comment: rest of line *)
      else if c = '#' then begin
        let comment = String.sub rest !i (rest_len - !i) in
        if starts_with comment "#lang " || starts_with comment "#!"
           || starts_with comment "#>" || starts_with comment "#=" then
          emit_s comment
        else if String.length comment > 1
                && comment.[1] <> ' ' && comment.[1] <> '\n' then
          (emit_s "# ";
           emit_s (String.sub comment 1 (String.length comment - 1)))
        else
          emit_s comment;
        i := rest_len
      end

      (* ::: proof annotation → " ::: " *)
      else if c = ':' && peek 1 = Some ':' && peek 2 = Some ':'
              && peek 3 <> Some ':' then begin
        ensure_space_before ();
        emit_s ":::";
        i := !i + 3;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* -> arrow → " -> " *)
      else if c = '-' && peek 1 = Some '>' then begin
        ensure_space_before ();
        emit_s "->";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* |> pipe → " |> " *)
      else if c = '|' && peek 1 = Some '>' then begin
        ensure_space_before ();
        emit_s "|>";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* || logical or → " || " *)
      else if c = '|' && peek 1 = Some '|' then begin
        ensure_space_before ();
        emit_s "||";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* && logical and → " && " *)
      else if c = '&' && peek 1 = Some '&' then begin
        ensure_space_before ();
        emit_s "&&";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* == → " == " *)
      else if c = '=' && peek 1 = Some '=' then begin
        ensure_space_before ();
        emit_s "==";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* != → " != " *)
      else if c = '!' && peek 1 = Some '=' then begin
        ensure_space_before ();
        emit_s "!=";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* <= → " <= " *)
      else if c = '<' && peek 1 = Some '=' then begin
        ensure_space_before ();
        emit_s "<=";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* >= → " >= " *)
      else if c = '>' && peek 1 = Some '=' then begin
        ensure_space_before ();
        emit_s ">=";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* => fat arrow (exists intro) → " => " *)
      else if c = '=' && peek 1 = Some '>' then begin
        ensure_space_before ();
        emit_s "=>";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* ++ string concat → " ++ " *)
      else if c = '+' && peek 1 = Some '+' then begin
        ensure_space_before ();
        emit_s "++";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* + → " + " *)
      else if c = '+' then begin
        ensure_space_before ();
        emit '+';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* * → " * " — arithmetic multiplication. Not ambiguous with anything else
         on this surface; the only `*` use outside expressions is the legacy
         dereference syntax in Racket output, which never goes through this
         formatter. *)
      else if c = '*' then begin
        ensure_space_before ();
        emit '*';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* / → " / " — arithmetic division. (Tesl has no regex or path syntax
         that starts with `/`.) *)
      else if c = '/' then begin
        ensure_space_before ();
        emit '/';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* % → " % " — arithmetic modulo. *)
      else if c = '%' then begin
        ensure_space_before ();
        emit '%';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* - → " - " — binary minus. UNARY minus (e.g. `-5`, `-x`, `(0 - x)`)
         must be preserved. We treat `-` as binary iff the previous non-ws
         code character is a value-producing token: an identifier char,
         a digit, a closing bracket/paren, `_`, or a closing quote. In every
         other position (start of line, after `(`, `,`, `=`, `<`, `>`, `[`,
         `:`, `|`, an operator, etc.) we pass it through unchanged so the
         lexer can still read the `-NUMBER` / unary form.
         SPECIAL CASE: multi-char hyphenated keywords (`api-test`,
         `load-test`) must be preserved verbatim — the lexer treats them
         as single tokens so spacing the `-` would break compilation. *)
      else if c = '-' then begin
        (* Detect hyphenated keywords: if the buffer ends with `api` or
           `load` on a clean word boundary AND the following chars are
           `-test` on a word boundary, emit the `-` unchanged. *)
        let is_hyphenated_keyword () =
          let buf_str = Buffer.contents buf in
          let buf_len = String.length buf_str in
          let ends_with_word w =
            let wl = String.length w in
            if buf_len < wl then false
            else if String.sub buf_str (buf_len - wl) wl <> w then false
            else buf_len = wl
                 || not (is_ident_char buf_str.[buf_len - wl - 1])
          in
          let followed_by_word w =
            let wl = String.length w in
            let start = !i + 1 in
            if start + wl > rest_len then false
            else if String.sub rest start wl <> w then false
            else
              let after = start + wl in
              after >= rest_len || not (is_ident_char rest.[after])
          in
          (ends_with_word "api" && followed_by_word "test")
          || (ends_with_word "load" && followed_by_word "test")
        in
        if is_hyphenated_keyword () then begin
          emit '-';
          incr i
        end
        else begin
          let prev = !last_nonws in
          let is_ident_or_value_char ch =
            (ch >= 'a' && ch <= 'z')
            || (ch >= 'A' && ch <= 'Z')
            || (ch >= '0' && ch <= '9')
            || ch = '_' || ch = ')' || ch = ']' || ch = '"'
          in
          let at_line_start = Buffer.length buf = String.length indent in
          (* A `-` glued to the next token (no whitespace between them) is
             meaningful in Tesl's surface grammar: in function-application
             position, `f a -3` parses `-3` as a negative-literal argument
             iff the `-` is immediately adjacent to the digit/ident (see
             parser.ml's `MINUS when adjacent ...` branch). Inserting a
             space between `-` and the argument would silently reparse it
             as binary subtraction: `(f a) - 3`. Preserve the attached
             form when the source had no whitespace after `-`. *)
          let next_is_value_no_space =
            !i + 1 < rest_len &&
            let nc = rest.[!i + 1] in
            (nc >= '0' && nc <= '9')
            || (nc >= 'a' && nc <= 'z')
            || (nc >= 'A' && nc <= 'Z')
            || nc = '_'
          in
          if next_is_value_no_space && (at_line_start || prev = ' ' || !last_emitted = ' ') then begin
            (* `-` glued to RHS and preceded by whitespace (or at line start):
               negative-literal / unary attachment. Preserve verbatim. *)
            emit '-';
            incr i
          end
          else if (not at_line_start) && is_ident_or_value_char prev then begin
            ensure_space_before ();
            emit '-';
            incr i;
            skip_ws ();
            if !i < rest_len then emit ' '
          end else begin
            emit '-';
            incr i
          end
        end
      end

      (* <- decode arrow → " <- " *)
      else if c = '<' && peek 1 = Some '-' then begin
        ensure_space_before ();
        emit_s "<-";
        i := !i + 2;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* < → " < " (but leave <=, <|, and <- to their dedicated cases) *)
      else if c = '<' && peek 1 <> Some '=' && peek 1 <> Some '|' && peek 1 <> Some '-' then begin
        ensure_space_before ();
        emit '<';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* > → " > " (but leave >= to its dedicated case) *)
      else if c = '>' && peek 1 <> Some '=' then begin
        ensure_space_before ();
        emit '>';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* Standalone = (function body separator, let binding, record field).
         Skipped when followed by '=' (handled as '==' above), or '>'
         (handled as '=>' above), and only inserted when not already
         preceded by a space. *)
      else if c = '=' && peek 1 <> Some '=' && peek 1 <> Some '>' then begin
        ensure_space_before ();
        emit '=';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* , → ", " *)
      else if c = ',' then begin
        emit ',';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* : type annotation → ": " (after identifier, not part of :::) *)
      else if c = ':' && peek 1 <> Some ':' && is_ident_char !last_nonws then begin
        emit ':';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* | ADT separator (not |>, not <|, not ||) → " | " *)
      else if c = '|' && peek 1 <> Some '>'
              && peek 1 <> Some '|'
              && !last_nonws <> '<' then begin
        ensure_space_before ();
        emit '|';
        incr i;
        skip_ws ();
        if !i < rest_len then emit ' '
      end

      (* [ after "exposing" → "exposing [" *)
      else if c = '[' then begin
        let buf_s = Buffer.contents buf in
        let blen = String.length buf_s in
        if blen >= 8 && String.sub buf_s (blen - 8) 8 = "exposing" then
          (emit ' '; emit '['; incr i)
        else
          (emit c; incr i)
      end

      (* Default: pass through *)
      else
        (emit c; incr i)
  done;

  indent ^ Buffer.contents buf

(* ── Phase 2b: Collapse internal whitespace ─────────────────────────── *)

(** Collapse runs of 2+ spaces into a single space within the code portion of
    a line (i.e., outside string literals), while preserving leading indentation. *)
let collapse_internal_spaces (line : string) : string =
  let len = String.length line in
  if len = 0 then line
  else
  let ws_count = leading_ws_count line in
  let indent = String.sub line 0 ws_count in
  let rest = String.sub line ws_count (len - ws_count) in
  let rest_len = String.length rest in
  if rest_len = 0 then indent
  else
  let buf = Buffer.create rest_len in
  let state = ref InCode in
  let i = ref 0 in
  while !i < rest_len do
    let c = rest.[!i] in
    (match !state with
    | InStr ->
      if c = '\\' && !i + 1 < rest_len then begin
        Buffer.add_char buf c;
        Buffer.add_char buf rest.[!i + 1];
        i := !i + 2
      end else begin
        Buffer.add_char buf c;
        if c = '"' then state := InCode;
        incr i
      end
    | InInterp depth ->
      Buffer.add_char buf c;
      if c = '{' then state := InInterp (depth + 1)
      else if c = '}' then
        (if depth <= 1 then state := InStr
         else state := InInterp (depth - 1));
      incr i
    | InCode ->
      if c = '"' then begin
        Buffer.add_char buf c;
        state := InStr;
        incr i
      end else if c = '#' then begin
        (* Comment: copy rest of line verbatim *)
        Buffer.add_string buf (String.sub rest !i (rest_len - !i));
        i := rest_len
      end else if c = ' ' then begin
        (* Collapse run of spaces to a single space *)
        Buffer.add_char buf ' ';
        incr i;
        while !i < rest_len && rest.[!i] = ' ' do incr i done
      end else begin
        Buffer.add_char buf c;
        incr i
      end)
  done;
  indent ^ Buffer.contents buf

(* ── Combined pipeline ───────────────────────────────────────────────── *)

(* Check if a line starts with "module <name> exposing [" or "module <name> exposing[" *)
let is_exposing_line line =
  (* Skip leading whitespace *)
  let len = String.length line in
  let i = ref 0 in
  while !i < len && (line.[!i] = ' ' || line.[!i] = '\t') do incr i done;
  let s = String.sub line !i (len - !i) in
  (* Must start with "module " or "import " *)
  let keyword_len =
    if starts_with s "module " then 7
    else if starts_with s "import " then 7
    else 0
  in
  if keyword_len = 0 then false
  else begin
    (* Skip module/import name *)
    let rest = String.sub s keyword_len (String.length s - keyword_len) in
    let j = ref 0 in
    while !j < String.length rest && rest.[!j] <> ' ' && rest.[!j] <> '\t' do incr j done;
    let after_name = String.sub rest !j (String.length rest - !j) in
    let after_name = String.trim after_name in
    starts_with after_name "exposing " || starts_with after_name "exposing["
  end

(** Reflow a long `module X exposing [a, b, c, ...]` or
    `import X exposing [a, b, c, ...]` line into multi-line form.
    If the line fits within [max_len] characters it is left as-is.
    If it is already split across multiple input lines (multi-line form), those
    are first collapsed back to a single line and then re-emitted if necessary.

    Rules:
      - Lines starting with `module ` followed by `exposing [` on the same line
        (or with the list continuing on the immediately following lines) are
        collected, joined, and reformatted.
      - If the resulting single-line form is ≤ max_len it is kept single-line.
      - Otherwise it is split:
            module Foo exposing [
              name1,
              name2,
              ...
            ]
*)
let reflow_exposing_lists ?(max_len = 80) (lines : string list) : string list =
  let result = ref [] in
  let rest = ref lines in
  while !rest <> [] do
    let line = List.hd !rest in
    rest := List.tl !rest;
    (* Check if this line is a module…exposing line *)
    if is_exposing_line line then begin
      (* Collect the full bracket content, potentially across multiple lines *)
      let collected = Buffer.create 128 in
      Buffer.add_string collected line;
      (* Keep adding lines until we see the closing ] (tracking bracket depth) *)
      let depth = ref 0 in
      String.iter (fun c ->
        if c = '[' then incr depth
        else if c = ']' then decr depth
      ) line;
      while !depth > 0 && !rest <> [] do
        let next = List.hd !rest in
        rest := List.tl !rest;
        Buffer.add_char collected ' ';
        (* Strip leading whitespace from continuation lines *)
        Buffer.add_string collected (String.trim next);
        String.iter (fun c ->
          if c = '[' then incr depth
          else if c = ']' then decr depth
        ) next
      done;
      let full = Buffer.contents collected in
      (* Normalise internal whitespace (collapse runs of spaces to one) *)
      let normalised =
        let buf = Buffer.create (String.length full) in
        let in_ws = ref false in
        String.iter (fun c ->
          if c = ' ' || c = '\t' || c = '\n' || c = '\r' then begin
            if not !in_ws then (Buffer.add_char buf ' '; in_ws := true)
          end else begin
            in_ws := false;
            Buffer.add_char buf c
          end
        ) full;
        Buffer.contents buf
      in
      if String.length normalised <= max_len then
        (* Fits on one line — emit the normalised single-line form *)
        result := normalised :: !result
      else begin
        (* Need to split into multi-line form.
           Extract: prefix = "module/import Foo exposing [", names = comma-separated, "]" *)
        let open_bracket = String.index normalised '[' in
        let prefix = String.sub normalised 0 (open_bracket + 1) in
        let rest_s = String.sub normalised (open_bracket + 1)
                       (String.length normalised - open_bracket - 1) in
        (* Strip trailing "]" *)
        let inner = String.trim rest_s in
        let inner =
          if String.length inner > 0 && inner.[String.length inner - 1] = ']' then
            String.sub inner 0 (String.length inner - 1) |> String.trim
          else inner
        in
        (* Split on commas (not inside brackets, but exposing names never nest) *)
        let names = String.split_on_char ',' inner
                    |> List.map String.trim
                    |> List.filter (fun s -> s <> "") in
        (* Prepend in order: prefix first, names in normal order, "]" last.
           Since result is reversed and List.rev is applied at the end,
           the correct prepend sequence is: prefix → names[0..n] → "]" *)
        result := prefix :: !result;
        List.iter (fun name ->
          result := (Printf.sprintf "  %s," name) :: !result
        ) names;
        result := "]" :: !result
      end
    end else
      result := line :: !result
  done;
  List.rev !result

let format_source (src : string) : string =
  let lines = cleanup_lines src in
  let lines = reflow_exposing_lists lines in
  let formatted = List.map format_line_tokens lines in
  let formatted = List.map collapse_internal_spaces formatted in
  String.concat "\n" formatted ^ "\n"

let format_file (filename : string) : (unit, string) result =
  try
    let src = In_channel.with_open_text filename In_channel.input_all in
    let formatted = format_source src in
    if src <> formatted then
      Out_channel.with_open_text filename (fun oc ->
        Out_channel.output_string oc formatted);
    Ok ()
  with Sys_error msg -> Error msg

(** Return [Ok true] if already formatted, [Ok false] if not, [Error msg] on IO error. *)
let format_check (filename : string) : (bool, string) result =
  try
    let src = In_channel.with_open_text filename In_channel.input_all in
    let formatted = format_source src in
    Ok (src = formatted)
  with Sys_error msg -> Error msg
