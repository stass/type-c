(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Writing the header of an interface to its path (design 9.3). *)

val write : first_line:string -> path:string -> string -> (unit, string) result
(** [write ~first_line ~path text] writes [text] to [path] where nothing
    stands there, or a regular file, not reached through a symbolic link,
    that begins with the line [first_line]; anything else is an error,
    found without reading through a link or blocking on a FIFO. The text
    goes to a new file of a unique name in the directory of [path],
    created exclusively, with the permissions of the file it replaces, or
    for a new header those that the umask leaves of [0666], which is then
    renamed to [path]. On a failure the new file is removed and the file
    at [path] is left as it was; the error is the message. *)
