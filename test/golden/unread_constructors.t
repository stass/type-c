SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The arguments of an attribute are unread text, which has no target type
(design 13.5): a constructor is named there only qualified, as `T.C`.
Through a generic or a universe name `T` the qualified form is refused,
since lowering writes `T` under a name of its own.

  $ cat > generic.tc <<'EOF'
  > type o(T) = | N | S(T x);
  > int y __attribute__((aligned(sizeof(o(int).S(1)))));
  > EOF
  $ ./golden.exe generic.tc
  generic.tc:2: `o` in the arguments of an attribute denotes a generic, which lowering writes under a name of its own, but it leaves the arguments as written (design 13.5) [TC0046]
  [1]
  $ cat > universe.tc <<'EOF'
  > int y __attribute__((aligned(sizeof(option(int).None))));
  > EOF
  $ ./golden.exe universe.tc
  universe.tc:1: `option` in the arguments of an attribute denotes a universe name, which lowering writes under a name of its own, but it leaves the arguments as written (design 13.5) [TC0046]
  [1]

Through a typedef name, which lowering keeps, `T.C` is no C: lowering
leaves it as written, for the backend to refuse.

  $ cat > typedef.tc <<'EOF'
  > type v = | A | B(int x);
  > int y __attribute__((aligned(sizeof(v.B(1)))));
  > EOF
  $ ./golden.exe typedef.tc | grep aligned
  int y __attribute__((aligned(sizeof(v.B(1)))));

An unqualified name is looked up as C looks it up (design 3.3), so it
does not denote the constructor: the backend reads the enumerator `A`
here, as typing does without a target type, and the constructor
lowers to `v_A`, which the backend never reads as `A`.

  $ cat > unqualified.tc <<'EOF'
  > enum { A = 8 };
  > type v = | A | B(int x);
  > int y __attribute__((aligned(A)));
  > int z = A;
  > EOF
  $ ./golden.exe unqualified.tc | grep 'v_A\|aligned\|z ='
  enum v_tag { v_A, v_B }; struct v { enum v_tag tag; union {
  int y __attribute__((aligned(A)));
  int z = A;

So does moved text: the instance keeps `aligned(A)`, which denotes the
enumerator at the definition and where lowering writes the instance.

  $ cat > moved.tc <<'EOF'
  > enum { A = 8 };
  > type g(T) = struct { T v __attribute__((aligned(A))); };
  > type w = | A | B(int x);
  > g(int) x;
  > EOF
  $ ./golden.exe moved.tc | grep aligned
  struct g__i { __tc_arg__i v __attribute__ ( ( aligned ( A ) ) ) ; } ;

Where C declares nothing under the spelling, the name is undeclared, as
typing finds it in read text; in unread text that is the backend's to
say, as for any name (design 13.5).

  $ cat > undeclared.tc <<'EOF'
  > type v = | A | B(int x);
  > int y __attribute__((aligned(sizeof(B(1)))));
  > EOF
  $ ./golden.exe undeclared.tc | grep aligned
  int y __attribute__((aligned(sizeof(B(1)))));
  $ cat > read.tc <<'EOF'
  > type v = | A | B(int x);
  > int y = sizeof(B(1));
  > EOF
  $ ./golden.exe read.tc
  read.tc:2: 'B' is not declared (C11 6.5.1p2)
  [1]
