<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Type-C language design

Type-C is C11 with ML-style types. It adds closed variant types with
exhaustive matching, distinct types, parametric generics, result propagation
and scope-exit cleanup, and it compiles to ordinary C11. Plain C keeps its
meaning, its ABI and its costs. A separately enabled checked mode rules out
specific classes of memory errors in the code it covers; it does not make
arbitrary C safe.

This document specifies the language and the compiler that implements it.
The order of work is in
[type-c-implementation-plan.md](type-c-implementation-plan.md) and open work
is in [TODO.md](TODO.md).

**How to read the status of a rule.** This document states the design and
not how much of it is built: the README says what `typec` accepts
([Status](README.md#status)), and the plan gives the order of the rest. A
rule stated without qualification is the design. A rule marked
*Provisional (Pn)* is a choice that needs evidence; section 15 lists each
one with what settles it and the default that stands if nothing does.
Section 12 holds features that are deliberately outside the core.

## 1. Principles

These are normative for design reviews. A proposal that conflicts with one of
them must say which and why.

1. **Preserve C.** Where C already expresses an operation clearly, Type-C
   keeps C's spelling and meaning: declarations, `if`, `for`, `while`,
   `switch`, `case`, `default`, `break`, `continue`, `return`, `goto`, casts,
   pointer operators, struct and union syntax, function calls, the
   preprocessor, headers and linkage.
2. **Extend, never redefine.** A valid C11 translation unit means the same
   thing as Type-C (2.2). New constructs occupy syntax that C rejects.
3. **ML where C has nothing.** Closed sums, destructuring, nominal scalars
   and type parameters justify new syntax. `let`, currying, pervasive
   inference and expression-oriented control flow do not.
4. **Costs stay visible.** No heap allocation, garbage collection,
   exceptions, unwinding, runtime library or link dependency. The compiler
   adds code the source does not spell out in four places only: the traps
   of `match`, the bounds check of slice indexing, the cleanups and the
   trap of `defer`, and the checks of checked mode.
5. **Claim only what is checked.** Each guarantee names the code it covers
   and what it depends on (section 14). C code and unchecked Type-C code can
   break any of them.
6. **Small vocabulary.** Every concept names the concrete problem it solves.
   No classes, inheritance, overloading, traits, templates or implicit
   conversion machinery.
7. **C's compilation model.** Translation units, headers and any build
   system. The compiler handles one translation unit at a time and keeps no
   project-wide state.
8. **By construction over by rule.** Prefer a design in which the wrong thing
   cannot be written or cannot happen over one that relies on a check being
   remembered. Examples in this document: untouched C is emitted verbatim,
   all-zero storage is always a valid variant, and a lowered `match` always
   lists every constructor.
9. **Language before machinery.** The semantics are defined here, not by what
   a particular implementation technique makes easy.

**Syntax-preservation test.** Before accepting a feature, write the clearest
ordinary C for it. If that C already behaves as wanted and reads well, keep
it. Otherwise add the smallest extension that does the job.

## 2. Source text

### 2.1 Files

| Suffix | Content | Handling |
| --- | --- | --- |
| `.c`, `.h` | C | A `.c` file is handed to the C compiler unchanged. A `.h` file is included as C. |
| `.tc` | Type-C source | One translation unit, compiled by `typec`. |
| `.tci` | Type-C interface | A header in Type-C syntax, pulled in by `#include` (section 9). |

Text is *Type-C text* when the file it comes from has the suffix `.tc` or
`.tci`, and *C text* otherwise. The grammar is the same for both but for
the words `try` and `defer` of 2.3; the other differences are that Type-C
text cannot name the C that a type declaration derives (10.1) and cannot
treat a variant as the structure it lowers to (3.2 rule 6). A `.tc` file
may include `.h` and `.tci` files in any mix.

`typec` predefines the macro `__TYPEC__` as `1` while preprocessing a Type-C
translation unit, so that a shared header can adapt.

### 2.2 Type-C is a superset of C11

Every C11 translation unit in the supported dialect (2.4) is a Type-C
translation unit with the same meaning, provided its Type-C text does not use
a universe name (2.3) as a parameter of an old-style definition, which C11
6.9.1p6 makes an error because the name is a typedef name there. This holds because each new construct begins
with a token sequence that C rejects:

| Construct | Begins with | Why C rejects it |
| --- | --- | --- |
| `try` expression, `defer` statement | `try` or `defer` where no declaration of an ordinary identifier of that spelling is in scope (2.3) | An identifier that no declaration makes visible is not a primary expression (6.5.1p2), and C11 has no implicit function declaration. |
| Type declaration | `type` *identifier*, starting a declaration | Two identifiers start a C declaration only when the first names a type; 2.3 excludes that case. |
| `match` statement | `match (` ... `) {`, starting a statement | A call cannot be followed by `{`. |
| Single-pattern test | `if (case` or `while (case` | `case` begins a labelled statement and never an expression, so it cannot begin a C condition. |
| Generic function | `generic (` ... `)`, starting a file-scope declaration | C11 has no implicit `int`, so this starts a C declaration only when `generic` names a type; 2.3 excludes that case. |
| `unsafe` block | `unsafe {`, starting a statement | An identifier cannot be followed by `{`. |
| Type application, explicit instance | *G* `(` *types* `)`, where *G* names a generic | Only Type-C declares such a *G*. |
| Qualified constructor | *type-name* `.` | A type name cannot begin a postfix expression. |
| Unqualified constructor, `str` literal | Selected by a target type that is a Type-C type (3.3) | No C expression has such a target type. |

The consequence for adoption: a C file can be renamed to `.tc` and compiled
before any Type-C construct is used in it.

### 2.3 Words

**Hidden words.** In Type-C text, `try` is the operator of 5.1 and
`defer` the statement of section 6 wherever no declaration of an ordinary
identifier of the same spelling is in scope. Any declaration of it, a
function, object, parameter, typedef or enumerator, in Type-C text or in
C text such as an included header, hides the word from that point under
C's ordinary scope rules, as it hides a universe name: inside that scope
`try` and `defer` are the identifier, and the Type-C construct is
unavailable. The words prefix an expression and a statement, where an
identifier could also appear, so position cannot tell them apart from a
call or a declaration; scope can, because C uses an ordinary identifier
only where a declaration of it is visible. A superset must accept C that
names something `try` or `defer`, as zlib's `test/infcover.c` names a
function and QBE's `rega.c` a parameter, so the words are not reserved.
A tag, a member or a label has a name space of its own, where neither
construct can stand, so it may be named `try` or `defer` anywhere:
`s.defer`, `struct try`, `goto try;`. A constructor may not, in any
text (3.2 rule 2). In C text both are ordinary identifiers. `_Defer`, the
spelling of ISO/DIS TS 25755, is a keyword in all text that always means
`defer`.

**Positional words.** `type`, `match`, `generic`, `unsafe`, `private` and
`distinct` are ordinary identifiers that Type-C recognises only in the
positions of the table in 2.2 (`private` and `distinct` only after the `=`
of a type declaration, `private` only before `|` or the word `distinct`,
and `distinct` only before a token that begins a type name, so
`type a = distinct;` and `type b = private *;` are aliases of typedef
names). A variable, function or field may carry any of these names. One
exception keeps C's meaning intact: where `type` or `generic` is
visible as a typedef name, `type x;` and `generic (x);` are the C
declarations, and the Type-C construct is unavailable in that scope.

**Universe names.** `option`, `result`, `slice`, `str`, `slice_from_array`,
`slice_sub` and `slice_unchecked` are declared in a *universe scope* that
encloses file scope. Any declaration of the same identifier, except a
generic that 3.6 refuses, shadows the universe name from that point, under
C's ordinary scope rules, so `int result = f();` remains valid C; inside
that scope `result(T, E)` is simply unavailable. Where C11 6.7.6.3p11
would read an identifier in a parameter declaration either as a typedef
name or as the parameter it declares, a universe name is the parameter:
`int f(int (str));` declares an `int` parameter named `str`, as in C, so
a header shared with C means the same in both. A parameter whose type is
a universe type and that has no name is written without parentheses,
`size_t len(str);`, where no other reading exists. In C text, a universe
name in the identifier list of an old-style definition is the parameter
it names, as in C, so C text keeps its meaning there too (2.2).

**Generated names.** Identifiers that begin with `__tc_` are reserved for the
compiler in a Type-C translation unit; one in its text, C text included, is
an error, so that no declaration and no use can meet a name that lowering
generates. The names that a type declaration derives for C (section 10)
are reserved in the scope of that declaration; none is an identifier
that C reserves for any use (3.1 rule 6), so none begins with `__tc_`.

Rationale. The words Type-C wants (`type`, `match`, `result`, `str`,
`option`) are among the most common identifiers in C. Reserving them would
break struct fields named `type`, parser functions named `match`, and every
`int result`, including uses that reach Type-C text through macros defined
in C headers. Recognition by position costs nothing where the construct is
invalid C anyway; Rust's contextual `union` and Go's universe block are the
precedents. Pilot A, a port of chibicc, renamed no identifier for a word
and broke no header macro: its function `match` and its local `type`
compile unchanged. It has no identifier `try` or `defer`, so the hidden
words rest on the argument above.

### 2.4 Preprocessing and C dialect

The C compiler that will compile the output also preprocesses the input
(13.2). Type-C therefore sees tokens after macro expansion and conditional
inclusion, and:

- Macros may produce any Type-C construct, in whole or in part. There are no
  restrictions on extensions inside macro expansions.
- A token belongs to the file that was being read when it was produced,
  that is, the include stack that the enter and leave flags of the line
  markers describe. Tokens of a macro expansion belong to the file of the
  expansion site. A `#line` directive changes the name that diagnostics
  show, not the file a token belongs to.
- `#pragma typec` lines are consumed by `typec` (section 11). Every other
  pragma is passed through in place.

The accepted dialect is ISO C11 plus a *GNU profile*: the GNU and Clang
extensions that system headers and common code rely on (13.3). `typec`
passes `-std=gnu17` to the C compiler unless the command line selects C11
or C17 in ISO or GNU form. Other dialects are not accepted. The GNU
keywords spelled without underscores, `asm` and `typeof`, are keywords in
the GNU form and identifiers in the ISO form, as for the C compiler;
`-fasm` and `-fno-asm` override the choice. The `__` spellings are
keywords in both.

Rationale. Headers select constructs by `__STDC_VERSION__`; pinning the
dialect bounds what the front end must parse. The default is `gnu17`,
the default of Clang 11 and later, so a `.c` file renamed to `.tc`
keeps the `__STDC_VERSION__` it had, `201710L`. C17 is C11 with defect
fixes and no new syntax, so the front end reads the same language in
either. GCC 15 and later default to `gnu23`, which `typec` does not
read; a build with such a GCC that wants its `.c` and `.tc` files in
one dialect passes `-std=gnu17` or `-std=gnu11`. Everything Type-C
lowers to compiles in the dialect the command line selects: ISO C11 plus only GNU
forms that GCC and Clang accept in every dialect, also under
`-pedantic-errors`. Four are used: `__typeof__`, which C23 standardises
as `typeof` and which names a type where no name for it is sure to be
visible, the type of a field for a match binding, the return type of a
function for the temporary of a `return` and the type of a slice's
length for the temporaries of its test (13.5); `__typeof_unqual__`,
C23's `typeof_unqual`, which names an untagged type without the
qualifiers that its one name carries (10.3); `__builtin_trap` (10.5);
and `__extension__` before C23's empty initialiser `{}`, which zeroes
the padding of a structure and the whole of a union with the members,
as no initialiser of ISO C11 does (13.5).
Lowered code also writes the three
packing pragmas of the bracket of 10.3 and, in its probe, `#pragma
pack(1)` and `#pragma pack(2)`. C11 6.10.6 leaves a pragma to the
implementation; GCC 14.2 and 16.2, Clang 20 and Apple Clang 21 take the
three of the bracket without a diagnostic in the ISO and the GNU form
of C11, also under `-pedantic-errors`. The two of the probe were
measured so with GCC 16.2, Apple Clang 21 and Clang 22 and 23 alone.
A backend that ignores the pragmas has no packing to keep out.
The one exception is GCC under `-fpack-struct` without a value, which
ignores them and warns of each; the driver refuses that option (13.2).
The emitted file is preprocessed output, with line markers, and is
compiled as such (`-x cpp-output`). So the output dialect is the input
dialect and nothing newer. Its line markers are the toolchain's text, not
the user's, and are no part of the dialect: they take the GNU form
(13.4). GCC 14 and 16, Clang 21 to 23 and Apple Clang 21 read them in
preprocessed input without a diagnostic under `-pedantic-errors`, and
Clang does so also under `-Wgnu-line-marker`, so the compile step adds
no option for them. A line marker that the user writes is still diagnosed, when the
backend preprocesses the source under the user's options.

## 3. Types

### 3.1 Type declarations

```c
type expr;                                        /* incomplete variant */
type expr = | Number(long value) | Add(expr *left, expr *right);
type reg_id = distinct uint32_t;                  /* distinct type      */
type pair(A, B) = struct { A first; B second; };  /* generic type       */
```

A type declaration may appear at file scope or in a block, where an
external declaration or a block item may (Appendix A); not in the first
clause of a `for` or in the declarations of an old-style definition. One
with type parameters appears at file scope only, where its instances are
emitted.

1. It declares its name in the ordinary identifier namespace of the current
   scope, as `typedef` does.
2. The name is in scope from the end of its identifier. Inside its own
   definition it is an incomplete type, so a variant, or a definition that
   is a struct or union specifier, can refer to itself through a pointer.
   No other definition can use its own name.
3. The definition after `=` is a variant (3.2), `distinct` followed by a
   type (3.4), or any C type name. The last form makes the name an alias,
   as `typedef` would; it exists to carry type parameters (3.5).
4. `type N;` declares an incomplete variant. It is completed at most once,
   in the same scope, by a variant definition with the same number of type
   parameters: `type list(T);` has one type parameter, and so has the
   definition that completes it. For an incomplete struct, C's
   `struct N;` remains the spelling.
5. A name has one definition in a scope. Unlike `typedef`, a type
   declaration is not repeated; headers use include guards.
6. In every scope, and whatever the form of the declaration, the name
   contains no two consecutive underscores, does not end with an
   underscore, and does not begin with an underscore and an uppercase
   letter. The names that the declaration derives (section 10) begin as
   its name does. Under this rule and the one for constructor names (3.2
   rule 2), none of them is a name that C reserves for any use (C11
   7.1.3p1), so none spells a keyword of the dialects of 2.4, where every
   keyword with an inner `_` is so reserved; and none holds the `__` that
   marks an instance name (10.3). `type _Static = | assert;` would derive
   `_Static_assert`, and `type vector_ = | i;` would derive `vector__i`.
7. Where it is declared at file scope, the name does not begin with an
   underscore. C reserves such a name at file scope, as an ordinary
   identifier and as a tag (C11 7.1.3p1), and the names derived from it
   begin as it does: `_x` would give `_x_tag`, `_x_A` and the instance
   `_x__i`.

### 3.2 Variants

```c
type expr =
    | Number(long value)
    | Variable(str name)
    | Add(expr *left, expr *right)
    | Multiply(expr *left, expr *right);
```

1. A variant is a closed, nominal type passed by value. Constructing a value
   allocates nothing.
2. Constructor names live in the variant, not in the ordinary namespace: two
   variants in one scope may both have a constructor `Add`, and no global
   `Add` exists. Names within one variant are unique. No constructor is
   named `try`, `defer` or a universe name (2.3), in any text: written
   unqualified (`T t = try(1);`) it could read as the constructor or as
   the word or universe name, and refusing it keeps one reading. A field
   may have such a name, as a member may. A constructor name also contains
   no two consecutive underscores and does not begin with an underscore,
   so that `N_C`, the enumerator it derives (10.1), has no `__` (3.1
   rule 6); a name that C reserves for any use begins with an underscore
   and is refused with the rest. A field is not named by a name that C
   reserves for any use (3.1 rule 6) either, since each field names a
   member of the C that `typec` builds for the variant (10.1 rule 3). A
   name inside C written in a field, such as a member of a structure type
   or a parameter of a function type, follows the rules of C, as in C
   text.
3. The leading `|` is required. It is what tells a one-constructor variant
   from an alias.
4. A constructor has zero or more named fields, written like parameters. A
   field type is a *value type*: a complete object type that is unqualified,
   not atomic, not an array, not `va_list` and not variably modified, and
   that contains no const-qualified member and no flexible array member at
   any depth. A value of such a type can be assigned and can be a member. A
   bit-field is not a field. An array is wrapped in a struct, because
   constructor arguments are expressions and C has no array values.
   `va_list` is refused because its representation is the target's (P20):
   on x86-64 it is an array, which cannot be assigned, and a variant is a
   value type. A structure that wraps a `va_list` is a value type, as one
   that wraps an array is.
5. Since a field type must be complete, a variant can contain itself only
   through a pointer. No separate check for infinite size is needed. A
   variant is itself a value type.
6. **A variant is opened only by matching**: a `match` (4.1) or a
   single-pattern test (4.6). Type-C text cannot open a
   variant, that is, reach its tag or payload, as a value or by name:
   constructors make them and matching reads them, and no other operation
   does either, except that `{0}` and `{}` write the zero value (rule 7). Every
   operation that does not open the value takes it whole and is allowed.
   Copying it, as initialisation, assignment, passing and returning do,
   copies the representation as for a struct and does not copy pointed-to
   objects. Among the whole-value uses are `sizeof`, `_Alignof` and unary
   `&`; parentheses, the second and third operands of `?:`, both operands
   of the comma operator and an expression statement; a cast to `void`,
   which discards the value; and `_Generic`, whose controlling expression
   is a type query, as the operand of `sizeof` is. Member access and an
   `offsetof` designator open it and are refused; so are `==`, a cast to
   a variant and a cast from one to any type but `void`, which C refuses
   for a structure too, and any operator that C defines only for scalars.
   These lists are examples: the definition is whether the operation
   opens the value. C text may use the structure that a variant lowers to
   (10.6).
7. **Zero value.** All-zero storage of a variant type holds its first
   constructor with every field zero. Static objects without an
   initialiser, `calloc` and `memset` yield that storage, and the
   initialiser `{0}` yields the value: C gives the tag and every field
   of the first constructor the value zero (C11 6.7.9p10 and p21). All
   four therefore make a valid value. `{0}` is C's initialiser here,
   in Type-C text as in C text, and lowering leaves it as written. It
   promises the values of the members and not the bytes of the object,
   as for any C object: for `union { char c; long l[4]; } u = {0};`
   GCC 16 zeroes `c` and leaves most of the other bytes as the stack
   held them, where Apple Clang 21 zeroes them all. Code that hands
   the representation on, to `memcmp`, to `write` or to a hash of the
   bytes, clears the object with `memset`, as in C. Where the text
   cannot know what the members are, in an object whose type mentions
   a type parameter, Type-C makes the zero initialiser zero the
   padding of a structure and the rest of a union as well
   (7.1 rule 3). `{0}` and the empty initialiser `{}` (GNU C, C23) are
   the only braced initialisers a variant accepts, and `{}` is its
   zero value wherever `{0}` is. `{0}` gives any object its zero
   value, so it also gives a structure whose first member is a variant
   its own: its `0` writes the variant's zero value through elided
   braces, which no other initialiser may do. Put the constructor that
   makes a sensible default first (`None`, `Empty`).
8. An automatic variant object without an initialiser is indeterminate, as
   in C. Matching on it traps when the tag is out of range and otherwise
   reads whatever the fields hold.

Rationale for the zero value. Zeroed storage is the commonest way a C object
comes into being. Making it valid for every variant removes the invalid tag
that zero-initialisation would otherwise produce, and asks of programmers
only what C enumerations already ask: mind which enumerator is zero.

### 3.3 Constructor expressions and target types

```c
expr x = Number(42);          /* target type expr, from the declaration */
expr y = expr.Add(&x, &x);    /* qualified: needs no target type        */
return Err(BadToken);         /* both resolved from the return type     */
```

A constructor expression is written `C` for a constructor without fields and
`C(arguments)` for one with fields. Each argument is converted to the type
of its field as if by assignment. The result is a value of the variant type
and not an lvalue. The order in which arguments are evaluated is
unspecified, as for a call. A constructor is not a function: it has no
address.
`C()`, with empty parentheses, is an error, since it reads as a call.

A constructor is named in one of two ways.

- **Qualified:** `T.C`, where `T` is a typedef name or a type application
  that denotes a variant. This works in every expression that typing
  reads.
- **Unqualified:** `C` alone, in a position whose *target type* is a variant
  with a constructor `C`. There, `C` denotes the
  constructor even when an ordinary identifier `C` is visible, so the
  meaning of a constructor expression depends only on the type expected at
  that point and not on which identifiers some header declares. A typedef
  name `C` is such an identifier too, except where C's grammar takes it
  to begin a type name, since the parser decides that before any target
  type is known: a block item `C (x);` declares `x`, and after a `(`
  that opens a primary expression or the operand of `sizeof`, `C`
  begins a cast, a compound literal or a type operand, so `(C(1))` needs
  the qualified form. Macros are another matter: they are expanded
  before Type-C sees the tokens, so a header that defines `None` as a
  macro breaks that constructor, as it breaks any identifier.

An expression has a target type in these positions and in no others:

| Position | Target type |
| --- | --- |
| Initialiser of an object or sub-object | The type of that object |
| Right operand of `=` | The type of the left operand |
| Operand of `return` | The return type of the function |
| Argument of a call to a prototyped function | The parameter type; for a generic function, once its type parameters are deduced (7.2) |
| Argument of a constructor | The field type |
| Parenthesised expression; second and third operand of `?:`; right operand of `,` | The target type of the enclosing expression |

The operand of `try` is not among them: `try` reads `T` and `E` from the
type of its operand (5.1), so no type is expected of it. The `Ok` of
`x = try Ok(1);` names no constructor and means what C declares, a
function `Ok` or nothing, where `x = try result(int, e).Ok(1);` names
the constructor. The target type of a position that holds a `try` ends
at the `try`, whose value of type `T` converts to it as if by
assignment.

Where a braced list elides braces (C11 6.7.9p20), which subobject an
initialiser initialises depends on its type, so its target type cannot
come from that subobject. It is the first variant that eliding the braces
of the subobject at the list's position leads to, or that subobject where
none does. No initialiser enters a variant except `{0}` or `{}` (3.2
rule 7), so a constructor initialises that variant whole, and a target
that is no variant selects no constructor:
`struct w { struct s { e v; int n; } s; } y = { A, 1 };` builds `y.s.v`
with the constructor `A` of `e`, whatever object `A` is visible.

Everywhere else an unqualified name is looked up as C looks it up, and a
constructor needs the qualified form. The positions are those of text
that typing reads: unread text (13.5) has no target type, since the
backend reads it as C, so an unqualified name there means what C
declares even in such a position. In the scope of `enum { A = 8 };`
and `type v = | A;`, the `A` of
`__attribute__((assume(g((struct s){ A, 1 }))))`, where the first
field of `struct s` has the type `v`, is the enumerator, as the backend
reads it. The cost is that unread text names no constructor, since
the qualified form is not C either (13.5). String literals use the
same mechanism to become `str` (section 8).

In a generic function the check of the definition decides whether a
name is a constructor or what C declares, against the opaque type
parameters, and every instance takes that decision (7.3 rule 3): a
type parameter is no variant, so a name whose target type is a type
parameter is what C declares there in every instance, even one whose
argument is a variant with a constructor of that name.

A constructor expression, qualified or not, stands within the scope of its
variant's declaration: from the type declaration to the end of the block,
match arm or translation unit that holds it. Outside that scope it is an
error, even where the type reaches: `__typeof__` carries the type of a
statement expression out of the block that declares it, and `int e_A = 7;
__typeof__(({ type e = | A; e v = A; v; })) y = A;` is refused. The names
that a constructor lowers to denote the variant only within its scope
(10.1 rule 6).

Rationale. Variants want short constructor names, and a C translation unit
has one flat namespace of ordinary identifiers. Scoping constructors to
their type keeps them out of it; target typing removes the qualification
wherever the type is already written nearby. C# target-typed `new` and
Swift implicit member expressions work the same way. In Pilot A every
constructor is unqualified, constructors of one name in two variants
(`Var`, `Function`, `Num`) resolve by their target types, and no
resolution surprised its author.

### 3.4 Distinct types

```c
type reg_id   = distinct uint32_t;
type block_id = distinct uint32_t;

reg_id r = (reg_id)3;
block_id b = (block_id)3;
r = b;                          /* error: block_id is not reg_id */
uint32_t n = (uint32_t)r + 1;   /* the crossing is explicit      */
```

`type D = distinct U;` declares a scalar type `D` with the size, alignment
and representation of `U`, where `U` is an arithmetic or pointer type. `D`
is compatible with no other type, including `U` and other distinct types
over `U`; so `D *` and `U *` are incompatible and `_Generic` tells them
apart.

| Use of a value of type `D` | Rule |
| --- | --- |
| Initialise, assign, pass, return | The source has type `D`. |
| Cast | `(D)e` is valid where `(U)e` is; `(T)d` is valid where a cast from `U` to `T` is. A cast is the only conversion. |
| `==`, `!=` | Both operands have type `D`. |
| Truth value: `if`, loops, `!`, `&&`, `\|\|`, first operand of `?:` | Allowed; the value is compared with zero. |
| Results of `?:` both of type `D`; `,`; `sizeof`; `_Alignof`; unary `&` | As in C. |
| Initialiser `{0}` or `{}` | The zero value of `U`. |
| Bit-field of type `D` | Allowed where one of type `U` is. |
| Anything else | Error: arithmetic, `<` and the other relational operators, `++`, compound assignment, unary `*`, `->`, `[]`, a call, `switch`, passing through `...`, and every implicit conversion. |

The table's edges are these rules.

1. `U` is unqualified, so `distinct const int` is an error: a qualifier
   belongs to an object, and `const D` states it where it applies.
2. `{0}` and `{}` also zero an object whose first member, reached
   through elided braces, has type `D`, because they are the C idioms
   that zero any object and zero is a value of every `U`.
3. A value of type `D` passes to a function without a prototype no more
   than through `...`, because the default argument promotions of both
   would convert it to another type.
4. An `asm` operand takes a value of type `D`, because `asm` is unchecked
   and the backend sees `D` as `U` (section 10.2).
5. The builtins that only move a value into or out of the object that
   their first argument points to take an object of type `D`, because
   they assign it as `=` does: `__atomic_load(_n)`, `__atomic_store(_n)`,
   `__atomic_exchange(_n)`, `__atomic_compare_exchange(_n)`,
   `__sync_lock_test_and_set`, `__sync_lock_release`,
   `__sync_val_compare_and_swap` and `__sync_bool_compare_and_swap`.
   Clang's `__c11_atomic_init`, `_load`, `_store`, `_exchange`,
   `_compare_exchange_strong` and `_weak` do the same on an object of
   type `_Atomic D`. The operands that stand for a value of the object
   then have type `D`, or `D *` where they point to one, as the source of
   an assignment does; the memory orders and `weak` stay integers.
6. The arithmetic, bitwise and ordering (max, min) `__atomic_*`,
   `__sync_*` and `__c11_atomic_*` builtins, such as
   `__atomic_fetch_add`, `__sync_or_and_fetch` and
   `__c11_atomic_fetch_max`, refuse an object of type `D`, because they
   compute on its representation.
   `__atomic_test_and_set` and `__atomic_clear` take a `volatile void *`,
   which a `D *` converts to as it does for `memset`.

Rationale. The purpose is that ids and units do not mix by accident. The
operation set is the smallest that lets a program store, compare and test
an id; arithmetic goes through casts so that each crossing is visible.
Declaring operators for a distinct type is outside the core (section 12).

### 3.5 Generic types

```c
type vector(T) = struct { T *data; size_t len; size_t capacity; };
type list(T)   = | Nil | Cons(T head, list(T) *tail);
type id(T)     = distinct uint32_t;     /* phantom parameter */

vector(int) numbers;
vector(expr *) nodes;
id(expr) e;
id(stmt) s;                             /* e = s is an error */
```

1. A type declaration with parameters declares a *generic type*. Its name
   alone is not a type; a *type application* `G(A1, ..., An)` is. The
   instance names made from the name (10.3) rely on what 3.1 rules 6 and
   7 require of it.
2. A type argument is an object type, complete or not, that is neither an
   array nor variably modified, and every type in it has a row in the
   table of 10.3. Every struct, union, enum, variant and distinct type
   in it, the argument itself or one under a pointer or in a function
   type, is declared at file scope, and a struct, union or enum among
   them has a tag or exactly one name that a declaration gives it, so
   that every type in an argument has one name (10.3). A tag that an
   argument is the first to mention is declared where C declares a tag
   first mentioned at that place (C11 6.7.2.3p8), in the smallest scope
   that holds the mention. That scope is file scope only for a mention
   at file scope and outside every parameter list, so the first mention
   of a tag in an argument that stands in a parameter list or in a
   block is an error; `struct s;` at file scope before it makes the
   argument valid.
   One rule names an untagged struct, union or enum, for a C `typedef`
   and a Type-C alias alike: a declaration names the type when the
   untagged specifier is the type specifier of the declaration, or of
   the alias's definition, and the declarator derives nothing. So
   `type e = enum { A };` names its enumeration `e`, as
   `typedef enum { A } e;` does, and
   `type s = const struct { int x; };` names its struct `s`, as the
   typedef of the same text does: a qualifier beside the specifier
   derives no type, and `s` is the qualified struct (`K1s` in 10.3). A
   specifier inside the type name of `_Atomic( )` or `__typeof__( )` is
   not the declaration's own, and that declaration names nothing.
   `typedef struct { int x; } a, b;` gives its struct two names, so
   neither `a` nor `b` is an argument. A declarator that derives
   another type names that type and not the struct:
   `typedef struct { int x; } n, *np;` gives its struct the one name
   `n`. An argument holds no attribute, whatever the attribute: none is
   written in it, and no typedef name that it uses, at any depth, is
   declared with one before the text that uses the name, which 13.5
   keeps true where lowering writes an alias. An instance name is built
   after typedef expansion and encodes no attribute (10.3), so
   `vector(int)` and `vector(wide)`, where `wide` is a typedef of `int`
   with the GNU attribute `aligned(16)`, would have one name and two
   layouts in one translation unit, as another attribute would give one
   name two aliasing behaviours. The depth is that of the names that
   spell the argument: a typedef name that the argument writes, one
   that the declaration of such a name writes, and so on down to the
   type specifiers, under every pointer, array, function and qualifier
   on the way. A Type-C alias is a typedef name here, and so is an
   application of a transparent alias generic, which is expanded as a
   typedef name is (10.3): the alias's definition is its declaration. A
   typedef name is declared with an attribute where one stands among
   the specifiers of its declaration, in its declarator or after it.
   The text inside the specifier of a struct, union or enum is outside
   that depth. An attribute there, after the keyword or
   after the closing brace, belongs to that type and not to a typedef
   name that the same declaration declares, and a member there is part
   of that type, which has its one name and one layout wherever an
   argument names it: `vector(struct s)` is valid where a member of
   `struct s` has the type `wide`, and so is `vector(p)` with
   `typedef struct __attribute__((packed)) { char c; int i; } p;`.
   A nullability qualifier of Clang (`_Nonnull`, `_Nullable`,
   `_Nullable_result`, `_Null_unspecified`) and a keyword that names an
   address space, as `__seg_gs` does, are attributes under this rule:
   the table of 10.3 has a row for neither. Clang holds `int * _Nonnull`
   and `int *` to be one type (Apple Clang 21), so the two arguments
   would share one name and one typedef of the argument (10.3), with the
   nullability of whichever is used first.
   *Provisional (P26).* An argument holds no `__typeof__` of an
   expression, in any of its spellings, at the same depth: none is
   written in it, and no typedef name that it uses is declared with one.
   C gives an expression the type of the typedef that declared it,
   attribute included, through an object, a member access or a
   dereference alike, and typec's types carry no attribute: with
   `wide w;`, `vector(__typeof__(w))` would be read as `vector(int)`,
   and its element would silently lose the alignment that C gives
   `__typeof__(w)`. `__typeof__` of a type name is valid, as the
   depth reaches through it. The rule refuses a macro that writes
   `vector(__typeof__(x))`, and it leaves no way to write the unqualified
   form of a qualified untagged type as an argument; deduction (7.2)
   still reaches it (10.3). A count of the arguments that it refuses, in
   Pilot B or the corpus, settles it; the refusal stays if that cannot
   settle it.
3. An application of a variant or distinct generic is a type of its
   own, as a variant or distinct type is. So is an application of an
   alias generic (3.1 rule 3) whose definition is a struct or union
   specifier with a body, as that of `vector` is: it names a structure
   or union of its own. Two such applications of one generic denote the
   same type exactly when the encodings of their arguments are pairwise
   equal (10.3); no other rule says which arguments are the same.
   Arguments are encoded after typedef expansion, so typedef names are
   transparent, and a distinct type has an encoding of its own, so it
   equals only itself. An application of any other alias generic is its
   definition with the arguments substituted, and is transparent as a
   typedef name is: with `type ptr(T) = T *;`, `ptr(int)` is `int *`. It
   is no type of its own, so C's rules compare it as they compare the
   type it stands for: with `type fp(T) = void (*)(T);`, `fp(const int)`
   and `fp(int)` are one type, as `void (*)(const int)` and `void
   (*)(int)` are, though their arguments are encoded differently. A
   qualifier of the return type of a function type is part of the type
   and of its encoding: the front end types C as Clang does, which
   keeps the qualifier where GCC drops `const`, `volatile` and
   `restrict` and keeps `_Atomic` alone (13.3, "Where GCC and Clang
   differ"). With `type fr(T) = T (*)(void);`, `fr(const int)` and
   `fr(int)` are two types.
4. A generic definition uses a type parameter only as a type: of a member,
   a field, a pointed-to object, an element, a parameter or a result, or as
   a type argument. It does not use one directly after `distinct`, in a
   bit-field, in `_Alignas` or in the arguments of an attribute, which
   lowering leaves as the source spells them (13.5), and no constant
   expression in it depends on one, by the test and the rule of 7.1
   rule 4. An attribute or an alignment specifier in it stands under
   the one rule of 13.3 for the definition of a generic ("Attributes
   in a generic"): `type g(T) = struct { T v
   __attribute__((vector_size(16))); };` is an error, as Apple Clang
   21 refuses `g(struct s)` ("invalid vector element type").
   A struct or union specifier with a body in it has no tag,
   and stands only where the definition of an instance holds it
   (10.3): as the whole definition of an alias, in a field of a
   variant, where a variant that is not generic may have one too, or
   inside either.
   Elsewhere no definition of an instance holds it: the instance of a
   distinct generic, or of an alias generic such as
   `type p(T) = struct { T x; } *;`, is a typedef that stands before its
   first use (10.3), where the types of the members need not be
   complete. No enum specifier in it has a body, since every instance
   would declare the enumerators again. The definition is checked once
   under these rules, so an application to value types (3.2) cannot
   fail.
5. An application with an argument that is not a value type, such as an
   incomplete or qualified type, is checked when a complete type is first
   needed (10.3): the arguments are substituted and the result must be a
   valid definition. An error is reported at the application and cites the
   definition. Where the instance is a typedef (10.3), an argument that
   the definition needs complete is complete where the typedef stands,
   before the external declaration that holds the first use of the
   application: with `type a2(T) = T[2];`, `a2(struct s) *` needs
   `struct s` complete there, as `struct s (*)[2]` needs it in C where
   it is written. An argument that the definition uses only under a
   pointer need not be.
6. `void` may be an argument. A variant field whose type
   becomes `void` does not exist: its constructor takes no argument for it
   and a pattern has no sub-pattern for it. This makes `result(void, E)` the
   type of a fallible function that produces no value. The field's type
   is what substitution makes of it, whatever route leads to `void`: the
   parameter itself, a typedef of `void`, an alias generic or a qualified
   `void`, since qualifiers do not change that the type is `void`. Only
   the field's own type counts: `T *p` is a pointer to `void`. Only an
   argument removes a field: `void` written as a field type in the
   definition is refused when the definition is checked (rule 4), as it
   is no value type (3.2 rule 4). A constructor whose fields are all
   removed has no fields: it is written without parentheses (3.3), as
   in `return Ok;` for `result(void, E)`, its pattern has no field list
   (4.1 rule 3), and it has no member in the union of 10.1, so a
   variant whose fields are all removed has no union (10.1 rule 3).
   The struct of a constructor that keeps some fields holds those in
   order. An error about the arguments or sub-patterns of a
   constructor names the fields that `void` removed.
7. A generic may refer to itself through a pointer (`list(T) *tail`). An
   instance is defined only where a complete type is needed (10.3), so an
   application under a pointer defines none, not even `g(g(T)) *` inside
   `g`, unless a point there needs it complete: the element type of an
   array is needed complete under a pointer as well, so
   `g(int) (*p)[2]` defines `g(int)`. A definition that needs its own
   instance complete, as `type s(T) = struct { s(T) inner; };` does, is
   an error of an incomplete type (3.1 rule 2), not of this rule. The
   definition of an instance, of a generic type or of a generic function
   (section 7), *causes* each instance that it needs and is the first to
   define: a type instance that it holds by value or otherwise needs
   complete and, in the body of a function instance, a function instance
   that the body calls or names. An instance that is defined already, or
   whose definition has begun, is caused by no later need of it. An
   instance of a transparent alias or distinct generic is defined where
   it is first applied, so the definition that holds that application
   causes it. The definition check of rule 4 defines no instance: what
   the check needs complete is defined, and causes its chain, at the
   first need of an application, as if no check had run. The check is
   still refused where its own chain, which begins at an instance that
   the definition needs, would hold a 65th instance (the limit below),
   even if a later application would find part of that chain defined
   already. The check of the definition of a generic function (7.1)
   follows its chain the same way: each call in the body reads the
   definition of the callee's instance over the opaque types of the
   check, as a trial that defines no instance and writes no text, and
   the calls within that reading share what the trial has read. So a
   chain that no instance could end, as that of `f` below, is refused
   at the call in the definition, whether or not `f` is used. A callee
   whose generic is defined after the definition is not followed:
   each of its instances is read at its first use (7.3 rule 2). The
   needs of a definition are visited in the order of its
   text, and what one of them causes is defined whole, with all that it
   causes in turn, before the next is visited.
   Instantiation *nests* along a chain of instances in which each
   causes the next, and a chain holds at most 64 instances. The
   application or call that would cause a 65th is an error, reported at
   that application or call: the message names the instance that it
   would define and cites the application or call that began the chain.
   The limit is exact and the order of visiting is fixed, so a chain has
   the same length for every `typec`, and each accepts or refuses a
   source as the others do. `generic(T) void f(T *p) { f(&p); }` reaches
   the limit, since every instance calls one of a new type. Generic
   functions that call each other (7.3 rule 2) do not: where `even(T)`
   calls `odd(T)` and `odd(T)` calls `even(T)`, the instance `even__i`
   causes `odd__i`, whose call names `even__i` again and causes nothing,
   so the first definition breaks the cycle. The error carries a name
   (13.6): the limit is a rule of the language, which says whether a
   source is valid, and not a translation limit of `typec`.

   The nesting limit bounds a chain and not what one use causes in
   all. Where each of 25 generic functions calls the next as

   ```c
   generic(T) void g0(T *p) { const T *q = p; g1(&p); g1(&q); }
   ```

   calls `g1`, for `T *` and for `const T *`, no chain holds more
   than 25 instances, and one use of `g0` causes 2^25 - 1 of them, no
   two of one type. Generic types that each hold two applications of
   the next do the same. So `typec` also bounds what a translation unit
   costs it, by two bounds: the *instance budget* of 16777216 bytes on
   what the front end reads for instances, and the *output limit* on
   all the C text that it writes for the unit.

   Both count bytes of text, because an instance is text that grows
   with its arguments as well as with its definition, and so is the
   unit's own lowered text. Where an instance differs from the
   definition, lowering writes a name (10.3): the typedef of an argument
   for a use of a type parameter, the name of an instance for an
   application or a call, and the names that a variant instance derives
   for its tag and for each of its constructors (10.1). A name holds the
   encodings of the arguments, and the line marker before a text holds
   the name of its file. The unit's own text grows in the same ways and
   in others: a copy of a deferred statement stands at each exit that
   runs it (section 6), each edit carries line markers that hold the
   presumed file name, and each enumerator of a variant holds the name
   of the variant. A count of definitions, of tokens or of constructs
   bounds none of this. Sources that read fewer than 524288 tokens of
   definitions for their instances show it (one x86-64 host). Thirteen
   lines, a tree of structures of 20 members over a tag of 4000 bytes,
   are 145 MB of text, which costs `typec` 2 s and 1 GB. Twelve lines
   with a variant of 200 constructors, each of them a name in every
   instance, are 226 MB, 5.5 s and 1.9 GB. Fourteen lines of aliases,
   each of which applies the one before it twice and so doubles the
   depth of a pointer, keep the front end reading for 12 s and write
   nothing. Without generics, 1700 defers in one function, each
   followed by a return that runs the copies of those before it, are
   66 KB of source and 205 MB of text, 14 s and 2.6 GB; 4000 type
   declarations after a presumed file name of 80 KB are 1.3 GB of text,
   13 s and 6.5 GB; and a variant whose name has 50 KB, with 5000
   constructors, is 252 MB, 9 s and 2.3 GB.

   `typec` counts the text where it makes it and holds each count to
   its bound:

   - Lowering charges the C text of the unit to the output limit as it
     makes it: each piece of moved text (13.4) when the piece is made,
     a token of the source or text of `typec`'s own, at least 32 bytes
     for a piece, which costs `typec` about a hundred bytes of memory
     whatever its text; the line marker of each run of pieces; the
     text, line markers and pragmas of each edit; and the unit's own
     text in full, first. Emission makes every piece and every edit,
     and charges it as it makes it, so the charge covers whatever
     lowering writes, the texts of instances, the copies of defers,
     the temporaries of tries and slices and the headers of
     `--emit-c-header` alike, and no list of constructs decides what
     is counted. The charge is at least what is written: the text of an
     edit that lowering moves into an instance is charged with the edit
     and again where it moves. A text that lowering builds from a list,
     such as the enumerators of a variant, is held to the limit item by
     item before it is built. The limit is 33554432 bytes and 256 for
     each byte of the preprocessed unit.
   - The front end counts what its reading gives the texts of
     instances, so that a source is refused before `typec` has read
     what lowering would refuse. Each time it reads the definition of a
     generic for an instance, to define the instance or to follow the
     chain of a definition check, it counts the bytes of the tokens of
     that definition, at least 32 for each, as reading a token costs
     as much whatever its length, and then the bytes of each name that
     the reading puts among them. The chain of a definition check is
     counted as a definition is, though lowering never writes its text.
     This count is held to the instance budget.
   - The front end counts the copies of deferred statements as well.
     It reads a deferred statement again at each exit of its scope,
     where lowering writes its copy and the check of 13.5 reads it, and
     those pairs of a defer and an exit grow with the square of the
     source before lowering makes any text: n defers, each followed by
     a return, are n(n+1)/2 copies. So reachability, which finds the
     exits, counts a copy for each scope that an exit leaves, when it
     finds the exit and before it records the pair, and stops at the
     first scope that the exit does not leave. A copy counts what
     lowering charges for it where each token of the deferred
     statement stays a piece of its own: each token as a piece, at
     least 32 bytes, and the two braces of the block that lowering
     writes the copy as. No stage then holds more pairs than the count
     lets through. The copies are text of the unit, not of its
     instances, so this count is held to the output limit, apart from
     lowering's charge, and not to the instance budget, which the
     copies of an ordinary unit pass: 3000 functions of three defers
     and twelve returns each count 24 MB of copies. The count refuses a
     unit that lowering would let through only where the edits of a
     deferred statement write its tokens as fewer pieces, as the name
     of an instance replaces an application.

   Type instances and function instances share each count. A count
   that would pass its bound ends the translation: the front end makes
   no further reading, lowering makes no further text, and `typec`
   writes no output. The error of the front end is reported at the
   application or call that needs the instance; its message names the
   instance and the budget and cites the application or call that
   began the chain, as that of the nesting limit does. The error of
   lowering is reported at the construct whose text would pass the
   limit, and that of the count of copies at the deferred statement
   whose copy would; each message gives the limit.

   A name is bounded as well: the encodings of the arguments of one
   instance hold at most 4096 bytes together, so the name of an
   instance is at most that and the name of its generic. An application
   or call whose instance would have a longer name is an error,
   reported there, and the message names the argument and the bound.
   Without the bound a name doubles with each line of
   `typedef pair(p0, p0) p1; typedef pair(p1, p1) p2;`, and the
   identifiers that `typec` hands the backend grow with it. The name of
   a type declaration or a generic function holds at most 255 bytes,
   and a longer one is an error, reported at the name. Every name that
   `typec` derives holds such a name: an enumerator of a variant holds
   the variant's, and an instance the generic's. Without the bound the
   parser, which claims each enumerator by its name (10.1), spends the
   length of the name times the constructors, the square of the source:
   89 KB of source that are a name of 50 KB with 5000 constructors took
   `typec` 4.9 s and 450 MB at its peak, nearly all of it the parser's.
   With it, an enumerator of a variant that is no instance is at most
   some 65 times the four bytes of source of its constructor (one of an
   instance holds the encodings as well, which their own bound and the
   instance budget limit), and 133 KB of source that are a variant of
   the longest name and 16000 constructors cost `typec` 0.5 s and 69 MB
   (one x86-64 host).

   The budget, the output limit and the bounds on encodings and names
   are translation limits of `typec` (C11 5.2.4.1) and no rules of the
   language, unlike the nesting limit: what they bound is the reading
   and the text of this compiler, the reading of its checks included,
   and a source is valid Type-C whatever they count. Their refusals
   therefore carry no code (13.6).

   *Provisional (P30).* The budget is between four and five times
   the text of a heavy unit of C++, which is the measure taken
   because no Type-C unit of that weight exists. A C++20 unit that
   uses the standard containers, regular expressions, futures,
   ranges and the filesystem instantiates 4424 class templates and
   2513 function templates (Apple Clang 21, `-ftime-trace`). The
   instance of a structure of two members is about 300 bytes of
   text, with its declaration, the typedef of its argument and its
   line markers, and that of a function of 152 tokens, the mean of
   the 82 functions of tomlc99 (their median is 72), about 900.
   Both sizes are estimates, and they make that unit 3.6 MB. The
   bound on encodings rests on no measurement of a Type-C program, and
   that on names, 2^8 - 1, above four times the 63 significant initial
   characters that C11 5.2.4.1 asks of an internal identifier, on none
   either.
   The output limit rests on the inputs of the test suite: of the 560
   units that it lowers, every one is charged less than the base, the
   most 32086171 bytes for 82 KB of source whose file name of 80 KB
   stands in
   400 line markers, and the instance texts that the front end lets
   through 27.9 MB at most; of those of over 100 KB, the most is 28
   times the source, for 20000 applications of a generic. A C unit,
   which lowering does not edit, is charged its own size. So the base
   is above every instance text that the tests let through and the
   factor nine times the largest ratio.

   A source that is written to reach the budget costs what the
   budget lets through, and the cost grows with the budget in
   proportion. On sources whose instance text is about the budget,
   `typec` takes 4 s and 450 MB for 16.6 MB that are 55292 small
   structures, and 4 s and 120 MB for 15.1 MB that are 511
   structures over a pointer 3900 levels deep. Text of that size
   which is long tags, the names of a variant's constructors or
   line markers takes under 0.5 s and 150 MB (one x86-64 host). A
   unit that stays under the limit gives the backend at most the
   limit of text and the fixed static assertions that end it. Half the
   budget of instance text,
   8.5 MB that are 65536 instances of a chain of functions in the
   form that 10.3 gives them, takes Apple Clang 21 5 s at `-O0` and
   33 s at `-O2` and GCC 16 23 s and 8 s, in 1.2 GB at most.

   The output limit bounds the text and the pieces that lowering makes,
   not the work that comes before them. Of the sources above that it
   refuses, the declarations in the long file take 0.4 s and 26 MB and
   the tree of variants 0.7 s and 58 MB. The count of copies refuses
   the defers before their pairs are made: 3400 defers, each followed
   by a return, are refused in 0.2 s and 28 MB, and 13000 in 0.6 s and
   88 MB. The costliest defers are those whose copies stay within the
   count, and their cost grows with the source, as the limit does: 580
   in one function are refused by lowering in 0.8 s and 97 MB, and 400
   functions of 120 defers of a null statement, each followed by a
   return, 1.5 MB of source, compile in 11 s and 1.8 GB. The 3000
   functions above, 950 KB of source, compile in 1.7 s and 235 MB (one
   x86-64 host).
8. *Provisional (P23).* The definition of a generic, type or function
   (section 7), is moved text: lowering writes it in each instance,
   where 10.3 places it, and the resolution property of 13.5 holds for
   it: what the definition names, and what it declares for itself,
   reads in each instance as it reads at the definition. A declaration
   that would change that is refused: the error is reported at the
   application or call that puts the instance there, and cites the
   declaration. The definition and every instance stand at file scope,
   so the declarations that can do so are those of file scope between
   the two. In

   ```c
   type handler(T) = struct { void (*call)(struct ctx *c, T value); };
   struct ctx { int depth; };
   handler(int) h;
   ```

   `struct ctx` in the definition is a type of the prototype's own
   scope (C11 6.2.1p4). In the instance `handler__i`, which is defined
   after the second line, it would be the structure of file scope, so
   the application is an error. In

   ```c
   type slot(T) = struct { void (*call)(int (foo), T value); };
   typedef char foo;
   slot(int) s;
   ```

   `foo` in the definition is the name of a parameter of type `int`. In
   the instance `slot__i` it would be the typedef name, and the
   parameter a function that takes a `char` (C11 6.7.6.3p11), so this
   application is an error as well. Rule 3 of 7.3 shows the property on
   a function, where a later declaration changes the type of what the
   body uses.

   Lowering does not write the definition at its own place. By the last
   clause of the property the definition therefore declares no name
   that is in scope after it, apart from its generic and, where that is
   a generic variant, its constructors, which lowering writes under the
   names of the instances (10.1, 10.3): the text that follows would
   lose any other declaration. Rule 4 keeps a tag with a body and an
   enumerator out of the definition of a generic type, which leaves the
   first mention of a tag. In

   ```c
   generic(T) struct pool *owner_of(T *p);
   void release(struct pool *p);
   ```

   the first line is the first to mention `struct pool`, and the second
   names that structure. In the lowered C the second line would be the
   first mention, and would declare a structure of its prototype's own
   scope. The first line is an error; with `struct pool;` before it,
   both lines use a tag that is already declared. A first mention among
   the members of a generic type is refused likewise, as that of `struct
   node` in `type link(T) = struct { struct node *next; T v; };`: C
   gives a tag that a member declares the scope around the structure. A
   name whose scope ends inside the definition, in a parameter list or
   in a block of a function's body, is declared in each instance as it
   is at the definition.

   The head of a generic function is the exception. An instance holds
   it twice, in its prototype and at its definition (10.3), so the
   return type and the parameter list of a generic function, with every
   parameter list nested in them, declare no type at all: no first
   mention of a tag stands there, and no specifier with a body, not
   even the untagged one that rule 4 gives a place in a generic type.
   In

   ```c
   generic(T) void put(struct item *it, T value) { /* ... */ }
   ```

   with no `struct item` declared before it, the prototype of `put__i`
   and its definition would each declare a `struct item` of its own
   scope, and the two would declare `put__i` with different types. The
   generic is an error; with `struct item;` before it, both name the
   structure of file scope.

   A universe name, a constructor and a type parameter are not written
   into an instance as the definition spells them: lowering writes names
   that cannot be hidden (13.5), so a declaration that hides one of them
   changes nothing, and `type named(T) = struct { str name; T value; };
   int str; named(int) n;` is valid.

Rationale for parentheses. `<` is ambiguous with less-than in C expressions.
Parentheses need no lookahead once `G` is known to be generic, and they
match the `VECTOR(int)` macro idiom that C programmers already use.

### 3.6 Universe types

```c
type option(T)    = | None | Some(T value);
type result(T, E) = | Err(E error) | Ok(T value);
```

Both are declared in the universe scope (2.3) and are ordinary generic
variants with the ordinary representation. The zero value of an `option` is
`None`. The zero value of a `result` is `Err` of a zero error, so storage
that was never assigned does not read as success. `try` (section 5) is the
only construct that knows `result`, and it means this type whatever the
scope declares under that name (5.1).

No generic type and no generic function (section 7) has a universe name
(2.3), whichever it is: `slice_sub` no more than `option`. The instances
of one named as a generic type of the universe scope would take the names
of that type's instances (10.3), and the rule covers every universe name
so that it lists none. Any other declaration may take such a name (2.3).

## 4. Matching

```c
long evaluate(const expr *e)
{
    match (*e) {
    case Number(n):
        return n;
    case Variable(name):
        return lookup(name);
    case Add(left, right):
        return evaluate(left) + evaluate(right);
    case Multiply(left, right):
        return evaluate(left) * evaluate(right);
    }
}
```

```c
int cost;
match (*e) {
case Number(_):
case Variable(_):
    cost = 1;
    break;
case Add(_, _):
    cost = 3;
    break;
case Multiply(_, _):
    cost = 5;
    break;
}
```

`match` is a statement shaped like `switch`: it keeps `case`, `default` and
`break` and adds patterns, exhaustiveness and per-arm scopes. It has no
expression form; a C local assigned in each arm does that job.

### 4.1 Form

1. The scrutinee is an expression of variant type; qualifiers are ignored. A
   pointer is not dereferenced implicitly: write `match (*e)`. The match
   stands within the scope of the variant's declaration, as a constructor
   expression does (3.3), since it lowers to the same names.
2. The body is a sequence of *arms*. An arm is one or more labels, `case`
   *pattern* `:` or `default:`, followed by at least one block item. A label
   of the match stands directly in its body, never inside a nested
   statement.
3. A pattern names a constructor of the scrutinee's type, unqualified, with
   one sub-pattern per field; a `case` label that omits the field list of
   a constructor with fields is refused (only a single-pattern test may,
   4.6(2)). A sub-pattern is `_`, which matches without binding; a
   *binding*, which is an identifier where the field's type is no
   variant; or, where the field is a variant or points to one, a pattern
   for the constructor that the field holds (4.7). The type of the field
   decides which of these an identifier alone is (4.7 rules 2 and 3).
4. A binding declares a non-modifiable object of the
   field's type in the scope of its arm, initialised with a copy of the
   field.
5. Each arm is a block of its own. Its bindings and declarations are
   invisible to other arms and after the match, and a declaration may follow
   a label directly. The bindings and the block items of the arm are one
   scope: a block item that declares the name of a binding again is
   refused, as C refuses a second declaration in one block (C11 6.7p3),
   and a declaration in a nested block hides the binding. Text that
   must begin a compound statement, such as `#pragma STDC FENV_ACCESS
   ON`, may begin an arm, whether the arm binds or not (13.5).
6. An arm may carry several labels only if none of them binds:
   `case None: case Empty:` share a body. This is one arm reached two ways,
   not fallthrough.
7. The scrutinee is evaluated once. Its tag is read once, and so is each
   tag that a nested pattern asks for (4.7 rule 6); the bound fields of
   the selected label are copied, and then the arm runs. Assigning to
   the scrutinee inside the arm does not change the bindings.

Rationale for copied, non-modifiable bindings. A copy cannot dangle or
change when the scrutinee is overwritten, and it is an ordinary C local that
a debugger shows under its own name. Making it non-modifiable turns the
likeliest mistake, assigning to a binding in the belief that the payload
changes, into a compile error. Updating a payload is done by assigning a new
constructor value to the object; binding by reference is in section 12.
Pilot A updates a payload at 24 sites in about 9000 lines and keeps two
payloads behind pointers for it. That cost stands, because a reference to
a payload dangles when the object's tag changes and nothing short of a
lifetime tier (11.3) refuses that.

Constructors that share an arm. Rule 6 keeps a shared arm from binding, so
a family of constructors with the same fields that most code treats alike
is declared as one constructor with a field that tells its members apart:
`Binary(binary_op op, expr *left, expr *right)` rather than one
constructor for each operator. One arm then binds the operands for the
whole family, and a `match` or `switch` on `op` inside it handles the
operators that differ. Pilot A declared a constructor for each operator
and wrote 57 arms that repeat the body of another for it.

### 4.2 Exhaustiveness

1. Every constructor is covered exactly once: by one `case` label, or by
   `default`. A missing constructor is an error that names it; so is a
   constructor named twice. With nested patterns (4.7) this is the same
   rule over values: every value of the scrutinee's type is matched by
   a `case` label or taken by `default`, and every `case` label is
   selected for some value. A value that nothing takes is an error that
   names it as a pattern, `Err(Overflow)`; so is a label that is never
   selected, because the labels before it match all that it matches
   (4.7 rule 6).
2. There is at most one `default`, and it must cover at least one
   constructor: with nested patterns, take at least one value that no
   `case` label matches. It takes those values wherever it stands among
   the arms.
3. A `default` hides constructors added later, and nothing warns about
   it. In Pilot A written with the single-pattern test (4.6), 49 of 60
   matches keep a `default`, most of them matches of several cases whose
   `default` means "every other constructor"; a warning would flag that
   correct code far more often than a forgotten constructor. A `_` or a
   typed binding at a position of variant type (4.7) hides the
   constructors added to that position's variant in the same way.
4. `match` accepts variants only. A C `enum` is not closed: its objects can
   hold values that are not enumerators.

### 4.3 Leaving an arm

A `switch` section may fall into the next one. A match arm cannot, because
the bindings of the next arm would be uninitialised. Type-C does not insert
an implicit `break`; it keeps C's explicit statements and requires them.

1. The end of every arm, including the last, must be unreachable (4.4). In
   practice an arm ends in `break`, `return`, `continue`, `goto`, or a call
   to a function that does not return.
2. A `break` in an arm that is not inside a nested loop, `switch` or `match`
   leaves the match. `continue` continues the enclosing loop; a match is not
   a loop.
3. A label inside an arm may be the target only of a jump to a label
   (4.4) that is in the same arm. The GNU address of such a label, `&&L`,
   is a jump to it from every point and is therefore refused anywhere,
   also in the label's own arm.
4. `switch` is unchanged.
5. A `break` that leaves a match must end its arm, that is, be in *tail
   position* of the arm. A statement is in tail position if it is the last
   block item of the arm, the last block item of a block in tail position,
   either branch of an `if` in tail position, including a single-pattern
   test (4.6), or the statement inside a labelled statement or an `unsafe`
   block in tail position. A `break` inside a statement expression, or in
   the control of a statement (4.4), is never in tail position. A `break`
   that leaves a match from any other position is refused. The rule binds
   a `break` that is Type-C text (2.1); one that a C header brings into an
   arm is judged by 4.3(1) alone, on both readings of 4.4. It reads as
   leaving more than the arm: most often it left a loop from inside an
   `if` before the code became an arm, and here it would leave only the
   match, silently. An arm that is done early says so with `if` and
   `else`, whose branches are in tail position. In Pilot A all 65 `break`
   statements that leave a match are in tail position, so the rule finds
   nothing there.

The lowered code also ends every arm in a trap (13.5). If the analysis of
4.4 and the generated code ever disagreed, execution would stop there and
could not enter another arm's bindings.

Porting note. A `break` that ends an arm leaves only the match, and rule
5 has nothing to say about it. So C code in a loop of the form
`if (k == A) { f(); break; }` changes meaning when it becomes the arm
`case A: f(); break;`: the loop goes on. The port keeps the `if`, as a
single-pattern test in the loop (4.6), whose `break` leaves the loop, or
leaves the loop from the arm with `goto` or `return`.

### 4.4 Reachability

Rule 4.3(1) needs a definition on which every implementation agrees. It is
syntactic and conservative, in the manner of the Java and C# rules, and
does not evaluate conditions other than constants. Rule 1 of section 6
reads from the same definition which blocks have an end that lowering
treats as an exit.

A statement *can complete* as follows.

| Statement | Can complete |
| --- | --- |
| `break`, `continue`, `return`, `goto`, GNU computed `goto *e` | No. |
| Expression statement | Yes, unless it is a call to a function declared `_Noreturn` or with the GNU `noreturn` attribute, or to a builtin that GCC or Clang declares noreturn: `__builtin_trap`, `__builtin_unreachable`, `__builtin_abort`, `__builtin_exit` (GCC only) or `__builtin_longjmp`. |
| Declaration, `defer`, `try` in any form | Yes. |
| `asm`, GNU `asm goto` included | Yes. |
| Block, arm body | If it is empty, or its last item is reachable and can complete. An item is reachable if it is first, if the item before it is reachable and can complete, or if it carries or contains a label, by the rule below. |
| `if (c) S` | Yes. |
| `if (c) S1 else S2` | If `S1` or `S2` can. |
| `while (c) S`, `for (..; c; ..) S` | Yes, if `c` is present and is not a non-zero constant, or if a reachable `break` leaves the loop. |
| `do S while (c);` | If a reachable `break` leaves the loop; or if `c` is not a non-zero constant and `S` can complete or contains a reachable `continue` of the loop. |
| `switch (e) S` | If it has no `default` label, or a reachable `break` leaves it, or `S` can complete. |
| `match` | If a reachable `break` leaves it. |
| Labelled statement, `unsafe` block | As the statement inside. |

An item contains every label that lies within it, except a named label
inside a match arm within the item, which by 4.3(3) only a jump in that
arm reaches, a label in the body of a block literal, which is a function
of its own, and a `case` or `default` label of a `switch` within the
item. Such a label belongs to the innermost `switch` around it (C11
6.8.4.2p4) and is reached only through that `switch`'s controlling
expression, so it counts for the items between it and the `switch` body
and for none that contains the `switch`. In `switch (n) { default: return
1; { case 2: ; } }` the block after the `return` is reachable and the
`switch` can complete.

The rules that say which labels control may jump to, 4.3(3) and rules 4,
5 and 10 of section 6, read *jump to a label* and *target* as follows. A
`goto L` is a jump to a label, and its target is `L`. A GNU `asm goto`
is one whose targets are all the labels it lists. A `switch` is one
whose targets are the `case` and `default` labels that belong to it. A
computed `goto *e` is one whose targets are the labels whose address the
function takes.

The GNU address of a label, `&&L`, has two readings. The rules that
ask what may reach a label, 4.3(3) and rule 5 of section 6, read it as
a jump to `L` from every point of the function, because a computed
`goto *e` at any point may be given that address. Rules 4 and 10 of
section 6 do not ask where a jump goes. Each refuses jumps by their
kind, whatever their targets: rule 4 every `goto`, `goto *e` and
`asm goto` that is written in a deferred statement, and rule 10 every
`goto *e` and `asm goto` in the scope of a `defer` statement. To them
`&&L` is no jump: the computed `goto *e` that is given the address is
the jump, and it is refused where it stands.

*Provisional.* The first reading refuses the address of a label that
stands in a match arm or in the scope of a `defer` statement even where
no `goto *e` is ever given that address, as none is given the one that
the `_THIS_IP_` of the Linux kernel takes. Pilot B counts those
refusals (plan, Stage 2). A count that matters would make `&&L` a jump
only in a function that holds a computed `goto *e`; the default is the
reading as stated.

A constant here is an integer constant expression that the front end can
evaluate (13.3). A statement expression of the GNU profile is treated as
the block it contains: a `break`, `continue`, `goto` or label inside it
counts for the statements around it. A `break` leaves the innermost
loop, `switch` or `match` around it and a `continue` the innermost loop;
the parser records which, so that the analysis reads the answer from one
place.

A statement's *control* is every expression or declaration that it holds
outside its body, the body of an `if` being both of its branches: a
condition, the clauses of a `for`, the controlling
expression of a `switch`, the scrutinee of a `match`, the operand of a
single-pattern test (4.6). A `break` or `continue` in a statement
expression in the control, which no loop, `switch` or `match` within that
expression takes, is not in the body, and what it leaves depends on when
the control is evaluated.

Control that is evaluated once, before the body, stands where a
statement just before its own statement would: the jump goes to the
loop, `switch` or `match` around that statement. GCC and Clang read the
condition of an `if`, the first clause of a `for` and the controlling
expression of a `switch` so. typec gives the scrutinee of a `match` and
the operand of an `if` test the same meaning, and lowers each to a
declaration before the statement it generates (13.5).

Control that is evaluated again for each iteration makes the jump
*disputed*: the condition of a `while` or `do` and the condition and
step of a `for`. Clang takes a disputed jump in a C loop to leave that
loop, GCC the statement around the loop, and GCC refuses it where there
is none (GCC 16, Apple Clang 21). Type-C text refuses a disputed jump. C
text keeps it, except in a deferred statement or in the scope of a
`defer` statement (section 6 rule 10), and the backend picks its target.
The parser records every statement that a backend may take, and the
analysis lets each of them complete. An arm that holds such C text,
which a header included in the arm brings, therefore passes these rules
only if its end is unreachable on both readings. The operand of a
`while` test is evaluated for each iteration too, but nothing disputes
it: the lowering evaluates it in the body of the loop it generates
(13.5), so both backends take a jump there to leave that `while`, in
Type-C text and C text alike. Whether a jump is Type-C text is decided
by its `break` or `continue`, as for every other token.

An arm that the rules reject but that cannot in fact fall through is
fixed by adding the `break` the rules ask for.

### 4.5 Invalid tags

Matching a value whose tag is none of its constructors *traps* (10.5). Such
a value comes only from code that writes the bytes of the object behind its
type (C code, or Type-C code that uses casts, unions or `memcpy`) or from
an uninitialised object. The check is present in every match, including
one with `default`: a `default` arm receives real constructors only.

A single-pattern test (4.6) makes the same check: a value whose tag is
none of its constructors traps and does not fail the test. A failed test
stands where a `default` arm does, so it too receives real constructors
only, and a match of one `case` and a `default` keeps its check when it
is written as a test.

With nested patterns (4.7) the check is made at every tag that
selection reads: that of the scrutinee, and that of each position below
it where a label names a constructor and selection reaches that label.
A field that a label binds or matches with `_` is not read, so an
invalid tag inside it does not trap in this match. It traps in the
match that opens the bound value.

`try` abbreviates a match and makes the check as well; rule 2 of 5.1
says what it traps on.

### 4.6 Single-pattern test

```c
if (case Number(n) = *e)
    return n;

/* type list = | Nil | Cons(long head, list *tail); */
while (case Cons(head, tail) = *l) {
    sum += head;
    l = tail;
}
```

A single-pattern test asks whether a variant value holds one constructor
and binds that constructor's fields if it does. It is the selection step
of a `match`, written as the condition of an `if` or a `while`: the test
*succeeds* where a match on the operand would select `case` *pattern*,
*fails* where it would select another arm, and traps where the
match would trap (4.5). The statement it controls is C's `if` or `while`
and not an arm.

1. The forms are `if (case P = e) S`,
   `if (case P = e) S else S2` and `while (case P = e) S`. The test is
   the whole condition and stands nowhere else: not in a `for` or a `do`,
   and not parenthesised, negated or joined with `&&` or `||`, since
   `case` begins no C expression. There is one pattern; a test of several
   constructors is a `match` whose labels share an arm (4.1(6)).
2. The operand `e` is an expression that extends to the closing
   parenthesis and obeys 4.1(1) as a scrutinee does: it has variant type,
   and a pointer is not dereferenced implicitly. So `case P = e && c`
   reads `e && c` as the operand and is refused, because that is not a
   variant. The pattern `P` is that of a `case` label (4.1(3)): one
   constructor of the operand's type, unqualified, with one sub-pattern
   per field. In a test, and only there, a constructor with fields may
   also be written without its field list, `case Str = tok->kind`: the
   test then binds nothing of that constructor, as if each of its
   fields were `_`. The pattern nests as that of a label does, and a
   field list may be left out at any depth of it (4.7 rule 9).
3. Each time the condition is evaluated, once for an `if` and before
   every iteration of a `while`, the operand is evaluated once and its
   tag is read once, as is each tag that a nested pattern asks for
   (4.7 rule 9). On success the bound fields are copied and then `S`
   runs, as an arm does (4.1(7)); on failure nothing is bound, and `S2`
   runs or the loop ends.
4. A binding is the object of 4.1(4): non-modifiable, initialised with a
   copy of the field. The bindings and `S` are one scope, as an arm and
   its bindings are (4.1(5)): where `S` is a compound statement they
   belong to its block, so a declaration there that redeclares a binding
   is refused, and one in a nested block hides it. A match of one arm
   written as a test therefore keeps its meaning. Text that must begin
   a compound statement may begin a compound `S`, as it may begin an
   arm (4.1(5)): `S` is written as it stands, after the bindings
   (13.5). The scope ends with `S`: a binding is not visible in `S2`
   or after the statement, and a `while` makes its bindings anew for
   each iteration.
5. `S` and `S2` are not arms, so 4.3(1) and 4.3(2) do not apply: either
   may complete, and `break` and `continue` in `S` and `S2` alike mean
   what they mean in a C `if` or `while`. A `break` in the `S` of an
   `if` goes to the loop, `switch` or `match` around the `if`, and where
   that is
   a match 4.3(5) applies to it, as to every `break` that leaves a match.
   One in the `S` of a `while` leaves that `while`, and `continue` there
   evaluates the test again. For 4.4 the test is a condition that is not
   a constant, and its operand is control: a jump in a statement
   expression there goes to the loop, `switch` or `match` around an
   `if`, as one in the scrutinee of a match does, and leaves a `while`
   test's own loop.
6. A successful test is the only way into `S`, since nothing else
   initialises the bindings: 4.3(3) holds for `S` as for an arm, whether
   or not the pattern binds, and the label rule of 4.4 treats `S` as one.
   `S2` has no such limit.
7. The test puts no requirement on the other constructors, and 4.2 does
   not apply. A constructor added later fails the test, as it would reach
   a `default`.

Rationale. In Pilot A 52 of 100 matches have one `case` and a `default`,
and the port wrote 20 predicate functions and 9 accessor functions, the
accessors with an `unreachable()` default, only to ask whether a value
holds one constructor (`WRITEUP.md`, P4, at commit 9898ecb of the pilot's
repository). A test that binds also joins the question to the read it
guards, which a predicate followed by an accessor does not. Every rule
above is a rule of `match` or of C's `if` and `while`; the form adds only
the place where a pattern may stand. `S` is not an arm because the
statement of a C condition may complete and may leave a loop around it
with `break`, and in the pilot a `break` ported into an arm left the
match instead of the loop.

The form stays a condition and not an expression. Pilot A written with
the test (Step 12) has 74 tests, and 92 tag tests it does not fit: 30
negated, 39 joined with `&&` or `||`, 17 in a `for` condition, 6 used as
a value. None of them binds a field, so each stays a call of a predicate
whose body is one test, while a test that is an expression would need
binding scopes across `&&`, `||` and `!`. Without a field list a test
that binds nothing does not repeat its constructor's arity at every
site; in a `case` label the full pattern stays, so that a label always
shows what an arm binds.

### 4.7 Nested patterns

```c
/* type eval_error = | DivByZero | Overflow; */
match (eval(e)) {
case Ok(value):
    printf("%d\n", value);
    break;
case Err(DivByZero):
    printf("division by zero\n");
    break;
case Err(Overflow):
    printf("overflow\n");
    break;
}

/* type expr = | Num(int value) | Add(const expr *l, const expr *r); */
match (*e) {
case Add(*Num(a), *Num(b)):
    return a + b;
case Add(l, r):
    return evaluate(l) + evaluate(r);
case Num(value):
    return value;
}

/* option(result(int, eval_error)) next(void); */
while (case Some(Ok(v)) = next())
    sum += v;
```

A sub-pattern may be a pattern of its own. It asks which constructor a
field holds, as a label asks of the scrutinee, and its sub-patterns ask
the same of that constructor's fields. Labels with nested patterns can
overlap, so this section says which label a match selects. It does so
with one construction, the selection tree of rule 6, and exhaustiveness
(4.2), the tags that are checked (4.5) and the lowered form (13.5) are
all read from that tree. A match without a nested pattern has a tree of
one node, for which 4.1 to 4.6 say everything.

1. **Positions.** A *position* is the scrutinee, a field of a constructor
   at a position, or the object that a pointer field points to. A
   sub-pattern stands at the position of the field it is written for,
   and the type of the field is the type of the position.
2. **The type of a position decides what stands there.**

   | Type of the position | Sub-patterns |
   | --- | --- |
   | A variant | `_`; a *constructor pattern*, `C` or `C(...)`; a *typed binding*, `T x` |
   | A pointer to a variant | `_`; a binding, `x`; `*P`, where `P` is a constructor pattern |
   | Any other type | `_`; a binding, `x` |

   A variant is a type that 4.1(1) accepts for a scrutinee. A type
   parameter of a generic function is an opaque type and no variant
   (7.1 rule 2): a field of that type takes a binding, in the definition
   and so in every instance. A sub-pattern that its position does not
   list is an error, which names the type of the position. A constructor
   pattern is written as the pattern of a label is and obeys 4.1(3) at
   its own position: it names a constructor of that position's variant,
   unqualified, with one sub-pattern for each field.
3. **An identifier alone at a position of variant type is a constructor
   pattern** and never a binding. It names a constructor of the
   position's variant whatever identifiers are visible, as the
   identifier of a label does and as an unqualified constructor does in
   an expression (3.3). One that names no constructor of that variant is
   an error, which names the identifier and the variant and says how a
   field is bound (rule 4). A misspelled constructor is therefore
   refused: it cannot become a binding that matches every value.
   The parser does not know the type of a position, so it declares an
   identifier alone in the scope of the arm wherever it stands, and
   typing then reads it as a constructor or a binding. A constructor
   declares nothing: a use of its name in the arm is the constructor
   where a target type resolves it (3.3), and an error that names the
   qualified form `T.C` everywhere else. Where the two readings would
   differ, the program is refused, never compiled to other code.
   *Provisional:* no ported program yet shows whether an arm uses such
   a name with no target type often enough to want it read as the
   constructor there; porting the examples of 4 and 5 settles it, and
   the error is the default.
4. **A typed binding binds a field of variant type whole.** `T x` is the
   binding of 4.1(4): an object `x` of the field's type, initialised
   with a copy of the field. `T` is a typedef name or a type application
   that denotes the type of the position, as the `T` of a qualified
   constructor is (3.3); a `T` that denotes another type is an error,
   since the binding converts nothing. It is written at a position of
   variant type and nowhere else: at every other position the
   identifier alone is the binding, and each position has one way to
   bind. What follows the type tells a typed binding from a constructor
   pattern: an identifier follows `T`, and `,` or `)` follows a
   pattern. No visible name changes that reading, so a constructor
   that has the name of a type is still written `C(...)`.
5. **`*P` follows a pointer.** At a position whose type is a pointer to
   a variant, `*P` matches where the object pointed to matches the
   constructor pattern `P`. Selection reads the tag of that object as a
   `match (*f)` in the arm would, where `f` is the field: the variant is
   complete there, and the pointer points to an object of it. It reads
   the tag only where rule 6 reaches the sub-pattern; a null or invalid
   pointer that selection follows is undefined behaviour, as it is in
   that match, and checked text traps on a null one (11.2 rule 1). The
   pointed-to type is not volatile-qualified or atomic: selection and
   the bindings read the object in place at separate moments, and a
   `match (*f)` in the arm, which copies such an object (13.5), serves
   it. A pointer is never followed without the `*`, as a scrutinee is
   not (4.1(1)). A binding at this position, which names the pointer,
   does not have the name of a constructor of the pointed-to variant:
   `case Cons(head, Nil):` is an error, and is written `*Nil` or with
   another name.
6. **Selection.** A sub-pattern *matches* a value as follows: `_`, a
   binding and a typed binding match every value; `C(p1, ..., pn)`
   matches a value that holds `C` with fields that `p1` to `pn` match;
   `*P` matches a pointer to an object that `P` matches. A match
   selects **the first label in source order whose pattern matches the
   scrutinee**, and its `default`, wherever that stands among the arms,
   where no label does.

   Selection finds that label by reading tags. It takes the labels in
   source order. For a label it reads the tags that the label's
   constructor patterns ask for, in the order in which the label
   writes them, and gives the label up at the first tag that holds
   another constructor. It reads the tag of a position at most once: a
   later label that names a constructor at a position already read is
   judged by the tag that was read. The first label that is not given
   up is selected.

   Laid out by what each tag can hold, these steps are the *selection
   tree* of the match. A node reads the tag of one position and has a
   branch for each constructor of that position's variant; a leaf is a
   label, the `default`, or, where the labels have run out and there
   is no `default`, nothing. Every branch can be taken, since every
   constructor has values, so a leaf stands for at least one value of
   the scrutinee. The tree is the one statement of what a match does,
   and four things are read from it and decided nowhere else:

   - **What is missing (4.2 rule 1).** A leaf that is nothing stands
     for values that no label matches: constructors that no label
     names at a position share a leaf, and the leaf has a value for
     each constructor of the branch into it. The error names these
     values in the tree's order, each as a pattern that a label could
     hold, with the constructors on the way to its leaf and `_` at each
     position that selection did not read: `Err(Overflow)`,
     `Add(*Num(_), _)`. A branch above the leaf of several constructors
     is named by its first. The error names at most eight values and
     gives the count of the others, as in `and 12 more`, so the checks
     read the tree in time linear in its size and the error stays
     short however many fields and constructors the values have.
     Where the one leaf of nothing is a branch of the root, its
     constructors are named as constructors of the scrutinee's variant,
     so a match without nested patterns reports what 4.2 says.
   - **What is never selected (4.2 rules 1 and 2).** A label that is no
     leaf matches no value that the labels before it leave, and is an
     error at that label; so is a `default` that is no leaf. This is
     the useless clause of Maranget (section 17, reference 9), found
     exactly, because every branch of the tree can be taken.
   - **What is checked (4.5).** A tag traps where a node reads it and it
     is no constructor's. Selection reads no other tag.
   - **What runs (13.5).** The lowered form is the tree, written as
     `switch` statements.

   Selection runs no code of the program: a pattern holds no
   expression. So the order of the reads shows in two ways only, an
   invalid tag that traps and a pointer that `*` follows. In
   `case Pair(Left, _):` before `case Pair(_, *Leaf(n)):`, the second
   field of a value whose first field holds `Left` is never followed.
7. **Bindings.** 4.1(4) to 4.1(7) hold at every depth. A binding is an
   object in the scope of its arm, whatever the depth of its field. The
   bindings of the selected label are copied after selection and
   before the arm runs, and nothing is copied for a label that was
   given up. A label that binds at any depth shares its arm with no
   other label (4.1(6)), and two bindings of one label have different
   names, since they are declared in one scope (4.1(5)).
8. **Scope.** Each constructor pattern stands within the scope of the
   declaration of its position's variant, as the match does within
   that of the scrutinee's (4.1(1)): it lowers to the names that the
   declaration claims.
9. **In a single-pattern test.** The pattern of a test (4.6) nests as
   that of a label does. The test succeeds where its pattern matches
   the operand and fails elsewhere; selection reads the tags that the
   pattern asks for, in the order of rule 6, and stops at the first
   that holds another constructor. A constructor with fields may be
   written without its field list at any depth of a test's pattern
   (4.6(2)), and at no depth of a label's.
10. **The bounds on selection.** *Provisional (P32).* Building the
    selection tree of one match or test (rule 9) takes at most 4194304
    steps, and the tree is at most 127 nodes deep, counting the root and
    the nodes on one path to a leaf. A step is a label that a node looks at to sort
    it by the constructor it names there, a constructor of the node's
    variant that the node sorts into a branch, or a look, below a
    branch, at the next test of a label that the branch can keep: one
    that names the branch's constructor at the node, or one whose next
    test reads another tag, which every branch keeps. A match or a test
    that needs more steps or a deeper tree is refused where the bound is
    passed. These are translation limits of `typec` (C11 5.2.4.1) and
    no rules of the language, so the refusals carry no name (13.6). Without the
    step bound a few lines can ask for a tree that doubles with each
    field, since a label that several branches leave possible is a
    leaf in each; and a small tree can ask for much work, since each
    branch of a node looks at every label that asks for another tag
    first. The checks build the tree before any text is made, so the
    output limit does not hold that work (3.5 rule 7). The count bounds
    it, and the size of the tree with it, since each branch costs a
    step; to keep that so, a step takes time that grows neither with
    the depth of the positions it compares nor with the names of the
    constructors, so selection names each position by a number and
    each constructor by its index in its variant, and the checks that
    read the tree take time linear in its size. A match without nested
    patterns, of L labels over as many constructors, takes about 4L
    steps. The depth bound holds lowering: it writes each node as a
    `switch` nested in the branch above it (13.5), one brace deeper,
    and Clang's default bracket depth is 256, of which 127 leaves room
    for the nesting around the match; GCC sets no such limit. C11
    5.2.4.1 names 127 nesting levels of blocks but counts a `switch`
    and its body as two, so a tree near the bound nests deeper than
    that minimum.

Rationale for deciding by the type of the position. An identifier in a
sub-pattern could be a binding or a constructor without fields. A rule
that looks the name up, a constructor if the variant has one and a
binding if not, turns every misspelled constructor into a binding that
matches all values, and turns a correct label into one when the
constructor is renamed in its type: `case Err(DivByZero): return
Err(DivByZero);` followed by a `default` still compiles after the
rename and then returns every error. Checks on top of the lookup, that
a later label is never selected or that a binding goes unused, catch
some of these and not that one. Here no lookup decides. At a position
of variant type an identifier is a constructor, and at any other type
it is a binding, so the one thing that settles the reading is the type
of the field, which is also what gives an unqualified constructor its
meaning in an expression (3.3). The pattern `Err(DivByZero)` then
matches exactly the value that the expression `Err(DivByZero)` makes.
The cost falls on binding a field of variant type whole, which names
the type, as C# and Java write a binding in a pattern. The field most
often bound so is the error of a `result`, where the error is a
variant and an arm hands it on (5.3). The rule holds for every
sub-pattern, also in a match that nests nothing. That an identifier
alone at a position of variant type is always a constructor, and that
a binding there writes its type, is the owner's decision and is not
provisional: it awaits no count. The pilots show what it asks of
written code. In Pilot A, at commit 323777e, none of the 400 bindings
in its 332 labels binds a field of variant type, since none of the 131
fields of its eight variants has one. In Pilot B, at commit 06d4eb8,
the eight labels with a field list are four `Ok(x)` and four `Err(_)`.
The counts are of the type declarations and `case` labels in the `.tc`
and `.tci` files of the two repositories.

Rationale for `*`. A variant holds itself only through a pointer (3.2
rule 5), so without a way through a pointer no nested pattern would
reach the second level of a tree. The `*` is required for the reason
of rule 3: at a pointer position an identifier alone is a binding of
the pointer, and a pattern that followed pointers unasked would make
`Nil` in `case Cons(head, Nil):` a binding that matches every tail.
With the `*` written, what follows it is a constructor and a wrong
name is refused. That a pointer is followed only where the `*` is
written is the owner's decision and is not provisional. The patterns
it serves are those over a variant that holds itself, the `expr` at
the head of this section and a list. Pilot A's tree does not gain from
`*`: its nodes are structures that hold a variant, and the fields of
that variant point to the structures. Two of its 131 fields point to a
variant, the links of a chain of designators.

Rationale for the name of a pointer binding. A label that leaves out
the `*`, `case Cons(head, Nil):`, would bind the tail under the name
`Nil` and match every list, which is the error that rule 3 keeps out
of a position of variant type. The last sentence of rule 5 refuses
it: a binding of a pointer does not have the name of a constructor of
the variant it points to. The refusal reads the constructors of that
one variant and costs a program a name for a binding. It decides no
reading, since an identifier alone at a pointer position is a binding
whatever its name, so a label that leaves out the `*` and also
misspells the constructor still binds.

Rationale for selecting the first label. Labels that overlap need an
order, and source order is the one a reader has. A `default` keeps the
meaning it has in a `switch` and in a match without nested patterns:
it takes what no `case` takes, wherever it is written, so moving it
among the arms changes no selection. A label that is never selected
is an error and no warning, as a constructor named twice is in a
match without nested patterns (4.2 rule 1): its arm is code that no
value reaches, and the label is most often one written after a wider
one that was meant to follow it. Reading a tag only when the first
label that is still possible asks for it makes the order of reads the
order a reader would follow, which matters where a read can trap or
follow a pointer, and it never reads a tag twice.

What a sub-pattern is not. An integer, character or enumeration
constant is no sub-pattern (section 12): an arm binds the field and
compares it. A constant position has no closed set of values, so every
match over one would need a `default`, and a C enumeration constant
fits any integer position, so the type of the position could not tell
a misspelled constant from a binding as rule 3 tells a constructor.
The three patterns at the head of this section need no constant.
There is no pattern that both binds a field of variant type and opens
it, no alternative inside a pattern, and no condition on a label:
labels that share an arm (4.1(6)) and an `if` in the arm do those
jobs.

## 5. Errors: `option`, `result`, `try`

```c
type parse_error = | EndOfInput | BadToken | OutOfMemory;

result(uint32_t, parse_error) read_number(reader *r)
{
    uint8_t tag = try read_byte(r);
    uint32_t n = try read_u32(r);
    if (tag != EXPECTED)
        return Err(BadToken);
    return Ok(n);
}
```

### 5.1 `try`

1. The operand of `try` has type `result(T, E)`, and the enclosing function
   returns `result(U, E)` with the identical `E`. Both are the `result` of
   the universe scope (3.6), also where a declaration hides that name.
   An operand of another type, or a function that returns another, is
   an error (`try-operand`), and so are two `E` that differ
   (`try-error-type`): there is no implicit conversion between error
   types. The two `E` are identical where their encodings are
   equal (10.3), qualifiers at every level of `E` included: it is the
   one comparison that says whether two instances are one type (3.5
   rule 3). An operand of type `result(int, const char *)` is an error
   in a function that returns `result(int, char *)`, and so is one of
   type `result(int, const void)` in a function that returns
   `result(int, void)`. A top-level qualifier of the operand's type or
   of the return type does not count, since `try` reads a value and
   returns one. A typedef name or an alias (3.1) of such a type is
   that type, and no distinct type is over one (3.4). The operand has
   no target type (3.3).
2. `try` evaluates its operand once and abbreviates a `match` on the
   value (section 4). In the arm of `Err(x)` the function returns
   `Err(x)` exactly as a `return` statement would, running the deferred
   statements that are active (section 6). The error `x` is read before
   they run: it is held in the temporary that takes the operand's value,
   and the `Err(x)` that the function returns is built from that
   temporary after they have run. No deferred statement can name the
   temporary, so the error path needs no temporary of a `return` (13.5).
   From the arm of `Ok(v)` the `try` expression has the value `v` and
   the type `T`. It is no lvalue, as the value of a call is none, and
   neither is a member of it (C11 6.5.2.3p3): where C asks for an
   lvalue, as the operand of `&`, `++` or `--` and as the left operand
   of an assignment, it is an error (`try-lvalue`). When `T` is `void`
   it is a void expression (C11 6.3.2.2), which stands where its value
   is discarded (5.2) or as the operand of a cast to `void`:
   `try e;`, `try e, n++;` and `c ? try e : try g();` hold one, and
   `x = try e;` is an error (`try-void`). When
   `E` is `void`, `Err` has no field (3.5 rule 6): no error is read, and
   the function returns `Err`. As in every match (4.5), a value whose
   tag is no constructor's, here neither `Ok` nor `Err`, traps (10.5)
   and does not take the error path.
3. `try` is a unary operator and binds as the other unary operators do
   (Appendix A): `try f() + try g()` adds two values,
   `(long long)try eval(l)` converts one, and `try r->next(r)` applies
   `try` to the call. An operand that is a conditional or an
   assignment stands in parentheses, `try (c ? f() : g())`: without
   them `try c ? f() : g()` applies `try` to `c`, which rule 1
   refuses where `c` is no `result` (`try-operand`).

   ```c
   n = g(x) + try f();                 /* f, then g */
   return fit((long long)try eval(l) + try eval(r));
                                       /* eval(l), eval(r), then fit */
   buf[len++] = try read_byte(r);      /* read_byte, then len++ */
   if (p && try check(p) > 0)          /* p; check where p is not null */
       use(p);
   ```

   **The holder.** A `try` stands in the expression of a statement or
   declaration that evaluates it once each time control reaches it.
   That statement or declaration is the *holder* of the `try`:
   * an expression statement;
   * a declaration that is a block item, in its initialiser, a braced
     list included. The declaration has exactly one declarator, and it
     declares an automatic object whose type is not variably modified:
     C evaluates the size expressions of a declaration before its
     initialiser (C11 6.7.6p3, 6.8p3), and the `try` is evaluated
     before both;
   * a `return` statement, in its operand;
   * an `if` or a `switch`, in its controlling expression; a `match`,
     in its scrutinee (4.1); an `if` whose condition is a single-pattern
     test (4.6), in the operand of the test.

   A holder holds any number of `try` expressions. Between the
   expression of the holder and a `try` stand only operators whose
   operand C evaluates as a value: the postfix, unary, cast and binary
   operators of C11 6.5.2 to 6.5.17, `sizeof` and `_Alignof` excepted,
   with the conditional, assignment and comma operators among them;
   parentheses; the braces of an initialiser list, of a declaration
   or of a compound literal, where the initialiser that holds the
   `try` is itself a `try` expression (`try-list`, below);
   the arguments of a constructor expression (3.3) and the
   operands of a slice operation (section 8); `__extension__`; and
   the arguments of a builtin function
   whose result the values of its arguments alone decide, which is the
   fact that the table of builtins holds for 7.1 rule 4 (13.3).

   **The order.** The `try` expressions of a holder are evaluated before
   the rest of it, in the order of the source, one that stands in the
   operand of another before that one. Each is evaluated whole, its
   operand and then its test, before the next begins: the error path of
   a `try` returns before a later `try` is evaluated and before
   anything else of the holder is. One that is an initialiser of a
   braced list is whole with a third step, the conversion of its value
   to the object that it initialises (*The initialisers of a braced
   list*, below). The rest of the holder is then
   evaluated as C evaluates it, each `try` standing for its value.

   The four operators that C sequences keep their order and their
   conditions. Where a `try` stands, at any depth, in the second
   operand of `&&` or `||`, in the second or third operand of a
   conditional operator or in the right operand of a comma operator,
   the first operand of that operator is evaluated with the `try`
   expressions, at its place in the order of the source and once. The
   `try` is then evaluated only where C evaluates the operand that
   holds it, and so is a first operand that itself stands in such an
   operand, as `b` does in `a && (b || try f())`. The rest of the
   holder reads of that first operand what the operator reads: whether
   it compared unequal to 0, and nothing of the left operand of a
   comma. The operands of the `try` expressions and these first
   operands are the *hoisted operands* of the holder.

   Three things follow from the order.
   * When a `try` takes the error path, the holder has evaluated its
     earlier `try` expressions and the first operands before them, and
     nothing else: `buf[len++] = try read_byte(r);` leaves `len` as it
     was, and `emit(out, pos++, try next(in));` leaves `pos`. Where two
     operands fail, the function returns the error of the one that the
     source writes first, under every backend.
   * It is one of the orders that C allows for the same expression
     with a call in place of each `try`. C leaves the operands of an
     operator and the arguments of a call unsequenced (C11 6.5p3,
     6.5.2.2p10): their parts may be evaluated in any order that
     keeps what C does sequence, which is of three kinds. An operand
     is evaluated before the operator that reads its value, and the
     arguments of a call before the call (6.5p1, 6.5.2.2p10): a
     `try` is evaluated before everything that reads it. The first
     operand of one of the four operators above is evaluated before
     its other operands: the four keep their order. And two things
     are evaluated whole, with nothing else of the function between
     their parts. One is the body of a called function (6.5.2.2p10),
     which the lowered code calls as the source does: in
     `f(g(), try h())` the order is `h`, `g`, `f`, which C allows
     whatever `g` and `h` do. The other is an initialiser of a
     braced list, which C evaluates before or after each other one
     of the list (6.7.9p23): an initialiser that holds a `try` is
     itself a `try` expression (`try-list`, below), which is
     evaluated whole, the conversion of its value included, so the
     order divides none. An expression that is right in every order
     of C is right in this one.
   * It is not the order of reading: `g(x) + try f()` calls `f` first.
     A holder that needs `g` first has a declaration for its value
     before it, as C code does that needs `g` before a second call.

   **The initialisers of a braced list.** An initialiser gives its
   object the value of its expression after a conversion to the
   object's type, the one that an assignment makes (C11 6.7.9p11),
   and C evaluates the initialisers of a list one whole after another
   (6.7.9p23). C does not say whether the conversion is part of what
   it evaluates whole. The design takes it to be: an order that
   completes each conversion with its initialiser is an order of C
   under either reading.
   So a `try` that is an initialiser of a braced list, of a
   declaration or of a compound literal, in parentheses or not, is
   evaluated in three steps before the next `try` begins: its operand,
   its test, and the conversion of its value to the type of the object
   that it initialises. The list then reads the converted value.

   ```c
   float a[2] = { try f(), try g() };  /* f, to float, g, to float */
   ```

   The conversion counts because it can have an effect. One between
   arithmetic types may raise a floating-point exception (C11 6.3.1.4,
   6.3.1.5, Annex F), which C makes a side effect (5.1.2.3p2 and its
   footnote) that a program under `#pragma STDC FENV_ACCESS ON` may
   read (7.6.1). Above, `f` and `g` yield a `double`: `f` stores 1 in
   `x` and yields `0x1.000001p0`, which no `float` holds, and `g`
   yields `x`, plus 2 where the inexact exception is raised
   (7.6.2.5). Where `x` is 0 and no exception is raised before the
   declaration, the list leaves 3 in `a[1]`. That is one of the two
   values that `{ f(), g() }` may leave, and 0 is the other, where
   the second initialiser is evaluated first. With both conversions
   after both calls the list would leave 1, which no order of C
   leaves.

   The step is taken where the conversion is from one arithmetic type
   to another, an enumerated type and `_Bool` among them (C11
   6.2.5p18), whatever the two types are: the rule keeps no list of
   the conversions that have an effect. For a bit-field the type is
   the one that declares it, and fitting an integer to the width is
   left to the list: it has no effect (C11 6.3.1.3; where the type is
   signed, both backends reduce the value and raise no signal, 13.5).
   No other conversion of an initialiser has an effect
   to keep in order. A pointer converts to another pointer type or to
   `_Bool` (C11 6.3.2.3, 6.3.1.2) and a `slice(T)` to `slice(const T)`
   (section 8 rule 5), which read the value and change no state; a
   structure, a union, a variant and a distinct type (3.4) convert to
   themselves alone. Those stay in the list.

   No other place has the step, because C evaluates no operand and no
   argument whole. The conversion of a value to the type of a
   parameter, of a constructor's field, of the left operand of an
   assignment, of an object whose initialiser stands in no braces, or
   to the return type (C11 6.5.2.2p7, 3.3, 6.5.16.1p2, 6.7.9p11,
   6.8.6.4p3) is made by the call, the constructor, the assignment,
   the declaration or the `return` that reads the value, in the rest
   of the holder. In `h(try f(), g())`, where `h` takes a `float` and
   `f` yields a `double`, C sequences the conversion after `f` and
   before the call of `h`, and leaves open whether it comes before
   `g` or after (6.5.2.2p10): `f`, `g` and then the conversion is an
   order of `h(f(), g())`. A holder that converts the value of its
   one `try` and evaluates nothing else, as `float x = try f();` and
   `return try f();` do, converts it directly after the test.

   **Where no `try` stands.** A `try` in any other place is an error,
   and typing gives it from one function of the tree, which finds the
   holder of a `try` and the operators between the two and refuses
   what the two lists above do not name. No place that holds an
   expression has a check of its own, so none can be missing, and an
   operator that the lists do not name is refused until it is added to
   them. The refusals have four names.
   * `try-loop`, *provisional (P34)*: the condition of a `while`, a
     `do` or a `for`, a single-pattern test that is the condition of a
     `while`, and the first and third clause of a `for`. A loop
     evaluates its condition and its third clause once for each
     iteration, and the `try` expressions of a holder are evaluated
     once, before it. The loop holds the `try` in its body:
     `for (;;) { if (!try more(r)) break; ... }`.
   * `try-declaration`: the initialiser of an object of static or
     thread storage duration, which is a constant expression, and a
     declaration of a variably modified type.
   * `try-list`, *provisional (P35)*: an initialiser of a braced
     list, of a declaration or of a compound literal, that holds a
     `try` and is not itself a `try` expression, in parentheses or
     not. In a list, a `try` is a whole initialiser or stands in the
     operand of one that is. C evaluates the initialisers of a list
     one whole after another, in an order that it leaves open (C11
     6.7.9p23, 5.1.2.3p3). An initialiser that is a `try` expression
     is evaluated whole with the `try` expressions of the holder,
     through the conversion of its value (*The initialisers of a
     braced list*, above), and every other one whole after them,
     which is such an order:
     `struct point p = { try coord(r), try coord(r) };` reads two
     coordinates in the order of the source. An initialiser that
     holds a `try` beside something else would be evaluated in two
     parts, with the `try` expressions of the later initialisers
     between them. Where `x` is 0, `set_two` stores 2
     in `x` and `read_x` returns it,
     `int a[2] = { (try set_two(), x = 1), try read_x() };` would
     leave 2 in `a[1]`, where the same list with a call in place of
     each `try` leaves 1, or 0 if the second initialiser is evaluated
     first. One `try` in the list is enough: after the `try` of
     `{ (try set_two(), x = 1), read_x() }` the backend chooses the
     order of `x = 1` and `read_x()`, and C allows no order that
     calls `read_x` between `set_two` and `x = 1`. The rule asks
     nothing about what else the initialiser holds, so it also
     refuses a cast of the value, as in
     `{ .len = (size_t)try read_u32(r) }`, where the order divides
     nothing that has an effect. P35 counts those. The conversion
     that the list itself makes of a value is no part of what the
     source writes in the initialiser, and the rule refuses nothing
     for it: `{ .len = try read_u32(r) }` stands.
   * `try-position`: every other place. Outside a function body. In a
     declaration of more than one declarator, where C sequences an
     earlier initialiser before the `try` (C11 6.8p4). In what C does
     not evaluate, or evaluates by a rule of its own: a constant
     expression, a type name, the operand of `sizeof`, `_Alignof` or
     `__typeof__`, an operand of `_Generic` or of
     `__builtin_choose_expr`, the last operand of a conditional
     operator that omits its second, whose first operand is also its
     value, and an argument of a builtin that inspects more than the
     values of its arguments, as `__builtin_constant_p` does, so a
     macro that tests its argument with one takes no `try`. In a
     statement expression, whatever the place of the `try` there: the
     holder would be a statement inside an expression, and the error
     path would return from inside the expression around it, where C
     does not say which of the other operands have been evaluated. In
     a deferred statement (rule 4). In a block literal, which holds no
     Type-C text (13.3, P24), where `try` is no word (2.3). In an
     attribute argument of Type-C text, which typing does not read
     (13.5): the one scan of unread text (section 6 rule 13) refuses
     the word there where no declaration hides it, as it refuses
     `defer`.

   The remedy is the same in each: a declaration of its own holds the
   `try`, and the place reads the object that it declares. The scan
   looks for no word in a `#pragma` line, so a `try` in one, as in
   `#pragma omp parallel if(try f())`, is a word of the pragma: it
   reaches the backend as an identifier that the lowered C does not
   declare, and what the pragma does with it is the backend's to say.

   **What a hoisted operand names.** Each hoisted operand is moved
   text: lowering writes it before the holder (13.5), and the
   resolution property of 13.5 holds for it (`try-name-capture`). Two
   consequences are particular to `try`. A hoisted operand names
   nothing that the holder declares before it: a declaration by its
   declarator or in its specifiers, any holder in the part of its
   expression that stands before the operand. C puts a declarator in
   scope in its own initialiser (C11 6.2.1p7), so in `int n = 0; {
   size_t n = try rd(&n); }` the source names the inner `n` and the
   lowered code would name the outer one. In `a[sizeof(enum { K = 5
   })] = try g(K);` the source names the `K` of the left operand, and
   the lowered code writes the operand where no `K` is declared yet, or
   an outer one is. And a hoisted operand declares no name that is in
   scope after it and no object or function with linkage, which is the
   third clause of the property on the operand. In `a[K] = try
   g(sizeof(enum { K = 5 }));` the source reads the `K` of `a[K]`
   where the operand has not yet declared one, and the lowered code
   would read the operand's, and store to `a[5]`.

   **What a hoisted operand makes.** An expression of C makes objects
   of two kinds, and C ends the life of each with a unit that
   lowering changes for a hoisted operand (13.5). A compound literal
   lives until the block that encloses it ends (C11 6.5.2.5p5), and a
   hoisted operand that is evaluated under a condition is written in
   a block of its own. A structure or union value that is no lvalue
   and holds an array, as the value of a call may, lives in a
   temporary object until the full expression ends (6.2.4p8), and
   every hoisted operand is written as a full expression of its own.
   The rest of the holder may read either object through a pointer
   that the operand hands on, in its value or in an object that it
   assigns. So a hoisted operand holds neither where the lowered code
   would end its life before the source does (`try-lifetime`).
   * A hoisted operand that is evaluated under a condition holds no
     compound literal. It is one that stands, at any depth, in the
     second operand of `&&` or `||` or in the second or third operand
     of a conditional operator. In
     `consume(c ? try wrap((int[]){7}) : NULL);`, where `wrap`
     returns `Ok` of its argument, the array lives in the source
     until the block that holds the statement ends, and in the
     lowered code until the `if` of the prelude does, before
     `consume` is called: GCC 16 at `-O2` then reads another value
     through the pointer (13.5). Under no condition, a hoisted
     operand is written in the block of its holder. A compound
     literal lives there as long as in the source, and longer where
     the holder is itself a block, as an `if` and a `switch` are
     (C11 6.8.4p3): `consume(try wrap((int[]){7}));` and
     `try send(s, &(struct msg){ .kind = Ping });` stand.
   * No hoisted operand holds an expression of array type that is no
     lvalue, a member of the value of a `try` excepted. Such an array
     is part of a temporary object, and its conversion to a pointer
     (C11 6.3.2.1p3) is the only way to a pointer into one, since `&`
     takes an lvalue. In `consume(try wrap(make().a));` and in
     `(p = make().a, try read_value(p));`, where `make` returns a
     structure that holds the array `a`, the source keeps the
     temporary object until the statement ends, and the lowered code
     until the hoisted operand does, before `consume` or `read_value`
     reads it (13.5). The array of a declared object stands:
     `struct s m = make();` before the holder, and `m.a` in it. The
     value of a `try` is in no temporary object of C: the prelude
     holds it in an object of the holder's block (13.5), so an array
     member of it stands in a hoisted operand as it does in the rest
     of the holder, `try g((try f()).name)`.

   **Pragmas.** No `try` stands in a holder that holds or directly
   follows a pragma line (`try-pragma`). A `try` is an error where a
   `#pragma` line, which is also how a `_Pragma` operator reaches
   `typec`, stands anywhere from directly before its holder, the
   labels of the holder included, to the end of the expression that
   holds the `try`: the final `;` of an expression statement, a
   declaration or a `return`, and the `)` that closes the controlling
   expression, the scrutinee or the test of the others. The holder is
   the statement or declaration above and no statement around it: in
   `do x = try f(); while (c);` it is `x = try f();`. Its labels are
   C's: an identifier label, and a `case` or `default` label of a C
   `switch`. The labels of a `match` arm (4.1 rule 2) are the arm's,
   so the stretch of a statement that begins an arm starts after them.
   13.5 gives the reason with the rule.

   The cost falls on three common forms. A macro whose expansion holds
   a `_Pragma`, such as one that wraps its argument in `_Pragma("GCC
   diagnostic ...")` to silence a warning in it, cannot be used in a
   holder, and its use takes a statement or declaration of its own. A
   bracket of pragmas around statements, `DIAG_PUSH ... DIAG_POP` or
   the `#pragma GCC diagnostic` lines that such macros stand for, puts
   a pragma directly before the first statement of the bracket and
   before the statement after it. And `#pragma STDC FENV_ACCESS ON` at
   the start of a compound statement or of an arm stands directly
   before its first block item. A `try` in such a statement or
   declaration is an error. A null statement, `;`, after the pragma
   takes the next statement out of the stretch, so `DIAG_PUSH; ...
   DIAG_POP;` refuses nothing. The clause is accepted without a count
   of its refusals: the source of Pilot B holds no pragma. It is a
   refusal, so relaxing it breaks no program that it accepts, and the
   Stage 3 library and the corpus count how often it refuses (section
   15, P8).
4. `try` cannot appear in a deferred statement.
5. *Provisional (P21).* A `try` is an error where one of these rules
   asks something of an unknown type (13.3): whether the type of the
   operand or the return type of the function is a `result`, and of
   which arguments, whether the type that a declaration holding the
   `try` declares is variably modified, whether a member of a
   value that is no lvalue, in a hoisted operand, is an array
   (`try-lifetime`), which no unknown type says, or to which type a
   braced list converts an initialiser that is a `try` expression of
   an arithmetic `T`. Typing also has no type for the object of such
   an initialiser where the object follows a position of the list
   that depends on a length or an index that `typec` does not compute
   (P16), and lowering has none to write where the type is an
   enumerated type whose integer type `typec` does not compute.
   Each is a point that needs the answer. Taking the type for one that
   passes would guess it, and the backend cannot make the check
   instead: it reads the lowered C, where the operand already stands
   before the size expressions of the declaration, and where lowering
   has written the type that the value is converted to, or none. The
   measurement of P21 counts these refusals.

Rationale for the order. *Provisional (P33).* C leaves the evaluation
order of operands and arguments unspecified and sequences `&&`, `||`,
`?:` and `,`, and C11 has no expression that can hold a `return`. Three
orders were weighed.

- C's own order, each `try` lowered where it stands as a statement
  expression of the GNU profile that returns on `Err`. Nothing moves,
  so the rules on what a hoisted operand names and makes, on a braced
  list and on pragmas would go, and a loop could hold a `try`. But the
  order is then the backend's,
  and the backends differ. With each `try` written so by hand, where
  `a` and `b` both fail, `two(try a(), try b())` returns the error of
  `a` under Apple Clang 21 and that of `b` under GCC 16, and
  `two(g(), try a())` calls `g` under Clang and not under GCC, at `-O0`
  and at `-O2` on x86-64. The errors of a program would depend on its
  compiler, and no test of them could run on both backends. The lowered
  code would also return from inside an expression, in a GNU form that
  both backends take under `-pedantic-errors` only after
  `__extension__` (2.4).
- The order of reading. To evaluate `x + try f()` left to right,
  lowering holds the value of every operand that stands before a `try`
  in a temporary, a plain name included, since it cannot know that `f`
  leaves `x` alone. Such a temporary has a type that lowering must
  write, and each kind of operand needs a form of its own or a refusal:
  a bit-field, an array, a function, a void expression, a variably
  modified type, a type that `typec` does not compute (P21), a member
  of a structure value whose life ends with the full expression (C11
  6.2.4p8), and an operand that C needs as an lvalue, as the left
  operand of an assignment is. Every one of those operands would be
  moved text as well.
- The `try` expressions first. Lowering holds values of three kinds, a
  `result`, the truth of a first operand and a value that a braced
  list converts to an arithmetic type, and names the type of each
  without reading the operand (13.5). The lowered code is the C that a
  programmer writes for a fallible call inside an expression: a
  declaration and a test before the statement, which is also what a
  `try` that stands in a declaration of its own lowers to. In
  `lvalue = try e;` the operand is evaluated before the left
  operand, as C++17 orders every assignment.

The third is the design. What it costs is the reader who expects the
order of reading where an operand before a `try` has a side effect,
and P33 says what would settle that.

Rationale for the loops. *Provisional (P34).* The condition of a
`while` or of a `for` could be lowered as a test and a `break` that
begin the body, which moves the whole condition into the body and makes
it moved text of a second kind. The condition of a `do` and the third
clause of a `for` are where `continue` jumps to, and evaluating a `try`
there takes a label and a rewrite of each `continue` of the loop. The
refusal costs one line in the loop, and relaxing it breaks no program
that it accepts.

Rationale for the lifetimes. A prelude is several full expressions,
and a condition of it is an `if`, whose branch C makes a block in
braces or without them (C11 6.8.4p3). Two forms would keep the objects
that `try-lifetime` refuses. A prelude without an `if` writes an
operand under a condition as an expression statement of the holder's
block, `__tc_c0 ? (void)(__tc_t0 = (e)) : (void)0;`, and tests it
under the same condition, `if (__tc_c0 && __tc_t0.tag != R_Ok)`. A
compound literal then lives as in the source, and the prelude is no
longer the C that is written by hand, which P33 measures it against.
For a temporary object C has no such form: it lives to the end of its
full expression, so lowering would hold the structure in an object of
the holder's block, a temporary whose type it must write, with the
forms and refusals that the order of reading needs (above). Each
refusal costs a declaration, in a statement that makes such an object
beside a `try`. Neither refusal is provisional: one of these forms
lifts it and no measurement does, and lifting it breaks no program
that it accepts.

Rationale for the list. *Provisional (P35).* Three rules keep C's
order in a braced list. A list holds no `try`: it refuses
`{ try coord(r), try coord(r) }`, which reads a structure member by
member. An initialiser that holds a `try` is itself a `try`
expression: the rule asks nothing about the rest of the initialiser,
since the source writes none. An initialiser
that holds a `try` holds nothing else that has an effect: it admits
`(size_t)try read_u32(r)`, and takes a definition of what has an
effect, which a call, an assignment, a volatile object, a slice test
that traps (section 8) and a conversion that raises a floating-point
exception all do. The second is the design, and P35 says what would
widen it.

Rationale for the conversion of a list. What the source does not
write in such an initialiser, C adds: the conversion of the value to
its object. Left to the list, as the C written by hand leaves it, the
conversion of one initialiser would come after the calls of the later
ones, in an order that C gives no list, and the second consequence of
the order above would be false of one place. A refusal of every `try`
that a list converts would cost a declaration for
`{ .len = try read_u32(r) }` wherever `len` is not a `uint32_t`. A
refusal of those alone whose conversion has an effect would need the
list of such conversions. The prelude makes the conversion instead:
the programmer has no rule to learn, and the cost is one object for
each initialiser that is converted (13.5).

### 5.2 Results are not dropped

An expression of a `result` type whose value is discarded is an error: as
an expression statement, as the left operand of `,`, as the first or
third clause of `for`, as the expression of a `return` in a function
that returns `void`, and as a branch of a conditional whose type is
`void`, as GNU C makes one with a `void` branch. Handle the value with
`try` or `match`, store it, or discard it on purpose with a cast to
`void`. The value of an assignment is the value it stored, so
discarding it drops nothing: `r = f();` is no error.

C forbids `return f();` in a `void` function where `f` returns a value
(C11 6.8.6.4p1), but GCC and Clang accept it under
`-Wno-return-mismatch` and drop the value, so the rule refuses it as
it refuses `f();`. Where the value of a conditional is discarded, one
branch is a `result` and the other has a type that `typec` does not
know (13.3), the result is dropped whether the conditional is `void` or
not, and the conditional is an error (P21). Where its value is used, a
`void` conditional is an error of C.

An expression whose value is the value of the expression around it is
discarded where that one is: in parentheses, as the right operand of
`,`, as the association that a `_Generic` or `__builtin_choose_expr`
selects, and as the last block item of a statement expression (below).
So `_Generic(0, int: c ? f() : u);` is the error that `c ? f() : u;`
is, where `typec` does not know the type of `u`. Where `typec` cannot
tell which association a discarded selection selects (13.3), as in
`__builtin_choose_expr(__builtin_constant_p(n), f(), 0);`, each of its
associations stands where the selected one would, and one of a `result`
type is an error (P21), as the backend's choice may drop it. An
association that a selection which `typec` decides does not select is
not discarded, so a type-generic macro may name a function that returns
a `result` in one.

A `result` type is what rule 1 of 5.1 asks of an operand: an instance
of the `result` of the universe scope, under a typedef name or an alias
as well, with top-level qualifiers or without.

The value of a `try` is discarded as any other is. `try e;` where `T`
is itself a `result` type tests the outer result and drops the inner
one, and is an error; a declaration holds the `try` instead, and the
inner result is handled from the object it declares.

The rule goes by the position of the expression and not by whether it
is evaluated: `sizeof(f(), 1)` is an error where `f` returns a
`result`. A rule by evaluation would have to say which operands C
evaluates, which for `sizeof` depends on a variably modified type, and
a result dropped there is no more meant than one dropped elsewhere.

The last block item of a statement expression of the GNU profile,
labelled or not, when it is an expression statement, does not discard
its value, which is the value of the statement expression. The
statement expression is judged where it stands: `({ g(); f(); });` is
an error where `f` returns a `result`, and `x = ({ g(); f(); });` is
none. Every other expression statement in it discards its value, as
`g();` does, and as `f();` does in `({ f(); int y = 0; })`.

The rule binds Type-C text (2.1), judged by the first token of the
expression: some one token has to decide, and the tokens of an
expression come from more than one file only where an `#include` line
stands inside it. C text keeps C's meaning (2.2): C drops a structure
value without a word, and a header that C compiles as well means the
same in both. Only a Type-C declaration makes a value of a `result`
type, so C text holds one only where it is written against such a
declaration.

Type-C text holds no excess initialiser, one with no element or member
left to initialise, judged by its first token: GCC drops it with a
warning, which would drop the result of `struct p s = { 1, f() };`
unchecked, and C11 6.7.9p2 makes it an error of C already. The 0 of
`{0}` drops no result and gives any object its zero value (3.2 rule 7),
so it is none.

### 5.3 Other error conventions

An error of one type becomes an error of another through an ordinary
function and a `match`:

```c
/* type io_error = | NotFound | Denied | Failed(int code); */
match (open_file(path)) {
case Ok(opened):
    f = opened;
    break;
case Err(io_error e):
    return Err(io_to_app_error(e));
}
```

The error here is a variant, so the binding names its type (4.7 rule
4); an error of a C type, such as an `int` or an enumeration, is bound
by an identifier alone.

C functions that report failure through return codes, `errno` or null are
wrapped by ordinary Type-C functions that return a `result`. Errors are
values: nothing is allocated and nothing unwinds.

## 6. `defer`

```c
FILE *f = fopen(path, "rb");
if (!f)
    return Err(IoError);
defer fclose(f);
```

`defer` follows ISO/DIS TS 25755.

1. The *scope* of a `defer` statement runs from its end to the end of
   the enclosing block. `defer S` schedules the statement `S` to run
   when control leaves that scope: by reaching the end of the block; by
   `return`, `break`, `continue` or `goto` to a point outside the scope,
   which includes a `goto` back to before the `defer` statement; or by
   the error path of `try`. Lowering treats the end of the block as an
   exit where the block can complete (4.4), and writes a copy of `S`
   there (13.5). Where 4.4 judges that the block cannot complete, as
   one whose last item is a `return` or the block of a match arm (4.3
   rule 1), its end is no exit: lowering writes no copy of `S` there
   but a trap (10.5), the one that ends every match arm, and rule 8
   asks nothing of that place. If the analysis of 4.4 and the
   generated code ever disagreed, as over a constant that the front
   end and the backend fold differently or a call that only one of
   them takes not to return, execution would stop at the trap and
   would not go on past a cleanup that did not run.
   When several scopes are left together, their statements run in the
   reverse order of the `defer` statements. The body of a block literal
   is a function of its own (4.4): a `return` in it leaves no scope
   around the literal.
   `S` is any statement, a null statement included: `defer ;` is
   allowed and runs nothing. `S` is moved text, so it holds no block
   literal (13.5).
2. `S` runs at the exit and sees the values variables have then.
3. The operand of `return` is evaluated, and its value converted to the
   return type, before any deferred statement runs (13.5). The function
   returns the value that this conversion gave: a deferred statement
   that changes an object the operand read, or the rounding mode,
   changes nothing of it.
4. `S` cannot be left by `return`, `break` or `continue`, and `S`
   cannot contain `try`. `S` contains no `goto`, no GNU computed
   `goto *e` and no `asm goto`. Each is a jump to a label (4.4), and
   such a jump that stands in `S` may have no target outside `S`; it
   has none inside either, since `S` holds no identifier label (rule
   9). The three are therefore refused whatever they name, a `goto *e`
   also in a function that takes the address of no label. A `switch` in
   `S` jumps to its own `case` and `default` labels and is allowed. A
   loop inside `S` may use its own `break` and `continue`.
5. No jump to a label from outside `S` has a target in `S`, and none from
   outside the scope of a `defer` statement has a target in that scope.
   Section 4.4 says what is a jump to a label and what its targets are.
   The address of a label, `&&L`, is by 4.4 a jump to `L` from every
   point of the function. It is therefore refused, wherever it is
   written, when `L` is in the scope of a `defer` statement, and only
   then: a function that has a `defer` statement may take the address
   of a label that is in no such scope.
6. A loop body and a match arm are blocks: a `defer` in one runs when
   each iteration or arm is left.
7. `longjmp`, `exit`, `abort` and other functions that do not return leave
   without running deferred statements.
8. `S` is moved text, and the resolution property of
   13.5 holds for it: what `S` names reads, at each exit where `S` is
   copied (13.5), as it reads at the `defer` statement. A declaration
   that would change that at an exit is an error, in whichever block of
   the scope it stands, the `defer` statement's own included. An
   identifier in an attribute argument or a `#pragma` line of `S` is
   among what `S` names (13.5). In

   ```c
   int x;
   void f(void) { defer use(x); int x = 0; }
   ```

   the copy of `use(x);` at the end of the block would read the inner
   `x`, so the declaration of that `x` is an error. A binding named `x`
   in a match arm that holds an exit is refused in the same way. So is
   `__label__ L;` in a block that holds an exit, where `S` takes the
   address `&&L` of a label of the function: the copy at that exit
   would take the address of the local label. A declaration that has
   no exit in its scope reaches no copy and is allowed: in
   `{ defer use(x); { int x = 0; work(x); } }` the scope of the inner
   `x` ends before the one exit. An exit is the place where lowering
   writes the copy, and 13.5 says where that is for each kind of exit.
   The end of a block that cannot complete is none (rule 1): in
   `{ defer use(x); if (c) return; int x = 0; for (;;) work(x); }` no
   copy stands in the scope of the inner `x`, which is allowed. The
   error path of a `try` is an exit before the statement or
   declaration that holds the `try`, so that declaration is not in
   scope there:
   `{ defer use(x); { int x = try f(); } }` is allowed, since the copy
   stands before the declaration of the inner `x`. `S` is a block, as
   the substatement of an `if` is in C (C11 6.8.4p3), and each copy is
   written as one, `{ S }`: what `S` declares is in scope in `S` alone,
   at the `defer` statement as in each copy.
9. `S` contains no identifier label and no
   definition of an object with static or thread storage duration, and
   `S` declares no type. That leaves out a struct, union or enum
   specifier that has a body or declares its tag, and a Type-C type
   declaration, such as a variant that a block in `S` declares. A
   specifier declares its tag wherever it is the first mention of the
   tag, outside a declaration too: the cast `(struct s *)p` in `S`,
   with no `struct s` visible, declares `s` (C11 6.7.2.3p8) and is
   refused. `S` is copied to every exit (13.5): each copy would define
   the label again, would hold an object of its own, and would declare
   a type of its
   own, with the names it claims (10.1) and a layout set by the pragmas
   in force at its exit and not at the `defer` statement (13.5). A
   label declared with `__label__` is local to its copy and would not
   clash, and neither would an incomplete type; both are refused all
   the same, so that the rule has no exception. A declaration with
   `extern` defines no object and this rule allows it, though it
   declares an entity with linkage, which rule 8 refuses in `S`
   (13.5). A typedef whose specifier declares no type is allowed: the
   typedef itself names a type and declares none (C11 6.7.8p3). Since
   `S` is copied to every exit, a `#pragma` line in `S` is one of the
   pragmas that apply only to the statement after them or to their
   block, which 13.5 lists; one that sets state for the text after it,
   as `#pragma pack(push, 1)` does, would be set again by each copy.
   And since lowering removes the `defer` statement from its place, no
   `#pragma` line stands directly before it: a `#pragma GCC ivdep`
   there would apply to the statement after the `defer`, a loop that
   the source does not annotate. A `;` between them keeps the pragma
   on a statement of its own. Each copy is compiled under the pragmas
   in force at its exit, and those must be the pragmas in force at the
   `defer` statement. With

   ```c
   double r;
   void f(double x, double y, double z, int c) {
   #pragma clang fp contract(off)
     ;
     defer r = x * y + z;
     if (c) {
   #pragma clang fp contract(on)
       return;
     }
   }
   ```

   Clang at `-O2 -mfma` contracts the copy at the `return` to an FMA
   and the copy at the end of the block not. So the scope of a `defer`
   statement, from it to the end of its block or match arm, nested
   blocks included, holds only the pragmas that annotate the loop after
   them, which 13.5 lists. The pragmas there that are in force to the end of their block
   are left out, since a copy at a later exit of that block would be
   compiled under them. A loop pragma in the scope also stands directly
   before no exit, no end of the block and no statement or declaration
   that holds an exit, since the pragma would reach the copy that
   lowering writes there. A loop that holds an exit holds the copy at
   it. A `break` or `continue` that leaves only a loop or switch inside
   the scope is no exit, so a loop pragma may annotate that loop. The
   pragma lines of `S` are held to the rule on `S` above, and those
   before the `defer` statement are outside its scope.
10. Within the scope of a `defer` statement there is no GNU computed
    `goto *e` and no `asm goto`. Both are jumps to labels (4.4) that no
    deferred statement can precede: the first chooses its target when
    it runs, and the second jumps from inside the assembly. Neither
    there nor in `S` is there a disputed `break` or `continue` (4.4),
    in whichever text it stands: C text keeps a disputed jump
    elsewhere, and `_Defer` is a `defer` statement in C text too (2.3).
    The backend picks the statement that a disputed jump leaves, so
    the deferred statements that it runs, and whether it leaves `S`,
    would differ between backends.
11. A `defer` statement is a block item, as a declaration is (Appendix A):
    it stands directly in a compound statement or in a match arm, where
    it may follow the labels of the arm (4.1). It is not the substatement
    of an `if`, an `else`, a `switch`, a loop or a single-pattern test.
    It is not the statement of a labelled statement, a `case` or
    `default` of a `switch` included: write `case 1: { defer S; ... }`.
    It is not a block item of the compound statement of a statement
    expression. It does not stand in the statement `S` of another
    `defer` statement, at any depth of `S`: not as `S` itself, as in
    `defer defer g();`, and not in a block of `S`, a statement
    expression in `S` or a match arm in `S`. A `defer` statement,
    which C text writes too, as `_Defer` (rule 10), stands only in a
    function body. Outside one, only a block inside a statement
    expression could hold it, and it is an error wherever that
    expression stands: in the definition of a generic type (3.5), as in
    the size of an array member, in the head of a function, generic
    (section 7) or not, or in any other declaration of file scope, in C
    text too.
12. Lowering writes a `return` in the scope of a
    `defer` statement as a block (13.5), which ends where the `return`
    does. Its operand therefore declares no name that is in scope
    after it, and no `goto`, `break` or `continue` leaves it, as one
    in a statement expression would; a `return` that does either is
    an error. The first is the third clause of the resolution property
    of 13.5 on the operand. In `{ defer g(); if (c) goto skip; return
    sizeof(enum { K = 5 }); skip: return K; }` the source names the
    operand's `K` in the last statement, and the lowered code would
    name an outer `K` there or none. In `return (p = (int[]){42}, ({
    goto out; 0; }));` the compound literal lives until the block that
    holds the `return` ends (C11 6.5.2.5p5), and in the lowered code
    until the block of the `return` does, which the `goto` leaves:
    code after `out` that reads `*p` reads 42 in the source and an
    object whose life has ended in the lowered code (GCC 16 at `-O2`
    gives another value). A `return` in the operand leaves the
    function, and is no such jump.
13. No `defer` statement stands among the tokens that typing does not
    read (unread text, 13.5), in any text: the statement would reach
    the backend as written. One scan passes over every such token,
    whatever holds it: the body of a block literal, a function body
    that is passed through unread (13.3), an attribute argument, or
    anything else that typing passes over. The scan refuses `_Defer`
    in every token it passes over, and the word `defer` in an
    attribute argument of Type-C text, where no declaration hides the
    word (2.3). The word begins a statement in Type-C text alone, and
    of the unread tokens of Type-C text only an attribute argument can
    hold a statement: a block literal and a function body that is
    passed through unread hold no token of Type-C text (13.3). A
    `#pragma` line alone is not scanned: a pragma holds no statement,
    so `_Defer` or `defer` on its line is a word of the pragma, which
    the backend reads, and is no error. Every token outside a
    `#pragma` line is thus read by typing or by the scan; the rule
    lists no kind of unread text that it covers, so it can miss none.

Rules 1, 5 and 10 make the set of deferred statements that a jump leaves
a static fact, so `defer` needs no flags or run-time bookkeeping. Rules
8 and 12 are not in the TS. Rules 8 and 9 let the compiler repeat `S` at
each exit exactly as written, with every name bound as in the original
and no label, object or type defined twice, and rule 12 lets it write a
`return` as a block. `typec` lowers every `defer` statement itself
(13.5) and hands the backend none: a `defer` statement stands either
in text that typing reads, where it is lowered, or among the tokens
that typing does not read, where the scan of rule 13 refuses it.
`defer` so does not depend on the C compiler implementing the TS.

The diagnostics tell apart (13.6) the refusals of rule 8, of rule 9,
of rule 12, of a `defer` statement in the statement of another (rule
11, which exists only because lowering repeats the statement at every
exit) and of the form of a `return` on each of its grounds (13.5), so
a count of a rule reads names and matches no message text. Pilot B
met none of these refusals (section 15, P9). A failure of the
resolution property for a deferred statement is a refusal under rule
8 and carries the name of rule 8: one name, whichever clause of the
property fails. Rule 8 has no check of its own for that. The one check
of the property derives the name from the kind of text that it reads
(13.5). A failure that rests on a type that typec does not compute is
the exception: it carries the one name of such failures, whatever the
kind of text, and P21 counts it (13.5). Rule 9 has one name. Under rule
12, a declaration in the operand fails the same check on the operand of
a `return` and carries the name of that kind of text, and a jump out of
the operand a name of its own; no other rule has either name. Each
refusal of the form of a `return` has a name of its own (13.5).

Rationale for rule 11. C makes the substatement of a selection or
iteration statement a block of its own (C11 6.8.4p3, 6.8.5p5), so the
scope of a `defer` statement there would be empty and `S` would run at
once. A label is followed by a statement, which a declaration is not in
C11 or in the accepted dialect (2.4, 13.3), and a `defer` statement
stands where a declaration does. The last expression of a statement
expression is its value and leaves `S` no place after it. Outside a
function body a block stands only in a statement expression, or in the
body of a block literal, which is unread text (rule 13). Neither backend
takes a statement expression there. Apple Clang 21 and GCC 16 refuse
one in a declaration of file scope: in an array size, in a
`__typeof__`, in an initialiser and in the value of an enumeration
constant. They refuse one in the head of a function definition too: in
the array size of a parameter, in a `__typeof__` of the return type and
in a declaration of an old-style parameter. One rule therefore covers
the definition of a generic type, which stands at file scope (3.5 rule
8), the head of a generic function, whose instances stand there (10.3),
and C text of file scope. The text that it refuses compiles nowhere,
and no instance of such a generic does, so the refusal costs no code
that a backend takes. Lowering writes no copy of a deferred statement
outside a function body: none in the definition of a type instance and
none in the head of a function instance (10.3).

The refusal of a `defer` statement in `S` follows from the
repetition. Lowering copies `S` to every exit of its scope
(13.5), so each copy of `S` would hold every copy of a `defer`
statement in it: with `e` exits at each of `n` levels of nesting, the
innermost statement is written `e` to the power `n` times. A prototype
of the lowering turned 655 bytes of source with 12 levels and 3 exits
per level into 24 MB of C. With no `defer` statement in `S`, the text
that lowering writes for a scope is linear in its exits times its
`defer` statements.

## 7. Generic functions

```c
generic(T)
T *vector_last(vector(T) *v)
{
    return v->len ? &v->data[v->len - 1] : NULL;
}

int *p = vector_last(&numbers);                 /* T deduced as int  */
int *(*fp)(vector(int) *) = vector_last(int);   /* explicit instance */
```

### 7.1 Declaration and checking

1. `generic(T1, ..., Tn)` prefixes a function definition or declaration at
   file scope. Each `Ti` is a type name for the rest of that declaration.
   The function's name meets what 3.1 rules 6 and 7 require of a type
   name declared at file scope, since its instance names are built as
   those of a generic type are (10.3). Rule 6 says what the declaration
   holds, and rule 7 when two declarations of one name agree.
2. Inside, `Ti` is an opaque value type (3.2): the check types it as C
   types a complete structure whose members cannot be named. An object
   of the type can be declared and copied whole and its size taken, and
   no part of it can be read or written.
3. The body is checked once, against the opaque types, when the definition
   is read, and an instance is the same text with each `Ti` naming its
   argument (10.3). A use of a type parameter is therefore valid only
   where, for every value type, the instance is valid C and gives each
   expression the type that the check gave it, with the argument in the
   place of `Ti`. Typing `Ti` as a structure allows a value of the type
   to be used in these ways:

   - declare objects of the type, and initialise an object or a
     subobject of the type with an expression of the type or with the
     zero initialiser (below);
   - assign, pass to a parameter of a prototype, and return;
   - discard it, as an expression statement, as the left operand of a
     comma or under a cast to `void`, and yield it as the right operand of
     a comma;
   - apply unary `&`, `sizeof`, `__alignof__` and `__typeof__`. C11
     gives `_Alignof` a type name alone (6.5.3p1), so the alignment of a
     value is `__alignof__(t)` or `_Alignof(__typeof__(t))`. Both
     backends take these two under `-pedantic-errors` and refuse
     `_Alignof(t)` there, of which Apple Clang 21 warns without the
     option as well (Apple Clang 21, GCC 16);
   - do everything C allows with a `Ti *`: dereference, arithmetic,
     subscripting, comparison, casts to and from other object pointers;
   - use `Ti` as a type argument and in derived types.

   What C refuses of a structure is an error: arithmetic, comparison,
   conversion, member access, calls, truth tests, and every cast of a `Ti`
   value but the cast to `void`. C allows that cast of every value (C11
   6.5.4p2), and it is how C marks a parameter as unused.

   Valid C is here what 2.4 holds lowered code to: ISO C11, as both
   backends enforce it under `-pedantic-errors`, with the GNU forms
   that 2.4 names. An instance is the definition's own tokens, so what
   a definition writes of a `Ti` is held to the same, and an extension
   of the backends makes no use valid. Two uses meet that line. A cast
   to `Ti` is an error like the other casts: C allows it of a scalar
   alone, and the backends take a cast of a structure to its own type
   only as an extension, which they refuse under `-pedantic-errors`
   (Apple Clang 21, GCC 16). Nothing is lost by the refusal, as `(T)t`
   says what `t` says. The empty initialiser `{}` is an extension of
   C11 as well, and the zero initialiser below needs it, since ISO C11
   has no initialiser that zeroes the padding of a structure and the
   rest of a union. That one is therefore lowered: whichever of `{0}`
   and `{}` the definition writes, an instance holds `{}` under
   `__extension__`, which both backends take under `-pedantic-errors`
   in every dialect (13.5).

   No initialiser enters a `Ti` but the *zero initialiser*, `{0}` or
   `{}`. An initialiser list is read as C reads it, against the types
   of the check. Where it reaches an object or subobject of type `Ti`,
   an expression of the type `Ti` initialises it whole (C11 6.7.9p13).
   Any other initialiser there is for a member of `Ti`, written in
   braces of `Ti`'s own or handed to its first member with the braces
   left out (6.7.9p20), and it is an error, as `Ti` has no member that
   can be named. The zero initialiser names none. As the whole
   initialiser of an object or of a subobject whose type mentions a
   type parameter (rule 4), `{0}` or `{}` initialises it as C
   initialises an object of static storage that has no initialiser
   (C11 6.7.9p10), whatever the argument is, and nothing in the list
   is matched against a member. Every scalar in it has the value
   zero: each member of a structure, each element of an array and the
   first member of a union, to any depth. Every byte of it outside
   those scalars is zero: the padding of each structure, the bits of
   each unnamed bit-field and the rest of each union. C leaves an
   unnamed member indeterminate after any initialiser (6.7.9p9), so
   the bits of an unnamed bit-field are zero by what both backends
   do with the lowered form, which the test of 13.5 holds. The bytes
   inside a scalar that hold none of its
   value are not promised (below). The two spellings mean the same.
   So these are valid and mean the same in every instance:

   ```c
   T u = {0};
   T row[4] = {0};
   T both[] = { t, t };
   T *fresh = &(T){0};
   struct { T a; int b; } w = { t, 5 };
   struct { T a; int b; } z = {0};
   struct { T a; int b; } y = { .b = 5 };
   ```

   The members that a list leaves out, as `a` in the last line, are
   initialised as those of a static object are (6.7.9p21), which is
   the same zero (6.7.9p10; Apple Clang 21 and GCC 16, for the bytes
   of a union and for the padding of a structure).

   These are errors, because what each means is the argument's to say:

   ```c
   T u = { t };
   T both[] = { 0, 0 };
   T one[] = {0};
   struct { T a; int b; } w = { 0, 5 };
   struct { T a; int b; } y = { .a = 0 };
   T *q = (T[]){ 0, 0 };
   ```

   `T u = { t };` is valid where `T` is `short` and an error where it is
   a structure. `both` and the array of the compound literal have two
   elements where `T` is `short` and one where it is
   `struct { short x, y; }`, and the 5 of `w` is stored in `b` in the
   first instance and in `a.y` in the second (Apple Clang 21, GCC 16).
   `one` takes its length from its list (6.7.9p22), so its `{0}` is a
   list of one element, whose `0` enters `T`, and no zero initialiser;
   `T one[1] = {0};` is one. A zero for one subobject of a longer list
   is `(T){0}`. `{ {0}, 5 }` is valid as well, and GCC 16 warns there
   of braces around a scalar initialiser where `T` is a scalar.

   C's `{0}` does not give a definition this zero. It promises the
   values of members and not the bytes between them (3.2 rule 7).
   That serves text that knows its type and can name what the list
   left, and not a definition, which names no member of `Ti`. Left as
   C, `T u = {0};` would hold under GCC 16, where `T` is
   `union { char c; long l[4]; }`, what the stack held in 31 of its 32
   bytes, without optimisation and at `-O2`, and Apple Clang 21 would
   refuse it where `T` is a structure that begins with a structure
   without members ("initializer for aggregate with no elements
   requires explicit braces"). The lowered form is one for every type
   that an argument can be, a structure without members among them,
   which is a GNU extension (13.3) of the text that declares it. An
   object whose type mentions no type parameter keeps C's initialiser
   as written, in a generic function as outside one: untouched C is
   emitted verbatim (principle 8).

   The promise ends at a scalar. A scalar type may hold its value in
   fewer bytes than its size, and the others are padding inside its
   own representation. C says nothing of those bytes, in C11 or in
   C23, whose rule for `{}` zeroes the padding of structures and
   unions, and a backend that stores the value leaves them as they
   were. The `long double` of x86-64 holds its value in 10 of its 16
   bytes, and its complex type in 20 of 32. After the zero initialiser
   of an object of either type Apple Clang 21 leaves the other 6 and
   12 as the stack held them, and GCC 16 leaves 6 of the complex
   type's 12 without optimisation and 4 and 8 at `-O2` (13.5). So the
   zero initialiser
   does not make the bytes of a `Ti` fit to hand on. A definition
   that gives the representation of an object to `memcmp`, to `write`
   or to a hash of the bytes clears the object with `memset` first,
   as C text does (3.2 rule 7). Lowering adds nothing for these
   bytes. No form clears them in every place where an initialiser
   stands, a `const` object, a static object and a compound literal
   among them (13.5), and the next store to the scalar leaves them
   unspecified again.

   The lowered form sets three limits. Each is an error of the check,
   since the backend would stay silent or would refuse lowered text:

   - A variable length array takes no initialiser (C11 6.7.9p3), the
     zero initialiser included: both backends take `{}` for one, which
     C23 allows (Apple Clang 21, GCC 16).
   - A declaration in the first clause of a `for` holds no zero
     initialiser of an object whose type mentions a type parameter:
     Apple Clang 21 does not read `__extension__` before a declaration
     there. The object is declared before the loop. A compound literal
     stands in that clause as anywhere.
   - An object or subobject whose own type is atomic takes none. Apple
     Clang 21 refuses braces around the initialiser of an `_Atomic
     int` and of an atomic structure, `{0}` and `{}` alike ("illegal
     initializer type"), where GCC 16 takes them. A structure with an
     atomic member and an array of atomic elements take the zero
     initialiser whole (both).

   Lowering writes `{}` where the check finds a zero initialiser, so
   the check types every list of a definition, and two errors keep it
   so. A list it could not type would reach the backend as C's `{0}`,
   with the bytes that the stack held in it:

   - A braced initialiser of an object whose type typec does not
     compute (13.3), or holds a member or element of one, as
     `__typeof__` of a call of a Clang overloaded function, or of a
     conditional whose null pointer constant is a value that the
     backend computes. The type may be the argument or hold it.
   - In a list for an object whose type mentions a type parameter, an
     initialiser without a designator after the list has lost its
     place: after an element of an array whose length or designated
     index the backend computes, or after an initialiser whose reach
     typec does not know. Where it goes, and so whether it is a zero
     initialiser, is the argument's to say. A designator places it:
     `{ x, .a = {0} }` is valid where `{ x, x, {0} }` is not, for
     `struct { int k[sizeof(struct s)]; T a; }`. A list for an object
     whose type mentions no type parameter loses its place as in C.

   Other things that C allows of a structure are errors too, because
   another value type gives them another type or another meaning:

   - What applies the default argument promotions (C11 6.5.2.2p6), which
     convert the values of some types and not of others: passing a `Ti`
     value through `...` or to a function without a prototype, and
     `va_arg` with the type `Ti`, qualified, atomic or neither,
     however its type name writes that type (rule 6), which is
     undefined where the argument is `short` or `float`
     (7.16.1.1p2): `va_arg(ap, const T)` is an error as
     `va_arg(ap, T)` is, and both backends report it in the instance
     for `char`. For the same reason a function
     type with a parameter of type `Ti` is compatible with no function
     type without a prototype (6.7.6.3p15): `void (*old)() = take;` with
     `void take(T t)` is an error in the instances for `short` and
     `float` and valid for a structure (Apple Clang 21, GCC 16). The
     promotions also keep a `Ti` from the place before an ellipsis in
     the head of the function itself (rule 6).
   - *Provisional (P29).* The conditional operator with a `Ti` value as
     its second or third operand. C gives it the type of the usual
     arithmetic conversions (6.5.15p5), so `c ? a : b` has the type
     `int` where `Ti` is `short`: `sizeof(c ? a : b)` is 4 in that
     instance and 2 for a structure that holds one `short`, and
     `__typeof__(c ? a : b) *p = &a;` is an error in that instance alone
     (GCC 16; Apple Clang 21 warns). An `if` statement selects the value
     instead. The container library of Stage 3 settles it, by how often
     it wants the operator over such values, read from the name of this
     refusal: if that is common, the operator is allowed where its value
     is converted to `Ti` at once, by an initialisation, an assignment,
     an argument or a `return`. The refusal stays if that cannot settle
     it.
   - A construct that asks whether two types are compatible, `_Generic`
     and `__builtin_types_compatible_p` (13.5), where the answer is the
     argument's (rule 4). `__typeof__` asks nothing: it names the type
     that the check gave its operand, which is that type in every
     instance.
   - A declaration in the body that gives its identifier linkage,
     whatever its type: `extern T shared;`, `extern int count;`, or the
     declaration of a function, `T helper(T);`. Every declaration of an
     identifier with linkage denotes the same object or function (C11
     6.2.2p2), which has one type, and an instance can declare it with
     a type of its own. That type may be the argument's. It may also
     mention no type parameter and still be the instance's: in
     `struct s { int a; }; extern struct s x;` every instance defines a
     `struct s` of its own. Both backends refuse two such instances in
     one unit for conflicting types, for `shared` and for `x`. With one
     instance in each of two units the program links without a
     message, and one unit reads the other's `short` as a structure
     (Apple Clang 21, GCC 16). The refusal asks nothing of the type, so
     no list says what the type of such a declaration may name. The
     object or function is declared at file scope before the generic,
     where every instance names the one declaration (3.5 rule 8). An
     object without linkage is each instance's own, so `static T
     cache;` is valid.
   - An attribute or an alignment specifier that the one rule of 13.3
     for the definition of a generic refuses ("Attributes in a
     generic"): one whose subject mentions a type parameter, or whose
     arguments name what the definition declares, unless the table of
     effects records that both backends take the attribute alike. The
     subject may be the function itself (rule 6), a parameter or
     anything that the body declares.
   - An `__asm__` operand whose type mentions a type parameter, a `T *`
     too: its constraint asks of the operand a size and a kind, which
     differ between instances.
   - A use of a predefined name of the function, `__func__`,
     `__FUNCTION__` or `__PRETTY_FUNCTION__`, that reads the type of
     its array. Each is a static `const` array of `char` that holds
     the name of the function it stands in (C11 6.4.2.2p1), and an
     instance has a name of its own (10.3), which the definition does
     not know. The array therefore has another length in each
     instance, which is another type, and other contents. In
     `generic(T) void f(T *p)`, `sizeof __func__` is 2 by the name of
     the definition and 5 in the instance `f__i`:
     `_Static_assert(sizeof __func__ == 2, "name length");` fails
     there with both backends, as `const char (*q)[2] = &__func__;`
     and `__typeof__(__func__) *q = (const char (*)[2])0;` do (Apple
     Clang 21, GCC 16). The pointer to its first element is a
     `const char *` in every instance. So the name is valid where C
     converts the array to that pointer (6.3.2.1p3), and every other
     use of it is an error. The one place where C converts an array
     decides this for every form. An expression that hands the array
     on as it is, in parentheses, as the chosen association of
     `_Generic`, as the chosen operand of `__builtin_choose_expr` or
     under `__extension__`, is the array still, so the refusal
     follows the value through such forms, however they nest, to the
     use that converts it or does not. `sizeof`, `__alignof__`,
     unary `&`, `__typeof__` and `__typeof_unqual__` do not:
     `sizeof (__func__)`, `sizeof _Generic(0, int: __func__)`,
     `sizeof __builtin_choose_expr(1, __func__, 0)`,
     `sizeof __extension__ __func__` and
     `sizeof(__typeof_unqual__(__func__))` are each 2 in `f` and 5
     in `f__i`, and each is an error. The value of a statement
     expression, the right operand of a comma, the controlling
     expression of `_Generic` and the initialiser of an
     `__auto_type` object are converted, and each is a pointer in
     both functions (Apple Clang 21, GCC 16). As the
     initialiser of an array of `char` C refuses it in every
     function, since it is no string literal (6.7.9p14 and p16; both
     backends). The pointer serves what the name is written for. It
     is an argument, as in `printf("%s\n", __func__)`, and the
     `assert` of `<assert.h>` is valid in a generic function, as its
     macro hands the name to a function of the library: Apple's
     expands to `__assert_rtn(__func__, ...)`. The contents of the
     array are the instance's too, and rule 4 says what follows from
     that.
4. A type *mentions* a type parameter where it is one, is derived from a
   type that mentions one, is a type application with an argument that
   mentions one, or is a structure or union with a member whose type
   mentions one. The test reads the structure of the type and asks
   nothing of its layout, which the front end does not compute (13.3,
   P16): `T *` and `vector(T)` mention `T`.

   The check runs once, so it knows such a type by that structure and
   by nothing else. Three things about the type are the argument's to
   say: its layout, which is its size, its alignment and the offsets
   of its members; its class, whether it is an integer, a pointer or a
   structure; and whether it is compatible with a type that is not the
   same type for every argument. One rule holds for all three: **a
   definition takes no type, no meaning and no validity from an answer
   that the argument gives.** An instance computes with such an answer
   as with a value that is read at run time, and a definition does
   nothing else with one.

   No list of operators or of constructs keeps the rule. Each answer
   carries the fact that it is the argument's, from the one place in
   the front end that gives it to every place that asks.

   The class of a type is asked wherever C constrains an operand, and
   rules 2 and 3 answer there for a type parameter.

   Whether two types are compatible is asked of one comparison (C11
   6.2.7), which has three answers: they are, they are not, or the
   argument decides. The comparison walks the two types together, and
   the argument decides exactly where it comes to compare a type
   parameter with any type but that parameter itself. A construct that
   asks, `_Generic` or `__builtin_types_compatible_p`, is an error
   where an answer is the third. C makes the answer a constant, a
   `_Generic` selection takes its type from it, and 13.5 answers it in
   the front end wherever a distinct type is compared, which no
   instance does for its argument. Every comparison of the construct
   counts, those among the associations of a `_Generic` too. With
   `int x`, `_Generic(x, T: 1, default: 0)` is 1 where `T` is `int` and
   0 where it is `long`, and `_Generic(x, T: 1, int: 2)` is not valid C
   where `T` is `int`, as two of its associations are compatible (Apple
   Clang 21, GCC 16). An answer that is the same for every argument
   stands: with `T row[4]`,
   `__builtin_types_compatible_p(__typeof__(row), __typeof__(&row[0]))`
   compares an array with a pointer and is 0 whatever `T` is, so the
   macro that counts the elements of an array with that test is valid.

   The layout of a type is handed to the program as a value, and there
   the fact is one of the value. An expression *depends on a type
   parameter* where its value is an answer that the argument gives, or
   is computed from one. The fact arises in three places. The first is
   the one function of the front end that gives the layout of a type:
   for a type that mentions a type parameter it answers that the value
   depends, where for another structure it answers with an opaque
   constant (13.3, P16). `sizeof`, `_Alignof`, `__alignof__` and
   `offsetof` ask it in so many words. Arithmetic on a pointer to such
   a type asks it for a size, and the address of a member of one asks
   it for an offset. So `sizeof(T)` and `sizeof(T *)` both depend on
   `T`: C does not promise one size for all object pointers
   (6.2.5p28), and `sizeof(void *)` says what is meant. The second
   place is the call of a builtin function. The check has the type of
   a builtin and not what it inspects:
   `__builtin_object_size(&t, 0)` reads the size of `t`,
   `__builtin_classify_type(t)` its class, and
   `__builtin_constant_p(k)` whether the backend can fold `k`, which
   it decides from what the body has stored in `k`. So in the
   definition of a generic the result of a builtin depends, whatever
   its arguments are, unless the table of builtin functions records
   that the values of its arguments alone decide it, as they decide
   `__builtin_bswap32` and `__builtin_expect` (13.3). A gap in the
   table costs a refusal and never an instance that the backend
   judges by itself.

   The third place is a predefined name of the function (rule 3). It
   designates a `const` array whose contents are the name of the
   instance, which the argument gives. The name therefore depends,
   and with it the pointer that C converts it to and what is read
   through that pointer. Apple Clang 21 reads those contents as a
   constant. In `generic(T) void f(T *p)`,
   `_Static_assert(__builtin_strlen(__func__) == 1, "length");` holds
   by the name of the definition and fails in the instance `f__i`,
   and the bound `__builtin_strlen(__func__) == 1 ? 1 : -1` declares
   an array by the one name and is an error by the other. GCC 16
   takes neither for a constant, and declares a variable length array
   with that bound. Read at run time the name is valid, as in
   `assert(p)` and in `report(__func__, code)`. A static initialiser
   requires a constant, so `static const char *name = __func__;` is
   an error, valid though it is in every instance, like the address
   of `pool[3]` below.

   From each place the fact flows as a value does. An operation
   depends where an operand does, evaluated or not, and a call where
   an argument does. An expression that designates a `const` object,
   or a part of one, depends where the initialiser of that object
   does, because the backends read such an object as a constant. With
   `const int j = sizeof(T) > 1000 ? 1 : -1;`, `char b[j]` is an array
   of one element where `T` has 2000 bytes and an error where it has
   two, and with `const int k = sizeof(T) > 1000 ? 1 : n;`,
   `static int s = k;` is valid in the first instance and an error in
   the second (Apple Clang 21, GCC 16). Clang reads a member of a
   `const` structure and a `const` compound literal in the same way.
   An object that is not `const` is a constant to neither backend, so
   `size_t n = count * sizeof(T); char scratch[n];` declares a
   variable length array in every instance.

   The value of an expression that depends belongs to the instance. It
   is a constant there, a different one in each instance, and the
   check, which runs once, has the expression's type and no value for
   it. The definition therefore cannot use it as a constant: a
   construct to which C gives a type, a meaning or its validity by the
   value of a constant expression is an error where that expression
   depends on a type parameter. Any other use computes with the value
   as with one that is read at run time, so `malloc(n * sizeof(T))`,
   `memcpy(to, from, sizeof(T))` and `if (sizeof(T) > 16)` are valid.

   The front end has one evaluation of constant expressions, which
   every construct that needs such a value asks, and for an expression
   that depends on a type parameter its one answer is this error. What
   the evaluation leaves to the backend passes through where the fact
   is absent: an opaque constant, a call, the value of a `const`
   object. The backend judges each of these once outside a generic and
   once in every instance of one, and the absence of the fact is what
   says that those judgements are one. C has two kinds of construct
   that ask:

   - One that requires a constant expression, whose value must lie in
     the range of its type (C11 6.6p4) and meet the constraint of its
     place: a `case` value, a static initialiser, the width of a
     bit-field, the value of an enumerator, the index of a designator,
     the operand of `_Static_assert`, the first operand of
     `__builtin_choose_expr`, and the operand of `_Alignas`, where a
     type name that mentions a type parameter stands for the alignment
     of that type (6.7.5p5).
   - One that asks whether an expression is a constant and takes a type
     from the answer. An array bound declares an array of that length
     where it is a constant and a variable length array where it is not
     (6.7.6.2p4), so a bound that depends on a type parameter is an
     error and is not read as the bound of a variable length array. A
     null pointer constant is an integer constant expression of the
     value 0, or one cast to `void *` (6.3.2.3p3), so an expression
     that depends on a type parameter is an error wherever a rule of C
     asks whether it is one.

   Each can be valid, or have one type, for some arguments and not for
   others. `char pad[sizeof(T) - 4]` is an error where `T` has two
   bytes and an array where it has 2000, and
   `static int k = 1 / (sizeof(T) - 2);` is an error where `T` has two
   bytes and valid where it has 2000. With `T *p`,
   `c ? p : (void *)(sizeof(T) > 1000)` has the type `T *` where `T` is
   small, as its third operand is a null pointer constant there
   (6.5.15p6), and `void *` where `T` has 2000 bytes: a `_Generic` over
   it selects another association, and an object declared with its
   `__typeof__` has another type. The size of
   `__builtin_choose_expr(sizeof(T) > 1000, (char)0, 0L)` is that of a
   `long` in the first instance and 1 in the second (Apple Clang 21 and
   GCC 16 for all four). Storage for a `T` is declared as a `T` and not
   as `char buf[sizeof(T)]`.

   The same holds of a value that reaches a constant by another road.
   The bounds `(size_t)((T *)0 + 1) > 1000 ? 1 : -1`, the same over the
   distance between two elements of a static array of `T`, and
   `__builtin_classify_type(t) == 12 ? 1 : -1` each declare an array
   for one of the two arguments and are an error for the other with
   both backends. The bound over `__builtin_object_size(&t, 0)` is so
   with Apple Clang 21 alone, and the bound
   `__builtin_constant_p(j) ? 1 : -1` is an error of GCC 16 without
   optimisation and an array at `-O2`, for both arguments.

   A static initialiser requires a constant, so
   `static T *next = &pool[3];` is an error for a static `T pool[8]`,
   valid though it is for every argument: its value is an address that
   the size of `T` moves, and nothing tells an address that a pointer
   will hold from one that a bound will read. `static T *next = pool;`
   asks for no layout and is valid.

   The rule ends where C stops reading the value. Arithmetic on it
   that no constant expression holds is the instance's computation,
   and what a backend says of it is that instance's too: for
   `int a = 1 / (sizeof(T) - 2);` both backends warn of a division by
   zero in the instance where `T` has two bytes and in no other, as
   they warn of `1 / 0` in any function, and of a shift by
   `sizeof(T) * 16` only where that reaches the width of the shifted
   type (Apple Clang 21, GCC 16). The warning is true of that instance,
   and the check cannot look for it without the value.
5. Type parameters have no constraints. An operation that is not valid for
   every type, such as hashing, equality or ordering, is passed as an
   ordinary function pointer, as `qsort` takes its comparison:

   ```c
   type map(K, V) = struct {
       size_t (*hash)(K key);
       bool (*equal)(K a, K b);
       /* ... */
   };
   ```
6. After `generic(...)` stands one function: a function definition, or a
   declaration with exactly one declarator, which declares a function. A
   second function is a second `generic`. An instance is written from
   the head of the definition alone, as its prototype and again at its
   definition, under a name of its own and with internal linkage (7.3,
   10.3), and each rule here keeps one fact about it:

   - The function has a prototype: `(void)` where it takes no argument,
     and neither `()` nor an identifier list. Deduction reads the types
     of the parameters (7.2), and an identifier list cannot stand in the
     prototype of an instance (C11 6.7.6.3p3).
   - Where the parameter list ends in an ellipsis, the last named
     parameter does not have the type `Ti`, qualified, atomic or
     neither, however the head writes that type: `T last`,
     `const T last`, `_Atomic(T) last`, `__typeof__(T) last`,
     `__typeof__(first) last` after `T first` and, with
     `type same(T) = T;`, `same(T) last` are errors. `va_start`
     names that parameter, and its behaviour is undefined where the
     type of the parameter is not compatible with the type that the
     default argument promotions give a value of it (C11
     7.16.1.4p4). The promotions change `_Bool`, the character
     types, `short`, `unsigned short`, `float` and an enumeration
     narrower than `int`, and change no structure. The check types
     `Ti` as a structure (rule 2), so it
     would pass a body whose instance for `char` is undefined: with
     `generic(T) int f(T last, ...)` and `char c`, the call
     `f(c, 42)` deduces `char` (7.2). In C text of such an instance,
     where `T` is a typedef of `char`, `short`, `_Bool`, `float` or
     a packed enumeration, Apple Clang 21 reports "passing an object
     that undergoes default argument promotion to 'va_start' has
     undefined behavior" for a last parameter of the type `T`,
     `const T`, `volatile T`, `__typeof__(T)` and `__typeof__` of an
     earlier parameter of the type `T`, and nothing where
     `T` is `int`, `double` or a structure. GCC 16 reports none of
     these. For `_Atomic(T)` Clang is silent, and GCC warns for
     every `T` that the parameter is not the last named one; the
     refusal covers it by the paragraph of C11, as the value of an
     atomic `char` is promoted as that of a `char` is.

     No other type that mentions a type parameter (rule 4) is
     promoted in one instance and not in another, so the refusal
     names the type and no list of types. A pointer is not promoted,
     `T *` included, and neither is a structure or a union that
     holds a `Ti`. A last named parameter that is declared with an
     array or a function type makes `va_start` undefined whatever
     its element or return type is (7.16.1.4p4): in every instance
     alike, as in C text, so it is no difference between instances
     and this rule leaves it to C. A type application is a
     variant, which is a structure (10.1), the type that an alias
     stands for, or a distinct type, whose underlying type is a
     pointer or an arithmetic type that is the same in every
     instance, since no definition writes a type parameter directly
     after `distinct` (3.5 rule 4). An enumeration mentions no type
     parameter. Both backends take each of these as the last named
     parameter without a message, for every `T` above: a structure
     and a union that hold a `T`,
     `T *`, `const T *`, `T (*)[3]`, `T (*)(T)`, `T last[4]`,
     `T last[4][2]` and `T last(T)`. A function that takes a value
     of type `Ti` and variable arguments has another parameter
     between them, as in `generic(T) int f(T first, int count, ...)`,
     or takes a `T *`. The rule is about the function that the
     generic defines, the one place where its `va_start` stands: a
     function type elsewhere in the head or the body, as that of
     `void (*log)(T last, ...)`, defines no function.
   - `static` is the only storage-class specifier, on a definition or on
     a declaration, and it changes nothing: an instance has internal
     linkage whatever is written. `extern` is an error, since it would
     promise an external definition that no translation unit holds.
   - `inline`, `_Noreturn` and attributes stand on the definition, and
     every instance carries them where its head is written. A
     declaration that is not a definition gives the check a type and
     writes nothing into an instance, so `_Noreturn` or an attribute on
     it is an error: the check would know what the backend is never
     told. `inline` may stand on it and asks nothing there: for a
     function with internal linkage it is a hint that changes no meaning
     (6.7.4p6), and an instance is `inline` where the definition is.
   - An attribute means on an instance what the backend makes of it on a
     `static` function, and the backend refuses one that such a function
     cannot carry, as `weak` (Apple Clang 21, GCC 16). It stands under
     the one rule of 13.3 for the definition of a generic ("Attributes
     in a generic"), with the function as its subject: where the
     function's type mentions a type parameter, the table of effects
     must record that both backends take the attribute alike, which
     keeps `nonnull`, `format` and `alloc_size` off nearly every
     generic function.
   - No type in the head is variably modified, at any depth: not the
     type of a parameter, once C has adjusted an array parameter to a
     pointer (C11 6.7.6.3p7), and not the type of a parameter of a
     function type that the head holds, adjusted likewise. `T a[n]` is
     `T *a` and stands, and `T (*m)[n]`, `T m[n][k]` and
     `void (*fp)(size_t n, int (*m)[n])` are errors. Whether two such
     types are the same rests on the values of their bounds at run
     time (6.7.6.2p6), so C lets no typedef name of one be defined
     twice (6.7p3), and rule 7 compares two declarations as two such
     definitions. The backends differ there: Apple Clang 21 refuses the
     same text twice, `void (size_t n, int (*a)[n])` and
     `void (void (*fp)(size_t n, int (*m)[n]))` alike, and GCC 16 takes
     both, with `[*]` beside `[n]` in the first and `[n + 1]` beside
     `[n]` in the second as well. Both take `int a[n]` beside
     `int *a`, and `int a[static 4]` beside it, as one type. The refusal is the
     smaller rule: comparing such types with their bounds left out, as
     compatibility does, would add a case to rule 7 and one to the
     match of 7.2 rule 2, for a parameter that few generic functions
     have. A function over a matrix takes a `T *` and the two lengths.
     A type argument is not variably modified either (3.5 rule 2), so
     no type in the head of an instance is.
   - No assembler label follows the declarator. `__asm__("name")` would
     give every instance the one name: with two instances so labelled,
     GCC 16 stops at the assembler, and Apple Clang 21 compiles the unit
     without a message and sends the calls of one instance to the body
     of the other.
   - The head declares no tag, with a body or without one, in its
     specifiers or its parameters. An instance writes the head twice,
     as its prototype and at its definition. A structure, union or
     enumeration that the head defined would be defined twice, and its
     enumerators with it. A tag that a parameter list is the first to
     mention, as `struct s` in `generic(T) void f(T, struct s *p);`
     where no `struct s` is visible, has the scope of that list (C11
     6.2.1p4): the prototype of an instance and its definition would
     name two types, and both backends refuse the second for
     conflicting types (Apple Clang 21, GCC 16). A tag that is declared
     before the generic is named in the head and not declared there,
     and stands (3.5 rule 8).
7. A generic function may be declared more than once at file scope and is
   defined at most once. Two declarations agree where they have the same
   number of type parameters and, with each type parameter of one read
   as the type parameter at the same position of the other, declare the
   same type, as two definitions of one typedef name must (C11 6.7p3).
   No type in the head is variably modified (rule 6), so the comparison
   reads no bound that is not a constant and always has an answer.
   The names of the type parameters and of the parameters may differ.
   Types that are compatible and not the same do not agree, so the
   declarations of a generic function form no composite type, and a use
   is checked against one type whichever of them it follows. The
   function types `void (int)` and `void (const int)` are the same, and
   so are `void (int[])` and `void (int *)`; `void (int (*)[])` and
   `void (int (*)[4])` are compatible and not the same (Apple Clang 21,
   GCC 16, as two definitions of a typedef name).

   The name of a generic function denotes nothing else at file scope: any
   other declaration of it there, of a function, an object, a typedef
   name, a type or an enumeration constant, before it or after it, is an
   error. A name that was both a generic and an ordinary function would
   make `f(x)` a choice between the two, which is overloading (principle
   6). A declaration in a block or a parameter list hides the name as it
   hides any name of file scope.
8. Lowering writes a generic function only as its instances (3.5 rule 8,
   10.3). Neither its definition nor a declaration of it leaves text at
   its own place, so a generic function that the unit does not use is
   checked and leaves nothing in the lowered C (7.3 rule 1). An instance
   of a generic type that the type of the function applies to types
   that mention no type parameter, as `box(int)` in
   `generic(T) box(int) count(T x);`, is used at the declaration, as in
   that of a function that is not generic, so that every declaration
   and every call names the one instance.
9. A generic function is not defined in a system header. Its body there
   is C text that `typec` passes through unread (13.3), while each
   instance reads the definition again under its type arguments, so
   such a definition is an error.

Because of rules 2 to 4, an instance of a checked generic function is
valid C for every value type. Instantiation fails only where a chain of
instances exceeds the nesting limit (3.5 rule 7), where a declaration
changes what the definition names (3.5 rule 8), where 10.3 or rule 2
or 4 of 7.3 refuses the instance's placement, or at a translation
limit of `typec` (13.6). A declaration of a name that an instance would
take is refused whether or not the instance is
used (10.3). What a backend warns of in one instance and not in another
is no part of this (rule 4).

Rationale for no constant that depends on a type parameter. A use of
`sizeof(T)` as a constant can be valid for some arguments and not for
others, so allowing it would move an error from the definition, where
rule 3 reports it once, to each instance that fails, in a message about
text that the caller did not write. That `sizeof(T)` is no constant in
a definition is the owner's decision and is not provisional: it awaits
no count, and what would reopen it is a generic function that cannot be
written without such a constant.

Rationale for no constraints. Resolving `hash(K)` statically for an
arbitrary `K` needs overloading, or named instances that the compiler
searches. Both are large mechanisms that principle 6 excludes, and the C
idiom already exists. The price is an indirect call and an extra argument;
section 12 says what evidence would revisit this.

### 7.2 Calls

1. *Provisional (P11).* A call `f(arguments)` deduces the type arguments
   from left to right. For each parameter in turn: if every type parameter
   in its type is already deduced, it is an ordinary parameter of the
   substituted type, with a target type and C's implicit conversions.
   Otherwise the argument is typed on its own, after lvalue, array and
   function conversion, and matched structurally against the parameter
   type; each type parameter met is deduced as the corresponding part of
   the argument's type.
2. The structural match is exact, except that a pointer parameter may add
   qualifiers to the pointed-to type, as C assignment allows, and a slice
   parameter to its element type (section 8). A type parameter that occurs
   twice in one parameter type must match identical types.
3. Every type parameter must be deduced by the end of the argument list.
4. `f(type, ..., type)` names an instance explicitly. It is a function
   designator of an ordinary C function type that can be called or have its
   address taken. After the name of a generic function and `(`, a token
   that begins a type name begins the type arguments, since the parser
   decides that before any type is known; so a typedef-named unqualified
   constructor as the first argument of a call needs the qualified form,
   as after the `(` of a cast (3.3). A parenthesised name, as in
   `(max)(1, 2)`, is still called, as parentheses around a function
   designator change nothing in C (C11 6.5.1p5).
5. A type argument, deduced or explicit, is a value type that also meets
   rule 2 of 3.5. A value type is unqualified, so `first(p)` with `p` a
   `const int *` and `T *first(T *p)` is refused: a generic function
   meant for const data declares `const T *`, which takes `int *` and
   `const int *` alike by rule 2, as a C function meant for both
   declares `const int *`, since `int *` takes no `const int *`.

Example: with `vector(long) v`, the call `vector_push(&v, 0)` deduces `T` as
`long` from the first argument and then converts `0` to `long`. The first
argument that mentions a type parameter fixes it: `max(0, n)` with `n` a
`size_t` deduces `int` and converts `n`, exactly as a call to
`int max(int, int)` would. A stricter rule, under which only constants
convert, is weighed with P11.

### 7.3 Instances

1. *Provisional (P12).* Each instance used in a translation unit is compiled
   in that translation unit as a function with internal linkage, named
   and placed as 10.3 says. A generic function that is not used produces
   no code. Rule 7 of 3.5 bounds what a use causes: a chain of
   instances by the nesting limit, and what the instances of the unit
   cost by the instance budget and the output limit.
   As an instance has internal linkage, an inline definition of a
   function with external linkage uses none in its head or its body
   (C11 6.7.4p3): such a use is an error. typec refuses it itself, as
   GCC and Clang report the constraint violation only as a warning,
   which Clang (`-Wstatic-in-inline`) gives in the main file only under
   `-pedantic`. Whether a definition is an inline definition follows
   from the declarations before its end (6.7.4p7): every file-scope one
   says `inline` without `extern`. A later declaration that says
   `extern` would make it an external definition, which may use an
   instance, but the use is refused where the definition stands.
2. The definition of a generic function precedes the first use of each
   of its instances, since the instance is defined there (10.3): generic
   functions are defined in headers. A declaration that is not a
   definition lets generic functions call each other, provided both are
   defined before an instance of either is used. Rule 6 of 7.1 says
   what such a declaration holds besides the type, and rule 7 when it
   agrees with the definition. The definition of a generic type and
   the head of a generic function use no generic function: 10.3 writes
   the text of a type instance, and the prototype of a function
   instance, before the prototypes of the function instances that the
   reading of its definition causes, so the instance that such a use
   names would stand before its prototype. Nothing needs such a use; a
   body or an initializer holds it instead.
3. Rule 8 of 3.5 binds the whole definition, its body included, from the
   definition to each instance. In

   ```c
   int g();
   generic(T) void f(T *p) { g(p); }
   int g(long);
   void h(int *p) { f(p); }
   ```

   the instance `f__i` is defined after the second declaration of `g`,
   whose prototype the check of the body (7.1 rule 3) never saw, so the
   call in `h` is an error that cites that declaration. A declaration
   that completes the array type of an object the body uses, and a
   file-scope declaration of a tag that the body declares for itself,
   are refused in the same way. The first is the refusal expected most
   often where nothing would go wrong: a header declares
   `extern int tbl[];`, a generic uses `tbl`, and the definition of `tbl`
   with its size stands before an instance. The measurement of P23
   counts these.

   Where the source declares an enumeration without its list before
   the definition, the first use of an instance that is written after
   the list is refused as well, whether or not the body names the
   enumeration (13.5). In

   ```c
   enum E;
   generic(T) int f(T *p)
   {
       return _Generic((enum E *)0, int *: 1, default: 0);
   }
   enum E { A = -1 };
   int h(int *p) { return f(p); }
   ```

   the body reads 0 at the definition, where `enum E` is compatible
   with no integer type, and would read 1 in the instance `f__i`, which
   is defined after the list (Apple Clang 21, GCC 16). The call in `h`
   is an error that cites the list.

   An instance also reads each name whose meaning a type decides as the
   check read it: an unqualified name is a constructor (3.3), and an
   identifier alone in a pattern a constructor pattern (4.7 rule 3),
   exactly where the check read one, whatever the arguments make of the
   target type or the type of the position. In

   ```c
   generic(T) void put(T *out, T Overflow) { *out = Overflow; }
   ```

   the target type of `*out` is the opaque `T`, so the check reads the
   parameter `Overflow`, and so does the instance over `eval_error`,
   whose target type has a constructor `Overflow`. typec records the
   check's reading of each such name and every instance takes it, so
   that the check and an instance cannot read one name two ways; an
   instance that read its own would compile code that no check
   typed.
4. *Provisional (P27).* An instance is compiled under the pragmas in
   force at the definition of its generic, as a `static inline`
   function of a header is under those of the header. It is not
   compiled under the pragmas in force at its first use, which it would
   carry to every later use in the unit. So no `#pragma` line that sets
   state stands between the definition and the place where 10.3 writes
   the instance: the first use of an instance is an error where such a
   line stands between the two, and the error cites the line. Every
   `#pragma` line sets state but for the three kinds that 13.5 lists,
   each with its reason: a `pack` line, because every instance stands
   in the bracket of 10.3 and has the packing of the command line; a
   `GCC diagnostic` or `clang diagnostic` line; and a line of
   `Statement_pragma` (13.5) that stands inside a function body. In

   ```c
   generic(T) float damp(T *state, float x) { return x * 0.0f; }
   #pragma GCC optimize("fast-math")
   float first(int *s, float x) { return damp(s, x); }
   ```

   GCC 16 would give `damp__i` the options of the pragma, and the
   instance would return 0 for a NaN to every caller in the unit, so
   the call in `first` is an error. A unit therefore includes the
   headers that define generic functions after the headers whose
   pragmas set state; 13.5 gives the measured cost.
5. Consequences: the code of an instance is duplicated across translation
   units, the address of an instance differs between them, and a static
   object in a generic function exists once per instance per translation
   unit.
6. An ordinary function gives C code and other translation units a single
   external entry point:

   ```c
   int *int_vector_last(vector(int) *v) { return vector_last(v); }
   ```

Rationale. One instance per program needs either weak symbols or a
compiler that sees the whole program and deduplicates. The first is not
portable to every toolchain and the second breaks principle 7. Per-unit
instances are what `static inline` functions in C headers already are, they
work with every build system, and linkers can fold identical functions.

## 8. Slices and strings

```c
type slice(T) = struct { T *data; size_t len; };   /* universe */
typedef slice(const char) str;                      /* universe */

uint8_t buffer[512];
slice(uint8_t) bytes = slice_from_array(buffer);
uint8_t first = bytes[0];                           /* checked  */
str greeting = "hello";                             /* len 5    */
```

1. `s[i]`, for `s` of a slice type and `i` of an integer type no wider
   than `size_t`, is an lvalue of type `T` that designates `s.data[i]`.
   It traps unless `(size_t)i < s.len`; the test precedes any pointer
   arithmetic, and `s` and `i` are each evaluated once. An index of a
   wider type is an error, as one of type `unsigned __int128` is, and
   one of type `long long` where `size_t` has 32 bits: the conversion
   would drop the bits that tell such an index from one in range.
   `s[(size_t)i]` writes the narrowing into the source. An index of any
   other type is an error, as it is in a subscript of C (C11
   6.5.2.1p1). Where C does not evaluate the index, as in
   `sizeof(s[0])`, there is nothing to test (rule 9). *Provisional
   (P14):* no option turns the check off. `s.data[i]` is the unchecked
   spelling and is visible in the source.
2. `slice_from_array(a)` takes an lvalue of array type `T[N]` and yields a
   `slice(T)` of length `N`. A pointer is not accepted, and neither is
   an array of arrays, as `int rows[3][4]`: its `T` is an array type,
   which no type argument is (3.5 rule 2). The length is
   the backend's: lowering writes the operand a second time, as the
   operand of a `sizeof` (13.5), and `a` is still evaluated once. Four
   limits follow:
   * the array type is complete and not variably modified. C evaluates
     the operand of `sizeof` where it is a variable length array (C11
     6.5.3.4p2), so such an `a` would be evaluated twice. A variable
     length array and an array of unknown bound become slices through
     `slice_unchecked`, with the count that the program holds;
   * the operand declares no name whose scope reaches beyond it: no
     tag and no enumeration constant in the scope around it, and no
     label of the function. That is the third clause of the resolution
     property of 13.5 on the operand. In
     `slice_from_array(rows[sizeof(enum { K = 1 })])` the second
     writing would declare `K` again, and a label in a statement
     expression of the operand would be defined twice. A label that
     the statement expression declares with `__label__` is in scope in
     its block alone and is allowed;
   * the operand holds no `#pragma` line, which the second writing
     would repeat;
   * the size of an element is not 0. The length is the size of the
     array over the size of an element, and the GNU profile has types
     of size 0: a structure without members, an array of length 0. The
     size of a type is the backend's alone (13.3, P16), so the refusal
     is the backend's too: for such an element lowering names an array
     type of negative size, which the backend reports at the
     `slice_from_array` (13.5).

   A `slice_from_array` stands wherever an expression does, in a
   parameter list as in a block. Its value is a slice and no constant:
   `slice_from_array(a).len` is no integer constant expression, and an
   array of that size is a variable length array (13.5).
   `sizeof(a) / sizeof(a[0])` is the constant, as in C.
3. `slice_sub(s, lo, hi)` yields the elements `[lo, hi)` of `s`. `lo` and
   `hi` have the types that an index may have (rule 1) and are
   converted to `size_t`, and it traps unless `lo <= hi` and
   `hi <= s.len`. Each operand is evaluated once. Where C does not
   evaluate it there is nothing to test, as for an index (rule 9).
4. `slice_unchecked(p, n)` makes a slice from a pointer and a count that the
   compiler cannot verify. The count has an integer type no wider than
   `size_t`, as an index does (rule 1), so that no conversion drops the
   bits of a count the program holds.
5. `slice(T)` converts implicitly to `slice(const T)`, as `T *` converts to
   `const T *`, and in the places where C converts the pointer:
   * in a position that has a target type (3.3), where the expression
     of the position has the type `slice(T)` and the target type is
     `slice(const T)`. These are the places where C converts as if by
     assignment (C11 6.5.16.1), which are an initialiser, the right
     operand of `=`, an argument of a prototyped function and the
     operand of a `return`, and the argument of a constructor, which
     initialises its field. The expression of the position converts;
     where that expression is a parenthesised expression, a
     conditional or a comma expression, the operands that have its
     target type (3.3) convert instead, at any depth, each branch of a
     conditional on its own, and where it is a `try`, the value that
     the `try` yields converts (5.1);
   * in a conditional operator whose second and third operands are a
     `slice(T)` and a `slice(const T)`, in either order. The result
     is a `slice(const T)` and the other operand converts, as
     `c ? p : q` of a `T *` and a `const T *` is a `const T *` (C11
     6.5.15p6).

   The two are different structures of C, so the conversion makes a
   slice: that of a `slice_sub` over the whole operand, with nothing to
   test. The operand is evaluated once, and rule 9 holds for the
   conversion as for a `slice_sub`. A `slice_from_array` and a
   `slice_unchecked`, in parentheses or not, are converted by their
   pointer alone and are under no rule for it (13.5), so
   `slice(const uint8_t) bytes = slice_from_array(buffer);`,
   `str name = (slice_from_array(letters));` and
   `option(str) o = Some(slice_from_array(letters));` stand at file
   scope.
6. *Provisional (P13).* A string literal whose target type is `str` denotes
   a `str` over the characters of the literal. Its length excludes the
   terminating NUL, which is still present in storage. The literal is
   one of plain or UTF-8 characters, whose elements C11 writes as
   `char`; one of wide characters denotes no `str`. It stands in the
   places of rule 5: in a position whose target type is `str`, and as
   an operand of a conditional operator whose other operand is a `str`.
   Like a `slice_from_array`, it is under no rule for the conversion
   and stands at file scope (13.5).
7. A slice does not own its storage and says nothing about how long it
   lives. A slice of length 0 may have a null `data`. A `str` promises
   neither NUL termination nor an encoding.
8. `data` and `len` are ordinary members and can be read and, outside
   checked mode, written.
9. *Provisional (P28).* The test of an index and of a `slice_sub` is
   code of the place where it stands. Lowering writes it there as an
   expression and shares no function between the uses (13.5), so the
   test is compiled under the pragmas in force at its use and lies in
   the function and the section of that use, as `s.data[i]` does. A
   function that the uses shared would be compiled once, under the
   pragmas in force where the unit first uses it, for every later use.
   The operands stay in the expression, each at its own place and in
   the block of the use, and only their values go into temporaries. A
   compound literal in an operand so lives to the end of that block, as
   C has it (C11 6.5.2.5p5): `slice_from_array((int[]){ 1, 2, 3 })[i]`
   reads a live object. A name that an operand declares is in scope
   after the index, as it is after a subscript of C. The function
   declares the temporaries, and one limit follows: an index and a
   `slice_sub` that C evaluates stand in a function body. Outside one,
   in the definition of a generic type (3.5), in the head of a
   function, generic (section 7) or not, and in any other declaration
   of file scope, each is an error, as a `defer` statement is (section
   6 rule 11): no function is there to declare the temporaries. One
   that C does not evaluate has no test and no temporary (13.5) and
   stands wherever an expression does: `sizeof(s[0])` is the size of
   an element in the size of an array of file scope as in a function
   body. Whether C evaluates one is a judgement of `typec`, and no
   judgement lets an index reach an element without its test: where C
   evaluates what `typec` took it to leave alone, the program traps
   before it evaluates an operand (13.5).
10. A full expression (C11 6.8p4) that holds an index, a `slice_sub`
    or a conversion (rule 5) is not resumed after the same call of its
    function has begun to evaluate it again; where one is, the
    behaviour is undefined. A call that returns a second time resumes
    the full expression that holds it: `setjmp` and `sigsetjmp` in a
    statement expression of the GNU profile, `getcontext`, `vfork`,
    `__builtin_setjmp` and a function declared with the GNU attribute
    `returns_twice` are such calls. The function holds what a full
    expression has evaluated and not yet used: the value of each
    operand of an index or a `slice_sub` until the element is reached
    or the slice is made, and from there the address of the element,
    or the slice, until the rest of the expression uses it, as C holds
    the value of one operand of an expression while it evaluates the
    next. A call of the function has one place for each value, and a
    recursive call has places of its own. Where the same call of the
    function has begun to evaluate the same full expression between
    the two returns, the values that the resumed evaluation held are
    indeterminate, as C11 7.13.2.1p3 has the objects that a function
    changes between a `setjmp` and its `longjmp`. Two results are
    measured (13.5). The pointer of one evaluation meets the length
    of the other, and the index passes its test and reaches beyond the
    end of a slice whose array is live. And the address of an element
    that has passed its test is held across a call that returns twice
    in another argument, as in
    `put(&s[idx()], ({ ... setjmp ... }))`, and the resumed call
    stores through the address of the later evaluation, into an array
    that is freed. The second is what C does with `&a[i]` in that
    argument, and it is why the limit is over the full expression and
    not over the operands of the index: no form of the test reaches a
    value that the backend holds. Where the call of the function has
    not begun the full expression again, the values are those that the
    evaluation had, and the test holds. `typec` refuses no expression
    for this and writes the test no other way: the backend alone knows
    which calls return twice. Volatile temporaries would keep the
    pointer and the length of one evaluation together, at a cost that
    P28 records (section 15), and would leave every value that the
    backend holds. The owner's decision is this rule: behaviour that
    is undefined and documented here, with plain temporaries, over
    volatile ones (13.5).

`slice` is a universe generic type with one piece of syntax, `[]`. The three
functions are universe names that the compiler implements at each use; they
need no library and no function of the unit. Bounds checks address reads and
writes past the end of a live buffer, and nothing else.

## 9. Interfaces and privacy

### 9.1 Interfaces

A `.tci` file is a header written in Type-C: type declarations, function
prototypes, generic function definitions and macros. `#include` works on it
as on any header. There is no module system, no metadata file and no import
statement.

- Types and functions follow C's rules across translation units. Each unit
  sees a declaration by including it, and consistency between units rests
  on shared headers, as it does for C structs.
- A `.tc` file that includes its own `.tci` has its definitions checked
  against the interface by C's redeclaration rules.
- A representation is hidden by declaring `type N;` in the interface and
  defining the variant in the `.tc` file. Clients can then hold only `N *`.

Rationale. A separate interface format with compiler-managed metadata buys
one instance per program and cross-module privacy for generic bodies. It
costs a build model that only `typec` understands. Textual headers cost
nothing to adopt and are what principle 7 asks for.

### 9.2 `private`

```c
/* ir.tci */
type instruction = private
    | Move(reg dst, reg src)
    | Load(reg dst, address src);
type symbol = private distinct uint32_t;

instruction make_move(reg dst, reg src);
symbol intern(str name);
```

1. `private` restricts creating values to the *owner* of the type: for a
   variant, constructor expressions; for a distinct type, casts to it.
   Everything else stays open. Clients match on a private variant, read its
   fields, and cast a private distinct value to its underlying type. The
   check is syntactic: every cast to a private distinct type outside its
   owner is refused, including those that create no value, such as
   `sizeof((symbol)1)` and the identity cast `(symbol)s`.
2. The owner is the text of the file that contains the
   declaration and, when that file is `M.tci`, the text of the primary
   source file `M.tc` of the translation unit.
   - `M.tci` and `M.tc` compare by their last component, the path split
     on `/` only, because the backend names an interface by the `-I` path it
     found it through, not by where the module keeps it.
   - The primary source file is the bottom of the include stack that the
     line markers describe, so an `M.tc` that another file includes owns
     nothing of `M.tci`.
   - A variant declared `type N;` in one file and defined `private` in
     another belongs to the file of the definition, which is where
     `private` is written.
3. Tokens that a macro produces belong to the file of the expansion (2.4),
   so a macro defined in `M.tci` does not carry the owner's rights into a
   client.
4. `private` is an interface convention that the compiler enforces between
   Type-C files. Only Type-C text is bound: C text, such as a header that
   a Type-C file includes, may cast to a private distinct type. `private`
   is a design aid, not a security boundary. The zero value is available
   to every client: `(T){0}` writes it in any expression, as the
   initialisers `{0}` and `{}` do in a declaration, because a compound
   literal is neither a cast nor a constructor expression and every
   variant and distinct type takes these initialisers (3.2 rule 7, 3.4).
   A compound literal of a private distinct type with another value,
   `(symbol){7}`, is refused by 3.4, under which an `int` becomes a
   `symbol` only by a cast, and that cast by rule 1. C code or unchecked
   Type-C can write any bytes, and a line marker in the source can name
   the owner's file and so claim its rights.
   Type-C text also makes a private value without a cast or a
   constructor through any operation that reinterprets storage, such as a
   pointer conversion (`*(symbol *)p`), a union member, `va_arg` or
   copying bytes; these stay outside the rule, because refusing pointer
   conversions would break `malloc` code. Bounding them belongs to checked
   mode (section 11).

Rationale for ownership by file name. It needs no declaration of who owns
a type and no build model. In Pilot A one module owns a private variant
and a private distinct type, and the rule holds through an include chain
in which every file reaches `type.tci` through one shared header. Its cost
is that a header owns nothing unless a source file of its name exists, so
the types of each module stand in that module's own `.tci`.

### 9.3 C clients

`typec --emit-c-header M.tci` writes `M.h`, the lowered form (section
10) of the declarations in `M.tci`, for C compilers: variants as tagged
structs, distinct types as typedefs, and function prototypes. An
`#include` of another `.tci` becomes an `#include` of its `.h`. Generic
declarations are omitted. An instance that `M.tci` names is written as
10.3 writes it in a translation unit, by the same code: the forward
declarations of the tags that its arguments name, the typedefs of its
arguments, and its declaration and definition inside the packing
bracket. A C client and a Type-C unit therefore see one layout.

The header differs from a translation unit in three respects.

- The whole header stands between `#ifndef M`, `#define M` and `#endif`,
  where the macro `M` is the include guard of the header, so a client
  may include it more than once: C lets neither the structure nor the
  enumeration of a variant be defined twice. The guard is named from
  the last component of the interface's path by the scheme of 13.5,
  which is how 9.2 rule 2 identifies an interface. Two interfaces with
  the same last component therefore have one guard, and a client that
  includes the headers of both gets the text of the first alone: the
  second is skipped with no message, and the client meets its names
  as undeclared, or as what the first header declares under them.
  That is a limitation: a program whose headers one client includes
  keeps the last components of its interfaces distinct. More of the
  path in the guard would not lift it, since the backend names a file
  by the `-I` path it was found through (9.2 rule 2), and one header
  would then have a guard for each way of reaching its interface.
- It defines every instance that its own declarations write and that it
  can define. A translation unit defines an instance where a point
  needs it complete (10.3); a client may need complete an instance that
  the header only passes by pointer. So the header defines at its end
  every instance that an application in the declarations of `M.tci`
  names and that it has not defined, provided that everything the
  definition needs complete is complete there. An instance that fails
  this is left with its declaration alone. An instance that only a
  generated definition names is written as in a translation unit:
  declared, and defined where that definition needs it complete. An
  application inside a generic declaration of `M.tci` is of that
  kind, whether it names a type parameter or not: the declaration is
  omitted, and what it applies is first used where an instance of the
  generic is defined (10.3). The text of the interface thus bounds the
  instances that the header defines. With `type g(T) = struct { g(g(T))
  *next; T v; };` and a prototype that takes a `g(int) *`, the header
  defines `g(int)` and declares `g(g(int))`, which the definition names
  under a pointer; were that one defined too, its definition would name
  the next, without end.
- The definition of an instance, and nothing else, stands between
  `#ifndef G`, `#define G` and `#endif`, where the macro `G` is the
  include guard of that instance, named by the scheme of 13.5 from the
  module that defines its generic and from the instance name. C does
  not let a structure be defined twice. All else that the header
  writes for an instance may be repeated: a tag may be declared again,
  and C11 lets a typedef be declared again with the same type (6.7p3).

Two headers that name one instance, as each does with `vector(int)` in a
prototype, can then be included together in either order. Each writes
the declaration of the instance and the typedefs of its arguments for
itself, so its own text is valid wherever it stands. The first of them
that can define the instance defines it, and a later one finds the guard
defined. A header that cannot define the instance sets no guard, and so
keeps no later header from defining it: with `struct s` incomplete in
`a.h` and complete in `b.h`, `option(struct s)` is declared by both and
defined by `b.h`, whichever comes first. The guard of a header and the
guard of an instance are names of different kinds (13.5), so the two
never meet.

The guard of an instance names the module of its generic because the
instance name does not: two modules may each define a generic `vec`,
and `vec(int)` is `vec__i` to both (10.3). A client that includes a
header of each gets both definitions of `struct vec__i`, and its
compiler refuses the second as a redefinition (GCC 16 as C23 accepts
one that repeats the first member for member, which lays out alike).
A guard of the instance name alone would skip the second definition,
and the client would call the functions of the second module with the
layout of the first, with no message.

*Provisional.* An emitted header is written for C translation units.
Whether a Type-C unit may include one, as it does when it shares a C
header that includes one, is open. The guards are macros and do not
survive preprocessing, so what reaches the unit is the header's text
without them: names that begin with `__tc_`, which are errors in a
Type-C unit (2.3), names of instances, which their generics claim
(10.3), and definitions of instances that lowering would write again.
Package 4.1 of the plan settles it, either by keeping the
refusal, so that a Type-C unit includes the `.tci`, or by having
lowering take an instance that the header's text defines as defined.
The default is the refusal of 2.3.

The header is C11, as lowered code is (2.4), and a client compiles it as
C11 or later: C99 does not let a typedef be declared again. Its names
that begin with `__tc_` are reserved identifiers to C (C11 7.1.3), which
is what keeps a client's names from them (2.3). Clang reports them under
`-Wreserved-identifier` and `-Wreserved-macro-identifier`, which
`-Weverything` turns on and `-Wall`, `-Wextra` and `-pedantic` do not
(Apple Clang 21). In a header that ends with the probe of 10.3,
`-Weverything` also reports the padding of the probe's two structures
under `-Wpadded`, which GCC 16 has as well, outside `-Wall` and
`-Wextra`, and the `_Static_assert` and `_Alignof` of the probe under
`-Wpre-c11-compat`. The two structures are padded by design: a `char`
before an `int` is what makes a packing show in the alignment.

The header is specific to the target and configuration it was generated
for, and assumes that a client includes it as the command line of that
configuration leaves the compiler: with the same options that change a
layout, and outside the region of every `#pragma pack` and of every
other pragma that changes one (13.5). The bracket keeps a client's
`#pragma pack` from an instance and from nothing else in the header,
and it assumes the reading of `#pragma pack()` that 10.3 states; a
header that holds a bracket ends, inside its guard, with the probe of
that reading (10.3), so a client whose compiler reads the line
otherwise fails to compile. `typec` does not see a client's compile and
checks nothing else of this.

*Provisional.* The three type assertions that end a lowered unit (13.4)
are not written into an emitted header. In a header they would assert
the options of the client's compile, and what a header requires of its
client is for package 4.1 of the plan to decide. The same package
decides whether `--emit-c-header` refuses the options that change one
of those types, which the driver refuses for a `.tc` input (13.2). The
default is a header without the assertions and no such refusal.

C clients can read and write everything the header exposes, and no
Type-C rule binds them.

## 10. Representation and C ABI

### 10.1 Variants

The declaration of `expr` in 3.2 becomes this C:

```c
struct expr;
typedef struct expr expr;
enum expr_tag { expr_Number, expr_Variable, expr_Add, expr_Multiply };
struct expr {
    enum expr_tag tag;
    union {
        struct { long value; } Number;
        struct { str name; } Variable;
        struct { expr *left; expr *right; } Add;
        struct { expr *left; expr *right; } Multiply;
    } u;
};
```

1. Tags number the constructors from 0 in declaration order. Reordering or
   removing constructors changes the ABI. Appending one adds a tag on which
   code compiled earlier traps.
2. The tag has the generated enumeration type, with the
   size and alignment the target's C ABI gives that enumeration. Debuggers
   then print constructors by name, and layout has one authority. Pilot A
   gives no reason for a narrower tag: its structures shrink because the
   payloads share one union, and in the two largest the union is aligned
   to 16, so a smaller tag saves nothing.
3. The union `u` has one member per constructor that has fields, named after
   the constructor: a struct of the fields in order. A variant whose
   constructors all lack fields has no union.
4. The layout is whatever the C compiler gives this struct. `typec` does
   not compute it.
5. Bytes outside the tag and the fields of the active constructor, that is
   padding and the rest of the union, are unspecified. A variant is not a
   wire format, and copying one to an untrusted destination can disclose
   stale memory, as with any C struct that has padding.
6. The declaration claims the struct tag `expr`, the enum tag `expr_tag` and
   the enumerators `expr_C` in its scope, which, as in C (C11 6.2.1p4),
   includes the blocks and prototypes nested in it. Declaring any of them
   otherwise in the same block is an error, whichever comes first, and so
   is a declaration of one in a nested block or prototype, in C text such
   as a header included there as well. So is a name that two variants
   derive alike (`a_b` with `C` and `a` with `b_C`), and a type
   declaration in a block that claims a name an enclosing one claims. No
   claimed name is one that C reserves for any use or spells a keyword,
   since each begins as the name of its declaration does (3.1 rule 6). No
   declaration hides a claimed name, so it denotes the variant wherever
   the variant is in scope, and a constructor lowers to it (13.5). The
   typedef name `expr` is not claimed: a block may declare `int expr;`,
   as in C. Type-C code cannot name the claimed names; they exist for C
   clients, debuggers and the lowering. An incomplete
   variant `type expr;` claims the struct tag, as it declares the struct;
   the definition that completes it claims the rest, since only it knows
   the constructors. The enum tag and the enumerators are in scope from
   the start of the definition, before its first field, as in the C it
   lowers to, where the enumeration precedes the structure.
7. Where a definition completes `type expr;`, the forward declaration has
   already become `struct expr; typedef struct expr expr;`, and the
   definition becomes the rest.

### 10.2 Distinct types and aliases

`type D = distinct U;` becomes `typedef U D;`. C callers see `U` and lose
the check. An alias becomes a `typedef`. When its definition is a struct
or union specifier with a body, it becomes
`struct T; typedef struct T N; struct T { ... };`, so that the body can
use `N` (3.1 rule 2). `T` is the specifier's tag; an untagged specifier
takes the declared name as its tag, and the declaration claims that tag
as a variant does.

The leading `struct T;` of this form and of 10.1 declares the tag in the
scope of the declaration (C11 6.7.2.3p7). A `typedef struct T N;` alone
would name a tag `T` that an enclosing block declares, and the body
after it would define another.

### 10.3 Generic instances

An instance is named by its generic followed by `__`
and the encoding of each argument, so that the same application has the
same name in every translation unit:

| Type | Encoding |
| --- | --- |
| `void`, `_Bool`, `char`, `signed char`, `unsigned char` | `v` `b` `c` `a` `h` |
| `short`, `unsigned short`, `int`, `unsigned`, `long`, `unsigned long`, `long long`, `unsigned long long` | `s` `t` `i` `j` `l` `m` `x` `y` |
| `float`, `double`, `long double` | `f` `d` `e` |
| `_Complex` *T* | `C` *T* |
| Pointer to *T* | `P` *T* |
| Array of *T*, under a pointer | `Y` *T* *n* `E` for *n* elements and `Y` *T* `E` for an unknown size. A size that the front end does not compute (13.3, P16) is an error in an argument. |
| `_Atomic`, `restrict`, `volatile`, `const` qualified *T* | `A` *T*, `r` *T*, `V` *T*, `K` *T*; several are written in the order `A`, `r`, `V`, `K`. `_Atomic(`*T*`)` is the atomic-qualified *T*. The qualifiers of an array type are those of its element (C11 6.7.3p9) and are encoded there. |
| Struct, union or enum whose own specifier has the tag *name* | `T` *length* *name* |
| Variant, distinct type, or untagged struct, union or enum under the one name that a typedef or an alias gives it (3.5 rule 2) | *length* *name* |
| Application `G(args)` of a variant or distinct generic, or of an alias generic whose definition is a struct or union specifier with a body | `I` *length* `G` *args* `E` |
| Function type, under a pointer | `F` *return* *parameters* `E`. The parameters are `v` for an empty prototype and `N` for no prototype; `z` marks a trailing ellipsis; a parameter of array or function type is encoded as the pointer type that C adjusts it to (C11 6.7.6.3p7 and p8); top-level qualifiers of parameters are dropped, as in C's type compatibility (C11 6.7.6.3p15), which GCC and Clang both apply. Qualifiers of the return type are encoded, as they are part of the type (3.5 rule 3). |

`vector(int)` is `vector__i`, `vector(expr *)` is `vector__P4expr`, and
`result(uint32_t, parse_error)` is `result__j11parse_error` where
`uint32_t` is `unsigned int`. Arguments are encoded after typedef
expansion, so names depend on the target, like every other ABI fact; an
argument holds no attribute for the expansion to lose, nor a
`__typeof__` of an expression whose type may carry one (3.5 rule 2). An
application of an alias generic is expanded as a typedef name is, down
to the structure or union it names where its definition is a specifier
with a body (3.5 rule 3), which takes the application row:
`vector(ptr(int))` is `vector__Pi`, and `pair(vector(int), int)` is
`pair__I6vectoriEi`. The table is complete: a type without a row is no
type argument (3.5 rule 2). That leaves out the remaining types of the
GNU profile, among them `__int128`, `unsigned __int128`, the `_Float`
types, `__bf16` and vector types; no rule needs one as an argument.

Equal encodings are what makes two applications that are types of their
own the same type (3.5 rule 3); nothing else compares their arguments.
The table is therefore also the statement of which qualifiers tell two
such arguments apart: every one but a top-level qualifier of a parameter
in a function type. An application of a transparent alias is compared by
C's rules as the type it stands for (3.5 rule 3), and two of its
instances may be typedefs of one type: `fp__Ki` and `fp__i`, with `type
fp(T) = void (*)(T);`. A qualifier of a return type is part of the type
there as it is in the table (3.5 rule 3): `fr__Ki` and `fr__i`, with
`type fr(T) = T (*)(void);`, are typedefs of two types to the front end
and to Clang, and of one type to GCC (13.3).

The declaration of a type chooses its row, however a use spells the
type. A type that a Type-C declaration defines, a variant or an alias of
an untagged struct or union, is encoded by its Type-C name, also where C
text writes `struct expr` for it: the tag that 10.1 or 10.2 gives it is
not a tag of its own specifier. So `type n = struct { int x; };` is
encoded `1n`, as `typedef struct { int x; } n;` is, and the encoding
depends on the type alone, not on how the type lowers. The one rule
that names an untagged type (3.5 rule 2) reads an alias as it reads a
typedef: `type e = enum { A };` is `1e`, as `typedef enum { A } e;`
is, and `type s = const struct { int x; };` is `K1s`.

Every encoding is self-delimiting and none begins with `_`. A *length*
is the number of bytes of its *name*, in decimal; a character outside
ASCII counts as the bytes of its UTF-8 form. The name of a generic,
type or function, meets 3.1 rule 6 (7.1 rule 1), so the first
`__` of an instance name ends the name of its generic, and by the same
rule no name that a variant or an alias derives is an instance name. The
names `I_tag` and `I_C` that a variant instance `I` derives are none
either: they follow its last encoding with `_`. The encodings of the
arguments of one instance hold at most 4096 bytes together, which is a
translation limit of `typec` (3.5 rule 7).

Every type application and every use of a generic function names an
instance. An application of an alias generic is transparent as a type
(3.5 rule 3) and is encoded as the type it stands for, but it lowers to
the name of an instance like any other: C has no type specifier that
stands for a type name such as `T[2]` or `T (*)(T)`, and a typedef name
is one.

An instance is emitted at file scope in two steps. A type instance is
what 10.1 or 10.2 makes of the generic's definition under the instance
name; a function instance is a `static` function (7.3). In both, every
type parameter is written as the typedef of its argument, as said below
the steps.

1. Its declaration stands before the external declaration that holds its
   first use. For a variant instance, or an instance of an alias that is
   a struct, it is `struct I; typedef struct I I;`; for an alias that is
   a union, `union I; typedef union I I;`. An instance of a distinct
   generic, or of an alias generic whose definition is not a struct or
   union specifier with a body, is the one `typedef` of 10.2 and stands
   here whole. For a function instance it is the prototype, so the
   head of the generic is written twice, here and at the definition,
   and declares no type (3.5 rule 8).
2. Its definition is the rest of 10.1 or 10.2, or the function with its
   body. A type instance is defined before the external declaration that
   holds the first point that needs the type complete; one that no point
   needs complete is not defined. A function instance is defined before
   the external declaration that holds its first use, which the
   definition of its generic precedes (7.3 rule 2). A use that is not
   evaluated, in the operand of `sizeof` or in an association of
   `_Generic`, is a use all the same: lowering writes the instance's
   name there, so the instance is defined before it. The type instances
   that a definition needs complete are defined before it. The function
   instances that one external declaration uses, and those that their
   definitions use in turn, have their prototypes first, each after the
   type instances its head needs, and then their definitions, so that
   instances that call each other each see the other's prototype.

A point *needs a type complete* where typing requires a complete type
of the construct that stands there, and a Type-C construct needs what
the C that it lowers to needs (13.5). Typing types C as Clang does
(13.3), so the requirements are C11's and those that Clang adds for the
GNU profile and for `_Atomic`. They are cited here, not listed for
`typec` to keep in step with:

- the element type of an array declarator, wherever the declarator
  stands, under a pointer as well (6.7.6.2p1);
- the type of a member of a structure or union (6.7.2.1p3);
- the type of an object that a block defines (6.7p7), of an object
  with an initialiser (6.7.9p3) and of a tentative definition, which is
  said below;
- the return type and, after adjustment, the parameter types of a
  function definition (6.9.1p3, 6.7.6.3p4), and not those of a
  declarator that is no part of one (6.7.6.3p12);
- the return type of a called function and the type of each argument
  (6.5.2.2p1 and p4);
- the structure or union whose member is accessed (6.5.2.3);
- the operand of `sizeof` and of `_Alignof` (6.5.3.4p1), and so the
  type name of `_Alignas`, which is `_Alignas(_Alignof(`*type-name*`))`
  (6.7.5p5);
- the type pointed to in pointer arithmetic, in a subscript and under
  `++` and `--` (6.5.6p2 and p3, 6.5.16.2p1, 6.5.2.1p1, 6.5.2.4,
  6.5.3.1);
- the type of an lvalue that is converted to its value or assigned to
  (6.3.2.1p1 and p2);
- the type name of a compound literal (6.5.2.5p1) and of an association
  of `_Generic` (6.5.1.1p2);
- the type operand of `__builtin_offsetof`, which `offsetof` expands
  to, and of `__builtin_va_arg`, which `va_arg` expands to: Apple Clang
  21 and GCC 16 refuse an incomplete type in both;
- the type that `_Atomic` applies to, as a specifier and as a
  qualifier: Apple Clang 21 refuses `_Atomic(struct s) *p;` and
  `_Atomic struct s *p;` where `struct s` is incomplete. C11 does not
  require it (6.7.2.4p3, 6.7.3p3) and GCC 16 accepts both.

`typec` decides it in one place. Typing passes every type that a
construct requires complete, with the place of the construct, to one
function of the front end, and nothing else defines a type instance
(3.5 rules 5 and 7) or tells the placement rule below what is needed
complete; no construct instantiates on its own. A requirement of
Clang's that typing misses leaves an instance declared and not defined,
and the backend refuses the incomplete type: the failure is a refused
build and not a wrong program. That is a `typec` bug in text that
typing reads. In unread text (13.5) it is a limit: a `sizeof` of a
typedef name of an instance in an attribute argument defines nothing,
and a declaration before it that needs the type complete does.

A tentative definition is such a point for instances alone, whatever
its linkage: an instance that its type needs complete is defined before
it. It asks nothing of another type. C11 requires the type there of
internal linkage (6.9.2p3) and only by the end of the translation unit
of external linkage (6.9.2p2); GCC 16 and Apple Clang 21 accept
`struct s x; struct s { int a; };` and, the second with a warning, the
same with `static`, and both stay valid in Type-C. An instance cannot
wait as `struct s` does: only lowering completes it, at the place that
this section chooses, so the source has nothing to write later that
would complete it, and waiting for the end of the unit would add a
place that stands before no external declaration. The cost is one
refusal, and only the placement of an instance can fail here: with
`type box(T) = struct { T value; };`, the declaration
`box(struct s) b;` at file scope is an error before `struct s` is
completed, where C accepts a hand-written `struct box_s b;` whose
structure is defined later. `extern box(struct s) b;` there, or the
declaration after `struct s` is completed, is valid.

An instance names its arguments through typedefs. For each argument
type, the typedef `__tc_arg__` followed by the encoding of the type
stands at file scope, once, before the first instance that takes the
type, and every use of a type parameter in a definition is written as
that name, in type and function instances alike: `vector__Pi` holds
`__tc_arg__Pi *data;`. The argument's own text in place of the
parameter would be wrong: with `T` as `int *`, `const T` is a constant
pointer, which `const __tc_arg__Pi` is and `const int *` is not. Equal
encodings are one type, so one typedef serves every instance that takes
the type. The name is reserved (2.3) and follows the scheme of 13.5.

The typedef spells exactly the argument's type. An untagged type is
spelled through its one name (3.5 rule 2), which denotes the type with
the qualifiers of that name's declaration, and no qualifier written
beside a typedef name takes one of them away. Where that declaration
qualifies the type, the typedef writes `__typeof_unqual__(`*name*`)`
with the argument's own qualifiers: with
`typedef _Atomic struct { char a, b, c; } s;`, the argument `s` is the
atomic struct, whose typedef writes `_Atomic __typeof_unqual__(s)`, and
a generic function `f(T v)` called with an `s x` deduces `T` as the
unqualified struct (7.2 rule 1, after lvalue conversion), encoded `1s`,
whose typedef is `typedef __typeof_unqual__(s) __tc_arg__1s;`.
`typedef s __tc_arg__1s;` would make it atomic again, which Apple
Clang 21 lays out in 4 bytes and not 3. Deduction is the only way to
the unqualified form: no type name written in a program denotes it, as
a type name that writes `s` keeps its qualifiers and an argument holds
no `__typeof__` of an expression (3.5 rule 2, P26); only a type
parameter bound by deduction does. *Provisional:* GCC 16.2, Clang 21
and Apple Clang 21 take `__typeof_unqual__` in every dialect of 2.4
under `-pedantic-errors` and remove `_Atomic` with the other
qualifiers, as C23's `typeof_unqual` does; GCC 14, the oldest GCC that
13.3 supports, is unmeasured, and its release notes give the keyword in
every dialect. A run of the instance tests on it settles it; a release
without the keyword would raise the minimum.

The one name is moved text (13.5), a use of the first declarator that
gives it to the type, and its declaration where the typedef stands is
exact as well, which no declaration of the argument vouches for. An
application is an error where its typedef would stand after a
declaration of that name with an attribute or a `__typeof__` of an
expression, or after such a declaration, and so is one where the
declarator that gives the name holds an attribute. With
`typedef struct { int x[4]; } s; typedef s *p;`, a later
`typedef s s __attribute__((aligned(16)));` makes `option(p)` an error
after it, though `p` is exact: `typedef s *__tc_arg__P1s;` there would
point to the aligned type, and `p` to the other (Apple Clang 21), as it
would after `typedef struct { int x[4]; } s
__attribute__((aligned(16))), *p;` on both backends.

One rule places these texts: the typedef of an argument, the
declaration of an instance and its definition. Each stands directly
before an external declaration. Everything that it names is declared
before that external declaration, and everything that it needs complete
is complete before it; otherwise the application or call that puts the
text there is an error. So a typedef instance such as `a2(struct s)`
(3.5 rule 5) is refused where the declaration that holds its first use
is the one that completes `struct s`, and so is a function instance
whose body needs complete an argument that is not complete there.

The rule reads the lowered C, in three respects.

- The external declarations are those of the lowered C. A variant, or
  an alias whose definition is a struct or union specifier with a body,
  lowers to several (10.1, 10.2), and the instances that its body uses
  are declared, and defined where the body holds one by value, directly
  after its own forward declaration:
  `type expr = | Call(vector(expr *) args);` defines `vector__P4expr`
  after `typedef struct expr expr;` and before `enum expr_tag`. A
  variant that completes `type expr;` has the forward declaration that
  `type expr;` became (10.1 rule 7), so its instances stand at the
  start of its own text, before `enum expr_tag`.
- What lowering declares counts as declared: another generated text,
  and the forward declaration of a tag, which is said next.
- Several texts before one external declaration stand in the order of
  their first uses, and a use inside a generated text counts where
  that text stands. An application or a call inside a generic's
  definition, such as `vector(tree(T) *)` inside `tree`, is first used
  where an instance of that generic is defined, and what it puts there
  stands before that definition.

The typedef of an argument names a type that has a tag in the lowered C,
a variant or an alias of 10.2 included, by `struct`, `union` or `enum`
and the tag, and not by a typedef name. One instance then has one
definition wherever its first use falls, also before the typedef names
of its arguments are declared. For every structure or union tag `T`
that the typedef names so, `struct T;` or `union T;` stands at file
scope before it. The tag then denotes the type of file scope also where
the instance stands before that type's own declaration, and where a
prototype would otherwise declare a tag of its own (C11 6.2.1p4). An
enumeration has no such declaration in ISO C, which lowered code keeps
to (2.4), and an untagged type that a typedef names in the lowered C,
as the struct of `type s = const struct { int x; };` is (10.2), has
none at all, so
the placement rule leaves both to the source: an argument that holds
one is refused unless the source declares it before the external
declaration of the first use.

The generated line stands before the whole external declaration that
holds the application, so it must leave what the source wrote earlier
in that declaration as it was. A tag that an argument names is declared
at file scope (3.5 rule 2), by the source before the application or by
the application itself, and where the source declares it before a
mention the line changes nothing at that mention. The line changes one
kind of earlier text: a mention that declares the tag in a scope nested
in file scope, a parameter list or a block, only because no declaration
of the tag is visible there (C11 6.7.2.3p8). It would name the
structure of file scope instead. A specifier with a body and a `struct
X;` that is a declaration of its own declare a tag of their scope
whatever is visible (C11 6.7.2.3p6 and p7), and the line changes
neither. An application is therefore an error when a mention of its
argument's tag that stands before it in the same external declaration
declares the tag in a nested scope in the first of these ways. In

```c
struct H { int (*call)(struct X *); struct X { vec(struct X *) v; } x; };
```

the first `struct X` declares a tag of the prototype's own scope, so
`vec(struct X *)` is an error. With `struct X;` before `struct H`, or
with a member `struct X *p;` before `call`, the source declares the tag
at file scope before that mention, and the application is valid. A
structure that names itself in an argument, as `struct node {
option(struct node *) next; };` does, is valid as it stands: before the
application only the head of the structure mentions the tag, and it
declares the tag at file scope, as the generated line does.

`typec` does not read the body of a block literal (13.3), so it cannot
tell whether one holds such a mention. An application is an error as
well when a block literal stands before it in the same external
declaration and the source does not declare the tag at file scope
before the literal. In

```c
int (^probe)(void) = ^{ struct X *p = 0; struct X { int n; } y; /* ... */ },
    size = sizeof(ptr(struct X *));
```

`p` points to the structure that the body declares, and with the
generated line before the declaration it would point to the one of
file scope, with no message from the backend (Apple Clang 21).

Every text that the two steps write for an instance, a declaration as
much as a definition, stands between the lines `#pragma pack(push)` and
`#pragma pack()` before it and `#pragma pack(pop)` after it. The layout
of an instance is then the one that the command line gives, whatever
packing a pragma has put in force where its first use puts it, and the
packing around it stays as it was. The texts that stand at one place,
before an external declaration or after the forward declaration that
begins one, share one bracket, in their order. No rule need say
which of these texts can hold a layout, since all are written through
the one bracket. A
generic that is defined under `#pragma pack` is not packed by it; a
struct or union in a generic that is to be packed says so in the
definition, with `__attribute__((packed))`, which every instance then
carries. Under `-fpack-struct=n` the packing of the command line is
that option's, for an instance as for every other structure of the unit.
Other pragmas that change a layout are not kept from a type instance;
rule 4 of 7.3 keeps them from a function instance (13.5).

The bracket assumes that `#pragma pack()` restores the packing of the
command line and leaves the stack of `push` alone, as GCC and Clang
read it. How a backend reads the line is a fact of the compile and not
of a place in the unit, so one probe settles it for every bracket. A
unit that holds a bracket ends with

```c
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
_Static_assert(_Alignof(struct __tc_pack_probe_1)
               == _Alignof(struct __tc_pack_probe_2),
               "typec assumes '#pragma pack()' restores the packing "
               "of the command line (-fapple-pragma-pack or "
               "-fxl-pragma-pack?)");
```

among the assertions of 13.4, and an emitted header that holds one ends
with the same text inside its guard, the two structures named for the
header (9.3, 13.5). Each structure stands in a bracket, written as
every bracket is: the first inside a region that the probe packs to 1,
the second inside one that it packs to 2. Under the assumed reading
both have the packing of the command line, whatever it is, and are
aligned alike. Where the backend reads `#pragma pack()` as a pop, each
has the packing of its region and the assertion fails the build,
whichever route gave the backend that reading: an option, a wrapper, a
config file or the default of the target. No route passes the probe by,
so the driver refuses no option on this ground; the message names the
options known to give the other reading.

The probe compares two brackets with each other and with no structure of
the command line's packing, so it does not depend on where it stands.
Its outer `push` and `pop` leave the packing around it and the stack as
they were, also where a client includes a header inside a region of
`#pragma pack`. `_Alignof` needs no header, as `offsetof` would. The
probe tells the two readings apart where `int` is aligned to 2 or more
without packing; where it is aligned to 1, packing changes nothing of
the two structures. Apple Clang 21, Clang 22 and 23 and GCC 16 pass the
probe by default, under `-fpack-struct=1` and `-fpack-struct=2`, under
`-mms-bitfields`, and inside regions that pack to 1 and to 4, which they
leave in force. The three Clangs fail it under `-fapple-pragma-pack`,
with and without those two values of `-fpack-struct`, and Apple Clang 21
fails it for AIX, where the other reading is the default of the target.

*Provisional (P25).* A generic whose definition holds a pragma is an
error: a `#pragma` line, which is also how a `_Pragma` operator reaches
`typec`. The text of an instance then holds no pragma, and the three
lines of the bracket are the only packing pragmas that reach it. A
definition is written into each instance as its tokens (13.5), and a
pragma is a line and no token, so writing one there would need a form
of moved text that lowering does not have. A `#pragma pack` line of a
definition would stand inside the bracket and give the instance a
packing that the probe does not test. The definition of a generic is
expected to hold a pragma rarely. A count of the generic definitions
that hold one, in Pilot B or the corpus, settles the refusal; it stays
if that cannot settle it.

What a definition names means in the instance what it means in the
generic (3.5 rule 8).

A generic claims every name that begins with its own name and `__`, as
an ordinary identifier and as a tag, from its first declaration, and a
universe generic from the start of the unit. Every name of its
instances is one: a type instance's typedef name and tag and, where it
is a variant, the enum tag and the enumerators of 10.1; a function
instance's name. As with a variant's names (10.1 rule 6), any other
declaration of such a name where the generic is in scope, nested
blocks and prototypes included and in C text as well, is an error, and
so is one in the scope of the generic before it, whichever comes
first. In unread text (13.5) `typec` cannot tell a declaration from a
use, and an enumerator that
`__attribute__((aligned(sizeof(enum { option__i_Some = 0 }))))`
declares is in scope in the block around the attribute, so every
identifier of the space in an attribute argument, the body of a block
literal or a function body that is passed through unread is an error
where the generic is in scope; the one scan of unread text (section 6
rule 13) refuses it. A `#pragma` line declares no ordinary identifier
or tag, and the scan does not look into one. The
cost is that unread text does not name an instance by its C name, as
`sizeof(option__i)` in an attribute argument would. A
block that declares `int max__i;` where `max` is a generic is refused,
whether or not the unit uses `max(int)`, and so is one that declares
`enum { option__i_Some };`, which would otherwise be what `Some` of an
`option(int)` lowers to there. A declaration of the generic's own name
in a block does not end the claim, as an instance of the generic may be
used there all the same. Claiming the whole space, rather than the
names of the instances that a unit uses, needs no list of those
instances and no point where each claim would begin; it costs the C
names of that form, which no rule needs a declaration of.

Rationale. The typedef name of a variant is not claimed, because only
the source names it. The names of an instance are written by the
lowering wherever the instance is used, so they are among the names that
no declaration may hide (13.5).

A generic variant instance is laid out as in 10.1 under its instance name.
A generic function instance is a function with internal linkage under its
instance name.

### 10.4 Functions and objects

Functions and objects that are not generic are C functions and objects
under their source names with their C types. Nothing is mangled, and no
runtime library is linked.

So a freestanding program (`-ffreestanding -nostdlib`) needs from its
environment what the same C needs there, and nothing more: the lowering
calls no function but the trap function that the program names with
`--trap-function` (10.5). That includes `memcpy`, `memmove`, `memset`
and `memcmp`, which GCC and Clang require of every freestanding
environment and call for copies and initialisers. The one fact that
Type-C adds is the trap: GCC lowers `__builtin_trap` to a call of
`abort` on a target without a trap instruction.

### 10.5 Traps

A *trap* stops execution at the point of failure and never returns control
to the failing code. By default it is `__builtin_trap()` on GNU-compatible
compilers. `--trap-function=name` calls `_Noreturn void name(void)`, which
the program supplies, before the builtin; freestanding targets use this to
report the failure. Where the compiler has no such builtin, the call is
followed by an endless loop. The traps are: an invalid tag in `match`,
in a single-pattern test (4.5) or in `try` (5.1 rule 2), the end of a
match arm, the end of a block that holds a `defer` statement and cannot
complete (section 6 rule 1), a slice index or sub-slice out of range,
and the checks of checked mode.

### 10.6 What C code sees

| Type-C | C |
| --- | --- |
| Variant | Tagged struct (10.1), by value |
| Distinct type | Its underlying type |
| Type application | Struct, union or typedef under the instance name, written as 10.3 writes an instance; an emitted header carries the same text, with the definition of each instance under an include guard (9.3) |
| `option`, `result`, `slice`, `str` | Instances of the universe generics |
| Non-generic function | The same function |
| Generic function | Nothing; wrap an instance (7.3) |

## 11. Checked mode

Checked mode is a per-file opt-in that rejects or guards the operations
through which C code corrupts memory. It is specified in two tiers. Tier 1
is a rule set to prototype. Tier 2 is an open problem with a candidate
answer.

### 11.1 Scope and trust

1. `#pragma typec checked`, at file scope in Type-C text, makes the rest of
   that file *checked text*; `#pragma typec unchecked` ends it. The state
   does not carry into an included file or out of one. In Type-C text
   a `#pragma typec` line stands outside every external declaration
   and is an error inside one, which is in a function body and also in
   a structure body or a parameter list at file scope. In C text the
   line is ignored, as C11 6.10.6p1 ignores a pragma that the
   implementation does not recognise, so C text keeps the meaning C
   gives it (2.2). The line sets the state of the text of its file
   after it. Text that an `#include` line inside an external
   declaration brings in keeps the state of its own file, and 11.2
   applies to the text that is checked. Every kind of moved text
   (13.5) stands inside an external declaration, so no moved text
   holds a line that sets the state: the rule names no kind of moved
   text and can miss none.
2. A function defined in checked text is a *checked function*, and its body
   obeys 11.2.
3. A function declared in checked text is a *trusted contract*: its author
   asserts that it upholds what checked callers assume, even if it is
   implemented in C.
4. Checked code names only checked functions and trusted contracts,
   whether to call them or to take their address. Any other function is
   named inside an `unsafe` block.
5. `unsafe { ... }` suspends 11.2 for the block. Code inside must leave
   every value that flows back into checked code in the state checked code
   assumes; the compiler does not verify that. In unchecked text `unsafe`
   has no effect.

Wrapping a C library for checked code means writing a `.tci` in checked
text that declares the functions that are safe to call as they are, and
checked wrapper functions around the rest.

### 11.2 Tier 1: bounds, null and initialisation

*Provisional (P17).* In the body of a checked function:

1. A dereference, `*p`, `p->m` or a `*` sub-pattern that selection
   follows (4.7 rule 5), traps if the pointer is null. The check
   is omitted where flow analysis shows the pointer is not null.
2. Pointer arithmetic is rejected: `p + n`, `p - q`, `p[i]`, `++p`, and
   relational comparison of pointers. Indexed access goes through slices
   and arrays.
3. Subscripting an array lvalue of known bound is bounds-checked, at compile
   time when the index is constant. Subscripting an array of unknown bound
   is rejected, and so is declaring a variable length array.
4. An array converts to a pointer only as the operand of `slice_from_array`,
   `sizeof` or `&`.
5. A conversion, explicit or implicit, between pointers to different types,
   between a pointer and an integer, or from `void *` is rejected.
   Conversion to `void *` and conversions that only add qualifiers are
   allowed. For this rule a distinct type counts as its underlying type.
6. Access to a member of a C union is rejected; variants replace unions.
7. Every automatic object is definitely assigned before it is read or its
   address is taken. An object is assigned by its initialiser or by an
   assignment to the whole object; assigning its members one by one does
   not count.
8. A slice object or sub-object is initialised only from an expression of
   slice type or by `{0}`. `slice_unchecked` and assignment to the members
   of a slice are rejected. A slice then comes only from
   `slice_from_array`, `slice_sub`, a `str` literal, the conversion to a
   const element type, or a copy.
9. Defining a variadic function, using `va_arg`, and inline assembly are
   rejected.
10. A call through a function pointer is allowed. Rule 4 of 11.1 ensures
    that checked code makes such pointers only from checked functions and
    trusted contracts.

What tier 1 gives: a checked function does not access storage outside the
bounds of an object, dereference null, read an uninitialised automatic
object, or create an invalid variant value, **provided that every pointer
and slice it uses refers to a live object**, that its inputs were produced
under the same rules, and that the trusted contracts and `unsafe` blocks it
relies on are correct. Signed overflow, shifts, division by zero, data
races and aliasing violations are outside it; sanitizers cover those.

### 11.3 Tier 2: lifetimes

*Provisional (P18).* Tier 1 assumes that pointers are live. Checking that
needs a lifetime discipline for pointers to automatic objects and for
pointers into *regions*, the bump allocators over caller-provided storage
that suit compiler data structures.

The obstacle is known. A discipline that lets a pointer be stored in memory
must track exactly where the object that holds it lives. If a pointer to a
long-lived mutable object may be treated as pointing to a shorter-lived
one, a short-lived pointer can be stored through that view and then
outlives its target through the original pointer. Cyclone answers this
with region parameters on types, Rust with lifetimes and borrow rules. A
rule set with neither is unsound or too restrictive to express linked data.

The candidate for Type-C is *homogeneous regions*:

- Every object lives in one region: a lexical region object, the block of
  an automatic object, or static storage.
- A pointer stored in memory points into the region of the object that
  holds it, or to const static storage. Pointers that cross regions exist
  only in automatic variables and parameters and cannot be stored.
- Links that cross regions are distinct-type ids rather than pointers.
- A function signature relates the regions of its pointer parameters and
  its result through annotations; the candidate spellings are `returns(r)`
  and `in(r)`.

This candidate has no soundness argument yet and its restrictions have not
been tried on real code. Until both are done, checked mode makes no
lifetime claim, and a region is an ordinary library type, a bump allocator
whose allocation function returns `result(T *, alloc_error)`, with no
compiler support.

## 12. Outside the core

These features are not part of the language. Each entry says what problem
the feature would solve and what evidence would bring it in. Adding one is
a design change to this document, not an implementation detail.

| Feature | Sketch | Evidence that would bring it in |
| --- | --- | --- |
| Binding by reference | `case Block(&stmts):` binds a pointer to the field, for in-place update of a payload. | A lifetime tier in checked mode (11.3) that keeps a pointer into a payload from outliving an assignment that changes the object's tag. Pilot A shows the need (4.1): 24 payload updates, and payloads moved behind pointers to allow them. |
| Constant patterns | `case Add(*Number(0), r):`, with an integer, character or enumeration constant as a sub-pattern (4.7). Needs a test of equality beside the tests of tags, a `default` wherever a constant stands, and a rule that tells a misspelled enumeration constant from a binding, which the type of the position cannot do: such a constant fits any integer position. | Arms in pilot code that bind a field only to compare it with a constant. |
| `try` on `option` | Returns `None` from a function that returns an `option`. | Repeated hand-written propagation of `None`. |
| Expression `match` | A match that yields a value. | Real code where a local assigned in each arm reads materially worse. |
| Constraints | `requires(...)` on type parameters, resolved statically. Needs overloading or named instances. | Measured cost of function-pointer operations in the Stage 3 library: time, and noise at call sites. |
| Deduction from the target type | `vector(int) v = vector_new(8);` | Frequency of explicit instances in pilot code (P11). |
| Declarations typed by their initialiser | `auto r = parse_numbers(text);` gives `r` the type of the initialiser after lvalue conversion, as GNU `__auto_type` and C23 `auto` do. Block-scope objects with an initialiser only: never parameters, return types or file-scope objects, so every interface still states its types. One expression decides the type, so this is not the pervasive inference that principle 3 excludes. | Local declarations in the Stage 2 pilots that repeat a long generic type their initialiser already names, and whether passing `__auto_type` through from the GNU profile suffices. |
| External instances | One definition of an instance per program. | Measured code growth from per-unit instances (P12). |
| Operations on distinct types | Declared arithmetic, so that `meters + meters` is `meters`. | Casts that dominate real arithmetic on distinct values. |
| Tag ordinal | The tag as an integer, for tables and serialisation. | Tables in pilot code that a `match` expresses badly. |
| Compact layouts | Smaller tags; `option(T *)` as a nullable pointer. An ABI change, so opt-in. | Measured size of pilot data against hand-written C (10.1). |
| Equality and hashing | `==` on variants or a `derive` declaration. Needs a policy for pointers, floating point and cycles. | Hand-written equality functions that recur in pilot code. |
| Closures | A code pointer with an environment pointer; no allocation. Needs capture rules and tier 2. | A lifetime tier that exists. |

## 13. Compiler

### 13.1 Shape

```text
typec [cc options] file.tc
   |
   |  cc -E                    the backend C compiler preprocesses
   v
tokens, line markers, pragmas
   |
   |  parse                    C11 + GNU profile + Type-C
   v
syntax tree; every node records the span of tokens it came from
   |
   |  resolve and type         C typing rules, then Type-C rules
   |  check                    exhaustiveness, reachability, privacy,
   |                           generic bodies, try/defer, checked mode
   v
typed tree
   |
   |  emit                     untouched spans verbatim,
   |                           Type-C nodes lowered to C11
   v
preprocessed C   --- cc -x cpp-output --->   object file
```

*Provisional (P19).* `typec` is a standalone program that owns a complete C
front end and no back end. It does not use a C compiler to learn types.

Rationale. The alternatives are to ask a C compiler for types through a
probe translation unit, or to extend Clang. A probe cannot resolve
constructors by target type, cannot keep distinct types apart reliably, and
cannot check a generic body against opaque type parameters, because the C
compiler has no notion of any of them; and the arm-termination rule alone
needs a full statement parser. Extending Clang gives complete C coverage
at once, but ties the language to a large C++ code base that must be
rebased continuously, gives up C output and with it every other C compiler
as a back end, and fits generics poorly into C-mode semantic analysis. A
front end of its own is the larger first step and the smaller total. A
second implementation inside a C compiler remains possible, since the
language is defined here and not by the tool.

### 13.2 Driver and preprocessing

- `typec` accepts the command line of the C compiler. Inputs with the
  suffix `.tc` go through the pipeline above; every other input and option
  is handed to the C compiler unchanged. `typec` therefore replaces `cc` in
  a makefile rule and works under make, ninja and cmake. Dependencies
  come from the preprocessing step, which gets the dependency options:
  with `-MD` or `-MMD` its file names the real output, and with `-M` or
  `-MM` it prints the rule in place of the preprocessed text and nothing
  is compiled. The rule of a `.tc` file thus names it and every header
  and `.tci` interface that it includes, as the backend names those of a
  `.c` file. `typec` writes no dependency file of its own: it reads no
  file but the preprocessed text, and a second writer would repeat the
  backend's rules for quoting and for `-MP`, `-MG` and `-MT`.
- The *backend* is the C compiler named by `--cc=` or `TYPEC_CC`, by default
  `cc`. GCC and Clang are supported, from the releases that 13.3 names.
- A backend that runs `typec` again, such as a `cc` first on `PATH` that
  is `typec` itself, would make `typec` start itself forever. `typec` sets
  `TYPEC_OUTER_CC` to the backend's name in the environment of every
  backend it runs, so the backend's whole process tree inherits it, and a
  `typec` that starts with it set refuses, as an error of its
  environment, naming that backend. The mark, rather than a comparison of
  the backend's file with `typec`'s, also catches a copy of `typec` and a
  wrapper that runs it, and needs no second copy of the `PATH` search
  that starting the backend does. Its costs: a nested `typec` that would
  end, such as a wrapper that runs `typec --cc=/usr/bin/cc`, is refused
  too, as is any `typec` that a long-lived process started by a backend
  (a compile server) runs later; and a hop that clears the environment,
  such as `env -i` or `sudo`, still loops. No use of a nested `typec` is
  known, so neither cost is worth more mechanism.
- *Provisional (P15).* The backend preprocesses: `typec` runs it with
  `-E -x c` and the user's options, parses the result, and compiles its
  own output with `-x cpp-output`. Macros are expanded once, by the
  compiler that compiles the result, so the two cannot disagree. The
  cost is that locations are a file and a line: columns and macro
  backtraces are not available, and backend warnings that depend on
  macro provenance or on comments can differ from a direct compile. The
  reader requires a line marker naming a file before the first token of
  the `-E` output, so options that remove line markers, however they
  reach the preprocessor, are refused. Without the markers every token,
  those of system headers included, would count as the input's own and
  so as Type-C text (2.1).
- The backend reads the emitted C as the reader did, which reads no
  trigraph. Under `-std=c11`, `-std=c17` or `-trigraphs` the `-E` step
  translates the trigraphs of the source, but one that a macro builds
  reaches its output: after `#define Q ?`, `Q?=pragma pack(1)` gives
  `??=pragma pack(1)`, which Clang 21 reads in `-x cpp-output` input
  under the same options as a pragma that `typec` never read, and `??/`
  as a line splice. The commands that compile emitted C therefore give
  Clang `-fno-trigraphs`, after the user's options so that `-trigraphs`
  does not turn trigraphs back on. GCC 16 reads no trigraph in
  preprocessed input under any option and refuses `-fno-trigraphs`, so
  it gets none. The commands depend on which compiler the backend is,
  which the target model names (13.3), so `typec` reads the model once,
  as the first step. `-Xclang -ftrigraphs` still reaches Clang's
  front end after the option, as any `-Xclang` option reaches it.
- `--emit-c` stops after emission and writes the C. `--emit-c-header` is
  described in 9.3.
- `--stats` prints on stderr what each `.tc` unit counts against the
  translation limits of 3.5 rule 7: the bytes of the preprocessed unit,
  those charged to the instance budget and to the output limit, the
  limit, the longest code of one instance and the longest name of a
  type declaration or generic function. P30 is settled by these
  counts, so `typec` reports them itself rather than leaving a
  measurement to reconstruct them. It also prints how many slice
  indexes, `slice_sub` expressions and conversions the unit and each of
  its instances hold with a test and without (section 8 rule 9), and
  how many of the tested indexes and `slice_sub`s hold a call or a
  statement expression in an operand after the first (rule 10): the
  counts that P28 reads.
- With a `.tc` input, `-fpack-struct` without a value is refused as an
  error of the command line: under it GCC ignores the three lines of
  the bracket that 10.3 writes around an instance and warns of each,
  for every instance (GCC 16.2), which fails a build under `-Werror`.
  `-fpack-struct=n` is accepted: the reset restores the option's
  packing, so an instance is laid out as every other structure of the
  unit is, and alike in every unit built with the same value, which C
  already requires of units that share a structure. The driver refuses
  no option for the way it makes the backend read `#pragma pack()`:
  `-fapple-pragma-pack` and `-fxl-pragma-pack` are passed on, and the
  probe of 10.3 fails the build wherever the backend then takes that
  reading, as it does for every other route to it, with a message that
  names the two. Apple Clang 21 takes the reading under
  `-fapple-pragma-pack`. Its driver ignores `-fxl-pragma-pack` for a
  target other than AIX, with the warning "argument unused during
  compilation": the reading stays the assumed one and the probe passes,
  as it should. The probe fails where the option reaches the front end
  through `-Xclang`, and for AIX, where the reading is the default.
- With a `.tc` input, the options known to change one of the three
  types that the front end assumes (13.4), `-funsigned-bitfields`,
  `-fsingle-precision-constant` and `-fshort-enums`, and their aliases,
  as `-fno-signed-bitfields`, are refused as an error of the command
  line. The refusal names the option before anything is compiled; the
  assertions of 13.4 cover the routes that the command line does not
  show. An option that changes a macro the target model reads (13.3),
  as `-funsigned-char` and `-fshort-wchar` do, reaches the model and is
  accepted.
- With a `.tc` input, a long option, one spelled with `--`, that the
  driver's table of options does not name is refused as an error of
  the command line, naming the option; an option that also has a form
  spelled with one `-` passes in that form. The table
  gives each option it names a role: the steps it reaches, or a
  refusal. Other options spelled with one `-` reach every step, which is
  right for those that select the target, the code or the warnings, but
  a long option the table lacks may mean anything: GCC 16 reads an
  unambiguous abbreviation of a long option as that option and any
  other `--NAME` as `-fNAME`, so `--write-user-dep` is `-MMD`,
  `--short-enums` is `-fshort-enums` and `--syntax-only` is
  `-fsyntax-only`, and aliases such as `--preprocess` for `-E` are many.
  Listing every such spelling would be a list that is never complete,
  and each one missed would reach every step unseen. The table names
  the long options whose role it knows, such as `--output`,
  `--include-directory` and `--target=`, and an option the table lacks
  fails loudly rather than reaching a step whose meaning it changes.
  Without a `.tc` input every option reaches the backend unchanged.
- With a `.tc` input, three more families of options are refused, each
  by a rule rather than a list of its members. An option that names a
  file of further options, a response file (`@FILE`), a GCC spec file
  (`-specs=`, `--specs`) or a Clang configuration file (`--config=`) or
  its directory (`--config-user-dir=`, `--config-system-dir=`), can add
  any option, `-E` included, to every step, and `typec` reads no such
  file. Every option that starts with `-d` is refused, as is GCC's
  `--dump`: GCC and Clang read the letters after `-d` as dumps, of
  which `-dD`, `-dM`, `-dN`, `-dU` and `-dI` change the preprocessed
  text, in any combination such as `-dDI`, and releases add letters.
  The options of other meaning spelled with `-d`, such as `-dumpbase`,
  `-dependency-file` and `-dead_strip`, have entries of their own in
  the table, which win as the longer spelling. Every option that starts
  with `-print-` or `--print-`, and `-dumpmachine`, `-dumpversion`,
  `-dumpfullversion` and `-dumpspecs`, is a query of the backend. GCC 16
  and Clang 21 print the answer of a query and compile nothing, but for
  three that serve other languages and print beside a compile: Clang's
  `-print-ivar-layout` and `-print-rocm-search-dirs` and GCC's
  `-print-objc-runtime-info`. `typec` refuses a query with a `.tc` input
  rather than answering it, since a command that both asks and names a
  `.tc` input has no use, and answering it would be a second way to run
  the backend; without a `.tc` input the query reaches the backend,
  which answers it. `typec`'s own `--print-target` is spelled out in the
  table and passes.
- These refusals name, before anything runs, the options that the
  command line shows. Options still reach every step by routes that it
  does not show: a `specs` file in a directory of `-B` or `--prefix` or
  of `GCC_EXEC_PREFIX`, Clang's default configuration files (which
  `--no-default-config` turns off and so passes), and `-Xclang`, `-Wp,`
  or `-Xpreprocessor` with `-dD`. Refusing `-B` would break cross and
  linker setups, and the other routes are the environment of the
  backend, so `typec` leaves them open. The reader refuses the
  preprocessed text that they change and the assertions of 13.4 catch a
  type that they change; another change, such as an `-E` that a spec
  file adds to the compile step, is the backend's own configuration,
  which `typec` does not inspect.
- Subprocesses are started with argument vectors, never through a shell.
  Intermediate files live in a private temporary directory.
- A backend step that fails ends `typec` with the backend's own status,
  or by the signal that ended it, as a direct compile would. `typec`'s
  own failures have statuses of their own, so that a build tool or a
  test runner tells them from the backend's without reading stderr: 80
  when `typec` refuses the program (a diagnostic about the source), 81
  for an error of its environment (the command line, a backend it cannot
  start or whose output is no target model, a file it cannot read or
  write)
  and 82 for an internal error, which is a bug in `typec`. *Provisional
  (P22).* The values assume that no backend exits with them, apart from
  a `typec` that a backend runs again, which refuses with 81: GCC and
  Clang exit with small statuses, statuses of the sysexits range (64 to
  78) and 128 plus a signal number, a shell with 126 or 127 for a
  command it cannot run, and distcc from 100 up.

### 13.3 Front end

**Parsing.** A hand-written recursive-descent parser over the complete
token array. C's grammar needs scope feedback for typedef names; Type-C
adds positional words that need lookahead to a matching parenthesis, and
the universe scope. All three are direct in recursive descent. The scope
rules (C11 6.2.1, the name spaces of 6.2.3 that scopes hold, and the
tags of 6.7.2.3) have one implementation, the parser's, and the tree
records their outcome: every declaration of an ordinary identifier or a
tag has an id, the token of its identifier, and the declaration of the
same name in the same scope and name space that it redeclares; every
use resolves, where it is read, to the declaration visible there or to
none. The declaration reader follows these links and keeps no scope of
its own; linkage (6.2.2), which joins declarations across scopes, is its
table keyed by name. A second walk that kept its own scope boundaries
would have to agree with the parser's at every point. Parsing needs the
kind of a name (a typedef name or not), never its type, in Type-C as in
C. Members belong to their structure and are resolved by type. A
label's scope is its function (6.2.1p3), so a jump to it resolves once
the function's body is read. The parser records each mention's label,
identified by the token of the first mention that resolves to it, and
refuses a `goto` to a label that its body does not define where the
body ends.

**Universe text.** The generic types of the universe scope are Type-C
text, the two lines of 3.6, which the reader reads in front of the own
text of a unit whose main file is Type-C text (2.1) into one token
array; that file alone decides, so no caller of the reader chooses.
The parser declares them in the universe scope (2.3), and the type
checker and lowering then treat them as any generic declaration, so
every identity that a token index gives (a declaration's id, a span, moved text) covers
them with no second source of the declarations. Their tokens belong to
a file `<universe>` that no line marker opens: a marker that names
`<universe>` opens an ordinary file of that name, which is C text.
Their lines carry flag 3, as typec's own assertions do (13.4), so the
instances written from them are exempt from the warnings that judge the
user's code.
Emission writes the unit's own text alone and refuses an edit of the
universe text.

**GNU profile.** The front end accepts the extensions that system headers
and common code use: attributes, including those among the qualifiers
of a pointer, at the start of a parenthesized declarator, before a
declarator after the first and after a label, C23's attribute
specifiers (`[[gnu::noipa]]`, `[[noreturn]]`) before a declaration, a
parameter or a member and as a null statement, read as the GNU
attributes they mean, `__extension__`,
alternate keyword spellings, assembler labels and statements, `typeof`,
statement expressions, label addresses and computed goto (`&&label`,
`goto *p`), local labels (`__label__`), the conditional without a
middle operand (`a ?: b`, typed as `a ? a : b` with `a` evaluated
once), `__real__` and `__imag__`, `__alignof__` of an expression,
`__builtin_types_compatible_p`, the variable-argument and `offsetof`
builtins, a table of
builtin functions with their types, the typedef names that GCC and
Clang declare before the first token (`__builtin_va_list`,
`__int128_t` and `__uint128_t` where the target has `__int128`, and
on AArch64 the Arm vector types that glibc names, the Neon
`__Float32x4_t` and `__Float64x2_t` and the SVE `__SVFloat32_t`,
`__SVFloat64_t` and `__SVBool_t`, with both compilers),
`__int128` where the backend's `__SIZEOF_INT128__` says that it has the
type, the optional floating types (`_Float16`, `_Float32`,
`_Float64`, `_Float128`, `_Float32x`, `_Float64x` and `__float128`),
the complex integer types (`_Complex int`, typed as unknown) and plain
`_Complex` for `_Complex double`, case ranges, range designators and
the obsolete `member:` designator, empty structures and `{}`
initialisers, a lone `;` at file scope and among members, and, for the
macOS SDK, block declarators and block literals (`^{ ... }`, `^(int x)
{ ... }`), nullability qualifiers, enumerations with a fixed
underlying type and a parameter list of `...` alone. One table holds
the builtin typedef names: the parser reads the names from it and the
declaration reader the types. Another holds the builtin functions that
the corpus calls and the macros of the system headers expand to, each with
the compilers that have it, the architectures that each has it on (Clang
lowers `__builtin_setjmp` on some only, an architecture that the target
model reads from the backend's macros), and its type: a prototype; a rule of its
own, which gives a call of a type-generic builtin such as
`__builtin_add_overflow` or `__atomic_load_n` its type from the
arguments; or unknown (P21), as for the vector builtins. The table
holds one more fact of a builtin function, which 7.1 rule 4 reads:
whether the values of its arguments alone decide the result of a call.
A builtin is held to inspect more, the type or the object behind an
argument or what the backend knows of it, until the backends'
documentation says that it does not. An undeclared
identifier is an error unless the table has it for the backend, and one
that only the other compiler has, or that the backend has on other
architectures only, is an error saying so, so a builtin is never
guessed. *Provisional:* no macro says which Arm vector types a backend
declares, so the architecture decides, as GCC 14 and Clang 21 declare
Neon's and SVE's on AArch64 whatever the target's features; a
later release that declares the names otherwise would settle it, and
without one the rule stays. *Provisional:* an optional floating type
is a keyword exactly where the backend's predefined macros say that it
has the type, `__FLTN_MANT_DIG__` for `_FloatN`, `__FLTNX_MANT_DIG__`
for `_FloatNx` and `__SIZEOF_FLOAT128__` for `__float128`, as on every
backend of the test hosts: where the compiler lacks the keyword, the C
library declares the spelling, as glibc declares `typedef __float128
_Float128;` for Clang, so no fixed keyword set reads glibc under both
GCC and Clang. No macro says that a backend reserves a spelling it
cannot use, as Apple Clang reserves `__float128` and GCC `_Float128x`;
typec reads such a spelling as an identifier, which only a program that
declares a reserved identifier (C11 7.1.3) can tell; GCC's `__float128`
is a builtin typedef name, which such a program can tell as well. Both
GCC and Clang reserve `__int128` on targets without the type, i386
among them, where typec reads it as an identifier in the same way. Only
x86-64 backends confirm the rule; a backend of another architecture
whose macros disagree with its keywords would settle it otherwise, and
without one the rule stays. A construct outside the profile is an error
that names it; the front end does not guess. GCC's nested functions are
outside the profile, as Clang has none. A function body whose `{` is C
text of a system header is not parsed: it is brace-matched and passed
through, because it is written for its own compiler and may use any of
that compiler's extensions. Such a body is C text of system headers
only, as a block literal is C text only (below): every token from its
`{` to its `}` decides, and one that is Type-C text, or C text of a
file that is no system header, is an error. The body is unread text
(13.5), and the one scan of the tokens that typing does not read
finds such a token (section 6 rule 13). A body is therefore passed
through unread only where every token of it is C text of a system
header, and no body that holds Type-C text goes unread: a `.tci` that
a system header includes inside a body is refused. A body whose `{`
is any other text is read, each token as the text it is, whatever an
include puts inside it. A macro of a system header that opens a body
which the user's text fills gives such a body: tokens of a macro
expansion belong to the file of the expansion (2.4), so its `{` is
the user's text. The reason for passing a body through holds for C
text alone: Type-C text that is found through `-isystem` or in a
default system directory is read, typed and lowered as any other
Type-C text is.

**Block literals.** *Provisional (P24).* A block literal is C text only:
one that holds a token of Type-C text, from its `^` to the brace that
closes its body, is an error. The one rule covers a literal that Type-C
text writes, one that an include puts Type-C text inside, and one that a
C macro builds around its argument, as `ASYNC(try f())` does. Typing
does not read the body of a block literal. The one scan of the tokens
that typing does not read passes over the body, for this rule and for
`_Defer` (section 6 rule 13). A Type-C
construct in the body, which typing finds for lowering, would reach the
backend as written; typing the body needs Clang's rules for blocks,
chiefly that a captured automatic variable is a `const` copy, without
which typec would answer a `_Generic` or lower a match on a captured
variant differently from Clang. The body is unread text, which keeps a
block literal out of moved text (13.5). Type-C code reaches an
API that takes a block through C text, or through the function-pointer
form that such APIs also have (`dispatch_async_f`). Type-C code on macOS
settles it: a block-taking API with no function-pointer form that Type-C
code needs would make typec type block bodies; the default is that
blocks stay C text.

**Typing.** The front end types every expression by C's rules: promotions,
usual arithmetic conversions, lvalues, qualifiers, composite types and
`_Generic`. Type-C rules need the type of any expression that can hold a
Type-C value, and that is any expression. Where GCC and Clang type a
construct differently, one rule decides (below).

**Target model.** Sizes of scalar types, the signedness of `char` and
the types behind `size_t`, `ptrdiff_t` and `wchar_t` are read from the
backend's predefined macros, obtained from the same compiler with the
options of the step that compiles the output. Preprocessing options such
as `-D` and `-undef` are left out: they cannot change the ABI of that
step, and `-D__SIZEOF_LONG__=4` would make the model lie. `typec` has no
target table of its own.

The front end assumes three types that no predefined macro states.
13.4 names them and asserts them in the emitted C, and the driver
refuses the options known to change one (13.2).

The model also names the backend, Clang when `__clang__` is defined and
GCC otherwise, with its major version (`__clang_major__` or
`__GNUC__`). The compiler decides the constructs whose types are
unknown (below).

`typec` refuses a release older than `Target.minimum_major_version`,
the one statement of the oldest supported releases. For Clang that is
the first release that types C as the front end does: Clang 20 keeps
`_Atomic` on a member of a structure value, where Clang 21 and 23,
Apple Clang 21 and the front end drop it. With
`struct t { _Atomic int a; } tf(void);`, Clang 20 selects `_Atomic int`
in `_Generic(tf().a, int: 1, _Atomic int: 2)`, and in the same with
`(0, tf().a)` or `x ? tf().a : tf().a` as the operand, and its
`__typeof__((0, tf().a))` is `_Atomic int`. Clang 19 also gives an enumerator
that `int` holds the type `int` in an enumeration whose values `int`
does not all hold, where later releases and GCC follow C23 6.7.2.2
(N3029) in every dialect and give every enumerator the enumerated type.
For GCC it is the oldest release that a test host runs. *Provisional:*
Apple numbers its Clang releases on its own and is held to the same
minimum, which only Apple Clang 21 confirms; an Apple release at or
above the minimum that types C as Clang 20 does would settle it
otherwise, and without one the minimum stays.

**No aggregate layout.** *Provisional (P16).* The size, alignment and
member offsets of struct, union and array types are opaque constants to
the front end. Expressions that use them are emitted as written and the
backend evaluates them; `_Static_assert` passes through. Packing pragmas,
bit-fields and layout attributes make this the part of C that is hardest
to duplicate, and a silent disagreement would be an ABI bug. A type
that follows from the value of such a constant is one that the front
end does not compute, and is unknown (P21): that of a conditional with
an operand that is a null pointer constant only where the constant is
0, as `(void *)(sizeof(struct s) - 4)` is, and that of a
`__builtin_choose_expr` whose condition holds one.

**The va_list type.** *Provisional (P20).* `__builtin_va_list` is an
opaque complete object type, compatible only with itself, whose
representation and size are the backend's: it is an array of one
structure on x86-64 and `char *` on i386 and arm64 Darwin, and with no
target table `typec` cannot know which. A parameter of that type is
therefore not adjusted to a pointer. Where compatibility depends on the
representation the reader is wrong both ways: it accepts `const va_list`
against `va_list`, which the backend then refuses on x86-64, and it
refuses `char *` against `va_list`, which i386 and arm64 Darwin accept.
Both are unportable code. Typing `__builtin_va_arg` and
the bodies that pass a `va_list` on settles it: if one needs the
representation, it comes from the backend, as the target model does;
otherwise the opaque type stays.

**Unknown types.** *Provisional (P21).* A type that the front end does
not compute is unknown, never guessed: Clang's block pointers,
the optional floating types, the Arm vector types, and the type that
an attribute applies to when the front end does not record the
attribute's effect
there: one without an entry in the table of effects that the front end
knows, as `mode` and `vector_size` change a type in ways it does not
model, or `noreturn`, `gnu_inline` and `overloadable` anywhere but in
the specifiers of a function declared at file scope or after its
declarator. Every question about an unknown type, such
as its size, class, completeness or compatibility, answers that it
depends on that type, and the front end reports an error only at the
first point that needs the answer, naming the construct: whether a
file-scope declaration declares a function, the value of a cast in a
constant expression, the enumerators of an enumeration whose integer
type is unknown. Elsewhere the backend checks: a redeclaration with an
unknown type is not compared where the type is unknown, and the
composite is the unknown type, since keeping the known side would guess
that the unknown one adds nothing to it. The size of an unknown type is
an opaque constant, as an aggregate's is (P16), so an SVE type, which
has no size, needs no model of sizeless types: the backend refuses its
size and arrays of it. An unknown type keeps
whether it is a function type where its declarator says so, since no
attribute makes a function of an object. Typing bodies (0.9b) and the
corpus settle it: a point that often needs an unknown type's properties
makes the front end type that construct; the default is that unknown
types stay.

The table of effects holds one more fact of an attribute: a mark on
each that, on a declaration of a function, breaks on its own the
property on which the form of a `return` in the scope of a `defer`
statement rests (13.5), that the function's name names exactly one
function which `__typeof__` may name. 13.5 says what a mark refuses.
A mark is a fact of the attribute alone: `typec` reads no attribute
arguments, and a mark does not ask which backend compiles the unit, as
the refusal for `target` does not (13.5). It applies to the attribute
under the one name that reading gives it, however the source spells
it. The table records the spellings of each attribute, and the one
function that names an attribute reads them from it: the GNU
spelling, as `overloadable` and `__overloadable__`; in a C23
specifier `[[gnu::x]]`; and Clang's `[[clang::x]]` where Clang
defines that spelling. No uniform mapping gives the last: Apple Clang
21 accepts `[[clang::overloadable]]` and ignores
`[[clang::diagnose_if(...)]]` and `[[clang::noreturn]]` with a
warning. The table is the one list of marks:

- `overloadable`. The front end does not tell the members of an
  overload set from redeclarations of one of them ("Overloads" below),
  so the attribute alone decides. Apple Clang 21 refuses the `f` of the
  typedef where two overloads are in scope, and in a plain function
  with an overload declared beside it; it takes the form for a set of
  one.
- `cpu_dispatch` and `cpu_specific`, which make the name stand for
  several versions of a function. Apple Clang 21 refuses the `f` for
  `cpu_specific`, with and without a `cpu_dispatch` declaration.
- `target_clones` and `target_version`, on the property alone, since
  the name stands for more than one function: both backends take the
  form for `target_clones`, and Clang for `target_version` on AArch64.
- `unavailable`, which forbids a mention of the name. GCC 16 refuses
  the `f` with "'f' is unavailable"; Apple Clang 21 takes the form.
- `availability`, whatever its arguments and whichever the backend.
  One that makes the function unavailable forbids a mention of the
  name: GCC 16 on Darwin refuses the `f` for `availability(macos,
  unavailable)` with the same message and takes it for an
  `availability` that makes nothing unavailable, and Apple Clang 21
  takes the form whatever the arguments. `typec` cannot tell the two
  kinds apart without reading the arguments, so every `availability`
  is marked. Few functions that a program defines carry the attribute,
  and a refusal for a marked attribute has a name of its own (13.5),
  by which a pilot counts it.
- Clang's `diagnose_if`, whatever its arguments. It reports a mention
  of the name where its condition holds, as an error or as a warning,
  whichever an argument says, and `typec` cannot tell which without
  reading the arguments, so every `diagnose_if` is marked. Apple Clang
  21 reports the `f` where the condition holds and reads no parameter.

`deprecated` has no mark: it reports a mention of the name as a
warning, and the table of diagnostics in 13.5 holds what the form adds
for it. Under `-Werror` the added warning breaks a build; a mark is
for what reports an error by itself. An attribute that is found to
break the form joins the table with a mark; 13.5 says what an attribute
without one means there.

**Attributes in a generic.** The table of effects holds a last fact of
an attribute: whether both backends take it alike wherever it stands
and whatever it is given, that is on a subject of every type, on every
kind of subject and with every argument list. The *subject* of an
attribute is what it stands on: the object, member, parameter,
function or typedef name that its declaration declares, the type of
the type name that holds it, or the structure, union or enumeration
whose specifier holds it. A subject mentions a type parameter where
its type does, or where it is a type that does (7.1 rule 4). One rule
reads the fact, for a generic type and a generic function alike (3.5
rule 4; 7.1 rules 3 and 6): **in the definition of a generic, an
attribute whose subject mentions a type parameter, or whose arguments
name something that the definition declares, is an error unless the
table records that fact of it.** An alignment specifier, `_Alignas`,
is read under the rule as the attribute `aligned`.

The backend judges an attribute against the types of the instance, by
its subject and by its arguments, so the fact covers both:

- By the type of the subject. `vector_size(16)`, on a member and in
  the type name of a `sizeof`, and `mode(DI)` on an object are errors
  of both backends where the type is a structure. Over a parameter of
  type `T`, `alloc_size(1)` is an error of Apple Clang 21 unless the
  argument is an integer type,
  `format(printf, 1, 2)` an error of both backends unless it is a
  string type, and `access(read_only, 1)` an error of GCC 16 unless it
  is a pointer. `returns_nonnull`, which has no arguments, is an error
  of GCC 16 on a function that returns `T` unless the argument is a
  pointer; both backends ignore `malloc` on that function, and
  `nonnull(1)` over that parameter, with a warning where it is not
  one. `_Alignas(8)` is an error of both on an object of a type whose
  alignment is 16.
- By the kind of the subject. Both backends take `aligned(8)` on an
  object of type `T`. On a typedef name of `T` they take it too, and
  then refuse an array of that name wherever the size of `T` is no
  multiple of 8, as for a `short`.
- By the arguments. `cleanup(f)` on an object of type `T` is an error
  of both backends unless the parameter of `f` points to the
  argument's type or to `void`. `aligned(sizeof(t))` on an array of
  `char`, with `t` a parameter of type `T`, asks for an alignment of
  the size of `T`, and one of 12 bytes is an error of both.

The fact is the attribute's alone, as a mark is: `typec` models
neither the kinds of subject that each attribute takes nor the form
of its arguments, so one fact per attribute must hold for all of
them. Of the arguments `typec` looks at the identifiers and at
nothing else (13.5). One that denotes a parameter of the generic or
something that its body declares ties the arguments to the instance,
through a type as in `sizeof(t)` or through a value as with a `const`
object whose initialiser depends on a type parameter (7.1 rule 4). An
identifier that denotes a type parameter is an error in any attribute
argument (13.5), and what is declared at file scope is the same for
every instance. So `nonnull(1)` is refused also where parameter 1 is
a `T *`: a rule that read the arguments for the parameters they name
would need the form of every attribute's arguments, and would still
pass `returns_nonnull`. An attribute on a subject that mentions no
type parameter, with arguments that name nothing of the definition,
is outside the rule: `FILE *f __attribute__((cleanup(close_file)));`
stands in the body of a generic function.

`always_inline`, `cold`, `noinline` and `unused` have the fact: on a
function, a parameter, an object, a member, a typedef name and in a
type name, both backends say the same of each for a `short` and for a
structure (Apple Clang 21, GCC 16). An attribute is held not to have it
until a measurement with both backends shows that they take it alike in
all three respects. The table errs to the safe side: an attribute that
it does not hold, or does not record as taken alike, is refused, so a
gap in the table costs a refusal and never an instance that the backend
rejects.

**Where GCC and Clang differ.** The front end types C as Clang does,
whichever the backend is. GCC types a few constructs otherwise: the
value of a bit-field narrower than its type, which it gives a type of
that width and keeps through assignment, `++`, `--`, the comma operator,
a statement expression, `__real__` and `__imag__`; `__real__` of a
bit-field, which is the bit-field itself, where Clang takes its value;
the promotion of a bit-field of a type ranked above `int` and at least
as wide as `int`, which it leaves unpromoted; a member found through a
`const` or `volatile` anonymous member, which it qualifies as that
member; `__builtin_types_compatible_p` of an `_Atomic` type and one that is not,
as it drops `_Atomic` with the other top-level qualifiers; a
function of an old-style definition with parameters, to which Clang
gives the prototype of their promoted types, which a later declaration
without a prototype inherits and the uses that the definition reaches do
not see (C11 6.9.1p7, DR 316), where GCC gives the definition no
prototype of its own and keeps one before it; the composite of an
enumerated type and its compatible integer type, which is the enumerated
type in GCC and the integer type in Clang; and a function type whose
return type is qualified with `const`, `volatile` or `restrict`, from
which it drops those three qualifiers (C17 6.7.6.3p5), so that `const
int (void)` and `int (void)` are one type, where Clang keeps them and
holds the two incompatible: with `const int cf(void);`, `int
(*p)(void) = cf;` is an error to Clang and none to GCC. GCC keeps
`_Atomic` in the function type, as Clang does, and both refuse
`_Atomic int af(void); int af(void);`, so the entry covers the three
qualifiers and not `_Atomic`. GCC does drop `_Atomic` from the value of
a call of such a function, and of a cast to an `_Atomic` type, which
Clang keeps and converts no further, so that Clang takes the value
only whole and as the left operand of `*`, `/`, `%`, `+`, `-`, `&`, `^`
and `|`: `_Generic(af(), int: 1, default: 2)` is 1 in GCC and 2 in
Clang. With
GCC as the backend each of these has an unknown type
(P21) wherever GCC's type differs from Clang's, and the real part of a
bit-field, which differs in being an lvalue, has one too: the front end
neither guesses GCC's type nor refuses what GCC accepts, and the error
at a point that needs the type names the construct and says that GCC
types it otherwise. For the return type that is those three qualifiers
alone: a comparison of two function types that turns on them has an
unknown answer, so the initialiser of `p` is an error with Clang as
the backend
and is left to GCC with GCC. One table, `Backend_difference`, holds the
constructs, what GCC does and a probe of each, and decides for every
place that types one. GCC 14 to 16 and Clang 20 to 22 confirm every
entry but the old-style definition and the composite, which GCC 16 and
Clang 21 to 23 confirm, and the return type and the call or cast, which
are measured on GCC 16.2 and Apple Clang 21 only. One rule for the class
replaces a policy per construct: the front end models one compiler's
typing, and the other costs an unknown type where it differs, not a
second model.
*Provisional:* the table holds the differences that probes have found;
a construct that the typing oracle or the corpus shows GCC typing
otherwise joins it, and without one the table stays.

**Overloads.** Clang's `overloadable` attribute makes a function one of
an overload set of its name, which Clang chooses among by the argument
types of a call, as musl's fortify-headers do for `fgets` beside the
library's declaration. Each declaration with it declares an entity of
its own: it redeclares no other declaration of the name, a
declaration without the attribute redeclares the one before the
overloads, as if they were absent, and an overload has no entry in the
table of names with linkage, since Clang gives it a symbol of its own.
No declaration is checked against an overload, so the rules that Clang
puts on an overload set are left to it, save one: an overload stands
beside a function, and one whose name its scope declares as an object,
a typedef name or an enumerator is an error (C11 6.7p3), as in Clang.
The check of moved text (13.5) relies on it: each declaration of a
typedef name that redeclares one names the declaration of the same
name before it in its scope. A use of the name resolves as
the parser resolves it, to the last declaration in scope, so a use
whose declaration is an overload, or follows one in its scope, has an
unknown type until typing resolves overloads by Clang's rules (0.9b).
An overload takes its linkage from its own storage class, as nothing
visible is redeclared. GCC ignores the attribute
with a warning and checks the declarations as one function; its
headers do not use it.

**Division of diagnostics.** The front end diagnoses every Type-C rule and
the C errors it must detect to do so: syntax, undeclared names, types. It
is not required to diagnose every C constraint. The backend compiles every
token and reports the rest at the right file and line. A backend error in
*lowered* code is a bug in `typec`.

### 13.4 Emission

Each node of the tree keeps the span of tokens it was parsed from. A
subtree without a Type-C construct is emitted as its original tokens. A
node with Type-C descendants emits its own tokens around the lowered
children. A lowered construct is printed as new C11 text. The line markers
of the preprocessor are reproduced, so the backend's diagnostics and debug
line tables refer to the original source, and lowered code carries the
line of its construct.

Every marker, copied or written by `typec`, takes the GNU form
`# 12 "file" flags`. It is the only form that GCC reads in preprocessed
input, where it refuses `#line`, and the only one with flags: flag 3
marks a system header, which the backend exempts from warnings, so that
the user's `-pedantic-errors` or `-Wextra` judges the user's code and
not the platform's headers. A marker that `typec` writes carries the
flags 3 and 4 of the marker in effect at the location it gives, and no
enter or return flag. A marker without a file name, and `#line`, keep
the flags in effect. The marker before lowered text takes the flags of
the construct it lowers, and the marker after it those of the last
replaced token, so the backend exempts the text after an edit exactly as
before: in a file that a marker with flag 3 opened, after
`#pragma GCC system_header`, and in a region GCC marks as a system
macro's expansion, where the lowered text is exempt as well. The owner
(2.4) does not change: a header that only the pragma makes a system
header is not one to `typec`.

A token of moved text (13.5) keeps its own file and line at every place
where lowering writes it. The definition of an instance (10.3) spans the
lines of its generic's definition, and each of those lines is written
under a marker for its own file and line; a name that lowering writes
for a token, as the name of an argument's typedef for a type parameter,
takes the line of that token. Text of an instance that lowering writes
from no token of the definition, as the declaration of an argument's
typedef, the forward declaration of a tag and the packing bracket are,
carries the line of the application or call that puts it there, the
construct that it lowers; the texts at one place share one bracket,
whose lines carry that of the first. The marker after the text gives
the place of the external declaration that follows. Every one of these markers takes the flags 3
and 4 of its location by the rule above, and moved text has no rule of
its own for them. An instance of a generic that a system header defines
is therefore exempt from warnings as the header is, wherever its first
use stands, and an instance of the user's generic is judged as the
user's code, also where a system header is the first to use it. The
flags are those of the location and not of the owner (2.4): Apple Clang
21 and GCC 16 write a marker with flag 3 in place of
`#pragma GCC system_header`, so an instance of a generic defined after
the pragma is exempt as the rest of that header is, and one of a
generic defined before it in the same header is judged as the user's
code. Apple Clang 21 and GCC 16 exempt the lines under such a marker
inside a user's file and judge the lines after the marker that returns
to it.

The front end assumes three types that no predefined macro of the
target model (13.3) states: a plain `int` bit-field is signed, an
unsuffixed floating constant is `double`, and an enumeration of the
value 0 has the compatible type that the model's rule gives it. A
backend that holds otherwise would compile code that the front end has
typed differently, with no message. The C of a unit with a Type-C
construct therefore ends with static assertions of these three, and of
no other type assumption, under a marker for `<typec>` with flag 3, so
the user's warnings do not judge them. The backend thus fails the build
when an option, wrapper, config file or target default changes one of
those types out of the model's sight. One enumeration stands for all of
them, because those routes change the rule for the whole unit.
`#pragma GCC optimize` regions are not covered. *Provisional:* the one
enumeration is confirmed for the measured targets alone. A target whose
rule differs from the model's only for values other than 0 would settle
it otherwise, with an assertion for each enumeration; without one, the
one enumeration stays.

A unit that holds a packing bracket ends, under the same marker, with
one assertion more: the probe of 10.3, which asserts how the backend
reads `#pragma pack()` and no type. The message of each of the four
names the options known to break it. The driver refuses those of the
three types as well, and none for the probe (13.2). A unit without
Type-C constructs gets none of this, since its text is the backend's
own. An emitted header ends with the probe where it holds a bracket and
carries none of the three type assertions (9.3).

Two properties follow by construction:

- A translation unit without Type-C constructs yields the preprocessor's
  token sequence unchanged, hence the same object code as compiling that
  preprocessed text directly.
- The front end never prints plain C from its own understanding of it. A
  mistake in how it reads plain C can produce a wrong diagnostic, or wrong
  lowered code where a Type-C construct depends on the misread type; it
  cannot alter the plain C itself.

### 13.5 Lowering

| Construct | Lowered form |
| --- | --- |
| Variant declaration | The enum, struct and typedef of 10.1, at the point of declaration. |
| Constructor expression | A compound literal, `((struct expr){ .tag = expr_Add, .u.Add = { a, b } })`, which names the claimed struct tag and enumerator (10.1 rule 6) rather than the typedef name, which a block may hide. As the initialiser of an object, or of a member or an element of one, that is declared with the variant's type, the braced list alone, also for a constructor nested in another's arguments, so that static initialisers remain constant. The braced list replaces the whole initialiser, with the parentheses that the source writes around the constructor, which change neither its type nor its value (C11 6.5.1p5): a braced list inside them would be a statement expression of GNU C, and GCC under `-pedantic-errors` refuses the compound literal inside them at file scope. An object that takes its type from its initialiser, as one declared with `__auto_type` does, has no type for a braced list, and its initialiser is the compound literal. |
| `match` | A block: a pointer to the scrutinee where it is an lvalue whose address C aligns for its type, or else a copy. The address is aligned for a named object not declared `register`, a compound literal, the object of a pointer that is read as a stored value or returned by a call, and an element of an array whose address is aligned; it is not for a member of a structure or union, which a `#pragma pack` or an attribute may pack where typec does not see it and which the backend reads correctly through a member access only, nor for the object of a pointer that the scrutinee forms, as by converting a member array. A volatile or atomic scrutinee is copied too. Then: a `switch` on the tag with a `case` for every constructor; a block per arm that holds its block items as written and ends in a trap (10.5), `case X: { items trap }`; where the arm binds, that block declares the bindings first and holds the items in a block of their own, `case X: { bindings { items } trap }`; `break`, `continue` and `return` unchanged; `default:` holding the trap. The copy is declared with the type `const struct R`, where `struct R` names the variant, or the instance, by its claimed tag (10.1 rule 6, 10.3): no declaration hides a claimed name, and nothing writes to the copy after its initialiser. |
| Single-pattern test, `if` | A block: the operand held as a `match` holds its scrutinee; the tag, read once into a local; an `if` on that local. The true branch is a block that opens at the `)` of the test, declares the bindings and then holds what follows that `)` as written, the controlled statement `S` with a pragma that stands before it: `{ bindings S }`, whether the test binds or not and whether `S` is a compound statement or not. The false branch traps when the local is no constructor's tag and then holds the `else` statement, if there is one. |
| Single-pattern test, `while` | The same block as the body of an endless loop, with a false branch that traps on an invalid tag and then ends in `break`. `break` and `continue` in the controlled statement stay unchanged, and the operand is evaluated in the body of that loop (4.4). |
| Selection with a nested pattern | A `match` or a single-pattern test whose selection tree has more than one node (4.7 rule 6) holds its scrutinee or operand as its row says and then writes the tree: a local, `unsigned __tc_arm;`, then a pointer local for each position under a `*` where a constructor pattern stands, `const struct V *__tc_pK = 0;` for the `K`th such position, of the variant `V`, and for each node a `switch` on the tag of the node's position. The locals are numbered from 1 in the order in which the labels name their positions, so that each follows the one it is reached from, and the scrutinee's pointer is `__tc_match`. An object is reached from the nearest local above it, `__tc_match` or one of a position under a `*`, through the members of 10.1: a node under a `*` first points its local at the object that the pointer field points to, `__tc_p1 = __tc_match->u.Add.l;`, and switches on `__tc_p1->tag`; a node at a field in place switches on the field's tag, `__tc_match->u.Err.error.tag`, `__tc_p1->u.Wrapped.inner.tag`. A field in place has no local, since its address may be misaligned in a packed variant, where a member access is not. The `switch` has a `case` for every constructor of the position's variant, each followed by the `switch` or the leaf of its branch and a `break`; constructors that no label names at the position share one branch, after their `case` labels; `default:` holds the trap. A leaf is `__tc_arm = k;`. In a `match`, `k` numbers the arms from 0 in source order, and after the tree stands `switch (__tc_arm)`, with `case k:` where the labels of arm `k` stood, the block of each arm as in the `match` row, and `default:` holding the trap. In a test the leaf of the pattern is 1 and every other leaf is 0, and the `if` of the test's row is on `__tc_arm`; its false branch checks no tag, since the tree has. A binding is declared from the field of its position, `const __typeof__(F) x = F;`, where `F` is such as `__tc_p1->u.Num.value`. The path from a local to an object never passes a `*`, so a variant is held in place at most once on it and its length is bounded by the variants of the unit and the depth of the tree, not by the depth of a pattern under `*`; spelling the whole path from `__tc_match` at each node would make a 100 KB pattern 120 deep over a long field name about 900 MB of text. Every path to a node or to an arm passes the nodes that point the locals that it reads, since a label is selected only after every tag that it names is read (4.7 rule 6); the null pointer that a local starts as spares a backend that cannot see this a warning of a value used uninitialized. |
| Distinct type | A typedef. Casts are kept. A construct that asks whether two types are compatible, `_Generic` and `__builtin_types_compatible_p`, is answered by the front end where Type-C text compares a distinct type: one of the types compared (the controlling type or an association's, either operand) is or contains one. The selection keeps its controlling expression and every association, so the backend sees the names they use and the tags they declare outside the association type names, and is steered to the front end's choice: the type name of the association at position `i` becomes `char (*)[i]`, and the controlling expression `e` becomes `((void)(e), (char (*)[k])0)`, where `k` is the position of the selected association. Arrays of different lengths make these types pairwise incompatible, and `default` stays, as its position is no type name's. The builtin becomes `1` or `0`. C text compares the representation (10.2), and the backend answers. |
| Type application | The name of its instance; the instance is declared and defined at file scope in the two steps of 10.3. |
| Generic function instance | A `static` function: the tokens of the definition, resolved as at the definition (3.5 rule 8), with each type parameter written as the typedef of its argument (10.3). Its prototype and its definition stand where 10.3 says. |
| Zero initialiser of an object whose type mentions a type parameter (7.1 rule 3) | The empty initialiser `{}`, whichever of `{0}` and `{}` the source writes, under `__extension__`: before the declaration whose initialiser holds it, `__extension__ T u = {};`, or, where the list of a compound literal holds it, before that literal, `__extension__ (T){}`. As said below the table ("The zero initialiser of a type parameter"). Every other initialiser stays as written. |
| `try` | Before each holder (5.1 rule 3), its prelude: for each `try`, in the order of 5.1, a temporary of the result type that takes the operand; a test of whether its tag is `Ok`, the only test that success passes; where it is not, a trap unless the tag is `Err` (5.1 rule 2), then the active cleanups and a `return` of the `Err` built from the temporary. Then the holder, with the `Ok` field read where each `try` stood, or `((void)0)` where the value of the `try` is discarded or `T` is `void`, where `Ok` has no field (3.5 rule 6). A `try` that is an initialiser of a braced list and whose value the list converts from one arithmetic type to another takes a second temporary, of the type converted to, which holds the converted value and which the list reads. A first operand that 5.1 evaluates with the `try` expressions takes a temporary of type `int`, and what it conditions stands under an `if` on that temporary, as said below the table. Where `E` is `void`, `Err` has no field either, and the `Err` is built without one. |
| `defer` | The deferred statement `S` is repeated, as written and as a compound statement `{ S }`, at every exit from its scope, in reverse order. The end of the block that holds the `defer` statement is an exit where that block can complete (4.4). Where it cannot, the end gets no copy and a trap (10.5) in its place, the trap that ends a match arm, which the block of an arm has already (section 6 rule 1). `S` holds no `defer` statement (section 6 rule 11), so the copies that a scope gets are linear in its exits times its `defer` statements. Every jump that runs copies is written as a block that holds them. The block stands in place of the jump, after the labels of its statement, so a jump that is the substatement of another statement, as in `if (c) break;` or `if (c) return e;`, stays one statement; a jump that is a block item gets the same block. For a `break`, `continue`, `goto` or `return;` the block holds the copies and then the jump, `{ copies jump; }`. For a `return e;` it has a form of its own, `{ __tc_ret __tc_r = (e); copies return __tc_r; }` or, in a function that returns `void`, `{ e; copies return; }`, as said below the table; "Moved text" below says at which place each exit has its copies. |
| Slice index, `slice_sub` | An expression at the use, and no call: a comma expression of ISO C that assigns the value of each operand to a temporary of the function, tests, traps (10.5) and then indexes, as said below the table ("The check of a slice"). An index is `(*(assignments, test, &element))`, an lvalue. Where C does not evaluate one, it has no test and no temporary: it is the trap and then its operands, each written once, `(*((void)__builtin_trap(), &(s).data[+(i)]))` for an index, so that it traps where C evaluates it after all. |
| Conversion to `slice(const T)` (section 8 rule 5) | The form of a `slice_sub` with no bounds and no test: `((void)(__tc_s0 = (e)), (struct C){ __tc_s0.data, __tc_s0.len })`, where `struct C` is the instance converted to and `e` the expression that converts: the expression of a position that has a target type, or an operand that has the target type of the expression around it, or one operand of a conditional operator. Where C does not evaluate it, the form of a `slice_sub` there. A `slice_from_array`, a `slice_unchecked` and a string literal that denotes a `str` hold no temporary and are converted by being written for `struct C`, and so is the value of a `try`, the read of the `Ok` field of its temporary (5.1), which has no side effect: `(struct C){ v.data, v.len }`. |
| `slice_from_array`, `slice_unchecked`, `str` literal | A compound literal, at the use, of the instance that the use takes: its own, or the one that it is converted to (the row above). As the initialiser of an object, member or element that is declared with the type of that instance, the field of a constructor among them, the braced list alone, in place of the whole initialiser with its parentheses, as for a constructor and under the same condition. Neither holds a test. The length of a `slice_from_array` is a `sizeof` of its operand over the size of an element, plus a term of the value 0 that names an array type of negative size where that size is 0. A string literal that denotes a `str` is `(struct C){ "lit", sizeof("lit") - 1 }`, or the braced list `{ "lit", sizeof("lit") - 1 }`. |
| Checked-mode checks | Inline tests that trap. |

A constructor passed by value to a function that the backend inlines,
`add_node(arena, Call(f, a, b))`, costs nothing on Clang or GCC 16, but
GCC 13 and 14 build the compound literal in a stack temporary and copy it
again before the store. Code that must be small on those compilers stores
the constructor into its destination instead,
`next_node(arena)->op = Call(f, a, b);`, which they compile to nearly the
code Clang and GCC 16 give either form; passing a pointer to the literal
or to a named local recovers only part of the cost. This is a
code-generation weakness of GCC, not a rule of the language, and both
forms lower as the table says.

At -O0 neither Clang nor GCC shares stack slots between sibling blocks,
so each arm's bindings take frame space of their own: in Pilot A's
chibicc at -O0 `gen_expr` has a 616-byte frame against upstream's 248.
At -Og and above the backends share the slots and the bindings cost no
frame space, so a debug build of deeply recursive code uses -Og. The
lowering keeps a block per arm because sharing the slots in typec, one
union of every arm's bindings, would rename each use of a binding, and
typec does not read attribute arguments or `#pragma` lines, where a
binding can be named; it would also hide the bindings from a debugger
under their own names (4.1).

**Selection of a nested pattern.** The first match of 4.7 becomes this
C, where `struct R` is the instance `result(int, eval_error)` under its
claimed tag and `TRAP` the trap of 10.5:

```c
{ const struct R __tc_copy = (eval(e)), *const __tc_match = &__tc_copy;
  unsigned __tc_arm;
  switch (__tc_match->tag) {
  case R_Ok: __tc_arm = 0; break;
  case R_Err:
    switch (__tc_match->u.Err.error.tag) {
    case eval_error_DivByZero: __tc_arm = 1; break;
    case eval_error_Overflow: __tc_arm = 2; break;
    default: TRAP
    }
    break;
  default: TRAP
  }
  switch (__tc_arm) {
  case 0: { const __typeof__(__tc_match->u.Ok.value) value =
                __tc_match->u.Ok.value;
            { printf("%d\n", value); break; } TRAP }
  case 1: { printf("division by zero\n"); break; TRAP }
  case 2: { printf("overflow\n"); break; TRAP }
  default: TRAP
  } }
```

The tree and the arms are two statements. A label that several
branches leave possible is a leaf in each of them, and the items of its
arm are written once, as the source writes them, so a leaf cannot hold
them. They also stay outside every `switch` of the tree, where a
`break` of the arm would leave that `switch` and not the match: in the
`switch` on `__tc_arm` a `break`, a `continue` and a `return` mean what
they mean in the `switch` of a match without nested patterns. The
`default:` of that `switch` is reached by no run, since every path
through the tree sets the local to the number of an arm or traps. It
is written because a backend that does not follow the values of the
local would see a path past the `switch`, and would report a function
whose arms all return as one that can end without a value. `__tc_arm`
is declared in the block of its match or test, as `__tc_match` is, and
needs no more than the prefix.

A tree of one node has one branch for each arm, so the `switch` on the
tag holds the arms and there is no local: that is the `match` row and
the rows of the test, which a match or a test without a nested pattern
always gets.

The tree holds no token of the source. A pattern has no expression,
its constructors are written as the enumerators that their variants
claim (10.1 rule 6), and the type of a typed binding is read by typing
and not written, since a binding takes its type from its field. So
nested patterns add no moved text (below), and the scrutinee and the
items of the arms stay where the source has them. The form uses what a
match without nested patterns uses, `switch`, member access,
`__typeof__` for a binding (2.4) and the trap, and nothing else of the
dialect.

Selection reads each tag at most once on a path and reads a tag only
for the first label that is still possible (4.7 rule 6), so no path
makes more tests than the labels would in order. *Provisional (P31).*
Against nested `switch` statements written by hand, whose branches
hold the bodies, the form costs one store to the local and one
`switch` on it; in a test, the store and the `if`. A backend that
threads jumps can remove both where it optimises, and they remain at
`-O0`. The text of the tree can be longer than the labels, because a
label is a leaf in each branch that leaves it possible; a leaf is one
assignment, 4.7 rule 10 bounds the size and depth of the tree, and the
text is charged to
the output limit as it is made, as all that lowering writes is (3.5
rule 7).

**The zero initialiser of a type parameter.** The zero initialiser of
an object or subobject whose type mentions a type parameter gives
every scalar in it the value zero and zeroes the padding of each
structure and the rest of each union (7.1 rule 3), and one lowered
form does so for every type, in every dialect and in every place
where the initialiser stands. Lowering writes `{}` for the list, `{0}`
or `{}`, and puts `__extension__` before what holds it most closely:
the compound literal whose list holds it, or else the declaration
whose initialiser does. The declaration is a block item, as 7.1 rule 3
keeps the zero initialiser out of the first clause of a `for`.

ISO C11 has no initialiser with this meaning, and no other form is one
for every type and place:

- `{0}` gives member values. With GCC 16 it leaves the bytes of a
  union past its first member, and the padding that ends a structure
  whose every member the list names, as they were, in an object, in a
  subobject of a longer list and in a compound literal. Apple Clang 21
  zeroes them, and refuses `{0}` for a structure that begins with a
  structure without members.
- A copy of a static object that has no initialiser,
  `static const T zero; T u = zero;`, is no initialiser of an array
  (C11 6.7.9p16), is no constant for a static object, and C leaves the
  padding of a copy unspecified (6.2.6.1p6).
- `memset` after the declaration is no initialiser: it cannot follow a
  `const` object, a static object, a subobject of a longer list or a
  compound literal.

`{}` is C23's empty initialiser, which initialises an object as one of
static storage is initialised without an initialiser, the padding of
structures and unions included (C23 6.7.10), and both backends give it
that meaning in the dialects that `typec` accepts. Measured with GCC
16.2 and Apple Clang 21 on x86-64, at `-O0`, `-O2` and `-O3`, in C11
and in gnu17, every byte is zero after `{}` in a type that has no
padding inside a scalar. The types were a union with a longer second
member, a structure with padding between its members, a structure of
one member with padding after it, a variant's structure, a `double`,
a pointer and three structures with unnamed bit-fields: one of 32 bits
between two members, one of 40 bits before a bit-field, and one of
width zero with another of 24 bits after the last member. C leaves an
unnamed member indeterminate after any initialiser (C11 6.7.9p9), so
the bits of these are zero by what the two backends do and by no rule
of C. The places were an object, a `const` object, an array,
a structure that begins with the type, a subobject of a longer list, a
static object, and a compound literal read as a value, through its
address and as the initialiser of a subobject.

The padding that C23's rule zeroes is that of structures and unions.
The bytes of a scalar that hold none of its value are no part of it,
and the same measurement finds them left as the stack held them. On
x86-64 a `long double` holds its value in the first 10 of its 16
bytes, and `_Complex long double` in 20 of its 32. After `{}`, in the
record of the test below, Apple Clang 21 leaves the other 6 and 12 at
each of the three levels, and GCC 16.2 leaves none of a
`long double`'s 6 and 6 of the complex type's 12 at `-O0`, and 4 and
8 at `-O2` and `-O3`, in these places:

| Type | Apple Clang 21 | GCC 16.2 |
| --- | --- | --- |
| `long double`, `_Complex long double` | An object, a `const` object, a compound literal through its address | The same, and a subobject of a longer list, in an object and in a compound literal |
| A structure whose one member has one of the two types | A compound literal of the structure of `long double`, through its address | An object, a `const` object, a compound literal through its address |

In every other place of these four types the bytes were zero. They
were zero in every place of a structure that holds a `long double`
after a `char`, before one or between two, of a structure that holds
an array of two, and of a union that holds one as its first or as its
second member. In all of these types every byte outside a
`long double` was zero. Which of its bytes a backend leaves is
therefore nothing that text can know, and 7.1 rule 3 promises none of
them. No form zeroes them in every place. A statement after the
declaration, `memset` or GCC's `__builtin_clear_padding`, which Apple
Clang 21 does not have, follows none of the objects that `memset`
cannot follow above. A copy of a static `long double` that has no
initialiser stores the value alone, as every store to the scalar does,
and leaves the same bytes (both backends).

Both take `{}` for a scalar, a pointer, an enumeration, a
complex type, a structure, a union, an array and a structure without
members, with no diagnostic under `-Wall -Wextra` but one: GCC warns
of braces around a scalar initialiser where the `{}` of a subobject
stands in a longer list and the type is a scalar.

Both backends refuse `{}` under `-pedantic-errors` in C11 and in
gnu17, as an extension of C23, and take it under `__extension__` with
no diagnostic in C11, gnu11, C17 and gnu17 under
`-pedantic-errors -Wall -Wextra`. `__extension__` stands before a
declaration that is a block item, whatever follows it: a storage
class, a qualifier, an attribute or another `__extension__`. Before a
compound literal it is a unary operator, and the literal stays an
lvalue and an operand of `sizeof`, `&__extension__ (T){}`. Apple Clang
21 does not read it before a declaration in the first clause of a
`for`, where GCC 16 does. It silences what the backend would say under
`-pedantic` of everything in the declaration or the literal that it
stands before, the user's own text there included, which is the cost
of the form.

*Provisional:* C23 gives `{}` its meaning, and in the C11 and C17
dialects it is the backends' extension, measured with GCC 16.2 and
Apple Clang 21 alone. A test of the suite holds the assumption for the
backend of each test host. It compiles the lowered form in each place
above for each type above, those that hold a `long double` or its
complex type among them, but in the two places that copy a compound
literal, whose copy C leaves unspecified in its padding. It calls each
function through a pointer, after one that fills the stack with a
non-zero byte, at `-O0`, `-O2` and `-O3`, and finds zero every byte
that 7.1 rule 3 promises: each byte of the object but those inside a
`long double` that hold none of its value. They are the last 6 of its
16 on x86-64, and the test asserts that format by `LDBL_MANT_DIG`; on
arm64, which is not measured, the type has no such bytes and every
byte must be zero. A control in the same test, a union whose first
member alone is assigned, must leave a byte that is not zero, which
shows that the test reads the bytes it claims to read; the same test
over `{0}` finds 31 of the 32 bytes of the union of 7.1 rule 3 left
with GCC 16.2 at `-O2`. No test asks for a byte that is not zero
among those that this one passes over. How many of them are left
depends on the harness as well as on the backend: on what the
function called before left on the stack, and on how the backend
compiles the function that holds the object. The counts above are
those of this test's harness. Another finds 3, 4 and none of the 6
bytes left with GCC 16.2 at `-O0`, `-O2` and `-O3`, in a `long double`
object, in a `const` one and in a compound literal read through its
address, and all 6 with Apple Clang 21 at each level. The counts are
therefore a record of one measurement and nothing that a test can
hold: 7.1 rule 3 needs of them only that some arrangement leaves a
byte, which is why it promises none. The record is taken with the
functions of this test, which count and print the bytes that the test
passes over and assert nothing of them, so that it can be taken again
for another backend. A
second test compiles the lowered form under `-pedantic-errors` in the
four dialects, and the same text without `__extension__` must fail
there. The repair for a backend that fails either test is a form of
its own for that backend, or its refusal by the driver, and never a
pass over the lowered C. The form stays if no backend fails.

**The statement that holds a `try`.** The *prelude* of a holder (5.1
rule 3) stands directly before it, in the same block. It evaluates
what 5.1 evaluates before the rest of the holder, in that order, so
the hoisted operands are moved text. Lowering writes a prelude from
the typed tree of the holder's expression, as one function that
returns the text of the prelude and the edits of the holder, and it
writes three forms, each with the hoisted operand `e` in parentheses:

- for a `try`, the temporary and the test,
  `struct R __tc_t0 = (e); if (__tc_t0.tag != R_Ok) { ... }`. The
  temporary has the type that the copy of a `match` has (the `match`
  row above), named by its claimed tag for the same reason, and no
  qualifier: the value of a `try` may hold an array, which the holder
  reads through a pointer to its first element (C11 6.3.2.1p3), and
  under a `const` temporary that pointer has a qualifier that the
  source does not give it. Apple Clang 21 and GCC 16 refuse
  `use((try f()).name)` lowered over a `const` temporary under
  `-pedantic-errors`, where `name` is an array of `char` and `use`
  takes a `char *`;
- for the first operand of `&&`, `||` or a conditional operator, its
  truth, `const int __tc_c0 = (e) ? 1 : 0;`, and then the prelude of
  what the operator evaluates under it: `if (__tc_c0) { ... }` for
  `&&`, `if (!__tc_c0) { ... }` for `||`, and for a conditional
  operator `if (__tc_c0) { ... } else { ... }`, without the part that
  holds nothing;
- for the left operand of a comma, the operand as a statement,
  `(void)(e);`.

A temporary that the prelude assigns under an `if` is declared without
an initialiser directly before the outermost such `if`,
`struct R __tc_t1;` or `int __tc_c1;`, and the form assigns it,
`__tc_t1 = (e);`. The holder follows the prelude with three edits: the
read of the `Ok` field where a `try` stood, `__tc_t0.u.Ok.value`; the
temporary where a first operand stood, `__tc_c0`; and `(void)0` where
the left operand of a comma stood. A hoisted operand that holds a
`try` or a first operand is written with the same edits. So

```c
if (p && try check(p) > 0)
    use(p);
x = c ? try f() : (g(), try h());
```

becomes

```c
const int __tc_c0 = (p) ? 1 : 0;
struct R __tc_t0;
if (__tc_c0) { __tc_t0 = (check(p)); /* test of __tc_t0 */ }
if (__tc_c0 && __tc_t0.u.Ok.value > 0)
    use(p);
const int __tc_c1 = (c) ? 1 : 0;
struct R __tc_t1;
struct R __tc_t2;
if (__tc_c1) { __tc_t1 = (f()); /* test of __tc_t1 */ }
else { (void)(g()); __tc_t2 = (h()); /* test of __tc_t2 */ }
x = __tc_c1 ? __tc_t1.u.Ok.value : ((void)0, __tc_t2.u.Ok.value);
```

The holder reads a temporary under the conditions under which the
prelude assigned it, since both read the same `__tc_c` temporaries and
nothing writes one a second time. `__tc_t` and `__tc_c` each
take a number, which counts the `try` expressions and the first
operands of the function from 0 in the order of 5.1: the temporaries
of one block share a scope, so each needs a name of its own.

A `try` that is an initialiser of a braced list, and whose value the
list converts from one arithmetic type to another (5.1 rule 3), has
one line more in its form, after the test: a temporary that takes the
value converted. `float a[2] = { try f(), try g() };`, where `f` and
`g` yield a `double`, becomes

```c
struct R __tc_t0 = (f()); /* test of __tc_t0 */
const float __tc_v0 = __tc_t0.u.Ok.value;
struct R __tc_t1 = (g()); /* test of __tc_t1 */
const float __tc_v1 = __tc_t1.u.Ok.value;
float a[2] = { __tc_v0, __tc_v1 };
```

The edit of the holder is then the temporary where the `try` stood,
and no read of the `Ok` field. `__tc_v` takes the number of its `try`,
and under an `if` it is declared and assigned as the others are,
`float __tc_v1;` and `__tc_v1 = __tc_t1.u.Ok.value;`.

The temporary has the type of the object that the initialiser
initialises, without its qualifiers, which typing gives with the
position of the initialiser in its list (C11 6.7.9p17 to p20). Lowering
writes that type in keywords alone, as it writes the `int` of a first
operand: every arithmetic type has such a name, which no declaration
hides. An enumerated type is written as the integer type that it is
compatible with (C11 6.7.2.2p4), to which the conversion is the same
(6.3p2), and a bit-field as the type that declares it. The line is an
initialisation or an assignment and no cast, so C converts there as it
converts in the list (C11 6.7.9p11, 6.5.16.1p2), the backend refuses
there what it refuses in the list, and it reports the conversion as it
reports it there: under `-Wconversion` Apple Clang 21 and GCC 16 give
one warning for each `__tc_v` above, and one for each initialiser of
`float a[2] = { f(), g() };`. For an enumerated type the backend
reads the integer type, and the warnings differ: for an `int` and a
`double` that initialise an `enum e` whose integer type is
`unsigned`, both backends report both conversions to `unsigned`,
where Apple Clang 21 reports the first alone to `enum e` and GCC 16
neither. Each warning names a conversion that the source makes. The
list then takes each value in the type of its object and converts
nothing, or fits it to the width of a bit-field.

No other conversion of an initialiser has a line: 5.1 says why none
needs one, and lowering could not write the type of every object, a
structure without a tag or a pointer to one among them. Nor has an
argument of a constructor expression, which lowering writes as an
initialiser of a braced list (the table above): 3.3 orders the
arguments as those of a call, and the prelude is written from the
tree of the source, where an argument is no initialiser.

Where the value of a `try` is discarded (5.2), or `T` is `void` and
`Ok` has no field, the holder has `((void)0)` in its place, so
`try e;` becomes its prelude and `((void)0);`. A read of the field
there would do nothing, and Apple Clang 21 and GCC 16 report an
expression statement that only reads it under `-Wall`
(`-Wunused-value`).

The labels of the holder stay in place on a null statement, `L: ;`,
and the prelude and the holder follow it. No block is then made around
a labelled statement, and a tag that the holder declares keeps the
scope it has in the source. Where the holder is not a block item once
its labels are set aside, it is the substatement of another statement,
which C makes a block of its own (C11 6.8.4p3, 6.8.5p5), and a block is
made around the null statement of the labels, the prelude and the
holder, so the labels stay inside the substatement:
`if (c) L: x = try f();` becomes
`if (c) { L: ; /* prelude */ x = /* the Ok field */; }`, with `L`
under the `if`, and the `if` of `else if (try f())` stands in a block
after its prelude.

The labels of a statement are C's: an identifier label, and a `case`
or `default` label of a C `switch`. The labels of a `match` arm (4.1
rule 2) are the arm's and no statement's. The statement that begins an
arm is a block item of the arm's block (the `match` row above), and
its prelude stands before it there, with no null statement.

Measured with Apple Clang 21 and GCC 16 on x86-64, in the ISO form of
C11 and in gnu17, at `-O0` and at `-O2`: a function written in these
forms, with a `try` under `&&` inside `||`, under both branches of a
conditional operator and after a comma, and with discarded values of
type `void`, compiles without a diagnostic under `-pedantic-errors
-Wall -Wextra -Wshadow -Wconversion -Wsign-conversion`, also for the
temporaries that have no initialiser, and evaluates its operands in
the order of 5.1 under both backends.

**The objects and the order of a prelude.** Each form is a full
expression of its own, and what stands under an `if` of a prelude is
in a block of its own, in braces or without them (C11 6.8.4p3).
Lowering has no form that carries an object of a hoisted operand past
the end of either: 5.1 rule 3 refuses the operand that makes one
(`try-lifetime`), and three facts about every prelude follow.

- A compound literal of the source stands in a prelude outside its
  `if` statements only, and so in the block of the holder. That is the
  block of the literal in the source where the holder is a block item
  or a substatement, which is a block with braces as without them. It
  is the block around the literal's own where the holder is itself a
  block, as an `if` and a `switch` are: the object then lives longer
  than in the source, and a program that reads it only while the
  source keeps it reads the same.
- No hoisted operand forms a pointer into a temporary object of C
  (C11 6.2.4p8), so none is read after the full expression that made
  it.
- The compound literals that lowering itself writes, for a
  constructor expression, a `slice_from_array`, a `slice_unchecked`
  and a `str` literal (the table above), stand under an `if` as
  anywhere. Each is a value in the source (3.3, section 8): the
  source has no lvalue of it to take the address of, and the members
  that it reads of one, the pointer and the length of a slice, are no
  arrays.

In a braced list an initialiser that holds a `try` is itself a `try`
expression (`try-list`), and its form ends with the conversion that
the list would make of its value, so a prelude evaluates whole
initialisers, the holder evaluates the others, and lowering has no
form for the order of a list.

The refusals rest on the forms that they refuse, lowered by hand and
measured with Apple Clang 21 and GCC 16 on x86-64 at `-O0` and at
`-O2`. In `consume(c ? try wrap((int[]){7}) : NULL);` GCC 16 at
`-O2` leaves out the store of 7 and jumps to `consume` with the frame
of the caller released, so a `consume` that writes automatic objects
of its own reads one of them through the pointer; it reads 7 in the
three other builds, and in all four where the operand stands under no
`if`. In
`consume(try wrap(make().a));` and in
`(p = make().a, try read_value(p));` every build reads the element,
and the address sanitizer of Apple Clang 21 (`-fsanitize=address` at
`-O1`) reports a use of the temporary object after its scope in both,
where it reports nothing in the same expressions with a call in place
of each `try`; that of GCC 16 reports nothing in either. The lowered
code reads an object whose life has ended, whatever a build makes of
it (C11 6.2.4p2).
`int a[2] = { (try set_two(), x = 1), try read_x() };` leaves 2 in
`a[1]` in every build, and 1 with a call in place of each `try`.

The temporary of a converted value rests on the same builds.
`float a[2] = { try f(), try g() };`, with the `f` and `g` of 5.1 and
`#pragma STDC FENV_ACCESS ON` at file scope, leaves 1 in `a[1]` in
every build where the list reads the two `Ok` fields and converts
them. With the two `__tc_v` temporaries it leaves 3 under Apple Clang
21 at both levels and under GCC 16 at `-O0`, as
`float a[2] = { f(), g() };` does in those three builds. GCC 16 does
not implement the pragma, which it reports under `-Wunknown-pragmas`,
and from `-O1` it converts the first value after the second call and
leaves 1, in the list of two calls as in both lowered forms, with
`-frounding-math` as without. The lowered C has the order that C
gives the list. What GCC makes of it is what GCC makes of the list
written in C, and no form of lowering answers for it. A member
`int b : 3` initialised with 13 holds -3, and a member
`unsigned u : 3` initialised with 5.5 holds 5, from a temporary of
the declaring type as from a call, in every build, and no signal is
raised.

**The cost of a prelude.** *Provisional (P33).* A prelude is the C
that a programmer writes for a fallible call inside an expression: a
declaration and a test for the call, an `if` where the call is under a
condition, and then the statement. Measured on one function of four
`try` expressions, one under `&&`, two under `+` and one in a branch
of a conditional operator, against the same function written with
each `try` in a declaration of its own, under the `if` statements that
the conditions need: the two compile to text of the same size at
`-O2`, 241 bytes under Apple Clang 21 and 476 under GCC 16 on x86-64.
At `-O0` the prelude takes 722 bytes against 576 and 632 against 603,
for the `int` temporaries and for the temporaries that it declares
outside the `if`. The same function with each `try` as a statement
expression takes 244 and 547 bytes at `-O2`. A converted initialiser
of a braced list adds one object of an arithmetic type to its prelude,
which C written by hand declares as well where it keeps the order of
the list; its size and speed are not measured. One function measures
no program: package 3.12 of the plan measures the preludes of the
container library, the pilot and the README, those of braced lists
among them, from a script that it keeps under `tools/measure`.

**A `try` beside the other lowered forms.** The holder is lowered as it
would be with the reads in place of its `try` expressions, and each
hoisted operand as the expression that it is, so no other form has a
case for a `try`:

- A `return e;` in the scope of a `defer` statement becomes its
  prelude and then the block of the form below, whose operand is `e`
  with its edits. A `try` that fails runs the copies of its own test,
  and the block is not reached.
- A scrutinee or an operand of a single-pattern test that is a `try`
  is no lvalue (5.1 rule 2), so the `match` or the test reads a copy
  (the `match` row).
- A test of a slice (below) in a hoisted operand is evaluated in the
  prelude, and one in the rest of the holder after it. In
  `s[i] + try f()` an `f` that fails returns before `i` is tested, so
  an index out of range does not trap there.
- Every `try` of a holder has the cleanups that are active at the
  holder, so a holder of *n* `try` expressions in the scope of *d*
  `defer` statements gets *n* times *d* copies, each charged to the
  output limit (3.5 rule 7) as it is written.
- The temporaries of a prelude are objects of the holder's block, and
  the holder reads them after other calls of its expression. A call
  there that returns a second time, after the same call of the
  function has evaluated the holder again, finds them as the later
  prelude left them, and C11 7.13.2.1p3 makes their values
  indeterminate, as it does those of the temporaries of a slice
  test ("An evaluation that is resumed", below).

A pragma is a line and no token: it acts from the place where it
stands, on the text after it. Lowering moves each hoisted operand
ahead of every token of its holder that stands before it, the labels
excepted, and writes nothing between the prelude and the holder. A
`try` is therefore an error where a pragma stands anywhere from
directly before its holder, the labels of the holder included, to
the end of the expression that holds the `try` (5.1 rule 3), the
hoisted operands included: a `#pragma` line,
which is also how a `_Pragma` operator reaches `typec`. The labels are
those of the null statement, so the stretch of a statement that begins
a `match` arm starts after the arm's labels. `typec` sees
the line as tokens and applies the rule without reading them, whatever
the pragma. No pragma then stands between the place where a hoisted
operand is written and its place in the source, so each is written
under the pragma state of its own place. At each place in that stretch
lowering would otherwise change what a pragma acts on:

- Directly before the statement or one of its labels, a pragma would
  come to stand before the temporary, or before the null statement of
  the labels. It may govern the one statement after it, as OpenMP's
  `critical` does. It would govern the declaration of the temporary,
  which GCC 16 refuses under `-fopenmp` and the front end of Apple
  Clang 21 under `-Xclang -fopenmp` (Apple's driver rejects `-fopenmp`
  itself), and the error path of the `try` would leave the governed
  statement.
- Inside the statement and before the operand, a pragma would cease to
  act on the operand. Apple Clang 21 applies a `#pragma pack(1)` line
  between the specifiers and the declarator of a declaration to its
  initialiser:

  ```c
  int
  #pragma pack(1)
  n = sizeof(struct { char c; int i; });
  ```

  gives `n` the value 5, and 8 without the line. With `try
  f(sizeof(struct { char c; int i; }))` as the initialiser, the operand
  would be written before the declaration and so before the line, and
  `f` would be passed 8. GCC 16 refuses a pragma at that place.
- Inside a hoisted operand, a pragma would move with it, and act on
  the rest of the prelude and on the tokens of the holder that stand
  before it in the source.
- After the last hoisted operand, a pragma would keep its place and
  what it acts on. The stretch runs to the end of the expression all
  the same, so that the rule names one stretch and does not ask where
  the last hoisted operand ends.

One rule over the whole stretch asks for no reading of a pragma and no
list of the places where one would be harmless.

The temporaries share the block of their statements, so a build that
asks for C90's order of declarations or for C++'s jump rule hears of
them: `-Wdeclaration-after-statement` reports a temporary that follows
a statement of its block, and `-Wjump-misses-init` a `goto` that
crosses one (Apple Clang 21, GCC 16). Neither is in `-Wall` or
`-Wextra`.

The error path returns the `Err` that is built from the temporary after
the cleanups (5.1 rule 2).

**`return` in the scope of a `defer` statement.**
A function that returns a value and holds a `return e;` in the scope of
a `defer` statement declares its return type under the name `__tc_ret`,
once, and each such `return` becomes a block that holds a temporary of
that type, the cleanups and the `return` of the temporary. The function
`long f(int a, char *b) { /* body */ }` becomes

```c
long f(int a, char *b)
{ typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(a) *)0,
                                          *(__typeof__(b) *)0)) __tc_ret;
  { /* body */ } }
```

and each such `return e;` in its body becomes

```c
{ __tc_ret __tc_r = (e); /* cleanups */ return __tc_r; }
```

A function with no such `return` declares no `__tc_ret`. One that also
holds no test and no conversion of a slice, whose temporaries stand
beside the typedef ("The check of a slice", below), is written as it
stands.

The type of `__tc_ret` is the type of a call of `f`, which is the
return type, and the typedef spells no part of that type. The tokens of
the head cannot be written a second time: they may declare a type, as
in `struct s { int a; } f(void)`, and a parameter may hide a name among
them, as in `T f(int T)`. The call goes through a null pointer to the
type of `f` and passes, for each parameter of the definition in order,
an lvalue of the parameter's type. A function with no parameters passes
none, and a variadic function its named parameters alone. In a function
instance `f` is the instance name. No part of the call is evaluated:
the operand of `__typeof__` is evaluated only where its type is
variably modified, as the operand of `sizeof` is (C11 6.5.3.4p2), and
no return type is.

The initialisation converts the value of `e` to the return type as the
`return` would have, as if by assignment (C11 6.8.6.4p3), and before the
cleanups (section 6 rule 3); the `return` of the temporary converts
nothing. A constructor expression or a `str` literal that takes its type
from the return type (3.3) is written in the initialiser as the compound
literal it lowers to, which carries that type. `__tc_ret` and `__tc_r`
are reserved (2.3), so neither the body, `e` nor a cleanup names one,
and each such block declares its own `__tc_r`.

The typedef is the first block item of the function's body, and the
body as written is a block after it. At the typedef the names in scope
are those of file scope and those that the parameter list declares, and
no others, so no declaration of the body hides `f` or a parameter
there. The names in the typedef are read where the head declares them
and are not moved text; no rule about a hidden name is needed at a
`return`.

The body is a block of its own because some text must begin a compound
statement: `#pragma STDC FENV_ACCESS` and `#pragma clang fp` lines, and
`__label__` declarations. Clang refuses those pragmas after the typedef
in one block, and both backends refuse `__label__` there. In the inner
block Apple Clang 21 and GCC 16 take all three, and a pragma before the
first statement of the body, such as `#pragma clang loop` or `#pragma
GCC ivdep`, governs that statement as it does in the source.

The bindings of a match arm and of a single-pattern test are declared
before the block or statement that uses them, not inside it, for the
same reason (the table above). An arm that binds is
`{ bindings { items } trap }`, so that what begins the arm still
begins a compound statement. An arm that
binds nothing is `{ items trap }`: its items begin the arm's own block
and need no second one. The true branch of a test is `{ bindings S }`
with the controlled statement `S` as written. A compound statement `S`
is still begun by what begins it in the source, and a pragma that the
source writes between the `)` of the test and `S`, as `#pragma GCC
unroll` before a loop, still stands directly before `S`. A test that
binds nothing gets the block too, since the false branch follows it as
an `else`, which an `if` in `S` would otherwise take. The added scope
would let a second declaration of a binding's name, among the items of
the arm or in the outermost block of a compound `S`, hide the binding,
where the source has the two in one scope; the front end refuses that
declaration (4.1(5), 4.6(4)).

The inner block is one scope further in than the body is in C, where
the parameters and the outermost block of the body share one scope
(C11 6.2.1p4). Two refusals follow from that, and a function that gets
the typedef is an error in each.

- The parameter list declares the function's own name, as a parameter
  or as an enumeration constant. In `long f(int f)`, `__typeof__(f)`
  would name the parameter. The own name of a function instance is its
  instance name, which is claimed (10.3), so no parameter list declares
  it: a parameter with the name of the generic hides nothing that the
  typedef names.
- A declaration in the outermost block of the body declares a name that
  the parameter list declares, in the same name space. C reads the two
  as declarations of one scope. It forbids the second declaration of a
  parameter or of an enumeration constant (C11 6.7p3), and both
  backends refuse it in plain C; it lets the block complete a tag of
  the parameter list, as in `int f(struct s *p) { struct s { int a; };
  return p->a; }`. In the inner block the first would hide the
  parameter with no message, and the second would declare another
  structure, which the backends then refuse at `p->a`.

The form cannot be written in three more cases. A function that gets
the typedef is an error in the first two, and the `return` in the
third.

- A function whose name does not, at its definition, name exactly one
  function that `__typeof__(f)` may name there. The typedef rests on
  that one property of the name, and the property is a fact of the
  declarations of the name that are in scope at the definition, the
  definition's own among them: the form is refused where the backend
  keeps two of them apart, as it does the members of an overload set
  (13.3, "Overloads") and the versions of a function, or where one of
  them forbids a mention of the name, or reports one as an error.
  `typec` decides it from those declarations in two ways, and from
  nothing else.
  - Two of the declarations carry `target` attributes whose arguments
    differ: they declare two versions of the function. `typec` compares
    the arguments token for token and does not read them, so two
    spellings of one set of features, as `target("avx2,fma")` and
    `target("fma,avx2")`, count as two versions and the function is
    refused, which errs on the safe side. A single
    definition with `target("avx2")` is one function and gets the
    form, and so does a function whose declarations repeat one `target`
    attribute. Apple Clang 21 on x86-64 refuses the `f` of the typedef
    for two versions and takes it for a function of either of those
    shapes. GCC 16 reads two such declarations as one function in C
    there and takes the form; the refusal does not ask which backend
    compiles the unit.
  - One of the declarations carries an attribute that breaks the
    property on its own, whatever else is declared, as `overloadable`
    does. The table of attributes that the front end knows marks each
    such attribute (13.3, "Unknown types"). It is the one list of
    them and says what was measured of each.

  Nothing else refuses the form on this ground: an attribute without a
  mark, or with no entry in the table, does not. A backend error that
  such an attribute causes in the typedef is a bug in `typec` (13.3),
  and the attribute joins the table.
- A function with a parameter that has no name, which the backends
  accept in a definition as an extension: the typedef has no lvalue to
  write for it.
- A `return e;` in a function that returns `void`, where `e` is not a
  void expression or has an unknown type (13.3, P21). C forbids the
  first (C11 6.8.6.4p1), the block that is said next would lose the
  backend's diagnostic, and an unknown type does not say which case it
  is. In a function that returns a value the form needs no type of `e`,
  so an operand of unknown type is no error there. A return type that
  the front end does not know may be void, so the first `return e;` in
  the scope of a `defer` statement is the point that needs the answer,
  and it is refused there as 13.3 says.

Each refusal of the form has a name of its own (13.6), so that a count
tells them apart: one for each of the two refusals that follow from the
inner block, one for each of the two ways in which `typec` decides the
first of the three cases, the `target` attributes and the marked
attribute, and one for each of the other two cases.

In a function that returns `void` there is no value to hold and no
typedef. `return e;` with a void expression for `e`, as in
`return g();`, becomes `{ e; /* cleanups */ return; }`. The `return` of
the error path of a `try` needs no temporary either: the temporary of
the `try` holds its value, and no cleanup reads or changes that one,
since its name is reserved (2.3).

A `return;` with no operand has no value to hold in any function and
is written as every jump that runs copies is (the `defer` row). In a
function that returns a value C forbids it (C11 6.8.6.4p1). The lowered
code keeps the `return;`, so the diagnostic stays the backend's, and
`typec` refuses nothing. Such a `return` asks for no typedef: a
function gets `__tc_ret` for a `return e;` alone.

Apple Clang 21 and GCC 16 take the form under `-std=c11
-pedantic-errors -Wall -Wextra -Wconversion -Wsign-conversion
-Wfloat-conversion -Wformat-security`. They report the conversion of
`e`, a format string and a bit-field operand as they do for the plain
`return e;`; that was measured as well for a null pointer constant in a
function that returns a pointer (`return 0;`) and for parameters of
variably modified type. A diagnostic of the conversion speaks of an
initialisation where the plain form speaks of a `return`, and names the
type as `'__tc_ret' (aka 'int')` in Clang and `'__tc_ret' {aka 'int'}`
in GCC.

The diagnostics differ by one rule and its mirror. A diagnostic that
rests on the operand standing in a `return` statement, on the `return`
standing without braces, or on a name going unused, is lost: the
operand stands in an initialiser, the `return` in a block, and the
typedef names the function and every parameter. The form adds the
diagnostics of the text that it writes. Measured with both backends,
at `-O0` and `-O2`, and with Clang's `-Weverything`:

| Diagnostic | Plain `return e;` | The form |
| --- | --- | --- |
| Clang `-Wreturn-stack-address` (on by default), `return &x;` of a local | Reported | Lost |
| GCC `-Wreturn-local-addr` (on by default), the same | Reported | Lost at `-O0`; reported at `-O2` |
| Clang `-Wnonnull` (on by default), `return 0;` in a function declared `returns_nonnull` or with a `_Nonnull` return type | Reported | Lost |
| `-Wmisleading-indentation` (in `-Wall`), both backends, `if (c) return x;` followed by a statement indented as if the `if` guarded it; the same for every other jump that runs copies, as `if (c) break;`, which stands in a block too (the `defer` row) | Reported | Lost: the jump stands in a block |
| `-Wunused-parameter`, `-Wunused-but-set-parameter`, both backends | Reported | Lost for every parameter of the function |
| Clang `-Wunused-function`, an unused `static` function | Reported | Replaced by `-Wunneeded-internal-declaration`; GCC reports `-Wunused-function` for both |
| `-Wshadow`, both backends, where `e` holds a statement expression with such a `return` of its own | None | Added: the inner `__tc_r` hides the outer one |
| Clang `-Wunreachable-code`, where `e` is a call of a `noreturn` function | None | Added: what follows the initialiser is never reached |
| Clang `-Wused-but-marked-unused` (in `-Weverything`), a parameter marked `unused` | None | Added, once for the function |
| Clang `-Wdeprecated-non-prototype`, an old-style definition with no prototype in scope | Once, for the definition | Once more, for the call in the typedef |
| GCC `-Wdeprecated-declarations`, a function marked `deprecated` | None | Added, once for the function; Clang reports none |
| `-pedantic`, `return e;` of a void expression in a function that returns `void` | Reported | Lost |

Clang's `-Weverything` also reports every `__tc_` name that a lowered
unit declares under `-Wreserved-identifier`, as it does those of an
emitted header (9.3). Clang's `-Wunreachable-code`, which neither
`-Wall` nor `-Wextra` turns on, reports the trap that follows a
`return`, at the end of a match arm as at the end of a block that
holds a `defer` statement (Apple Clang 21); GCC 16 reports nothing
there.

Pilot B lost no diagnostic of this list, met none of the refusals
above and had no build broken by a diagnostic that the form adds
(section 15, P9).

Rules 8 and 9 of section 6 guarantee that each copy of a deferred
statement binds its names as the original does and defines no label,
object or type twice. Rule 12 guarantees that the block ends the scope
of no name that the operand declares, and that control leaves the
operand only as it ends or by leaving the function, so that the block
ends the life of no object that the source keeps.

**Moved text.** Lowering writes some source text at a place other than
its own: a deferred statement at each exit from its scope (section 6),
the definition of a generic in each instance (10.3), the one name of an
untagged type in the typedef of a type argument (10.3) and the hoisted
operands of a holder of `try` expressions before it (5.1). One
*resolution property* holds for such *moved text*: it reads, at each
place where lowering writes it, as it reads at its own place, and the
text around it reads as it would had nothing moved. Lowering writes a
name of moved text in one of two ways, and the property has a half for
each. A third clause covers the text around it.

- A name that lowering writes as the source spells it, an ordinary
  identifier, a tag or a label name, has one reading at both places.
  Where the text uses the name, it denotes the same entity at both, and
  the entity has the same type. Where the text declares the name for
  itself, the name denotes at each place of writing what it denotes at
  the text's own place, the entity that the text declares: the name of a
  parameter does not become a typedef name that is visible there, and a
  tag of a prototype's own scope does not become a structure that file
  scope declares before the place of writing. A declaration that would
  make a reading differ at a place where the text is written is an
  error; a declaration in whose scope no such place lies is none.
  Completing a structure or union changes neither an entity nor its
  type, and neither does declaring an entity again with the type it has:
  a member that names a structure of file scope reads alike where the
  structure is completed between the text and a place of writing after
  it. A completion adds the content of the type, and the text reads
  that content only at a point that needs the type complete (10.3),
  which is an error at the text's own place, where the type is
  incomplete. Every other reading takes the type for the one type that
  it is before and after (C11 6.7.2.3p4). Apple Clang 21 and GCC 16
  read alike, before and after a completion that packs the structure,
  aligns it to 32 and marks it `may_alias`: a `_Generic` on a pointer
  to it, the type of a conditional on that pointer and a `void *`,
  `__builtin_types_compatible_p`, and the size and alignment of the
  pointer. Only a message differs: `-Wcast-align`, which neither
  `-Wall` nor `-Wextra` turns on, reports a cast to the pointer after
  the completion and not before it.
  Completing an enumeration does change its type. ISO C has no
  incomplete enumeration (C11 6.7.2.3p3). The GNU profile takes
  `enum E;` before the list of `E`, and until the list such an
  enumeration is compatible with no integer type; the list makes it
  compatible with one (C11 6.7.2.2p4). Text that needs nothing complete
  reads the difference. On Apple Clang 21 and GCC 16,
  `_Generic((enum E *)0, int *: 1, default: 0)` is 0 before
  `enum E { A = -1 };` and 1 after it, also where the text reaches the
  enumeration through a typedef name or through the type of an object
  and does not name the tag. With an association for `enum E *` beside
  the one for `int *`, both backends take the expression before the
  list and refuse it after. An enumeration with a fixed type is
  complete from its first declaration, and compatible with that type
  before its list as after it (both backends), so its list completes
  nothing.
  The backend reads attributes that typec's types lack and cannot
  compare, so the declarations that may change what the text reads are
  found by where they stand rather than by what the text names. Between
  the text's own place and a place of writing, in either order and in
  any scope, three declarations are errors. One declares again,
  inexactly, an object or a function that the text uses; only a use of
  its name reads an object or a function. One declares again,
  inexactly, a typedef name declared before both places, whether or not
  the text uses it: GCC changes the name in place, and with it every
  declaration and member written through it. One completes a tag
  declared before both places, whether or not the text names it: a tag
  of any kind where the place of writing precedes the text, and an
  enumeration where it follows the text as well. The completion of a
  structure or union changes nothing for text written after it, as
  said above. That of an enumeration is found by where it stands
  because the text reads the enumeration's type through every typedef
  name, object and function declared with it, and none of them names
  the tag. The cost is the refusal of text that reads nothing of the
  enumeration: after `enum E;` and the definition of a generic, the
  list of `E` makes the first use of each instance that follows it an
  error, whatever the definition names. The case is expected to be
  rare: both backends report `enum E;` before the list under
  `-pedantic`, and an enumeration that is declared with a fixed type
  is not refused. Where the text is the definition of a generic, the
  measurement of P23 counts the refusal with the others of rule 8 of
  3.5. A declaration is inexact if it or an earlier declaration of its
  entity that it sees holds an attribute, an alignment specifier or
  a `__typeof__` of an expression (3.5 rule 2), or is written through a
  typedef name so declared. Clang gives `__typeof__(obj)` the alignment
  of `extern wide obj;` after `extern int obj;`, where `wide` is an
  `int` aligned to 16, and GCC that of `typedef int t
  __attribute__((aligned(16)));` after `typedef int t; extern t obj;`.
  The exactness of a type argument, which 3.5 rule 2 reads from the
  text of an alias at its own place, so holds at each place where
  lowering writes the alias. The one name of an untagged type has no
  own place that vouches for it, so its declaration where the typedef
  of the type argument is written must be exact itself.
  *Provisional (P21).* Where an entity that the text uses is declared
  again between the two and whether its type stays the same depends on
  an unknown type (13.3), that declaration is an error, as one that
  changes the type is.
  The check is a point that needs the answer: the backend reads the
  lowered C alone and cannot compare it with the source, and taking the
  two types for one would guess that the unknown one adds nothing, which
  13.3 does not do for a composite type either. An entity of unknown
  type that is not declared again between the two has the type it had,
  and the text uses it as any other. The cost is the refusal of a
  declaration that changes nothing: a function with a SIMD type,
  `_Float16` or a block pointer in its signature that a generic uses
  and that is declared again, as by its definition, between the
  generic's definition and an instance. After
  `static __m128 dot(__m128);` and a generic that calls `dot`, the
  definition of `dot` makes the first use of each instance that follows
  it an error. The measurement of P21 counts these refusals and settles the
  rule; the refusal stays if it cannot. If the corpus shows the case to
  be common, the alternative gives an unknown type an origin, so that
  two unknown types of equal origin compare equal and such a
  declaration is seen to keep the type.
- Every other name that lowering writes there is its own: the name of
  what a type application, a universe name, a constructor or a type
  parameter denotes (10.1, 10.3), the name of the instance that a call
  or a use of a generic function names, or a name that it invents. Each
  is claimed (10.1, 10.3) or reserved (2.3), so no declaration hides
  one: not in a block, not in a copy of a deferred statement and not in
  an instance. The check leaves out the use of a generic function in
  the body of another, since the name that lowering writes for it is
  declared before each place of writing by construction: the first use
  of the instance whose body holds it causes the instance it names, and
  10.3 writes that one's prototype before the definition of the first.
  Only a body holds such a use in moved text, as the definition of a
  generic type and the head of a generic function hold none (7.3
  rule 2). A declaration that hides a universe name or a constructor
  from the source therefore changes no moved text.
- Moved text declares no name that is in scope after it. The text does
  not stay at its own place, so what follows it there would lose the
  declaration, and what follows a place of writing would gain it. A name
  whose scope ends inside the text, in a parameter list or in a block,
  is no such name. The kinds of moved text meet the clause each in its
  own way. A deferred statement is a block (section 6 rule 8), so the
  clause's first sentence holds for it by construction. A hoisted
  operand of a `try` declares no tag and no enumeration constant in
  the scope
  around it (5.1 rule 3). The definition of a generic declares its
  generic, and that of a generic variant its constructors, which
  lowering writes under the names of the instances (10.1, 10.3), and
  nothing else: it is not the first mention of a tag in file scope, and
  the head of a generic function declares no type at all (3.5 rule 8).
  The one name of an untagged type declares nothing, and the typedef
  around it only its reserved name (2.3). The clause holds as well for
  two texts that do not move: the operand of a `return` in the scope
  of a `defer` statement, which lowering writes in a block (section 6
  rule 12), and the operand of a `slice_from_array`, which it writes
  twice (section 8 rule 2). Text that moves, of
  every kind, also declares no object or function with linkage, even in
  a block of its own, as an `extern` declaration or a function
  declaration there: that entity is one the text around it sees, so
  what the declaration says reaches that text at each place of writing,
  unseen by the window above, which leaves out the text's own
  declarations; GCC reads `__alignof__(o)` in the holder of a `try` as
  16 where the operand declares `extern int o
  __attribute__((aligned(16)));`. Typing reads no declaration in the
  arguments of an attribute, so there text that moves holds none: no
  `{`, which may open a block, and no `struct`, `union` or `enum` of a
  tag that is not visible there.

The property is stated here alone and checked in one place. Every move
goes through one check of the three clauses, and so do the two texts
that stay in place (above), the operand of a `return` and the operand
of a `slice_from_array`, where the third clause applies. No kind of
text has a check of the property of its own: rules 8 and 12 of section
6, rule 8 of 3.5, rule 3 of 5.1 and rule 2 of section 8 cite the
property and show it on examples, and what rule 3 of 5.1, rule 12 of
section 6 and rule 2 of section 8 say of a name that an operand
declares is the third clause on their text. The check is told the kind
of text that it reads, and a failure carries the name of that kind
(13.6): one name for each kind, whichever clause fails. The one name of
an untagged type is written into an instance as the definition of a
generic is, and is refused under the same name. A count of the refusals
that one of those rules makes through the property so reads a name, and
no kind needs a check of its own to have a name of its own. A failure
that rests on a type that typec does not compute (*Provisional (P21)*,
above) carries instead one name of its own, whatever the kind of text,
so that the measurement of P21 counts those refusals under one name; the
count of a kind's rule leaves them out.

A place where the text is written is a place in the lowered C. The
copies of deferred statements stand at one place for each exit (section
6 rule 1), and the check reads the names that are in scope there:

- for a `break`, `continue`, `goto` or `return;`, directly before the
  keyword of the jump, in the block that stands in its place (the
  `defer` row). That block declares nothing, so the names in scope
  there are those in scope at the jump;
- for the end of a block that can complete (4.4), directly before its
  `}`;
- for a `return e;`, directly before the `return` keyword. Lowering
  writes the copies after the initialiser, or the expression statement,
  that holds `e` (above). The names in scope there are those in scope
  before the `return` of the source, since `e` declares none that is in
  scope after it (section 6 rule 12), and `__tc_r` where the block
  declares it, which is reserved (2.3), so that no copy names it;
- for the error path of a `try`, with its test: before the statement or
  declaration that holds the `try` and after the labels of that
  statement (above), so a declaration that holds a `try` is not in
  scope at them (section 6 rule 8).

The property covers the text that `typec` reads. *Unread text* is
every token that typing does not read. Attribute arguments, `#pragma`
lines, the bodies of block literals and the function bodies that are
passed through unread (13.3) are unread text. The backend
resolves what unread text names, at the place where the text is
written and under the spelling of the source. `typec` looks at the
identifiers of an attribute argument and of a `#pragma` line without
knowing which of them the backend reads as a name. It reads the text of
a `#pragma` line after `pragma` as preprocessing tokens (C11 6.10.6),
with the reader of the unit's text and under that reader's rules, and
the identifiers of the line are the identifiers among them. A line
that is no sequence of preprocessing tokens, as one with a `'` or a `"`
that begins no literal ending on the line (C11 6.4p3), is an error
wherever a rule below looks at the identifiers of a pragma: in moved
text and in Type-C text. Nothing says which names a backend takes from
such a line (for `#pragma weak f '`, GCC 16 reports an error and Apple
Clang 21 warns and ignores the pragma), so no reading of it would keep
the property. The cost is the refusal of a line that both backends
accept: `#pragma mark - Don't edit` in Type-C text is an error under
GCC 16, whose `-E` keeps the line and warns of the `'`, and the mark
has to be reworded. Apple Clang 21's `-E` drops a `#pragma mark` line,
so `typec` does not read it there. In C text that does not move `typec`
looks at the
identifiers of no pragma and passes every line on whole: GCC keeps some
pragmas verbatim in its `-E` output, the free text of a `#pragma mark`
line among them.

Of the kinds of moved text, only a deferred statement can hold a
`#pragma` line. The definition of a generic holds none, since a generic
whose definition holds one is an error (10.3), and the operand of a
`try` holds none, since a `try` is an error where a pragma line
stands in or directly before the statement or declaration that holds
it (5.1 rule 3). What the rules
below say of a `#pragma` line of moved text they say of a deferred
statement. The line moves with the statement: lowering writes it on a
line of its own, at its place among the tokens of each copy. A `#pragma
typec` line of Type-C text stands outside every external declaration,
and one of C text is ignored (11.1 rule 1), so lowering moves none.

A copy of a pragma is right only where the pragma applies to no more
than the statement after it or the block it stands in. One that sets
state for the rest of the text is in force once per copy: with

```c
void f(int c) {
  defer {
#pragma pack(push, 1)
    ;
  }
  if (c)
    return;
}
#pragma pack(pop)
struct s { char c; int i; };
```

the two exits push twice and the one pop leaves `struct s` packed, of
size 5 and not 8. A deferred statement therefore holds only the pragmas
of one list, `Statement_pragma` in the parser, each there with the
reason it reaches no further: `GCC unroll`, `GCC ivdep` and `GCC
novector`, Clang's `clang loop`, `unroll` and `nounroll`, which annotate
the loop that follows; and `STDC FP_CONTRACT`, `STDC FENV_ACCESS` and
`STDC CX_LIMITED_RANGE`, which in a compound statement are in force to
its end (C11 7.12.2, 7.6.1, 7.3.4), and lowering writes each copy as a
block of its own. On Apple Clang 21 and GCC 16 each reaches the loop or
block it precedes and no statement after it; a backend that does not
know one ignores it. Every other `#pragma` line of a deferred statement
is an error, in Type-C text and C text alike: `pack`, `GCC diagnostic`,
`GCC visibility`, `GCC optimize`, `GCC push_options`, `weak`,
`redefine_extname`, `message`, `once`, and a pragma that no backend
knows. OpenMP's `omp` pragmas are left out too: they do nothing without
`-fopenmp`, and with it the namespace holds regions such as `declare
target ... end declare target` that set state as `pack` does. The list
matches the leading identifiers of the line; a line whose first tokens
are not those identifiers alone holds a pragma that neither backend
knows. A `#pragma` line that is no sequence of tokens is refused first,
under its own code.

The scope of a defer statement holds pragmas of the list as well, the
six that annotate a loop alone, and none of those directly before an
exit, the end of its block or a statement that holds an exit (section
6 rule 9). A copy is then compiled under the pragmas in force at the
`defer` statement. Typing decides this once per function, in
`Scope_pragma`, from the scopes and exits that reachability finds:
every other pragma line there is an error, in Type-C text and C text
alike, among them `clang fp`, `STDC FP_CONTRACT`, `GCC optimize`,
`float_control`, `fenv_access` and `pack`.

Three rules carry the property into unread text.

- For the first half, an identifier in an attribute argument or a
  `#pragma` line of moved text that denotes something at the text's own
  place, as an ordinary identifier or as a tag, counts as a use of it. A
  declaration that hides it at a place of writing is refused as for any
  other use: where a deferred statement declares an object with
  `__attribute__((vector_size(N)))` and `N` is an enumeration constant,
  an `enum { N = 4 };` in a block that holds an exit is an error. An
  identifier that denotes nothing at the text's own place is not
  counted, which is the case of most words of a pragma, such as `push`.
  `typec` cannot tell such a word from a name that the source left
  undeclared, and what the backend finds under it at a place of writing
  is the backend's to say. A word that does denote something is counted,
  and a declaration that hides it at a place of writing is refused
  though it would change nothing.
- For the second half, an identifier in an attribute argument or a
  `#pragma` line may denote, at its place, what lowering writes under a
  name of its own: a type parameter, a universe name or a generic.
  Lowering leaves unread text as the source spells it, whether the text
  is moved or not, so the backend reads the spelling as the lowered C
  declares it there. In an attribute argument such an identifier is
  an error whatever the C around it declares: a type parameter in the
  definition of a generic, in any text (3.5 rule 4), and a generic or a
  universe name in Type-C text. The backend would read a C entity of
  the spelling with no message, as
  `__attribute__((aligned(sizeof(T))))` in a generic with a type
  parameter `T` would take the size of `char` in every instance after
  `typedef char T;`; or find nothing and refuse the lowered C, as it
  refuses the `vector` of
  `__attribute__((aligned(_Alignof(vector(int)))))`; or take the
  spelling for a word of the attribute, which the Type-C name does not
  mean. The cost is an attribute word that Type-C text spells as a
  generic, as the `open` of `enum_extensibility(open)` in the scope of
  a generic named `open`, which then takes another name. A `#pragma`
  line, whose words are many and common (`push`, `pop`, `pack`), is held
  to less, and so is an attribute argument of moved text that is C
  text, which Type-C text does not write: where the Type-C name hides a
  C entity of the spelling, the backend would read that entity, with no
  message, and the identifier is an error, in Type-C text and in moved
  text that is C text. With `int option;` between the definition of a
  generic that C text writes and an instance of it,
  `__attribute__((aligned(sizeof(option))))` in the definition is such
  an error. Where it hides none, the lowered C declares nothing under
  the spelling and the backend decides, as it takes the `push` of
  `#pragma pack(push)` in the scope of a generic named `push`. C text
  that does not move is the backend's to read. A constructor is not
  among these names. Unread text has no target type (3.3), so an
  unqualified name there means what C declares. The qualified `T.C` is
  refused through a generic or a universe name `T`; through a typedef
  name it is not C, and the backend refuses it.
- No other unread text stands in moved text, in any text. The two
  rules above cover attribute arguments and `#pragma` lines, whose
  identifiers `typec` looks at. All other unread text is a body that
  holds statements and declarations and is unread as a whole, so that
  neither rule reaches into it: the body of a block literal and a
  function body that is passed through unread (13.3). A block literal
  holds no Type-C text (13.3), so the rule refuses one in a deferred
  statement that C text writes with `_Defer` and in a generic that C
  text defines. A function body that is passed through unread is moved
  text only as the body of a generic function, and that function is an
  error: no instance could be lowered from its body.

The state that positional pragmas set is that of the place where the
text is written, and it is outside the property, which speaks of names.
A deferred statement sets no such state and declares no type for it to
lay out (section 6 rule 9). A hoisted operand of a `try` is written
under the
state of its own place, since no pragma stands between the two (5.1
rule 3). A type instance is kept from `#pragma pack` by the bracket of
10.3 and from no other pragma that changes a layout, among them
`#pragma ms_struct on`, GCC's `#pragma scalar_storage_order` and a
`#pragma clang attribute push` that applies `packed`. A type instance
that is first used inside the region of one of them in one translation
unit, and outside it in another, has one name and two layouts. Code
under such a pragma keeps the first use of every type instance outside
its region.

*Provisional (P27).* A function instance is compiled under the state of
its generic's definition, by the construction that serves the operand
of a `try`: no `#pragma` line that sets state stands between the two
places (7.3 rule 4). The first use of an instance is an error where
such a line stands, in any scope, between the definition of its generic
and the place where 10.3 writes the instance, its prototype and its
definition. The error cites the line. The state at a place is what the
`#pragma` lines before it have set, so two places with no such line
between them have one state, whatever the pragmas are and whatever a
backend makes of them: `typec` does not read what a pragma does. What a
file-scope `__asm__(".section ...")` tells the assembler is no such
state and is outside the rule.

Without the rule, the place of one use would decide the code of an
instance for every use in the unit, and that place differs between
units. GCC 16 gives a function the options of a `#pragma GCC optimize`
region that holds its definition, or only its prototype. After
`#pragma GCC optimize("fast-math")` a body `return x * 0.0f;` returns 0
for a NaN, at `-O0` and at `-O2`, and it does so as well where the
prototype alone stands in the region and the definition after its
`#pragma GCC pop_options`. Apple Clang 21 with `-O2 -mfma` compiles
`a * b + c` as one fused operation before a `#pragma STDC FP_CONTRACT
OFF` line of file scope and as a multiplication and an addition in
every function after it. It leaves a function defined after `#pragma
clang optimize off` unoptimised, and puts one defined in a `#pragma
clang attribute push` region that names a section, or after a `#pragma
clang section` line, into that section.

A `#pragma` line sets state unless it is of one of three kinds. Each
has a reason that holds for every instance:

- A `pack` line. Every text of an instance stands in the bracket of
  10.3, so an instance has the packing of the command line whatever
  line stands before it. This one part of the state is the command
  line's and not the definition's (10.3).
- A `GCC diagnostic` or `clang diagnostic` line. It changes the
  messages of the backend and no code: Apple Clang 21 and GCC 16 write
  the same assembly for a function inside a `diagnostic ignored` region
  and outside it, at `-O0` and at `-O2`. Which warnings an instance
  draws is thus decided where it is written, unlike its exemption as
  the text of a system header, which follows the lines of the
  definition (13.4). A `diagnostic ignored` bracket around the
  definition of a generic silences nothing in its instances, and under
  a `diagnostic error` line the backend refuses an instance whose body
  draws that warning, as it does under `-Werror` on the command line.
  Counting these lines would refuse nearly every unit: the twelve
  headers measured below put a diagnostic bracket into a unit under
  both backends.
- A line of `Statement_pragma` (above) that stands inside a function
  body. It reaches the loop that follows it or the end of its block,
  and nothing after the body: with `#pragma STDC FP_CONTRACT OFF` in
  the body of one function, Apple Clang 21 still fuses `a * b + c` in
  the next. At file scope the three `STDC` lines of the list are in
  force to the end of the unit (C11 7.12.2, 7.6.1, 7.3.4) and set
  state.

Every other line sets state for this rule: one that no backend knows,
one that only prints, as `#pragma message`, and one that names what it
acts on, as `#pragma weak f`. The three kinds are a list, and the list
errs to one side only. A line that it lacks is refused with a message
that cites it; a line that it held without cause would change the code
of an instance with no message. So a kind enters the list with the
reason that it reaches no instance, and with nothing less.

Two other constructions were measured and set aside.

- A bracket around each instance that restores the state of the
  command line, as the bracket of 10.3 restores the packing. GCC 16 has
  the lines for its options: an instance between `#pragma GCC
  push_options`, `#pragma GCC reset_options` and `#pragma GCC
  pop_options` inside a fast-math region returns a NaN for a NaN.
  Apple Clang 21 ignores those lines as unknown pragmas, and its own
  lines set a state of their choice and not the command line's: under
  `-ffast-math`, a body between `#pragma float_control(push)` and
  `#pragma float_control(pop)` is compiled strictly after `#pragma
  float_control(precise, on)` and after `#pragma clang fp
  reassociate(off)` alike, where the rest of the unit is not. The
  bracket would be a list of the pragma families of each backend that
  no measurement completes, and it would give the state of the command
  line, which is not that of a definition inside a region.
- Every function instance at the end of the unit. All instances would
  share one state, the one that the unit leaves in force, which is not
  the definition's after a region that the unit does not close. The
  prototype of an instance would still stand before its first use, and
  GCC 16 takes the options from the prototype. The text of the
  definition would be written at the end of the unit, so each of the
  three declarations that the resolution property refuses between the
  two places (above) would be refused anywhere after the definition
  of a generic function that the unit uses.

The cost is the refusal of a use where the lines between change
nothing for the instance: a region that is opened and closed again
between the two places, and a line that sets no state at all. Measured
on macOS with twelve headers of the C library and POSIX (`<stdio.h>`,
`<stdlib.h>`, `<string.h>`, `<stdint.h>`, `<math.h>`, `<pthread.h>`,
`<unistd.h>`, `<sys/stat.h>`, `<sys/socket.h>`, `<netinet/in.h>`,
`<time.h>`, `<errno.h>`), the lines that reach `typec` are `pack` and
diagnostic lines, which are not counted, and under Apple Clang 21 the
`#pragma clang assume_nonnull begin` and `end` of `<pthread.h>` and two
headers that it includes. GCC 16's `<immintrin.h>` holds 118 regions of
`#pragma GCC push_options` and `#pragma GCC target`. A generic function
that is defined before `#include <pthread.h>` under Apple Clang 21, or
before `#include <immintrin.h>` under GCC 16, has no instance first
used after it. The same holds for one that is defined before a
`#pragma weak`, `#pragma GCC visibility` or `#pragma message` line,
which the `-E` of both backends keeps, or before a `#pragma mark` line
under GCC 16 (above). A unit therefore includes the headers that define
generic functions after the headers that hold such lines, and writes
such a line of its own after the first use of each instance or before
the definitions.

Stage 3 settles the rule. The container library and the measurements
(packages 3.5 and 3.6) count its refusals from the name of rule 4 of
7.3, by the leading identifiers of the cited line. If the refusals are
common, the alternative reads the pairs of lines that open and close a
region, as `#pragma GCC push_options` and `#pragma GCC pop_options`,
and passes over a region that is closed before the place of writing.
Each pair enters one list with the measurement, for each backend, that
its closing line restores everything that a line of the region can
set. Without such a finding the refusal stays.

**The check of a slice.** *Provisional (P28).* A function that served
the indexes of a slice type would be written from no definition in the
source, and the rule above would have nothing to hold it to. Lowering
therefore writes none. A slice index `s[i]` is an expression at its use
that assigns the value of each operand to a temporary, tests, traps
(10.5) and only then indexes:

```c
(*((void)(__tc_s0 = (s)),
   (void)(__tc_i0 = (__typeof__(__tc_i0))(i)),
   (void)(__tc_i0 < __tc_s0.len ? (void)0 : trap),
   &__tc_s0.data[__tc_i0]))
```

and `slice_sub(s, lo, hi)` is one that yields the slice:

```c
((void)(__tc_s0 = (s)),
 (void)(__tc_lo0 = (__typeof__(__tc_lo0))(lo)),
 (void)(__tc_hi0 = (__typeof__(__tc_hi0))(hi)),
 (void)(__tc_lo0 <= __tc_hi0 && __tc_hi0 <= __tc_s0.len
        ? (void)0 : trap),
 (struct R){ __tc_s0.data + __tc_lo0, __tc_hi0 - __tc_lo0 })
```

The function that holds the test declares its temporaries:

```c
struct R __tc_s0;
__typeof__(__tc_s0.len) __tc_i0;
```

and `__tc_lo0` and `__tc_hi0` as it declares `__tc_i0`. The
declarations stand where the typedef of `__tc_ret` stands (above),
before the block that holds the body as written, for the reasons given
there. No statement precedes them and no jump crosses them.

`struct R` names the slice instance by its claimed tag, as the copy of
a `match` does (the `match` row). `__typeof__` of the member `len`
names its type, since no name for it is sure to be visible. *trap* is
the trap of 10.5 written as an expression of type `void`: the call of
`__builtin_trap`, which both backends have (2.4), after the call of the
trap function where the command line names one. Everything else in the
two forms is ISO C. Each operand is written once and evaluated once,
`s` first, and the index is an lvalue: the target of the pointer that
the expression yields. The conversion of an index to the type of `len`
is a cast, as rule 1 of section 8 writes it, and that rule leaves it no
bit to drop. As an implicit conversion it would draw
`-Wsign-conversion`, which `-Wconversion` turns on, for every signed
index under both backends. Each left operand of a comma is cast to
`void`, which says that its value is not wanted; without the cast Apple
Clang 21 reports every comma under `-Wcomma`.

The conversion of rule 5 of section 8 is a `slice_sub` with no bounds
and nothing to test. `slice(T)` and `slice(const T)` are two structures
of C, `struct R` and `struct C`, and neither backend takes one for the
other, so the conversion of `e` makes its slice from the members of
the operand:

```c
((void)(__tc_s0 = (e)), (struct C){ __tc_s0.data, __tc_s0.len })
```

C converts the pointer, as it does in an assignment (C11 6.5.16.1p1).
`e` is written and evaluated once, and `__tc_s0` is declared and
numbered as that of a test is. What this part says of a `slice_sub`
holds for the conversion: where C evaluates it, it stands in a function
body (section 8 rule 9), and where C does not, it has the form that a
`slice_sub` has there (below). Nothing of the program is evaluated
between its assignment and its two reads, so no call resumes it while
its temporary holds a value; the slice that it makes is a value of the
full expression, as that of a `slice_sub` is ("An evaluation that is
resumed", below). A `slice_from_array` and a `slice_unchecked` are
converted without a temporary (below).

`e` is the expression that rule 5 of section 8 converts, and the form
is the same in each place. In a position that has a target type it is
the expression of the position, or the operand that has its target
type (3.3) where that expression is in parentheses, a conditional or a
comma expression, so an initialiser, the right operand of `=`, an
argument, the operand of a `return` and the argument of a constructor
are one case to lowering, and in `str s = k ? m : n;` each branch
converts on its own. In a conditional
operator it is the one operand of type `slice(T)`, and the other
stands as written:

```c
c ? ((void)(__tc_s0 = (s)), (struct C){ __tc_s0.data, __tc_s0.len }) : k
```

Both backends refuse the conditional whose operands are the two
structures, as the source has them.

The operands are written inside the expression, where the source has
them, and only their values go into the temporaries. What section 8
says of an index follows from that and needs no rule for any place:

- A compound literal in an operand belongs to the block that encloses
  the use (C11 6.5.2.5p5), which is the user's, so it lives as long as
  it does in the source.
- A tag or an enumeration constant that an operand declares is in
  scope after the index, as the source has it. The third clause of the
  resolution property has nothing to refuse.
- The test is written the same in the header of a `for`, in the
  condition of a `while`, in an initialiser, in a statement expression,
  in the operand of a `try` and in a deferred statement. The
  temporaries are in scope in the whole body, so the copies of a
  deferred statement assign the same ones, and only one copy runs at a
  time.
- The temporaries have no initialiser and no variably modified type,
  and they stand before the body, so no `goto` and no `switch` is
  refused for them (C11 6.8.6.1p1), and neither `-Wjump-misses-init`
  nor `-Wdeclaration-after-statement` reports one.
- The temporaries take a number, which counts the tests and the
  conversions of the function from 0 in the order of the source: by
  the first token of each, which for an index is that of its slice
  and for a conversion that of its operand, and where two begin at
  one token, the outer one first. In `s[t[k]]` the index of `s` takes
  0 and that of `t` takes 1, and the conversion of `rows[i]` takes its
  number before the index that is its operand. No two of them share a
  temporary, so an index in an operand of another, as in `s[t[k]]`,
  assigns none that the outer one holds, two tests that C leaves
  unsequenced, as in `f(s[i], t[j])`, assign different objects, and no
  name hides another under `-Wshadow`. Each call of the function has
  temporaries of its own, and in one call an evaluation of a test ends
  before the next begins, unless a call in an operand returns a second
  time ("An evaluation that is resumed", below). An index or a
  `slice_sub` that C does not evaluate holds no test and takes no
  number (below).

Measured on Apple Clang 21 and GCC 16, in the ISO and the GNU form of
C11 and of C17: the two forms compile without
a diagnostic under `-pedantic-errors -Wall -Wextra -Wshadow
-Wconversion -Wsign-conversion` in the header of a `for`, the
condition of a `while`, an initialiser and a statement expression,
with a nested index, with a signed one and with a `goto` over a block
that declares a variable length array. At `-O0` and at `-O2`,
`slice_from_array((int[]){ k, k + 1, k + 2 })[1]` yields `k + 1`, a
`slice_sub` of such a slice reads its elements, and a pointer that an
index stores, as in `s[(p = (int[]){ 42 }, 0)]`, reads 42 after it.
The conversion compiles without a diagnostic under the same options in
an initialiser, an assignment, an argument and a `return`, from
elements of `int` and of `int *`, and evaluates its operand once. It
compiles so on either operand of a conditional operator as well.

**An index or a `slice_sub` that C does not evaluate.** C leaves four
operands alone, each by a rule of its own:

- the operand of `sizeof`, unless its type is a variable length array
  (C11 6.5.3.4p2). An operand whose type is variably modified and no
  such array, as a pointer to one is, is not evaluated;
- the operand of `__typeof__`, unless its type is variably modified.
  C23 says so of `typeof` (6.7.2.5p4), and both backends do so for
  `__typeof__` in C11 and in C17;
- the operand of `_Alignof`, always. ISO C gives it a type name alone
  (C11 6.5.3p1), and both backends leave the expression of the GNU
  `__alignof__` alone as well, also one whose type is a variable
  length array;
- the controlling expression of `_Generic`, always (C11 6.5.1.1p3).

Apple Clang 21 and GCC 16 agree on each. With a call in the bound of
an array type, `sizeof(*(int (*)[g()])p)` calls `g` and
`sizeof((int (*)[g()])p)` does not, `__typeof__((int (*)[g()])p)`
calls it, and `__alignof__(*(int (*)[g()])p)` and a `_Generic` on that
operand do not.

An index or a `slice_sub` that stands in such an operand, at any
depth, has no value to test. Lowering writes it as the trap followed
by its operands, with no test and no temporary:

```c
(*((void)__builtin_trap(), &(s).data[+(i)]))

((void)__builtin_trap(), (void)(s), (void)(lo), (void)(hi),
 (struct R){ 0 })
```

A conversion (above) is the second form with its one operand,
`((void)__builtin_trap(), (void)(e), (struct C){ 0 })`. The index
stands under a unary plus, which promotes it and changes neither its
value nor the type of the element. Without the plus, an index of type
`char` is the subscript of an array as written, and both backends
report it under `-Wchar-subscripts`, which `-Wall` turns on; the form
that is evaluated casts its index and draws no such report.

Each has the type of the form that is evaluated: the first is an
lvalue of the element type, the second a `struct R`. Each operand is
written once, in the order of the source, so what an operand declares
is declared once and the form sets no limit on what an operand holds.
Neither form names anything of a function, so section 8 rule 9 lets
both stand anywhere. The trap is the builtin alone, also where the
command line names a trap function (10.5). That function reports the
failures of the program, and this trap marks a defect of `typec`
(below); without the call, the form names nothing beyond its operands
and their instance, so no unit and no emitted header (9.3) has a
declaration to place before it.

The trap is what makes the form safe to choose. Whether C evaluates an
operand follows from the type that the backend gives it, and `typec`
judges by the type that its own typing gives it. Where the two agree,
nothing of the form is executed, the trap included. Where C evaluates
an operand that `typec` took it to leave alone, the trap is the first
thing evaluated: the program ends there, before it evaluates an
operand and before it reaches an element, at an index in range as at
one out of range. So no judgement of `typec` yields an index that is
executed without its test, and none evaluates an operand twice. Two
smaller forms do not give that:

- The subscript alone, `(s).data[(i)]`, is an access without a test
  wherever the judgement is wrong. No wrong judgement is known, and
  the nearest case shows what one would do. In
  `sizeof(*(c ? (int (*)[s[i] = 5])p : (void *)(sizeof(struct four) - 4)))`,
  where `struct four` holds one `int`, the third operand is a null
  pointer constant because a layout constant has the value 0, which
  `typec` does not compute (13.3, P16). The conditional so has the
  type of its second operand, the operand of the `sizeof` is a
  variable length array, and C evaluates it. 13.3 gives that
  conditional an unknown type, an operand of unknown type counts as
  evaluated (below), and the index has its test: under both backends
  it stores once at an index in range and traps at one out of range.
  The judgement rests on the type of every expression that can stand
  in such an operand, though, and so on all of typing. A defect
  anywhere in it that took a variably modified type for another would,
  with the subscript alone, be an access without a test and without a
  message: written so in the operand above, both backends store
  through an index out of range, which AddressSanitizer reports as a
  write beyond a heap object. With the trap, such a defect ends the
  program at its first index.
- A test written over the operands,
  `(*((size_t)(i) < (s).len ? &(s).data[(i)] : ...))`, evaluates the
  index once for the test and once for the element. With `s[n++]` in
  that operand it tests one index and reaches the next: under both
  backends at `-O0` the store goes beyond the heap object. A test
  reads the value of the index twice, so it needs a temporary.

The form that is evaluated cannot stand in these operands either. Its
temporaries need a function, and its assignments are side effects:
Apple Clang 21 reports them in three of the four operands under
`-Wunevaluated-expression`, which it has on without an option: once
for `sizeof(s[0])`, once for `__alignof__(s[i])`, once for a
type-generic macro whose `_Generic` is given `s[i]`, and twice for
`isnan(s[i])` with the `<math.h>` of macOS, whose macro takes `sizeof`
of its argument. GCC 16 reports none of them.

Measured on Apple Clang 21 and GCC 16, in the ISO and the GNU form of
C11 and of C17, at `-O0` and at `-O2`: the two forms draw no
diagnostic under `-pedantic-errors
-Wall -Wextra -Wshadow -Wconversion -Wsign-conversion` in the operand
of `sizeof`, of `__alignof__` and of `__typeof__`, in the controlling
expression of `_Generic` and in `isnan`, with a signed index, an index
of type `char`, an index
of an index and an index of a `slice_sub`, and at file scope in the
size of an array, the width of a bit-field, the value of an
enumerator, a `_Static_assert`, an initialiser and the size of an
array parameter. Copied into an operand that C evaluates, each traps
under both backends, at `-O0` and at `-O2`, before it evaluates an
operand.

The judgement errs to the side of the test. Lowering writes the form
above in the four operands and nowhere else: in the operand of
`_Alignof` and in the controlling expression of `_Generic` always,
and in the operand of `sizeof` and of `__typeof__` only where typing
has the type of the operand and that type is not variably modified.
An operand of unknown type (13.3, P21) counts as evaluated. Lowering
asks one question of both operators, whether the type is variably
modified. C asks that of `__typeof__`, and of `sizeof` whether the type
is a variable length array. The two differ for a variably modified
type that is no such array, as a pointer to one is: in a `sizeof` such
an operand gets the test, which C then leaves alone with the rest of
the operand.
Every other index and `slice_sub` gets the test, also where a backend
evaluates nothing: in an association of a `_Generic` that is not
selected, and in an argument of `__builtin_constant_p`. A test that is
not evaluated costs nothing, and neither backend reports one in an
operand of variably modified type.

**The forms set aside.** The test is text of its use, so it has the
state of its use, as `s.data[i]` has, and no place of a first use
decides the code of a later one. A function that the uses of a unit
shared would be compiled under the state of the place where lowering
wrote it, before its first use. Measured with such a function,
`static inline` and written
directly before the first function that indexes: inside a `#pragma GCC
target("avx512f")` region, GCC 16 at `-O2` does not inline it into a
function after the region's `#pragma GCC pop_options`, which calls it
out of line, where under a region whose target adds nothing it inlines
the function there. After `#pragma clang section text="..."`, Apple
Clang 21 at `-O0` puts it into that section, and a function after the
line that ends the section calls it there. With the expression, each
of the two functions holds its own test in both cases.

Rule 4 of 7.3 cannot take such a function in. The one place that could
stand for its definition is the start of the unit, and the function
names its slice instance, which 10.3 writes after the declaration of
the type argument. The rule would so refuse the first index of each
slice type that follows any line that sets state: every one after
`#include <pthread.h>` under Apple Clang 21 and after `#include
<immintrin.h>` under GCC 16 (above).

A statement expression of the GNU profile is set aside as well. It
declares the temporaries in a block of its own,
`(*__extension__ ({ const struct R __tc_s0 = (s); ... }))`, and needs
none in the function. Its operands stand in that block. A compound
literal in one of them dies where the block ends, before the element is
read: for `slice_from_array((int[]){ k, k + 1, k + 2 })[1]`, GCC 16 at
`-O2` yields 0. A name that an operand declares goes out of scope
there too. Neither backend takes a statement expression outside a
function body (section 6, rationale for rule 11), and it is a fourth
GNU form of lowered code (2.4).

**An evaluation that is resumed.** A full expression that holds a
test holds values while the rest of it is evaluated. The test holds
the value of `s` in `__tc_s0` while `i` is evaluated, and that of a
`slice_sub` holds `s` and `lo` so, until the element is reached or the
slice is made. From there the backend holds the address of the
element, or the slice, in a place that it chooses, until the
expression uses it: across the right operand of an assignment to the
element, and across the other arguments of a call that takes its
address. A call that returns a second time, at any depth in the full
expression, resumes the evaluation there. Where the same call of the
function has evaluated the same full expression in between, or begun
to, `__tc_s0` holds what that evaluation assigned, and C11 7.13.2.1p3
makes it indeterminate: it is an object of the function, not volatile,
that changed between the two returns. The place of the backend is the
same place in both evaluations, and no object that a qualifier could
reach. The copies of a deferred statement are one full expression in
this, since they assign the same temporaries (above). A recursive
call of the function is another call, with temporaries of its own, and
an index that is evaluated after the call that returns twice is
evaluated again after the second return, with its test. Section 8
rule 10 makes the behaviour undefined. No form of the test and no
refusal would make it defined (below), so lowering writes nothing for
it and `typec` refuses nothing.

C keeps `setjmp` out of an operand, and other calls not. A call of
`setjmp` is a whole expression statement or the controlling expression
of a statement, alone, under `!` or compared with a constant (C11
7.13.1.1p4), and anywhere else its behaviour is undefined (p5): when
it returns, no expression holds an operand that is evaluated and not
yet used. A statement expression of the GNU profile puts such a
statement inside an operand, and `getcontext` and `__builtin_setjmp`
are calls that no rule keeps out of one.

Two programs measure it on Apple Clang 21 and GCC 16. In the first, a
loop evaluates
`s[__extension__ ({ if (!phase) { if (setjmp(env)) phase = 2; } 0; })]`
over a static array and then over a heap array; the program then frees
the heap array, restores `s` and calls `longjmp`. Under
AddressSanitizer the resumed evaluation reads the array of its own
evaluation, the static one, or that of the later one, which is freed:

| The index is written as | Apple Clang 21 `-O0` | Apple Clang 21 `-O2` | GCC 16 `-O0` | GCC 16 `-O2` |
| --- | --- | --- | --- | --- |
| the expression of this part | later | own | later | later |
| the same with `volatile` temporaries | later | later | later | later |
| the statement expression set aside above | later | own | later | later |
| a function that takes the slice, then the index | later | own | own | own |
| a function that takes the index, then the slice | own | own | later | later |
| `*(p() + i)` of C, where a call yields the pointer | later | own | later | later |
| `*(i + p())` of C | own | own | later | later |

The rows of the expression and of `*(p() + i)` are the same where the
operand holds a call of `getcontext` or of `__builtin_setjmp` and no
statement expression. No row is `own` in every column.

In the second program both arrays stay alive. The first has 4
elements and the later one 64, and the resumed evaluation has the
index 40, at which the source traps. With the expression of this part
the resumed evaluation traps where it has its own values (Apple
Clang 21 at `-O1`, `-O2` and `-Os`), and points to element 40 of the
later array where it has the later ones (Apple Clang 21 at `-O0`,
GCC 16 at `-O0`, `-O1` and `-Os`). Under GCC 16 at `-O2`, with `setjmp`
as the call, it has one of each: it tests the index against the length
of the later slice and adds it to the pointer of its own, and so
points 36 elements beyond an array of 4. The code keeps the two
members of `__tc_s0` in two places of the frame, and the evaluation in
between stores one of them. That is an access out of bounds with every
array alive and nothing freed. A subscript of C, which holds one
pointer, has no such result: a test of a slice reads two values, and
indeterminate values need not belong together.

A third program measures the value that the backend holds. Its loop
evaluates `put(&s[idx()], v)`, where `put` stores `v` through its
pointer and `v` holds the call that returns twice, over a static array
of 4 with the index 2 and then over a heap array of 64 with the index
40; each index passes its test. The program then frees the heap
array, restores `s` and resumes the first evaluation. Where the
backend evaluates the index before `v`, as Apple Clang 21 does with
the arguments in this order and GCC 16 with them in the other, the
resumed call stores through the address of the later evaluation:
AddressSanitizer reports a write to the freed heap array under Apple
Clang 21 at `-O0` and under GCC 16 at `-O0` and at `-O2`, with each of
the three calls. Apple Clang 21 at `-O2` stores into element 2 of the
static array. The subscript of C in that argument, `&*(p() + i)`, gives
the same result in each of these cases, and so do volatile
temporaries, but for GCC 16 at `-O2` with `setjmp`, which stores into
the static array. Where the backend evaluates the index after `v`,
the index is evaluated after the second return and traps: 40 in a
slice of 4. The operands of the index hold no call that returns
twice here, so the limit of rule 10 is over the full expression.

No form of the test keeps the values of the resumed evaluation. The
evaluations of one test that are suspended at once in one call of a
function have no bound, since each turn of a loop can mark a place of
its own, and the objects of that call are those of the blocks it is
executing, a fixed number. So no declaration gives each suspended
evaluation a place for the value of `s`.

Volatile temporaries keep the values of one evaluation together, and
no more. They hold what was last assigned to them, since C11
7.13.2.1p3 speaks of the other objects alone, so the resumed
evaluation tests and reaches the slice of the later evaluation: in the
second program, element 40 of the later array under both backends at
the four levels and with the three calls. What remains is whether that
slice is alive, which no slice promises (section 8 rule 7). The
temporaries are plain all the same, on two grounds:

- The cost falls on every index. A volatile object is stored and
  loaded at each use and is held in no register. On the sample of
  "The cost of the expression" (below) the code at `-O2` grows from
  609 bytes to 1318 under Apple Clang 21 and from 422 to 1374 under
  GCC 16. A loop that sums the 4096 elements of a slice takes about 20
  times as long under Apple Clang 21, which no longer vectorises it,
  and about 3 times under GCC 16; one that copies them, about 40 and
  about 4 times.
- It does not close the case. The first operand can hold a slice that
  C itself holds across such a call: an argument of a call that yields
  `s`, while the call that returns twice stands in another argument.
  That value is where a plain temporary is, and lowering does not
  declare it. In the second program with the call there, the resumed
  evaluation had the values of one evaluation in each of 96 runs (the
  two backends, the four levels, the three calls, either order of the
  arguments, plain and volatile temporaries); neither backend promises
  it. The address of an element that has passed its test is such a
  value in every index, and in the third program the qualifier changes
  one result of twelve.

Volatile temporaries for the tests that can be resumed, and plain ones
for the rest, would cost less. Control enters an expression of C a
second time only where a call returns or at a label of a statement
expression, so a test with no call and no statement expression in its
operands after the first holds no value in a temporary across one. No
test of the sample has one, and the qualifier would cost the sample
nothing; an index whose operand calls a function that the backend
inlines into a loop would pay what the loops above pay. The form adds
a judgement to lowering and leaves the values that the backend holds.
The owner's decision is against it: the temporaries are plain, and
section 8 rule 10 documents the limit. Stage 3 still counts such tests
in the library and the pilot and measures the qualifier on them
(package 3.6), so that the cost that the decision avoids is on record
with P28.

No refusal is complete short of one that refuses every call in a
full expression that holds an index. A refusal of the statement
expression there would leave `getcontext` and `__builtin_setjmp`,
which need none, and would refuse the macros that GNU C writes as
statement expressions to evaluate an argument once, a `max` in an
index among them. A refusal of the calls that return twice needs
their list, which is the backend's. The headers of macOS declare
`setjmp`, `sigsetjmp`, `getcontext` and `vfork` without an attribute,
and each backend takes
a call of each to return twice by its name, as it takes a call of a
function declared with the GNU attribute `returns_twice`. A call
through a pointer to `getcontext` both take to return once. A list in
`typec` would be a second copy of each backend's, and no list holds
the call through a pointer.

An evaluation that is resumed before its function begins the next
finds its values: `__tc_s0` did not change between the two returns,
and the later operands are assigned after the second. Without the
second turn of the loop, the first program reads the static array
again under both backends at both levels, with each of the three
calls, and the second reaches element 2 of its own array with the
index 2 and traps with the index 40, at the four levels. Checked text
names a function that returns twice only in an `unsafe` block or as a
trusted contract (11.1 rule 4), so tier 1 rests there on what it rests
on elsewhere (section 14).

**The cost of the expression.** The expression has three costs.

- An index and a `slice_sub` that C evaluates stand in a function body
  alone (section 8 rule 9). At file scope and in the definition of
  a generic type C evaluates constant expressions only, which neither
  is, so the rule refuses there what the backend would. In the head of
  a function it refuses what C takes with a pointer: an index in the
  size of an array parameter, `void f(slice(int) s, int a[s[0]])`.
- In the operands that C does not evaluate, the judgement of `typec`
  decides between the test and the trap (above). A wrong judgement
  leaves no access without a test and evaluates nothing twice; it ends
  a program that C defines, at an index in range as at any other, and
  is a defect of `typec`, to be repaired in its typing. None is known.
- Without optimisation the test is repeated at each use, where a call
  would stand, and each test keeps its temporaries in the frame of its
  function. On a sample of 20 tests in 13 functions, compiled for
  x86-64, the code at `-O0` is 29% larger under Apple Clang 21 (1669
  bytes against 1297) and 23% larger under GCC 16 (1815 against 1478),
  and the locals of the function of four tests reach 140 bytes below
  the frame pointer under Apple Clang 21 and 144 under GCC 16, against
  44 and 64. The frame grows in proportion to the tests of the
  function, whichever of them run, since no two share a temporary;
  that function holds the most tests of the sample. With optimisation
  the two forms cost the same: at `-O1`
  and at `-O2` both backends write the same instructions for the
  expression as for the function (609 and 422 bytes at `-O2`), at
  `-Os` Apple Clang 21 does so too, and GCC 16 writes 4 bytes fewer.
  The statement expression takes 1885 and 1818 bytes at `-O0`. An
  index and a `slice_sub` out of range end the program with the same
  trap in both forms, at `-O0` and at `-O2`.

These measurements are of a sample written by hand in the lowered
form, on one target and two backends. The sample is in no repository:
it is at `/Volumes/Optaine/design-fix/slice` on the owner's machine, as
it was measured. `comma/measure.sh` there repeats the measurements
of the expression that this part cites, `uneval/measure.sh` those
of the operands that C does not evaluate and of `slice_from_array`,
`longjmp/measure.sh` and `volatile/measure.sh` those of an evaluation
that is resumed and of volatile temporaries, and `forms/measure.sh`
those of the conversion, of an index of type `char`, of an index under
a layout constant, of an initialiser in parentheses and of a
structure in a parameter list, and `contexts/measure.sh` those of the
term for an element of size 0, of the initialisers of file scope, of
the conversion in a conditional operator and for elements of array
type, of the length of a `slice_from_array` as the size of an array
and of an element that is held across a call in another argument.
Stage 3 settles the form
(package 3.6): the cost of the tests in the container library and the
pilot, without optimisation as well as with it, the refusals of rule 9
of section 8, read from its name, the indexes and `slice_sub`
expressions that stand where C does not evaluate them, and the tests
that a call could resume, with the cost of volatile temporaries for
those alone. Without a finding against it the expression stays, with
plain temporaries.

**`slice_from_array` and `slice_unchecked`.** Neither holds a test or
a temporary. Each is a compound literal of the instance that its use
takes, `struct R`: its own, or the instance of the `slice(const T)`
that rule 5 of section 8 converts it to, in parentheses or not. C
converts the pointer in the literal (C11 6.5.16.1p1), so the
conversion of either needs no function to stand in. The literal of
its own instance would not do there: both backends refuse it as the
initialiser of the other structure. `slice_unchecked(p, n)` is
`(struct R){ (p), (n) }`, and `slice_from_array(a)` is, where the
elements of `struct R` are `int`,

```c
(struct R){ (a), sizeof(a) / sizeof(__tc_arg__i)
    + 0 * sizeof(char[sizeof(__tc_arg__i) != 0 ? 1 : -1]) }
```

where `__tc_arg__i` is the typedef of the argument of `struct R`
(10.3): the type of an element, with the `const` of the conversion,
which changes no size. Converted to a `slice(const int)`, whose
instance is `struct C`, the same `slice_from_array(a)` is

```c
(struct C){ (a), sizeof(a) / sizeof(__tc_arg__Ki)
    + 0 * sizeof(char[sizeof(__tc_arg__Ki) != 0 ? 1 : -1]) }
```

As the initialiser of an object, or of a member or an element of one,
that is declared with the type of `struct R`, each is the braced list
alone, `{ (a), ... }` with the same length, as a constructor is there
and under the condition of its row (the constructor row), so that the
initialiser of an object of static storage remains constant. GCC 16
refuses the compound literal at file scope under `-pedantic-errors`
("initializer element is not constant"), where Apple Clang 21 takes
it, and both take the braced list. So
`slice(uint8_t) bytes = slice_from_array(buffer);` stands at file
scope, as section 8 has it, and so does
`slice(const uint8_t) bytes = slice_from_array(buffer);`, whose braced
list initialises the instance of `slice(const uint8_t)`.

The braced list replaces the whole initialiser, with the parentheses
that the source writes around the `slice_from_array` or the
`slice_unchecked`, as it does for a constructor:
`slice(uint8_t) b = (slice_from_array(buffer));` has the initialiser
`{ (buffer), ... }`. Parentheses change neither the type nor the
value of an expression (C11 6.5.1p5), so the initialiser means the
same without them, and nothing that keeps them stands at file scope
under GCC 16 with `-pedantic-errors`: around the braced list they
make `({ ... })`, a statement expression of GNU C, which neither
backend takes at file scope, and around the compound literal they
leave what GCC refuses above.

The argument of a constructor initialises its field (3.3), in the
braced list of the constructor as in its compound literal, so a
`slice_from_array` or a `slice_unchecked` that is one is a braced list
as well, nested in the payload. The initialiser of
`option(str) o = Some(slice_from_array(letters));` is, where `O` is
the name of the instance of `option(str)`,

```c
{ .tag = O_Some, .u.Some = { { (letters),
    sizeof(letters) / sizeof(__tc_arg__Kc)
    + 0 * sizeof(char[sizeof(__tc_arg__Kc) != 0 ? 1 : -1]) } } }
```

which both backends take at file scope under `-pedantic-errors`. With
the compound literal as the payload, GCC 16 refuses it there as it
does above.

An object that takes its type from its initialiser, as one declared
with `__auto_type` does, has no type for a braced list, which both
backends refuse there, and its initialiser is the compound literal.
Where such an object has static storage, GCC 16 under
`-pedantic-errors` refuses it, as it does in C.

A string literal that denotes a `str` (section 8 rule 6) is made the
same way, with no test and no temporary: the compound literal
`(struct C){ "lit", sizeof("lit") - 1 }`, where `struct C` is the
instance of `str`, or, under the condition above, the braced list
`{ "lit", sizeof("lit") - 1 }`, in place of the parentheses around
the literal too. The count is the size that the backend computes,
less its terminating NUL. It writes the literal a second time, as the
operand of a `sizeof`, where a literal declares nothing and is not
evaluated; the pragma lines between its pieces are left out of that
writing, which would repeat them.

The length is the quotient that the backend computes, and no number
that `typec` writes. `typec` holds the size of an array as an opaque
constant (13.3, P16), and the length of an array may rest on one, as in
`char buf[sizeof(struct header)]`. A length that the front end computed
beside the backend's would also be a second source for one fact: where
the front end's was the larger, the slice would be longer than its
array, and the test would pass an index beyond it. The price is that
the operand is written twice, and
rule 2 of section 8 refuses the operands whose second writing could be
told from the first:

- one of variable length array type, which the `sizeof` evaluates: a
  side effect in such an operand happens twice under both backends;
- one that declares a name whose scope reaches beyond it. A tag or an
  enumeration constant in the scope around it, and a label of the
  function in a statement expression, are all that an expression can
  declare so: every other declaration in one stands in a block or a
  parameter list of its own, where its scope ends (C11 6.2.1p4), and
  a label is the one name of function scope (6.2.1p3). Both backends
  refuse each as a redefinition, and take a label that the statement
  expression declares with `__label__`, which each writing has for
  itself. The check of the resolution property refuses the operand
  first, with the name of this kind of text (above);
- one that holds a `#pragma` line.

An operand of fixed length is evaluated once, whatever it holds. Where
it holds an increment or an assignment, as in
`slice_from_array(rows[n++])`, Apple Clang 21 reports the second
writing under `-Wunevaluated-expression`; GCC 16 does not.

The second writing is the operand of a `sizeof` and no variable length
array, so an index, a `slice_sub` or a conversion in it is written as
one that C does not evaluate (above): it holds no test, needs no
temporary and takes no number. The tests of the operand are those of
its first writing.

The second term of the length is the limit of rule 2 on the size of
an element and adds 0.
A quotient by the size of an element has no value where that size is
0, as it is in the GNU profile for a structure without members and
for an array of length 0. In a block both backends take the quotient
alone with a warning and no error: Apple Clang 21 then yields a length
that is no count of elements, and the code of GCC 16 ends the program
with a division fault. The size of a type is the backend's alone (13.3, P16).
What `typec` reads of a type shows a structure without members, and
not an array whose length is a layout constant that has the value 0,
as `int[sizeof(struct four) - 4]` where `struct four` holds one `int`.
So the backend makes the refusal, for every such type, from text that
lowering writes: the name of an array type of `char` whose length is 1,
or -1 where the element has the size 0. The length of an array type
is greater than 0 where it is a constant (C11 6.7.6.2p1), and this one
is a constant: rule 2 keeps a variably modified type out of the
operand, so the size of its element is one.
Both backends refuse an element of size 0 so, Apple Clang 21 with
"array size is negative" and GCC 16 with "size of unnamed array is
negative", and take every other `slice_from_array` without a
diagnostic under the options of the measurements above. The line
marker of the use (13.4) puts the report at the `slice_from_array`,
and where the length is evaluated each backend warns of the division
by zero beside it.

A type name declares nothing and stands in a `sizeof` wherever an
expression stands, so the term sets no limit on the place of a
`slice_from_array`. Both results above hold in a block, at file
scope, in a return type, in the size of a member and in a parameter
list: in the head of a function, in the declarator of a pointer to a
function and in the type name of a cast to one.

A static assertion in the term's place would give the refusal a
message of `typec`. It is set aside. C11 takes one among the members
of a structure (6.7.2.1p1) and nowhere else in an expression, and a
structure that is declared in a parameter list is in scope in that
list alone (C11 6.2.1p4): GCC 16 reports one there without an option
("anonymous struct declared inside parameter list will not be visible
outside of this definition or declaration"). That form needs a rule
that keeps `slice_from_array` out of every parameter list, with a
refusal of its own, for the wording of a report that only a type of
the GNU profile can draw.

The value of a `slice_from_array` is a compound literal, so
`slice_from_array(a).len` is no integer constant expression, and an
array of that size is a variable length array, as it is for a
compound literal that the program writes there: `int x[(int){ 8 }]`.
GCC 16 refuses such an array at file scope and takes it in a block
and as a parameter; under `-Wall` it reports a function that is
declared twice with such a parameter (`-Wvla-parameter`), since it
takes the two literals for two bounds. Apple Clang 21 takes it in a
block and as a parameter in the ISO form of C. In the GNU form there,
and at file scope in both forms, it computes the size as a constant
and says so in a warning that it has on without an option
(`-Wgnu-folding-constant`), an error under `-pedantic-errors`; it
does the same for the literal of C. `sizeof(a) / sizeof(a[0])` is the
constant, in Type-C as in C, and draws none of this.

The identifiers that the compiler invents begin with `__tc_`, which
keeps them from every name in the text (2.3). One that is declared at
file scope or defined as a macro, and is one of many of its kind,
continues with a word for its kind, then `__`, then what tells it from
the others of its kind:

- the typedef of a type argument (10.3): `arg`, then the encoding of
  the type, as in `__tc_arg__Pi` for `int *`;
- the include guard of an emitted header itself (9.3): `module`, then
  the module of its interface, as in `__tc_module__ir_5fexpr` for
  `ir_expr.tci`. The *module* of a file is the last component of its
  path without a `.tci` suffix, and it is written with an ASCII letter
  or a digit standing for itself and every other byte as `_` and its
  two hexadecimal digits in lower case;
- the include guard of the definition of an instance in an emitted
  header (9.3): `header`, then the module of the file that defines the
  instance's generic, then `__`, then the instance name, as in
  `__tc_header__vec__vector__i` for `vector(int)` where `vec.tci`
  defines `vector`. No file defines a generic of the universe (3.6),
  and its module is written as nothing: `__tc_header____option__i` for
  `option(int)`;
- the two structures of the packing probe of an emitted header (10.3):
  `pack_probe_1` or `pack_probe_2`, then the module of the header, as
  in `__tc_pack_probe_1__ir_5fexpr`.

No kind word holds a `__` or ends in `_`, so the first `__` after the
prefix ends the word, and names of different kinds differ: the guard of
a header never meets the guard of an instance. Within a kind, an
encoding is one type, an instance name one instance (10.3), and the
written form of a module that last component alone, since every `_` in
it begins an escape. The written form holds no `__` and
does not end in `_` either, so in the guard of an instance the first
`__` after the kind word's ends the module, and the guard is one module
and one instance. A generic of the universe shares its guards with no
other: no generic of a file has a universe name (3.6), so none has its
instance names.

No other invented name holds a `__` after the prefix. `__tc_ret`, the
return type of a function, is declared once in the outermost block of
its function, and `__tc_r`, the temporary of a `return`, in a block of
its own; neither needs more than the prefix. `__tc_t0`, `__tc_t1` and
so on are the temporaries of the `try` expressions of a function,
`__tc_v0` and so on those of the values that a prelude converts for a
braced list, each with the number of its `try`, and
`__tc_c0` and so on those of the first operands that a prelude
evaluates (above); they share its blocks and take the number that
tells them apart. `__tc_s0`,
`__tc_i0`, `__tc_lo0` and `__tc_hi0` and so on are the temporaries of
the test and of the conversion of a slice (above), declared where
`__tc_ret` is, with the number of their test or conversion. `__tc_bits`
and `__tc_enum_probe` are the probes of the assertions that end a unit
(13.4), and `__tc_pack_probe_1` and `__tc_pack_probe_2` the two
structures of the packing probe that ends one (10.3), one of each.

### 13.6 Diagnostics and debugging

- A diagnostic is written as GCC and Clang write an error,
  `file:line: error: text`, and carries the source line and a stable
  name. Stable names let tests, editors and users refer to a diagnostic
  without matching its text.
- A stable name is lowercase words of letters and digits joined by
  hyphens, as GCC and Clang name the options of their warnings. It names
  a rule of this design that the text breaks, a limit of the GNU profile
  (13.3) that C text or Type-C text meets, or a construct that a later
  work package implements, and ends the diagnostic in brackets, as GCC
  and Clang end a warning with its option:
  `file:line: error: the end of the match arm can be reached
  [match-arm-end]`. The message cites no clause of this design. Each
  rule's name is written beside it in the one table of rules, which
  generates the catalogue of diagnostics: one entry for each name, with
  the rule and the clause that states it. A name is never renamed, and
  the name of a removed rule is never given to another.
- A message about no place in the source, as one about the command line
  or a file that `typec` cannot read or write, begins with `typec:`, as
  a C compiler's begins with its own name.
- A refusal of C text that states no rule of this design carries no
  name: C11, the GCC manual or the backend's own diagnostic names what
  is wrong. A translation limit of `typec` (C11 5.2.4.1) is such a
  refusal: it bounds what this compiler reads or writes and says
  nothing of whether the source is valid, and its message names it
  as a limit of `typec`. The parser's bound on the nesting of
  brackets is one, and 3.5 rule 7 states four: the instance budget,
  in bytes of what the front end reads for a unit's instances; the
  output limit, in bytes of all the C text that `typec` writes for a
  unit but the fixed static assertions that end it, charged where each
  piece and edit of it is made, so that no construct's text escapes
  it, and of the copies of its deferred statements, which the front
  end counts first; the bound of 4096 bytes on the encodings of the
  arguments of one instance; and the bound of 255 bytes on the name
  of a type declaration or a generic function. 4.7 rule 10 states two
  more, the bounds on the steps of selection of a match and on the
  depth of its selection tree. The limit on
  nested instantiation is none: 3.5 rule 7 states it as a rule of
  Type-C, so it carries a name. A limit of the GNU profile, a construct
  outside the profile or one that needs what `typec` does not compute,
  is a refusal of the accepted dialect by this design rather than by C,
  so it carries a name. C text that breaks a rule of this design is
  refused with the rule's name, as Type-C text is: a `defer` statement
  that C text writes with `_Defer` is refused under rules 8, 9, 11 and
  12 of section 6, and a `return` in its scope under the refusals of
  the form (13.5), each with the name it has in Type-C text. Every
  refusal of the front end is either named or a refusal of C text that
  states no rule of this design, and only the function that appends a
  rule's name makes a named one.
- Debuggers step through the original lines. Bindings are C locals under
  their source names. A variant value appears as its lowered struct, with
  the tag printed by name. Generic instances appear under their instance
  names.
- `--emit-c` shows what any construct became. Its output is the file
  that the compile step reads, preprocessed output with GNU line markers
  (13.4): compiling it by hand takes `-x cpp-output` and the options
  that the compile step adds to the user's (2.4, 13.2).

### 13.7 Implementation

`typec` is written in OCaml. The work is tree construction and
transformation, which variants and exhaustive matching serve directly, and
a tool that reads untrusted source should be memory-safe. The consequence
is that the compiler is not written in Type-C, so the pilots that judge
the language are other programs (see the plan).

The compiler never executes code from its input. Input-dependent recursion
and instantiation are bounded, and exceeding a bound is a diagnostic, not
a crash.

## 14. Guarantees

| Property | Covers | Depends on |
| --- | --- | --- |
| Plain C keeps its meaning and ABI | Every translation unit in the supported dialect, but for the one exception of 2.2 | Emission by token span (13.4) |
| A variant value has a valid tag and the payload of that tag | Values made by constructors, the zero value, and copies of either | No code writing the bytes of the object behind its type (C code, casts, unions, `memcpy`); no read of an uninitialised automatic object |
| A `match` selects an arm for every value of its scrutinee's type | Every `match` | An invalid tag traps where selection reads it (4.5); a pointer that a `*` sub-pattern follows points to an object of its type (4.7 rule 5) |
| Distinct types do not mix without a cast | Type-C code | C code sees the underlying type |
| Only the owner creates values of a private type, other than the zero value | Type-C code that does not write bytes behind the type | Not a security boundary (9.2) |
| A generic function is valid for every instance | Every instance that compiles: a chain past the nesting limit (3.5 rule 7), a declaration that changes what the definition names (3.5 rule 8), a declaration of a name that a generic claims for its instances (10.3), a placement that 10.3 or 7.3 rule 2 or 4 refuses and a translation limit of `typec` (13.6) are compile errors | Nothing |
| The zero initialiser of an object whose type mentions a type parameter gives every scalar in it the value zero and zeroes the padding of each structure, the bits of each unnamed bit-field and the rest of each union in it | Every instance of a generic function (7.1 rule 3). Not covered: the bytes inside a scalar that hold none of its value, as 6 of the 16 of the `long double` of x86-64 and 12 of the 32 of its complex type, which are unspecified as in C. Text that hands the representation on clears the object with `memset` first | The backend gives `{}` the meaning of C23 in the selected dialect and zeroes an unnamed bit-field, which C leaves indeterminate (13.5, provisional). A copy of the object is C's, which leaves the padding of a copy unspecified (C11 6.2.6.1p6) |
| Text that lowering moves means what it means at its own place, and the text around it what it means without the move | Every kind of moved text that 13.5 names. Attribute arguments and `#pragma` lines are covered as far as 13.5 says: for the identifiers that denote something at the text's own place, and where a Type-C name hides a C entity | Pragma state is that of the place where the text is written. A type instance is kept from `#pragma pack` alone: under another pragma that changes a layout (`#pragma ms_struct`, `#pragma scalar_storage_order`, `#pragma clang attribute`), a type instance first used inside its region in one translation unit and outside it in another has one name and two layouts. A function instance has the state of its generic's definition, but for its packing, which is the command line's, and its diagnostics, which are those of the place where it is written (13.5), since its first use is an error where a line that sets state stands between the two (7.3 rule 4). The test of a slice is written at each use, in no function of its own, and has the state of that use (section 8 rule 9, 13.5) |
| The C text that `typec` writes for a unit is at most its output limit, and what the front end reads for its instances at most the instance budget | Every unit and every byte of its C text but the fixed static assertions that end it, instances, copies, temporaries and line markers alike: emission charges each piece and edit as it makes it, with no list of constructs, and the front end counts the copies of deferred statements against the output limit as it finds their exits (3.5 rule 7) | Nothing; a unit past either bound is refused and nothing is written. The work of the parser and of the front end outside its readings for instances and its count of copies is not counted |
| A C client and a Type-C unit see one layout of what an emitted header declares | Headers written by `--emit-c-header` (9.3) | The client compiles the header as C11 or later, for the target and with the layout options it was generated for, and includes it outside the region of every `#pragma pack` and of every other pragma that changes a layout. `typec` does not see a client's compile and cannot check this |
| A `result` is not discarded silently | Expression statements, left operands of `,`, clauses of `for`, `return` in a `void` function, branches of a `void` conditional | Explicit casts to `void`; types that `typec` knows (13.3) |
| A slice access stays in bounds | `s[i]` and `slice_sub`, wherever C evaluates one, whatever `typec` took C to do there (13.5) | The slice describes live storage of its length. No full expression that holds an index, a `slice_sub` or a conversion of a slice is resumed, by a call that returns a second time (`setjmp`, `sigsetjmp`, `getcontext`, `vfork`, `__builtin_setjmp`, a function declared with the GNU attribute `returns_twice`), after the same call of its function has begun to evaluate it again: the values that it held are then indeterminate, as C11 7.13.2.1p3 has the objects of a function after a `longjmp`, and the test does not protect the access (section 8 rule 10). Measured: under GCC 16 at `-O2` such an index passes its test and points beyond the end of a slice whose array is live, and under both backends a call stores through the address of an element that it held across such a call in another argument, into an array that is freed, as C does with `&a[i]` there. `typec` does not refuse such an expression (13.5) |
| Tier 1 of checked mode (11.2) | Checked functions | Live pointers, correct trusted contracts and `unsafe` blocks |

Not guaranteed anywhere: object lifetimes, freedom from data races,
defined arithmetic, and anything about C code. Type-C does not replace a
memory-safe language, and none of the properties above holds against an
author who sets out to defeat it. The checked claims are backed by negative
tests, sanitizers and fuzzing, as the plan describes.

## 15. Provisional decisions

Each open row is a choice that this document makes without evidence: it
names what settles the choice and the default that stands if nothing does.
A row whose last column reads **Decided** is settled: its third column
holds the evidence, and the rules it names carry no mark. The stage
numbers refer to the implementation plan. Pilot B is the rewrite of
tomlc99, a TOML parser, in Type-C. It lives in a repository of its own
(plan, package 2.6), which has no remote: it is at
`/Volumes/Optaine/type-c-pilot-b` on the owner's machine, and where it
is hosted is open (plan, "Open logistics"). The pilot's counts are in
`RECORD.md` on the branch `port` of that repository, at commit 06d4eb8,
with the scripts that reproduce them (`make size-split`,
`tools/bench/run.sh`).

| | Decision | Settled by | Default |
| --- | --- | --- | --- |
| P7 | A `void` type argument removes the field (3.5) | Pilot B: one `void` argument, `result(void, reported)`, the return type of 11 functions; no refusal and no rewrite | **Decided:** as specified |
| P8 | No `try` stands in a holder that holds or directly follows a pragma line (5.1 rule 3) | The clause is accepted unmeasured, as tomlc99, the source of Pilot B, holds no pragma: it is a refusal, so relaxing it breaks no program that it accepts. Stage 3, package 3.12: how often it refuses in the container library and the corpus, read from the rule's name. Pilot B's 4 rewrites, all of `T *p = try f(sizeof(*p));`, came from another clause of 5.1 rule 3, which is not provisional: a hoisted operand names nothing that its holder declares before it | **Decided:** as specified |
| P9 | `defer` is lowered by repeating the cleanup at each exit, which needs rules 8, 9 and 12 of section 6 and the refusal of a `defer` statement in a deferred statement (rule 11), and a `return` in the scope of a `defer` statement holds its value in a temporary whose type `__typeof__` takes from a call of the function (13.5) | Pilot B: rules 8, 9, 11 and 12 of section 6 and the form of a `return` (13.5) refused nothing, no diagnostic of the list of 13.5 was lost, and no diagnostic that the form adds broke a build. The 30 copies of the 9 deferred statements cost 1.1% of the text under Apple Clang 21 and 2.0% under GCC 16 more than the cleanups of a hand-written `goto cleanup` version, each cost measured by removing the cleanups from its source. The limit of the evidence: every deferred statement is a single call | **Decided:** repetition, and the temporary as specified |
| P10 | The instance naming scheme (10.3) | The injectivity tests of the encoding, on types drawn from a seeded generator (`test/unit/test_naming.ml`); in Pilot B lldb shows an instance as `result__Pc8reported`, with its tags by name, and hides no value. gdb is untried | **Decided:** as specified |
| P11 | Type arguments are deduced left to right, and later arguments convert (7.2) | Stage 3 container library: conversions that surprised | As specified |
| P12 | Instances are per translation unit (7.3) | Stage 3: code size of the library and pilot | Per unit |
| P13 | A string literal becomes `str` by target type (8) | Stage 3 pilot | As specified |
| P14 | Slice checks cannot be turned off (8) | Stage 3 benchmarks | Always on |
| P15 | The backend preprocesses (13.2) | Stage 4 review of diagnostic quality | Backend preprocesses |
| P16 | The front end computes no aggregate layout (13.3) | Stage 0 corpus: constructs that need a layout value | No layout |
| P17 | The tier 1 rule set (11.2) | Stage 5 prototype on pilot code | Tier 1 is not released until the rules pass |
| P18 | Lifetimes by homogeneous regions (11.3) | Stage 6: a formal model, then a prototype | No lifetime tier |
| P19 | `typec` has a C front end of its own (13.1) | Stage 0 gate and its change-of-course condition | Own front end |
| P20 | `__builtin_va_list` is an opaque type (13.3) | Typing `__builtin_va_arg` and bodies (0.9b, 0.7b): a case that needs the representation | Opaque |
| P21 | A type that the front end does not compute is unknown, an error only where it is needed (13.3) | Typing bodies (0.9b) and the corpus: points that need an unknown type's properties, the declarations that the resolution check of 13.5 refuses for one among them, read from the one code that such a refusal carries for every kind of moved text | Unknown types stay |
| P22 | `typec`'s own failures exit with 80, 81 and 82, which no backend uses (13.2) | Corpus runs with GCC and Clang: a backend failure that exits with one of them | As specified |
| P23 | A generic's definition is written as its tokens into each instance, which needs rule 8 of 3.5 (13.5) | Stage 2 pilot: how often rule 8 rejects a type definition, read from the code of the definition of a generic (13.5). Stage 3: how often it rejects code in the container library (package 3.5) and in generic function bodies, where most of its cases arise | As specified |
| P24 | A block literal is C text only (13.3) | Stage 2, Pilot B: how often a block literal is refused. Type-C code on macOS: how often a block-taking API has no function-pointer form | C text only |
| P25 | A generic whose definition holds a pragma is an error (10.3) | Stage 2, Pilot B, or the corpus: how many generic definitions hold a `#pragma` line or a `_Pragma` operator | The refusal stays |
| P26 | A type argument holds no `__typeof__` of an expression (3.5 rule 2) | Stage 2, Pilot B, or the corpus: how many type arguments it refuses | The refusal stays |
| P27 | A function instance is compiled under the pragma state of its generic's definition: a `#pragma` line that sets state between the definition and the place where the instance is written makes its first use an error (7.3 rule 4, 13.5) | Stage 3, packages 3.5 and 3.6: how often the rule refuses a use in the container library and the pilot, by the pragma of the cited line, read from the rule's code. If refusals are common: regions that are closed before the place of writing are passed over (13.5) | The refusal stays |
| P28 | The test of a slice is an expression at each use, a comma expression of ISO C over temporaries of the function, and no function that the uses share, which needs rule 9 of section 8 (8, 13.5) | Stage 3, package 3.6: the cost of the tests in the container library and the pilot, without optimisation as well as with it; how often rule 9 of section 8 refuses an index or a `slice_sub`, read from its name; how many of them stand where C does not evaluate them; and how many tests hold a call or a statement expression in an operand after the first, with what volatile temporaries for those tests alone cost there, the form that the owner decided against (section 8 rule 10). A hand-written sample gives the same instructions at `-O2` and the same trap as a shared function under Apple Clang 21 and GCC 16, and 29% and 23% more code at `-O0` (13.5) | The expression stays, and its temporaries are not volatile |
| P29 | The conditional operator takes no value of a type parameter as its second or third operand (7.1 rule 3) | Stage 3, package 3.5: how often the container library wants the operator over such values, read from the code of the refusal. If that is common: the operator is allowed where its value is converted to the type parameter at once | The refusal stays |
| P30 | The instance budget of a translation unit is 16777216 bytes of what the front end reads for its instances, each token at least 32; the output limit is 33554432 bytes and 256 for each byte of the preprocessed unit, on all the C text that `typec` writes for it, each piece at least 32, and on the front end's count of the copies of its deferred statements, each token at least 32 and each copy 64 more; the encodings of the arguments of one instance hold at most 4096 bytes; and the name of a type declaration or a generic function at most 255 (3.5 rule 7) | Stage 3, package 3.6: the bytes that each unit of the container library and of the pilot counts for its instances in the front end, the bytes that lowering charges for each of them and their ratio to the source, the longest encodings of one instance in them, and their longest name of a type declaration or generic function. The budget and the base of the limit are at least four times the largest count and charge, the factor at least four times the largest ratio and each bound at least four times the longest; a larger budget or limit costs in proportion, and a longer name in proportion to the constructors and uses that hold it (3.5 rule 7) | 16777216 bytes; 33554432 bytes and 256 for each byte; 4096 bytes; 255 bytes |
| P31 | Selection sets a local that a second `switch` reads (13.5) | Stage 3, package 3.10: size and speed against hand-written nested `switch` statements, on both backends at `-O0` and at `-O2`. If the local costs at `-O2`: the leaves reach the arms by `goto` | The local stays |
| P32 | Building the selection tree of a match or a test takes at most 4194304 steps, and the tree is at most 127 nodes deep (4.7 rule 10) | Stage 3, package 3.10: the most steps and the deepest tree of one match in the container library, the pilot and the tests. The step bound is at least sixteen times the most, and the depth bound at least the deepest; with GCC and Clang, a tree of the depth bound lowered and compiled at `-O0` and `-O2` | 4194304 steps; 127 nodes |
| P33 | The `try` expressions of a holder are evaluated before the rest of it, in the order of the source, and not in the order of reading; the prelude that does so is ISO C and costs what the same code written by hand costs (5.1 rule 3, 13.5) | Stage 3, package 3.12: each holder in the container library, the pilot and the README that holds, before a `try`, an operand with a side effect that C leaves unsequenced with it, found by reading the holders, and whether the order of reading was meant there; size and speed of the preludes against the same code with each `try` in a declaration of its own, on both backends at `-O0` and at `-O2`. If such holders are common and mean the order of reading: the operands before a `try` are hoisted with it, with the forms and refusals that the rationale of 5.1 lists | The order stays |
| P34 | No `try` stands in the condition or in a clause of a loop (5.1 rule 3) | Stage 3, package 3.12: how often `try-loop` refuses in the container library, the pilot and the README, read from the rule's name, and what each loop became. If loops that test a fallible call are common: the condition of a `while` and of a `for` is lowered as a test and a `break` that begin the body | The refusal stays |
| P35 | In a braced list an initialiser that holds a `try` is itself a `try` expression (5.1 rule 3) | Stage 3, package 3.12: how often `try-list` refuses in the container library, the pilot and the README, read from the rule's name, and what each refused initialiser holds beside its `try`. If most hold a conversion of the value and nothing else: the design names the operators over a `try` that have no effect, and an initialiser may hold them | The refusal stays |

## 16. Non-goals

Garbage collection, exceptions and unwinding, classes and inheritance,
operator and function overloading, traits and implementations, C++
templates and specialisation, implicit conversion machinery, a module
system or package manager, a runtime library, an async runtime, a borrow
checker for arbitrary C, a native code generator, and a stable
serialisation format for variants.

## 17. References

1. [Cyclone manual](https://www.cs.cornell.edu/Projects/cyclone/online-manual/):
   datatypes, pattern matching, regions and polymorphism in a C dialect.
2. [Cforall](https://github.com/cforall/cforall) and its
   [papers](https://cforall.uwaterloo.ca/papers): checked polymorphism in
   C by translation to C.
3. [Cake](https://cakecc.org/manual.html): a C front end that emits C.
4. [Checked C](https://www.checkedc.org/) and Clang's
   [bounds-safety](https://clang.llvm.org/docs/BoundsSafety/index.html):
   bounds checking for C inside a C compiler.
5. [ISO/DIS TS 25755, N3734](https://www.open-std.org/JTC1/SC22/WG14/www/docs/n3734.pdf):
   the `defer` statement.
6. [Java Language Specification, 14.22](https://docs.oracle.com/javase/specs/jls/se21/html/jls-14.html#jls-14.22):
   reachability defined syntactically.
7. [Go specification, blocks](https://go.dev/ref/spec#Blocks): the universe
   block of shadowable predeclared names.
8. [Rust RFC 1444](https://rust-lang.github.io/rfcs/1444-union.html):
   `union` as a contextual keyword.
9. [Maranget, Warnings for pattern matching](http://moscova.inria.fr/~maranget/papers/warn/):
   exhaustiveness for nested patterns.
10. [GCC preprocessor output](https://gcc.gnu.org/onlinedocs/cpp/Preprocessor-Output.html):
    line markers.
11. [OCaml private types](https://ocaml.org/manual/5.2/privatetypes.html):
    the model for `private`.

## Appendix A. Grammar

Additions to the C11 grammar. `?` marks an optional part, `*` zero or more
and `+` one or more. Words in quotes are recognised as described in 2.3.

```text
external-declaration:  ... | type-declaration | generic-function
block-item:            ... | type-declaration | defer-statement

type-declaration:      "type" identifier type-parameters? ";"
                     | "type" identifier type-parameters? "=" definition ";"
type-parameters:       "(" identifier ("," identifier)* ")"
definition:            "private"? ("|" constructor)+
                     | "private"? "distinct" type-name
                     | type-name
constructor:           identifier ("(" field ("," field)* ")")?
field:                 specifier-qualifier-list declarator

type-specifier:        ... | generic-type-name type-arguments
type-arguments:        "(" type-name ("," type-name)* ")"

generic-function:      "generic" type-parameters generic-head
                       compound-statement
                     | "generic" type-parameters generic-head ";"
generic-head:          declaration-specifiers declarator

primary-expression:    ... | variant-type "." identifier
                           | generic-function-name type-arguments
                           | slice-operation
variant-type:          typedef-name | generic-type-name type-arguments
unary-expression:      ... | "try" cast-expression

statement:             ... | match-statement | unsafe-block
selection-statement:   ... | "if" "(" pattern-test ")" statement
                           | "if" "(" pattern-test ")" statement
                             "else" statement
iteration-statement:   ... | "while" "(" pattern-test ")" statement
pattern-test:          "case" pattern "=" expression
match-statement:       "match" "(" expression ")" "{" arm+ "}"
arm:                   arm-label+ block-item+
arm-label:             "case" pattern ":" | "default" ":"
pattern:               identifier ("(" sub-pattern ("," sub-pattern)* ")")?
sub-pattern:           "_" | pattern | "*" pattern
                     | variant-type identifier
defer-statement:       ("defer" | "_Defer") statement
slice-operation:       "slice_from_array" "(" assignment-expression ")"
                     | "slice_sub" "(" assignment-expression
                       "," assignment-expression "," assignment-expression ")"
                     | "slice_unchecked" "(" assignment-expression
                       "," assignment-expression ")"
unsafe-block:          "unsafe" compound-statement
```

A type declaration with type parameters is an external declaration only.
A generic head declares one function with a prototype: its declarator
is a function declarator with a parameter type list, `static` is the
only storage-class specifier among its specifiers, and neither an
initialiser, a second declarator nor a list of parameter declarations
follows it (7.1 rule 6).
A `defer` statement is a block item and not a statement, so it is not the
substatement of another statement (section 6 rule 11). The grammar
derives a `try` wherever a unary expression stands, and 5.1 rule 3
says which of those places hold one.
A sub-pattern that is an identifier alone is a constructor pattern or
a binding by the type of its position, and the identifier that ends a
typed binding tells it from a pattern (4.7 rules 2 to 4).
An unqualified constructor is an ordinary identifier or call in the
grammar; 3.3 decides its meaning. Slice indexing uses C's subscript
syntax. The words of a slice operation are universe names, which a
declaration may hide (2.3); a hidden one is an ordinary identifier.
