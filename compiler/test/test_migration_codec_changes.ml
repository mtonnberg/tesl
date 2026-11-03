open Alcotest
module M = Migration_codec_changes
let replace a b = Str.global_replace (Str.regexp_string a) b
let get = function Ok x->x | Error (e:Migration_ir.error)->fail e.message
let rec mkdir path=if not(Sys.file_exists path) then (mkdir(Filename.dirname path);Unix.mkdir path 0o700)
let rec remove path=if Sys.is_directory path then (Array.iter(fun n->remove(Filename.concat path n))(Sys.readdir path);Unix.rmdir path) else Sys.remove path
let source={|module Schema.Notes.VCurrent exposing [Note, Payload]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Payload { text: String }
codec Payload {
 toJson { text -> "title" with_codec stringCodec }
 fromJson [ { text <- "title" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id {
 id: String
 payload: Payload
}
|}
let old_alt={|{ text <- "title" with_codec stringCodec }|}
let extra_alt={|{ text <- "legacy" with_codec stringCodec }|}
let appended=replace old_alt (old_alt ^ " " ^ extra_alt) source
let project before after run =
 let root=Filename.temp_file "tesl-codec-changes-" ".dir" in
 Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun()->remove root) (fun()->
  let write name text=let path=Filename.concat root name in mkdir(Filename.dirname path);
   Out_channel.with_open_bin path (fun out->output_string out text);path in
  ignore(write "tesl.toml" "");
  let load revision body =
   Migration_inventory.load ~compiler_abi:"test-abi" ~root_file:(write ("schema/notes/" ^ String.lowercase_ascii revision ^ ".tesl")
     (replace "VCurrent" revision body)) |> get in
  run (load "V1" before) (load "VCurrent" after))
let reports before after=project before after (fun before after->get(M.inspect ~before ~after))
let one before after=match reports before after with
 | [{M.entity="Note";field="payload";codecs=[c]}]->c
 | _ -> fail "expected one stored occurrence and one changed codec"
let unchanged ()=check int "revision normalization and comments" 0
 (List.length(reports source ("# comment\n" ^ source)))
let append ()=
 let c=one source appended in
 check bool "encoder syntax unchanged" false c.encoder_syntax_changed;
 check bool "decoder changed" true c.decoder_alternatives_changed;
 check bool "append preserves prefix" true (c.decoder_order_change=M.Append_only);
 check bool "other bound definitions unchanged" false c.dependency_closure_changed;
 check (option string) "previous identity" (Some "Schema.Notes.V1.Payload") c.previous_codec;
 check (option string) "current identity" (Some "Schema.Notes.VCurrent.Payload") c.current_codec
let order ()=
 let reversed=replace (old_alt ^ " " ^ extra_alt) (extra_alt ^ " " ^ old_alt) appended in
 check bool "priority matters" true ((one appended reversed).decoder_order_change=M.Reordered_or_replaced);
 check bool "removal is observed" true ((one appended source).decoder_order_change=M.Removed);
 let replaced=replace old_alt extra_alt source in
 check bool "replacement is not append" true ((one source replaced).decoder_order_change=M.Reordered_or_replaced)
let encoder ()=
 let changed=replace {|text -> "title"|} {|text -> "bridge"|} source in
 let c=one source changed in
 check bool "encoder changed" true c.encoder_syntax_changed;
 check bool "decoder unchanged" false c.decoder_alternatives_changed;
 check bool "encoder only does not fabricate dependency edit" false c.dependency_closure_changed
let nested ()=
 let nested=replace "record Payload { text: String }" {|record Inner { value: String }
codec Inner {
 toJson { value -> "nested" with_codec stringCodec }
 fromJson [ { value <- "nested" with_codec stringCodec } ]
}
record Payload { text: Inner }|} source
  |> replace "text -> \"title\" with_codec stringCodec" "text -> \"title\" with_codec Inner"
  |> replace "text <- \"title\" with_codec stringCodec" "text <- \"title\" with_codec Inner" in
 let changed=replace {|value -> "nested"|} {|value -> "different"|} nested in
 match reports nested changed with
 | [{M.codecs;_}] ->
  check int "both codecs reached" 2 (List.length codecs);
  let outer=List.find(fun c->c.M.current_codec=Some "Schema.Notes.VCurrent.Payload") codecs in
  check bool "outer encoder syntax unchanged" false outer.encoder_syntax_changed;
  check bool "nested encoder still changes dependency closure" true outer.dependency_closure_changed
 | _ -> fail "missing nested occurrence"
let occurrences ()=
 let add=replace " payload: Payload" " payload: Payload\n backup: Payload" in
 check int "every stored occurrence reported" 2 (List.length(reports (add source) (add appended)))
let semantic_guard ()=project source appended (fun before after->
 let path=Filename.temp_file "tesl-codec-incompatible-" ".tesl" in
 Fun.protect ~finally:(fun()->Sys.remove path) (fun()->
  Out_channel.with_open_bin path(fun out->output_string out appended);
  let incompatible=get(Migration_inventory.load ~compiler_abi:"another-abi" ~root_file:path) in
  (match M.inspect ~before ~after:incompatible with Error _->() | Ok _->fail "incompatible semantic domain admitted");
  ignore after))
let serialization ()=
 let result=reports source appended in
 let json=M.json ~quote:(fun s->Yojson.Basic.to_string (`String s)) result |> Yojson.Basic.from_string in
 let open Yojson.Basic.Util in
 let codec=json |> to_list |> List.hd |> member "codecs" |> to_list |> List.hd in
 check bool "report grants no adapter authority" false (codec |> member "adapterOnlyEligible" |> to_bool);
 check string "stable classification" "append-only" (codec |> member "decoderOrderChange" |> to_string)
let ()=run "read-only codec change observations" ["changes",[
 test_case "unchanged frozen revision" `Quick unchanged;
 test_case "append-only decoder" `Quick append;
 test_case "decoder priority and removal" `Quick order;
 test_case "encoder direction" `Quick encoder;
 test_case "nested dependency closure" `Quick nested;
 test_case "all stored occurrences" `Quick occurrences;
 test_case "semantic domain guard" `Quick semantic_guard;
 test_case "JSON does not grant authority" `Quick serialization]]
