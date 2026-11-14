SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The all-headers translation unit (plan, Stage 0 exit gate item 3)
includes every C11 standard header and every POSIX header that the host
has, and parses as each backend preprocesses it in each dialect and
feature mode. parse_check fails at the first construct it does not
parse, so a passing run prints nothing.

  $ clang=/usr/bin/clang
  $ gcc=/usr/local/bin/gcc-16

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

A header that a backend does not have, or cannot preprocess alone, is
left out of that backend's unit.

  $ includes() {
  >   while read -r header; do
  >     if printf '#include <%s>\n' "$header" |
  >       "$1" -std=gnu11 -E -x c - > /dev/null 2>&1; then
  >       printf '#include <%s>\n' "$header"
  >     fi
  >   done < headers.txt
  > }
  $ includes "$clang" > all-clang.c
  $ includes "$gcc" > all-gcc.c

Neither unit is a handful of headers: both hold stdio.h and unistd.h.

  $ grep -c -e '<stdio.h>' -e '<unistd.h>' all-clang.c all-gcc.c
  all-clang.c:2
  all-gcc.c:2

Each unit parses in ISO and GNU C11, and with the feature macros that
widen what the headers declare.

  $ parse_all() {
  >   for mode in "-std=gnu11" "-std=c11" "-std=gnu11 -D_GNU_SOURCE" \
  >     "-std=c11 -D_DARWIN_C_SOURCE" "-std=c11 -D_POSIX_C_SOURCE=200809L"; do
  >     "$1" $mode -E "$2" > all.i || return 1
  >     ./parse_check.exe all.i > /dev/null || return 1
  >   done
  > }
  $ parse_all "$clang" all-clang.c
  $ parse_all "$gcc" all-gcc.c
