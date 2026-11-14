(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The checks that more than one target makes. A broken property raises,
   which the harness reports as a crash. *)

open Typec_cpp

let violated property = failwith ("property violated: " ^ property)

(* Every stage refuses with a Reader.error, whose message escapes what
   the input spells, so that it never carries a control byte to a
   terminal. *)
let check_refusal error =
  if not (String.for_all Char.Ascii.is_print (Reader.error_message error))
  then violated "an error message is printable ASCII"
