SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Clang's block literals are C text only (design 13.3): typec refuses one
in Type-C text before the backend sees it, and keeps one in a C header
that Type-C text includes. GCC has no blocks, so only Clang runs; the
units are compiled, not linked, as a host other than macOS needs a
blocks runtime to link them.

  $ . ./backends.sh

  $ cat > typed.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(e v) {
  >   int (^b)(void) = ^{
  >     match (v) { case B(i): return i; default: return 0; }
  >   };
  >   return b();
  > }
  > EOF
  $ typec --cc=$clang -fblocks -c typed.tc
  typed.tc:3: error: a block literal is C text only, so Type-C text cannot write one or be included in one [block-literal]
  [80]

  $ cat > twice.h <<'EOF'
  > static int twice(int x) {
  >   int (^b)(int) = ^(int y) { return 2 * y; };
  >   return b(x);
  > }
  > EOF
  $ cat > header.tc <<'EOF'
  > #include "twice.h"
  > type e = | A | B(int i);
  > e f(void) { return B(twice(1)); }
  > EOF
  $ typec --cc=$clang -fblocks -Wall -Werror -c header.tc
