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

let () = run "migration-hash" ["SHA-256", [
  test_case "published vectors" `Quick vectors;
  test_case "independent binary and padding corpus" `Quick padding_boundaries;
]]
