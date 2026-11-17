(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Raised at the first step that fails, with its message, and caught once
   in write. *)
exception Failed of string

let fail format = Printf.ksprintf (fun message -> raise (Failed message)) format

let not_ours path =
  fail
    "%s is not a header that typec wrote, and typec does not write over \
     it: name another path with -o"
    path

(* The first bytes of the regular file [found] at [path], at most
   [count]. The file is opened without blocking, and read only where it
   is still the file that lstat found, as another process may have put a
   link or a FIFO in its place since. *)
let read_start path (found : Unix.stats) count =
  let flags = Unix.[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  let file =
    try Unix.openfile path flags 0 with Unix.Unix_error _ -> not_ours path
  in
  Fun.protect
    ~finally:(fun () -> Unix.close file)
    (fun () ->
      let opened = Unix.fstat file in
      if (opened.st_dev, opened.st_ino) <> (found.st_dev, found.st_ino) then
        not_ours path;
      let bytes = Bytes.create count in
      let rec fill offset =
        let got = Unix.read file bytes offset (count - offset) in
        if got = 0 || offset + got = count then offset + got
        else fill (offset + got)
      in
      Bytes.sub_string bytes 0 (fill 0))

(* The permissions of the header that [path] holds, or None where nothing
   stands there. *)
let existing_permissions ~first_line path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | { st_kind = Unix.S_REG; st_perm; _ } as found ->
      let expected = first_line ^ "\n" in
      if read_start path found (String.length expected) <> expected then
        not_ours path;
      Some st_perm
  | _ -> not_ours path

(* A name that no file had: one taken in the meantime is tried again
   with another, so a name planted beforehand is never opened. *)
let rec create_new ~attempts random directory base =
  let name =
    Filename.concat directory
      (Printf.sprintf ".%s.%06x.tmp" base
         (Random.State.bits random land 0xffffff))
  in
  let flags = Unix.[ O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC ] in
  match Unix.openfile name flags 0o666 with
  | file -> (name, file)
  | exception Unix.Unix_error (Unix.EEXIST, _, _) when attempts > 1 ->
      create_new ~attempts:(attempts - 1) random directory base

(* Tries at a unique name before giving up, each failing only when
   another file took that name first. *)
let unique_name_attempts = 100

let write_all file text =
  let bytes = Bytes.unsafe_of_string text in
  let rec from offset =
    if offset < Bytes.length bytes then
      from (offset + Unix.write file bytes offset (Bytes.length bytes - offset))
  in
  from 0

let write_new ~permissions path text =
  let random = Random.State.make_self_init () in
  let name, file =
    create_new ~attempts:unique_name_attempts random (Filename.dirname path)
      (Filename.basename path)
  in
  match
    Fun.protect
      ~finally:(fun () -> Unix.close file)
      (fun () ->
        Option.iter (Unix.fchmod file) permissions;
        write_all file text);
    Unix.rename name path
  with
  | () -> ()
  | exception error ->
      (try Unix.unlink name with Unix.Unix_error _ -> ());
      raise error

let write ~first_line ~path text =
  match
    let permissions = existing_permissions ~first_line path in
    write_new ~permissions path text
  with
  | () -> Ok ()
  | exception Failed message -> Error message
  | exception Fun.Finally_raised (Unix.Unix_error (error, call, _))
  | exception Unix.Unix_error (error, call, _) ->
      Error
        (Printf.sprintf "cannot write the header %s: %s: %s" path call
           (Unix.error_message error))
