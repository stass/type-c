(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_test_support

(* A recursion that is not a tail call, one frame per level. *)
let rec depth levels = if levels = 0 then 0 else 1 + depth (levels - 1)

let overflows levels =
  match Small_stack.run (fun () -> depth levels) with
  | _ -> false
  | exception Stack_overflow -> true

(* Each frame takes at least a word, so this many levels cannot fit. *)
let too_deep = 2 * Small_stack.limit_words

(* The frames that the backtrace of an overflow names. The handler and
   the caller give a few; the recursion that overflowed gives many. *)
let overflow_frames () =
  match Small_stack.run (fun () -> depth too_deep) with
  | _ -> 0
  | exception Stack_overflow ->
      Printexc.raw_backtrace_length (Printexc.get_raw_backtrace ())

let frames_of_the_stage = 100

(* The checks run in this order: the third grows the stack of the main
   fiber, which must not lift the limit for the fourth. *)
let failures () =
  let shallow_fits = not (overflows 1000) in
  let deep_overflows = overflows too_deep in
  let default_holds = depth too_deep = too_deep in
  let overflows_after_growth = overflows too_deep in
  let restored = (Gc.get ()).stack_limit > Small_stack.limit_words in
  let traced = overflow_frames () > frames_of_the_stage in
  List.filter_map
    (fun (name, holds) -> if holds then None else Some name)
    [
      ("a shallow recursion fits", shallow_fits);
      ("a deep recursion overflows", deep_overflows);
      ("the default stack holds it", default_holds);
      ("it overflows after the main stack grew", overflows_after_growth);
      ("the default limit is restored", restored);
      ("the backtrace names the stage", traced);
    ]

let () =
  Printexc.record_backtrace true;
  match failures () with
  | [] -> ()
  | failed ->
      List.iter (fun name -> prerr_endline ("FAIL: " ^ name)) failed;
      exit 1
