(** Structured diagnostic guidance. These producer-owned judgments never grant
    permission to apply an edit; a command still needs its guarded source preview. *)
type action_class = Mechanical | Suggested | Decision
type command = {title:string;name:string;arguments:(string * string) list}
type action = {class_:action_class;fix_all_eligible:bool;needs_confirmation:bool;command:command option}
type t = {message:string;related:(Location.loc * string) list;action:action option}

let class_name = function Mechanical -> "mechanical" | Suggested -> "suggested" | Decision -> "decision"
let action class_ = {class_;fix_all_eligible=false;needs_confirmation=(class_=Decision);command=None}
let migration ~code ~message ~related =
 let class_ = match code with
  | "MIG001" | "MIG010" | "MIG012" | "MIG015" | "MIG024" | "MIG027" -> Some Mechanical
  | "MIG004" | "MIG008" | "MIG009" | "MIG017" | "MIG018" | "MIG019"
  | "MIG021" | "MIG022" | "MIG023" | "MIG031" | "MIG032" -> Some Suggested
  | "MIG014" | "MIG025" | "MIG029" -> None
  (* MIG002 needs proven generator ownership before a mechanical action can be
     offered. MIG020/MIG026 also cover ambiguous malformed source/history; only
     a producer with a checked unique repair may narrow this default. *)
  | _ when String.starts_with ~prefix:"MIG" code -> Some Decision
  | _ -> None in
 {message;related;action=Option.map action class_}
