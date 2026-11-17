(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Whether the work of some code grows with its size at most as a power
   of it, judged by the ratio of its work at two sizes, measured two
   ways that each cover what the other misses:
   - the words that the code allocates, which are the same on every
     run whatever the load or the speed of the host, but do not count a
     quadratic scan that allocates nothing, such as a search of a list;
   - the CPU seconds of the process, least over several runs so that a
     busy host, which only slows a run, does not decide the ratio; a
     bound in seconds would depend on the speed of the host, and an
     emulated host is ten times slower, but the ratio does not.
   The work fails when either measure outgrows its bound. *)

(* The large size is this many times the small one. *)
let size_factor = 4

(* The most that the work may grow from the small size to the large,
   where it should grow as the size to the power [degree]. Linear work
   takes [size_factor] times as much at the large size and quadratic
   work [size_factor] squared times; the bound lies halfway between the
   power and the next on a log scale, so that a logarithmic factor (a
   set or a map), a cache that the large size outgrows and a small
   quadratic share of the work pass: 8 for linear work. *)
let bound ~degree =
  float_of_int size_factor ** (float_of_int degree +. 0.5)

(* The words that one [run size] allocates. *)
let words_allocated run size =
  let bytes_per_word = float_of_int (Sys.word_size / 8) in
  let before = Gc.allocated_bytes () in
  run size;
  (Gc.allocated_bytes () -. before) /. bytes_per_word

(* A time is measured over runs that take at least this many seconds of
   CPU in all, so that the resolution of the timer does not decide it. *)
let shortest_sample = 0.02

(* Samples of the time, of which the least counts: noise from other
   processes adds to a sample and never takes from it. *)
let samples = 5

(* The CPU seconds that one [run size] takes, on average over one
   sample. A collection first keeps the garbage of earlier work out of
   the sample. *)
let seconds_per_run run size =
  Gc.full_major ();
  let started = Sys.time () in
  let rec repeat runs =
    run size;
    let elapsed = Sys.time () -. started in
    if elapsed >= shortest_sample then elapsed /. float_of_int runs
    else repeat (runs + 1)
  in
  repeat 1

(* The least of the samples of [seconds_per_run]. *)
let least_seconds run size =
  List.init samples (fun _ -> seconds_per_run run size)
  |> List.fold_left Float.min Float.infinity

(* A description of the growth from [small] to [large] if it exceeds
   [most] times, in [unit]; [None] if it does not. *)
let exceeds ~most ~unit_name ~small ~large small_work large_work =
  if large_work <= most *. small_work then None
  else
    Some
      (Printf.sprintf "%s: %.3g at %d and %.3g at %d, over %.0f times"
         unit_name small_work small large_work large most)

(* The growth of [run small] to [run (size_factor * small)] where the
   work grows faster than the size to the power [degree], in words
   allocated or in seconds; [None] where it does not. [run] runs many
   times at each size. *)
let outgrows ~degree ~small run =
  let large = size_factor * small in
  let most = bound ~degree in
  let in_words =
    exceeds ~most ~unit_name:"words allocated" ~small ~large
      (words_allocated run small)
      (words_allocated run large)
  in
  match in_words with
  | Some _ -> in_words
  | None ->
      exceeds ~most ~unit_name:"CPU seconds" ~small ~large
        (least_seconds run small)
        (least_seconds run large)
