(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = Refused | Environment | Internal

(* Design 13.2 says why no backend exits with these (P22). *)
let code = function Refused -> 80 | Environment -> 81 | Internal -> 82

(* Every constructor of [t]; one added there is added here too. *)
let every_failure = [ Refused; Environment; Internal ]

let of_code status =
  List.find_opt (fun failure -> code failure = status) every_failure
