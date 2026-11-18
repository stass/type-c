SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A match (design 4) becomes a block that reaches its scrutinee through a
pointer, to the lvalue that a pointer reaches or that a name designates,
or else to a copy, and a switch on its tag with a case for every
constructor, the arm of a default taking those no label names. Each arm
is a block that declares its bindings and ends in a trap, and the
switch's default, which only an invalid tag reaches, traps (design 13.5,
10.5). An arm that binds holds its items in a block of their own after
the bindings, so that they begin a block as written. The scrutinee and
the block items keep their tokens and lines.

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
  { const struct e *const __tc_match0 = &(
  *p
  ); switch (__tc_match0->tag) {
  case e_B: { const __typeof__(__tc_match0->u.B.i) i = __tc_match0->u.B.i; {
      return i;
   } __builtin_trap(); }
  case e_A: case e_C: {
      break;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  { const struct e *const __tc_match1 = &(
  v
  ); switch (__tc_match1->tag) {
  case e_C: { const __typeof__(__tc_match1->u.C.l) l = __tc_match1->u.C.l; {
  { const struct e *const __tc_match2 = &(
  *p
  ); switch (__tc_match2->tag) {
  case e_A: case e_B: case e_C: {
   return l;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
   } __builtin_trap(); }
  case e_A: case e_B: {
      break;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
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
  { const struct e __tc_copy0 = (
  r
  ), *const __tc_match0 = &__tc_copy0; switch (__tc_match0->tag) {
  case e_B: { const __typeof__(__tc_match0->u.B.i) i = __tc_match0->u.B.i; {
   {
      int i = 2;
      return i;
    }
   } __builtin_trap(); }
  case e_A: {
      return 0;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  }
  int g(e a[2]) {
  { const struct e *const __tc_match1 = &(
  a[1]
  ); switch (__tc_match1->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  }
  int h(void) {
    register e a[2] = {
  { .tag = e_A }
  ,
  { .tag = e_A }
   };
  { const struct e __tc_copy2 = (
  a[1]
  ), *const __tc_match2 = &__tc_copy2; switch (__tc_match2->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  }

A scrutinee that is a member, reached from its base by member
designators only, is read through a pointer to that base where the
base's address is aligned, so no pointer to the member is formed: the
base of `.` is an aligned object, that of `->` a pointer read as a
stored value. The tag, the bindings and the nodes of a selection tree
read the member path from that pointer. A path with a subscript, or a
base pointer formed by arithmetic, is copied.

  $ cat > member.tc <<'EOF'
  > type e = | A | B(int i);
  > type w = | W(e x) | N;
  > struct holder { int n; e state; e pair[2]; struct { w wrapped; } inner; };
  > int f(struct holder *h) {
  >   match (h->state) { case B(i): return i; default: return 0; }
  > }
  > int g(struct holder h) {
  >   if (case W(B(i)) = h.inner.wrapped) return i;
  >   return 0;
  > }
  > int k(struct holder *h) {
  >   match (h->pair[1]) { default: return 1; }
  > }
  > int m(struct holder *h) {
  >   match ((h + 1)->state) { default: return 1; }
  > }
  > EOF
  $ ./golden.exe member.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^int f/,$p'
  int f(struct holder *h) {
  { __extension__ __auto_type const __tc_base0 = (
  h
  ); switch (__tc_base0->state.tag) {
  case e_B: { const __typeof__(__tc_base0->state.u.B.i) i = __tc_base0->state.u.B.i; {
   return i;
   } __builtin_trap(); }
  case e_A: {
   return 0;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  }
  int g(struct holder h) {
  { __extension__ __auto_type const __tc_base1 = &(
   h
  ); unsigned __tc_arm1; switch (__tc_base1->inner.wrapped.tag) { case w_W: switch (__tc_base1->inner.wrapped.u.W.x.tag) { case e_B: __tc_arm1 = 1; break; case e_A: __tc_arm1 = 0; break; case __tc_tag_max__e_tag: default: __builtin_trap(); } break; case w_N: __tc_arm1 = 0; break; case __tc_tag_max__w_tag: default: __builtin_trap(); } if (__tc_arm1 == 1) { const __typeof__(__tc_base1->inner.wrapped.u.W.x.u.B.i) i = __tc_base1->inner.wrapped.u.W.x.u.B.i;
   return i;
   } else { } }
  return 0;
  }
  int k(struct holder *h) {
  { const struct e __tc_copy2 = (
  h->pair[1]
  ), *const __tc_match2 = &__tc_copy2; switch (__tc_match2->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
  }
  int m(struct holder *h) {
  { const struct e __tc_copy3 = (
  (h + 1)->state
  ), *const __tc_match3 = &__tc_copy3; switch (__tc_match3->tag) {
  case e_A: case e_B: {
   return 1;
   __builtin_trap(); }
  case __tc_tag_max__e_tag: default: __builtin_trap(); } }
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
  missing.tc:3: error: the match does not cover the constructors 'A' and 'C' of the variant 'e' [match-coverage]
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
  twice.tc:7: error: the constructor 'A' is covered twice [match-coverage]
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
  shared.tc:5: error: the labels 'A' and 'B(i)' share an arm, so 'i' may not be bound in it; give each label its own arm [shared-arm-binding]
  [1]

A pragma that a macro leaves around a pattern is no part of the label
that the message quotes:

  $ cat > shared_pragma.tc <<'EOF'
  > type e = | A | B(int i);
  > void f(e v) {
  >   match (v) {
  >   case
  > #pragma GCC diagnostic push
  >   A
  > #pragma GCC diagnostic pop
  >   :
  >   case B(
  > #pragma GCC diagnostic push
  >   i
  > #pragma GCC diagnostic pop
  >   ):
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe shared_pragma.tc
  shared_pragma.tc:11: error: the labels 'A' and 'B( i )' share an arm, so 'i' may not be bound in it; give each label its own arm [shared-arm-binding]
  [1]

A C programmer's shared case, with each label binding the same name:

  $ cat > shared_both.tc <<'EOF'
  > type shape = | Circle(double r) | Square(double s) | Dot;
  > double f(shape s) {
  >   match (s) {
  >   case Circle(x): case Square(x):
  >     return x;
  >   case Dot:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe shared_both.tc
  shared_both.tc:4: error: the labels 'Circle(x)' and 'Square(x)' share an arm, so 'x' may not be bound in it; give each label its own arm [shared-arm-binding]
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
  scrutinee.tc:3: error: the scrutinee of a match is of type 'e *', not a variant type; a pointer is not dereferenced implicitly [match-scrutinee]
  [1]

The bindings and the items of an arm are one scope (design 4.1 rules 4
and 5): an item that redeclares a binding is refused, although the
block that lowering makes around the items would hide the binding.

  $ cat > redeclared.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(e v) {
  >   match (v) {
  >   case B(i):
  >     int i = 1;
  >     return i;
  >   case A:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe redeclared.tc
  redeclared.tc:5: error: 'i' is declared twice in one scope without linkage (C11 6.7p3)
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
  form.tc:4: error: expected `case` or `default` to begin an arm of `match`, found `v` [match-arm-form]
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
  pattern.tc:4: error: the pattern 'B' has 2 sub-pattern(s), and the constructor has 1 field(s) [match-pattern]
  [1]

A case label that omits the field list of a constructor with fields is
refused: only a single-pattern test may (design 4.1 rule 3, 4.6 rule 2).

  $ cat > label_fields.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v) {
  >   match (v) {
  >   case Cons:
  >     return 1;
  >   case Nil:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe label_fields.tc
  label_fields.tc:4: error: the case label 'Cons' omits the field list of a constructor with 2 field(s); write 'Cons(_, _)' to ignore the fields [match-pattern]
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
  default.tc:6: error: the `default` of a match covers no constructor [match-default]
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
  label.tc:7: error: a case or default label inside a match arm, which is not one of its own and belongs to no switch inside it [stray-case-label]
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
  open.tc:6: error: the arm of 'B(i)' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
  [1]

An arm of many labels names the first eight, as a missed arm names
constructors, and counts the others:

  $ cat > many.tc <<'EOF'
  > type op = | A | B | C | D | E | F | G | H | I | J(int j);
  > int f(op o) {
  >   int k = 0;
  >   match (o) {
  >   case A: case B: case C: case D: case E: case F: case G: case H: case I:
  >     k = 1;
  >   case J(_):
  >     return 2;
  >   }
  >   return k;
  > }
  > EOF
  $ ./golden.exe many.tc
  many.tc:5: error: the arm of 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' and 1 more can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
  [1]
  $ cat > many_shared.tc <<'EOF'
  > type op = | A | B | C | D | E | F | G | H | I | J(int j);
  > int f(op o) {
  >   match (o) {
  >   case A: case B: case C: case D: case E: case F: case G: case H: case I:
  >   case J(j):
  >     return 2;
  >   }
  > }
  > EOF
  $ ./golden.exe many_shared.tc
  many_shared.tc:5: error: the labels 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' and 2 more share an arm, so 'j' may not be bound in it; give each label its own arm [shared-arm-binding]
  [1]

A C fall-through into the next arm, and a last arm without its break,
as a ported switch has them:

  $ cat > fall.tc <<'EOF'
  > type shape = | Circle(double r) | Square(double s) | Dot;
  > int f(shape s) {
  >   int k = 0;
  >   match (s) {
  >   case Circle(_): k = 1;
  >   case Square(_): k = 2; break;
  >   case Dot: break;
  >   }
  >   return k;
  > }
  > EOF
  $ ./golden.exe fall.tc
  fall.tc:5: error: the arm of 'Circle(_)' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
  [1]
  $ cat > last.tc <<'EOF'
  > type shape = | Circle(double r) | Square(double s) | Dot;
  > int f(shape s) {
  >   int k = 0;
  >   match (s) {
  >   case Circle(_): k = 1; break;
  >   case Square(_): case Dot: k = 2;
  >   }
  >   return k;
  > }
  > EOF
  $ ./golden.exe last.tc
  last.tc:6: error: the arm of 'Square(_)' and 'Dot' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  contained.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  section.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  duff.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  nswnamed.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  innerdefault.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
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
  entry.tc:5: error: a jump into a match arm from outside it [match-arm-entry]
  [1]

A break or continue in a statement expression in the condition of a
loop or the step of a for leaves the loop in Clang and the statement
around the loop in GCC, so in Type-C text it is refused unless it leaves
a loop, switch or match within the expression (design 4.4).

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
  control.tc:5: error: a break in the condition of a loop or the step of a for, which Clang takes to leave the loop and GCC the statement around it [ambiguous-jump]
  [1]

C text keeps such a break, and the backend decides where it goes. A
C header included in a match arm is C text inside the arm, whose end
must be unreachable on either reading (design 4.4): here the break
leaves the match in GCC, and the loop, and with it the arm, in Clang.

  $ cat > clang_ends.tc <<'EOF'
  > # 1 "clang_ends.tc"
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  > # 1 "step.h" 1
  >     for (;; ({ break; })) n--;
  > # 6 "clang_ends.tc" 2
  >   case B:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe clang_ends.tc
  clang_ends.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
  [1]

Here Clang leaves the inner loop for the return, and GCC the outer loop,
and with it the arm.

  $ cat > gcc_ends.tc <<'EOF'
  > # 1 "gcc_ends.tc"
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  >     for (;;) {
  > # 1 "step.h" 1
  >       for (;; ({ break; })) n--;
  > # 7 "gcc_ends.tc" 2
  >       return n;
  >     }
  >   case B:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe gcc_ends.tc
  gcc_ends.tc:4: error: the arm of 'A' can reach its end; control does not fall out of an arm, so end it with break, return, continue or goto [match-arm-end]
  [1]

An arm that ends unreachably on both readings stands, and so does such
a break in a C file; the loop reaches the C unchanged.

  $ cat > both_end.tc <<'EOF'
  > # 1 "both_end.tc"
  > type e = | A | B;
  > int f(e v, int n) {
  >   match (v) {
  >   case A:
  > # 1 "condition.h" 1
  >     while (({ if (n) break; n; })) n--;
  > # 6 "both_end.tc" 2
  >     return n;
  >   case B:
  >     return 0;
  >   }
  >   return -1;
  > }
  > EOF
  $ ./golden.exe both_end.tc | grep break
      while (({ if (n) break; n; })) n--;
  $ cat > plain_loop.c <<'EOF'
  > int f(int n) {
  >   for (;;)
  >     while (({ if (n) break; n; })) n--;
  > }
  > EOF
  $ ./golden.exe plain_loop.c
  # 1 "plain_loop.c"
  int f(int n) {
    for (;;)
      while (({ if (n) break; n; })) n--;
  }

A break leaves a loop, switch or match, and a statement expression
outside them has none to leave (design 4.3 rule 2).

  $ cat > stray.tc <<'EOF'
  > int f(int n) {
  >   return ({ if (n) break; n; });
  > }
  > EOF
  $ ./golden.exe stray.tc
  stray.tc:2: error: break outside a loop, switch or match [break-outside]
  [1]

A break that leaves a match ends its arm (design 4.3 rule 5). Before
this code became an arm the break left the loop; in the arm it would
leave only the match, and the loop would go on.

  $ cat > early.tc <<'EOF'
  > type e = | A | B;
  > int f(e *v, int n) {
  >   for (int i = 0; i < n; i++) {
  >     match (v[i]) {
  >     case A:
  >       if (i > 2)
  >         break;
  >       n--;
  >       break;
  >     case B:
  >       return i;
  >     }
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe early.tc
  early.tc:7: error: a break that leaves the match before the end of its arm; put the `break` last in the arm, or leave the loop with `goto` or `return`, or use a single-pattern test [early-break]
  [1]

A break that a C header brings into an arm is C text, which the rule
does not bind: the arm is judged by rule 1 alone.

  $ cat > header_break.tc <<'EOF'
  > # 1 "header_break.tc"
  > type e = | A | B;
  > int f(e v, int n) {
  >   for (;;) {
  >     match (v) {
  >     case A:
  > # 1 "early.h" 1
  >       if (n) break;
  > # 7 "header_break.tc" 2
  >       n--;
  >       break;
  >     case B:
  >       return n;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe header_break.tc | grep 'if (n)'
        if (n) break;

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
  carried.tc:2: error: the match is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant [match-scrutinee]
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
