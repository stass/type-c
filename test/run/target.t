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

Some options change a type of C but no macro that the model reads:
-fshort-enums gives an enumeration the narrowest integer type that
holds its values, and GCC's -funsigned-bitfields, also spelled
-fno-signed-bitfields, makes a bit-field declared without signed or
unsigned unsigned, and its -fsingle-precision-constant makes an
unsuffixed floating constant float. typec refuses them with a .tc
input, even when a later option undoes them. Their negations, which
keep the model's types, pass, and so do the refused options on a
command line without a .tc input.

  $ cat > enum.tc <<'EOF'
  > enum colour { red, green };
  > struct flags { int field : 3; };
  > EOF
  $ typec --cc=$clang -fshort-enums -c enum.tc
  typec: -fshort-enums cannot be used with a .tc input: it gives an enumeration the narrowest integer type that holds its values, which typec's target model does not read
  [81]
  $ typec --cc=$gcc -fshort-enums -fno-short-enums -c enum.tc
  typec: -fshort-enums cannot be used with a .tc input: it gives an enumeration the narrowest integer type that holds its values, which typec's target model does not read
  [81]
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
  $ typec --cc=$gcc -fshort-enums --print-target > /dev/null

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

A backend older than typec supports gives no model either. clang19 is
the Clang of the host that claims to be Clang 19.

  $ cat > clang19 <<EOF
  > #!/bin/sh
  > "$clang" "\$@" | sed 's/__clang_major__ .*/__clang_major__ 19/'
  > EOF
  $ chmod +x clang19
  $ typec --cc=./clang19 --print-target
  typec: the C compiler is Clang 19; typec supports Clang 20 or later and GCC 14 or later
  [81]
