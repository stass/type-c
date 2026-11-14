(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = { const : bool; volatile : bool; restrict : bool; atomic : bool }

let none = { const = false; volatile = false; restrict = false; atomic = false }

let union a b =
  {
    const = a.const || b.const;
    volatile = a.volatile || b.volatile;
    restrict = a.restrict || b.restrict;
    atomic = a.atomic || b.atomic;
  }
