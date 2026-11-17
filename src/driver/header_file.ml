(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Raised where the file at the path is not one that typec writes over,
   and caught in failing_as. *)
exception Refused

(* What a file is, which says what its write may replace besides
   nothing: a header replaces one that typec wrote, which begins with
   [first_line], and a dependency rule any regular file, as cc writes
   over any file that -MF names. *)
type kind = Header of { first_line : string } | Rule

(* The first bytes of the regular file [found] at [path], at most
   [count]. The file is opened without blocking, and read only where it
   is still the file that lstat found, as another process may have put a
   link or a FIFO in its place since. *)
let read_start path (found : Unix.stats) count =
  let flags = Unix.[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  let file =
    try Unix.openfile path flags 0 with Unix.Unix_error _ -> raise Refused
  in
  Fun.protect
    ~finally:(fun () -> Unix.close file)
    (fun () ->
      let opened = Unix.fstat file in
      if (opened.st_dev, opened.st_ino) <> (found.st_dev, found.st_ino) then
        raise Refused;
      let bytes = Bytes.create count in
      let rec fill offset =
        let got = Unix.read file bytes offset (count - offset) in
        if got = 0 || offset + got = count then offset + got
        else fill (offset + got)
      in
      Bytes.sub_string bytes 0 (fill 0))

let check_start kind path found =
  match kind with
  | Rule -> ()
  | Header { first_line } ->
      let expected = first_line ^ "\n" in
      if read_start path found (String.length expected) <> expected then
        raise Refused

(* The permissions of the file that [path] holds, or None where nothing
   stands there. *)
let existing_permissions kind path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | { st_kind = Unix.S_REG; st_perm; _ } as found ->
      check_start kind path found;
      Some st_perm
  | _ -> raise Refused

(* The mode a new file is created with: [0666] where nothing stood,
   which the umask or the directory's default ACL then cuts down, and
   for one that replaces a file, its owner's alone until it is given
   that file's permissions, so that it is never readable for a moment by
   those whom they keep from it. *)
let creation_mode = function None -> 0o666 | Some _ -> 0o600

(* A name that no file had: one taken in the meantime is tried again
   with another, so a name planted beforehand is never opened. *)
let rec create_new ~attempts ~mode random directory base =
  let name =
    Filename.concat directory
      (Printf.sprintf ".%s.%06x.tmp" base
         (Random.State.bits random land 0xffffff))
  in
  let flags = Unix.[ O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC ] in
  match Unix.openfile name flags mode with
  | file -> (name, file)
  | exception Unix.Unix_error (Unix.EEXIST, _, _) when attempts > 1 ->
      create_new ~attempts:(attempts - 1) ~mode random directory base

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

type file = {
  path : string;
  text : string;
  kind : kind;
  what : string;  (** names the file in a message *)
  refusal : string;  (** the message where [kind] refuses what stands *)
}

let header ~first_line ~path text =
  {
    path;
    text;
    kind = Header { first_line };
    what = "the header";
    refusal =
      Printf.sprintf
        "%s is not a header that typec wrote, and typec does not write \
         over it: name another path with -o"
        path;
  }

let rule ~path text =
  {
    path;
    text;
    kind = Rule;
    what = "the dependency rule";
    refusal =
      Printf.sprintf
        "%s is not a regular file, and typec does not write the dependency \
         rule over it: name another path with -MF"
        path;
  }

(* Raised at the first step of a write that fails, with its message, and
   caught once in write. *)
exception Failed of string

(* [step] on [file], its failures raised as the message of the file. *)
let failing_as file step =
  try step () with
  | Refused -> raise (Failed file.refusal)
  | Fun.Finally_raised (Unix.Unix_error (error, call, _))
  | Unix.Unix_error (error, call, _) ->
      raise
        (Failed
           (Printf.sprintf "cannot write %s %s: %s: %s" file.what file.path
              call (Unix.error_message error)))

(* A rule is renamed into place before a header: where the header's
   rename then fails, the old header is older than what changed and make
   builds it again, where a new header beside an old rule would stand as
   up to date. *)
let rules_first staged =
  let rules, headers =
    List.partition (fun (file, _) -> file.kind = Rule) staged
  in
  rules @ headers

(* Every file is written to a new file beside its path before any is
   renamed, so that a refusal or a failure to write one leaves every path
   as it was. [unplaced] holds the new files not yet renamed, which any
   failure removes. *)
let write files =
  let random = Random.State.make_self_init () in
  let unplaced = ref [] in
  let stage file =
    failing_as file (fun () ->
        let permissions = existing_permissions file.kind file.path in
        let temporary, descriptor =
          create_new ~attempts:unique_name_attempts
            ~mode:(creation_mode permissions) random
            (Filename.dirname file.path)
            (Filename.basename file.path)
        in
        unplaced := !unplaced @ [ (file, temporary) ];
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            write_all descriptor file.text;
            Option.iter (Unix.fchmod descriptor) permissions))
  in
  let rec place = function
    | [] -> ()
    | (file, temporary) :: rest ->
        failing_as file (fun () -> Unix.rename temporary file.path);
        unplaced := rest;
        place rest
  in
  let remove (_, temporary) =
    try Unix.unlink temporary with Unix.Unix_error _ -> ()
  in
  match
    List.iter stage files;
    place (rules_first !unplaced)
  with
  | () -> Ok ()
  | exception error -> (
      List.iter remove !unplaced;
      match error with Failed message -> Error message | _ -> raise error)
