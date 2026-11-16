(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = { before : int }

let before token = { before = token }

type 'a item = { declaration : 'a }

let item declaration = { declaration }
