SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The constructs that ask whether types are compatible (design 13.5). The
backend sees a distinct type as the typedef of its representation, so
where Type-C text compares a distinct type typec answers: a generic
selection becomes its selected expression in parentheses, and
__builtin_types_compatible_p the integer constant 1 or 0.

  $ cat > select.tc <<'EOF'
  > type d = distinct int;
  > d x;
  > int a = _Generic(x, d: 1, int: 2);
  > int b = _Generic((int)x, d: 1, int: 2);
  > int c = __builtin_types_compatible_p(d, int);
  > int k = __builtin_types_compatible_p(const d, d);
  > EOF
  $ ./golden.exe select.tc | grep -v '^# ' | grep .
  typedef
   int
  d
  ;
  d x;
  int a = 
  (
   1
  )
  ;
  int b = 
  (
   2
  )
  ;
  int c = 
  0
  ;
  int k = 
  1
  ;

The kept expression keeps the edits that lowering makes in it, and the
controlling expression and the associations dropped lose theirs: here a
constructor in each, and selections nested in both.

  $ cat > nested.tc <<'EOF'
  > type d = distinct int;
  > type e = | A | B(int i);
  > d x;
  > e f(void) {
  >   return _Generic(x, int: e.B(1),
  >                   d: _Generic(x, d: e.B(_Generic(0, d: 3, int: 4)),
  >                               default: e.A));
  > }
  > int g(void) { return _Generic(_Generic(x, d: 1, int: 2), d: 3, int: 4); }
  > EOF
  $ ./golden.exe nested.tc | grep -v '^# ' | grep .
  typedef
   int
  d
  ;
  struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum e_tag tag; union {
   
   
  struct {
  int i
  ; } B;
  } u; };
  d x;
  e f(void) {
    return 
  (
   
  (
   
  ((struct e){ .tag = e_B, .u.B = { 
  (
   4
  )
   } })
  )
  )
  ;
  }
  int g(void) { return 
  (
   4
  )
  ; }

A selection that compares no distinct type is the backend's, and its
tokens stay as they are.

  $ cat > plain.tc <<'EOF'
  > int n = _Generic(1, int: 2, default: 3);
  > int m = __builtin_types_compatible_p(int, long);
  > EOF
  $ ./golden.exe plain.tc
  int n = _Generic(1, int: 2, default: 3);
  int m = __builtin_types_compatible_p(int, long);

A string literal that a selection gives keeps no parentheses, so that it
still initialises an array (C11 6.7.9p14).

  $ printf 'type d = distinct int;\nd x;\nchar s[] = _Generic(x, d: "ab", default: "c");\n' > string.tc
  $ ./golden.exe string.tc | grep -v '^# ' | grep . | tail -3
  char s[] = 
   "ab"
  ;

C text compares the types as it sees them, the representation of a
distinct type (design 10.2), as the backend does, so its selections stay
as they are.

  $ printf 'type d = distinct int;\nd x;\n# 1 "c.h" 1\nint a = _Generic(x, int: 1, default: 2);\n' > c_text.tc
  $ ./golden.exe c_text.tc | grep -v '^# ' | grep . | tail -1
  int a = _Generic(x, int: 1, default: 2);
  $ printf 'type d = distinct int;\n# 1 "c.h" 1\nint b = __builtin_types_compatible_p(d, int);\nint c = _Generic(1, d: 1, int: 2);\n' > c_twice.tc
  $ ./golden.exe c_twice.tc
  c.h:2: the type of a generic association is compatible with that of another (C11 6.5.1.1p2)
  [1]

C text sees a distinct type inside another type as its representation
too.

  $ printf 'type d = distinct int;\nd *p;\n# 1 "c.h" 1\nint a = _Generic(p, int *: 1, default: 2);\n' > c_pointer.tc
  $ ./golden.exe c_pointer.tc | grep -v '^# ' | grep . | tail -1
  int a = _Generic(p, int *: 1, default: 2);

An answer that depends on a type typec does not know is refused in
Type-C text that has declared a distinct type, as the unknown type may
be one.

  $ printf 'type d = distinct int;\nd x; int n;\nint f(void) { return _Generic(__builtin_choose_expr(__builtin_constant_p(n), x, x), int: 1, default: 2); }\n' > unknown.tc
  $ ./golden.exe unknown.tc
  unknown.tc:3: the answer to a comparison of types, which may have a distinct type in them, depends on the condition of __builtin_choose_expr at unknown.tc:3, which typec does not type yet (design 13.3)
  [1]
