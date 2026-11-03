open Alcotest

let prefix = {|module FieldScope exposing [extract]
import Tesl.Prelude exposing [String, Bool(..), forgetFact]
fact Trusted (value: String)
record Proven { token: String ::: Trusted token, raw: String }
record Plain { token: String }
fn get(real: Proven) -> Proven = real
fn extract(real: Proven, plain: Plain, choose: Bool) -> value: String ::: Trusted value =
|}

let check valid body () =
 let source=prefix ^ body in
 let diagnostics=(Compile.agent_context_result_source "field-scope.tesl" source).diagnostics
  |> List.filter(fun(d:Compile.diagnostic)->d.severity="error") in
 let description=Compile.diagnostics_to_json diagnostics in
 if valid then Alcotest.check bool description true (diagnostics=[])
 else begin
  Alcotest.check bool description true
   (List.exists(fun(d:Compile.diagnostic)->d.code="V001") diagnostics);
  Alcotest.check bool "negative fixture has no unrelated parse/type/import failure" false
   (List.exists(fun(d:Compile.diagnostic)->d.code<>"V001") diagnostics)
 end

let branch body = " case choose of\n  True ->\n" ^ body ^ "\n  False -> real.token\n"
let ()=run "return field lexical scope" ["carry",[
 test_case "case-local exact receiver" `Quick (check true (branch "   let local = get real\n   local.token"));
 test_case "case-local projection alias" `Quick (check true (branch "   let local = get real\n   let token = local.token\n   token"));
 test_case "nested case local receiver" `Quick (check true (branch "   case choose of\n    True ->\n     let local = get real\n     local.token\n    False -> real.token"));
 test_case "nested branches keep receiver types separate" `Quick (check false (branch "   case choose of\n    True ->\n     let local = get real\n     local.token\n    False ->\n     let local = plain\n     local.token"));
 test_case "unrelated same-named field" `Quick (check false (branch "   let local = plain\n   local.token"));
 test_case "unproved sibling" `Quick (check false (branch "   let local = get real\n   local.raw"));
 test_case "branch shadows proven receiver" `Quick (check false (" let local = real\n" ^ branch "   let local = plain\n   local.token"));
 test_case "proved branch cannot upgrade outer raw receiver" `Quick (check false " let local = plain\n case choose of\n  True ->\n   let local = get real\n   local.token\n  False -> local.token\n");
 test_case "discarded proven projection" `Quick (check false (branch "   let local = get real\n   let ignored = local.token\n   plain.token"));
 test_case "forgotten projection proof" `Quick (check false (branch "   let local = get real\n   let token = forgetFact local.token\n   token"));
]]
