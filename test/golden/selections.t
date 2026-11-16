SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The constructs that ask whether types are compatible (design 13.5). The
backend sees a distinct type as the typedef of its representation, so
where Type-C text compares a distinct type typec answers: a generic
selection keeps its tokens, and its controlling expression and the type
name of each association are replaced so that the backend selects the
association typec selects; __builtin_types_compatible_p becomes the
integer constant 1 or 0.

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
  int a = _Generic(
  ((void)(
  x
  ), (char (*)[1])0)
  , 
  char (*)[1]
  : 1, 
  char (*)[2]
  : 2);
  int b = _Generic(
  ((void)(
  (int)x
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 1, 
  char (*)[2]
  : 2);
  int c = 
  0
  ;
  int k = 
  1
  ;

The controlling expression and the associations keep the edits that
lowering makes in them, and a replaced type name loses its own: here a
constructor in each association, and selections nested in both.

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
    return _Generic(
  ((void)(
  x
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 
  ((struct e){ .tag = e_B, .u.B = { 
  1
   } })
  ,
                    
  char (*)[2]
  : _Generic(
  ((void)(
  x
  ), (char (*)[1])0)
  , 
  char (*)[1]
  : 
  ((struct e){ .tag = e_B, .u.B = { 
  _Generic(
  ((void)(
  0
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 3, 
  char (*)[2]
  : 4)
   } })
  ,
                                default: 
  ((struct e){ .tag = e_A })
  ));
  }
  int g(void) { return _Generic(
  ((void)(
  _Generic(
  ((void)(
  x
  ), (char (*)[1])0)
  , 
  char (*)[1]
  : 1, 
  char (*)[2]
  : 2)
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 3, 
  char (*)[2]
  : 4); }

A selection that compares no distinct type is the backend's, and its
tokens stay as they are.

  $ cat > plain.tc <<'EOF'
  > int n = _Generic(1, int: 2, default: 3);
  > int m = __builtin_types_compatible_p(int, long);
  > EOF
  $ ./golden.exe plain.tc
  # 1 "plain.tc"
  int n = _Generic(1, int: 2, default: 3);
  int m = __builtin_types_compatible_p(int, long);

Where typec selects the default association, it stays, and the
controlling expression steers to the index of its position, which no
type name has.

  $ cat > default.tc <<'EOF'
  > type d = distinct int;
  > d x;
  > int y = _Generic(x, int: 1, default: 2);
  > EOF
  $ ./golden.exe default.tc | grep -v '^# ' | grep . | tail -7
  int y = _Generic(
  ((void)(
  x
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 1, default: 2);

A selection answered inside a type name that is replaced goes with it,
with its own edits.

  $ cat > inner.tc <<'EOF'
  > type d = distinct int;
  > d x;
  > int z = _Generic(x, __typeof__(_Generic(x, d: 1.0, int: 2)): 1, d: 2);
  > EOF
  $ ./golden.exe inner.tc | grep -v '^# ' | grep . | tail -9
  int z = _Generic(
  ((void)(
  x
  ), (char (*)[2])0)
  , 
  char (*)[1]
  : 1, 
  char (*)[2]
  : 2);

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
  unknown.tc:3: the answer to a comparison of types, which may have a distinct type in them, depends on the condition of __builtin_choose_expr at unknown.tc:3, which typec does not type yet (design 13.3) [TC0031]
  [1]
