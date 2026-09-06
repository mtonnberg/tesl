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

(* ── Human titles for code actions ───────────────────────────────────────────
   The editor shows this string in the lightbulb / quick-fix menu, and it is the
   ONLY thing a user reads before deciding to apply an edit.  The LSP used to
   synthesize it as [Printf.sprintf "Apply fix for %s" code], so every action in
   every file read "Apply fix for W010" — which says nothing about what the edit
   does and forces the user to apply it to find out.

   [title] derives a specific, imperative description from the diagnostic CODE
   (which carries the producer's intent) plus the edit's KIND and CONTENT.  It is
   deliberately total and has no "Apply fix for …"-style escape hatch: the worst
   case for an unrecognised code is still a content-derived description of the
   actual edit ("Delete these 2 lines", "Replace with `x ++ y`").

   Guarantees pinned by test/test_fix_titles.ml:
     • no title mentions a diagnostic code, or the word "diagnostic";
     • every title starts with an imperative verb and is ≤ 72 chars;
     • every code that ships a fix anywhere in the compiler has an entry here
       (a new fix-shipping code fails that test until its title is written).   *)

let truncate n s =
  let s = String.concat " " (String.split_on_char '\n' s) in
  let s = String.trim s in
  if String.length s <= n then s
  else String.sub s 0 (max 0 (n - 1)) ^ "\u{2026}"

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(** Parse a rendered import statement into its module name and exposed names.
    Handles both forms [Import_suggest.render_import] produces —
    [import M exposing [a, b]] and, for a long list, the multi-line
    [import M exposing [\n  a,\n  b,\n]] — plus a bare [import M].
    [None] when the text is not an import at all. *)
let parse_import (text : string) : (string * string list) option =
  let t = String.trim text in
  if not (starts_with "import " t) then None
  else begin
    let rest = String.trim (String.sub t 7 (String.length t - 7)) in
    match String.index_opt rest '[' with
    | None ->
      (* `import M` — or `import M exposing` with nothing after it. *)
      let m =
        match String.index_opt rest ' ' with
        | Some i -> String.sub rest 0 i
        | None -> rest
      in
      Some (String.trim m, [])
    | Some i ->
      let before = String.trim (String.sub rest 0 i) in
      (* strip a trailing `exposing` *)
      let m =
        match String.index_opt before ' ' with
        | Some j -> String.trim (String.sub before 0 j)
        | None -> before
      in
      let inside =
        let j = try String.rindex rest ']' with Not_found -> String.length rest in
        if j > i + 1 then String.sub rest (i + 1) (j - i - 1) else ""
      in
      let names =
        String.split_on_char ',' inside
        |> List.map (fun s ->
             (* the multi-line form indents each name and keeps newlines *)
             String.trim (String.concat " " (String.split_on_char '\n' s)))
        |> List.filter (fun s -> s <> "")
      in
      Some (m, names)
  end

(** How many lines an inclusive span covers, phrased for a human. *)
let line_count_phrase start_line end_line =
  let n = end_line - start_line + 1 in
  if n <= 1 then "this line" else Printf.sprintf "these %d lines" n

(** Title for an edit whose replacement text is a rendered import statement.
    [Import_suggest] APPENDS the name it is making available, so the last exposed
    name is the one this action adds — which is what the user wants to read.
    [None] when the text is not an import at all. *)
let import_title (text : string) : string option =
  match parse_import text with
  | None -> None
  | Some (m, []) -> Some (Printf.sprintf "Import %s" m)
  | Some (m, names) ->
    let added = List.nth names (List.length names - 1) in
    Some (Printf.sprintf "Import %s from %s" added m)

let rec content_title (fix : t) : string =
  match fix with
  | Insert_line { text; _ } ->
    (match import_title text with
     | Some t -> t
     | None -> Printf.sprintf "Insert `%s`" (truncate 48 text))
  | Replace_span { start_line; end_line; replacement } ->
    if replacement = "" then
      Printf.sprintf "Delete %s" (line_count_phrase start_line end_line)
    else
      (match parse_import replacement with
       | Some (m, names) when names <> [] ->
         Printf.sprintf "Change the import from %s to expose %s" m
           (String.concat ", " names)
       | _ -> Printf.sprintf "Replace with `%s`" (truncate 48 replacement))
  | Replace_line { replacement; _ } ->
    if String.trim replacement = "" then "Clear this line"
    else Printf.sprintf "Rewrite line as `%s`" (truncate 48 replacement)
  | Replace_range { start_line; start_col; end_line; end_col; replacement } ->
    if replacement = "" then "Delete this text"
    else if start_line = end_line && start_col = end_col then
      (* zero-width range = pure insertion *)
      Printf.sprintf "Insert `%s`" (truncate 32 replacement)
    else Printf.sprintf "Replace with `%s`" (truncate 48 replacement)
  | Multi [] -> "Apply the suggested edits"
  | Multi (first :: _) -> content_title first

(** The set of diagnostic codes that ship a fix and therefore need an
    intent-bearing title.  Kept as data so test/test_fix_titles.ml can assert it
    stays complete as new fixes are added. *)
let titled_codes = [ "W010"; "W011"; "W050"; "T001"; "E000"; "E002";
                     "VBOOL001"; "VBOOL002"; "MIG015" ]

(** The user-facing code-action title for [fix], reported under [code]. *)
let title ~(code : string) (fix : t) : string =
  match code, fix with
  | "MIG015", _ -> "Use VCurrent for this schema import and its qualified references"
  (* ── Linter formatting fixes: the code IS the intent. ── *)
  | "W010", _ -> "Remove trailing whitespace"
  | "W011", _ -> "Re-indent to a multiple of 2 spaces"
  (* ── Unused imports (W050).  Deleting the statement vs. pruning names from
        it are different actions and must not read alike. ── *)
  | "W050", Replace_span { replacement = ""; _ } -> "Remove this unused import"
  | "W050", Replace_span { replacement; _ } ->
    (match parse_import replacement with
     | Some (m, names) when names <> [] ->
       Printf.sprintf "Remove the unused names, keeping %s from %s"
         (String.concat ", " names) m
     | _ -> "Remove the unused names from this import")
  (* ── Type errors (T001) and a missing Bool import (VBOOL002): import
        suggestions dominate, and `import_title` names exactly which name the
        action makes available. ── *)
  | ("T001" | "VBOOL002"), Insert_line { text; _ } ->
    (match import_title text with Some t -> t | None -> content_title fix)
  | ("T001" | "VBOOL002"), Replace_span { replacement; _ } ->
    (match import_title replacement with Some t -> t | None -> content_title fix)
  (* ── Parser fixes (E000/E002). ── *)
  | "E002", _ -> "Delete the obsolete `#lang tesl` line"
  | "E000", (Multi _ | Replace_range _) ->
    "Move the body onto its own indented line"
  (* ── Legacy boolean spellings (VBOOL001) fix a token but ship the whole
        corrected LINE, so the honest, useful title is to show that line — the
        user sees exactly what they will get. ── *)
  | "VBOOL001", Replace_line { replacement; _ } ->
    Printf.sprintf "Rewrite line as `%s`" (truncate 48 replacement)
  (* ── Anything else: describe the actual edit. ── *)
  | _ -> content_title fix

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

(** Insert [text] immediately BEFORE the token [expect] whose first character
    sits exactly at [at] (e.g. `check ` before the callee of an unwrapped
    check call).  A zero-width [Replace_range] is the insertion; verified
    against the source line, so a location that does not actually name
    [expect] ships no fix rather than a misplaced one. *)
let verified_insert_before ~(source_lines : string array)
    ~(at : pos) ~(expect : string) ~(text : string) : t option =
  match line_at source_lines at.line with
  | None -> None
  | Some line ->
    let elen = String.length expect in
    if at.col < 0 || at.col + elen > String.length line
       || String.sub line at.col elen <> expect
    then None
    else Some (Replace_range { start_line = at.line; start_col = at.col;
                               end_line = at.line; end_col = at.col;
                               replacement = text })

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
