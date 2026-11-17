(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Writing the header of an interface, and the dependency rule of the
    header, to their paths (design 9.3). *)

type file
(** A text bound for a path, and what may stand there to be replaced. *)

val header : first_line:string -> path:string -> string -> file
(** [header ~first_line ~path text] replaces nothing or a regular file,
    not reached through a symbolic link, that begins with the line
    [first_line]: a header that typec wrote. *)

val rule : path:string -> string -> file
(** [rule ~path text] replaces nothing or a regular file, not reached
    through a symbolic link, whatever it holds. *)

val write : file list -> (unit, string) result
(** [write files] writes the text of each file to its path. A path that
    holds anything that the file does not replace is an error, found
    without reading through a link or blocking on a FIFO. Each text goes
    to a new file of a unique name in the directory of its path, created
    exclusively, with the permissions of the file it replaces, or where
    nothing stood those that the umask leaves of [0666]. Only once every
    new file is written are they renamed to their paths, a rule before a
    header so that make builds again a header whose rename fails. On a
    failure the new files not yet renamed are removed, so a refusal, or a
    failure to write a new file, leaves every path as it was; a failure
    to rename one leaves those before it in place. The error is the
    message. *)
