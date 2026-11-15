(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let private_mode = 0o700
let create () = Filename.temp_dir ~perms:private_mode "typec" ""
let make_subdirectory path = Sys.mkdir path private_mode

(* The removal must not raise: it runs on the way out of every path. *)
let report message =
  try prerr_endline ("typec: cannot remove the temporary directory: " ^ message)
  with Sys_error _ -> ()

(* lstat, so that a symbolic link is removed and not followed. *)
let rec remove_tree path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Sys.rmdir path
  | _ -> Sys.remove path

let remove dir =
  try remove_tree dir with
  | Sys_error message -> report message
  | Unix.Unix_error (error, _, path) ->
      report (path ^ ": " ^ Unix.error_message error)
