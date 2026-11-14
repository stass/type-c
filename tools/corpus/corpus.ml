(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The corpus runner (README, "Running the corpus"): for each program and
   backend it builds the program from its recipe, compares the object of
   every unit compiled as Type-C with the object of the same preprocessed
   text compiled without typec (plan 0.11, gate 2), links the Type-C
   objects and runs the program's tests (gate 1), and writes a run record
   into the corpus repository. *)

let usage =
  "usage: corpus.exe --corpus DIR --cache DIR --typec PATH --cc PATH \
   [--cc PATH]... PROGRAM..."

(* Every error that ends the whole run: a usage error, a recipe that
   cannot be read, an archive not fetched. [main]'s caller also ends the
   run on a file or process the runner itself cannot make. *)
exception Fatal of string

let fatal fmt = Printf.ksprintf (fun message -> raise (Fatal message)) fmt

(* A step of one build that failed; the build records it and goes on
   with the next unit, or stops when the step is not a unit's. *)
exception Step_failed of string

(* A step of a unit in which typec stopped with a diagnostic of its own;
   it carries the diagnostic. *)
exception Typec_refused of string

type options = {
  corpus : string;  (** the corpus repository *)
  cache : string;  (** the fetched sources and the build trees *)
  typec : string;
  backends : string list;
  programs : string list;
}

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

(* A backend named without a slash is found through PATH, as typec finds
   it; every other path is made absolute, since commands run in the
   build tree. *)
let backend_path path = if String.contains path '/' then absolute path else path

(* Program and backend names become directory names in the cache and the
   corpus repository, so they are plain names. *)
let checked_name what name =
  let plain = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  if name = "" || name.[0] = '.' || not (String.for_all plain name) then
    fatal "%s %S is not a plain name" what name;
  name

(* A backend's records and build trees are named after its file name. *)
let backend_label cc = checked_name "backend" (Filename.basename cc)

let parse_options arguments =
  let corpus = ref None and cache = ref None and typec = ref None in
  let backends = ref [] and programs = ref [] in
  let rec loop = function
    | "--corpus" :: dir :: rest -> corpus := Some (absolute dir); loop rest
    | "--cache" :: dir :: rest -> cache := Some (absolute dir); loop rest
    | "--typec" :: path :: rest -> typec := Some (absolute path); loop rest
    | "--cc" :: path :: rest ->
        backends := backend_path path :: !backends;
        loop rest
    | option :: _ when String.starts_with ~prefix:"-" option ->
        fatal "%s\nunknown option or missing value: %s" usage option
    | program :: rest -> programs := program :: !programs; loop rest
    | [] -> ()
  in
  loop arguments;
  match (!corpus, !cache, !typec, !backends, !programs) with
  | Some corpus, Some cache, Some typec, _ :: _, _ :: _ ->
      let backends = List.rev !backends in
      let labels = List.map backend_label backends in
      if List.length (List.sort_uniq compare labels) <> List.length labels
      then fatal "two backends have the same name: %s" (String.concat " " labels);
      List.iter (fun p -> ignore (checked_name "program" p)) !programs;
      { corpus; cache; typec; backends; programs = List.rev !programs }
  | _ -> fatal "%s" usage

(* The facts a run record states about where it ran. *)
type host = {
  system : string;  (** uname -s, which selects the cflags@ lines *)
  label : string;  (** the directory of its run records *)
}

let ask ~cwd command =
  match Command.first_line ~cwd command with
  | Some line -> line
  | None -> "unknown"

let probe_host () =
  let system = ask ~cwd:"/" [ "uname"; "-s" ] in
  let machine = ask ~cwd:"/" [ "uname"; "-m" ] in
  { system; label = String.lowercase_ascii system ^ "-" ^ machine }

let revision dir =
  ask ~cwd:dir [ "git"; "describe"; "--always"; "--dirty"; "--abbrev=12" ]

(* typec cannot report the revision it was built from, so the binary is
   named by its digest. The checkout beside it is only where the binary
   sits at run time: it may have moved on since the build. *)
let typec_identity typec =
  let digest = Digest.BLAKE256.to_hex (Digest.BLAKE256.file typec) in
  Printf.sprintf "blake2b-256 %s (checkout at run time: %s)" digest
    (revision (Filename.dirname typec))

(* What one build needs to run its commands. *)
type context = {
  root : string;  (** the build tree, the directory of every command *)
  log : Unix.file_descr;  (** the stderr of every command *)
  cc : string;
  typec : string;
  flags : string list;  (** -O2 and the recipe's cflags *)
}

let in_tree context path = Filename.concat context.root path

let write_to_log context text =
  ignore (Unix.write_substring context.log text 0 (String.length text))

let log_command context command =
  write_to_log context ("$ " ^ String.concat " " command ^ "\n")

let run_to ?cwd context ~stdout ~stderr ~step command =
  let cwd = Option.value cwd ~default:context.root in
  log_command context command;
  let outcome = Command.run ~cwd ~stdout ~stderr command in
  match outcome.status with
  | Unix.WEXITED 0 -> outcome.cpu_seconds
  | status -> raise (Step_failed (step ^ " " ^ Command.describe status))

let run ?cwd context ~step command =
  run_to ?cwd context ~stdout:context.log ~stderr:context.log ~step command

let with_output_file path f =
  let flags = [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] in
  let fd = Unix.openfile path flags 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)

let run_into_file context ~step ~output command =
  with_output_file (in_tree context output) (fun fd ->
      run_to context ~stdout:fd ~stderr:context.log ~step command)

let rec make_directories path =
  if not (Sys.file_exists path) then begin
    make_directories (Filename.dirname path);
    Sys.mkdir path 0o755
  end

let read_file path = In_channel.with_open_bin path In_channel.input_all

let copy_file ~source ~target =
  let text = read_file source in
  Out_channel.with_open_bin target (fun channel ->
      Out_channel.output_string channel text)

(* CPU seconds of the measured steps of one unit: preprocessing alone,
   typec's preprocessing and front end (--emit-c), and the backend's
   front end on the preprocessed text (-fsyntax-only). Their difference
   estimates typec's front end; it is recorded, never gated on. *)
type times = { preprocess : float; emit_c : float; syntax_only : float }

let no_time = { preprocess = 0.; emit_c = 0.; syntax_only = 0. }

let add_times a b =
  {
    preprocess = a.preprocess +. b.preprocess;
    emit_c = a.emit_c +. b.emit_c;
    syntax_only = a.syntax_only +. b.syntax_only;
  }

(* How the compile of one unit ended. [Refused] is typec's front end
   stopping at the unit; [Backend_failed] is any other step failing, the
   backend compiling typec's output included. *)
type unit_result =
  | Identical of times
  | Different of times
  | Refused of string
  | Backend_failed of string

(* The .tc copy of a unit sits next to it, so that its includes resolve
   as before. Every file the runner makes for the unit is named after the
   copy, which no other unit's files can be, since units end in .c. *)
let type_c_copy unit = Filename.chop_suffix unit ".c" ^ ".tc"

let derived unit suffix = type_c_copy unit ^ suffix

(* typec exits with the backend's status when a backend step fails, so
   its status does not tell a refusal from a backend failure. Its own
   diagnostics are the stderr lines that start with its name
   (src/driver/command.ml); a backend's diagnostics never do. *)
let typec_diagnostic stderr_text =
  let prefix = "typec: " in
  let skip = String.length prefix in
  let own line = String.starts_with ~prefix line in
  String.split_on_char '\n' stderr_text
  |> List.find_opt own
  |> Option.map (fun line -> String.sub line skip (String.length line - skip))

(* Runs typec on a unit with its stderr in [errors], which the log gets
   too. A failure is [Refused] with typec's first diagnostic, or
   [Step_failed] when typec printed none. *)
let run_typec context ~step ~errors command =
  let run fd =
    run_to context ~stdout:context.log ~stderr:fd ~step command |> ignore
  in
  let path = in_tree context errors in
  let outcome =
    match with_output_file path run with
    | () -> None
    | exception Step_failed message -> Some message
  in
  let stderr_text = read_file path in
  write_to_log context stderr_text;
  match (outcome, typec_diagnostic stderr_text) with
  | None, _ -> ()
  | Some _, Some diagnostic -> raise (Typec_refused diagnostic)
  | Some message, None -> raise (Step_failed message)

(* typec compiles the .tc copy of the unit first, so that a unit it
   refuses is reported as its failure. The reference follows
   test/run/pipeline.t: the backend preprocesses the .tc copy as typec
   does and compiles the text with -x cpp-output, both with -std=gnu11
   before the recipe's options. *)
let compile_unit context unit =
  let tc = type_c_copy unit and reference_i = derived unit ".ref.i" in
  let reference_o = derived unit ".ref.o" and object_ = derived unit ".o" in
  let cc = context.cc and flags = context.flags in
  let typec = [ context.typec; "--cc=" ^ cc ] @ flags in
  let backend_on_text = [ cc; "-x"; "cpp-output"; "-std=gnu11" ] @ flags in
  copy_file ~source:(in_tree context unit) ~target:(in_tree context tc);
  run_typec context ~step:"typec -c" ~errors:(derived unit ".typec.err")
    (typec @ [ "-c"; tc; "-o"; object_ ]);
  let preprocess =
    run_into_file context ~step:"preprocessing" ~output:reference_i
      ([ cc; "-E"; "-x"; "c"; "-D__TYPEC__=1"; "-std=gnu11" ] @ flags @ [ tc ])
  in
  let _ : float =
    run context ~step:"the reference compile"
      (backend_on_text @ [ "-c"; reference_i; "-o"; reference_o ])
  in
  let emit_c =
    run context ~step:"typec --emit-c"
      (typec @ [ "--emit-c"; tc; "-o"; derived unit ".emit.i" ])
  in
  let syntax_only =
    run context ~step:"-fsyntax-only"
      (backend_on_text @ [ "-fsyntax-only"; reference_i ])
  in
  let times = { preprocess; emit_c; syntax_only } in
  let same =
    read_file (in_tree context reference_o)
    = read_file (in_tree context object_)
  in
  if same then Identical times else Different times

let compile_or_fail context unit =
  match compile_unit context unit with
  | result -> result
  | exception Typec_refused diagnostic -> Refused diagnostic
  | exception Step_failed message -> Backend_failed message

(* [Substitute_passed] is a script that is not the program's own suite
   (the recipe says what it checks): it never counts as the tests
   passing. *)
type tests =
  | Passed
  | Substitute_passed of string
  | Tests_failed of string
  | Not_run of string

type build = {
  units : (string * unit_result) list;
  linked : string list;
  not_linked : string list;
  tests : tests;
  results : Test_lines.t;  (** what the script reported, if anything *)
}

let is_compiled = function
  | Identical _ | Different _ -> true
  | Refused _ | Backend_failed _ -> false

let compiled units unit = is_compiled (List.assoc unit units)

(* A program links the Type-C objects, so a unit typec did not compile
   keeps every program that uses it from linking. *)
let link context (recipe : Recipe.t) units (program : Recipe.program) =
  let sources = recipe.library @ program.units in
  if not (List.for_all (compiled units) sources) then false
  else
    let objects = List.map (fun unit -> derived unit ".o") sources in
    let command =
      (context.cc :: context.flags) @ [ "-o"; program.name ] @ objects
      @ recipe.libs
    in
    make_directories (in_tree context (Filename.dirname program.name));
    match run context ~step:"linking" command with
    | _ -> true
    | exception Step_failed _ -> false

(* A recipe's script runs with CC and TYPEC_CC naming the backend, for
   the scripts that compile test drivers, and TYPEC naming the typec
   under test (recipe.mli). *)
let script_command context ~recipe_dir script =
  [
    "env";
    "CC=" ^ context.cc;
    "TYPEC_CC=" ^ context.cc;
    "TYPEC=" ^ context.typec;
    "sh";
    Filename.concat recipe_dir script;
  ]

(* The script's stdout, kept beside the log; a run removes the last one's. *)
let tests_file context = context.root ^ ".tests"

(* The script runs on the programs that linked, and its stdout, which
   the log gets too, is kept next to the log for the results it prints. *)
let run_tests context ~recipe_dir (recipe : Recipe.t) ~linked =
  if linked = [] then (Not_run "no program linked", Test_lines.none)
  else
    let test = recipe.test in
    let command = script_command context ~recipe_dir test.script in
    let path = tests_file context in
    let run fd =
      run_to context ~stdout:fd ~stderr:context.log ~step:"the tests" command
      |> ignore
    in
    let failure =
      match with_output_file path run with
      | () -> None
      | exception Step_failed message -> Some message
    in
    let output = read_file path in
    write_to_log context output;
    let results = Test_lines.read output in
    let tests =
      match (failure, results, test.suite) with
      | Some message, _, _ -> Tests_failed message
      | None, Error message, _ -> Tests_failed (test.script ^ ": " ^ message)
      | None, Ok { failed = _ :: _; _ }, _ ->
          Tests_failed "the script exited with 0 but reported a failed test"
      | None, Ok _, Own -> Passed
      | None, Ok _, Substitute description -> Substitute_passed description
    in
    (tests, Result.value results ~default:Test_lines.none)

(* The build tree is made afresh: the trees of the recipe, copied from
   the cache, then its prepare script. *)
let set_up context ~cache ~recipe_dir (recipe : Recipe.t) =
  let remove = [ "rm"; "-rf"; "--"; context.root; tests_file context ] in
  ignore (run ~cwd:"/" context ~step:"removing the old tree" remove);
  let copy (tree : Recipe.tree) =
    let source = List.fold_left Filename.concat cache [ "src"; tree.archive ] in
    if not (Sys.file_exists source) then
      fatal "%s is missing: fetch the corpus first (fetch.sh)" source;
    let target =
      if tree.dir = "." then context.root else in_tree context tree.dir
    in
    make_directories target;
    ignore
      (run context ~step:"copying a tree" [ "cp"; "-R"; source ^ "/."; target ])
  in
  List.iter copy recipe.trees;
  match recipe.prepare with
  | None -> ()
  | Some script ->
      ignore
        (run context ~step:"the prepare script"
           (script_command context ~recipe_dir script))

let build context ~cache ~recipe_dir recipe =
  set_up context ~cache ~recipe_dir recipe;
  let compile unit = (unit, compile_or_fail context unit) in
  let units = List.map compile (Recipe.units recipe) in
  let linked, not_linked =
    List.partition (link context recipe units) recipe.programs
  in
  let names = List.map (fun (p : Recipe.program) -> p.name) in
  let linked = names linked and not_linked = names not_linked in
  let tests, results = run_tests context ~recipe_dir recipe ~linked in
  { units; linked; not_linked; tests; results }

let with_log path f =
  let flags =
    [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_APPEND; Unix.O_CLOEXEC ]
  in
  let fd = Unix.openfile path flags 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)

(* The run record of one program and backend. *)
type record = {
  program : string;
  backend : string;
  outcome : (build, string) result;  (** [Error] when setting up failed *)
  log : string;
}

let count predicate units = List.length (List.filter predicate units)

let unit_times = function
  | Identical times | Different times -> times
  | Refused _ | Backend_failed _ -> no_time

let is_identical = function _, Identical _ -> true | _ -> false
let is_different = function _, Different _ -> true | _ -> false
let is_refused = function _, Refused _ -> true | _ -> false
let is_backend_failed = function _, Backend_failed _ -> true | _ -> false

(* Everything the recipe lists is built: each unit compiled and each
   program linked. A script that passes on less has not met gate 1. *)
let all_built build =
  let compiled (_, result) = is_compiled result in
  build.not_linked = [] && List.for_all compiled build.units

let tests_text build =
  match build.tests with
  | Passed when not (all_built build) ->
      "partial: passed on what linked only, gate 1 not met"
  | Substitute_passed description when not (all_built build) ->
      "partial: a substitute passed on what linked only, not the program's \
       own suite: " ^ description
  | Passed -> "passed"
  | Substitute_passed description ->
      "substitute passed, not the program's own suite: " ^ description
  | Tests_failed message -> "FAILED: " ^ message
  | Not_run reason -> "not run: " ^ reason

let results_lines (results : Test_lines.t) =
  let failed = List.length results.failed in
  let with_backend = List.length results.failed_with_backend in
  let total = results.passed + failed + with_backend in
  if total = 0 then [ "results      none reported" ]
  else
    Printf.sprintf "results      %d passed, %d failed, %d failed with the \
                    backend too" results.passed failed with_backend
    :: (List.map (( ^ ) "test-failed  ") results.failed
       @ List.map (( ^ ) "test-host    ") results.failed_with_backend)

(* What a record says about the exit gate of plan 0.11: gate 1 (the
   program's own tests pass) and gate 2 (identical objects). *)
type verdict = Gates_met | Substitute_tests | Gates_failed

let build_verdict build =
  let identical = List.for_all is_identical build.units in
  let met = identical && all_built build in
  match build.tests with
  | Passed when met -> Gates_met
  | Substitute_passed _ when met -> Substitute_tests
  | _ -> Gates_failed

let record_verdict record =
  match record.outcome with
  | Ok build -> build_verdict build
  | Error _ -> Gates_failed

let verdict_text = function
  | Gates_met -> "gates met"
  | Substitute_tests -> "gate 1 not met: only a substitute test passed"
  | Gates_failed -> "gates not met"

(* Exit status 0 only when every record meets the gates; a failure (1)
   outranks a run whose only shortfall is a substitute test (3), so that
   a script reading the status never takes either for a pass. *)
let exit_status verdicts =
  if List.mem Gates_failed verdicts then 1
  else if List.mem Substitute_tests verdicts then 3
  else 0

let build_lines build =
  let add total (_, result) = add_times total (unit_times result) in
  let total = List.fold_left add no_time build.units in
  let detail = function
    | unit, Different _ -> [ "different    " ^ unit ]
    | unit, Refused message -> [ "refused      " ^ unit ^ ": " ^ message ]
    | unit, Backend_failed message ->
        [ "backend-fail " ^ unit ^ ": " ^ message ]
    | _, Identical _ -> []
  in
  [
    Printf.sprintf "units        %d" (List.length build.units);
    Printf.sprintf "identical    %d" (count is_identical build.units);
    Printf.sprintf "different    %d" (count is_different build.units);
    Printf.sprintf "refused      %d" (count is_refused build.units);
    Printf.sprintf "backend-fail %d" (count is_backend_failed build.units);
    Printf.sprintf "linked       %d of %d" (List.length build.linked)
      (List.length build.linked + List.length build.not_linked);
    Printf.sprintf "tests        %s" (tests_text build);
  ]
  @ results_lines build.results
  @ [
    "cpu seconds, summed over the units:";
    Printf.sprintf "  preprocessing (cc -E)            %8.2f" total.preprocess;
    Printf.sprintf "  typec --emit-c                   %8.2f" total.emit_c;
    Printf.sprintf "  typec front end (the difference) %8.2f"
      (total.emit_c -. total.preprocess);
    Printf.sprintf "  backend -fsyntax-only on the .i  %8.2f" total.syntax_only;
  ]
  @ List.concat_map detail build.units
  @ List.map (Printf.sprintf "not linked   %s") build.not_linked

type provenance = {
  host_line : string;
  typec_line : string;
  corpus_line : string;
}

let record_text provenance ~backend_line record =
  let header =
    [
      "program      " ^ record.program;
      "host         " ^ provenance.host_line;
      "backend      " ^ backend_line;
      "typec        " ^ provenance.typec_line;
      "corpus       " ^ provenance.corpus_line;
    ]
  in
  let body =
    match record.outcome with
    | Ok build -> build_lines build
    | Error message -> [ "setup FAILED: " ^ message ]
  in
  String.concat "\n" (header @ body @ [ "log          " ^ record.log ]) ^ "\n"

let run_program options host ~cc program =
  let backend = backend_label cc in
  let recipe_dir =
    Filename.concat (Filename.concat options.corpus "programs") program
  in
  let recipe_file = Filename.concat recipe_dir "recipe" in
  let recipe =
    match Recipe.read ~system:host.system recipe_file with
    | Ok recipe -> recipe
    | Error message -> fatal "%s" message
  in
  let build_dir =
    List.fold_left Filename.concat options.cache
      [ "build"; host.label; program ]
  in
  make_directories build_dir;
  let log = Filename.concat build_dir (backend ^ ".log") in
  let outcome =
    with_log log (fun fd ->
        let context =
          {
            root = Filename.concat build_dir backend;
            log = fd;
            cc;
            typec = options.typec;
            flags = "-O2" :: recipe.cflags;
          }
        in
        match build context ~cache:options.cache ~recipe_dir recipe with
        | build -> Ok build
        | exception Step_failed message -> Error message)
  in
  { program; backend; outcome; log }

let write_record options host provenance ~cc record =
  let dir =
    List.fold_left Filename.concat options.corpus [ "runs"; host.label ]
  in
  make_directories dir;
  let backend_line = cc ^ ": " ^ ask ~cwd:"/" [ cc; "--version" ] in
  let text = record_text provenance ~backend_line record in
  let name = record.program ^ "." ^ record.backend ^ ".txt" in
  let path = Filename.concat dir name in
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel text);
  print_string text;
  print_newline ()

let main arguments =
  let options = parse_options arguments in
  let programs = options.programs in
  let host = probe_host () in
  let release = ask ~cwd:"/" [ "uname"; "-r" ] in
  let provenance =
    {
      host_line = String.concat " " [ host.system; release; host.label ];
      typec_line = typec_identity options.typec;
      corpus_line = revision options.corpus;
    }
  in
  let verdicts = ref [] in
  let each_backend program cc =
    let record = run_program options host ~cc program in
    write_record options host provenance ~cc record;
    let verdict = record_verdict record in
    if verdict <> Gates_met then
      Printf.printf "%s.%s: %s\n\n" record.program record.backend
        (verdict_text verdict);
    verdicts := verdict :: !verdicts
  in
  let each_program program =
    List.iter (each_backend program) options.backends
  in
  List.iter each_program programs;
  exit_status !verdicts

let () =
  let arguments = List.tl (Array.to_list Sys.argv) in
  let status =
    match main arguments with
    | status -> status
    | exception Fatal message ->
        prerr_endline ("corpus: " ^ message);
        2
    | exception Sys_error message ->
        prerr_endline ("corpus: " ^ message);
        2
    | exception Unix.Unix_error (error, call, argument) ->
        prerr_endline
          (Printf.sprintf "corpus: %s %s: %s" call argument
             (Unix.error_message error));
        2
  in
  exit status
