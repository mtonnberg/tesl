(** Machine-applicable diagnostic edits — the single home for the fix type,
    the source-verified fix builders, and the pure applier.

    D9: any diagnostic that *knows* the exact edit must be able to ship it as a
    structured fix instead of prose.  This module is a dependency leaf (only
    [Location]) so every producer can reach it: the parser (which has no source
    text, only token locations), the checker (which has locations plus an
    optional source snapshot for verification), and the compile/linter layers.
    [Type_system.diagnostic_fix] and [Compile.diagnostic_fix] re-export [t] via
    type equations, so existing constructor uses keep working unchanged.

    All line/column numbers are 0-based, matching diagnostic positions on the
    JSON wire.  [Replace_range] columns are half-open: [end_col] is exclusive. *)

open Location

type t =
  | Replace_line of { line : int; replacement : string }
  | Insert_line  of { line : int; text : string }
      (** insert [text] as a new line BEFORE [line] *)
  | Replace_span of { start_line : int; end_line : int; replacement : string }
      (** replace the inclusive line range; [replacement = ""] deletes it *)
  | Replace_range of { start_line : int; start_col : int;
                       end_line : int; end_col : int; replacement : string }
      (** column-precise replacement of [start_line:start_col ..
          end_line:end_col) — the token-level edit the line-granular variants
          cannot express without re-synthesizing the whole line.  A zero-width
          range ([start = end]) is an insertion. *)
  | Multi of t list
      (** several non-overlapping edits applied together (one LSP code action
          carries them as one TextEdit list) — e.g. the single-line-`if` fix,
          which must split at `then` AND before `else` at once.  Elements must
          not themselves be [Multi]. *)

(* ── Source-verified builders ────────────────────────────────────────────────
   Fail-closed: when the source snapshot is absent or does not contain what the
   location claims, the builder returns [None] and the diagnostic ships without
   a fix — never with a fix that would edit the wrong text. *)

let line_at (source_lines : string array) (n : int) : string option =
  if n >= 0 && n < Array.length source_lines then Some source_lines.(n) else None

(** Delete the [expect] keyword sitting at [loc.start], plus any spaces
    immediately after it (`return x` → `x`).  Deliberately ignores [loc.stop]:
    parser stop positions overshoot into the next token (see
    [Parser.last_consumed_loc]'s doc), so trusting it would delete the value
    after the keyword too. *)
let verified_delete ~(source_lines : string array) (loc : loc) ~(expect : string) : t option =
  match line_at source_lines loc.start.line with
  | None -> None
  | Some line ->
    let len = String.length line in
    let s_col = loc.start.col in
    let elen = String.length expect in
    if s_col < 0 || s_col + elen > len || String.sub line s_col elen <> expect
    then None
    else begin
      let e_col = ref (s_col + elen) in
      while !e_col < len && line.[!e_col] = ' ' do incr e_col done;
      Some (Replace_range { start_line = loc.start.line; start_col = s_col;
                            end_line = loc.start.line; end_col = !e_col;
                            replacement = "" })
    end

(** Replace the [token] whose first character sits exactly at [at] (e.g. a
    binop's [op_loc.start]), verified against the source line. *)
let verified_token_replace ~(source_lines : string array)
    ~(at : pos) ~(token : string) ~(replacement : string) : t option =
  match line_at source_lines at.line with
  | None -> None
  | Some line ->
    let tlen = String.length token in
    if at.col < 0 || at.col + tlen > String.length line
       || String.sub line at.col tlen <> token
    then None
    else Some (Replace_range { start_line = at.line; start_col = at.col;
                               end_line = at.line; end_col = at.col + tlen;
                               replacement })

(* ── Pure applier ────────────────────────────────────────────────────────────
   The reference semantics for every fix kind — the LSP TextEdit construction
   mirrors this.  Used by the apply-and-recompile seam test, which is what
   keeps every shipped fix honest: a fix that does not make its diagnostic
   disappear fails the suite.  Raises [Invalid_argument] on out-of-range lines
   (loudly wrong beats silently no-op). *)

let rec apply (source : string) (fix : t) : string =
  match fix with
  | Multi edits ->
    (* Apply back-to-front so earlier positions stay valid. *)
    let key = function
      | Replace_line  { line; _ } | Insert_line { line; _ } -> (line, 0)
      | Replace_span  { start_line; _ } -> (start_line, 0)
      | Replace_range { start_line; start_col; _ } -> (start_line, start_col)
      | Multi _ -> invalid_arg "Diag_fix.apply: nested Multi"
    in
    let descending = List.sort (fun a b -> compare (key b) (key a)) edits in
    List.fold_left apply source descending
  | _ ->
  let lines = String.split_on_char '\n' source in
  let n = List.length lines in
  let check_line what l =
    if l < 0 || l >= n then
      invalid_arg (Printf.sprintf "Diag_fix.apply: %s line %d out of range (0..%d)" what l (n - 1))
  in
  let spliced =
    match fix with
    | Replace_line { line; replacement } ->
      check_line "replace_line" line;
      List.mapi (fun i l -> if i = line then replacement else l) lines
    | Insert_line { line; text } ->
      if line < 0 || line > n then
        invalid_arg (Printf.sprintf "Diag_fix.apply: insert_line line %d out of range (0..%d)" line n);
      let before = List.filteri (fun i _ -> i < line) lines in
      let after  = List.filteri (fun i _ -> i >= line) lines in
      before @ [text] @ after
    | Replace_span { start_line; end_line; replacement } ->
      check_line "replace_span start" start_line;
      check_line "replace_span end" end_line;
      if end_line < start_line then invalid_arg "Diag_fix.apply: replace_span end before start";
      let before = List.filteri (fun i _ -> i < start_line) lines in
      let after  = List.filteri (fun i _ -> i > end_line) lines in
      (* "" deletes the lines outright (mirrors the LSP edit); anything else
         replaces the range with the replacement text. *)
      if replacement = "" then before @ after
      else before @ [replacement] @ after
    | Replace_range { start_line; start_col; end_line; end_col; replacement } ->
      check_line "replace_range start" start_line;
      check_line "replace_range end" end_line;
      if end_line < start_line
         || (end_line = start_line && end_col < start_col) then
        invalid_arg "Diag_fix.apply: replace_range end before start";
      let arr = Array.of_list lines in
      let s_line = arr.(start_line) and e_line = arr.(end_line) in
      let s_col = min (max 0 start_col) (String.length s_line) in
      let e_col = min (max 0 end_col) (String.length e_line) in
      let joined =
        String.sub s_line 0 s_col ^ replacement
        ^ String.sub e_line e_col (String.length e_line - e_col)
      in
      let before = List.filteri (fun i _ -> i < start_line) lines in
      let after  = List.filteri (fun i _ -> i > end_line) lines in
      before @ [joined] @ after
    | Multi _ -> assert false  (* dispatched above *)
  in
  String.concat "\n" spliced
