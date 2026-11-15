SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec gives an identifier one name, in UTF-8, however the source spells
its characters: Clang writes extended characters in UTF-8 for -E and GCC
as universal character names. A universal character name and the
character it names are one identifier, and the name of a function is
its UTF-8 bytes, as each backend counts them.

  $ . ./backends.sh

names.tc spells e with acute accent (U+00E9) and U+1F600 both ways; the
printf escapes keep this file ASCII.

  $ e_acute=$(printf '\303\251')
  $ face=$(printf '\360\237\230\200')
  $ cat > names.tc <<EOF
  > int caf\\u00e9 = 1;
  > extern int caf$e_acute;
  > static int x\\U0001F600(void) {
  >   _Static_assert(sizeof __func__ == 6, "x and four bytes of UTF-8");
  >   return caf$e_acute;
  > }
  > int main(void) { return x$face() != 1; }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-names names.tc && ./clang-names
  $ typec --cc=$gcc -Wall -Werror -o gcc-names names.tc && ./gcc-names

The emitted C keeps each identifier as the backend wrote it for -E (design
13.4): GCC's universal character names stay, and none becomes UTF-8.

  $ typec --cc=$gcc --emit-c names.tc > gcc-names.c
  $ grep -c 'caf\\U000000e9' gcc-names.c
  3
  $ grep -c "caf$e_acute\\|x$face" gcc-names.c
  0
  [1]

-finput-charset names the encoding of the source, which only the step
that preprocesses it reads: GCC writes UTF-8 for -E, and the compile step
reads typec's output as UTF-8. latin1.tc holds e with circumflex as the
one byte 0xEA, in an identifier and in a string, which must equal the
UTF-8 string that the universal character name gives.

  $ printf '#include <string.h>\nconst char *\352 = "\352";\n' > latin1.tc
  $ printf 'int main(void) { return strcmp(\352, "\\u00ea") != 0; }\n' \
  >   >> latin1.tc
  $ typec --cc=$gcc -finput-charset=ISO-8859-1 -o latin1 latin1.tc
  $ ./latin1
