(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Running a stage whose interface bounds its recursion on a small stack,
   so that recursion growing with the input overflows it and raises
   Stack_overflow. The runtime enforces a stack limit only when a stack
   has to grow, so the stage runs on a fiber of its own, whose stack
   starts small whatever ran before it. *)

(* The parser at Parser.max_nesting needs between 8K and 16K words, as
   measured on brackets of every kind nested that deep; twice that leaves
   room for frames a change adds. A recursion of more than two words per
   token overflows it within the 16K tokens of the fuzz harness's largest
   input. The runtime doubles a stack while it is below the limit, so a
   power of two is the size it reaches. *)
let limit_words = 32 * 1024

let set_limit words = Gc.set { (Gc.get ()) with stack_limit = words }

(* A stage performs no effects, so the handler only gives the fiber. An
   exception leaves it with its backtrace, which names the frame that
   raised it. *)
let on_fresh_fiber stage =
  let reraise exn =
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  in
  Effect.Deep.match_with stage ()
    { retc = Fun.id; exnc = reraise; effc = (fun _ -> None) }

let run stage =
  let saved = (Gc.get ()).stack_limit in
  let limited () =
    set_limit limit_words;
    stage ()
  in
  Fun.protect ~finally:(fun () -> set_limit saved) (fun () ->
      on_fresh_fiber limited)
