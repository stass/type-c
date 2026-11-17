(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

type destination = File of string | Standard_output

type command = Target.compiler -> string list

type translation = {
  source : string;
  directory : string;
  preprocess : command;
  preprocessed : string;
  dialect : Typec_syntax.Keyword_set.dialect;
  emitted : destination;
  compile : command option;
}

type t = {
  target_options : string list;
  translations : translation list;
  finals : command list;
}

type error =
  | Refused_option of { option : string; reason : string }
  | Unaccepted_standard of string
  | Missing_value of string
  | Output_for_several_inputs
  | Emit_c_inputs
  | Emit_c_rules
  | Several_architectures of string list
  | Header_inputs
  | Header_stops
  | Header_rule_output
  | Header_rule_names
  | Header_name of string

(* Raised at the first reason the command line has no pipeline and
   caught in plan. *)
exception Failed of error

(* C11 and C17 in ISO and GNU form, under every name that GCC and Clang
   give them, and the dialect of the keywords of each form (design 2.4). *)
let accepted_standards : (string * Typec_syntax.Keyword_set.dialect) list =
  [
    ("c11", Iso); ("c1x", Iso); ("iso9899:2011", Iso); ("c17", Iso);
    ("c18", Iso); ("iso9899:2017", Iso); ("iso9899:2018", Iso);
    ("gnu11", Gnu); ("gnu1x", Gnu); ("gnu17", Gnu); ("gnu18", Gnu);
  ]

(* The standard of a command line without -std=, the default of Clang 11
   and later (design 2.4). *)
let default_standard = "gnu17"

(* Design 2.1: a shared header can tell Type-C from C. *)
let type_c_macro = "-D__TYPEC__=1"

(* Each step gets the options of the whole command line that it may not
   use, such as -F or a linker flag, and Clang warns about those, which
   -Werror makes fatal. GCC does not know the option and names it in a
   note after any diagnostic of the step, so only Clang gets it. It
   comes before the user's options, so that a -W option of theirs still
   counts. *)
let quiet_unused_options : Target.compiler -> string list = function
  | Clang -> [ "-Wno-unused-command-line-argument" ]
  | Gcc -> []

(* What the command line makes of its inputs. *)
type goal = Linked | Stopped of Cc_option.stop

let has_type_c_input arguments =
  List.exists
    (function Command_line.Input { type_c; _ } -> type_c | _ -> false)
    arguments

let type_c_sources arguments =
  List.filter_map
    (function
      | Command_line.Input { path; type_c = true } -> Some path | _ -> None)
    arguments

let input_count arguments =
  List.length
    (List.filter
       (function Command_line.Input _ -> true | _ -> false)
       arguments)

let has_role role arguments =
  List.exists
    (function
      | Command_line.Option option -> option.role = role | _ -> false)
    arguments

(* The value of the last option with [role]: cc lets a later option
   override an earlier one. *)
let last_value role arguments =
  List.fold_left
    (fun last -> function
      | Command_line.Option option when option.role = role ->
          Some option.value
      | _ -> last)
    None arguments

(* The options whose role [keep] accepts, spelled as given. *)
let options_where keep arguments =
  List.concat_map
    (function
      | Command_line.Option option when keep option.role -> option.words
      | _ -> [])
    arguments

let refuse_unusable_options arguments =
  List.iter
    (function
      | Command_line.Option { role = Refused reason; words; _ } ->
          raise (Failed (Refused_option { option = List.hd words; reason }))
      | Command_line.Truncated words ->
          raise (Failed (Missing_value (List.hd words)))
      | _ -> ())
    arguments

(* The -E step preprocesses for one architecture, so the translation
   cannot follow cc into a universal build. cc collapses a repeated
   name, so only distinct names count. *)
let refuse_several_architectures arguments =
  let names =
    List.filter_map
      (function
        | Command_line.Option { role = Architecture; value; _ } -> Some value
        | _ -> None)
      arguments
  in
  (* The distinct names in the order of their first use, for the
     message. *)
  let distinct =
    List.fold_left
      (fun seen name -> if List.mem name seen then seen else name :: seen)
      [] names
  in
  if List.length distinct > 1 then
    raise (Failed (Several_architectures (List.rev distinct)))

(* The keyword dialect of the -std= standard; raises Unaccepted_standard for one
   that Type-C does not accept. *)
let standard_dialect arguments =
  let standard =
    Option.value (last_value Dialect arguments) ~default:default_standard
  in
  match List.assoc_opt standard accepted_standards with
  | Some dialect -> dialect
  | None -> raise (Failed (Unaccepted_standard standard))

(* The dialect of the keywords that the backend reads: GCC and Clang let
   the last -fasm or -fno-asm decide, wherever -std= stands. *)
let dialect_of arguments =
  let chosen =
    List.fold_left
      (fun last -> function
        | Command_line.Option { role = Keywords set; _ } -> Some set
        | _ -> last)
      None arguments
  in
  let standard = standard_dialect arguments in
  Option.value chosen ~default:standard

(* cc stops at the earliest output any option asks for. *)
let goal_of arguments =
  let stops stop = has_role (Stop stop) arguments in
  if stops Syntax_check then Stopped Syntax_check
  else if stops Assembly then Stopped Assembly
  else if stops Object then Stopped Object
  else Linked

(* -M and -MM stop cc before any other output: it prints the rule of
   each input instead. *)
let prints_rules arguments = has_role (Dependency Print_rule) arguments

(* Whether the command line makes an output of each input, which one -o
   cannot name when there are several. *)
let output_of_each_input ~rules = function
  | Stopped (Object | Assembly) -> true
  | Linked | Stopped Syntax_check -> rules

let check_outputs ~emit_c ~rules ~goal ~output arguments =
  let several_inputs = input_count arguments > 1 in
  if emit_c then begin
    if rules then raise (Failed Emit_c_rules);
    if several_inputs || not (has_type_c_input arguments) then
      raise (Failed Emit_c_inputs)
  end
  else if
    several_inputs && Option.is_some output
    && output_of_each_input ~rules goal
  then raise (Failed Output_for_several_inputs)

let preprocessing_role : Cc_option.role -> bool = function
  | Preprocess | Dependency _ | Common | Architecture | Dialect | Keywords _
    ->
      true
  | Link | Output | Language | Stop _ | Refused _ | Typec _ -> false

let compiling_role : Cc_option.role -> bool = function
  | Common | Architecture | Dialect | Keywords _ -> true
  | Preprocess | Dependency _ | Link | Output | Language | Stop _
  | Refused _ | Typec _ ->
      false

(* What a final command whose only inputs were .tc ones keeps: the
   options that matter to preprocessing would make Clang warn that they
   are unused. *)
let linking_role : Cc_option.role -> bool = function
  | Preprocess | Dependency _ -> false
  | Link | Common | Architecture | Dialect | Keywords _ | Output | Language
  | Stop _ | Refused _ | Typec _ ->
      true

(* The name cc gives an output of [source] in the current directory. *)
let output_beside source suffix =
  Filename.remove_extension (Filename.basename source) ^ suffix

(* The file and target that cc would give the dependencies of [source],
   when the command line leaves them out. *)
let dependency_options ~output arguments source =
  let has kind = has_role (Dependency kind) arguments in
  let stem, target =
    match output with
    | Some output -> (Filename.remove_extension output, output)
    | None -> (output_beside source "", output_beside source ".o")
  in
  let file = if has Dependency_file then [] else [ "-MF"; stem ^ ".d" ] in
  let target = if has Dependency_target then [] else [ "-MQ"; target ] in
  if has Write_dependencies then file @ target else []

let object_file temp_dir index =
  Filename.concat temp_dir (string_of_int index ^ ".o")

let translation_directory temp_dir index =
  Filename.concat temp_dir (string_of_int index)

(* The emitted C of [source] has the name of a C source like it, in a
   directory of its own, so that a backend command that compiles it names
   the side outputs (-fstack-usage, -gsplit-dwarf) as it names those of
   that source, and GCC runs dsymutil for it as for a C source. *)
let emitted_file directory source =
  Filename.concat directory (output_beside source ".c")

(* Where the compile step of [source] writes, and the option that stops
   it there. *)
let compile_outputs ~goal ~output ~linked_object source =
  let named suffix =
    match output with
    | Some output -> output
    | None -> output_beside source suffix
  in
  match goal with
  | Linked -> [ "-c"; "-o"; linked_object ]
  | Stopped Object -> [ "-c"; "-o"; named ".o" ]
  | Stopped Assembly -> [ "-S"; "-o"; named ".s" ]
  | Stopped Syntax_check -> [ "-fsyntax-only" ]

(* The facts of a command line that each translation needs. *)
type shape = {
  program : string;
  emit_c : bool;
  temp_dir : string;
  goal : goal;
  output : string option;
  final_compiles : bool;
      (** the final command compiles the emitted C, instead of a compile
          step of each translation *)
  standard : string list;  (** what the backend adds for design 2.4 *)
  dialect : Typec_syntax.Keyword_set.dialect;
}

(* With --emit-c the C goes where -o says, and "-o -" is stdout as for
   cc. *)
let emit_c_destination output =
  match output with
  | Some output when output <> "-" -> File output
  | Some _ | None -> Standard_output

(* What a backend command for [compiler] that reads the text of a
   translation gets in front of the [options] of the command line. *)
let with_standard shape compiler options =
  shape.standard @ quiet_unused_options compiler @ options

let compile_options shape compiler arguments =
  with_standard shape compiler (options_where compiling_role arguments)

(* The target model is read with the compile step's options so that it
   describes the target that the step compiles for (design 13.3). The
   query is what names the backend's family, so it gets Clang's options
   whatever the backend: Clang fails it under -Werror for an unused
   option such as -stdlib=, and GCC adds its note to any diagnostic. *)
let target_options shape arguments = compile_options shape Clang arguments

(* Under -std=c11, -std=c17 or -trigraphs, Clang 21 reads a trigraph in
   preprocessed input, which typec's reader does not, and a macro can
   build one that the -E step leaves. -fno-trigraphs follows the user's
   options, so that their -trigraphs does not turn trigraphs back on.
   GCC 16 reads no trigraph there whatever its options, and refuses
   -fno-trigraphs (design 13.2). *)
let without_trigraphs : Target.compiler -> string list = function
  | Clang -> [ "-fno-trigraphs" ]
  | Gcc -> []

let as_preprocessed file = [ "-x"; "cpp-output"; file ]

let output_option = function
  | Some output -> [ "-o"; output ]
  | None -> []

(* A backend command that compiles emitted C: [words] gives its options
   and inputs for the compiler, and the backend reads the C as typec's
   reader did. *)
let emitted_c_command shape words compiler =
  (shape.program :: words compiler) @ without_trigraphs compiler

(* A backend command that reads no emitted C. *)
let same_for_every_compiler words (_ : Target.compiler) = words

let compile_command shape arguments ~linked_object source emitted_file =
  emitted_c_command shape (fun compiler ->
      compile_options shape compiler arguments
      @ compile_outputs ~goal:shape.goal ~output:shape.output ~linked_object
          source
      @ as_preprocessed emitted_file)

(* The -E step of [source] with the options of the command line that
   matter to preprocessing, and [own_options], which this step alone
   gets, before the input. *)
let preprocessing_command shape arguments ~own_options source compiler =
  (shape.program :: "-E" :: type_c_macro
   :: with_standard shape compiler
        (options_where preprocessing_role arguments))
  @ own_options @ [ "-x"; "c"; source ]

(* The -E step that a translation reads, whose dependency file is the
   one that cc would write when it compiles. -dD writes each #define and
   #undef at its place, so that the reader knows the macros at each
   token (design 13.2, 13.3). *)
let preprocess_command shape arguments source =
  preprocessing_command shape arguments source
    ~own_options:
      ("-dD" :: dependency_options ~output:shape.output arguments source)

(* Under -M or -MM the -E step prints the rule in place of the
   preprocessed text, where -o says. It gets -o and the dependency
   options as given, so the backend names the rule's target and any
   dependency file as it does for a C source. *)
let rule_command shape arguments source =
  preprocessing_command shape arguments source
    ~own_options:(output_option shape.output)

(* [linked_object] is the object that the step makes when the command
   line links. *)
let translation shape arguments ~linked_object index source =
  let directory = translation_directory shape.temp_dir index in
  let emitted_file = emitted_file directory source in
  let emitted, compile =
    if shape.emit_c then (emit_c_destination shape.output, None)
    else if shape.final_compiles then (File emitted_file, None)
    else
      ( File emitted_file,
        Some
          (compile_command shape arguments ~linked_object source emitted_file)
      )
  in
  {
    source;
    directory;
    preprocess = preprocess_command shape arguments source;
    preprocessed = Filename.concat directory "preprocessed.i";
    dialect = shape.dialect;
    emitted;
    compile;
  }

(* The command line with each .tc input replaced by the words of its
   replacement, in order: [replacements] has one for each. *)
let with_replaced_inputs replacements arguments =
  let replace replacements = function
    | Command_line.Input { type_c = true; _ } ->
        (List.tl replacements, List.hd replacements)
    | argument -> (replacements, Command_line.words [ argument ])
  in
  List.concat (snd (List.fold_left_map replace replacements arguments))

let without_type_c_inputs arguments =
  List.filter
    (function Command_line.Input { type_c; _ } -> not type_c | _ -> true)
    arguments

(* The final command compiles the emitted C and links as a one-step build
   of C sources does, so that the backend leaves what that build leaves:
   the side outputs of the compilation, named as there, and on macOS the
   debug information that it runs dsymutil for, from objects that it
   removes after. The -std= and -fno-trigraphs that the emitted C needs
   would apply to another input too, so a command line with another
   input compiles each .tc input to an object first. *)
let final_compiles ~emit_c ~goal arguments =
  (not emit_c) && goal = Linked
  && input_count (without_type_c_inputs arguments) = 0

(* The command line without its .tc inputs, for the backend to do with
   the other inputs what it would without typec, when there are any. *)
let other_inputs_commands shape arguments =
  let others = without_type_c_inputs arguments in
  if input_count others = 0 then []
  else
    [ same_for_every_compiler (shape.program :: Command_line.words others) ]

let final_commands shape ~objects ~emitted_files arguments =
  let other_inputs = input_count (without_type_c_inputs arguments) > 0 in
  let link_options = function
    | Command_line.Option option -> linking_role option.role
    | _ -> true
  in
  let linked =
    if other_inputs then arguments else List.filter link_options arguments
  in
  if shape.emit_c then []
  else
    match shape.goal with
    | Linked when shape.final_compiles ->
        let compiled =
          with_replaced_inputs (List.map as_preprocessed emitted_files) linked
        in
        [
          emitted_c_command shape (fun compiler ->
              with_standard shape compiler compiled);
        ]
    | Linked ->
        let objects = List.map (fun file -> [ file ]) objects in
        let words = with_replaced_inputs objects linked in
        [ same_for_every_compiler (shape.program :: words) ]
    | Stopped _ -> other_inputs_commands shape arguments

(* The plan of a command line that compiles: a translation of each .tc
   input, then the command that links or compiles the rest. *)
let compilation_plan shape arguments =
  (* The number of a .tc input, from 1, names its files. *)
  let sources =
    List.mapi (fun index source -> (index + 1, source))
      (type_c_sources arguments)
  in
  let objects =
    List.map (fun (index, _) -> object_file shape.temp_dir index) sources
  in
  let translations =
    List.map2
      (fun (index, source) linked_object ->
        translation shape arguments ~linked_object index source)
      sources objects
  in
  (* Only --emit-c writes to stdout, and it has no final command, so
     the list has a file for each .tc input when the final reads it. *)
  let emitted_files =
    List.filter_map
      (fun translation ->
        match translation.emitted with
        | File file -> Some file
        | Standard_output -> None)
      translations
  in
  {
    target_options = target_options shape arguments;
    translations;
    finals = final_commands shape ~objects ~emitted_files arguments;
  }

(* The plan of a command line with -M or -MM, which translates nothing:
   the rule of each .tc input, then those of the other inputs. *)
let rules_plan shape arguments =
  let rules =
    List.map (rule_command shape arguments) (type_c_sources arguments)
  in
  {
    target_options = target_options shape arguments;
    translations = [];
    finals = rules @ other_inputs_commands shape arguments;
  }

let plan ~program ~emit_c ~temp_dir arguments =
  try
    refuse_unusable_options arguments;
    refuse_several_architectures arguments;
    let dialect = dialect_of arguments in
    let rules = prints_rules arguments in
    let goal = goal_of arguments in
    let output = last_value Output arguments in
    check_outputs ~emit_c ~rules ~goal ~output arguments;
    let standard =
      if has_role Dialect arguments then [] else [ "-std=" ^ default_standard ]
    in
    let shape =
      {
        program;
        emit_c;
        temp_dir;
        goal;
        output;
        final_compiles = final_compiles ~emit_c ~goal arguments;
        standard;
        dialect;
      }
    in
    if rules then Ok (rules_plan shape arguments)
    else Ok (compilation_plan shape arguments)
  with Failed error -> Error error

(* The header of an interface (design 9.3). *)

type rule = { written : string; destination : destination }

type header_output =
  | Header
  | Header_and_rule of rule
  | Rule of rule

type header = {
  header_target_options : string list;
  interface : translation;
  name : Typec_emit.Header.name;
  output : header_output;
}

let interface_input arguments =
  let inputs =
    List.filter_map
      (function Command_line.Input { path; _ } -> Some path | _ -> None)
      arguments
  in
  match inputs with
  | [ path ] when Filename.check_suffix path Typec_cpp.File.interface_suffix
    ->
      path
  | _ -> raise (Failed Header_inputs)

let is_dependency_file = function
  | Command_line.Option { role = Dependency Dependency_file; _ } -> true
  | _ -> false

(* The header goes beside its interface unless -o names another path,
   and "-o -" is stdout as for cc. *)
let header_destination ~output source =
  match output with
  | Some "-" -> Standard_output
  | Some path -> File path
  | None ->
      File
        (Filename.chop_suffix source Typec_cpp.File.interface_suffix ^ ".h")

(* "-MF -" names stdout, for GCC and Clang alike. *)
let rule_file_destination = function
  | "-" -> Standard_output
  | path -> File path

(* What the command line asks --emit-c-header to write, the rule of its
   -E step going to [written] first (design 9.3). Under "-o -" no path
   names the header, so the user names the rule's target and its file. *)
let header_output ~output ~header ~written arguments =
  let has kind = has_role (Dependency kind) arguments in
  let rule_file =
    Option.map rule_file_destination
      (last_value (Dependency Dependency_file) arguments)
  in
  if has Print_rule then begin
    if Option.is_some output then raise (Failed Header_rule_output);
    let destination = Option.value rule_file ~default:Standard_output in
    Rule { written; destination }
  end
  else if has Write_dependencies then begin
    match (header, rule_file) with
    | File path, None ->
        Header_and_rule { written; destination = File (path ^ ".d") }
    | File _, Some destination -> Header_and_rule { written; destination }
    | Standard_output, Some destination when has Dependency_target ->
        Header_and_rule { written; destination }
    | Standard_output, (Some _ | None) -> raise (Failed Header_rule_names)
  end
  else Header

(* The arguments of the header's -E step and the options it alone gets:
   with a rule, -MF names [written] in place of the user's file, and the
   header is the rule's target unless -MT or -MQ names another. *)
let header_step_options ~header output arguments =
  match output with
  | Header -> (arguments, [])
  | Header_and_rule { written; _ } | Rule { written; _ } ->
      let names_target = has_role (Dependency Dependency_target) arguments in
      let target =
        match header with
        | File path when not names_target -> [ "-MQ"; path ]
        | File _ | Standard_output -> []
      in
      let given = List.filter (fun a -> not (is_dependency_file a)) in
      (given arguments, [ "-MF"; written ] @ target)

(* -dI writes each #include in place, which the header copies; the
   interface's own guard, as a main file, draws -Wunused-macros, which no
   unit that includes it draws, so the option follows the user's. *)
let header_preprocess_command shape ~header output arguments source =
  let arguments, dependency_options =
    header_step_options ~header output arguments
  in
  preprocessing_command shape arguments source
    ~own_options:
      ([ "-dD"; "-dI"; "-Wno-unused-macros" ] @ dependency_options)

let plan_header ~program ~temp_dir arguments =
  try
    refuse_unusable_options arguments;
    refuse_several_architectures arguments;
    let source = interface_input arguments in
    if goal_of arguments <> Linked then raise (Failed Header_stops);
    let name =
      match Typec_emit.Header.name_of_path source with
      | Some name -> name
      | None -> raise (Failed (Header_name source))
    in
    let dialect = dialect_of arguments in
    let output = last_value Output arguments in
    let standard =
      if has_role Dialect arguments then [] else [ "-std=" ^ default_standard ]
    in
    let shape =
      {
        program;
        emit_c = true;
        temp_dir;
        goal = Linked;
        output;
        final_compiles = false;
        standard;
        dialect;
      }
    in
    let directory = translation_directory temp_dir 0 in
    let header = header_destination ~output source in
    let written = Filename.concat directory "rule.d" in
    let header_output = header_output ~output ~header ~written arguments in
    let interface =
      {
        source;
        directory;
        preprocess =
          header_preprocess_command shape ~header header_output arguments
            source;
        preprocessed = Filename.concat directory "preprocessed.i";
        dialect;
        emitted = header;
        compile = None;
      }
    in
    Ok
      {
        header_target_options = target_options shape arguments;
        interface;
        name;
        output = header_output;
      }
  with Failed error -> Error error

let error_message = function
  | Refused_option { option; reason } ->
      Printf.sprintf "%s cannot be used with a .tc input: %s" option reason
  | Unaccepted_standard standard ->
      Printf.sprintf
        "-std=%s cannot be used with a .tc input: Type-C accepts C11 and \
         C17, in ISO or GNU form"
        standard
  | Missing_value option -> Printf.sprintf "missing argument to %s" option
  | Output_for_several_inputs ->
      "cannot specify -o with -c, -S or -M and more than one input"
  | Emit_c_inputs -> "--emit-c needs exactly one input, a .tc file"
  | Emit_c_rules ->
      "--emit-c cannot be used with -M or -MM: it writes the C, not a rule"
  | Header_inputs -> "--emit-c-header needs exactly one input, a .tci file"
  | Header_stops ->
      "--emit-c-header cannot be used with -c, -S or -fsyntax-only: it \
       writes a header and compiles nothing"
  | Header_rule_output ->
      "--emit-c-header cannot be used with -o under -M or -MM: it writes \
       the rule and no header, so -o would name both; name the file of \
       the rule with -MF"
  | Header_rule_names ->
      "--emit-c-header with -o - needs -MT or -MQ and -MF under -MD or \
       -MMD: no path names the header, which the rule names as its target \
       and beside which it goes"
  | Header_name path ->
      Printf.sprintf
        "%s cannot have a header: the last component of its path may hold \
         only ASCII letters, digits, '.', '_', '-' and '+', since the \
         header names it in an #include"
        path
  | Several_architectures names ->
      Printf.sprintf
        "-arch cannot name several architectures (%s) with a .tc input: \
         build each with one -arch and join the results with lipo"
        (String.concat ", " names)
