(** Source location types used throughout the compiler. Every error and AST node
    carries a [loc] so diagnostics always report exact file/line/column. *)

type pos = {
  line : int;   (** 0-based line number *)
  col  : int;   (** 0-based column number *)
}

type loc = {
  file  : string;
  start : pos;
  stop  : pos;
}

let dummy_pos = { line = 0; col = 0 }
let dummy_loc file = { file; start = dummy_pos; stop = dummy_pos }

let make_loc file sl sc el ec =
  { file; start = { line = sl; col = sc }; stop = { line = el; col = ec } }

let pp_pos fmt p = Format.fprintf fmt "%d:%d" (p.line + 1) (p.col + 1)
let pp_loc fmt l = Format.fprintf fmt "%s:%a-%a" l.file pp_pos l.start pp_pos l.stop

(** Span two locations — take the outer extremes. *)
let span a b =
  if a.file <> b.file then a   (* shouldn't happen in practice *)
  else
    let start = if a.start.line < b.start.line || (a.start.line = b.start.line && a.start.col <= b.start.col)
                then a.start else b.start in
    let stop  = if a.stop.line  > b.stop.line  || (a.stop.line  = b.stop.line  && a.stop.col  >= b.stop.col)
                then a.stop  else b.stop  in
    { file = a.file; start; stop }
