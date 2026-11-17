SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The tag of a variant has the size of int under both enumeration
representations, since its enumeration ends with a hidden enumerator of
the value INT_MAX (design 10.1 rule 2), so a variant has one layout under
both. Every switch on a tag that lowering writes names that enumerator
beside its default, so -Wswitch-enum stays quiet on lowered code (13.5).

The tests run on a Cortex-M3: Clang for thumbv7m-none-eabi, whose
default is int-sized enumerations, and arm-none-eabi-gcc, whose default
is short ones, named by TYPEC_TEST_ARM_GCC; each runs where present,
under each representation. A configuration is a backend, its target
option, the option of a representation and that of the other.

  $ . ./backends.sh
  $ arm_gcc=${TYPEC_TEST_ARM_GCC:-arm-none-eabi-gcc}
  $ configurations() {
  >   if "$clang" --target=thumbv7m-none-eabi -E -x c /dev/null \
  >       > /dev/null 2>&1; then
  >     echo "$clang --target=thumbv7m-none-eabi -fno-short-enums -fshort-enums"
  >     echo "$clang --target=thumbv7m-none-eabi -fshort-enums -fno-short-enums"
  >   fi
  >   if command -v "$arm_gcc" > /dev/null 2>&1; then
  >     echo "$arm_gcc -mcpu=cortex-m3 -fshort-enums -fno-short-enums"
  >     echo "$arm_gcc -mcpu=cortex-m3 -fno-short-enums -fshort-enums"
  >   fi
  > }

A flat match, a match with a nested pattern and a single-pattern test,
each over a variant of two constructors.

  $ cat > list.tc <<'EOF'
  > type list = | Nil | Cons(char head, list *tail);
  > type two = | A | B(char c);
  > int first(list l) {
  >   int head = 0;
  >   match (l) {
  >   case Nil: break;
  >   case Cons(h, _): head = h; break;
  >   }
  >   return head;
  > }
  > int second(const list *l) {
  >   int next = 0;
  >   match (*l) {
  >   case Cons(_, *Cons(n, _)): next = n; break;
  >   default: break;
  >   }
  >   return next;
  > }
  > int is_b(two t) {
  >   if (case B(c) = t) return c;
  >   return 0;
  > }
  > EOF

Under each configuration the unit compiles under -Wswitch-enum -Werror,
and its C has the layout of an int-sized tag on AAPCS: the union after 4
bytes of tag.

  $ cat > layout.c <<'EOF'
  > _Static_assert(sizeof(struct two) == 8, "two");
  > _Static_assert(__builtin_offsetof(struct two, u) == 4, "two.u");
  > _Static_assert(sizeof(struct list) == 12, "list");
  > _Static_assert(__builtin_offsetof(struct list, u) == 4, "list.u");
  > EOF
  $ configurations | while read -r cc target this other; do
  >   typec --cc="$cc" $target $this -Wall -Wswitch-enum -Werror -c list.tc ||
  >     echo "refused: $cc $this"
  >   typec --cc="$cc" $target $this --emit-c -o list.i list.tc &&
  >     cat list.i layout.c > layout_check.c &&
  >     "$cc" $target $this -fsyntax-only layout_check.c ||
  >     echo "layout: $cc $this"
  > done

The C that --emit-c writes under one representation fails under the
other with the enumeration assertion.

  $ configurations | while read -r cc target this other; do
  >   typec --cc="$cc" $target $this --emit-c -o other.i list.tc
  >   "$cc" $target $other -fsyntax-only other.i 2>&1 |
  >     grep -q 'typec assumes' || echo "no assertion: $cc $this"
  > done
