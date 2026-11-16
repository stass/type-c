SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A try stands in three positions (design 5.1 rule 3): the whole of an
expression statement, the whole right operand of a simple assignment
that is one, and the whole initialiser of the one declarator of a
declaration that is a block item. Each is typed and, until lowering
writes it, refused there.

  $ cat > statement.tc <<'EOF'
  > result(void, int) g(void);
  > result(int, int) h(void) {
  >   try g();
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe statement.tc
  statement.tc:3: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

  $ cat > assignment.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x;
  >   x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe assignment.tc
  assignment.tc:4: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

  $ cat > declaration.tc <<'EOF'
  > result(int, int) f(void);
  > result(int, int) h(void) {
  >   int x = try f();
  >   return Ok(x);
  > }
  > EOF
  $ ./golden.exe declaration.tc
  declaration.tc:3: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

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
  labelled.tc:6: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

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
  arm.tc:5: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

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
  qualified.tc:3: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]

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
  pragma_then_null.tc:5: lowering of `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]
