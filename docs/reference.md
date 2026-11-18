<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/reference.t checks the examples of this file on Clang and GCC:
test/run/readme.sh says how the blocks are marked. All files share one
directory, so each example has a name of its own.
-->

# Type-C language reference

This page states the rules of Type-C: what each construct that Type-C
adds to C means, where it may stand, and what is an error. It is brief
and does not argue; the reasons are in the
[language design](../type-c-language-design.md), which is the source
of truth and holds the rules in full, translation limits included. The [tutorial](tutorial.md) introduces the
same constructs by example, and [typec(1)](typec.1) describes the
compiler's command line.

"C11" is ISO/IEC 9899:2011, and a citation such as C11 6.5.16.1p1 is its
clause and paragraph. Everything this page does not change is C11, in
the dialect of [1.2](#12-c11-and-the-dialect). Text in *italics* in a
syntax line is a placeholder. A rule that ends in a bracketed name, such
as [match-coverage], is reported by `typec` with that name at the end of
the message. The C that `typec` writes is described only where a
program or a C client can observe it: names, sizes, layout and calling
convention.

The tests of [`test/run/reference.t`](../test/run/reference.t) compile
every valid example of this page with Clang and GCC under
`-Wall -Wextra -Werror`, run the programs, and compare the messages
shown, those of the examples that are errors included.

## Contents

1. [Source text](#1-source-text)
2. [Type declarations](#2-type-declarations)
3. [Matching](#3-matching)
4. [`option` and `result`](#4-option-and-result)
5. [`try`](#5-try)
6. [`defer`](#6-defer)
7. [Generic functions](#7-generic-functions)
8. [Slices and `str`](#8-slices-and-str)
9. [Interfaces and privacy](#9-interfaces-and-privacy)
10. [C clients and headers](#10-c-clients-and-headers)
11. [Checks and the trap](#11-checks-and-the-trap)
12. [Checked mode](#12-checked-mode)
13. [The driver](#13-the-driver)

## 1. Source text

### 1.1 Files

| Suffix | Content |
| --- | --- |
| `.c`, `.h` | C. A `.c` file is passed to the C compiler unchanged; a `.h` file is included as C. |
| `.tc` | Type-C source: one translation unit, compiled by `typec`. |
| `.tci` | Type-C interface: a header in Type-C, pulled in by `#include` ([9](#9-interfaces-and-privacy)). |

Text from a `.tc` or `.tci` file is *Type-C text*; text from any other
file, such as a `.h` that a `.tc` file includes, is *C text*. The
grammar is the same for both, except that `try` and `defer` are words
of Type-C text only ([1.3](#13-words)), and that Type-C text cannot
open a variant as the structure it becomes ([2.2](#22-variants)). A
`.tc` file may include `.h` and `.tci` files in any mix.

While it preprocesses a Type-C translation unit, `typec` defines the
macro `__TYPEC__` as `1`.

### 1.2 C11 and the dialect

Every C11 translation unit is a Type-C translation unit with the same
meaning, with one exception: Type-C text may not use a universe name
([1.3](#13-words)) as a parameter in the identifier list of an
old-style definition, where C11 6.9.1p6 makes a typedef name an error.

Type-C text checks every conversion as if by assignment against the
constraints of C11 6.5.16.1p1, and refuses those that GNU C accepts with
a warning, such as a pointer conversion that differs in the signedness
of the pointee or drops a qualifier, and an integer converted to a
pointer. Such C needs a cast before it compiles as Type-C. Of the GNU
extensions, the conversion between `void *` and a pointer to a
function, in either direction, is kept; conversions of the types that
`typec` leaves to the C compiler, such as vector types, are the C
compiler's.

Type-C sees the tokens after preprocessing: a macro may expand to any
Type-C construct, whole or in part, and a token belongs to the file that
was being read when it was produced. `#pragma typec` lines belong to
`typec` ([12](#12-checked-mode)); every other pragma passes through.

The dialect is C11 or C17, in ISO or GNU form, with the GNU and Clang
extensions that system headers rely on. A translation unit with Type-C
text accepts only `-std=` `c11`, `c17`, `gnu11` or `gnu17` (and their
synonyms), and is compiled as `-std=gnu17` without one.

### 1.3 Words

Type-C adds no reserved word. Its words are of three kinds.

**Hidden words.** In Type-C text, `try` is the operator of
[5](#5-try) and `defer` the statement of [6](#6-defer) wherever no
declaration of an ordinary identifier of that spelling is in scope. A
declaration of `try` or `defer` (a function, object, parameter, typedef
or enumerator, in Type-C or C text) hides the word under C's scope rules
(C11 6.2.1): inside that scope it is the identifier. A tag, a member or
a label may be named `try` or `defer` anywhere. In C text both are
ordinary identifiers. `_Defer` is a keyword in all text and always
means `defer`.

**Positional words.** `type`, `match`, `generic`, `unsafe`, `private`
and `distinct` are ordinary identifiers that have a Type-C meaning only
where they begin a Type-C construct:

| Word | Construct |
| --- | --- |
| `type` | `type` *identifier*, beginning a declaration ([2](#2-type-declarations)) |
| `match` | `match (` *expression* `) {`, beginning a statement ([3.1](#31-match)) |
| `generic` | `generic (` ... `)`, beginning a file-scope declaration ([7](#7-generic-functions)) |
| `unsafe` | `unsafe {`, beginning a statement ([12](#12-checked-mode)) |
| `private` | after the `=` of a type declaration, before `\|` or `distinct` ([9](#9-interfaces-and-privacy)) |
| `distinct` | after the `=` (or `private`) of a type declaration, before a type name ([2.4](#24-distinct-types)) |

A variable, function or field may have any of these names. Where `type`
or `generic` is visible as a typedef name, `type x;` and
`generic (x);` are C declarations and the Type-C construct is not
available in that scope.

**Universe names.** `option`, `result`, `slice`, `str`,
`slice_from_array`, `slice_sub` and `slice_unchecked` are declared in a
*universe scope* that encloses file scope. A declaration of the same
identifier hides the universe name under C's scope rules, so
`int result = 0;` is valid. In a parameter declaration that could read
an identifier either as a type name or as the parameter's name, a
universe name is the parameter's name, unlike a typedef name under C11
6.7.6.3p11: `int f(int (str));` declares an `int` parameter `str`, as in
C. No generic type or generic function has a universe name
[generic-universe-name].

**Reserved names.** An identifier that begins with `__tc_` is an error
anywhere in a Type-C translation unit, C text included
[generated-name].

<!-- file: words.tc -->
```c
int
words(void)
{
	int type = 1, match = 2, generic = 3, distinct = 4;
	int result = type + match + generic + distinct;

	return (result);
}
```

```console
$ typec -Wall -Wextra -Werror -c words.tc
```

## 2. Type declarations

### 2.1 Forms and names

```text
type name;                                  incomplete variant
type name = | C1(fields) | C2 ...;          variant (2.2)
type name = distinct type-name;             distinct type (2.4)
type name = type-name;                      alias, as a typedef
type name(T1, ..., Tn) = ...;               generic type (2.5)
```

1. A type declaration may stand at file scope or in a block, but not in
   the first clause of a `for` or among the parameter declarations of an
   old-style definition. A generic type is declared at file scope only
   [generic-scope].
2. The name is an ordinary identifier, as a typedef name is, and is in
   scope from the end of its identifier. Within its own definition the
   type is incomplete, so a variant, or a definition that is a structure
   or union specifier, refers to itself only through a pointer
   [field-type]. No other definition uses its own name
   [self-reference].
3. A name is defined once in a scope; unlike a typedef, a type
   declaration is never repeated [type-redeclaration]. `type name;`
   declares an incomplete variant, which a definition in the same scope
   completes once, with the same number of type parameters
   [completion-parameter-count].
4. The name contains no `__`, does not end in `_`, and does not begin
   with `_` and an uppercase letter; at file scope it does not begin
   with `_` (C11 7.1.3p1) [reserved-type-name].

### 2.2 Variants

A variant is a closed set of *constructors*, each with zero or more
named *fields*. A value holds one constructor and its fields.

```text
type name = | C1 | C2(type field, ...) | ...;
```

1. The leading `|` is required. A constructor without fields is written
   without parentheses.
2. Constructor names are unique within the variant and do not enter the
   ordinary name space [duplicate-constructor]. A constructor is not
   named `try`, `defer` or a universe name, contains no `__`, and does
   not begin with `_`; a field does not have a name that C reserves for
   any use (C11 7.1.3p1) [reserved-constructor].
3. Fields are declared as parameters are. A field's type is a complete
   object type that is not qualified, atomic, an array, `va_list` or
   variably modified, and holds no `const` member or flexible array
   member at any depth; a field is not a bit-field [field-type]. Wrap
   an array in a structure.
4. A variant is a value: it is copied whole by initialisation,
   assignment, argument passing and `return`, and the copy is shallow.
   Making one allocates nothing.
5. Type-C text reaches the tag and fields only through
   [matching](#3-matching). A variant may be copied, and may be the
   operand of `sizeof`, `_Alignof`, unary `&`, parentheses, the second
   and third operands of `?:`, `,`, an expression statement, a cast to
   `void` and `_Generic`. Member access, `offsetof`, `==`, a cast to or
   from a variant type, every operator that takes a scalar and a
   variant as the condition of `if`, `while`, `do`, `for` or `?:` are
   errors [variant-operation]; the message suggests the
   [single-pattern test](#3-matching) or the binding that replaces the
   C idiom.
6. The zero value of a variant is its first constructor with every field
   zero: an object of static storage duration, `{0}`, `{}` and the bytes
   that `calloc` and `memset` zero all hold it (C11 6.7.9p10, p21). `{0}` and
   `{}` are the only braced initialisers of a variant
   [variant-initializer]. An automatic variant without an initialiser
   is indeterminate.

The C that a variant `name` becomes is a structure `struct name`, with
a typedef `name`, holding a tag of type `enum name_tag` with an
enumerator `name_C` for each constructor `C`, numbered from 0 in
declaration order, and a union `u` with a member `C`, a structure of the
fields in order, for each constructor that has fields. The tag has the
size of `int`. The layout is what the C compiler gives this structure;
bytes outside the tag and the active constructor's fields are
unspecified, so copying a variant to an untrusted destination can
disclose stale memory, as with any C structure that has padding.
Reordering or removing constructors changes the ABI. The declaration
claims the tag names `name` and `name_tag` and the enumerators `name_C`
in its scope, nested blocks and prototypes included (C11 6.2.1p4):
declaring one of them otherwise there is an error, and Type-C text does
not name them [claimed-name]. An alias of a structure or union without
a tag, as `type point = struct { int x, y; };`, claims its name as the
tag in the same way.

### 2.3 Constructor expressions

```text
C                 a constructor without fields
C(e1, ..., en)    a constructor with n fields
T.C               qualified by the variant type T
```

1. A constructor expression is an rvalue of the variant type. Each
   argument converts to its field's type as if by assignment, and the
   arguments are evaluated in an unspecified order. `C()` is an error
   [constructor-expression]; a constructor has no address.
2. `T.C`, where `T` is a typedef name or a type application such as
   `option(int)`, names the constructor `C` of `T` wherever an
   expression may stand.
3. An unqualified `C` names a constructor only where the *target type*
   is a variant that has a constructor `C`; there it is the constructor
   even when an ordinary identifier `C` is visible. The target type is:
   - the type of the object or sub-object, for its initialiser;
   - the type of the left operand, for the right operand of `=`;
   - the function's return type, for the operand of `return`;
   - the parameter's type, for an argument of a call with a prototype;
   - the field's type, for an argument of a constructor;
   - the enclosing expression's target type, for a parenthesised
     expression, the second and third operands of `?:` and the right
     operand of `,`.

   No other position has a target type, not even the operand of `try`:
   there the name is looked up as in C, and `T.C` names the constructor.
   A visible typedef name `C` stays a type name where C's grammar can
   begin a type name, as after the `(` of `return (C(1));` or as the
   first argument of a generic function ([7.2](#72-calls)): write `T.C`
   there.
4. A constructor expression is valid only in the scope of its variant's
   declaration [constructor-scope].

<!-- file: shapes.tc -->
```c
type shape =
    | Empty
    | Circle(double r)
    | Rect(double w, double h);

type drawing = | Blank | One(shape s) | Two(shape a, shape b);

shape
unit_square(void)
{
	return (Rect(1, 1));
}

drawing
sketch(void)
{
	shape c = shape.Circle(0.5);
	shape none = {0};			/* Empty */

	(void)none;
	return (Two(c, unit_square()));
}
```

```console
$ typec -Wall -Wextra -Werror -c shapes.tc
```

### 2.4 Distinct types

```text
type D = distinct U;
```

A distinct type `D` has the size, alignment and representation of `U`,
an unqualified arithmetic or pointer type [distinct-base], and is
compatible with no other type: not with `U`, and not with another
distinct type over `U`.

| Operation on a `D` | Rule |
| --- | --- |
| Initialisation, assignment, argument, `return` | The value has type `D`. |
| Cast `(D)e` | Valid where `(U)e` is. |
| Cast `(T)d` | Valid where a cast from `U` to `T` is. |
| `==`, `!=` | Both operands have type `D`. |
| Truth value: `if`, loops, `!`, `&&`, `\|\|`, first operand of `?:` | Compared with zero, as `U`. |
| `?:` with both results `D`, `,`, `sizeof`, `_Alignof`, unary `&` | As in C. |
| `{0}`, `{}` | The zero of `U`. |
| Bit-field | Allowed where one of type `U` is. |

A cast is the only conversion between `D` and any other type; an
implicit conversion is an error [distinct-conversion]. Every other
operation is an error [distinct-operation]: arithmetic, the relational
operators, `++` and `--`, compound assignment, unary `*`, `->`, `[]`, a
call, `switch`, and an argument passed through `...` or to a function
without a prototype. `D` is written `const D` to qualify it; `distinct
const U` is an error. The C that `D` becomes is `typedef U D;`, so a C
client sees `U`.

<!-- file: ports.tc -->
```c
#include <stdint.h>

type port = distinct uint16_t;
type seconds = distinct uint16_t;

port
next_port(port p)
{
	return ((port)((uint16_t)p + 1));
}

int
same_port(port a, port b)
{
	return (a == b);
}
```

<!-- file: mixed.tc -->
```c
#include <stdint.h>

type port = distinct uint16_t;
type seconds = distinct uint16_t;

port
wrong(seconds s)
{
	return (s);
}
```

```console
$ typec -Wall -Wextra -Werror -c ports.tc
$ typec -c mixed.tc
mixed.tc:9: error: a value of type 'seconds' does not convert to 'port' without a cast [distinct-conversion]
[80]
```

### 2.5 Generic types

```text
type G(T1, ..., Tn) = definition;
G(A1, ..., An)                      an application
```

1. The definition is a variant, `distinct` over a type, or a type name.
   The bare name `G` is not a type; only an application is
   [generic-type-use].
2. The parameters are types. A type argument is an object type, complete
   or not, that is neither an array nor variably modified; a structure,
   union, enumeration, variant or distinct type in it is declared at
   file scope and has a tag or exactly one typedef name
   [type-argument] [type-argument-tag]. A type argument carries no
   attribute.
3. In the definition a parameter is used only as a type: of a member, a
   field, a pointee, an array element, a parameter or a result, or as a
   type argument. It does not follow `distinct`, is not the type of a
   bit-field, and no constant expression depends on it. A structure or
   union specifier with a body in the definition has no tag
   [generic-definition].
4. An application of a variant or distinct generic, or of one whose
   definition is a structure or union specifier with a body, is a type
   of its own, and two such applications are the same type exactly when
   their arguments are the same types, typedef names seen through. Any
   other generic is an alias, as a typedef is: with
   `type ptr(T) = T *;`, `ptr(int)` is `int *`.
5. `void` may be an argument. A variant field whose type becomes `void`
   is absent, so `Ok` of a `result(void, E)` has no field.
6. A generic refers to itself only through a pointer, as `list(T) *`.
   A chain of applications that each needs the next holds at most 64
   instances [instance-nesting].
7. The definition means the same at every application: a name in it
   that an application would see declared otherwise is an error at the
   application [generic-name-capture].

An application of a type of its own is a C structure named
`G__` followed by an encoding of the arguments: `vector(int)` is
`vector__i`, `pair(int, port)` is `pair__i4port`. A generic `G` claims
every name that begins with `G__`.

<!-- file: pairs.tc -->
```c
#include <stddef.h>

type pair(A, B) = struct { A first; B second; };
type list(T) = | Nil | Cons(T head, list(T) *tail);
type ptr(T) = T *;

double
second_of(pair(int, double) p)
{
	return (p.second);
}

int
sum(list(int) l)
{
	int total = 0;

	while (case Cons(head, tail) = l) {
		total += head;
		l = *tail;
	}
	return (total);
}

ptr(int)
first_item(int *items)
{
	return (items);
}
```

```console
$ typec -Wall -Wextra -Werror -c pairs.tc
```

## 3. Matching

### 3.1 `match`

```text
match ( expression ) {
case pattern:
	statements
case pattern:
case pattern:
	statements
default:
	statements
}
```

1. The scrutinee has a variant type; its qualifiers are ignored. A
   pointer is not followed: write `match (*e)` [match-scrutinee]. Only
   a variant is matched, not a C enumeration.
2. The body is a sequence of *arms*. An arm is one or more `case`
   *pattern* `:` or `default:` labels followed by at least one block
   item, and the labels stand directly in the body [match-arm-form]. A
   `case` or `default` label nested in a statement of the body is an
   error, unless it belongs to a `switch` or `match` nested there
   [stray-case-label].
3. An arm with several labels is one arm, not a fall-through, and none
   of its labels binds a field [shared-arm-binding].
4. Each arm is a block of its own. A declaration may follow a label
   directly.
5. The scrutinee is evaluated once. The fields that the selected label
   binds are copied before the arm runs, so assigning to the scrutinee
   in the arm does not change the bindings.
6. `match` is a statement and has no value.

### 3.2 Patterns and bindings

A pattern is an unqualified constructor with one sub-pattern for each of
its fields, in order; a constructor with fields is never written bare in
a `case` label, so the pattern of `Cons` is `Cons(_, _)` at least
[match-pattern]. The type of the field decides what its sub-pattern may
be:

| Field type | Sub-pattern |
| --- | --- |
| A variant | `_`; a constructor pattern `C` or `C(...)` of it; or `T x`, binding the field whole, where `T` denotes exactly the field's type |
| A pointer to a variant | `_`; `x`, binding the pointer; or `*P`, matching the pattern `P` against the pointee |
| Any other type | `_`, or `x`, binding the field |

1. `_` matches anything and binds nothing.
2. At a variant position a bare identifier is always a constructor, so a
   misspelt one is an error, never a binding. A binding of a pointer to
   a variant does not have the name of a constructor of the pointee's
   variant.
3. A binding is a non-modifiable object of the field's type, initialised
   with a copy of the field and scoped to its arm; assigning to it is an
   error, as for a `const` object (C11 6.5.16p2). The names a label
   binds are distinct, and an arm's own declarations may not redeclare
   them (C11 6.7p3), though a nested block may hide them.
4. `*P` follows the pointer, which must point to a valid object. Its
   pointee is not `volatile` or atomic.
5. There are no constants, alternatives or guards inside a pattern:
   write several labels on one arm, or an `if` in the arm.

When patterns nest, the first label in source order that matches selects
its arm, and `default` takes what no label matches. Tags are read lazily,
left to right, each at most once.

### 3.3 Coverage

1. Every value of the scrutinee is covered by a label or by `default`. A
   constructor, or with nesting a value, that no arm covers is an error
   that names it; so are a constructor named twice and a label that can
   never be selected [match-coverage].
2. There is at most one `default`, it covers at least one value, and it
   may stand anywhere among the arms [match-default].
3. A constructor added to the variant later is an error at every `match`
   that misses it, unless a `default`, a `_` or a typed binding covers
   it.

### 3.4 Leaving an arm

An arm does not fall through and has no implicit `break`.

1. The end of every arm, the last one included, is unreachable
   [match-arm-end]. Typically an arm ends in `break`, `return`,
   `continue` or `goto`, an `if` and `else` that both end so, an endless
   loop, or a call to a function declared `_Noreturn` (or with GNU's
   `noreturn` attribute) or to `__builtin_trap`, `__builtin_unreachable`
   or `__builtin_abort`. The analysis is syntactic and evaluates only
   constant conditions.
2. A `break` that is not inside a loop, `switch` or `match` nested in the
   arm leaves the `match`; `continue` goes on to the enclosing loop.
3. A `break` that leaves a `match` stands in tail position: the last item
   of the arm or of a block in tail position, either branch of an `if`
   in tail position, or within a labelled statement or `unsafe` block in
   tail position [early-break].
4. A label inside an arm is the target of a jump only from the same arm,
   and its address `&&L` is never taken [match-arm-entry].
5. In Type-C text, a `break` or `continue` in a statement expression in
   the condition of a loop or the third clause of a `for`, which no loop,
   `switch` or `match` inside the statement expression takes, is an
   error [ambiguous-jump].

`switch` keeps its C11 meaning.

### 3.5 Single-pattern test

```text
if (case pattern = expression) statement
if (case pattern = expression) statement else statement
while (case pattern = expression) statement
```

1. The test is the whole condition: it is not negated, parenthesised,
   joined by `&&` or `||`, or used in a `for` or `do`. The expression
   extends to the closing `)` and has a variant type
   [match-scrutinee].
2. Patterns are those of `match`, and only here may a constructor with
   fields be written bare, at any depth, to test the constructor alone:
   `if (case Num = *e)`.
3. The expression is evaluated once, by the `if` or before each
   iteration of the `while`. When the pattern matches, its bindings are
   copied and are in scope in the first statement only, not in the
   `else` statement or after.
4. The statements are not arms: they may complete, and `break` and
   `continue` keep their C meaning. A `break` that leaves an enclosing
   `match` obeys [3.4](#34-leaving-an-arm). The first statement is
   entered only by a successful test [match-arm-entry].
5. A test does not cover anything: a constructor added later makes it
   fail.

### 3.6 Invalid tags

A tag that is no constructor's, as an uninitialised automatic variant
can hold, traps ([11](#11-checks-and-the-trap)) when a `match`, a test
or a `try` reads it, even where a `default` is present. Only the tags
that selection reads are checked.

<!-- file: eval.tc -->
```c
#include <stdio.h>

type expr =
    | Num(long value)
    | Neg(expr *operand)
    | Add(expr *left, expr *right);

type maybe_expr = | Nothing | Just(expr e);

long
eval(const expr *e)
{
	match (*e) {
	case Num(v):
		return (v);
	case Neg(*Num(v)):
		return (-v);
	case Neg(operand):
		return (-eval(operand));
	case Add(left, right):
		return (eval(left) + eval(right));
	}
}

int
is_leaf(maybe_expr m)
{
	int leaf;

	match (m) {
	case Nothing:
	case Just(Num(_)):
		leaf = 1;
		break;
	default:
		leaf = 0;
		break;
	}
	return (leaf);
}

int
main(void)
{
	expr one = Num(1);
	expr two = expr.Num(2);
	expr sum = Add(&one, &two);
	expr neg = Neg(&sum);

	printf("%ld %d %d\n", eval(&neg), is_leaf(Just(one)),
	    is_leaf(Just(sum)));
	if (case Neg(*Add(_, right)) = neg)
		printf("%ld\n", eval(right));
	return (0);
}
```

<!-- file: arms.tc -->
```c
type token = | Number(long value) | Name(const char *text) | End;

long
value_of(token t)
{
	match (t) {
	case Number(v):
		return (v);
	case Name(_):
		break;
	}
	return (0);
}
```

```console
$ typec -Wall -Wextra -Werror -o eval eval.tc
$ ./eval
-3 1 0
2
$ typec -c arms.tc
arms.tc:6: error: the match does not cover the constructor 'End' of the variant 'token' [match-coverage]
[80]
```

## 4. `option` and `result`

Every Type-C translation unit has two generic variants in its universe
scope:

```text
type option(T) = | None | Some(T value);
type result(T, E) = | Err(E error) | Ok(T value);
```

1. They are variants ([2.2](#22-variants)): built with constructors and
   opened with [matching](#3-matching) or [`try`](#5-try). The zero
   value of an `option` is `None`, and that of a `result` is `Err` of a
   zero error.
2. `option(void)` and `result(void, E)` have a `Some` and an `Ok`
   without a field, and `result(T, void)` an `Err` without one
   ([2.5](#25-generic-types) rule 5).
3. A value of a variant type, these two included, converts to no other
   type (C11 6.5.16.1p1): `int n = f();`, where `f` returns a `result`,
   and `return 0;` in a function that returns one are errors. Write a
   constructor, `try` or `match`.
4. No cast converts to or from an `option`, a `result`, a slice or a
   `str`, a cast to its own type included (C11 6.5.4p2).
5. A value of a `result` type is not discarded:
   [5.2](#52-results-are-not-dropped).
6. One error type does not convert to another. To return the error of a
   callee as one of the caller's, match it and build the caller's.

<!-- file: lookup.tc -->
```c
#include <stddef.h>

type lookup_error = | NotFound | Ambiguous(size_t count);

option(size_t)
find(const int *items, size_t n, int wanted)
{
	for (size_t i = 0; i < n; i++)
		if (items[i] == wanted)
			return (Some(i));
	return (None);
}

result(size_t, lookup_error)
find_one(const int *items, size_t n, int wanted)
{
	size_t count = 0;

	for (size_t i = 0; i < n; i++)
		if (items[i] == wanted)
			count++;
	if (count > 1)
		return (Err(Ambiguous(count)));
	if (case Some(i) = find(items, n, wanted))
		return (Ok(i));
	return (Err(NotFound));
}

result(void, lookup_error)
require(const int *items, size_t n, int wanted)
{
	match (find_one(items, n, wanted)) {
	case Ok(_):
		return (Ok);
	case Err(lookup_error e):
		return (Err(e));
	}
}
```

```console
$ typec -Wall -Wextra -Werror -c lookup.tc
```

## 5. `try`

### 5.1 The operator

```text
try unary-expression
```

1. The operand has type `result(T, E)`, and the function that holds the
   `try` returns `result(U, E)` with the same `E`, qualifiers at every
   level of `E` included [try-operand] [try-error-type].
2. The operand is evaluated once. If it is `Err(x)`, the function
   returns `Err(x)` as a `return` statement would, running the active
   [deferred statements](#6-defer). If it is `Ok(v)`, the `try`
   expression has the value `v` and the type `T`; it is not an lvalue
   [try-lvalue]. If `T` is `void`, the `try` is a void expression
   [try-void].
3. `try` is a unary operator: `try f() + try g()` adds two values, and a
   conditional or assignment operand needs parentheses,
   `try (c ? f() : g())`. The operand of `try` has no target type, so a
   constructor there is written qualified ([2.3](#23-constructor-expressions)).
4. A `try` stands only in one of these *holders*: an expression
   statement; the initialiser of a block-scope declaration of one
   automatic object that is not variably modified; the operand of
   `return`; the controlling expression of an `if` or `switch`; the
   scrutinee of a `match`; and the expression of an `if` test
   [try-position]. In particular:
   - not in the condition of a `while` or `do`, or in a clause of a
     `for` [try-loop]: write `for (;;) { if (!try more()) break; ... }`;
   - not in the initialiser of a `static` or `_Thread_local` object or a
     variably modified one [try-declaration];
   - in a braced initialiser, only as a whole initialiser of an element
     or member [try-list];
   - not in a declaration of several declarators, a constant
     expression, the operand of `sizeof`, `_Alignof` or `_Generic`, a
     statement expression, or a deferred statement.

   The remedy in each case is a declaration of the `try` value of its
   own.
5. All the `try` expressions of a holder are evaluated first, in source
   order, each one whole, before the rest of the holder. The first
   operand of a `&&`, `||`, `?:` or `,` whose other operand holds a
   `try` is evaluated with it, in source order, and `&&`, `||` and `?:`
   still decide whether that `try` runs. When a `try` fails, only the
   earlier `try` expressions and those first operands have run: after
   `buf[len++] = try read_byte(r);` fails, `len` is unchanged. A `try`
   operand does not use a name that its holder declares
   [try-name-capture].

### 5.2 Results are not dropped

A value of a `result` type, through any typedef, alias or qualifier, is
not discarded: as an expression statement, the left operand of `,`, the
first or third clause of a `for`, the operand of `return` in a `void`
function, or a branch of a `void` conditional [discarded-result]. The
rule follows the position, so it holds through parentheses, the right
operand of `,` and a selected `_Generic` association, and also where
the expression is not evaluated, as in `sizeof (f(), 1)`. Handle the
value with `try` or `match`, store it, or cast it to `void`. The rule
holds in Type-C text.

<!-- file: digits.tc -->
```c
#include <stdio.h>

type digit_error = | Empty | NotDigit(char c);

result(int, digit_error)
digit(const char *s)
{
	if (*s == '\0')
		return (Err(Empty));
	if (*s < '0' || *s > '9')
		return (Err(NotDigit(*s)));
	return (Ok(*s - '0'));
}

result(int, digit_error)
two_digits(const char *s)
{
	int tens = try digit(s);
	int units = try digit(s + 1);

	return (Ok(tens * 10 + units));
}

result(void, digit_error)
check(const char *s)
{
	try two_digits(s);
	return (Ok);
}

int
main(void)
{
	if (case Ok(n) = two_digits("42"))
		printf("%d\n", n);
	if (case Err(NotDigit(c)) = check("4x"))
		printf("not a digit: %c\n", c);
	(void)check("");
	return (0);
}
```

<!-- file: dropped.tc -->
```c
type parse_error = | Bad;

result(int, parse_error) parse(const char *s);

void
skip(const char *s)
{
	parse(s);
}
```

```console
$ typec -Wall -Wextra -Werror -o digits digits.tc
$ ./digits
42
not a digit: x
$ typec -c dropped.tc
dropped.tc:8: error: a value of a result type is discarded; handle it with try or match, store it, or cast it to void [discarded-result]
[80]
```

## 6. `defer`

```text
defer statement
_Defer statement
```

`defer` follows ISO/DIS TS 25755. In C text it is spelt `_Defer`.

1. A `defer` statement is a block item of a compound statement or of a
   `match` arm, in a function body. It is not the substatement of an
   `if`, `else`, `switch` or loop, or of a labelled or `case` statement,
   and is not a block item of the compound statement of a statement
   expression [defer-position]. A deferred statement holds no `defer`
   [nested-defer].
2. The deferred statement runs each time control leaves the *scope* of
   the `defer`, which runs from the end of the `defer` statement to the
   end of the enclosing block: at the end of the block, by `return`,
   `break`, `continue` or `goto` out of it (a `goto` back to before the
   `defer` included), and by the error path of `try`.
3. When several scopes are left together, their statements run in the
   reverse order of their `defer` statements.
4. The deferred statement sees the values of variables when it runs. The
   operand of a `return` is evaluated and converted before the deferred
   statements run, so they cannot change the returned value.
5. A loop body and a `match` arm are blocks, so a `defer` in one runs on
   each iteration or for each arm.
6. `longjmp`, `exit`, `abort` and every other call that does not return
   leave without running deferred statements.
7. Control leaves a deferred statement only at its end: it is not left
   by `return`, `break` or `continue`, and holds no `goto`, computed
   `goto` or `asm goto` [deferred-exit]. A loop or `switch` inside it
   may use its own `break` and `continue`. It holds no `try`
   [try-position].
8. No jump enters a deferred statement, or the scope of a `defer` from
   outside that scope, and the address `&&L` of a label in such a scope
   is not taken [deferred-entry].
9. The scope of a `defer` holds no computed `goto` and no `asm goto`
   [defer-scope-jump], and, in C text too, the `break` or `continue`
   that [3.4](#34-leaving-an-arm) rule 5 refuses is refused in a
   deferred statement and in the scope of a `defer` [ambiguous-jump].
10. Each name in the deferred statement means at every exit what it
    means at the `defer` [defer-name-capture].
11. A deferred statement holds no identifier label and no definition of
    a `static` or `_Thread_local` object, and declares no type: no
    structure, union or enumeration specifier with a body or that
    declares its tag (C11 6.7.2.3p8), and no Type-C type
    [deferred-declaration]. A typedef of an existing type is allowed
    (C11 6.7.8p3).
12. Where the end of a block that holds a `defer` cannot be reached,
    reaching it traps ([11](#11-checks-and-the-trap)).

<!-- file: files.tc -->
```c
#include <stdio.h>

type io_error = | CannotOpen | CannotSeek;

result(long, io_error)
file_size(const char *path)
{
	FILE *f = fopen(path, "rb");

	if (f == NULL)
		return (Err(CannotOpen));
	defer fclose(f);
	if (fseek(f, 0, SEEK_END) != 0)
		return (Err(CannotSeek));
	return (Ok(ftell(f)));
}

int
main(void)
{
	for (int i = 0; i < 2; i++) {
		defer printf("end of %d\n", i);
		defer {
			printf("body of %d\n", i);
		}
		if (i == 1)
			break;
	}
	if (case Err(CannotOpen) = file_size("/nonexistent/file"))
		printf("cannot open\n");
	return (0);
}
```

<!-- file: leave.tc -->
```c
int
last(int *p)
{
	defer {
		return (*p);
	}
	return (0);
}
```

```console
$ typec -Wall -Wextra -Werror -o files files.tc
$ ./files
body of 0
end of 0
body of 1
end of 1
cannot open
$ typec -c leave.tc
leave.tc:5: error: `return` in the statement of a defer, which control leaves only at its end [deferred-exit]
[80]
```

## 7. Generic functions

### 7.1 Declaration

```text
generic(T1, ..., Tn)
declaration or definition of one function
```

1. `generic (...)` stands at file scope and introduces one function; each
   `Ti` is a type name for the rest of the declaration. The function's
   name obeys the rules of a type's name ([2.1](#21-forms-and-names)
   rule 4) [reserved-type-name]. The function has a prototype, `static`
   is its only storage class, the last named parameter before `...`
   does not have the type `Ti`, the head has no variably modified type,
   no assembler label and declares no tag, and `_Noreturn` and
   attributes stand only on the definition [generic-function-form].
2. A generic function may be declared many times, and is defined once;
   the declarations agree exactly [generic-function-agreement].
3. In the body, a `Ti` is an opaque value type. A value of type `Ti` may
   be declared, initialised from a `Ti` expression or the zero
   initialiser `{0}` or `{}`, assigned, passed to a prototyped
   parameter, returned, discarded, and be the operand of `,`, `&`,
   `sizeof`, `__alignof__` and `__typeof__`. A `Ti *` is a pointer as in
   C, and `Ti` may be used to derive types and as a type argument.
4. Every other operation on a `Ti` value is an error
   [type-parameter-operation]: arithmetic, comparison, conversion,
   member access, a call, a truth test, a cast other than to `void`, a
   cast to `Ti`, and an argument passed through `...` or to a function
   without a prototype.
5. `sizeof (Ti)` and the other values that depend on the layout of a
   `Ti` may be computed at run time, but are not constant expressions:
   not in a `case` label, an array bound, a bit-field width, a static
   initialiser, `_Static_assert` or `_Alignas` [type-parameter-constant].
6. There are no constraints on a type parameter. An operation that the
   body needs, such as a comparison or a hash, is passed in as a
   function pointer.

### 7.2 Calls

1. A call deduces the type arguments from the arguments, left to right.
   A parameter whose type parameters are all deduced takes its argument
   with C's implicit conversions; otherwise the argument's type matches
   the parameter's exactly, except that a pointer or slice parameter may
   add qualifiers to its element type. A `Ti` that occurs twice matches
   the same type both times [deduction-mismatch], and every `Ti` is
   deduced [undeduced-type-parameter].
2. `f(A1, ..., An)`, where `A1` begins with a type name, is an explicit
   instance: an ordinary function designator that may be called or have
   its address taken. It has one type argument for each type parameter
   [instance-arguments]. Every other use of the name
   of a generic function is an error [generic-function-use].
3. Type arguments are unqualified: with `T *first(T *p)`, `first(p)` on
   a `const int *` is refused; declare the parameter `const T *`.

### 7.3 Instances

1. Each instance that a translation unit uses is compiled in that unit,
   with internal linkage. Its address therefore differs between units,
   and each unit has its own `static` objects of the instance. An
   instance is not used in an `inline` definition with external linkage
   [instance-in-inline] (C11 6.7.4p3).
2. The definition precedes the first use of each instance, so a generic
   function shared by several units is defined in a header
   [generic-undefined].
3. A generic function leaves no C for a C client. To give one instance
   an external name, write an ordinary function that calls it.

<!-- file: swap.tc -->
```c
#include <stdlib.h>

type vector(T) = struct { T *data; size_t len; };

generic(T)
void
swap(T *a, T *b)
{
	T t = *a;

	*a = *b;
	*b = t;
}

generic(T)
T *
vector_last(vector(T) *v)
{
	if (v->len == 0)
		return (NULL);
	return (&v->data[v->len - 1]);
}

generic(T)
T *
new_array(size_t n)
{
	return (calloc(n, sizeof(T)));
}

int *
int_vector_last(vector(int) *v)
{
	return (vector_last(v));
}

int
demo(void)
{
	int x = 1, y = 2;
	int *(*last)(vector(int) *) = vector_last(int);
	double *d = new_array(double)(4);
	vector(int) v = { &x, 1 };

	swap(&x, &y);
	free(d);
	return (*last(&v) + *int_vector_last(&v));
}
```

<!-- file: less.tc -->
```c
generic(T)
int
less(T a, T b)
{
	return (a < b);
}
```

```console
$ typec -Wall -Wextra -Werror -c swap.tc
$ typec -c less.tc
less.tc:5: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
[80]
```

## 8. Slices and `str`

The universe scope declares a slice type and its string:

```text
type slice(T) = struct { T *data; size_t len; };
str             is slice(const char)
```

1. `s[i]` designates `s.data[i]` and is an lvalue. The index has an
   integer type no wider than `size_t` [slice-index]. Unless
   `(size_t)i < s.len`, it traps ([11](#11-checks-and-the-trap)),
   before any pointer arithmetic; `s` and `i` are each evaluated once.
   No option removes the check; `s.data[i]` is the unchecked access.
2. `slice_from_array(a)` is the slice of all of the array lvalue `a`, of
   type `T[N]`, with length `N`. It takes no pointer, no variable length
   array, no array of unknown bound and no string literal, even in
   parentheses or selected by `_Generic` [slice-operand]: a plain or
   UTF-8 one is a `str` instead (rule 6), and a wide one is sliced
   through an array that it initialises. An array of
   arrays is refused because an array is no type argument
   [type-argument]. The C compiler refuses an array of elements of
   size 0. The operand declares no tag,
   enumeration constant or label [array-operand-name-capture].
3. `slice_sub(s, lo, hi)` is the slice of the elements `lo` to `hi - 1`
   of `s`. `lo` and `hi` are indexes as in rule 1 [slice-index]. Unless
   `lo <= hi && hi <= s.len`, it traps; each operand is evaluated once.
4. `slice_unchecked(p, n)` is the slice of `n` elements at the pointer
   `p`, unchecked; `n` has an integer type no wider than `size_t`.
5. A `slice(T)` converts implicitly to `slice(const T)`, as if by
   assignment (C11 6.5.16.1) and in `?:` (C11 6.5.15p6). There is no
   other conversion between arrays, pointers and slices; `s.data` is the
   pointer.
6. A string literal, plain or UTF-8, whose target type is `str` is a
   `str` of its characters; its length does not count the terminating
   null character, which is still stored. A `str` promises no null
   character and no encoding.
7. A slice owns nothing. A slice of length 0 may have a null `data`.
   `data` and `len` are ordinary members.
8. An evaluated index, `slice_sub` or conversion of a slice stands in a
   function body [slice-check-place]; a string literal and
   `slice_from_array` may stand at file scope.
9. A full expression that holds an index, a `slice_sub` or a conversion
   of a slice has undefined behavior, and its check does not hold, when
   a call that returns twice, such as `setjmp` in a statement expression
   or `vfork`, returns again after the same call has begun that full
   expression once more.

A slice is the C structure `{ T *data; size_t len; }`, with its layout
and calling convention; `str` is `slice__Kc` to C.

<!-- file: slices.tc -->
```c
#include <stdio.h>

int
sum(slice(const int) xs)
{
	int total = 0;

	for (size_t i = 0; i < xs.len; i++)
		total += xs[i];
	return (total);
}

int
main(void)
{
	int a[4] = { 1, 2, 3, 4 };
	slice(int) all = slice_from_array(a);
	slice(int) middle = slice_sub(all, 1, 3);
	str hello = "hello";
	str abc = slice_unchecked("abcdef", 3);

	printf("%d %d %zu %.*s\n", sum(all), sum(middle), hello.len,
	    (int)abc.len, abc.data);
	return (0);
}
```

```console
$ typec -Wall -Wextra -Werror -o slices slices.tc
$ ./slices
10 5 5 abc
```

## 9. Interfaces and privacy

### 9.1 Interfaces

A `.tci` file is a header written in Type-C. It holds what a C header
holds, and also type declarations ([2](#2-type-declarations)) and
generic function definitions ([7](#7-generic-functions)), and
`#include` reads it as it reads any header. There is no module system
and no import statement.

1. Types and functions follow C's rules across translation units
   (C11 6.2.2, 6.2.7): a unit sees a declaration by including it, and
   units agree on a type by including one interface.
2. A type declaration is never repeated [type-redeclaration], so an
   interface that a unit may reach twice has an include guard.
3. A `.tc` file that includes its own interface has its definitions
   checked against the interface's declarations by C's rule for
   redeclarations (C11 6.7p4).
4. `type N;` in an interface, completed by the definition of the
   variant in the `.tc` file ([2.1](#21-forms-and-names)), hides the
   representation: in a unit that sees only the interface, `N` is an
   incomplete type (C11 6.2.5p1), which the unit holds through
   pointers and does not match on [match-scrutinee].
5. A generic function that an interface defines is compiled in each
   unit that uses it ([7.3](#73-instances)).

### 9.2 `private`

```text
type name = private | C1(fields) | C2 ...;
type name = private distinct type-name;
```

1. `private` restricts the creation of values to the *owner* of the
   type: for a variant, constructor expressions; for a distinct type,
   casts to it. Outside the owner, every such constructor expression or
   cast is refused, also one that creates no value, as `sizeof((D)1)`
   or the identity cast `(D)d` [private-creation]. Everything else
   stays open: a client matches on a private variant, reads its fields,
   and casts a private distinct value to another type.
2. The owner is the text of the file that holds the definition. When
   that file is `M.tci`, the owner is also the text of `M.tc`, if
   `M.tc` is the file that the command line names (not one that
   another file includes). `M.tci` and `M.tc` compare by the last
   component of their paths.
3. Tokens that a macro produces belong to the file where the macro is
   expanded, so a macro of `M.tci` gives a client no right of the
   owner.
4. The zero value is open to every client: `(T){0}`, and the
   initialisers `{0}` and `{}`. A compound literal of a private
   distinct type with another value is refused by
   [2.4](#24-distinct-types), as an implicit conversion to the
   distinct type [distinct-conversion].
5. Only Type-C text is bound: C text may cast to a private distinct
   type. An operation that reinterprets storage, such as `*(D *)p`, a
   union member, `va_arg` or a copy of bytes, makes a private value
   outside the rule. `private` is a design aid, not a security boundary.

An interface with an incomplete variant and two private types, in a
directory that `-Iinclude` names:

<!-- file: include/ticket.tci -->
```c
#ifndef TICKET_TCI
#define TICKET_TCI

type counter;
type ticket = private distinct unsigned;
type answer = private
    | Granted(ticket t)
    | Refused;

counter *counter_new(unsigned limit);
answer counter_take(counter *c);
void counter_free(counter *c);

#endif
```

Its owner, which completes `counter` and creates the values:

<!-- file: ticket.tc -->
```c
#include <stdlib.h>
#include "ticket.tci"

type counter = | Counter(unsigned next, unsigned limit);

counter *
counter_new(unsigned limit)
{
	counter *c = malloc(sizeof(*c));

	if (c != NULL)
		*c = Counter(0, limit);
	return (c);
}

answer
counter_take(counter *c)
{
	match (*c) {
	case Counter(next, limit):
		if (next == limit)
			return (Refused);
		*c = Counter(next + 1, limit);
		return (Granted((ticket)next));
	}
}

void
counter_free(counter *c)
{
	free(c);
}
```

A client, which matches on `answer` and reads a `ticket`:

<!-- file: queue.tc -->
```c
#include <stdio.h>
#include "ticket.tci"

int
main(void)
{
	counter *c = counter_new(2);

	if (c == NULL)
		return (1);
	for (int i = 0; i < 3; i++) {
		match (counter_take(c)) {
		case Granted(t):
			printf("ticket %u\n", (unsigned)t);
			break;
		case Refused:
			printf("refused\n");
			break;
		}
	}
	counter_free(c);
	return (0);
}
```

```console
$ typec -Wall -Wextra -Werror -Iinclude -o queue queue.tc ticket.tc
$ ./queue
ticket 0
ticket 1
refused
```

A client that creates a value:

<!-- file: forged.tc -->
```c
#include "ticket.tci"

answer
forged(void)
{
	return (Refused);
}
```

```console
$ typec -Iinclude -c forged.tc
forged.tc:6: error: the variant 'answer' is private to 'include/ticket.tci', so only the text of its owner creates its values [private-creation]
[80]
```

## 10. C clients and headers

What C code sees of each Type-C type, and the headers of
`typec --emit-c-header`: design 9.3 and section 10.

## 11. Checks and the trap

A *trap* stops the program; it does not return. These checks trap:

| Check | Section |
| --- | --- |
| A tag that is no constructor's, read by `match`, a test or `try` | [3.6](#36-invalid-tags) |
| The end of a `match` arm reached | [3.4](#34-leaving-an-arm) |
| The unreachable end of a block that holds a `defer` reached | [6](#6-defer) |
| A slice index out of range, or a `slice_sub` range outside its slice | [8](#8-slices-and-str) |
| A check of checked mode | [12](#12-checked-mode) |

A trap is `__builtin_trap()`. With the option `--trap-function=name`,
every trap first calls `name`, which the program supplies with the type

```text
_Noreturn void name(void);
```

for example to report the fault on a system without signals. `name` is
a C identifier; the last such option given wins. `name` does not return:
the trap follows the call. A unit that has no check refers to no `name`.

<!-- file: trap.tc -->
```c
#include <stdio.h>
#include <stdlib.h>

_Noreturn void
on_trap(void)
{
	fputs("trap\n", stderr);
	_Exit(3);
}

int
main(void)
{
	int a[4] = { 1, 2, 3, 4 };
	slice(int) s = slice_from_array(a);
	size_t i = 4;

	return (s[i]);
}
```

```console
$ typec -Wall -Wextra -Werror --trap-function=on_trap -o trap trap.tc
$ ./trap
trap
[3]
```

## 12. Checked mode

`#pragma typec`, `unsafe` blocks and the checks of checked mode: design
section 11.

## 13. The driver

`typec` takes the command line of `cc` and stands in for it in a build:
it compiles each Type-C unit and hands every other input and option to
the *backend*, the C compiler that it runs. [typec(1)](typec.1) states
which input is a Type-C unit, how the backend is chosen, the options of
`typec`, the options that it refuses with a Type-C unit, its
environment and its exit statuses. This section says how a unit passes
through the backend.

1. A unit passes through three steps:
   1. the backend preprocesses it, with `__TYPEC__` defined and the
      dialect of [1.2](#12-c11-and-the-dialect);
   2. `typec` reads the preprocessed text, checks it by the rules of
      this page and lowers it to C11. It stops at the first error, which
      it prints as `file:line: error: message`, without a column;
   3. the backend compiles that C as preprocessed C, under the options
      of the command line, as it would compile the unit's `.c` file:
      `-c`, `-S`, `-o` and linking make the outputs that they make for a
      `.c` file, under the same names.
2. The dependency options reach the first step, so the rule of a unit
   names its `.tc` file and every header and interface that it
   includes, as the rule of a `.c` file does. A build tool therefore
   compiles a `.tc` file as it compiles a `.c` file; the
   [README](../README.md#in-a-build) gives rules for make, ninja and
   CMake.
3. The rules of C that `typec` does not check are the backend's: an
   error in the third step comes with the backend's message and status.
4. `--emit-c` writes the C of the second step. It is preprocessed for
   one target, so the command takes the options of the build; the
   backend compiles the C as preprocessed C (a `.i` file) under the
   `-std=` of [1.2](#12-c11-and-the-dialect) and the options that the
   [README](../README.md#compiling-a-tc-input) gives the third step.
5. `--print-target` prints the target model for which the second step
   reads a unit, as the backend gives it under the other options of the
   command line, which are therefore those of the build.
6. `--trap-function=name` is described in
   [11](#11-checks-and-the-trap).

The unit `ticket.tc` of [9.2](#92-private) with its dependency file,
`queue.tc` through its C, and a refused option:

```console
$ typec -Wall -Wextra -Werror -Iinclude -MMD -c ticket.tc
$ cat ticket.d
ticket.o: ticket.tc include/ticket.tci
$ typec -Iinclude --emit-c -o queue.i queue.tc
$ cc -std=gnu17 -Wall -Wextra -Werror -c queue.i
$ cc -o tickets queue.o ticket.o
$ ./tickets
ticket 0
ticket 1
refused
$ typec --print-target | grep -e '^char_bit' -e '^sizeof_int:'
char_bit: 8
sizeof_int: 4
$ typec -Iinclude -E queue.tc
typec: -E cannot be used with a .tc input: it stops after preprocessing; --emit-c writes the C of a .tc input
[81]
```
