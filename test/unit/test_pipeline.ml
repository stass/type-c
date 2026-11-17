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
  let option = Cc_option.classify argument in
  option.role = role
  && option.separate_values = separate_values
  && option.joined_value = joined_value

let () =
  let cases =
    [
      ("-o", (Cc_option.Output, 1, ""));
      ("-ofile", (Output, 0, "file"));
      ("-MF", (Dependency Dependency_file, 1, ""));
      ("-MFdeps", (Dependency Dependency_file, 0, "deps"));
      ("-M", (Dependency Print_rule, 0, ""));
      ("-MM", (Dependency Print_rule, 0, ""));
      ("--dependencies", (Dependency Print_rule, 0, ""));
      ("--user-dependencies", (Dependency Print_rule, 0, ""));
      ("--write-dependencies", (Dependency Write_dependencies, 0, ""));
      ("--write-user-dependencies", (Dependency Write_dependencies, 0, ""));
      ("--print-missing-file-dependencies",
        (Dependency Dependency_detail, 0, ""));
      ("-E", (Refused "", 0, ""));
      ("-fpack-struct", (Refused "", 0, ""));
      ("-fpack-struct=2", (Common, 0, ""));
      ("-fshort-enums", (Common, 0, ""));
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
      (* A long option that the table lacks is refused: GCC reads an
         abbreviation of a long option as that option and any other
         --NAME as -fNAME. *)
      ("--cc", (Refused "", 0, ""));
      ("--emit", (Refused "", 0, ""));
      ("--preprocess", (Refused "", 0, ""));
      ("--ansi", (Refused "", 0, ""));
      ("--write-user-dep", (Refused "", 0, ""));
      ("--short-enums", (Refused "", 0, ""));
      ("--syntax-only", (Refused "", 0, ""));
      ("--output-x", (Refused "", 0, ""));
      ("--target=x86_64-linux-gnu", (Common, 0, "x86_64-linux-gnu"));
      ("--gcc-toolchain=/usr", (Common, 0, "/usr"));
      ("--coverage", (Common, 0, ""));
      ("--sysroot=/", (Common, 0, "/"));
      ("--gcc-install-dir=/usr", (Common, 0, "/usr"));
      ("--embed-dir=data", (Preprocess, 0, "data"));
      ("--unwindlib=libgcc", (Link, 0, "libgcc"));
      ("--target", (Refused "", 0, ""));
      ("--include-dir=x", (Refused "", 0, ""));
      (* GCC reads --dump as -d. Every -d form is refused, as the letters
         after -d select dumps and -dD, -dM and -dI change the
         preprocessed text; the options spelled with -d that name
         something else pass. *)
      ("--dump=M", (Refused "", 0, ""));
      ("--dump", (Refused "", 1, ""));
      ("-d", (Refused "", 0, ""));
      ("-dD", (Refused "", 0, ""));
      ("-dI", (Refused "", 0, ""));
      ("-dDI", (Refused "", 0, ""));
      ("-dA", (Refused "", 0, ""));
      ("-dumpbasex", (Refused "", 0, ""));
      ("-dumpbase", (Common, 1, ""));
      ("-dumpdir", (Common, 1, ""));
      ("-dumpbase-ext", (Common, 1, ""));
      ("-dsym-dir", (Common, 1, ""));
      ("-dsym-dirx", (Common, 0, "x"));
      ("-darwin-target-variant", (Common, 1, ""));
      ("-darwin-target-variant-triple", (Common, 1, ""));
      ("-dependency-dot", (Preprocess, 1, ""));
      ("-dylib_file", (Link, 1, ""));
      ("-dylinker_install_name", (Link, 1, ""));
      ("-dylinker_install_namex", (Link, 0, "x"));
      ("-dependency-file", (Preprocess, 1, ""));
      ("-dynamiclib", (Link, 0, ""));
      ("-dead_strip", (Link, 0, ""));
      ("-dynamic", (Link, 0, ""));
      ("-dylinker", (Link, 0, ""));
      (* A file of further options can add any option to every step. *)
      ("-specs", (Refused "", 1, ""));
      ("-specs=my.specs", (Refused "", 0, ""));
      ("--specs", (Refused "", 1, ""));
      ("--specs=my.specs", (Refused "", 0, ""));
      ("--config", (Refused "", 1, ""));
      ("--config=my.cfg", (Refused "", 0, ""));
      ("--config-user-dir=.", (Refused "", 0, ""));
      ("--config-system-dir=.", (Refused "", 0, ""));
      ("--no-default-config", (Common, 0, ""));
      (* A query prints its answer and compiles nothing. *)
      ("-print-file-name=libc.a", (Refused "", 0, ""));
      ("--print-file-name=libc.a", (Refused "", 0, ""));
      ("--print-file-name", (Refused "", 1, ""));
      ("-print-prog-name=ld", (Refused "", 0, ""));
      ("--print-prog-name=ld", (Refused "", 0, ""));
      ("--print-prog-name", (Refused "", 1, ""));
      ("-print-search-dirs", (Refused "", 0, ""));
      ("--print-search-dirs", (Refused "", 0, ""));
      ("-print-target-triple", (Refused "", 0, ""));
      ("-dumpmachine", (Refused "", 0, ""));
      ("-dumpversion", (Refused "", 0, ""));
      ("--print-target", (Typec Print_target, 0, ""));
    ]
  in
  List.iter
    (fun (argument, expected) ->
      let role, separate_values, _ = expected in
      let passed =
        match role with
        | Cc_option.Refused _ -> (
            match Cc_option.classify argument with
            | { role = Refused _; separate_values = values; _ } ->
                values = separate_values
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

(* An option passed on to a later step is refused when it is a dump
   (design 13.2); the role of each argument of [words]. *)
let () =
  let roles words =
    List.map
      (function
        | Command_line.Option { role = Cc_option.Refused _; _ } -> "refused"
        | Option _ -> "passed"
        | Input _ | Truncated _ -> "other")
      (Command_line.read words)
  in
  let refused = [ "refused" ] and passed = [ "passed" ] in
  check "-Wp,-dD" (roles [ "-Wp,-dD" ] = refused);
  check "-Wp, with a dump after a comma" (roles [ "-Wp,-MD,-dM" ] = refused);
  check "-Xpreprocessor -dU" (roles [ "-Xpreprocessor"; "-dU" ] = refused);
  check "-Xclang -dI" (roles [ "-Xclang"; "-dI" ] = refused);
  check "-Wp,-P passes, for the reader" (roles [ "-Wp,-P" ] = passed);
  check "-Xpreprocessor -dependency-file, which is no dump"
    (roles [ "-Xpreprocessor"; "-dependency-file" ] = passed);
  check "-Xassembler -dD, which no preprocessor reads"
    (roles [ "-Xassembler"; "-dD" ] = passed);
  check "a dump as the value of an option that passes none on"
    (roles [ "-o"; "-dD" ] = passed)

(* Planning. *)

let temp_dir = "/T"

(* What Clang's steps and the target query get before the options of
   the command line. *)
let quiet = "-Wno-unused-command-line-argument"

let plan ?(emit_c = false) words =
  Pipeline.plan ~program:"cc" ~emit_c ~temp_dir (Command_line.read words)

let planned ?emit_c words =
  match plan ?emit_c words with
  | Ok plan -> plan
  | Error error -> failwith (Pipeline.error_message error)

(* A command for GCC, which gets no option of typec's own. *)
let for_gcc = Option.map (fun (command : Pipeline.command) -> command Gcc)

let finals_for_gcc (plan : Pipeline.t) =
  List.map (fun (command : Pipeline.command) -> command Gcc) plan.finals

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
    (translation.preprocess Gcc
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-O2"; "-Iinc"; "-DX";
        "-dD"; "-x"; "c"; "x.tc";
      ]);
  check "-c -o: compile"
    (for_gcc translation.compile
    = Some
        [
          "cc"; "-std=gnu17"; "-O2"; "-c"; "-o"; "out/x.o";
          "-x"; "cpp-output"; "/T/1/x.c";
        ]);
  check "-c -o: files"
    (translation.directory = "/T/1"
    && translation.preprocessed = "/T/1/preprocessed.i"
    && translation.emitted = File "/T/1/x.c");
  check "-c -o: target options are the compile step's"
    (plan.target_options = [ "-std=gnu17"; quiet; "-O2" ]);
  check "-c -o: no final command" (plan.finals = [])

(* The compile step reads typec's output, which is UTF-8 whatever the
   source's encoding. *)
let () =
  let charset = "-finput-charset=ISO-8859-1" in
  let translation = only_translation (planned [ charset; "-c"; "x.tc" ]) in
  check "-finput-charset: preprocess" (List.mem charset (translation.preprocess Gcc));
  check "-finput-charset: not compile"
    (for_gcc translation.compile
    = Some
        [
          "cc"; "-std=gnu17"; "-c"; "-o"; "x.o"; "-x"; "cpp-output";
          "/T/1/x.c";
        ])

let () =
  let compile words = for_gcc (only_translation (planned words)).compile in
  check "-c without -o"
    (compile [ "-c"; "dir/x.tc" ]
    = Some
        [
          "cc"; "-std=gnu17"; "-c"; "-o"; "x.o"; "-x"; "cpp-output";
          "/T/1/x.c";
        ]);
  check "-S"
    (compile [ "-S"; "-c"; "x.tc"; "-std=c17" ]
    = Some
        [
          "cc"; "-std=c17"; "-S"; "-o"; "x.s"; "-x"; "cpp-output";
          "/T/1/x.c";
        ]);
  check "-fsyntax-only"
    (compile [ "-fsyntax-only"; "x.tc"; "-o"; "x" ]
    = Some
        [
          "cc"; "-std=gnu17"; "-fsyntax-only"; "-x"; "cpp-output";
          "/T/1/x.c";
        ])

let () =
  let plan = planned [ "x.tc"; "-Iinc"; "y.c"; "-o"; "prog"; "-lm" ] in
  check "link with a .c input"
    (finals_for_gcc plan
    = [ [ "cc"; "/T/1.o"; "-Iinc"; "y.c"; "-o"; "prog"; "-lm" ] ]);
  check "link: compile to the temporary object"
    (for_gcc (only_translation plan).compile
    = Some
        [
          "cc"; "-std=gnu17"; "-c"; "-o"; "/T/1.o"; "-x"; "cpp-output";
          "/T/1/x.c";
        ]);
  let plan = planned [ "-Iinc"; "-MD"; "a.tc"; "b.tc"; "-lm" ] in
  check "link .tc inputs only: the final command compiles"
    (finals_for_gcc plan
    = [
        [
          "cc"; "-std=gnu17"; "-x"; "cpp-output"; "/T/1/a.c"; "-x";
          "cpp-output"; "/T/2/b.c"; "-lm";
        ];
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
    (finals_for_gcc (planned [ "-c"; "x.tc"; "y.c"; "-O2" ])
    = [ [ "cc"; "-c"; "y.c"; "-O2" ] ])

(* Clang's steps quiet its warning about unused options, which GCC does
   not know. Clang reads no trigraph in the emitted C, after the user's
   options; GCC reads none there and refuses the option (design 13.2). *)
let () =
  let for_clang =
    Option.map (fun (command : Pipeline.command) -> command Clang)
  in
  let finals_for_clang (plan : Pipeline.t) =
    List.map (fun (command : Pipeline.command) -> command Clang) plan.finals
  in
  let plan = planned [ "-trigraphs"; "-c"; "x.tc" ] in
  check "Clang: preprocess quiets unused options"
    ((only_translation plan).preprocess Clang
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; quiet; "-trigraphs";
        "-dD"; "-x"; "c"; "x.tc";
      ]);
  check "Clang: compile without trigraphs"
    (for_clang (only_translation plan).compile
    = Some
        [
          "cc"; "-std=gnu17"; quiet; "-trigraphs"; "-c"; "-o"; "x.o"; "-x";
          "cpp-output"; "/T/1/x.c"; "-fno-trigraphs";
        ]);
  check "Clang: the final command compiles without trigraphs"
    (finals_for_clang (planned [ "x.tc" ])
    = [
        [
          "cc"; "-std=gnu17"; quiet; "-x"; "cpp-output"; "/T/1/x.c";
          "-fno-trigraphs";
        ];
      ]);
  let plan = planned [ "x.tc"; "y.c" ] in
  check "Clang: the final command that links objects is the same"
    (finals_for_clang plan = finals_for_gcc plan)

let () =
  let preprocess words = (only_translation (planned words)).preprocess Gcc in
  check "-MD names the file and target after -o"
    (preprocess [ "-MD"; "-c"; "x.tc"; "-o"; "out/x.o" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-MD"; "-dD"; "-MF";
        "out/x.d";
        "-MQ"; "out/x.o"; "-x"; "c"; "x.tc";
      ]);
  check "-MMD names the file and target after the input"
    (preprocess [ "-MMD"; "-MP"; "-c"; "dir/x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-MMD"; "-MP"; "-dD";
        "-MF"; "x.d"; "-MQ"; "x.o"; "-x"; "c"; "dir/x.tc";
      ]);
  check "-MF and -MT are kept"
    (preprocess [ "-MD"; "-MF"; "d"; "-MTt"; "-c"; "x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-MD"; "-MF"; "d";
        "-MTt"; "-dD";
        "-x"; "c"; "x.tc";
      ]);
  check "-MF without -MD adds nothing"
    (preprocess [ "-MF"; "d"; "-c"; "x.tc" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-MF"; "d"; "-dD"; "-x";
        "c"; "x.tc";
      ]);
  check "--write-dependencies is -MD"
    (preprocess [ "--write-dependencies"; "-c"; "x.tc"; "-o"; "x.o" ]
    = [
        "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "--write-dependencies";
        "-dD"; "-MF"; "x.d"; "-MQ"; "x.o"; "-x"; "c"; "x.tc";
      ]);
  let plan = planned [ "--write-user-dependencies"; "-c"; "x.tc" ] in
  check "--write-user-dependencies: not compile or the target query"
    (for_gcc (only_translation plan).compile
     = Some
         [
           "cc"; "-std=gnu17"; "-c"; "-o"; "x.o"; "-x"; "cpp-output";
           "/T/1/x.c";
         ]
    && plan.target_options = [ "-std=gnu17"; quiet ])

(* With -M or -MM the -E step of each .tc input prints its rule where -o
   says, and the other inputs get the command line without the .tc
   ones. *)
let () =
  let printed = planned [ "-MM"; "-MP"; "-Iinc"; "-c"; "x.tc" ] in
  check "-MM: no translation" (printed.translations = []);
  check "-MM: the -E step prints the rule"
    (finals_for_gcc printed
    = [
        [
          "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-MM"; "-MP"; "-Iinc";
          "-x"; "c"; "x.tc";
        ];
      ]);
  check "-M -o: the rule goes to the file"
    (finals_for_gcc (planned [ "-M"; "x.tc"; "-o"; "x.d" ])
    = [
        [
          "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-M"; "-o"; "x.d"; "-x";
          "c"; "x.tc";
        ];
      ]);
  check "-M -MD: the backend names the file and target"
    (finals_for_gcc (planned [ "-M"; "-MD"; "x.tc"; "-o"; "x.d" ])
    = [
        [
          "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-M"; "-MD"; "-o"; "x.d";
          "-x"; "c"; "x.tc";
        ];
      ]);
  check "-M: the other inputs follow"
    (finals_for_gcc (planned [ "-M"; "x.tc"; "-DX"; "y.c" ])
    = [
        [
          "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17"; "-M"; "-DX"; "-x"; "c";
          "x.tc";
        ];
        [ "cc"; "-M"; "-DX"; "y.c" ];
      ]);
  check "-M -o with two inputs"
    (plan [ "-M"; "x.tc"; "y.c"; "-o"; "deps" ]
    = Error Output_for_several_inputs);
  check "--emit-c with -MM"
    (plan ~emit_c:true [ "-MM"; "x.tc" ] = Error Emit_c_rules)

let () =
  let emitted words = (only_translation (planned ~emit_c:true words)).emitted in
  check "--emit-c to stdout" (emitted [ "x.tc" ] = Standard_output);
  check "--emit-c to -o" (emitted [ "x.tc"; "-o"; "x.c" ] = File "x.c");
  check "--emit-c compiles nothing"
    (let plan = planned ~emit_c:true [ "x.tc" ] in
     Option.is_none (only_translation plan).compile
     && plan.finals = []);
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
  check "--preprocess" (refused [ "--preprocess"; "x.tc" ]);
  check "-specs" (refused [ "-specs"; "my.specs"; "x.tc" ]);
  check "--config=" (refused [ "x.tc"; "--config=my.cfg" ]);
  check "-dDI" (refused [ "-dDI"; "x.tc" ]);
  check "--print-file-name=" (refused [ "--print-file-name=libc.a"; "x.tc" ]);
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

(* --emit-c-header with the dependency options: what is written, and the
   dependency options of the -E step, which follow its own. *)
let () =
  let plan_header words =
    Pipeline.plan_header ~program:"cc" ~temp_dir (Command_line.read words)
  in
  let planned_header words =
    match plan_header words with
    | Ok header -> header
    | Error error -> failwith (Pipeline.error_message error)
  in
  let output words = (planned_header words).output in
  let step words = (planned_header words).interface.preprocess Gcc in
  let step_for options input =
    [ "cc"; "-E"; "-D__TYPEC__=1"; "-std=gnu17" ]
    @ options
    @ [ "-x"; "c"; input ]
  in
  let own = [ "-dD"; "-dI"; "-Wno-unused-macros" ] in
  let written = "/T/0/rule.d" in
  check "header: no rule" (output [ "m.tci" ] = Header);
  check "header: -MD beside the header"
    (output [ "-MD"; "d/m.tci" ]
    = Header_and_rule { written; destination = File "d/m.h.d" });
  check "header: -MMD beside the -o header"
    (output [ "-MMD"; "m.tci"; "-o"; "o/x.h" ]
    = Header_and_rule { written; destination = File "o/x.h.d" });
  check "header: the last -MF"
    (output [ "-MD"; "-MF"; "a.d"; "-MFb.d"; "m.tci" ]
    = Header_and_rule { written; destination = File "b.d" });
  check "header: -MD -MF - -MT -o -"
    (output [ "-MD"; "-MF"; "-"; "-MT"; "t"; "m.tci"; "-o"; "-" ]
    = Header_and_rule { written; destination = Standard_output });
  check "header: -M to stdout"
    (output [ "-M"; "m.tci" ]
    = Rule { written; destination = Standard_output });
  check "header: -M -MD prints the rule"
    (output [ "-M"; "-MD"; "m.tci" ]
    = Rule { written; destination = Standard_output });
  check "header: -M -MF -"
    (output [ "-M"; "-MF"; "-"; "m.tci" ]
    = Rule { written; destination = Standard_output });
  check "header: -M: -MF for the step, the header as target"
    (step [ "-M"; "m.tci" ]
    = step_for ([ "-M" ] @ own @ [ "-MF"; written; "-MQ"; "m.h" ]) "m.tci");
  check "header: -MM -MF"
    (output [ "-MM"; "-MF"; "r.d"; "m.tci" ]
    = Rule { written; destination = File "r.d" });
  check "header: -M -o"
    (plan_header [ "-M"; "m.tci"; "-o"; "m.d" ] = Error Header_rule_output);
  check "header: -MM -o -"
    (plan_header [ "-MM"; "m.tci"; "-o"; "-" ] = Error Header_rule_output);
  check "header: -MD -o - without a target"
    (plan_header [ "-MD"; "-MF"; "m.d"; "m.tci"; "-o"; "-" ]
    = Error Header_rule_names);
  check "header: -MMD -o - without a file"
    (plan_header [ "-MMD"; "-MQ"; "m.h"; "m.tci"; "-o"; "-" ]
    = Error Header_rule_names);
  check "header: -MD -MP: -MF for the step, the header as target"
    (step [ "-MD"; "-MP"; "-MF"; "m.d"; "d/m.tci" ]
    = step_for
        ([ "-MD"; "-MP" ] @ own @ [ "-MF"; written; "-MQ"; "d/m.h" ])
        "d/m.tci");
  check "header: -MT names the target"
    (step [ "-MMD"; "-MT"; "t"; "m.tci" ]
    = step_for ([ "-MMD"; "-MT"; "t" ] @ own @ [ "-MF"; written ]) "m.tci");
  check "header: without a rule, the options as given"
    (step [ "-MP"; "-MF"; "m.d"; "m.tci" ]
    = step_for ([ "-MP"; "-MF"; "m.d" ] @ own) "m.tci")

let () = if !failures > 0 then exit 1
