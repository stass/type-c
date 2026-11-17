(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The expected output of a cram test, which cram compares with what its
   commands print, so a check of it is a check of that output. *)

(* An output line is indented by two spaces and is neither a command
   ("  $ ") nor its continuation ("  > "). *)
let is_output line =
  String.starts_with ~prefix:"  " line
  && not
       (String.starts_with ~prefix:"  $ " line
       || String.starts_with ~prefix:"  > " line)

let output_lines path =
  In_channel.with_open_bin path In_channel.input_lines
  |> List.filter is_output
