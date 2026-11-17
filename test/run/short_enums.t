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
under each representation, and backends_report in backends.sh says
which ran. A configuration is a backend, its target option, the option
of a representation and that of the other.

  $ . ./backends.sh
  $ configurations() {
  >   if arm_clang_present; then
  >     echo "$clang $arm_clang_target -fno-short-enums -fshort-enums"
  >     echo "$clang $arm_clang_target -fshort-enums -fno-short-enums"
  >   fi
  >   if arm_gcc_present; then
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

--print-target names the representation of each configuration.

  $ configurations | while read -r cc target this other; do
  >   expected=short
  >   [ "$this" = -fno-short-enums ] && expected=int-sized
  >   typec --cc="$cc" $target $this --print-target |
  >     grep -qx "enum_representation: $expected" ||
  >     echo "representation: $cc $this"
  > done

An enumeration whose values fit in 8 bits has 8 bits under short
enumerations, so typec refuses a bit-field of 9 bits of it under them
alone. --emit-c runs no compile of the unit, so a refusal is typec's
and not the backend's.

  $ cat > bitfield.tc <<'EOF'
  > struct s { enum { A } f : 9; };
  > EOF
  $ configurations | while read -r cc target this other; do
  >   expected=accepted
  >   [ "$this" = -fshort-enums ] && expected=refused
  >   outcome=accepted
  >   typec --cc="$cc" $target $this --emit-c -o /dev/null bitfield.tc \
  >     2> /dev/null ||
  >     outcome=refused
  >   [ "$outcome" = "$expected" ] || echo "$outcome: $cc $this"
  > done

An -Xclang -fshort-enums reaches the target query, so it gives Clang
the short representation.

  $ if arm_clang_present; then
  >   typec --cc="$clang" $arm_clang_target -Xclang -fshort-enums \
  >     --print-target | grep -qx 'enum_representation: short' ||
  >     echo "-Xclang -fshort-enums: not short"
  > fi

An enumeration whose earlier declaration alone holds packed compiles
under each configuration.

  $ cat > packed.tc <<'EOF'
  > enum __attribute__((packed)) p7;
  > enum p7 { P7 };
  > EOF
  $ configurations | while read -r cc target this other; do
  >   typec --cc="$cc" $target $this -c packed.tc ||
  >     echo "refused: $cc $this"
  > done
