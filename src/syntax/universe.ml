(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The names that the universe scope declares (design 2.3). It encloses
    file scope, so a declaration of the same identifier in any scope
    hides the universe name from that point, under C's scope rules, and
    [int result = f();] keeps its meaning. Each name gets its meaning in
    work [package] of the plan, after design [section]; until then a use
    of one is an error, and each is an ordinary identifier to the
    grammar. *)

type t = { name : string; section : string; package : string }

let names =
  [
    { name = "option"; section = "3.6"; package = "2.3" };
    { name = "result"; section = "3.6"; package = "2.3" };
    { name = "slice"; section = "8"; package = "3.4" };
    { name = "str"; section = "8"; package = "3.4" };
    { name = "slice_from_array"; section = "8"; package = "3.4" };
    { name = "slice_sub"; section = "8"; package = "3.4" };
    { name = "slice_unchecked"; section = "8"; package = "3.4" };
  ]

let find name = List.find_opt (fun universe -> universe.name = name) names
