(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_driver

(* A command line and the backend program and arguments it must yield. *)
type case = {
  name : string;
  env_cc : string option;
  arguments : string list;
  expected : (string * string list, Invocation.error) result;
}

let cases =
  [
    {
      name = "default backend, arguments kept";
      env_cc = None;
      arguments = [ "-c"; "a.c"; "-o"; "a.o" ];
      expected = Ok ("cc", [ "-c"; "a.c"; "-o"; "a.o" ]);
    };
    {
      name = "no arguments";
      env_cc = None;
      arguments = [];
      expected = Ok ("cc", []);
    };
    {
      name = "TYPEC_CC beats the default";
      env_cc = Some "gcc";
      arguments = [ "a.c" ];
      expected = Ok ("gcc", [ "a.c" ]);
    };
    {
      name = "empty TYPEC_CC counts as unset";
      env_cc = Some "";
      arguments = [ "a.c" ];
      expected = Ok ("cc", [ "a.c" ]);
    };
    {
      name = "--cc= beats TYPEC_CC and is removed where it stands";
      env_cc = Some "gcc";
      arguments = [ "-c"; "--cc=/opt/clang"; "a.c" ];
      expected = Ok ("/opt/clang", [ "-c"; "a.c" ]);
    };
    {
      name = "the last --cc= wins";
      env_cc = None;
      arguments = [ "--cc=gcc"; "a.c"; "--cc=clang" ];
      expected = Ok ("clang", [ "a.c" ]);
    };
    {
      name = "look-alikes of --cc= are forwarded";
      env_cc = None;
      arguments = [ "--cc"; "gcc"; "-cc=x"; "--ccx=y"; "a --cc=b" ];
      expected = Ok ("cc", [ "--cc"; "gcc"; "-cc=x"; "--ccx=y"; "a --cc=b" ]);
    };
    {
      name = "an empty argument is forwarded";
      env_cc = None;
      arguments = [ "-c"; ""; "a.c" ];
      expected = Ok ("cc", [ "-c"; ""; "a.c" ]);
    };
    {
      name = "a path keeps its spaces and equals signs";
      env_cc = None;
      arguments = [ "--cc=/my tools/c=c" ];
      expected = Ok ("/my tools/c=c", []);
    };
    {
      name = "--cc= without a path is an error";
      env_cc = Some "gcc";
      arguments = [ "--cc=clang"; "--cc=" ];
      expected = Error Invocation.Empty_cc_option;
    };
    {
      name = "--cc= without a path is an error before a later --cc=";
      env_cc = None;
      arguments = [ "--cc="; "--cc=clang" ];
      expected = Error Invocation.Empty_cc_option;
    };
  ]

let outcome case =
  Invocation.of_command_line ~env_cc:case.env_cc case.arguments
  |> Result.map (fun (invocation : Invocation.t) ->
         (invocation.program, invocation.arguments))

let () =
  let failed = List.filter (fun case -> outcome case <> case.expected) cases in
  List.iter (fun case -> Printf.eprintf "FAIL: %s\n" case.name) failed;
  if failed <> [] then exit 1
