open Alcotest

let vectors () =
  List.iter (fun (input, expected) ->
    check string "SHA-256" expected (Migration_hash.digest input)) [
    "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
    String.make 1_000_000 'a',
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
  ]

let padding_boundaries () =
  (* Independent hashlib/OpenSSL oracle, including NUL/non-ASCII bytes and both
     sides of every padding boundary. No compiler serialization is involved. *)
  let path = Filename.concat (Compile.default_root_path ())
    "compiler/test/fixtures/migration-hash-vectors.txt" in
  let lines = In_channel.with_open_text path In_channel.input_all
    |> String.split_on_char '\n' |> List.filter ((<>) "") in
  check bool "nonempty independent corpus" true (List.length lines >= 130);
  List.iter (fun line ->
    match String.split_on_char ' ' line with
    | [length; expected] ->
      let source = String.init (int_of_string length) (fun i -> Char.chr ((i * 131 + 17) mod 256)) in
      check string ("length " ^ length) expected (Migration_hash.digest source)
    | _ -> failf "bad vector %S" line) lines

(* 64-bit builds hash with native integers, JavaScript builds with Int32; the
   two implementations must agree on every length around the block padding. *)
let portable_and_native_agree () =
  for length = 0 to 300 do
    let source = String.init length (fun i -> Char.chr ((i * 197 + length) mod 256)) in
    check string ("length " ^ string_of_int length)
      (Migration_hash.compute source) (Migration_hash.compute_native source)
  done

(* Hashing pieces equals hashing their concatenation, across block boundaries. *)
let parts_equal_concatenation () =
  let source = String.init 1000 (fun i -> Char.chr ((i * 31 + 7) mod 256)) in
  List.iter (fun cuts ->
    let rec pieces start = function
      | [] -> [String.sub source start (String.length source - start)]
      | cut::rest -> String.sub source start (cut - start) :: pieces cut rest in
    check string (String.concat "," (List.map string_of_int cuts))
      (Migration_hash.digest source) (Migration_hash.digest_parts (pieces 0 cuts)))
    [[]; [0]; [1]; [63]; [64]; [65]; [1;2;3]; [55;56;57]; [64;128;192]; [100;100;700]; [999]; [1000]]

(* The C implementation the CLI installs (SHA extensions when present, portable
   rounds otherwise) agrees with the OCaml one on every padding boundary and on
   large inputs. *)
let c_implementations_agree () =
  let lengths = List.init 300 Fun.id @ [1_000; 4_095; 4_096; 65_537; 1_000_003] in
  List.iter (fun length ->
    let source = String.init length (fun i -> Char.chr ((i * 89 + length * 7) mod 256)) in
    let expected = Migration_hash.compute_native source in
    check string ("portable C, length " ^ string_of_int length) expected (Hash_native.portable source);
    check string ("installed C, length " ^ string_of_int length) expected (Hash_native.sha256_hex source false)) lengths;
  Hash_native.install ();
  check string "installed digest" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (Migration_hash.digest "abc");
  check string "installed parts" (Migration_hash.compute_native "abcdef")
    (Migration_hash.digest_parts ["ab"; "cd"; "ef"])

let () = run "migration-hash" ["SHA-256", [
  test_case "C implementations agree" `Quick c_implementations_agree;
  test_case "pieces hash like their concatenation" `Quick parts_equal_concatenation;
  test_case "portable and native implementations agree" `Quick portable_and_native_agree;
  test_case "published vectors" `Quick vectors;
  test_case "independent binary and padding corpus" `Quick padding_boundaries;
]]
