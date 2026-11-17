# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The calc example of README.md for the tests of its build rules, sourced
# by each. It writes the files of the README into readme, and unsets the
# variables of the environment that change what make, ninja or CMake run
# or print.
#
# calc_directory NAME FILE...: makes the directory NAME and enters it,
# with FILE... of the README, main.c, calc.h and calc.tc. calc.tc keeps
# its Type-C declaration in command.tci, an interface that it includes,
# so that a rule that compiled it as C would fail.

unset CFLAGS CPPFLAGS LDFLAGS LDLIBS TARGET_ARCH MAKEFLAGS MFLAGS \
  MAKELEVEL NINJA_STATUS
sh ./readme.sh --files ../../README.md readme || exit 1

calc_directory() {
  calc_name=$1
  shift
  mkdir "$calc_name" && cd "$calc_name" || return
  for calc_file in "$@" main.c calc.h; do
    cp "../readme/$calc_file" . || return
  done
  grep '^type command ' ../readme/calc.tc > command.tci &&
    sed 's/^type command .*/#include "command.tci"/' ../readme/calc.tc \
      > calc.tc
}
