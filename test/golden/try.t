SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A try stands in three positions (design 5.1 rule 3): the whole of an
expression statement, the whole right operand of a simple assignment
that is one, and the whole initialiser of the one declarator of a
declaration that is a block item. Lowering writes a temporary that
holds the operand and its test before the statement or declaration
that holds the try, and the Ok field where the try stood (design 13.5).
The error path traps on a tag that is neither Ok nor Err, and returns
the Err built from the temporary. A statement try e; reads no field and
leaves nothing after the test; a void T has no Ok field, and a void E
no Err field, so the Err is built without one.

  $ cat > statement.tc <<'EOF'
  > result(void, int) g(void);
  > result(int, int) h(void) {
  >   try g();
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe statement.tc
  # 1 "statement.tc"
  
  # 1 "statement.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "statement.tc"
  typedef void __tc_arg__v; typedef int __tc_arg__i; struct result__vi; typedef struct result__vi result__vi;
  # 1 "statement.tc"
  #pragma pack(pop)
  # 1 "statement.tc"
  
  # 1 "statement.tc"
  result__vi
  # 1 "statement.tc"
   g(void);
  
  # 2 "statement.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "statement.tc"
  struct result__ii; typedef struct result__ii result__ii;
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; }; enum result__vi_tag { result__vi_Err, result__vi_Ok }; struct result__vi { enum result__vi_tag tag; union { struct { __tc_arg__i error ; } Err; } u; };
  # 2 "statement.tc"
  #pragma pack(pop)
  # 2 "statement.tc"
  
  # 2 "statement.tc"
  result__ii
  # 2 "statement.tc"
   h(void) {
    
  # 3 "statement.tc"
  const struct result__vi __tc_t0 = g ( ) ; if (__tc_t0.tag != result__vi_Ok) { if (__tc_t0.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "statement.tc"
  
  # 3 "statement.tc"
  
  # 3 "statement.tc"
  
    return 
  # 4 "statement.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 4 "statement.tc"
  0
  # 4 "statement.tc"
   } })
  # 4 "statement.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A statement try e; discards the value of an Ok that has a field: no
read of the field is left as a statement of its own.

  $ cat > discarded.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   try f();
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe discarded.tc
  # 1 "discarded.tc"
  
  # 1 "discarded.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "discarded.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "discarded.tc"
  #pragma pack(pop)
  # 1 "discarded.tc"
  
  # 1 "discarded.tc"
  result__ii
  # 1 "discarded.tc"
   f(void);
  
  # 2 "discarded.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "discarded.tc"
  #pragma pack(pop)
  # 2 "discarded.tc"
  
  # 2 "discarded.tc"
  result__ii
  # 2 "discarded.tc"
   h(void) {
    
  # 3 "discarded.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "discarded.tc"
  
  # 3 "discarded.tc"
  
  # 3 "discarded.tc"
  
    return 
  # 4 "discarded.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 4 "discarded.tc"
  0
  # 4 "discarded.tc"
   } })
  # 4 "discarded.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > assignment.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x;
  >   x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe assignment.tc
  # 1 "assignment.tc"
  
  # 1 "assignment.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "assignment.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "assignment.tc"
  #pragma pack(pop)
  # 1 "assignment.tc"
  
  # 1 "assignment.tc"
  result__ii
  # 1 "assignment.tc"
   f(void);
  
  # 2 "assignment.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "assignment.tc"
  #pragma pack(pop)
  # 2 "assignment.tc"
  
  # 2 "assignment.tc"
  result__ii
  # 2 "assignment.tc"
   h(void) {
    int x;
    
  # 4 "assignment.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 4 "assignment.tc"
  x = 
  # 4 "assignment.tc"
  __tc_t0.u.Ok.value
  # 4 "assignment.tc"
  ;
    return 
  # 5 "assignment.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 5 "assignment.tc"
  x
  # 5 "assignment.tc"
   } })
  # 5 "assignment.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > declaration.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe declaration.tc
  # 1 "declaration.tc"
  
  # 1 "declaration.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "declaration.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "declaration.tc"
  #pragma pack(pop)
  # 1 "declaration.tc"
  
  # 1 "declaration.tc"
  result__ii
  # 1 "declaration.tc"
   f(void);
  
  # 2 "declaration.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "declaration.tc"
  #pragma pack(pop)
  # 2 "declaration.tc"
  
  # 2 "declaration.tc"
  result__ii
  # 2 "declaration.tc"
   h(void) {
    
  # 3 "declaration.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "declaration.tc"
  int x = 
  # 3 "declaration.tc"
  __tc_t0.u.Ok.value
  # 3 "declaration.tc"
  ;
    return 
  # 4 "declaration.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 4 "declaration.tc"
  x
  # 4 "declaration.tc"
   } })
  # 4 "declaration.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A label of C stands before the statement that holds a try, and an arm
holds one as any block does.

  $ cat > labelled.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(int c) {
  >   int x;
  >   switch (c) {
  >   case 1:
  >   again: x = try f();
  >   }
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe labelled.tc
  # 1 "labelled.tc"
  
  # 1 "labelled.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "labelled.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "labelled.tc"
  #pragma pack(pop)
  # 1 "labelled.tc"
  
  # 1 "labelled.tc"
  result__ii
  # 1 "labelled.tc"
   f(void);
  
  # 2 "labelled.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "labelled.tc"
  #pragma pack(pop)
  # 2 "labelled.tc"
  
  # 2 "labelled.tc"
  result__ii
  # 2 "labelled.tc"
   h(int c) {
    int x;
    switch (c) {
    case 1:
    again: 
  # 6 "labelled.tc"
  ; const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 6 "labelled.tc"
  x = 
  # 6 "labelled.tc"
  __tc_t0.u.Ok.value
  # 6 "labelled.tc"
  ;
    }
    return 
  # 8 "labelled.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 8 "labelled.tc"
  x
  # 8 "labelled.tc"
   } })
  # 8 "labelled.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > arm.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(result(int, int) r) {
  >   match (r) {
  >   case Ok(v):
  >     int w = try f();
  >     return Ok(v + w);
  >   default:
  >     return r;
  >   }
  > }
  > EOF
  $ ./golden.exe arm.tc
  # 1 "arm.tc"
  
  # 1 "arm.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "arm.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "arm.tc"
  #pragma pack(pop)
  # 1 "arm.tc"
  
  # 1 "arm.tc"
  result__ii
  # 1 "arm.tc"
   f(void);
  
  # 2 "arm.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "arm.tc"
  #pragma pack(pop)
  # 2 "arm.tc"
  
  # 2 "arm.tc"
  result__ii
  # 2 "arm.tc"
   h(
  # 2 "arm.tc"
  result__ii
  # 2 "arm.tc"
   r) {
    
  # 3 "arm.tc"
  { const struct result__ii *const __tc_match = &(
  # 3 "arm.tc"
  r
  # 3 "arm.tc"
  ); switch (__tc_match->tag) {
  # 3 "arm.tc"
  
    
  # 4 "arm.tc"
  case result__ii_Ok: { const __typeof__(__tc_match->u.Ok.value) v = __tc_match->u.Ok.value; {
  # 4 "arm.tc"
  
      
  # 5 "arm.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 5 "arm.tc"
  int w = 
  # 5 "arm.tc"
  __tc_t0.u.Ok.value
  # 5 "arm.tc"
  ;
      return 
  # 6 "arm.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 6 "arm.tc"
  v + w
  # 6 "arm.tc"
   } })
  # 6 "arm.tc"
  ;
    
  # 7 "arm.tc"
   } __builtin_trap(); }
  # 7 "arm.tc"
  
  # 7 "arm.tc"
  case result__ii_Err: {
  # 7 "arm.tc"
  
      return r;
    
  # 9 "arm.tc"
   __builtin_trap(); }
  # 9 "arm.tc"
  
  # 9 "arm.tc"
  default: __builtin_trap(); } }
  # 9 "arm.tc"
  
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A substatement that holds a try becomes a block, which holds the null
statement of its labels, the temporary, the test and the statement, so
that the labels stay under the statement around it.

  $ cat > substatement.tc <<'EOF'
  > result(int, int) f(void);
  > result(void, int) g(void);
  > result(int, int) h(int c) {
  >   int x = 0;
  >   if (c)
  >     x = try f();
  >   else
  >   again: try g();
  >   while (c--) try g();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe substatement.tc
  # 1 "substatement.tc"
  
  # 1 "substatement.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "substatement.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "substatement.tc"
  #pragma pack(pop)
  # 1 "substatement.tc"
  
  # 1 "substatement.tc"
  result__ii
  # 1 "substatement.tc"
   f(void);
  
  # 2 "substatement.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "substatement.tc"
  typedef void __tc_arg__v; struct result__vi; typedef struct result__vi result__vi;
  # 2 "substatement.tc"
  #pragma pack(pop)
  # 2 "substatement.tc"
  
  # 2 "substatement.tc"
  result__vi
  # 2 "substatement.tc"
   g(void);
  
  # 3 "substatement.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; }; enum result__vi_tag { result__vi_Err, result__vi_Ok }; struct result__vi { enum result__vi_tag tag; union { struct { __tc_arg__i error ; } Err; } u; };
  # 3 "substatement.tc"
  #pragma pack(pop)
  # 3 "substatement.tc"
  
  # 3 "substatement.tc"
  result__ii
  # 3 "substatement.tc"
   h(int c) {
    int x = 0;
    if (c)
      
  # 6 "substatement.tc"
  {
  # 6 "substatement.tc"
  
  # 6 "substatement.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 6 "substatement.tc"
  x = 
  # 6 "substatement.tc"
  __tc_t0.u.Ok.value
  # 6 "substatement.tc"
  ;
    
  # 7 "substatement.tc"
  }
  # 7 "substatement.tc"
  else
    
  # 8 "substatement.tc"
  {
  # 8 "substatement.tc"
  again: 
  # 8 "substatement.tc"
  ; const struct result__vi __tc_t1 = g ( ) ; if (__tc_t1.tag != result__vi_Ok) { if (__tc_t1.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  # 8 "substatement.tc"
  
  # 8 "substatement.tc"
  
  # 8 "substatement.tc"
  
    
  # 9 "substatement.tc"
  }
  # 9 "substatement.tc"
  while (c--) 
  # 9 "substatement.tc"
  {
  # 9 "substatement.tc"
  
  # 9 "substatement.tc"
  const struct result__vi __tc_t2 = g ( ) ; if (__tc_t2.tag != result__vi_Ok) { if (__tc_t2.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t2.u.Err.error } }); }
  # 9 "substatement.tc"
  
  # 9 "substatement.tc"
  
  # 9 "substatement.tc"
  
    
  # 10 "substatement.tc"
  }
  # 10 "substatement.tc"
  return 
  # 10 "substatement.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 10 "substatement.tc"
  x
  # 10 "substatement.tc"
   } })
  # 10 "substatement.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

Where E is void, Err has no field, and the function returns the Err
without one. The Ok of the operand's type may be a result of its own.

  $ cat > void_error.tc <<'EOF'
  > result(int, void) f(void);
  > result(long, void) h(void) {
  >   long x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe void_error.tc
  # 1 "void_error.tc"
  
  # 1 "void_error.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "void_error.tc"
  typedef int __tc_arg__i; typedef void __tc_arg__v; struct result__iv; typedef struct result__iv result__iv;
  # 1 "void_error.tc"
  #pragma pack(pop)
  # 1 "void_error.tc"
  
  # 1 "void_error.tc"
  result__iv
  # 1 "void_error.tc"
   f(void);
  
  # 2 "void_error.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "void_error.tc"
  typedef long __tc_arg__l; struct result__lv; typedef struct result__lv result__lv;
  # 2 "<universe>" 3
  enum result__lv_tag { result__lv_Err, result__lv_Ok }; struct result__lv { enum result__lv_tag tag; union { struct { __tc_arg__l value ; } Ok; } u; }; enum result__iv_tag { result__iv_Err, result__iv_Ok }; struct result__iv { enum result__iv_tag tag; union { struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "void_error.tc"
  #pragma pack(pop)
  # 2 "void_error.tc"
  
  # 2 "void_error.tc"
  result__lv
  # 2 "void_error.tc"
   h(void) {
    
  # 3 "void_error.tc"
  const struct result__iv __tc_t0 = f ( ) ; if (__tc_t0.tag != result__iv_Ok) { if (__tc_t0.tag != result__iv_Err) __builtin_trap(); return ((struct result__lv){ .tag = result__lv_Err }); }
  # 3 "void_error.tc"
  long x = 
  # 3 "void_error.tc"
  __tc_t0.u.Ok.value
  # 3 "void_error.tc"
  ;
    return 
  # 4 "void_error.tc"
  ((struct result__lv){ .tag = result__lv_Ok, .u.Ok = { 
  # 4 "void_error.tc"
  x
  # 4 "void_error.tc"
   } })
  # 4 "void_error.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > nested.tc <<'EOF'
  > result(result(int, char), int) f(void);
  > result(char, int) h(void) {
  >   result(int, char) inner = try f();
  >   match (inner) {
  >   case Ok(v):
  >     return Ok((char)v);
  >   case Err(e):
  >     return Ok(e);
  >   }
  > }
  > EOF
  $ ./golden.exe nested.tc
  # 1 "nested.tc"
  
  # 1 "nested.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "nested.tc"
  typedef int __tc_arg__i; typedef char __tc_arg__c; struct result__ic; typedef struct result__ic result__ic; struct result__ic; typedef struct result__ic __tc_arg__I6resulticE; struct result__I6resulticEi; typedef struct result__I6resulticEi result__I6resulticEi;
  # 1 "nested.tc"
  #pragma pack(pop)
  # 1 "nested.tc"
  
  # 1 "nested.tc"
  result__I6resulticEi
  # 1 "nested.tc"
   f(void);
  
  # 2 "nested.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "nested.tc"
  struct result__ci; typedef struct result__ci result__ci;
  # 2 "<universe>" 3
  enum result__ci_tag { result__ci_Err, result__ci_Ok }; struct result__ci { enum result__ci_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__c value ; } Ok; } u; }; enum result__ic_tag { result__ic_Err, result__ic_Ok }; struct result__ic { enum result__ic_tag tag; union { struct { __tc_arg__c error ; } Err; struct { __tc_arg__i value ; } Ok; } u; }; enum result__I6resulticEi_tag { result__I6resulticEi_Err, result__I6resulticEi_Ok }; struct result__I6resulticEi { enum result__I6resulticEi_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__I6resulticE value ; } Ok; } u; };
  # 2 "nested.tc"
  #pragma pack(pop)
  # 2 "nested.tc"
  
  # 2 "nested.tc"
  result__ci
  # 2 "nested.tc"
   h(void) {
    
  # 3 "nested.tc"
  const struct result__I6resulticEi __tc_t0 = f ( ) ; if (__tc_t0.tag != result__I6resulticEi_Ok) { if (__tc_t0.tag != result__I6resulticEi_Err) __builtin_trap(); return ((struct result__ci){ .tag = result__ci_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "nested.tc"
  
  # 3 "nested.tc"
  result__ic
  # 3 "nested.tc"
   inner = 
  # 3 "nested.tc"
  __tc_t0.u.Ok.value
  # 3 "nested.tc"
  ;
    
  # 4 "nested.tc"
  { const struct result__ic *const __tc_match = &(
  # 4 "nested.tc"
  inner
  # 4 "nested.tc"
  ); switch (__tc_match->tag) {
  # 4 "nested.tc"
  
    
  # 5 "nested.tc"
  case result__ic_Ok: { const __typeof__(__tc_match->u.Ok.value) v = __tc_match->u.Ok.value; {
  # 5 "nested.tc"
  
      return 
  # 6 "nested.tc"
  ((struct result__ci){ .tag = result__ci_Ok, .u.Ok = { 
  # 6 "nested.tc"
  (char)v
  # 6 "nested.tc"
   } })
  # 6 "nested.tc"
  ;
    
  # 7 "nested.tc"
   } __builtin_trap(); }
  # 7 "nested.tc"
  
  # 7 "nested.tc"
  case result__ic_Err: { const __typeof__(__tc_match->u.Err.error) e = __tc_match->u.Err.error; {
  # 7 "nested.tc"
  
      return 
  # 8 "nested.tc"
  ((struct result__ci){ .tag = result__ci_Ok, .u.Ok = { 
  # 8 "nested.tc"
  e
  # 8 "nested.tc"
   } })
  # 8 "nested.tc"
  ;
    
  # 9 "nested.tc"
   } __builtin_trap(); }
  # 9 "nested.tc"
  
  # 9 "nested.tc"
  default: __builtin_trap(); } }
  # 9 "nested.tc"
  
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

The operand is moved text with its own lowering: a constructor and the
name of an instance in it move with it.

  $ cat > moved.tc <<'EOF'
  > result(int, int) f(option(int) o, const void *p);
  > result(int, int) h(const void *p) {
  >   int x = try f(Some(1), (const option(long) *)p);
  >   int y = try f(None, p);
  >   return Ok(x + y);
  > }
  > EOF
  $ ./golden.exe moved.tc
  # 1 "moved.tc"
  
  # 1 "moved.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "moved.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii; struct option__i; typedef struct option__i option__i;
  # 1 "moved.tc"
  #pragma pack(pop)
  # 1 "moved.tc"
  
  # 1 "moved.tc"
  result__ii
  # 1 "moved.tc"
   f(
  # 1 "moved.tc"
  option__i
  # 1 "moved.tc"
   o, const void *p);
  
  # 2 "moved.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 1 "<universe>" 3
  enum option__i_tag { option__i_None, option__i_Some }; struct option__i { enum option__i_tag tag; union { struct { __tc_arg__i value ; } Some; } u; };
  # 3 "moved.tc"
  typedef long __tc_arg__l; struct option__l; typedef struct option__l option__l;
  # 2 "moved.tc"
  #pragma pack(pop)
  # 2 "moved.tc"
  
  # 2 "moved.tc"
  result__ii
  # 2 "moved.tc"
   h(const void *p) {
    
  # 3 "moved.tc"
  const struct result__ii __tc_t0 = f ( ((struct option__i){ .tag = option__i_Some, .u.Some = {  1  } }) , ( const option__l * ) p ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "moved.tc"
  int x = 
  # 3 "moved.tc"
  __tc_t0.u.Ok.value
  # 3 "moved.tc"
  ;
    
  # 4 "moved.tc"
  const struct result__ii __tc_t1 = f ( ((struct option__i){ .tag = option__i_None }) , p ) ; if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  # 4 "moved.tc"
  int y = 
  # 4 "moved.tc"
  __tc_t1.u.Ok.value
  # 4 "moved.tc"
  ;
    return 
  # 5 "moved.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 5 "moved.tc"
  x + y
  # 5 "moved.tc"
   } })
  # 5 "moved.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

The operand of try has a result type, and the function returns one with
the identical error type (rule 1); a top-level qualifier counts on
neither.

  $ cat > qualified.tc <<'EOF'
  > const result(int, int) r;
  > const result(long, int) h(void) {
  >   int x = try r;
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe qualified.tc
  # 1 "qualified.tc"
  
  # 1 "qualified.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "qualified.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 1 "qualified.tc"
  #pragma pack(pop)
  # 1 "qualified.tc"
  const 
  # 1 "qualified.tc"
  result__ii
  # 1 "qualified.tc"
   r;
  
  # 2 "qualified.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "qualified.tc"
  typedef long __tc_arg__l; struct result__li; typedef struct result__li result__li;
  # 2 "<universe>" 3
  enum result__li_tag { result__li_Err, result__li_Ok }; struct result__li { enum result__li_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__l value ; } Ok; } u; };
  # 2 "qualified.tc"
  #pragma pack(pop)
  # 2 "qualified.tc"
  const 
  # 2 "qualified.tc"
  result__li
  # 2 "qualified.tc"
   h(void) {
    
  # 3 "qualified.tc"
  const struct result__ii __tc_t0 = r ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__li){ .tag = result__li_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "qualified.tc"
  int x = 
  # 3 "qualified.tc"
  __tc_t0.u.Ok.value
  # 3 "qualified.tc"
  ;
    return 
  # 4 "qualified.tc"
  ((struct result__li){ .tag = result__li_Ok, .u.Ok = { 
  # 4 "qualified.tc"
  x
  # 4 "qualified.tc"
   } })
  # 4 "qualified.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > operand.tc <<'EOF'
  > result(int, int) h(void) {
  >   int x = try 1;
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe operand.tc
  operand.tc:2: the operand of try is of no result type (design 5.1 rule 1) [TC0051]
  [1]

  $ cat > return_type.tc <<'EOF'
  > result(int, int) f(void);
  > int h(void) {
  >   int x = try f();
  >   return x;
  > }
  > EOF
  $ ./golden.exe return_type.tc
  return_type.tc:3: try stands in a function that returns no result type (design 5.1 rule 1) [TC0051]
  [1]

  $ cat > error_type.tc <<'EOF'
  > result(int, const char *) f(void);
  > result(int, char *) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe error_type.tc
  error_type.tc:3: the error type of the operand of try is not the one that the function returns; no error type converts to another (design 5.1 rule 1) [TC0052]
  [1]

  $ cat > void_error_type.tc <<'EOF'
  > result(int, const void) f(void);
  > result(int, void) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe void_error_type.tc
  void_error_type.tc:3: the error type of the operand of try is not the one that the function returns; no error type converts to another (design 5.1 rule 1) [TC0052]
  [1]

Only the statement try e; holds a void value (rule 2).

  $ cat > void_value.tc <<'EOF'
  > result(void, int) g(void);
  > result(int, int) h(void) {
  >   int x;
  >   x = try g();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe void_value.tc
  void_value.tc:4: the value of try is void, which only the statement try e; discards (design 5.1 rule 2) [TC0053]
  [1]

Anywhere else a try is one error.

  $ cat > compound.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = 0;
  >   x += try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe compound.tc
  compound.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > chained.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x, y;
  >   x = y = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe chained.tc
  chained.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > parenthesised.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x;
  >   x = (try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe parenthesised.tc
  parenthesised.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > parenthesised_assignment.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x;
  >   (x = try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe parenthesised_assignment.tc
  parenthesised_assignment.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > comma.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x, y = 0;
  >   x = try f(), y;
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe comma.tc
  comma.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > operand_of_operator.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = 1;
  >   x = x + try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe operand_of_operator.tc
  operand_of_operator.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > argument.tc <<'EOF'
  > result(int, int) f(void);
  > int k(int);
  > result(int, int) h(void) {
  >   int x = k(try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe argument.tc
  argument.tc:4: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > condition.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   if (try f())
  >     return Ok(1);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe condition.tc
  condition.tc:3: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > return.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   return Ok(try f());
  > }
  > EOF
  $ ./golden.exe return.tc
  return.tc:3: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > for_clause.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   for (int i = try f(); i < 3; i++)
  >     ;
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe for_clause.tc
  for_clause.tc:3: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > statement_expression.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = ({ int y = try f(); y; });
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe statement_expression.tc
  statement_expression.tc:3: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > declarators.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = 0, y = try f();
  >   return Ok(x + y);
  > }
  > EOF
  $ ./golden.exe declarators.tc
  declarators.tc:3: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > file_scope.tc <<'EOF'
  > result(int, int) f(void);
  > int x = try f();
  > EOF
  $ ./golden.exe file_scope.tc
  file_scope.tc:2: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

A declaration that holds a try declares an automatic object, whose type
is not variably modified.

  $ cat > static.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   static int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe static.tc
  static.tc:3: a declaration that holds try declares an object of static or thread storage duration (design 5.1 rule 3) [TC0055]
  [1]

  $ cat > variably_modified.tc <<'EOF'
  > result(int (*)[3], int) f(void);
  > result(int, int) h(int n) {
  >   int (*p)[n] = try f();
  >   return Ok((*p)[0]);
  > }
  > EOF
  $ ./golden.exe variably_modified.tc
  variably_modified.tc:3: a declaration that holds try declares an object of a variably modified type, whose size C evaluates before its initialiser (design 5.1 rule 3) [TC0055]
  [1]

try e; where T is a result drops the inner result (design 5.2).

  $ cat > dropped.tc <<'EOF'
  > result(result(int, int), int) f(void);
  > result(int, int) h(void) {
  >   try f();
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe dropped.tc
  dropped.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

No pragma line stands in the statement or declaration that holds a try,
or directly before it, its labels included; a null statement after a
pragma takes the next statement out.

  $ cat > pragma_before.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  > #pragma GCC diagnostic push
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe pragma_before.tc
  pragma_before.tc:4: a pragma line stands in or directly before the statement or declaration that holds try; give the pragma or the try a statement of its own (design 5.1 rule 3) [TC0056]
  [1]

  $ cat > pragma_before_label.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x;
  > #pragma GCC diagnostic push
  >   again: x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe pragma_before_label.tc
  pragma_before_label.tc:5: a pragma line stands in or directly before the statement or declaration that holds try; give the pragma or the try a statement of its own (design 5.1 rule 3) [TC0056]
  [1]

  $ cat > pragma_inside.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = try
  > #pragma GCC diagnostic push
  >     f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe pragma_inside.tc
  pragma_inside.tc:3: a pragma line stands in or directly before the statement or declaration that holds try; give the pragma or the try a statement of its own (design 5.1 rule 3) [TC0056]
  [1]

  $ cat > pragma_then_null.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  > #pragma GCC diagnostic push
  >   ;
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe pragma_then_null.tc
  # 1 "pragma_then_null.tc"
  
  # 1 "pragma_then_null.tc"
  #pragma pack(push)
  #pragma pack()
  # 1 "pragma_then_null.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 1 "pragma_then_null.tc"
  #pragma pack(pop)
  # 1 "pragma_then_null.tc"
  
  # 1 "pragma_then_null.tc"
  result__ii
  # 1 "pragma_then_null.tc"
   f(void);
  
  # 2 "pragma_then_null.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 2 "pragma_then_null.tc"
  #pragma pack(pop)
  # 2 "pragma_then_null.tc"
  
  # 2 "pragma_then_null.tc"
  result__ii
  # 2 "pragma_then_null.tc"
   h(void) {
  #pragma GCC diagnostic push
    ;
    
  # 5 "pragma_then_null.tc"
  const struct result__ii __tc_t0 = f ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 5 "pragma_then_null.tc"
  int x = 
  # 5 "pragma_then_null.tc"
  __tc_t0.u.Ok.value
  # 5 "pragma_then_null.tc"
  ;
    return 
  # 6 "pragma_then_null.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 6 "pragma_then_null.tc"
  x
  # 6 "pragma_then_null.tc"
   } })
  # 6 "pragma_then_null.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

The operand of a try is moved text (rule 3): lowering writes it before
the statement or declaration that holds the try, where it reads as at
its own place (design 13.5). A declarator is in scope in its own
initialiser, so the operand would name another object there, or none.

  $ cat > own_declarator.tc <<'EOF'
  > result(int, int) rd(int *);
  > result(int, int) h(void) {
  >   int n = 0;
  >   {
  >     int n = try rd(&n);
  >     return Ok(n);
  >   }
  > }
  > EOF
  $ ./golden.exe own_declarator.tc
  own_declarator.tc:5: 'n' denotes another entity where lowering writes the text, the one declared at own_declarator.tc:3 (design 5.1 rule 3, 13.5) [TC0061]
  [1]

  $ cat > undeclared_there.tc <<'EOF'
  > result(int, int) rd(int *);
  > result(int, int) h(void) {
  >   int n = try rd(&n);
  >   return Ok(n);
  > }
  > EOF
  $ ./golden.exe undeclared_there.tc
  undeclared_there.tc:3: 'n' is not visible where lowering writes the text (design 5.1 rule 3, 13.5) [TC0061]
  [1]

The left operand of an assignment is read before the try, so the
operand names nothing that it declares, and the operand declares
nothing in the scope around it that the left operand would read.

  $ cat > left_declares.tc <<'EOF'
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   int a[8];
  >   a[sizeof(enum { K = 5 })] = try g(K);
  >   return Ok(a[0]);
  > }
  > EOF
  $ ./golden.exe left_declares.tc
  left_declares.tc:4: 'K' is not visible where lowering writes the text (design 5.1 rule 3, 13.5) [TC0061]
  [1]

  $ cat > operand_declares.tc <<'EOF'
  > enum { K = 1 };
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   int a[8];
  >   a[K] = try g(sizeof(enum { K = 5 }));
  >   return Ok(a[1]);
  > }
  > EOF
  $ ./golden.exe operand_declares.tc
  operand_declares.tc:5: 'K' is declared in the scope around the text, which lowering writes elsewhere, so the text after it would lose the declaration; declare it before the text (design 5.1 rule 3, 13.5) [TC0061]
  [1]

A tag declared before the holder and completed in it before the try is
incomplete where lowering writes the operand, whether the operand names
the tag or reads a member through a pointer to it.

  $ cat > completed_named.tc <<'EOF'
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   struct S;
  >   int a[32];
  >   a[sizeof(struct S { int x; })] = try g(sizeof(struct S));
  >   return Ok(a[0]);
  > }
  > EOF
  $ ./golden.exe completed_named.tc
  completed_named.tc:5: the tag 'S' is completed at completed_named.tc:5, between a place where lowering writes the text and the text, so it is incomplete there (design 5.1 rule 3, 13.5) [TC0061]
  [1]

  $ cat > completed_unnamed.tc <<'EOF'
  > result(int, int) g(int);
  > result(int, int) h(void *v) {
  >   struct S;
  >   struct S *p = v;
  >   int a[32];
  >   a[sizeof(struct S { int x; })] = try g(p->x);
  >   return Ok(a[0]);
  > }
  > EOF
  $ ./golden.exe completed_unnamed.tc
  completed_unnamed.tc:6: the tag 'S' is completed at completed_unnamed.tc:6, between a place where lowering writes the text and the text, so it is incomplete there (design 5.1 rule 3, 13.5) [TC0061]
  [1]

An object declared again with an attribute in the holder before the try,
in a block of its own, has another alignment where lowering writes the
operand on GCC, which changes the object in place.

  $ cat > redeclared_in_block.tc <<'EOF'
  > extern int o;
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   int a[32];
  >   a[({ extern int o __attribute__((aligned(16))); 0; })] =
  >     try g(__alignof__(o));
  >   return Ok(a[0]);
  > }
  > EOF
  $ ./golden.exe redeclared_in_block.tc
  redeclared_in_block.tc:6: the declaration of 'o' at redeclared_in_block.tc:5, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses (design 5.1 rule 3, 13.5) [TC0061]
  [1]

A tag that the holder declares anew, in a block of its own, is none
that the place declares, so completing it there changes nothing for the
operand.

  $ cat > completed_inner.tc <<'EOF'
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   struct S;
  >   int a[32];
  >   a[({ struct S { int x; } s = { 1 }; s.x; })] = try g(2);
  >   return Ok(a[0]);
  > }
  > EOF
  $ ./golden.exe completed_inner.tc > /dev/null

A name that is declared before the holder reads alike at both places,
also one declared with an attribute, and so does a name whose scope
ends inside the operand.

  $ cat > reads_alike.tc <<'EOF'
  > typedef int wide __attribute__((aligned(16)));
  > result(int, int) g(int);
  > result(int, int) h(int n) {
  >   int x = try g((wide)n + ({ int y = 1; y; }));
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe reads_alike.tc
  # 1 "reads_alike.tc"
  typedef int wide __attribute__((aligned(16)));
  
  # 2 "reads_alike.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "reads_alike.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 2 "reads_alike.tc"
  #pragma pack(pop)
  # 2 "reads_alike.tc"
  
  # 2 "reads_alike.tc"
  result__ii
  # 2 "reads_alike.tc"
   g(int);
  
  # 3 "reads_alike.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 3 "reads_alike.tc"
  #pragma pack(pop)
  # 3 "reads_alike.tc"
  
  # 3 "reads_alike.tc"
  result__ii
  # 3 "reads_alike.tc"
   h(int n) {
    
  # 4 "reads_alike.tc"
  const struct result__ii __tc_t0 = g ( ( wide ) n + ( { int y = 1 ; y ; } ) ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 4 "reads_alike.tc"
  int x = 
  # 4 "reads_alike.tc"
  __tc_t0.u.Ok.value
  # 4 "reads_alike.tc"
  ;
    return 
  # 5 "reads_alike.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 5 "reads_alike.tc"
  x
  # 5 "reads_alike.tc"
   } })
  # 5 "reads_alike.tc"
  ;
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");
