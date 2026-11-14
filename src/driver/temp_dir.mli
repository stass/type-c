(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The private directory that holds the intermediate files of the
    pipeline (design 13.2). *)

val create : unit -> string
(** [create ()] makes a new, empty directory with mode 0700 in
    [Filename.get_temp_dir_name ()], which is [TMPDIR] or [/tmp], and
    returns its path. The directory is made with one [mkdir] of a name no
    file had, so no other user can have planted it or a link in its
    place. It raises [Sys_error] when the directory cannot be made. *)

val remove : string -> unit
(** [remove dir] removes the files in [dir] and then [dir]; the pipeline
    makes no subdirectories there. A symbolic link is removed, not
    followed. A failure is reported on stderr and leaves the rest in
    place. *)
