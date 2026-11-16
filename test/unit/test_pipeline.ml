(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_driver

let failures = ref 0

let check name passed =
  if not passed then begin
    Printf.eprintf "FAIL: %s\n" name;
    incr failures
  end

(* The option table. *)

let classified argument (role, separate_values, joined_value) =
  Cc_option.classify argument = { role; separate_values; joined_value }

let () =
  let cases =
    [
      ("-o", (Cc_option.Output, 1, ""));
      ("-ofile", (Output, 0, "file"));
      ("-MF", (Dependency Dependency_file, 1, ""));
      ("-MFdeps", (Dependency Dependency_file, 0, "deps"));
      ("-M", (Refused "", 0, ""));
      ("-fpack-struct", (Refused "", 0, ""));
      ("-fpack-struct=2", (Common, 0, ""));
      ("-std=c11", (Dialect, 0, "c11"));
      ("-std=", (Dialect, 0, ""));
      ("--std", (Dialect, 1, ""));
      ("-fasm", (Keywords Gnu, 0, ""));
      ("-fno-asm", (Keywords Iso, 0, ""));
      ("-x", (Language, 1, ""));
      ("-xc", (Language, 0, "c"));
      ("-I", (Preprocess, 1, ""));
      ("-Iinclude", (Preprocess, 0, "include"));
      ("-undef", (Preprocess, 0, ""));
      ("-lm", (Link, 0, "m"));
      ("-Wl,-rpath,x", (Link, 0, "-rpath,x"));
      ("-Xarch_arm64", (Common, 1, "arm64"));
      ("-Xarch_", (Common, 1, ""));
      ("-sectcreate", (Link, 3, ""));
      ("-e", (Link, 1, ""));
      ("-emit-llvm", (Common, 0, ""));
      ("-object", (Link, 0, ""));
      ("--output=x", (Output, 0, "x"));
      ("--output", (Output, 1, ""));
      ("--include-directory=x", (Preprocess, 0, "x"));
      ("-include-pch", (Preprocess, 1, ""));
      ("-fuse-ld=lld", (Link, 0, "lld"));
      ("-O2", (Common, 0, ""));
      ("--cc=gcc", (Typec Cc, 0, "gcc"));
      ("--cc", (Common, 0, ""));
    ]
  in
  List.iter
    (fun (argument, expected) ->
      let role, _, _ = expected in
      let passed =
        match role with
        | Cc_option.Refused _ -> (
            match Cc_option.classify argument with
            | { role = Refused _; separate_values = 0; _ } -> true
            | _ -> false)
        | _ -> classified argument expected
      in
      check ("classify " ^ argument) passed)
    cases;
  check "a response file is refused"
    (match Cc_option.classify "@args" with
    | { role = Refused _; _ } -> true
    | _ -> false)

(* Reading a command line. *)

let () =
  let arguments =
    Command_line.read
      [ "-o"; "x.tc"; "a.tc"; "-x"; "c"; "b.tc"; "-xnone"; "c.tc"; "-"; "-I" ]
  in
  let inputs =
    List.filter_map
      (function
        | Command_line.Input { path; type_c } -> Some (path, type_c)
        | _ -> None)
      arguments
  in
  check "inputs and their language"
    (inputs
    = [ ("a.tc", true); ("b.tc", false); ("c.tc", true); ("-", false) ]);
  check "an option without its value ends the line"
    (List.rev arguments |> List.hd = Command_line.Truncated [ "-I" ]);
  check "words spell the line"
    (Command_line.words arguments
    = [ "-o"; "x.tc"; "a.tc"; "-x"; "c"; "b.tc"; "-xnone"; "c.tc"; "-"; "-I" ])

(* Planning. *)

let temp_dir = "/T"

(* What every step gets before the options of the command line. *)
let quiet = "-Wno-unused-command-line-argument"

(* What the compile step gets in front of its preprocessed input. *)
let quiet_markers = "-Wno-gnu-line-marker"

let plan ?(emit_c = false) words =
  Pipeline.plan ~program:"cc" ~emit_c ~temp_dir (Command_line.read words)

let planned ?emit_c words =
  match plan ?emit_c words with
  | Ok plan -> plan
  | Error error -> failwith (Pipeline.error_message error)

(* A command for GCC, for which no option is added to the user's. *)
let for_gcc = Option.map (fun (command : Pipeline.command) -> command Gcc)

let only_translation (plan : Pipeline.t) =
  match plan.translations with
  | [ translation ] -> translation
  | _ -> failwith "not one translation"

let () =
  let plan =
    planned [ "-O2"; "-Iinc"; "-DX"; "-c"; "x.tc"; "-o"; "out/x.o"; "-lm" ]
  in
  let translation = only_translation plan in
  check "-c -o: preprocess"
    (translation.preprocess
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-O2"; "-Iinc"; "-DX";
        "-x"; "c"; "x.tc";
      ]);
  check "-c -o: compile"
    (for_gcc translation.compile
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-O2"; "-c"; "-o"; "out/x.o";
          "-x"; "cpp-output"; "/T/1/x.c"; quiet_markers;
        ]);
  check "-c -o: files"
    (translation.directory = "/T/1"
    && translation.preprocessed = "/T/1/preprocessed.i"
    && translation.emitted = File "/T/1/x.c");
  check "-c -o: target options are the compile step's"
    (plan.target_options = [ "-std=gnu17"; quiet; "-O2" ]);
  check "-c -o: no final command" (Option.is_none plan.final)

(* The compile step reads typec's output, which is UTF-8 whatever the
   source's encoding. *)
let () =
  let charset = "-finput-charset=ISO-8859-1" in
  let translation = only_translation (planned [ charset; "-c"; "x.tc" ]) in
  check "-finput-charset: preprocess" (List.mem charset translation.preprocess);
  check "-finput-charset: not compile"
    (for_gcc translation.compile
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-c"; "-o"; "x.o"; "-x"; "cpp-output";
          "/T/1/x.c"; quiet_markers;
        ])

let () =
  let compile words = for_gcc (only_translation (planned words)).compile in
  check "-c without -o"
    (compile [ "-c"; "dir/x.tc" ]
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-c"; "-o"; "x.o"; "-x"; "cpp-output";
          "/T/1/x.c"; quiet_markers;
        ]);
  check "-S"
    (compile [ "-S"; "-c"; "x.tc"; "-std=c17" ]
    = Some
        [
          "cc"; quiet; "-std=c17"; "-S"; "-o"; "x.s"; "-x"; "cpp-output";
          "/T/1/x.c"; quiet_markers;
        ]);
  check "-fsyntax-only"
    (compile [ "-fsyntax-only"; "x.tc"; "-o"; "x" ]
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-fsyntax-only"; "-x"; "cpp-output";
          "/T/1/x.c"; quiet_markers;
        ])

let () =
  let plan = planned [ "x.tc"; "-Iinc"; "y.c"; "-o"; "prog"; "-lm" ] in
  check "link with a .c input"
    (for_gcc plan.final
    = Some [ "cc"; "/T/1.o"; "-Iinc"; "y.c"; "-o"; "prog"; "-lm" ]);
  check "link: compile to the temporary object"
    (for_gcc (only_translation plan).compile
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-c"; "-o"; "/T/1.o"; "-x"; "cpp-output";
          "/T/1/x.c"; quiet_markers;
        ]);
  let plan = planned [ "-Iinc"; "-MD"; "a.tc"; "b.tc"; "-lm" ] in
  check "link .tc inputs only: the final command compiles"
    (for_gcc plan.final
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-x"; "cpp-output"; "/T/1/a.c"; "-x";
          "cpp-output"; "/T/2/b.c"; "-lm"; quiet_markers;
        ]);
  check "link .tc inputs only: no compile step"
    (List.for_all
       (fun (t : Pipeline.translation) -> Option.is_none t.compile)
       plan.translations);
  check "link .tc inputs only: a directory each"
    (List.map (fun (t : Pipeline.translation) -> t.directory) plan.translations
    = [ "/T/1"; "/T/2" ]);
  check "two translations"
    (List.map (fun (t : Pipeline.translation) -> t.source) plan.translations
    = [ "a.tc"; "b.tc" ]);
  check "-c with a .c input"
    (for_gcc (planned [ "-c"; "x.tc"; "y.c"; "-O2" ]).final
    = Some [ "cc"; "-c"; "y.c"; "-O2" ])

(* Clang reads no trigraph in the emitted C, after the user's options;
   GCC reads none there and refuses the option (design 13.2). *)
let () =
  let for_clang =
    Option.map (fun (command : Pipeline.command) -> command Clang)
  in
  let plan = planned [ "-trigraphs"; "-c"; "x.tc" ] in
  check "Clang: compile without trigraphs"
    (for_clang (only_translation plan).compile
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-trigraphs"; "-c"; "-o"; "x.o"; "-x";
          "cpp-output"; "/T/1/x.c"; quiet_markers; "-fno-trigraphs";
        ]);
  check "Clang: the final command compiles without trigraphs"
    (for_clang (planned [ "x.tc" ]).final
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-x"; "cpp-output"; "/T/1/x.c";
          quiet_markers; "-fno-trigraphs";
        ]);
  let plan = planned [ "x.tc"; "y.c" ] in
  check "Clang: the final command that links objects is the same"
    (for_clang plan.final = for_gcc plan.final)

let () =
  let preprocess words = (only_translation (planned words)).preprocess in
  check "-MD names the file and target after -o"
    (preprocess [ "-MD"; "-c"; "x.tc"; "-o"; "out/x.o" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-MD"; "-MF";
        "out/x.d";
        "-MQ"; "out/x.o"; "-x"; "c"; "x.tc";
      ]);
  check "-MMD names the file and target after the input"
    (preprocess [ "-MMD"; "-MP"; "-c"; "dir/x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-MMD"; "-MP"; "-MF";
        "x.d"; "-MQ"; "x.o"; "-x"; "c"; "dir/x.tc";
      ]);
  check "-MF and -MT are kept"
    (preprocess [ "-MD"; "-MF"; "d"; "-MTt"; "-c"; "x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-MD"; "-MF"; "d";
        "-MTt";
        "-x"; "c"; "x.tc";
      ]);
  check "-MF without -MD adds nothing"
    (preprocess [ "-MF"; "d"; "-c"; "x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-MF"; "d"; "-x"; "c";
        "x.tc";
      ])

let () =
  let emitted words = (only_translation (planned ~emit_c:true words)).emitted in
  check "--emit-c to stdout" (emitted [ "x.tc" ] = Standard_output);
  check "--emit-c to -o" (emitted [ "x.tc"; "-o"; "x.c" ] = File "x.c");
  check "--emit-c compiles nothing"
    (let plan = planned ~emit_c:true [ "x.tc" ] in
     Option.is_none (only_translation plan).compile
     && Option.is_none plan.final);
  check "--emit-c target options"
    ((planned ~emit_c:true [ "-m32"; "-std=c11"; "x.tc" ]).target_options
    = [ quiet; "-m32"; "-std=c11" ])

let () =
  let fails words error = plan words = Error error in
  let refused words =
    match plan words with
    | Error (Refused_option _) -> true
    | _ -> false
  in
  check "-std=c99" (fails [ "-std=c99"; "x.tc" ] (Unaccepted_standard "c99"));
  check "the last -std= counts"
    (Result.is_ok (plan [ "-std=c99"; "-std=c11"; "x.tc" ]));
  check "--emit-c -o - is stdout"
    ((only_translation (planned ~emit_c:true [ "x.tc"; "-o"; "-" ])).emitted
    = Standard_output);
  check "-E" (refused [ "-E"; "x.tc" ]);
  check "-P" (refused [ "x.tc"; "-P" ]);
  check "@file" (refused [ "x.tc"; "@args" ]);
  check "-o without a value" (fails [ "x.tc"; "-o" ] (Missing_value "-o"));
  check "-o with -c and two inputs"
    (fails [ "-c"; "x.tc"; "y.c"; "-o"; "x.o" ] Output_for_several_inputs);
  check "--emit-c with two inputs"
    (plan ~emit_c:true [ "x.tc"; "y.tc" ] = Error Emit_c_inputs);
  check "--emit-c with a .c input"
    (plan ~emit_c:true [ "y.c" ] = Error Emit_c_inputs);
  check "a .tc input after -x c is not one"
    (not (Pipeline.has_type_c_input (Command_line.read [ "-x"; "c"; "x.tc" ])))

(* The keywords are those of the last -std=, else of gnu17, unless the
   last -fasm or -fno-asm overrides them wherever it stands, as in GCC
   and Clang. *)
let () =
  let keywords words = (only_translation (planned words)).dialect in
  check "gnu17 by default" (keywords [ "x.tc" ] = Gnu);
  check "-std=c11" (keywords [ "-std=c11"; "x.tc" ] = Iso);
  check "--std iso9899:2018"
    (keywords [ "--std"; "iso9899:2018"; "x.tc" ] = Iso);
  check "-std=gnu17" (keywords [ "-std=gnu17"; "x.tc" ] = Gnu);
  check "the last -std= decides"
    (keywords [ "-std=gnu11"; "-std=c17"; "x.tc" ] = Iso);
  check "-fasm in ISO C" (keywords [ "-std=c11"; "-fasm"; "x.tc" ] = Gnu);
  check "-fno-asm before -std=gnu11"
    (keywords [ "-fno-asm"; "-std=gnu11"; "x.tc" ] = Iso);
  check "the last of -fasm and -fno-asm decides"
    (keywords [ "-fno-asm"; "-fasm"; "x.tc" ] = Gnu);
  check "-fasm with an unaccepted standard"
    (plan [ "-fasm"; "-std=c99"; "x.tc" ] = Error (Unaccepted_standard "c99"))

let () = if !failures > 0 then exit 1
