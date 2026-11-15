SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A match (design 4) becomes a block that reaches its scrutinee through a
pointer, to the lvalue that a pointer reaches or that a name designates,
or else to a copy, and a switch on its tag with a case for every
constructor, the arm of a default taking those no label names. Each arm
is a block that declares its bindings and ends in a trap, and the
switch's default, which only an invalid tag reaches, traps (design 13.5,
10.5). The scrutinee and the block items keep their tokens and lines.

  $ cat > lower.tc <<'EOF'
  > type e = | A | B(int i, e *next) | C(long l);
  > long f(const e *p, e v) {
  >   match (*p) {
  >   case B(i, _):
  >     return i;
  >   case A: case C(_):
  >     break;
  >   }
  >   match (v) {
  >   case C(l):
  >     match (*p) { default: return l; }
  >   default:
  >     break;
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe lower.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^long f/,$p'
  long f(const e *p, e v) {
  { const struct e *const __tc_match = &(
  *p
  ); switch (__tc_match->tag) {
  case e_B: { const __typeof__(__tc_match->u.B.i) i = __tc_match->u.B.i;
      return i;
   __builtin_trap(); }
  case e_A: case e_C: {
      break;
   __builtin_trap(); }
  default: __builtin_trap(); } }
  { const struct e *const __tc_match = &(
  v
  ); switch (__tc_match->tag) {
  case e_C: { const __typeof__(__tc_match->u.C.l) l = __tc_match->u.C.l;
  { const struct e *const __tc_match = &(
  *p
  ); switch (__tc_match->tag) {
  case e_A: case e_B: case e_C: {
   return l;
   __builtin_trap(); }
  default: __builtin_trap(); } }
   __builtin_trap(); }
  case e_A: case e_B: {
      break;
   __builtin_trap(); }
  default: __builtin_trap(); } }
    return 0;
  }

A scrutinee declared register is copied, as C takes no address of it
(C11 6.5.3.2p1), also an element of a register array; an element of
another array is reached through a pointer.

  $ cat > register.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(register e r) {
  >   match (r) {
  >   case B(i): {
  >     int i = 2;
  >     return i;
  >   }
  >   default:
  >     return 0;
  >   }
  > }
  > int g(e a[2]) {
  >   match (a[1]) { default: return 1; }
  > }
  > int h(void) {
  >   register e a[2] = { A, A };
  >   match (a[1]) { default: return 1; }
  > }
  > EOF
  $ ./golden.exe register.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^int f/,$p'
  int f(register e r) {
  { const struct e __tc_copy = (
  r
  ), *const __tc_match = &__tc_copy; switch (__tc_match->tag) {
  case e_B: { const __typeof__(__tc_match->u.B.i) i = __tc_match->u.B.i;
   {
      int i = 2;
      return i;
    }
   __builtin_trap(); }
  case e_A: {
      return 0;
   __builtin_trap(); }
  default: __builtin_trap(); } }
  }
  int g(e a[2]) {
  { const struct e *const __tc_match = &(
  a[1]
  ); switch (__tc_match->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  default: __builtin_trap(); } }
  }
  int h(void) {
    register e a[2] = {
  { .tag = e_A }
  ,
  { .tag = e_A }
   };
  { const struct e __tc_copy = (
  a[1]
  ), *const __tc_match = &__tc_copy; switch (__tc_match->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  default: __builtin_trap(); } }
  }

Each refusal is located at the construct it concerns.

  $ cat > missing.tc <<'EOF'
  > type e = | A | B(int i) | C;
  > void f(e v) {
  >   match (v) {
  >   case B(_):
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe missing.tc
  missing.tc:3: the match does not cover the constructors 'A' and 'C' of the variant 'e' (design 4.2 rule 1) [TC0018]
  [1]

  $ cat > twice.tc <<'EOF'
  > type e = | A | B(int i);
  > void f(e v) {
  >   match (v) {
  >   case A:
  >     break;
  >   case B(_):
  >   case A:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe twice.tc
  twice.tc:7: the constructor 'A' is covered twice (design 4.2 rule 1) [TC0018]
  [1]

  $ cat > shared.tc <<'EOF'
  > type e = | A | B(int i);
  > void f(e v) {
  >   match (v) {
  >   case A:
  >   case B(i):
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe shared.tc
  shared.tc:5: the binding 'i' is in an arm of several labels, which none of them may bind (design 4.1 rule 6) [TC0017]
  [1]

  $ cat > scrutinee.tc <<'EOF'
  > type e = | A;
  > void f(e *p) {
  >   match (p) {
  >   default:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe scrutinee.tc
  scrutinee.tc:3: the scrutinee of a match is not of a variant type; a pointer is not dereferenced implicitly (design 4.1 rule 1) [TC0014]
  [1]

A match body is a sequence of arms, each of labels and at least one
block item (design 4.1 rule 2).

  $ cat > form.tc <<'EOF'
  > type e = | A;
  > void f(e v) {
  >   match (v) {
  >     v = v;
  >   }
  > }
  > EOF
  $ ./golden.exe form.tc
  form.tc:4: expected `case` or `default` to begin an arm of `match`, found `v` (design 4.1 rule 2) [TC0015]
  [1]

A pattern names a constructor of the scrutinee's type, with a
sub-pattern for each of its fields (design 4.1 rule 3).

  $ cat > pattern.tc <<'EOF'
  > type e = | A | B(int i);
  > void f(e v) {
  >   match (v) {
  >   case B(i, j):
  >     break;
  >   default:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe pattern.tc
  pattern.tc:4: the pattern 'B' has 2 sub-pattern(s), and the constructor has 1 field(s) (design 4.1 rule 3) [TC0016]
  [1]

A match has at most one `default`, and that one covers a constructor
(design 4.2 rule 2).

  $ cat > default.tc <<'EOF'
  > type e = | A;
  > void f(e v) {
  >   match (v) {
  >   case A:
  >     break;
  >   default:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe default.tc
  default.tc:6: the `default` of a match covers no constructor (design 4.2 rule 2) [TC0019]
  [1]

A `case` or `default` label inside a match arm belongs to the match or
to a switch inside the arm (design 4.3 rule 3).

  $ cat > label.tc <<'EOF'
  > type e = | A;
  > void f(e v, int n) {
  >   switch (n) {
  >   case 0:
  >     match (v) {
  >     case A: {
  >     case 1:
  >       break;
  >     }
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe label.tc
  label.tc:7: a case or default label inside a match arm, which is not one of its own and belongs to no switch inside it (design 4.3 rule 3) [TC0020]
  [1]

The end of every arm, the last one too, must be unreachable by the rules
of design 4.4 (4.3 rule 1), which evaluate no condition but a constant;
the refusal names the arm. A label inside an arm is the target only of a
goto in the same arm (4.3 rule 3).

  $ cat > open.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     return 1;
  >   case B(i):
  >     if (i > n)
  >       return i;
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe open.tc
  open.tc:6: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

An item is reachable if it carries or contains a label (4.4), so the end
of an arm is reached through a goto to a label in a block, or through a
case label in a block that the switch around it jumps to.

  $ cat > contained.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     if (n)
  >       goto inside;
  >     return 0;
  >     {
  >     inside:
  >       n++;
  >     }
  >   case B:
  >     return 1;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe contained.tc
  contained.tc:4: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

  $ cat > section.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     switch (n) {
  >     default:
  >       return 1;
  >       {
  >       case 2:
  >         ;
  >       }
  >     }
  >   case B:
  >     return 1;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe section.tc
  section.tc:4: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

A label counts through a loop and a nested switch: a case label in a
loop in the switch body, as in Duff's device, and a named label in a
nested switch make the arm end reachable. A default label of a nested
switch is not one of the switch around it, which without its own
default can complete.

  $ cat > duff.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     switch (n) {
  >     default:
  >       return 1;
  >       while (n) {
  >       case 2:
  >         n--;
  >       }
  >     }
  >   case B:
  >     return 1;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe duff.tc
  duff.tc:4: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

  $ cat > nswnamed.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     if (n) goto L;
  >     return 0;
  >     switch (n) { case 1: return 2; L: ; }
  >   case B:
  >     return 1;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe nswnamed.tc
  nswnamed.tc:4: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

  $ cat > innerdefault.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n, int m) {
  >   match (v) {
  >   case A:
  >     switch (n) {
  >     case 1:
  >       while (m) { switch (m) { default: m--; } }
  >       return 1;
  >     }
  >   case B:
  >     return 1;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe innerdefault.tc
  innerdefault.tc:4: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
  [1]

A case label of a switch, or any label in a match arm, inside an item
does not make the item reachable: the switch reaches its case labels
only through its controlling expression, and a label in an arm is
reached only from the arm.

  $ cat > nested.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, e w, int n) {
  >   match (v) {
  >   case A:
  >     return 0;
  >     switch (n) {
  >     case 1:
  >       break;
  >     }
  >   case B:
  >     return 1;
  >     match (w) {
  >     case A:
  >     inside:
  >       break;
  >     case B:
  >       break;
  >     }
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe nested.tc > /dev/null && echo accepted
  accepted

  $ cat > entry.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(e v) {
  >   match (v) {
  >   case A:
  >     goto inside;
  >   case B(i):
  >   inside:
  >     return i;
  >   }
  > }
  > EOF
  $ ./golden.exe entry.tc
  entry.tc:5: a jump into a match arm from outside it (design 4.3 rule 3) [TC0022]
  [1]

A break or continue in a statement expression in the condition of a
loop or the step of a for leaves the loop in Clang and the statement
around the loop in GCC, so it is refused unless it leaves a loop, switch
or match within the expression (design 4.4).

  $ cat > control.tc <<'EOF'
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     while (({ if (n) break; n; }))
  >       n--;
  >     return n;
  >   case B:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe control.tc
  control.tc:5: a break in the condition of a loop or the step of a for, which Clang takes to leave the loop and GCC the statement around it (design 4.4) [TC0026]
  [1]

A break leaves a loop, switch or match, and a statement expression
outside them has none to leave (design 4.3 rule 2).

  $ cat > stray.tc <<'EOF'
  > int f(int n) {
  >   return ({ if (n) break; n; });
  > }
  > EOF
  $ ./golden.exe stray.tc
  stray.tc:2: break outside a loop, switch or match (C11 6.8.6.3p1, design 4.3 rule 2) [TC0027]
  [1]

The scrutinee is of a variant whose declaration is in scope at the
match, which names its tag and enumerators (design 4.1 rule 1).

  $ cat > carried.tc <<'EOF'
  > void f(void) {
  >   match (({ type e = | A; e v = A; v; })) {
  >   case A:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe carried.tc
  carried.tc:2: the match is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant (design 4.1 rule 1) [TC0014]
  [1]

Within the scope, in the block of the declaration or a statement
expression in it, the match stands.

  $ cat > scoped.tc <<'EOF'
  > int f(void) {
  >   type e = | A;
  >   e v = A;
  >   match (v) {
  >   case A:
  >     break;
  >   }
  >   return ({ match (v) { case A: break; } 1; });
  > }
  > EOF
  $ ./golden.exe scoped.tc > /dev/null
