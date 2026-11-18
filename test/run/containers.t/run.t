SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The container library of package 3.5, written as a test: a vector, a
hash map that takes its hash and equality as function pointers, and a
region allocator, in containers.tci, used from four translation units
with int, double, struct point, struct point * and str as elements and
keys. region.tc implements the region and the hashes, words.tc counts
words in a map(str, int), keeps their order in a vector(str) and sums
the counts through map_each, points.tc walks a vector(struct point)
and indexes region-allocated points in a map(int, struct point *), and
main.tc drives them with a vector(int) of its own, which vector_append
extends from slices of int that convert to slice(const int), one of
them the vector's own elements.

Each backend builds the library at -O0 and -O2 under the strictest
warnings, with and without AddressSanitizer and
UndefinedBehaviorSanitizer, and each build prints the same output.

  $ . ../backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ units="region words points main"
  $ build() {
  >   build_cc=$1
  >   shift
  >   for unit in $units; do
  >     typec --cc=$build_cc $flags "$@" -c $unit.tc || return 1
  >   done
  >   typec --cc=$build_cc $flags "$@" -o containers \
  >     region.o words.o points.o main.o -lm
  > }
  $ build $clang -O0 && ./containers > expected && cat expected
  squares 100, sum 328350, capacity 128: 9 none 9801 9604
  appended 103: 11, doubled 206: 0 11
  freed: none
  the 4
  quick 1
  brown 1
  fox 2
  jumps 1
  over 1
  lazy 1
  dog 2
  sleeps 1
  and 1
  runs 1
  16 words, 11 distinct
  points 1000, total distance 994026.582
  index 0: (-3, -5)
  index 1: none
  index 3: (0, 1)
  index 500: none
  index 501: (1, 997)
  index 999: (2, 1993)
  index 1000: none
  indexed 334
  $ for cc in $clang $gcc; do
  >   for options in "-O0" "-O2" "-O0 $sanitize" "-O2 $sanitize"; do
  >     build $cc $options && ./containers > output &&
  >       cmp output expected || echo "differs: $cc $options"
  >   done
  > done

The instances are local to each unit, so the units link without
duplicate symbols: each defines only its own external functions. The
host's nm lists them; awk drops the line that names the object.

  $ for cc in $clang $gcc; do
  >   build $cc -O0 &&
  >     for unit in $units; do
  >       echo $(nm -gP --defined-only $unit.o | awk 'NF > 1 { print $1 }' |
  >         sed 's/^_//' | sort)
  >     done
  > done
  equal_int equal_str hash_int hash_str region_alloc region_copy_str region_init region_release
  count_words
  walk_points
  main
  equal_int equal_str hash_int hash_str region_alloc region_copy_str region_init region_release
  count_words
  walk_points
  main

A clean build and an incremental one give identical objects and
programs: after an edit of words.tc, the incremental build compiles
words.tc alone and links again, and the clean one builds the edited
sources afresh in another directory. The edit gives the region of
words.tc smaller chunks, and the object it compiles to changes.

  $ cp words.tc words.orig
  $ edit='s/region_init(&names, 64)/region_init(\&names, 8)/'
  $ for cc in $clang $gcc; do
  >   rm -f words.tc && cp words.orig words.tc && build $cc -O2 &&
  >     cp words.o words.before &&
  >     rm -f words.tc && sed "$edit" words.orig > words.tc &&
  >     typec --cc=$cc $flags -O2 -c words.tc &&
  >     { ! cmp -s words.o words.before || echo "unchanged: $cc"; } &&
  >     typec --cc=$cc $flags -O2 -o containers \
  >       region.o words.o points.o main.o -lm &&
  >     rm -rf clean && mkdir clean &&
  >     cp containers.tci demo.tci *.tc clean &&
  >     (cd clean && build $cc -O2) &&
  >     for file in region.o words.o points.o main.o containers; do
  >       cmp $file clean/$file || echo "differs: $cc $file"
  >     done &&
  >     ./containers | cmp - expected
  > done

An operation that C refuses of a structure is refused at the
definition of a generic, with no use of it: a vector_contains that
compares elements with == takes an equality function instead, as the
map does.

  $ cat > contains.tc <<'EOF'
  > #include "containers.tci"
  > generic(T) int
  > vector_contains(const vector(T) *v, T x)
  > {
  >         size_t i;
  >         for (i = 0; i < v->length; i++)
  >                 if (v->data[i] == x)
  >                         return (1);
  >         return (0);
  > }
  > EOF
  $ typec --cc=$clang $flags -c contains.tc
  contains.tc:7: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
      7 |                 if (v->data[i] == x)
  [80]
