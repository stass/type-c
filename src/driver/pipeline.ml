(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type destination = File of string | Standard_output

type translation = {
  source : string;
  preprocess : string list;
  preprocessed : string;
  target_options : string list;
  dialect : Typec_syntax.Keyword_set.dialect;
  emitted : destination;
  compile : string list option;
}

type t = { translations : translation list; final : string list option }

type error =
  | Refused_option of { option : string; reason : string }
  | Unaccepted_standard of string
  | Missing_value of string
  | Output_for_several_inputs
  | Emit_c_inputs

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

let default_standard = "gnu11"

(* Design 2.1: a shared header can tell Type-C from C. *)
let type_c_macro = "-D__TYPEC__=1"

(* Each step gets the options of the whole command line that it may not
   use, such as -F or a linker flag, and Clang warns about those, which
   -Werror makes fatal; GCC ignores the option. It comes before the
   user's options, so that a -W option of theirs still counts. *)
let quiet_unused_options = "-Wno-unused-command-line-argument"

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

let check_outputs ~emit_c ~goal ~output arguments =
  let several_inputs = input_count arguments > 1 in
  if emit_c then begin
    if several_inputs || not (has_type_c_input arguments) then
      raise (Failed Emit_c_inputs)
  end
  else
    match (goal, output) with
    | Stopped (Object | Assembly), Some _ when several_inputs ->
        raise (Failed Output_for_several_inputs)
    | _ -> ()

let preprocessing_role : Cc_option.role -> bool = function
  | Preprocess | Dependency _ | Common | Dialect | Keywords _ -> true
  | Link | Output | Language | Stop _ | Refused _ | Typec _ -> false

let compiling_role : Cc_option.role -> bool = function
  | Common | Dialect | Keywords _ -> true
  | Preprocess | Dependency _ | Link | Output | Language | Stop _
  | Refused _ | Typec _ ->
      false

(* What a final command that only links keeps: the options that matter
   to preprocessing would make Clang warn that they are unused. *)
let linking_role : Cc_option.role -> bool = function
  | Preprocess | Dependency _ -> false
  | Link | Common | Dialect | Keywords _ | Output | Language | Stop _
  | Refused _ | Typec _ ->
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
  standard : string list;  (** what the backend adds for design 2.4 *)
  dialect : Typec_syntax.Keyword_set.dialect;
}

(* With --emit-c the C goes where -o says, and "-o -" is stdout as for
   cc. *)
let emit_c_destination output =
  match output with
  | Some output when output <> "-" -> File output
  | Some _ | None -> Standard_output

(* The target model is read with these options so that it describes the
   target that the compile step compiles for (design 13.3). *)
let compile_options shape arguments =
  shape.standard
  @ (quiet_unused_options :: options_where compiling_role arguments)

(* Clang 20 calls the line markers of preprocessed input, which no user
   wrote, a GNU extension under -pedantic; the option follows the user's
   options so that their -Wgnu does not turn that back on (design 2.4). *)
let quiet_line_markers = "-Wno-gnu-line-marker"

let compile_command shape arguments ~linked_object source emitted_file =
  (shape.program :: compile_options shape arguments)
  @ compile_outputs ~goal:shape.goal ~output:shape.output ~linked_object
      source
  @ [ quiet_line_markers; "-x"; "cpp-output"; emitted_file ]

(* [linked_object] is the object that the step makes when the command
   line links. *)
let translation shape arguments ~linked_object index source =
  let temp_file suffix =
    Filename.concat shape.temp_dir (string_of_int index ^ suffix)
  in
  let preprocess =
    (shape.program :: "-E" :: type_c_macro :: shape.standard)
    @ (quiet_unused_options :: options_where preprocessing_role arguments)
    @ dependency_options ~output:shape.output arguments source
    @ [ "-x"; "c"; source ]
  in
  let emitted_file = temp_file ".emitted.i" in
  let emitted, compile =
    if shape.emit_c then (emit_c_destination shape.output, None)
    else
      ( File emitted_file,
        Some
          (compile_command shape arguments ~linked_object source emitted_file)
      )
  in
  {
    source;
    preprocess;
    preprocessed = temp_file ".preprocessed.i";
    target_options = compile_options shape arguments;
    dialect = shape.dialect;
    emitted;
    compile;
  }

(* The command line with each .tc input replaced by its object, in
   order: [objects] has one for each. *)
let with_objects objects arguments =
  let replace objects = function
    | Command_line.Input { type_c = true; _ } ->
        (List.tl objects, [ List.hd objects ])
    | argument -> (objects, Command_line.words [ argument ])
  in
  List.concat (snd (List.fold_left_map replace objects arguments))

let without_type_c_inputs arguments =
  List.filter
    (function Command_line.Input { type_c; _ } -> not type_c | _ -> true)
    arguments

let final_command shape ~objects arguments =
  let others = without_type_c_inputs arguments in
  let other_inputs = input_count others > 0 in
  let link_options = function
    | Command_line.Option option -> linking_role option.role
    | _ -> true
  in
  let linked =
    if other_inputs then arguments else List.filter link_options arguments
  in
  if shape.emit_c then None
  else
    match shape.goal with
    | Linked -> Some (shape.program :: with_objects objects linked)
    | Stopped _ when other_inputs ->
        Some (shape.program :: Command_line.words others)
    | Stopped _ -> None

let plan ~program ~emit_c ~temp_dir arguments =
  try
    refuse_unusable_options arguments;
    let dialect = dialect_of arguments in
    let goal = goal_of arguments in
    let output = last_value Output arguments in
    check_outputs ~emit_c ~goal ~output arguments;
    let standard =
      if has_role Dialect arguments then [] else [ "-std=" ^ default_standard ]
    in
    let shape =
      { program; emit_c; temp_dir; goal; output; standard; dialect }
    in
    (* The number of a .tc input, from 1, names its files. *)
    let sources =
      List.mapi (fun index source -> (index + 1, source))
        (type_c_sources arguments)
    in
    let objects =
      List.map (fun (index, _) -> object_file temp_dir index) sources
    in
    let translations =
      List.map2
        (fun (index, source) linked_object ->
          translation shape arguments ~linked_object index source)
        sources objects
    in
    Ok { translations; final = final_command shape ~objects arguments }
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
      "cannot specify -o with -c or -S and more than one input"
  | Emit_c_inputs -> "--emit-c needs exactly one input, a .tc file"
