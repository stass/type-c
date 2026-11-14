(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = {
  passed : int;
  failed : string list;
  failed_with_backend : string list;
}

let none = { passed = 0; failed = []; failed_with_backend = [] }

(* The first line that starts with TEST and is not a result. *)
exception Malformed of string

(* The lists are built in reverse and turned around once, at the end. *)
let add_line counts line =
  match String.split_on_char ' ' line with
  | "TEST" :: kind :: words -> (
      let name = String.concat " " words in
      if String.trim name <> name || name = "" then raise (Malformed line);
      match kind with
      | "pass" -> { counts with passed = counts.passed + 1 }
      | "fail" -> { counts with failed = name :: counts.failed }
      | "fail-with-backend" ->
          let failed_with_backend = name :: counts.failed_with_backend in
          { counts with failed_with_backend }
      | _ -> raise (Malformed line))
  | [ "TEST" ] -> raise (Malformed line)
  | _ -> counts

let read output =
  match List.fold_left add_line none (String.split_on_char '\n' output) with
  | counts ->
      Ok
        {
          counts with
          failed = List.rev counts.failed;
          failed_with_backend = List.rev counts.failed_with_backend;
        }
  | exception Malformed line ->
      Error (Printf.sprintf "not a test result: %S" line)
