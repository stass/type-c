(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Running a stage whose interface bounds its recursion on a small stack,
   so that recursion growing with the input overflows it and raises
   Stack_overflow. The runtime enforces a stack limit only when a stack
   has to grow, so the stage runs on a fiber of its own, whose stack
   starts small whatever ran before it.

   A limit is given in words of amd64 frames. OCaml rounds every frame
   up to 16 bytes on arm64, so there the same recursion takes up to
   twice the words, and the limit is scaled to the platform. *)

(* The parser at Parser.max_nesting needs between 8K and 16K words, as
   measured on brackets of every kind nested that deep; twice that leaves
   room for frames a change adds. A recursion of more than two words per
   token overflows it within the 16K tokens of the fuzz harness's largest
   input. The runtime doubles a stack while it is below the limit, so a
   power of two is the size it reaches. *)
let limit_words = 32 * 1024

let set_limit words = Gc.set { (Gc.get ()) with stack_limit = words }

(* A recursion that keeps nothing but its return address takes one word
   a level on amd64 and two on arm64. *)
let amd64_minimal_frame_words = 1

(* The stack of the probe: large enough that the handler's own words
   do not change the rounded result. *)
let probe_limit_words = 64 * 1024

(* A stage performs no effects, so the handler only gives the fiber. An
   exception leaves it with its backtrace, which names the frame that
   raised it. *)
let on_fresh_fiber stage =
  let reraise exn =
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  in
  Effect.Deep.match_with stage ()
    { retc = Fun.id; exnc = reraise; effc = (fun _ -> None) }

let run_limited words stage =
  let saved = (Gc.get ()).stack_limit in
  let limited () =
    set_limit words;
    stage ()
  in
  Fun.protect ~finally:(fun () -> set_limit saved) (fun () ->
      on_fresh_fiber limited)

(* The words that the minimal frame takes on this platform, measured as
   the stack limit over the levels of a bare recursion that reach it,
   rounded to a whole word. A frame that holds more than its return
   address grows by less than that ratio, so it is an upper bound. *)
let minimal_frame_words =
  lazy
    (let levels = ref 0 in
     let rec recurse () =
       incr levels;
       1 + recurse ()
     in
     (match run_limited probe_limit_words recurse with
     | _ -> ()
     | exception Stack_overflow -> ());
     (probe_limit_words + (!levels / 2)) / !levels)

(* Runs [stage] on a stack of at most [words] of amd64 frames. *)
let run_within words stage =
  run_limited
    (words * Lazy.force minimal_frame_words / amd64_minimal_frame_words)
    stage

let run stage = run_within limit_words stage
