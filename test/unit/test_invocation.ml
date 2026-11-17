(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_driver

(* A command line and the backend program and arguments it must yield. *)
type case = {
  name : string;
  env_cc : string option;
  arguments : string list;
  expected :
    (string * string list * Invocation.action, Invocation.error) result;
}

let cases =
  [
    {
      name = "default backend, arguments kept";
      env_cc = None;
      arguments = [ "-c"; "a.c"; "-o"; "a.o" ];
      expected = Ok ("cc", [ "-c"; "a.c"; "-o"; "a.o" ], Compile);
    };
    {
      name = "no arguments";
      env_cc = None;
      arguments = [];
      expected = Ok ("cc", [], Compile);
    };
    {
      name = "TYPEC_CC beats the default";
      env_cc = Some "gcc";
      arguments = [ "a.c" ];
      expected = Ok ("gcc", [ "a.c" ], Compile);
    };
    {
      name = "empty TYPEC_CC counts as unset";
      env_cc = Some "";
      arguments = [ "a.c" ];
      expected = Ok ("cc", [ "a.c" ], Compile);
    };
    {
      name = "--cc= beats TYPEC_CC and is removed where it stands";
      env_cc = Some "gcc";
      arguments = [ "-c"; "--cc=/opt/clang"; "a.c" ];
      expected = Ok ("/opt/clang", [ "-c"; "a.c" ], Compile);
    };
    {
      name = "the last --cc= wins";
      env_cc = None;
      arguments = [ "--cc=gcc"; "a.c"; "--cc=clang" ];
      expected = Ok ("clang", [ "a.c" ], Compile);
    };
    {
      name = "look-alikes of --cc= are forwarded";
      env_cc = None;
      arguments = [ "--cc"; "gcc"; "-cc=x"; "--ccx=y"; "a --cc=b" ];
      expected =
        Ok ("cc", [ "--cc"; "gcc"; "-cc=x"; "--ccx=y"; "a --cc=b" ], Compile);
    };
    {
      name = "an empty argument is forwarded";
      env_cc = None;
      arguments = [ "-c"; ""; "a.c" ];
      expected = Ok ("cc", [ "-c"; ""; "a.c" ], Compile);
    };
    {
      name = "a path keeps its spaces and equals signs";
      env_cc = None;
      arguments = [ "--cc=/my tools/c=c" ];
      expected = Ok ("/my tools/c=c", [], Compile);
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
    {
      name = "--print-target is removed wherever it stands";
      env_cc = None;
      arguments = [ "-m32"; "--print-target"; "--cc=gcc"; "-funsigned-char" ];
      expected = Ok ("gcc", [ "-m32"; "-funsigned-char" ], Print_target);
    };
    {
      name = "--print-target twice";
      env_cc = None;
      arguments = [ "--print-target"; "-m32"; "--print-target" ];
      expected = Ok ("cc", [ "-m32" ], Print_target);
    };
    {
      name = "look-alikes of --print-target are forwarded";
      env_cc = None;
      arguments = [ "--print-target=x"; "-print-target"; "--print-targets" ];
      expected =
        Ok
          ( "cc",
            [ "--print-target=x"; "-print-target"; "--print-targets" ],
            Compile );
    };
    {
      name = "an option value is never a typec option";
      env_cc = None;
      arguments = [ "-o"; "--cc=x"; "-MF"; "--emit-c"; "--cc=gcc" ];
      expected = Ok ("gcc", [ "-o"; "--cc=x"; "-MF"; "--emit-c" ], Compile);
    };
    {
      name = "--emit-c";
      env_cc = None;
      arguments = [ "--emit-c"; "x.tc"; "--emit-c" ];
      expected = Ok ("cc", [ "x.tc" ], Emit_c);
    };
    {
      name = "--print-target beats --emit-c";
      env_cc = None;
      arguments = [ "--emit-c"; "--print-target" ];
      expected = Ok ("cc", [], Print_target);
    };
    {
      name = "--cc= without a path is an error with --print-target";
      env_cc = None;
      arguments = [ "--print-target"; "--cc=" ];
      expected = Error Invocation.Empty_cc_option;
    };
    {
      name = "--version beats every other action";
      env_cc = None;
      arguments = [ "--emit-c"; "--print-target"; "--version"; "x.tc" ];
      expected = Ok ("cc", [ "x.tc" ], Print_version);
    };
    {
      name = "look-alikes of --version are forwarded";
      env_cc = None;
      arguments = [ "-version"; "-v" ];
      expected = Ok ("cc", [ "-version"; "-v" ], Compile);
    };
    {
      name = "--cc= without a path is an error with --version";
      env_cc = None;
      arguments = [ "--version"; "--cc=" ];
      expected = Error Invocation.Empty_cc_option;
    };
  ]

let outcome case =
  Invocation.of_command_line ~env_cc:case.env_cc case.arguments
  |> Result.map (fun (invocation : Invocation.t) ->
         ( invocation.program,
           Command_line.words invocation.arguments,
           invocation.action ))

(* A command line and the definition that its trap writes after a unit,
   or the error it gives: the trap is seen through what it writes. *)
let trap_cases =
  let calling name =
    Ok
      [ "static inline _Noreturn void __tc_trap(void) { _Noreturn void "
        ^ name ^ "(void); " ^ name ^ "(); __builtin_trap(); }" ]
  in
  [
    ("no --trap-function", [ "-c"; "x.tc" ], Ok []);
    ("--trap-function=", [ "--trap-function=stop"; "x.tc" ], calling "stop");
    ( "the last --trap-function= wins",
      [ "--trap-function=first"; "--trap-function=_Stop9" ],
      calling "_Stop9" );
    ( "an invalid --trap-function= before a valid one",
      [ "--trap-function=1x"; "--trap-function=stop" ],
      Error (Invocation.Invalid_trap_function "1x") );
    ( "a name with a leading digit",
      [ "--trap-function=1x" ],
      Error (Invocation.Invalid_trap_function "1x") );
    ( "a name with other text",
      [ "--trap-function=f(); g" ],
      Error (Invocation.Invalid_trap_function "f(); g") );
    ( "a name outside ASCII",
      [ "--trap-function=caf\xc3\xa9" ],
      Error (Invocation.Invalid_trap_function "caf\xc3\xa9") );
    ( "no name",
      [ "--trap-function=" ],
      Error (Invocation.Invalid_trap_function "") );
  ]

let trap_outcome arguments =
  Invocation.of_command_line ~env_cc:None arguments
  |> Result.map (fun (invocation : Invocation.t) ->
         Typec_emit.Trap.definition invocation.trap)

let () =
  let failed = List.filter (fun case -> outcome case <> case.expected) cases in
  List.iter (fun case -> Printf.eprintf "FAIL: %s\n" case.name) failed;
  let failed_traps =
    List.filter
      (fun (_, arguments, expected) -> trap_outcome arguments <> expected)
      trap_cases
  in
  List.iter (fun (name, _, _) -> Printf.eprintf "FAIL: %s\n" name)
    failed_traps;
  if failed <> [] || failed_traps <> [] then exit 1
