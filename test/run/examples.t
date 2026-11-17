SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Each example of examples/ builds with its Makefile, typec as the C
compiler, on each backend at -O0 and at -O2 with -Wall -Wextra -Werror,
and passes its "make check", which compares the Type-C program with the C
program that it ports. An example builds in a copy of its directory,
cleaned first of what a build in the checkout left there. GNU make is
gmake where make is another, as on FreeBSD.

  $ . ./backends.sh
  $ make=$(command -v gmake || command -v make)
  $ unset CFLAGS CPPFLAGS LDFLAGS LDLIBS TARGET_ARCH MAKEFLAGS MFLAGS \
  >   MAKELEVEL
  $ check() {
  >   status=0
  >   for example in ../../examples/*/; do
  >     name=$(basename "$example")
  >     rm -rf "$name" && cp -RL "$example" "$name" &&
  >       chmod -R u+w "$name" && (
  >         cd "$name" && export TYPEC_CC=$1 &&
  >           "$make" -s clean &&
  >           "$make" -s check CFLAGS="$2 -Wall -Wextra -Werror"
  >       ) || status=1
  >   done
  >   return $status
  > }

  $ check "$clang" -O0
  cut: 102 cases agree with original/cut, 8 with cut(1)
  dns: 27 cases agree with original/dns
  queue: 8 inputs agree with original/sched
  $ check "$clang" -O2
  cut: 102 cases agree with original/cut, 8 with cut(1)
  dns: 27 cases agree with original/dns
  queue: 8 inputs agree with original/sched
  $ check "$gcc" -O0
  cut: 102 cases agree with original/cut, 8 with cut(1)
  dns: 27 cases agree with original/dns
  queue: 8 inputs agree with original/sched
  $ check "$gcc" -O2
  cut: 102 cases agree with original/cut, 8 with cut(1)
  dns: 27 cases agree with original/dns
  queue: 8 inputs agree with original/sched
