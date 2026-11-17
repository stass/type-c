SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the types of C. type_probe reads the
target model from a backend's predefined macros and writes static
assertions of what typec computes for that target: the integer promotions,
those of bit-fields, the usual arithmetic conversions, the integer type of
enumerations and the compatibility of pairs of types, where typec knows
it. The backend compiles the file only if it agrees on every one. The backends are those that
backends.sh names, for two targets (its second_target), in C11 so that
`int ()` declares no prototype.

  $ probe() {
  >   ./type_probe.exe "$@" -std=gnu11 > probe.c &&
  >   "$@" -std=gnu11 -fsyntax-only probe.c
  > }
  $ . ./backends.sh
  $ probe "$clang"
  $ probe "$clang" $second_target
  $ probe "$gcc"
  $ probe "$gcc" $second_target

Under short enumerations the rule begins its lists with the types of
lower rank than int, and the target query learns that representation. The
embedded targets are checked where Clang has them, each under both
representations; msp430 has an int of 16 bits, where the rule goes by rank
and an enumeration below int promotes to int.

  $ probe "$clang" -fshort-enums
  $ probe "$gcc" -fshort-enums
  $ for target in thumbv7m-none-eabi aarch64-none-elf msp430-elf; do
  >   if "$clang" --target=$target -E -x c /dev/null > /dev/null 2>&1; then
  >     probe "$clang" --target=$target -fshort-enums || echo "$target short"
  >     probe "$clang" --target=$target -fno-short-enums || echo "$target int"
  >   fi
  > done
