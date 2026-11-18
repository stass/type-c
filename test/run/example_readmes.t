SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The README of each example of examples/, but its blocks marked
untested, holds on both backends: the example builds with its Makefile
in a copy of its directory, cleaned first of what a build in the
checkout left there, and readme.sh runs the console blocks of the README
on copies of that build, with the README's edits and sh blocks marked
to run applied. It prints nothing when they agree. GNU make is gmake
where make is another, as on FreeBSD.

  $ . ./backends.sh
  $ make=$(command -v gmake || command -v make)
  $ unset CFLAGS CPPFLAGS LDFLAGS LDLIBS TARGET_ARCH MAKEFLAGS MFLAGS \
  >   MAKELEVEL
  $ check() {
  >   status=0
  >   for example in ../../examples/*/; do
  >     page=$(basename "$example")-$1
  >     mkdir "$page" && cp -RL "$example" "$page/base" &&
  >       chmod -R u+w "$page/base" && (
  >         cd "$page/base" && export TYPEC_CC=$2 &&
  >           "$make" -s clean && "$make" -s
  >       ) && (
  >         cd "$page" && sh ../readme.sh "$1" "$2" base/README.md base
  >       ) || status=1
  >   done
  >   return $status
  > }

  $ check clang "$clang"
  $ check gcc "$gcc"
