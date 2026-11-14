(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let private_mode = 0o700
let create () = Filename.temp_dir ~perms:private_mode "typec" ""

(* The removal must not raise: it runs on the way out of every path. *)
let report message =
  try prerr_endline ("typec: cannot remove the temporary directory: " ^ message)
  with Sys_error _ -> ()

let remove dir =
  try
    Array.iter
      (fun name -> Sys.remove (Filename.concat dir name))
      (Sys.readdir dir);
    Sys.rmdir dir
  with Sys_error message -> report message
