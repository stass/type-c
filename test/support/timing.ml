(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Whether the time of some work grows with its size at most as a power
   of it, judged by the ratio of its times at two sizes. A bound in
   seconds would depend on the speed of the host, and an emulated host
   is ten times slower; the ratio does not. *)

(* The large size is this many times the small one. *)
let size_factor = 4

(* The most that the time may grow from the small size to the large,
   where it should grow as the size to the power [degree]. Linear work
   takes [size_factor] times as long at the large size and quadratic
   work [size_factor] squared times; the bound lies halfway between the
   power and the next on a log scale, so that noise of up to twice
   either way does not change the verdict: 8 for linear work. *)
let bound ~degree =
  float_of_int size_factor ** (float_of_int degree +. 0.5)

(* A time is measured over runs that take at least this many seconds of
   CPU in all, so that neither the timer's resolution nor the noise of
   one short run decides the ratio. *)
let shortest_measurement = 0.05

(* The CPU seconds that one [run size] takes, on average. A collection
   first keeps the garbage of earlier work out of this one's time. *)
let seconds_per_run run size =
  Gc.full_major ();
  let started = Sys.time () in
  let rec repeat runs =
    run size;
    let elapsed = Sys.time () -. started in
    if elapsed >= shortest_measurement then elapsed /. float_of_int runs
    else repeat (runs + 1)
  in
  repeat 1

(* The times of [run small] and [run (size_factor * small)] where the
   second takes over [bound ~degree] times as long as the first, that
   is, where the time of [run] grows faster than its size to the power
   [degree]; [None] where it does not. [run] may run many times at each size. *)
let outgrows ~degree ~small run =
  let large = size_factor * small in
  let small_time = seconds_per_run run small in
  let large_time = seconds_per_run run large in
  let most = bound ~degree in
  if large_time <= most *. small_time then None
  else
    Some
      (Printf.sprintf "took %.3f s at %d and %.3f s at %d, over %.0f times"
         small_time small large_time large most)
