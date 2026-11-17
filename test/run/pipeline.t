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
references preprocess and compile with -std=gnu17, the dialect that
typec selects (design 2.4).

  $ $clang -E -x c -D__TYPEC__=1 -std=gnu17 -O2 x.tc > clang.i
  $ $clang -x cpp-output -std=gnu17 -O2 -c clang.i -o clang-ref.o
  $ typec --cc=$clang -O2 -c x.tc -o clang.o
  $ cmp clang-ref.o clang.o

  $ $gcc -E -x c -D__TYPEC__=1 -std=gnu17 -O2 x.tc > gcc.i
  $ $gcc -x cpp-output -std=gnu17 -O2 -c gcc.i -o gcc-ref.o
  $ typec --cc=$gcc -O2 -c x.tc -o gcc.o
  $ cmp gcc-ref.o gcc.o
  $ ls -A tmp

<stdlib.h> compiles to the same object too, with the block pointers that
the SDK declares for Clang.

  $ printf '#include <stdlib.h>\nint main(void) { return abs(0); }\n' > lib.tc
  $ $gcc -E -x c -D__TYPEC__=1 -std=gnu17 lib.tc > lib-gcc.i
  $ $gcc -x cpp-output -std=gnu17 -c lib-gcc.i -o lib-gcc-ref.o
  $ typec --cc=$gcc -c lib.tc -o lib-gcc.o
  $ cmp lib-gcc-ref.o lib-gcc.o
  $ $clang -E -x c -D__TYPEC__=1 -std=gnu17 lib.tc > lib-clang.i
  $ $clang -x cpp-output -std=gnu17 -c lib-clang.i -o lib-clang-ref.o
  $ typec --cc=$clang -c lib.tc -o lib-clang.o
  $ cmp lib-clang-ref.o lib-clang.o
  $ ls -A tmp

The default dialect gives a .tc file the __STDC_VERSION__ of C17 on
either backend, and a -std= of the command line replaces it.

  $ printf 'long version(void) { return __STDC_VERSION__; }\n' > version.tc
  $ typec --cc=$clang --emit-c version.tc | grep -o '[0-9][0-9]*L'
  201710L
  $ typec --cc=$gcc --emit-c version.tc | grep -o '[0-9][0-9]*L'
  201710L
  $ typec --cc=$clang -std=gnu11 --emit-c version.tc | grep -o '[0-9][0-9]*L'
  201112L
  $ typec --cc=$gcc -std=gnu11 --emit-c version.tc | grep -o '[0-9][0-9]*L'
  201112L

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
build. A command that links .tc inputs alone compiles and links them in
its final command, without the options that only preprocessing uses.

  $ link_flag=-s
  $ if [ "$(uname -s)" = Darwin ]; then link_flag=-dead_strip; fi
  $ typec --cc=$clang -Werror -Fout $link_flag x.tc twice.c -o prog
  $ typec --cc=$clang -Werror -Fout $link_flag -Iinc -DX lib.tc -o prog
  $ typec --cc=$clang -Werror -fmacro-prefix-map=/a=/b lib.tc -o prog
  $ typec --cc=$clang -Werror -Fout -c x.tc -o out/x.o
  $ typec --cc=$clang -Werror -lm -c x.tc -o out/x.o
  $ ls -A tmp

Only Clang's steps get the option that quiets those warnings: GCC does
not know it, and names it in a note after any diagnostic of a step that
gets it.

  $ cat > gcc-warns.tc <<'EOF'
  > #warning in the preprocessing step
  > int f(void) { int unused; return 0; }
  > EOF
  $ typec --cc=$gcc -Wall -c gcc-warns.tc -o out/gcc-warns.o 2> gcc-warns.err
  $ grep -c 'warning:' gcc-warns.err
  2
  $ grep 'unrecognized command-line option' gcc-warns.err
  [1]

--emit-c writes the emitted C, on stdout or to the -o file, and compiles
nothing. It is the preprocessed text.

  $ $clang -E -x c -D__TYPEC__=1 -std=gnu17 x.tc > plain.i
  $ typec --cc=$clang --emit-c x.tc | cmp - plain.i
  $ typec --cc=$clang --emit-c x.tc -o out/x.i && cmp out/x.i plain.i
  $ typec --cc=$clang --emit-c x.tc twice.c
  typec: --emit-c needs exactly one input, a .tc file
  [81]

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

The long forms of the options are the same options, and only the
preprocessing step gets them: the target query and the compile step of
Clang would each write a dependency file of their own.

  $ typec --cc=$clang --write-user-dependencies -c x.tc -o out/long.o
  $ cat out/long.d
  out/long.o: x.tc x.h
  $ ls *.d
  x.d

-M and -MM print the rule of the preprocessing step and compile
nothing, as cc does for a .c input: to stdout, or to the file of -o or
-MF. The other inputs get the command line without the .tc ones.

  $ typec --cc=$clang -MM -c x.tc
  x.o: x.tc x.h
  $ typec --cc=$gcc -MM -MT t -o out/rule x.tc && cat out/rule
  t: x.tc x.h
  $ typec --cc=$clang --user-dependencies -MP -MF out/rules x.tc twice.c
  $ cat out/rules
  twice.o: twice.c
  $ typec --cc=$gcc -MM x.tc twice.c
  x.o: x.tc x.h
  twice.o: twice.c
  $ typec --cc=$clang -M -o out/rule x.tc twice.c
  typec: cannot specify -o with -c, -S or -M and more than one input
  [81]

The dialect is C11 or C17 (design 2.4), and options that would stop the
backend at preprocessing or change the preprocessed text are refused
with a .tc input. Without one they reach the backend as they are.

  $ typec --cc=$clang -std=c17 -c x.tc
  $ typec --cc=$clang -std=c99 -c x.tc
  typec: -std=c99 cannot be used with a .tc input: Type-C accepts C11 and C17, in ISO or GNU form
  [81]
  $ typec --cc=$clang -P -c x.tc
  typec: -P cannot be used with a .tc input: the preprocessed text must keep its line markers and nothing else
  [81]
  $ typec --cc=$clang -std=c99 -c twice.c

GCC reads an abbreviation of a long option as that option and any other
--NAME as -fNAME, so with a .tc input typec refuses each long option
that it does not know: --preprocess is -E, --write-user-dep is -MMD and
--short-enums is -fshort-enums. A long option that typec knows, such as
--coverage, passes, and without a .tc input every one reaches the
backend.

  $ typec --cc=$gcc --preprocess -c x.tc
  typec: --preprocess cannot be used with a .tc input: typec does not know this long option, which GCC may read as an abbreviation of another or as -f and its name
  [81]
  $ typec --cc=$clang --preprocess -c x.tc
  typec: --preprocess cannot be used with a .tc input: typec does not know this long option, which GCC may read as an abbreviation of another or as -f and its name
  [81]
  $ typec --cc=$clang --ansi -c x.tc
  typec: --ansi cannot be used with a .tc input: typec does not know this long option, which GCC may read as an abbreviation of another or as -f and its name
  [81]
  $ mkdir long && cd long
  $ typec --cc=$gcc --write-user-dep -c ../x.tc
  typec: --write-user-dep cannot be used with a .tc input: typec does not know this long option, which GCC may read as an abbreviation of another or as -f and its name
  [81]
  $ cd .. && ls -A long
  $ typec --cc=$gcc --short-enums -c x.tc
  typec: --short-enums cannot be used with a .tc input: typec does not know this long option, which GCC may read as an abbreviation of another or as -f and its name
  [81]
  $ typec --cc=$clang --coverage -c x.tc -o out/coverage.o && ls out/*.gcno
  out/coverage.gcno
  $ typec --cc=$gcc --std=c17 -c x.tc
  $ typec --cc=$clang --std c17 -c x.tc
  $ typec --cc=$gcc --short-enums -c twice.c

The options inside -Wp, and after -Xpreprocessor reach the -E step
unseen, so the reader refuses the text they change: text without line
markers, in which no token can be placed in its file, and text that
keeps comments or directives. Where the refused text stands depends on
the backend and its headers, so its location is cut.

  $ without_location() { sed 's/^.*:[0-9]*: error: //'; }
  $ typec --cc=$clang -Wp,-P -c x.tc 2>&1 | without_location
  token before the first line marker, as when an option such as -P removes the line markers
  $ typec --cc=$gcc -Wp,-P -c x.tc 2>&1 | without_location
  token before the first line marker, as when an option such as -P removes the line markers
  $ typec --cc=$clang -Xpreprocessor -P -c x.tc 2>&1 | without_location
  token before the first line marker, as when an option such as -P removes the line markers
  $ typec --cc=$gcc -Xpreprocessor -P -c x.tc 2>&1 | without_location
  token before the first line marker, as when an option such as -P removes the line markers
  $ typec --cc=$clang -Wp,-C -c x.tc 2>&1 | without_location
  comment in preprocessed text, as when an option such as -C keeps the comments
  $ typec --cc=$gcc -Xpreprocessor -dD -c x.tc 2>&1 | without_location
  unsupported directive #define

Several -arch options make Apple's cc build a universal binary, but its
-E step preprocesses for one architecture only, so typec refuses two
architectures with a .tc input. One architecture, given once or more,
is a plain compile, and a command line without a .tc input still
reaches the backend, which builds the universal object. Apple's cc
leaves the objects of each architecture of a universal build in TMPDIR,
so that build gets a directory of its own.

  $ typec --cc=$clang -arch x86_64 -arch arm64 -c x.tc
  typec: -arch cannot name several architectures (x86_64, arm64) with a .tc input: build each with one -arch and join the results with lipo
  [81]
  $ if [ "$(uname -s)" = Darwin ]; then
  >   typec --cc=$clang -arch $(uname -m) -c x.tc -o out/one.o &&
  >   typec --cc=$clang -arch $(uname -m) -arch $(uname -m) x.tc twice.c \
  >     -o out/one
  > fi
  $ if [ "$(uname -s)" = Darwin ] &&
  >   mkdir universal-tmp && universal_tmp=$PWD/universal-tmp &&
  >   TMPDIR=$universal_tmp $clang -arch x86_64 -arch arm64 -c twice.c \
  >     -o out/probe.o 2>/dev/null
  > then
  >   TMPDIR=$universal_tmp typec --cc=$clang -arch x86_64 -arch arm64 \
  >     -c twice.c -o out/fat.o &&
  >   lipo out/fat.o -verify_arch x86_64 arm64
  > fi

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
  iso.tc:1: error: expected `(` after `typeof`, found `;`
  [80]
  $ typec --cc=$gcc -std=c11 -fasm -c iso.tc
  iso.tc:1: error: expected `(` after `typeof`, found `;`
  [80]
  $ $clang -x c -std=gnu11 -fsyntax-only iso.tc 2>/dev/null
  [1]
  $ $gcc -x c -std=gnu11 -fsyntax-only iso.tc 2>/dev/null
  [1]

-x before an input changes how cc reads it: after -x c, x.tc is C and is
forwarded, so -E is the backend's and __TYPEC__ is not defined.

  $ typec --cc=$clang -x c -E x.tc | grep -c ', __TYPEC__, n'
  1

A backend step that fails ends typec with the status of the step, text
that the reader refuses ends it with 80, the status of a refused program
(src/driver/exit_status.ml), and the temporary directory is removed on
every path: a backend that fails to preprocess or to compile, text that
the reader refuses, and a backend ended by a signal. The first step is
the target query, where a backend that rejects an option fails, as a
direct compile would. fails-compile fails the compile step with a
status of its own, which typec passes on. A
backend that cannot be started, because it is missing, not executable or
a directory, ends typec with 81, while one that runs and exits with 127,
the status a shell gives a command it cannot start, ends it with 127.
says-why fails the link step after a message on stderr, which typec was
started without and the backend writes to /dev/null instead. Clang
aborts when it cannot write a warning to its stderr, so warns.c also
shows that the backend can write there.

  $ typec --cc=$clang -fno-such-option -c x.tc 2>/dev/null
  [1]
  $ typec --cc=$gcc -fno-such-option -c x.tc 2>/dev/null
  [1]
  $ printf '#error stop\n' > bad-cpp.tc
  $ typec --cc=$clang -c bad-cpp.tc 2>/dev/null
  [1]
  $ printf 'void f(void) { __asm__("no_such_instruction"); }\n' > bad-c.tc
  $ typec --cc=$clang -c bad-c.tc 2>/dev/null
  [1]
  $ printf 'int @;\n' > bad-read.tc
  $ typec --cc=$clang -c bad-read.tc
  bad-read.tc:1: error: unexpected character '@'
  [80]
  $ printf '#!/bin/sh\nkill -s KILL $$\n' > killed-cc && chmod +x killed-cc
  $ { typec --cc=./killed-cc -c x.tc; } 2>/dev/null
  [137]
  $ printf '#!/bin/sh\ncase " $* " in *" cpp-output "*) exit 42 ;; esac\n' \
  >   > fails-compile
  $ printf 'exec "%s" "$@"\n' "$clang" >> fails-compile
  $ chmod +x fails-compile
  $ typec --cc=./fails-compile -c x.tc
  [42]
  $ typec --cc=./no-such-cc -c x.tc
  typec: cannot run the C compiler "./no-such-cc": No such file or directory
  [81]
  $ printf '#!/bin/sh\n' > not-executable
  $ typec --cc=./not-executable -c x.tc
  typec: cannot run the C compiler "./not-executable": Permission denied
  [81]
  $ mkdir a-directory
  $ typec --cc=./a-directory -c x.tc
  typec: cannot run the C compiler "./a-directory": Permission denied
  [81]
  $ sed 's/exit 42/exit 127/' fails-compile > exits-127 && chmod +x exits-127
  $ typec --cc=./exits-127 -c x.tc
  [127]
  $ printf '#!/bin/sh\ncase " $* " in *" -o linked "*)\n' > says-why
  $ printf '  echo cannot link >&2; exit 42 ;;\nesac\n' >> says-why
  $ printf 'exec "%s" "$@"\n' "$clang" >> says-why
  $ chmod +x says-why
  $ typec --cc=./says-why x.tc -o linked >&- 2>&-
  [42]
  $ printf 'int f(void) { int unused; return 0; }\n' > warns.c
  $ typec --cc=$clang -Wall -c warns.c 2>&-
  $ ls -A tmp

The front end parses the text it reads and reads its declarations for
the target model of the compile step; a text it refuses ends typec with
status 80 and one message, before anything is emitted or compiled.

  $ printf 'int x = ;\n' > bad-parse.tc
  $ typec --cc=$clang -c bad-parse.tc
  bad-parse.tc:1: error: expected an expression, found `;`
  [80]
  $ printf 'int n;\nlong n;\n' > bad-type.tc
  $ typec --cc=$gcc -c bad-type.tc
  bad-type.tc:2: error: 'n' is redeclared with an incompatible type (C11 6.7p4)
  [80]
  $ typec --cc=$clang --emit-c bad-type.tc
  bad-type.tc:2: error: 'n' is redeclared with an incompatible type (C11 6.7p4)
  [80]
  $ test ! -e bad-parse.o && test ! -e bad-type.o && ls -A tmp

The target model comes from the backend with the options of the compile
step, so -funsigned-char reaches the declarations. Plain char is signed
by default on x86-64 and not on arm64, so the first compile asks for it.

  $ printf 'int a[(char)-1 < 0 ? 1 : -1];\n' > signed-char.tc
  $ typec --cc=$clang -fsigned-char --emit-c signed-char.tc -o out/signed-char.i
  $ typec --cc=$clang -funsigned-char --emit-c signed-char.tc
  signed-char.tc:1: error: array has a negative length
  [80]
