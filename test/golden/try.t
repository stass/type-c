SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A try stands in the expression of its holder (design 5.1 rule 3): an
expression statement, a block-item declaration of one declarator, a
return, the controlling expression of an if or a switch, the scrutinee
of a match and the operand of a test of an if. Lowering writes its
prelude before the holder, a temporary that holds the operand and its
test for each try, and the Ok field where the try stood (design 13.5).
The error path traps on a tag that is neither Ok nor Err, and returns
the Err built from the temporary. A try whose value is discarded, as in
the statement try e;, reads no field and leaves ((void)0); a void T has
no Ok field, and a void E no Err field, so the Err is built without
one.

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
  struct result__vi __tc_t0 = ( g ( ) ); if (__tc_t0.tag != result__vi_Ok) { if (__tc_t0.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "statement.tc"
  
  # 3 "statement.tc"
  ((void)0)
  # 3 "statement.tc"
  ;
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
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "discarded.tc"
  
  # 3 "discarded.tc"
  ((void)0)
  # 3 "discarded.tc"
  ;
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
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  ; struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  { const struct result__ii *const __tc_match0 = &(
  # 3 "arm.tc"
  r
  # 3 "arm.tc"
  ); switch (__tc_match0->tag) {
  # 3 "arm.tc"
  
    
  # 4 "arm.tc"
  case result__ii_Ok: { const __typeof__(__tc_match0->u.Ok.value) v = __tc_match0->u.Ok.value; {
  # 4 "arm.tc"
  
      
  # 5 "arm.tc"
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
    
  # 6 "arm.tc"
   } __builtin_trap(); }
  # 7 "arm.tc"
  
  # 7 "arm.tc"
  case result__ii_Err: {
  # 7 "arm.tc"
  
      return r;
    
  # 8 "arm.tc"
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
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 6 "substatement.tc"
  x = 
  # 6 "substatement.tc"
  __tc_t0.u.Ok.value
  # 6 "substatement.tc"
  ;
    
  # 6 "substatement.tc"
  }
  # 7 "substatement.tc"
  else
    
  # 8 "substatement.tc"
  {
  # 8 "substatement.tc"
  again: 
  # 8 "substatement.tc"
  ; struct result__vi __tc_t1 = ( g ( ) ); if (__tc_t1.tag != result__vi_Ok) { if (__tc_t1.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  # 8 "substatement.tc"
  
  # 8 "substatement.tc"
  ((void)0)
  # 8 "substatement.tc"
  ;
    
  # 8 "substatement.tc"
  }
  # 9 "substatement.tc"
  while (c--) 
  # 9 "substatement.tc"
  {
  # 9 "substatement.tc"
  
  # 9 "substatement.tc"
  struct result__vi __tc_t2 = ( g ( ) ); if (__tc_t2.tag != result__vi_Ok) { if (__tc_t2.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t2.u.Err.error } }); }
  # 9 "substatement.tc"
  
  # 9 "substatement.tc"
  ((void)0)
  # 9 "substatement.tc"
  ;
    
  # 9 "substatement.tc"
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
  struct result__iv __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__iv_Ok) { if (__tc_t0.tag != result__iv_Err) __builtin_trap(); return ((struct result__lv){ .tag = result__lv_Err }); }
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
  struct result__I6resulticEi __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__I6resulticEi_Ok) { if (__tc_t0.tag != result__I6resulticEi_Err) __builtin_trap(); return ((struct result__ci){ .tag = result__ci_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  { const struct result__ic *const __tc_match0 = &(
  # 4 "nested.tc"
  inner
  # 4 "nested.tc"
  ); switch (__tc_match0->tag) {
  # 4 "nested.tc"
  
    
  # 5 "nested.tc"
  case result__ic_Ok: { const __typeof__(__tc_match0->u.Ok.value) v = __tc_match0->u.Ok.value; {
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
    
  # 6 "nested.tc"
   } __builtin_trap(); }
  # 7 "nested.tc"
  
  # 7 "nested.tc"
  case result__ic_Err: { const __typeof__(__tc_match0->u.Err.error) e = __tc_match0->u.Err.error; {
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
    
  # 8 "nested.tc"
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
  struct result__ii __tc_t0 = ( f ( ((struct option__i){ .tag = option__i_Some, .u.Some = {  1  } }) , ( const option__l * ) p ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 3 "moved.tc"
  int x = 
  # 3 "moved.tc"
  __tc_t0.u.Ok.value
  # 3 "moved.tc"
  ;
    
  # 4 "moved.tc"
  struct result__ii __tc_t1 = ( f ( ((struct option__i){ .tag = option__i_None }) , p ) ); if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
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
  struct result__ii __tc_t0 = ( r ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__li){ .tag = result__li_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  operand.tc:2: error: the operand of try is of no result type [try-operand]
  [1]

  $ cat > return_type.tc <<'EOF'
  > result(int, int) f(void);
  > int h(void) {
  >   int x = try f();
  >   return x;
  > }
  > EOF
  $ ./golden.exe return_type.tc
  return_type.tc:3: error: try stands in a function that returns no result type [try-operand]
  [1]

  $ cat > error_type.tc <<'EOF'
  > result(int, const char *) f(void);
  > result(int, char *) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe error_type.tc
  error_type.tc:3: error: the error type of the operand of try is not the one that the function returns; no error type converts to another [try-error-type]
  [1]

  $ cat > void_error_type.tc <<'EOF'
  > result(int, const void) f(void);
  > result(int, void) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe void_error_type.tc
  void_error_type.tc:3: error: the error type of the operand of try is not the one that the function returns; no error type converts to another [try-error-type]
  [1]

A try of a void T stands only where its value is discarded or cast to
void (rule 2).

  $ cat > void_value.tc <<'EOF'
  > result(void, int) g(void);
  > result(int, int) h(void) {
  >   int x;
  >   x = try g();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe void_value.tc
  void_value.tc:4: error: the value of try is void, which stands only where a value is discarded or cast to void [try-void]
  [1]

A try stands under any operator of C that evaluates its operand as a
value, and its prelude evaluates the tries of the holder first, in the
order of the source, one inside another's operand first. The holder
reads each where it stood.

  $ cat > compound.tc <<'EOF'
  > result(int, int) f(void);
  > int k(int);
  > result(int, int) h(void) {
  >   int x = 0, y = 0;
  >   x += k(try f()) + try f(), y;
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe compound.tc | grep -v '^#'
  
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  
  result__ii
   f(void);
  int k(int);
  
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  
  result__ii
   h(void) {
    int x = 0, y = 0;
    
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); } struct result__ii __tc_t1 = ( f ( ) ); if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  x += k(
  __tc_t0.u.Ok.value
  ) + 
  __tc_t1.u.Ok.value
  , y;
    return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  x
   } })
  ;
  }
  
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

  $ cat > nested.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   if (try g(try f()))
  >     return Ok(1);
  >   return Ok(try f());
  > }
  > EOF
  $ ./golden.exe nested.tc | grep -v '^#'
  
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  
  result__ii
   f(void);
  
  result__ii
   g(int);
  
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  
  result__ii
   h(void) {
    
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); } struct result__ii __tc_t1 = ( g ( __tc_t0.u.Ok.value ) ); if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  if (
  __tc_t1.u.Ok.value
  )
      return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  1
   } })
  ;
    
  struct result__ii __tc_t2 = ( f ( ) ); if (__tc_t2.tag != result__ii_Ok) { if (__tc_t2.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t2.u.Err.error } }); }
  return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  
  __tc_t2.u.Ok.value
  
   } })
  ;
  }
  
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

The first operand of &&, || and ?:, and the left operand of a comma,
whose other operand holds a try, is evaluated with the tries, once, and
the try under an if on its truth (design 13.5).

  $ cat > conditions.tc <<'EOF'
  > typedef struct q q;
  > result(int, int) check(q *);
  > result(int, int) f(void);
  > result(int, int) h2(void);
  > void use(q *);
  > void g(void);
  > result(int, int) h(q *p, int c) {
  >   int x;
  >   if (p && try check(p) > 0)
  >     use(p);
  >   x = c ? try f() : (g(), try h2());
  >   x = try f() || (x && try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe conditions.tc | grep -v '^#'
  typedef struct q q;
  
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  
  result__ii
   check(q *);
  
  result__ii
   f(void);
  
  result__ii
   h2(void);
  void use(q *);
  void g(void);
  
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  
  result__ii
   h(q *p, int c) {
    int x;
    
  const int __tc_c0 = ( p ) ? 1 : 0; struct result__ii __tc_t0 = { 0 }; if (__tc_c0) { __tc_t0 = ( check ( p ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); } }
  if (
  __tc_c0
   && 
  __tc_t0.u.Ok.value
   > 0)
      use(p);
    
  const int __tc_c1 = ( c ) ? 1 : 0; struct result__ii __tc_t1 = { 0 }; struct result__ii __tc_t2 = { 0 }; if (__tc_c1) { __tc_t1 = ( f ( ) ); if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); } } else { (void)( g ( ) ); __tc_t2 = ( h2 ( ) ); if (__tc_t2.tag != result__ii_Ok) { if (__tc_t2.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t2.u.Err.error } }); } }
  x = 
  __tc_c1
   ? 
  __tc_t1.u.Ok.value
   : (
  (void)0
  , 
  __tc_t2.u.Ok.value
  );
    
  struct result__ii __tc_t3 = ( f ( ) ); if (__tc_t3.tag != result__ii_Ok) { if (__tc_t3.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t3.u.Err.error } }); } const int __tc_c2 = ( __tc_t3.u.Ok.value ) ? 1 : 0; int __tc_c3 = 0; struct result__ii __tc_t4 = { 0 }; if (!__tc_c2) { __tc_c3 = ( x ) ? 1 : 0; if (__tc_c3) { __tc_t4 = ( f ( ) ); if (__tc_t4.tag != result__ii_Ok) { if (__tc_t4.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t4.u.Err.error } }); } } }
  x = 
  __tc_c2
   || (
  __tc_c3
   && 
  __tc_t4.u.Ok.value
  );
    return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  x
   } })
  ;
  }
  
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A try of a void T stands where its value is discarded: the holder
reads nothing of it.

  $ cat > discarded.tc <<'EOF'
  > result(void, int) v(void);
  > result(void, int) w(void);
  > result(int, int) h(int c) {
  >   int n = 0;
  >   try v(), n++;
  >   c ? try v() : try w();
  >   (void)try v();
  >   return Ok(n);
  > }
  > EOF
  $ ./golden.exe discarded.tc | grep -v '^#'
  
  typedef void __tc_arg__v; typedef int __tc_arg__i; struct result__vi; typedef struct result__vi result__vi;
  
  result__vi
   v(void);
  
  result__vi
   w(void);
  
  struct result__ii; typedef struct result__ii result__ii;
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; }; enum result__vi_tag { result__vi_Err, result__vi_Ok }; struct result__vi { enum result__vi_tag tag; union { struct { __tc_arg__i error ; } Err; } u; };
  
  result__ii
   h(int c) {
    int n = 0;
    
  struct result__vi __tc_t0 = ( v ( ) ); if (__tc_t0.tag != result__vi_Ok) { if (__tc_t0.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  
  ((void)0)
  , n++;
    
  const int __tc_c0 = ( c ) ? 1 : 0; if (__tc_c0) { struct result__vi __tc_t1 = ( v ( ) ); if (__tc_t1.tag != result__vi_Ok) { if (__tc_t1.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); } } else { struct result__vi __tc_t2 = ( w ( ) ); if (__tc_t2.tag != result__vi_Ok) { if (__tc_t2.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t2.u.Err.error } }); } }
  
  __tc_c0
   ? 
  ((void)0)
   : 
  ((void)0)
  ;
    
  struct result__vi __tc_t3 = ( v ( ) ); if (__tc_t3.tag != result__vi_Ok) { if (__tc_t3.tag != result__vi_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t3.u.Err.error } }); }
  (void)
  ((void)0)
  ;
    return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  n
   } })
  ;
  }
  
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A try that is an initialiser of a braced list is a whole initialiser.

  $ cat > list.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int a[2] = { try f(), (try f()) };
  >   return Ok(a[1]);
  > }
  > EOF
  $ ./golden.exe list.tc | grep -v '^#'
  
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  
  result__ii
   f(void);
  
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  
  result__ii
   h(void) {
    
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); } struct result__ii __tc_t1 = ( f ( ) ); if (__tc_t1.tag != result__ii_Ok) { if (__tc_t1.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t1.u.Err.error } }); }
  int a[2] = { 
  __tc_t0.u.Ok.value
  , (
  __tc_t1.u.Ok.value
  ) };
    return 
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  a[1]
   } })
  ;
  }
  
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A try that initialises an object of another arithmetic type in a
braced list has its value converted in the prelude, after its test
(design 5.1 rule 3, 13.5): a temporary __tc_v of the object's type in
keywords takes it, an enumerated type as its compatible integer type
and a bit-field as its declared type, where braces are elided too. A
try of the object's own type, d below and the int of list.tc above,
and one whose value is no arithmetic type, keep the read of the Ok
field. Under a condition the temporary is declared before the if and
assigned in it.

  $ cat > list_conversion.tc <<'EOF'
  > result(double, int) f(void);
  > struct t { int n; };
  > result(struct t, int) k(void);
  > enum e { A, B };
  > struct s { float x; enum e k; unsigned b : 3; _Bool t; double d; };
  > struct p { float x; float y; };
  > result(int, int) h(int c) {
  >   float a[2] = { try f(), (try f()) };
  >   struct s v = { try f(), try f(), try f(), try f(), try f() };
  >   struct p ps[1] = { try f(), { try f() } };
  >   struct t w[1] = { try k() };
  >   int x = { try f() };
  >   int y = c ? (int[]){ try f() }[0] : 0;
  >   return Ok(x + y + (int)a[0] + (int)v.x + (int)ps[0].y + w[0].n);
  > }
  > EOF
  $ ./golden.exe list_conversion.tc | sed -n '/h(int c)/,$p' | tr ';' '\n' \
  >   | grep -E '__tc_v|^ *__tc_t[0-9]+\.u\.Ok|= \{ *$|\? \(int' \
  >   | sed 's/^[ }]*//'
  const float __tc_v0 = __tc_t0.u.Ok.value
  const float __tc_v1 = __tc_t1.u.Ok.value
  float a[2] = { 
  __tc_v0
  __tc_v1
  const float __tc_v2 = __tc_t2.u.Ok.value
  const unsigned int __tc_v3 = __tc_t3.u.Ok.value
  const unsigned int __tc_v4 = __tc_t4.u.Ok.value
  const _Bool __tc_v5 = __tc_t5.u.Ok.value
  struct s v = { 
  __tc_v2
  __tc_v3
  __tc_v4
  __tc_v5
  __tc_t6.u.Ok.value
  const float __tc_v7 = __tc_t7.u.Ok.value
  const float __tc_v8 = __tc_t8.u.Ok.value
  struct p ps[1] = { 
  __tc_v7
  __tc_v8
  struct t w[1] = { 
  __tc_t9.u.Ok.value
  const int __tc_v10 = __tc_t10.u.Ok.value
  int x = { 
  __tc_v10
  int __tc_v11 = 0
  __tc_v11 = __tc_t11.u.Ok.value
  ? (int[]){ 
  __tc_v11
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 

The type that the value converts to is one that typec computes (design
5.1 rule 5): neither an enumerated type whose integer type an attribute
that typec does not type decides, nor the type of an object that
follows a position or a member that typec does not compute. A try of no
arithmetic type there converts nothing and stands.

  $ cat > list_unknown.tc <<'EOF'
  > result(double, int) f(void);
  > result(int, int) h(void) {
  >   enum __attribute__((packed)) e { D };
  >   enum e z[1] = { try f() };
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe list_unknown.tc
  list_unknown.tc:4: error: the type that a braced list converts the value of try to depends on the attribute 'packed' at list_unknown.tc:3, which typec does not type yet [unsupported]
  [1]
  $ cat > list_unplaced.tc <<'EOF'
  > result(double, int) f(void);
  > result(int, int) h(void) {
  >   float a[4] = { [sizeof(_Float16)] = 0, try f() };
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe list_unplaced.tc
  list_unplaced.tc:3: error: the type of the object that try initialises in a braced list, which its value converts to, depends on a position or a type that typec does not compute; give the try a declaration of its own [unsupported]
  [1]
  $ cat > list_unknown_member.tc <<'EOF'
  > result(double, int) f(void);
  > result(int, int) h(void) {
  >   struct q { float x; _Float16 h; } v = { 0, try f() };
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe list_unknown_member.tc
  list_unknown_member.tc:3: error: the type of the object that try initialises in a braced list, which its value converts to, depends on a position or a type that typec does not compute; give the try a declaration of its own [unsupported]
  [1]
  $ cat > list_unplaced_record.tc <<'EOF'
  > struct t { int n; };
  > result(struct t, int) k(void);
  > result(int, int) h(void) {
  >   struct t v[2] = { [sizeof(_Float16)] = { 0 }, try k() };
  >   return Ok(v[1].n);
  > }
  > EOF
  $ ./golden.exe list_unplaced_record.tc | grep -c '__tc_t0.u.Ok.value'
  1

An initialiser of a list that holds a try and is no try itself is an
error (try-list).

  $ cat > list_part.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int a[2] = { 0, try f() + 1 };
  >   return Ok(a[1]);
  > }
  > EOF
  $ ./golden.exe list_part.tc
  list_part.tc:3: error: an initialiser of a braced list that holds try is itself a try expression; give the rest of it a declaration of its own [try-list]
  [1]

A hoisted operand holds no object whose life lowering would end before
the source does (design 5.1 rule 3, try-lifetime). A compound literal
lives until its block ends, and one in a hoisted operand that is
evaluated under a condition would end its life with the if of the
prelude, before consume reads it.

  $ cat > lifetime.h <<'EOF'
  > struct s { int a[2]; };
  > struct s make(void);
  > struct msg { int kind; };
  > void consume(int *p);
  > result(int *, int) wrap(int *p);
  > result(struct s, int) made(void);
  > result(int, int) send(struct msg *m);
  > result(int, int) read_value(int *p);
  > EOF
  $ cat lifetime.h - > literal_conditioned.tc <<'EOF'
  > result(int, int) h(int c) {
  >   consume(c ? try wrap((int[]){7}) : 0);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe literal_conditioned.tc
  literal_conditioned.tc:10: error: a compound literal in an operand that the prelude of try evaluates under a condition would end its life with the if of the prelude; give it a declaration before the holder [try-lifetime]
  [1]
  $ cat lifetime.h - > literal_and.tc <<'EOF'
  > result(int, int) h(int c) {
  >   c && try read_value(((struct s){{1}}).a);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe literal_and.tc
  literal_and.tc:10: error: a compound literal in an operand that the prelude of try evaluates under a condition would end its life with the if of the prelude; give it a declaration before the holder [try-lifetime]
  [1]

Under no condition a hoisted operand is written in the block of its
holder, where a compound literal lives as long as in the source, and so
does one under a condition inside the operand.

  $ cat lifetime.h - > literal.tc <<'EOF'
  > result(int, int) h(int c) {
  >   consume(try wrap((int[]){7}));
  >   try send(&(struct msg){ .kind = 1 });
  >   consume(try wrap(c ? (int[]){7} : 0));
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe literal.tc | grep -o '__tc_t[0-9] = ( [^;]* );'
  __tc_t0 = ( wrap ( ( int [ ] ) { 7 } ) );
  __tc_t1 = ( send ( & ( struct msg ) { . kind = 1 } ) );
  __tc_t2 = ( wrap ( c ? ( int [ ] ) { 7 } : 0 ) );

An array member of a value that is no lvalue lives in a temporary
object until its full expression ends, and a hoisted operand is a full
expression of its own, under a condition or not.

  $ cat lifetime.h - > array_value.tc <<'EOF'
  > result(int, int) h(void) {
  >   consume(try wrap(make().a));
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe array_value.tc
  array_value.tc:10: error: an array member of a value that is no lvalue, in an operand that the prelude of try evaluates, would end its life with that operand; give the value a declaration before the holder [try-lifetime]
  [1]
  $ cat lifetime.h - > array_comma.tc <<'EOF'
  > result(int, int) h(void) {
  >   int *p;
  >   (p = make().a, try read_value(p));
  >   return Ok(*p);
  > }
  > EOF
  $ ./golden.exe array_comma.tc
  array_comma.tc:11: error: an array member of a value that is no lvalue, in an operand that the prelude of try evaluates, would end its life with that operand; give the value a declaration before the holder [try-lifetime]
  [1]
  $ cat lifetime.h - > array_conditioned.tc <<'EOF'
  > result(int, int) h(int c) {
  >   consume(c ? try wrap(make().a) : 0);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe array_conditioned.tc
  array_conditioned.tc:10: error: an array member of a value that is no lvalue, in an operand that the prelude of try evaluates, would end its life with that operand; give the value a declaration before the holder [try-lifetime]
  [1]

The array of a declared object stands, and so does an array member of
the value of a try, which the prelude holds in an object of the
holder's block.

  $ cat lifetime.h - > array_object.tc <<'EOF'
  > result(int, int) h(void) {
  >   struct s m = make();
  >   consume(try wrap(m.a));
  >   consume(try wrap((try made()).a));
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe array_object.tc | grep -o '__tc_t[0-9] = ( [^;]* );'
  __tc_t0 = ( wrap ( m . a ) );
  __tc_t1 = ( made ( ) );
  __tc_t2 = ( wrap ( ( __tc_t1.u.Ok.value ) . a ) );

Whether a member of a value that is no lvalue is an array is a question
that a type typec does not compute cannot answer (design 5.1 rule 5).

  $ cat > member_unknown.tc <<'EOF'
  > struct o { _Float16 h; };
  > struct o odd(void);
  > result(int, int) take(_Float16 h);
  > result(int, int) h(void) {
  >   try take(odd().h);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe member_unknown.tc
  member_unknown.tc:5: error: whether a member of a value that is no lvalue, in an operand that the prelude of try evaluates, is an array depends on '_Float16' at member_unknown.tc:1, which typec does not type yet [unsupported]
  [1]

The value of a try is no lvalue (try-lvalue).

  $ cat > lvalue.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int *p = &(try f());
  >   return Ok(*p);
  > }
  > EOF
  $ ./golden.exe lvalue.tc
  lvalue.tc:3: error: the value of try is no lvalue, which the operand of &, ++ or -- and the left operand of an assignment are; give it an object of its own [try-lvalue]
  [1]

A loop evaluates its condition once for each iteration (try-loop).

  $ cat > loop.tc <<'EOF'
  > result(int, int) more(void);
  > result(int, int) h(void) {
  >   while (try more())
  >     ;
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe loop.tc
  loop.tc:3: error: a loop evaluates its condition and the clauses of a for once for each iteration, and the tries of a holder once before it; hold the try in the body [try-loop]
  [1]

What C does not evaluate as a value takes no try (try-position): the
operand of sizeof, a builtin that inspects its argument, and the last
operand of ?: without its second.

  $ cat > sizeof.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = sizeof(try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe sizeof.tc
  sizeof.tc:3: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]

  $ cat > inspected.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = __builtin_constant_p(try f());
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe inspected.tc
  inspected.tc:3: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]

  $ cat > omitted.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(int c) {
  >   int x = c ?: try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe omitted.tc
  omitted.tc:3: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]

Nor do the clauses of a for, a statement expression, a declaration of
more than one declarator, or file scope.

  $ cat > for_clause.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   for (int i = try f(); i < 3; i++)
  >     ;
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe for_clause.tc
  for_clause.tc:3: error: a loop evaluates its condition and the clauses of a for once for each iteration, and the tries of a holder once before it; hold the try in the body [try-loop]
  [1]

  $ cat > statement_expression.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = ({ int y = try f(); y; });
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe statement_expression.tc
  statement_expression.tc:3: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]

  $ cat > declarators.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = 0, y = try f();
  >   return Ok(x + y);
  > }
  > EOF
  $ ./golden.exe declarators.tc
  declarators.tc:3: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]

  $ cat > file_scope.tc <<'EOF'
  > result(int, int) f(void);
  > int x = try f();
  > EOF
  $ ./golden.exe file_scope.tc
  file_scope.tc:2: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
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
  static.tc:3: error: a declaration that holds try declares an object of static or thread storage duration [try-declaration]
  [1]

  $ cat > variably_modified.tc <<'EOF'
  > result(int (*)[3], int) f(void);
  > result(int, int) h(int n) {
  >   int (*p)[n] = try f();
  >   return Ok((*p)[0]);
  > }
  > EOF
  $ ./golden.exe variably_modified.tc
  variably_modified.tc:3: error: a declaration that holds try declares an object of a variably modified type, whose size C evaluates before its initialiser [try-declaration]
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
  dropped.tc:3: error: a value of a result type is discarded; handle it with try or match, store it, or cast it to void [discarded-result]
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
  pragma_before.tc:4: error: a pragma line stands in or directly before the holder of try; give the pragma or the try a statement of its own [try-pragma]
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
  pragma_before_label.tc:5: error: a pragma line stands in or directly before the holder of try; give the pragma or the try a statement of its own [try-pragma]
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
  pragma_inside.tc:3: error: a pragma line stands in or directly before the holder of try; give the pragma or the try a statement of its own [try-pragma]
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
  struct result__ii __tc_t0 = ( f ( ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
  own_declarator.tc:5: error: 'n' denotes another entity where lowering writes the text, the one declared at own_declarator.tc:3 [try-name-capture]
  [1]

  $ cat > undeclared_there.tc <<'EOF'
  > result(int, int) rd(int *);
  > result(int, int) h(void) {
  >   int n = try rd(&n);
  >   return Ok(n);
  > }
  > EOF
  $ ./golden.exe undeclared_there.tc
  undeclared_there.tc:3: error: 'n' is not visible where lowering writes the text [try-name-capture]
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
  left_declares.tc:4: error: 'K' is not visible where lowering writes the text [try-name-capture]
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
  operand_declares.tc:5: error: 'K' is declared in the scope around the text, which lowering writes elsewhere or in a block of its own, so the text after it would lose the declaration; declare it before the text [try-name-capture]
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
  completed_named.tc:5: error: the tag 'S' is completed at completed_named.tc:5, between a place where lowering writes the text and the text, so it is incomplete there [try-name-capture]
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
  completed_unnamed.tc:6: error: the tag 'S' is completed at completed_unnamed.tc:6, between a place where lowering writes the text and the text, so it is incomplete there [try-name-capture]
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
  redeclared_in_block.tc:6: error: the declaration of 'o' at redeclared_in_block.tc:5, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses [try-name-capture]
  [1]

An operand that declares an object or a function with linkage, in a
block of its own, declares an entity that the text around it sees:
written before the holder, an attribute there changes the object for
the holder on GCC, so the operand declares none (design 13.5).

  $ cat > declares_linked.tc <<'EOF'
  > extern int o;
  > result(int, int) h(result(int, int) r) {
  >   int a[32] = { 0 };
  >   a[__alignof__(o)] =
  >     try ({ extern int o __attribute__((aligned(16))); (void)o; r; });
  >   return Ok(a[4]);
  > }
  > EOF
  $ ./golden.exe declares_linked.tc
  declares_linked.tc:5: error: 'o' is declared with linkage in the text, which lowering writes elsewhere, so the declaration may change it for the text around it there; declare it outside the text [try-name-capture]
  [1]

  $ cat > declares_function.tc <<'EOF'
  > result(int, int) h(result(int, int) r) {
  >   int x = try ({ int f(void); r; });
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe declares_function.tc
  declares_function.tc:2: error: 'f' is declared with linkage in the text, which lowering writes elsewhere, so the declaration may change it for the text around it there; declare it outside the text [try-name-capture]
  [1]

So does one of internal linkage, while a block-scope static object has
no linkage and is the operand's own.

  $ cat > declares_internal.tc <<'EOF'
  > static int o;
  > result(int, int) h(result(int, int) r) {
  >   int x = try ({ extern int o; o = 1; r; });
  >   return Ok(x + o);
  > }
  > EOF
  $ ./golden.exe declares_internal.tc
  declares_internal.tc:3: error: 'o' is declared with linkage in the text, which lowering writes elsewhere, so the declaration may change it for the text around it there; declare it outside the text [try-name-capture]
  [1]

  $ cat > declares_static.tc <<'EOF'
  > result(int, int) h(result(int, int) r) {
  >   int x = try ({ static int n; n++; r; });
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe declares_static.tc > /dev/null

Typing reads no declaration in the arguments of an attribute, so the
operand holds no brace there, which could open one: here a statement
expression that GCC reads as declaring o aligned to 16 for the holder.

  $ cat > declares_unread.tc <<'EOF'
  > extern int o;
  > result(int, int) h(result(int, int) r) {
  >   int a[32] = { 0 };
  >   a[__alignof__(o)] =
  >     try ({ int z __attribute__((aligned(sizeof(({ extern int o
  >       __attribute__((aligned(16))); 1; }))))); (void)z; r; });
  >   return Ok(a[4]);
  > }
  > EOF
  $ ./golden.exe declares_unread.tc
  declares_unread.tc:5: error: a brace in the arguments of an attribute, which typing does not read, may declare a name that the text around it sees, and lowering writes the text elsewhere [try-name-capture]
  [1]

Nor a tag keyword there of a tag that is not visible, which would
declare the tag in front of the holder: here the two mentions of
struct q in the holder would name one type.

  $ cat > declares_unread_tag.tc <<'EOF'
  > result(int, int) g(int);
  > result(int, int) h(void) {
  >   int a[4] = { 0 };
  >   a[_Generic((void (*)(struct q *))0,
  >       void (*)(struct q *): 1, default: 2)] =
  >     try g(sizeof(int __attribute__((aligned(sizeof(struct q *))))));
  >   return Ok(a[2]);
  > }
  > EOF
  $ ./golden.exe declares_unread_tag.tc
  declares_unread_tag.tc:6: error: a tag keyword that names no visible tag in the arguments of an attribute, which typing does not read, may declare a name that the text around it sees, and lowering writes the text elsewhere [try-name-capture]
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
  struct result__ii __tc_t0 = ( g ( ( wide ) n + ( { int y = 1 ; y ; } ) ) ); if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap(); return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
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
