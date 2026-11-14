SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec --print-target prints the target model that the backend reports in
its predefined macros when it is run with the other arguments as options.
The backends are those that backends.sh names, on an x86-64 host, whose
release varies with the host, and so do the optional floating types of
Clang and uint64_t, which are left out here: __float128 is one on Linux
alone, and uint64_t is unsigned long long on macOS.

  $ unset TYPEC_CC
  $ . ./backends.sh

  $ typec --cc=$clang --print-target |
  >   sed -e '1s/ [0-9]*$//' -e '/^optional_floats:/d' -e '/^uint64_type:/d'
  backend: Clang
  char_bit: 8
  char_signed: true
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
  wchar_type: int
  intmax_type: long
  uintmax_type: unsigned long
  intptr_type: long
  char16_type: unsigned short
  char32_type: unsigned int
  byte_order: little-endian
  stdc_version: 201710

GCC spells the types in another order and reads the same target.

  $ facts() {
  >   grep -E -e '^(backend|char_signed|char16_type):' \
  >     -e '^sizeof_(int|long|pointer):' |
  >   sed '1s/ [0-9]*$//'
  > }
  $ typec --cc=$gcc --print-target | facts
  backend: GCC
  char_signed: true
  sizeof_int: 4
  sizeof_long: 8
  sizeof_pointer: 8
  char16_type: unsigned short

GCC has every optional floating type on each host.

  $ typec --cc=$gcc --print-target | grep '^optional_floats:' | tr ' ' '\n'
  optional_floats:
  _Float16
  _Float32
  _Float64
  _Float128
  _Float32x
  _Float64x
  __float128

The options reach the backend, so they change the model.

  $ typec --cc=$clang -m32 --print-target -funsigned-char | facts
  backend: Clang
  char_signed: false
  sizeof_int: 4
  sizeof_long: 4
  sizeof_pointer: 4
  char16_type: unsigned short
  $ typec --cc=$gcc -m32 --print-target -funsigned-char | facts
  backend: GCC
  char_signed: false
  sizeof_int: 4
  sizeof_long: 4
  sizeof_pointer: 4
  char16_type: unsigned short
  $ typec --cc=$gcc --print-target -std=gnu11 | grep stdc_version
  stdc_version: 201112

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
