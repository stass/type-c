SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec --print-target prints the target model that the backend reports in
its predefined macros when it is run with the other arguments as options.
The backends are those that backends.sh names, on an x86-64 or arm64
Linux host. Their release varies with the host, and so do the optional
floating types of Clang and uint64_t, which are left out here:
uint64_t is unsigned long long on macOS. The architecture, the signedness
of plain char and the type of wchar_t follow the host, and so does
__float128, which is x86-64 alone; they are checked on their own below.

  $ unset TYPEC_CC
  $ . ./backends.sh

  $ typec --cc=$clang --print-target |
  >   sed -e '1s/ [0-9]*$//' -e '/^optional_floats:/d' \
  >     -e '/^uint64_type:/d' -e '/^architecture:/d' -e '/^char_signed:/d' \
  >     -e '/^wchar_type:/d'
  backend: Clang
  char_bit: 8
  sizeof_short: 2
  sizeof_int: 4
  sizeof_long: 8
  sizeof_long_long: 8
  sizeof_pointer: 8
  sizeof_float: 4
  sizeof_double: 8
  sizeof_long_double: 16
  sizeof_int128: 16
  size_type: unsigned long
  ptrdiff_type: long
  intmax_type: long
  uintmax_type: unsigned long
  intptr_type: long
  uint16_type: unsigned short
  uint32_type: unsigned int
  char16_type: unsigned short
  char32_type: unsigned int
  byte_order: little-endian
  stdc_version: 201710
  enum_representation: int-sized

Plain char is signed on x86-64 and unsigned on arm64 Linux, where wchar_t
is unsigned int, not int. GCC spells the types in another order and reads
the same target.

  $ case $(uname -m) in
  >   x86_64|amd64) architecture=x86 char_signed=true wchar_type=int
  >     float128=1 ;;
  >   aarch64) architecture=AArch64 char_signed=false
  >     wchar_type="unsigned int" float128=0 ;;
  >   *) echo "no expected model for $(uname -m)" ;;
  > esac
  $ printf 'architecture: %s\nchar_signed: %s\nwchar_type: %s\n' \
  >   $architecture $char_signed "$wchar_type" > arch_facts
  $ arch_lines() {
  >   grep -E '^(architecture|char_signed|wchar_type):'
  > }
  $ typec --cc=$clang --print-target | arch_lines | diff arch_facts -
  $ typec --cc=$gcc --print-target | arch_lines | diff arch_facts -

  $ facts() {
  >   grep -E -e '^(backend|char16_type):' \
  >     -e '^sizeof_(int|long|pointer):' |
  >   sed '1s/ [0-9]*$//'
  > }
  $ typec --cc=$gcc --print-target | facts
  backend: GCC
  sizeof_int: 4
  sizeof_long: 8
  sizeof_pointer: 8
  char16_type: unsigned short

GCC has every optional floating type on each host, and __float128 on
x86-64.

  $ typec --cc=$gcc --print-target | grep '^optional_floats:' |
  >   tr ' ' '\n' | grep -v '^__float128$'
  optional_floats:
  _Float16
  _Float32
  _Float64
  _Float128
  _Float32x
  _Float64x
  $ test $(typec --cc=$gcc --print-target | grep -c ' __float128') = $float128

The options reach the backend, so they change the model.

  $ typec --cc=$clang -fsigned-char --print-target | grep '^char_signed:'
  char_signed: true
  $ typec --cc=$clang --print-target -funsigned-char | grep '^char_signed:'
  char_signed: false
  $ typec --cc=$gcc -fsigned-char --print-target | grep '^char_signed:'
  char_signed: true
  $ typec --cc=$gcc --print-target -funsigned-char | grep '^char_signed:'
  char_signed: false
  $ typec --cc=$gcc --print-target -std=gnu11 | grep stdc_version
  stdc_version: 201112
  $ typec --cc=$clang -fshort-wchar --print-target | grep '^wchar_type:'
  wchar_type: unsigned short
  $ typec --cc=$gcc -fshort-wchar --print-target | grep '^wchar_type:'
  wchar_type: unsigned short

-fshort-enums gives an enumeration the narrowest integer type that
holds its values, which no macro states on every target. The target
query learns it by two probe compiles, each of which fails under the
other representation; the backend's messages of the failing probe are
not shown.

  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" --print-target 2>&1 | grep -v '^[a-z0-9_]*: '
  >   typec --cc="$cc" -fshort-enums --print-target 2>&1 |
  >     grep -v '^[a-z0-9_]*: '
  >   typec --cc="$cc" --print-target | grep '^enum_representation:'
  >   typec --cc="$cc" -fshort-enums --print-target |
  >     grep '^enum_representation:'
  > done
  enum_representation: int-sized
  enum_representation: short
  enum_representation: int-sized
  enum_representation: short

A backend that compiles neither probe gives no model.

  $ cat > no-probe <<EOF
  > #!/bin/sh
  > case " \$* " in *" -dM "*) exec "$gcc" "\$@" ;; esac
  > exit 1
  > EOF
  $ chmod +x no-probe
  $ typec --cc=./no-probe -fshort-enums --print-target
  typec: the C compiler "./no-probe" compiled neither probe of the enumeration representation, for short and for int-sized enumerations, with the options "-fshort-enums"
  [81]

Some options change a type of C but no macro that the model reads:
GCC's -funsigned-bitfields, also spelled -fno-signed-bitfields, makes a
bit-field declared without signed or unsigned unsigned, and its
-fsingle-precision-constant makes an unsuffixed floating constant
float. typec refuses them with a .tc input, even when a later option
undoes them. Their negations, which keep the model's types, pass, and
so do the refused options on a command line without a .tc input.

  $ cat > enum.tc <<'EOF'
  > enum colour { red, green };
  > struct flags { int field : 3; };
  > EOF
  $ typec --cc=$gcc -funsigned-bitfields -c enum.tc
  typec: -funsigned-bitfields cannot be used with a .tc input: GCC makes every bit-field declared without signed or unsigned unsigned, which typec's target model does not read
  [81]
  $ typec --cc=$gcc -fno-signed-bitfields -c enum.tc
  typec: -fno-signed-bitfields cannot be used with a .tc input: GCC makes every bit-field declared without signed or unsigned unsigned, which typec's target model does not read
  [81]
  $ typec --cc=$gcc -fsingle-precision-constant -c enum.tc
  typec: -fsingle-precision-constant cannot be used with a .tc input: GCC makes an unsuffixed floating constant float, which typec's target model does not read
  [81]
  $ typec --cc=$gcc -fno-short-enums -fsigned-bitfields \
  >   -fno-unsigned-bitfields -fno-single-precision-constant -c enum.tc
  $ typec --cc=$clang -fno-short-enums -fsigned-bitfields -c enum.tc
  $ typec --cc=$gcc -funsigned-bitfields --print-target > /dev/null

GCC's -fpack-struct without a value makes it ignore every '#pragma
pack' that typec writes around an instance of a generic, with a warning
for each, which fails a build under -Werror. typec refuses it with a .tc
input, whatever the backend, as the option table is the same for all. -fpack-struct=n keeps the pragmas and passes, and so does
-fpack-struct on a command line without a .tc input.

  $ typec --cc=$gcc -fpack-struct -c enum.tc
  typec: -fpack-struct cannot be used with a .tc input: under it GCC ignores each '#pragma pack' that typec writes around an instance of a generic, and warns of it; -fpack-struct=n passes
  [81]
  $ typec --cc=$gcc -fpack-struct=2 -c enum.tc
  $ typec --cc=$clang -fpack-struct=1 -c enum.tc
  $ typec --cc=$gcc -fpack-struct --print-target > /dev/null

Other routes to these options reach the backend unseen, such as Clang's
-Xclang or a wrapper around the backend. The C that typec emits for a
unit with a Type-C construct therefore ends with a static assertion of
each type it assumes, which the backend fails. GCC quotes the message,
and Clang shows it again in the line it quotes.

  $ cat > lowered.tc <<'EOF'
  > enum colour { red, green };
  > type hue = enum colour;
  > EOF
  $ assumptions() { grep error: log | grep -o 'typec assumes [^"]*'; }
  $ typec --cc=$clang -Xclang -fshort-enums -c lowered.tc 2> log ||
  >   assumptions
  typec assumes an enumeration of small nonnegative values is compatible with unsigned int (-fshort-enums?)
  $ cat > gcc-wrapped <<EOF
  > #!/bin/sh
  > exec "$gcc" -fshort-enums -funsigned-bitfields \
  >   -fsingle-precision-constant "\$@"
  > EOF
  $ chmod +x gcc-wrapped
  $ typec --cc=./gcc-wrapped -c lowered.tc 2> log || assumptions
  typec assumes plain int bit-fields are signed (-funsigned-bitfields?)
  typec assumes unsuffixed floating constants are double (-fsingle-precision-constant?)
  typec assumes an enumeration of small nonnegative values is compatible with unsigned int (-fshort-enums?)

The assertions stand under a line marker with flag 3, so the warnings
that judge the user's code pass over them, as over a system header;
alone, they are valid C11 and C17 under -pedantic-errors.

  $ typec --cc=$gcc -Wc++-compat -Werror -c lowered.tc
  $ typec --cc=$clang --emit-c -o - lowered.tc |
  >   sed -n '/^# 1 "<typec>" 3$/,$p' | grep -v '^# ' > assertions.c
  $ wc -l < assertions.c | tr -d ' '
  3
  $ for cc in $clang $gcc; do
  >   for std in c11 c17; do
  >     $cc -std=$std -Wall -Wextra -pedantic-errors -fsyntax-only \
  >       assertions.c
  >   done
  > done

A backend that fails, cannot be started, prints something other than
macro definitions, prints without end, or omits a macro the model needs
gives one message and no model. endless prints without end whatever its
arguments, which GNU yes would refuse as options.

  $ typec --cc=false --print-target
  typec: the C compiler "false" exited with status 1 listing its predefined macros
  [81]
  $ typec --cc=./no-such-cc --print-target
  typec: cannot run the C compiler "./no-such-cc": No such file or directory
  [81]
  $ printf '#!/bin/sh\n' > not-executable
  $ typec --cc=./not-executable --print-target
  typec: cannot run the C compiler "./not-executable": Permission denied
  [81]
  $ mkdir a-directory
  $ typec --cc=./a-directory --print-target
  typec: cannot run the C compiler "./a-directory": Permission denied
  [81]
  $ typec --cc=echo --print-target
  typec: unexpected line "-dM -E -x c /dev/null" among the predefined macros
  [81]
  $ printf '#!/bin/sh\nexec yes\n' > endless && chmod +x endless
  $ typec --cc=./endless --print-target
  typec: the C compiler "./endless" printed more than 1048576 bytes listing its predefined macros
  [81]
  $ typec --cc=$clang --print-target -std=c89
  typec: the C compiler does not define __STDC_VERSION__
  [81]

A backend older than typec supports gives no model either. clang20 is
the Clang of the host that claims to be Clang 20, the newest release
that typec refuses.

  $ cat > clang20 <<EOF
  > #!/bin/sh
  > "$clang" "\$@" | sed 's/__clang_major__ .*/__clang_major__ 20/'
  > EOF
  $ chmod +x clang20
  $ typec --cc=./clang20 --print-target
  typec: the C compiler is Clang 20; typec supports Clang 21 or later and GCC 14 or later
  [81]
