(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* fuzz TARGET [FILE]: runs the fuzz target TARGET on the bytes of FILE,
   or of standard input without one, once per process, as AFL++ runs it.
   A target returns for an input it accepts or rejects as its interface
   documents and raises for anything else. The harness turns a raised
   exception, or a heap beyond the bound below, into a crash for AFL++
   (see crash); the message on standard error says which.

   fuzz -t TARGET: prints the time limit of one execution of TARGET in
   milliseconds, which fuzz.sh gives AFL++. *)

(* A longer input is skipped, not passed to the target. The reader and
   the parser are linear, so a longer input reaches no path a shorter one
   cannot, and it slows each execution. The bound keeps a linear run well
   inside the time limit that fuzz.sh gives AFL++, while a step quadratic
   in the bytes or tokens of an input this long exceeds it and is
   reported as a hang. One quadratic in a sparser unit, such as line
   markers, may stay inside it. The work of the stages after the parser
   is held by the budgets of design 3.5 rule 7, which a source of a few
   hundred bytes can fill, so a shorter bound would not shorten their
   slowest run. *)
let max_input_bytes = 16 * 1024

(* The major heap of a linear stage stays within a fixed allowance for
   the runtime and the harness plus a constant number of words per input
   byte; reaching past it means memory superlinear in the input. The
   densest input measured, max_input_bytes of a declarator of '*' in the
   parser target, peaks at about 21_000 words at start-up plus 50 words
   per byte; in the reader target, all ';' needs 26. The allowance per
   byte is about twice the higher rate and the fixed one about five
   times the start-up heap, so the slack the GC keeps is not reported.
   The peak counts what the checks of a target allocate too, and it holds
   for the default GC settings, which fuzz.sh keeps by unsetting
   OCAMLRUNPARAM. *)
let heap_words_fixed = 100_000
let heap_words_per_input_byte = 100

let linear_heap_words input_bytes =
  heap_words_fixed + (heap_words_per_input_byte * input_bytes)

(* The declaration reader and lowering are not linear: a source of a few
   hundred bytes can need instances, or copies of deferred statements,
   whose text grows exponentially with it. Design 3.5 rule 7 bounds that
   text by the instance budget and the output limit, so their heap stays
   within a constant number of words per byte of the two. The densest
   input measured, 14 slice_from_array operands nested in one another,
   peaks at 0.48 words per byte that lowering charges the output limit;
   49 aliases 8 deep over structures, which nearly fill the instance
   budget, at 23 million words, 0.46 per byte of the two budgets. The
   allowance assumes both budgets filled at about twice the higher rate,
   on top of that of the reader and the parser: some 51 million words. *)
let heap_words_per_budget_byte = 1

let budgeted_heap_words input_bytes =
  let budgets =
    Typec_sema.Declarations.instance_budget
    + Typec_sema.Output_limit.of_length input_bytes
  in
  linear_heap_words input_bytes + (heap_words_per_budget_byte * budgets)

(* The time limit of one execution of a linear target. AFL++ saves an
   input as a hang only if it exceeds the limit again in a second run with
   twice the limit (fuzz.sh), so that a busy host does not make one. The
   limit is about five times the slowest linear run measured, 65 ms,
   while a step quadratic in the 16K bytes or tokens of an input would
   cost thousands of times more. A step quadratic in something sparser,
   such as line markers, can stay inside it. *)
let linear_time_limit_ms = 300

(* The stages after the parser run as long as the budgets of design 3.5
   rule 7 let them, whatever the length of the input. The slowest input
   measured, the 49 aliases over structures above, which write 11 MB of
   C, takes 1.7 s in the instrumented harness; the limit is about three
   times that. *)
let budgeted_time_limit_ms = 5000

(* A fuzz target: the check of its module, the bound on the major heap
   that its stages keep for an input of a given length, and its time
   limit. *)
type target = {
  check : string -> unit;
  heap_words : int -> int;
  time_limit_ms : int;
}

let linear check =
  { check; heap_words = linear_heap_words;
    time_limit_ms = linear_time_limit_ms }

let budgeted check =
  { check; heap_words = budgeted_heap_words;
    time_limit_ms = budgeted_time_limit_ms }

let targets =
  [ ("reader", linear Reader_target.check);
    ("parser", linear Parser_target.check);
    ("lowering", budgeted Lowering_target.check) ]

let usage () =
  let names = String.concat ", " (List.map fst targets) in
  prerr_endline ("usage: fuzz [-t] TARGET [FILE]; targets: " ^ names);
  exit 2

(* The input, or None when it is longer than max_input_bytes. *)
let read_input channel =
  let buffer = Buffer.create 4096 in
  (try Buffer.add_channel buffer channel (max_input_bytes + 1)
   with End_of_file -> ());
  if Buffer.length buffer > max_input_bytes then None
  else Some (Buffer.contents buffer)

(* The exit code in AFL_CRASH_EXITCODE, which AFL++ takes as a crash,
   when it is one a crash can use: not 0, which is success, and below
   the codes a shell gives to a signal. *)
let crash_exit_code () =
  let variable = Sys.getenv_opt "AFL_CRASH_EXITCODE" in
  match Option.bind variable int_of_string_opt with
  | Some code when 1 <= code && code <= 125 -> Some code
  | _ -> None

(* fuzz.sh sets AFL_CRASH_EXITCODE because the crash reporter of macOS
   can hold a signalled process for seconds, which AFL++ would take as a
   hang. *)
let crash message =
  prerr_endline ("fuzz: " ^ message);
  match crash_exit_code () with
  | Some code -> exit code
  | None ->
      Unix.kill (Unix.getpid ()) Sys.sigabrt;
      (* SIGABRT is not caught, so the process never gets here. *)
      exit 134

let check_heap heap_words input_bytes =
  let peak = (Gc.quick_stat ()).top_heap_words in
  let bound = heap_words input_bytes in
  if peak > bound then
    crash
      (Printf.sprintf "the major heap peaked at %d words, over %d for %d bytes"
         peak bound input_bytes)

(* The heap is checked at the end of every major cycle as well as at the
   end, so that a runaway stops at its bound rather than at the time
   limit, which may be seconds of allocation later. *)
let run target input =
  let input_bytes = String.length input in
  ignore (Gc.create_alarm (fun () -> check_heap target.heap_words input_bytes));
  match target.check input with
  | () -> check_heap target.heap_words input_bytes
  | exception exn ->
      let backtrace = Printexc.get_backtrace () in
      crash ("uncaught exception " ^ Printexc.to_string exn ^ "\n" ^ backtrace)

let run_on_channel target channel =
  match read_input channel with
  | None -> ()
  | Some input -> run target input

let target_named name =
  match List.assoc_opt name targets with
  | Some target -> target
  | None -> usage ()

let () =
  Printexc.record_backtrace true;
  match Array.to_list Sys.argv with
  | [ _; "-t"; name ] ->
      print_endline (string_of_int (target_named name).time_limit_ms)
  | [ _; name ] -> run_on_channel (target_named name) stdin
  | [ _; name; path ] ->
      let target = target_named name in
      In_channel.with_open_bin path (run_on_channel target)
  | _ -> usage ()
