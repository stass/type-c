(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* fuzz TARGET [FILE]: runs the fuzz target TARGET on the bytes of FILE,
   or of standard input without one, once per process, as AFL++ runs it.
   A target returns for an input it accepts or rejects as its interface
   documents and raises for anything else. The harness turns a raised
   exception, or a heap beyond the bound below, into a crash for AFL++
   (see crash); the message on standard error says which. *)

(* Each target is a module with [check : string -> unit]. *)
let targets = [ ("reader", Reader_target.check) ]

(* A longer input is skipped, not passed to the target. Every stage under
   test is linear, so a longer input reaches no path a shorter one
   cannot, and it slows each execution. The bound keeps a linear run well
   inside the time limit that fuzz.sh gives AFL++, while a step quadratic
   in the bytes or tokens of an input this long exceeds it and is
   reported as a hang. One quadratic in a sparser unit, such as line
   markers, may stay inside it. *)
let max_input_bytes = 16 * 1024

(* The major heap of a linear stage stays within a fixed allowance for
   the runtime and the harness plus a constant number of words per input
   byte; reaching past it means memory superlinear in the input. The
   densest input measured, max_input_bytes of ';', peaks at about 21_000
   words at start-up plus 26 words per byte. The allowance per byte is
   about twice that rate and the fixed one about five times the start-up
   heap, so the slack the GC keeps is not reported. The peak counts what
   the checks of a target allocate too, and it holds for the default GC
   settings, which fuzz.sh keeps by unsetting OCAMLRUNPARAM. *)
let heap_words_fixed = 100_000
let heap_words_per_input_byte = 50

let usage () =
  let names = String.concat ", " (List.map fst targets) in
  prerr_endline ("usage: fuzz TARGET [FILE]; targets: " ^ names);
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

let check_heap input_bytes =
  let peak = (Gc.quick_stat ()).top_heap_words in
  let bound = heap_words_fixed + (heap_words_per_input_byte * input_bytes) in
  if peak > bound then
    crash
      (Printf.sprintf "the major heap peaked at %d words, over %d for %d bytes"
         peak bound input_bytes)

let run check input =
  match check input with
  | () -> check_heap (String.length input)
  | exception exn ->
      let backtrace = Printexc.get_backtrace () in
      crash ("uncaught exception " ^ Printexc.to_string exn ^ "\n" ^ backtrace)

let run_on_channel check channel =
  match read_input channel with
  | None -> ()
  | Some input -> run check input

let target_named name =
  match List.assoc_opt name targets with
  | Some check -> check
  | None -> usage ()

let () =
  Printexc.record_backtrace true;
  match Array.to_list Sys.argv with
  | [ _; name ] -> run_on_channel (target_named name) stdin
  | [ _; name; path ] ->
      let check = target_named name in
      In_channel.with_open_bin path (run_on_channel check)
  | _ -> usage ()
