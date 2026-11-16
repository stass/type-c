SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The compile step reads the emitted C as typec's reader did, which reads
no trigraph (design 13.2). The -E step translates the trigraphs of the
source under -std=c11 or -trigraphs, but one that a macro builds reaches
its output: here `??=pragma pack(1)`, in a function body of a system
header, which typec passes through unread as `? ? = pragma pack(1)`,
its conditionals closed by the colons of a pragma that the backend
ignores. Clang under -std=c11 or -trigraphs would read a trigraph there
and pack the structure that follows; read as typec reads it, the body
is no C, and each backend refuses it.

  $ . ./backends.sh

  $ mkdir system
  $ cat > system/packs.h <<'EOF'
  > #define Q ?
  > static inline void packs(void) {
  > Q?=pragma pack(1)
  > Q?=pragma unknown : : : :
  > }
  > EOF
  $ cat > main.tc <<'EOF'
  > #include <stdio.h>
  > #include <packs.h>
  > struct pair { char c; int i; };
  > int main(void) {
  >   if (sizeof(struct pair) < 2 * sizeof(int))
  >     printf("packed\n");
  >   return 0;
  > }
  > EOF
Compiled by hand without the option, the emitted C packs on Clang.

  $ typec --cc="$clang" -std=c11 -isystem system --emit-c main.tc -o main.i
  $ $clang -std=c11 -x cpp-output main.i -o packs 2> /dev/null && ./packs
  packed

  $ build() {
  >   typec --cc="$1" $2 -isystem system main.tc -o main 2> /dev/null &&
  >     ./main || echo "refused with status $?"
  > }
  $ build "$clang" -std=c11
  refused with status 1
  $ build "$gcc" -std=c11
  refused with status 1
  $ build "$clang" "-std=gnu11 -trigraphs"
  refused with status 1
  $ build "$gcc" "-std=gnu11 -trigraphs"
  refused with status 1
