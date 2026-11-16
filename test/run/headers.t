SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The all-headers translation unit (plan, Stage 0 exit gate item 3)
includes every C11 standard header and every POSIX header that the host
has and the backend compiles, and parses as each backend preprocesses it
in each dialect and feature mode, and its declarations are read.
parse_check fails at the first construct it does not parse, and typec
--emit-c, which runs the whole front end, at the first error, so a
passing run prints nothing.

  $ . ./backends.sh

The C11 headers (C11 7.1.2) and then the POSIX.1-2017 headers.

  $ cat > headers.txt <<'EOF'
  > assert.h
  > complex.h
  > ctype.h
  > errno.h
  > fenv.h
  > float.h
  > inttypes.h
  > iso646.h
  > limits.h
  > locale.h
  > math.h
  > setjmp.h
  > signal.h
  > stdalign.h
  > stdarg.h
  > stdatomic.h
  > stdbool.h
  > stddef.h
  > stdint.h
  > stdio.h
  > stdlib.h
  > stdnoreturn.h
  > string.h
  > tgmath.h
  > threads.h
  > time.h
  > uchar.h
  > wchar.h
  > wctype.h
  > aio.h
  > arpa/inet.h
  > cpio.h
  > dirent.h
  > dlfcn.h
  > fcntl.h
  > fmtmsg.h
  > fnmatch.h
  > ftw.h
  > glob.h
  > grp.h
  > iconv.h
  > langinfo.h
  > libgen.h
  > monetary.h
  > mqueue.h
  > ndbm.h
  > net/if.h
  > netdb.h
  > netinet/in.h
  > netinet/tcp.h
  > nl_types.h
  > poll.h
  > pthread.h
  > pwd.h
  > regex.h
  > sched.h
  > search.h
  > semaphore.h
  > spawn.h
  > strings.h
  > stropts.h
  > sys/ipc.h
  > sys/mman.h
  > sys/msg.h
  > sys/resource.h
  > sys/select.h
  > sys/sem.h
  > sys/shm.h
  > sys/socket.h
  > sys/stat.h
  > sys/statvfs.h
  > sys/time.h
  > sys/times.h
  > sys/types.h
  > sys/uio.h
  > sys/un.h
  > sys/utsname.h
  > sys/wait.h
  > syslog.h
  > tar.h
  > termios.h
  > trace.h
  > ulimit.h
  > unistd.h
  > utime.h
  > utmpx.h
  > wordexp.h
  > EOF

The modes: GNU C17, which typec selects without a -std=, ISO and GNU
C11, and the feature macros that widen what the headers declare.

  $ cat > modes.txt <<'EOF'
  > -std=gnu17
  > -std=c11
  > -std=gnu11 -D_GNU_SOURCE
  > -std=c11 -D_DARWIN_C_SOURCE
  > -std=c11 -D_POSIX_C_SOURCE=200809L
  > EOF

A backend has a header when it preprocesses it alone in GNU C.

  $ present() {
  >   while read -r header; do
  >     printf '#include <%s>\n' "$header" |
  >       "$1" -std=gnu11 -E -x c - > /dev/null 2>&1 && echo "$header"
  >   done < headers.txt
  > }
  $ present "$clang" > present-clang.txt
  $ present "$gcc" > present-gcc.txt

The unit of a backend in a mode is built a header at a time: a header
stays if the backend compiles the unit so far with it (-fsyntax-only).
So the backend accepts the whole unit, and typec is asked to accept
what the backend accepts: a header that needs a feature macro that the
mode lacks (musl's aio.h in ISO C) is not demanded of typec there.
unit CC MODE PRESENT writes the unit to all.tc and the refused headers,
as "MODE: HEADER", to refused.txt.

  $ unit() {
  >   : > all.tc
  >   : > refused.txt
  >   while read -r header; do
  >     cp all.tc try.c
  >     printf '#include <%s>\n' "$header" >> try.c
  >     if "$1" $2 -fsyntax-only -x c try.c > /dev/null 2>&1; then
  >       cp try.c all.tc
  >     else
  >       echo "$2: $header" >> refused.txt
  >     fi
  >   done < "$3"
  > }

A header that drops out is reported, so that it is seen. The refusals
differ by host (the SDK of macOS, the C library of Linux), and the
expected output must not, so the report holds the refusals missing from
the list below, and a passing run prints none. An entry is added only
after checking that the backend itself refuses the header in that mode
on some host, never because typec refuses it. musl declares a member of
struct sigevent in aio.h, which signal.h defines only under a POSIX
feature macro, so aio.h is refused in the modes without one.

  $ cat > known-refusals.txt <<'EOF'
  > -std=c11: aio.h
  > -std=c11 -D_DARWIN_C_SOURCE: aio.h
  > EOF
  $ report() {
  >   grep -F -x -v -f known-refusals.txt refused.txt |
  >     while read -r line; do echo "$1: $line"; done
  > }

Each unit holds stdio.h and unistd.h, parses, and its declarations are
read. typec reads a .tc file, which all.tc is. The modes come on
descriptor 3, so that nothing in the loop reads them.

  $ parse_all() {
  >   while read -r mode <&3; do
  >     unit "$1" "$mode" "$2"
  >     report "$1"
  >     grep -q -e '<stdio.h>' all.tc || return 1
  >     grep -q -e '<unistd.h>' all.tc || return 1
  >     "$1" $mode -E -x c all.tc > all.i || return 1
  >     "$1" $mode -dM -E -x c /dev/null > all.macros || return 1
  >     ./parse_check.exe all.macros all.i > /dev/null || return 1
  >     typec --cc="$1" $mode --emit-c all.tc -o /dev/null || return 1
  >   done 3< modes.txt
  > }
  $ parse_all "$clang" present-clang.txt
  $ parse_all "$gcc" present-gcc.txt
