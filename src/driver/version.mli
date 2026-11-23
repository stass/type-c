(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The release of [typec]. *)

val release : string
(** [release] is the version that dune-project names, such as ["1.0"];
    the build generates it from there, its one source. *)
