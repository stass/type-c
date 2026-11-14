SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec compiles a .tc input in three steps: the backend preprocesses it,
typec reads and emits the result, and the backend compiles the emitted C
with -x cpp-output. The backends are those that backends.sh names.
TMPDIR is a fresh directory, so that every run can check that typec
leaves nothing in it.

  $ unset TYPEC_CC
  $ . ./backends.sh
  $ mkdir tmp out
  $ export TMPDIR=$PWD/tmp

x.tc includes system headers and declares atoi in a header of its own;
<stdlib.h> is compiled on its own below.

  $ cat > x.h <<'EOF'
  > int atoi(const char *);
  > EOF
  $ cat > x.tc <<'EOF'
  > #include <stdarg.h>
  > #include <stdio.h>
  > #include <string.h>
  > #include "x.h"
  > int twice(int);
  > static void say(const char *format, ...) {
  >   va_list ap;
  >   va_start(ap, format);
  >   vprintf(format, ap);
  >   va_end(ap);
  > }
  > int main(int argc, char **argv) {
  >   int n = argc > 1 ? atoi(argv[1]) : 0;
  >   say("__TYPEC__ %d, twice(%d) = %d\n", __TYPEC__, n, twice(n));
  >   return strcmp(argv[0], "") == 0;
  > }
  > EOF
  $ cat > twice.c <<'EOF'
  > int twice(int n) { return 2 * n; }
  > EOF

Without Type-C constructs the emitted text is the preprocessed text, so
the object equals, byte for byte, the one that the backend builds from
the same preprocessed text without typec (exit gate 2 of Stage 0). Both
references preprocess and compile with -std=gnu11, the dialect that
typec selects (design 2.4).

  $ $clang -E -x c -D__TYPEC__=1 -std=gnu11 -O2 x.tc > clang.i
  $ $clang -x cpp-output -std=gnu11 -O2 -c clang.i -o clang-ref.o
  $ typec --cc=$clang -O2 -c x.tc -o clang.o
  $ cmp clang-ref.o clang.o

  $ $gcc -E -x c -D__TYPEC__=1 -std=gnu11 -O2 x.tc > gcc.i
  $ $gcc -x cpp-output -std=gnu11 -O2 -c gcc.i -o gcc-ref.o
  $ typec --cc=$gcc -O2 -c x.tc -o gcc.o
  $ cmp gcc-ref.o gcc.o
  $ ls -A tmp

<stdlib.h> compiles to the same object too, with the block pointers that
the SDK declares for Clang.

  $ printf '#include <stdlib.h>\nint main(void) { return abs(0); }\n' > lib.tc
  $ $gcc -E -x c -D__TYPEC__=1 -std=gnu11 lib.tc > lib-gcc.i
  $ $gcc -x cpp-output -std=gnu11 -c lib-gcc.i -o lib-gcc-ref.o
  $ typec --cc=$gcc -c lib.tc -o lib-gcc.o
  $ cmp lib-gcc-ref.o lib-gcc.o
  $ $clang -E -x c -D__TYPEC__=1 -std=gnu11 lib.tc > lib-clang.i
  $ $clang -x cpp-output -std=gnu11 -c lib-clang.i -o lib-clang-ref.o
  $ typec --cc=$clang -c lib.tc -o lib-clang.o
  $ cmp lib-clang-ref.o lib-clang.o
  $ ls -A tmp

Without -o, the object is named after the input in the current
directory, as cc names it.

  $ typec --cc=$clang -c x.tc twice.c
  $ ls x.o twice.o
  twice.o
  x.o

A .tc input and a .c input link together; the .c input reaches the
backend unchanged.

  $ typec --cc=$clang x.tc twice.c -o prog && ./prog 21
  __TYPEC__ 1, twice(21) = 42
  $ typec --cc=$gcc twice.c x.tc -o prog && ./prog 4
  __TYPEC__ 1, twice(4) = 8

Each step gets options that it does not use, such as -F, which only
preprocessing and linking use, or a linker flag that typec does not
know: -dead_strip on macOS, where the linker calls -s obsolete, and -s
elsewhere. Clang must not warn about them, or -Werror would fail the
build.

  $ link_flag=-s
  $ if [ "$(uname -s)" = Darwin ]; then link_flag=-dead_strip; fi
  $ typec --cc=$clang -Werror -Fout $link_flag x.tc twice.c -o prog
  $ typec --cc=$clang -Werror -Fout -c x.tc -o out/x.o
  $ ls -A tmp

--emit-c writes the emitted C, on stdout or to the -o file, and compiles
nothing. It is the preprocessed text.

  $ $clang -E -x c -D__TYPEC__=1 -std=gnu11 x.tc > plain.i
  $ typec --cc=$clang --emit-c x.tc | cmp - plain.i
  $ typec --cc=$clang --emit-c x.tc -o out/x.i && cmp out/x.i plain.i
  $ typec --cc=$clang --emit-c x.tc twice.c
  typec: --emit-c needs exactly one input, a .tc file
  [2]

A dependency file comes from the preprocessing step. It is named as cc
names it, and its target is the real output.

  $ typec --cc=$clang -MD -c x.tc -o out/x.o
  $ head -1 out/x.d | cut -d ' ' -f 1-2
  out/x.o: x.tc
  $ grep -c ' x.h' out/x.d
  1
  $ typec --cc=$gcc -MMD -MF out/deps -MT target -c x.tc
  $ head -1 out/deps
  target: x.tc x.h
  $ typec --cc=$clang -MD -c x.tc && grep -c ' x.h' x.d
  1

The dialect is C11 or C17 (design 2.4), and options that would stop the
backend at preprocessing or change the preprocessed text are refused
with a .tc input. Without one they reach the backend as they are.

  $ typec --cc=$clang -std=c17 -c x.tc
  $ typec --cc=$clang -std=c99 -c x.tc
  typec: -std=c99 cannot be used with a .tc input: Type-C accepts C11 and C17, in ISO or GNU form
  [2]
  $ typec --cc=$clang -P -c x.tc
  typec: -P cannot be used with a .tc input: the preprocessed text must keep its line markers and nothing else
  [2]
  $ typec --cc=$clang -std=c99 -c twice.c

The keywords follow the dialect as in GCC and Clang: asm and typeof are
identifiers in ISO C and under -fno-asm, so a C11 program that declares
them compiles to the backend's object, and in GNU C they are keywords, to
typec and to the backends alike.

  $ cat > iso.tc <<'EOF'
  > int typeof; int asm;
  > int sum(void) { return typeof + asm; }
  > EOF
  $ $clang -E -x c -D__TYPEC__=1 -std=c11 iso.tc > iso-clang.i
  $ $clang -x cpp-output -std=c11 -c iso-clang.i -o iso-clang-ref.o
  $ typec --cc=$clang -std=c11 -c iso.tc -o iso-clang.o
  $ cmp iso-clang-ref.o iso-clang.o
  $ $gcc -E -x c -D__TYPEC__=1 -std=c11 iso.tc > iso-gcc.i
  $ $gcc -x cpp-output -std=c11 -c iso-gcc.i -o iso-gcc-ref.o
  $ typec --cc=$gcc -std=c11 -c iso.tc -o iso-gcc.o
  $ cmp iso-gcc-ref.o iso-gcc.o
  $ typec --cc=$clang -fno-asm -fsyntax-only iso.tc
  $ typec --cc=$clang -c iso.tc
  typec: iso.tc:1: expected `(` after `typeof`, found `;`
  [1]
  $ typec --cc=$gcc -std=c11 -fasm -c iso.tc
  typec: iso.tc:1: expected `(` after `typeof`, found `;`
  [1]
  $ $clang -x c -std=gnu11 -fsyntax-only iso.tc 2>/dev/null
  [1]
  $ $gcc -x c -std=gnu11 -fsyntax-only iso.tc 2>/dev/null
  [1]

-x before an input changes how cc reads it: after -x c, x.tc is C and is
forwarded, so -E is the backend's and __TYPEC__ is not defined.

  $ typec --cc=$clang -x c -E x.tc | grep -c ', __TYPEC__, n'
  1

A failure ends typec with the status of the step that failed, and the
temporary directory is removed on every path: a backend that fails to
preprocess or to compile, text that the reader refuses, and a backend
ended by a signal.

  $ printf '#error stop\n' > bad-cpp.tc
  $ typec --cc=$clang -c bad-cpp.tc 2>/dev/null
  [1]
  $ printf 'int x = "a" * 2;\n' > bad-c.tc
  $ typec --cc=$clang -c bad-c.tc 2>/dev/null
  [1]
  $ printf 'int @;\n' > bad-read.tc
  $ typec --cc=$clang -c bad-read.tc
  typec: bad-read.tc:1: unexpected character '@'
  [1]
  $ printf '#!/bin/sh\nkill -s KILL $$\n' > killed-cc && chmod +x killed-cc
  $ { typec --cc=./killed-cc -c x.tc; } 2>/dev/null
  [137]
  $ ls -A tmp

The front end parses the text it reads and reads its declarations for
the target model of the compile step; a text it refuses ends typec with
status 1 and one message, before anything is emitted or compiled.

  $ printf 'int x = ;\n' > bad-parse.tc
  $ typec --cc=$clang -c bad-parse.tc
  typec: bad-parse.tc:1: expected an expression, found `;`
  [1]
  $ printf 'int n;\nlong n;\n' > bad-type.tc
  $ typec --cc=$gcc -c bad-type.tc
  typec: bad-type.tc:2: 'n' is redeclared with an incompatible type (C11 6.7p4)
  [1]
  $ typec --cc=$clang --emit-c bad-type.tc
  typec: bad-type.tc:2: 'n' is redeclared with an incompatible type (C11 6.7p4)
  [1]
  $ test ! -e bad-parse.o && test ! -e bad-type.o && ls -A tmp

The target model comes from the backend with the options of the compile
step, so -funsigned-char reaches the declarations.

  $ printf 'int a[(char)-1 < 0 ? 1 : -1];\n' > signed-char.tc
  $ typec --cc=$clang --emit-c signed-char.tc -o out/signed-char.i
  $ typec --cc=$clang -funsigned-char --emit-c signed-char.tc
  typec: signed-char.tc:1: array has a negative length
  [1]
