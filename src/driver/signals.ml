(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ending_signals =
  [ Sys.sighup; Sys.sigint; Sys.sigpipe; Sys.sigquit; Sys.sigterm ]

let first_caught = ref None

(* The handler only records, so no exception arrives in the middle of a
   step or of the removal of the temporary directory. *)
let record signal =
  if !first_caught = None then first_caught := Some signal

let catch () =
  List.iter
    (fun signal ->
      match Sys.signal signal (Sys.Signal_handle record) with
      | Sys.Signal_ignore -> Sys.set_signal signal Sys.Signal_ignore
      | Sys.Signal_default | Sys.Signal_handle _ -> ())
    ending_signals

let caught () = !first_caught

(* The base of the status a shell reports for a command that a signal
   ended, for the case that the signal does not end typec; the host's
   number of the signal is not known to OCaml. *)
let exit_after_signal = 128

(* The action of SIGKILL and SIGSTOP cannot be set, and is the default. *)
let end_by signal =
  (try Sys.set_signal signal Sys.Signal_default with Sys_error _ -> ());
  (try Unix.kill (Unix.getpid ()) signal with Unix.Unix_error _ -> ());
  exit exit_after_signal
