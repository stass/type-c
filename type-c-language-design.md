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

**How to read the status of a rule.** Nothing here is implemented. A rule
stated without qualification is the design. A rule marked *Provisional (Pn)*
is a choice that needs evidence; section 15 lists each one with what settles
it and the default that stands if nothing does. Section 12 holds features
that are deliberately outside the core.

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
   of `match`, the bounds check of slice indexing, the cleanup that `defer`
   schedules, and the checks of checked mode.
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
`size_t len(str);`, where no other reading exists.

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
passes `-std=gnu11` to the C compiler unless the command line selects C11
or C17 in ISO or GNU form. Other dialects are not accepted. The GNU
keywords spelled without underscores, `asm` and `typeof`, are keywords in
the GNU form and identifiers in the ISO form, as for the C compiler;
`-fasm` and `-fno-asm` override the choice. The `__` spellings are
keywords in both.

Rationale. Headers select constructs by `__STDC_VERSION__`; pinning the
dialect bounds what the front end must parse. Everything Type-C lowers to
compiles in the dialect the command line selects: ISO C11 plus only GNU
forms that GCC and Clang accept in every dialect, also under
`-pedantic-errors`. Two are used: `__typeof__`, which C23 standardises
as `typeof` and which names a type where no name for it is sure to be
visible, the type of a field for a match binding and the return type of
a function for the temporary of a `return` (13.5); and `__builtin_trap`
(10.5). Lowered code also writes the three packing pragmas of the
bracket of 10.3 and, in its probe, `#pragma pack(1)` and `#pragma
pack(2)`. C11 6.10.6 leaves a pragma to the implementation; GCC 14.2
and 16.2, Clang 20 and Apple Clang 21 take the three of the bracket
without a diagnostic in the ISO and the GNU form of C11, also under
`-pedantic-errors`. The two of the probe were measured so with GCC
16.2, Apple Clang 21 and Clang 22 and 23 alone. A backend that ignores
the pragmas has no packing to keep out. The one exception is GCC under
`-fpack-struct` without a value, which ignores them and warns of each;
the driver refuses that option (13.2).
The emitted file is preprocessed output, with line markers, and is
compiled as such (`-x cpp-output`). So the output dialect is the input
dialect and nothing newer. Its line markers are the toolchain's text, not
the user's, and are no part of the dialect: they take the GNU form
(13.4), which Clang 20 calls an extension under `-pedantic` even in
preprocessed input (Clang 21 and 22 do not). The compile step therefore
gets `-Wno-gnu-line-marker`, after the user's options so that `-Wgnu`
does not turn it back on. GCC ignores the option, naming it in a note
only when it reports another diagnostic. A line marker that the
user writes is still diagnosed, when the backend preprocesses the source
under the user's options.

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
   constructor with every field zero. Static objects without an initialiser,
   `calloc`, `memset` and the initialiser `{0}` therefore all yield a valid
   value. `{0}` and the empty initialiser `{}` (GNU C, C23) are the only
   braced initialisers a variant accepts, and `{}` is its zero value
   wherever `{0}` is. `{0}` zeroes any object, so it also zeroes a
   structure whose first member is a variant: its `0` writes the
   variant's zero value through elided braces, which no other
   initialiser may do. Put the constructor that makes a sensible default
   first (`None`, `Empty`).
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
  that denotes a variant. This works in every expression.
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
constructor needs the qualified form. String literals use the same
mechanism to become `str` (section 8).

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
   declared with one. An instance name is built after typedef expansion
   and encodes no attribute (10.3), so
   `vector(int)` and `vector(wide)`, where `wide` is a typedef of `int`
   with the GNU attribute `aligned(16)`, would have one name and two
   layouts in one translation unit, as another attribute would give one
   name two aliasing behaviours. The depth is that of the names that
   spell the argument: a typedef name that the argument writes, one
   that the declaration of such a name writes, and so on down to the
   type specifiers, under every pointer, array, function and qualifier
   on the way. A typedef name is declared with an attribute where one
   stands among the specifiers of its declaration, in its declarator or
   after it. The text inside the specifier of a struct, union or enum
   is outside that depth. An attribute there, after the keyword or
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
   bit-field or in `_Alignas`, and no constant expression in it depends on
   one. A struct or union specifier with a body in it has no tag, and
   stands only where the definition of an instance holds it (10.3): as
   the whole definition of an alias, in a field of a variant, where a
   variant that is not generic may have one too, or inside either.
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
6. *Provisional (P7).* `void` may be an argument. A variant field whose type
   becomes `void` does not exist: its constructor takes no argument for it
   and a pattern has no sub-pattern for it. This makes `result(void, E)` the
   type of a fallible function that produces no value.
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
   already. The needs of a definition are visited in the order of its
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
   so the first definition breaks the cycle. The error carries a code
   (13.6): the limit is a rule of the language, which says whether a
   source is valid, and not a translation limit of `typec`.
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
   4.6(2)). A sub-pattern is an identifier, which is a *binding*, or `_`,
   which matches without binding.
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
7. The scrutinee is evaluated once. Its tag is read once, the bound fields
   of the selected constructor are copied, and then the arm runs. Assigning
   to the scrutinee inside the arm does not change the bindings.

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
   constructor named twice.
2. There is at most one `default`, and it must cover at least one
   constructor.
3. A `default` hides constructors added later, and nothing warns about
   it. In Pilot A written with the single-pattern test (4.6), 49 of 60
   matches keep a `default`, most of them matches of several cases whose
   `default` means "every other constructor"; a warning would flag that
   correct code far more often than a forgotten constructor.
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
does not evaluate conditions other than constants.

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

The GNU address of a label, `&&L`, has two readings, one for each
question that these rules ask. The rules that ask what may reach a
label, 4.3(3) and rule 5 of section 6, read it as a jump to `L` from
every point of the function, because a computed `goto *e` at any point
may be given that address. Rule 4 of section 6 asks what leaves a
deferred statement and counts the jumps written in it. There `&&L` is no
jump and leaves nothing: the computed `goto *e` that is given the
address is the jump, and the rule judges it where it stands. Rule 10 of
section 6 asks neither question. It refuses every computed `goto *e` and
`asm goto` in the scope of a `defer` statement, whatever its targets.

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
*fails* where it would select another constructor, and traps where the
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
   test then binds nothing, as if each field were `_`.
3. Each time the condition is evaluated, once for an `if` and before
   every iteration of a `while`, the operand is evaluated once and its
   tag is read once. On success the bound fields are copied and then `S`
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
   Anything else is an error; there is no implicit conversion between
   error types.
2. `try` evaluates its operand once and abbreviates a `match` on the
   value (section 4). In the arm of `Err(x)` the function returns
   `Err(x)` exactly as a `return` statement would, running the deferred
   statements that are active (section 6). The error `x` is read before
   they run: it is held in the temporary that takes the operand's value,
   and the `Err(x)` that the function returns is built from that
   temporary after they have run. No deferred statement can name the
   temporary, so the error path needs no temporary of a `return` (13.5).
   From the arm of `Ok(v)` the `try` expression has the value `v` and
   the type `T`; when `T` is `void` it is a void expression. As in every
   match (4.5), a value whose tag is no constructor's, here neither `Ok`
   nor `Err`, traps (10.5) and does not take the error path.
3. *Provisional (P8).* A `try` expression stands in one of three positions
   and nowhere else:
   * a whole expression statement, `try e;`;
   * the whole right operand of a simple assignment that is a whole
     expression statement, `lvalue = try e;`. The operand of `try` is
     evaluated before the left operand. The assignment is not compound
     (`x += try f();`) and not chained (`a = b = try f();`);
   * the whole initialiser of the one declarator of a declaration that
     is a block item and declares an automatic object. A declaration
     that holds a `try` has exactly one declarator, and the type it
     declares is not variably modified: C evaluates the size expressions
     of a declaration before its initialiser (C11 6.7.6p3, 6.8p3), and
     lowering would evaluate the operand first.

   In each position the operand is moved text: lowering writes it before
   the statement or declaration that holds the `try`, and the resolution
   property of 13.5 holds for it. Two consequences are particular to
   `try`. The operand names nothing that the statement or declaration
   that holds the `try` declares: a declaration by its declarator or in
   its specifiers, an assignment in its left operand. C puts a
   declarator in scope in its own initialiser (C11 6.2.1p7), so in `int
   n = 0; { size_t n = try rd(&n); }` the source names the inner `n` and
   the lowered code would name the outer one. In `a[sizeof(enum { K = 5
   })] = try g(K);` the source names the `K` of the left operand, and
   the lowered code writes the operand where no `K` is declared yet, or
   an outer one is. And the operand declares no name that is in scope
   after it, which is the third clause of the property on the operand.
   In `a[K] = try g(sizeof(enum { K = 5 }));` the source reads the `K`
   of `a[K]` where the operand has not yet declared one, and the lowered
   code would read the operand's, and store to `a[5]`.

   A declaration in the first clause of a `for` is not a block item. The
   operand of `return`, the scrutinee of a `match` and the operand of a
   single-pattern test (4.6) are not among the positions. No `try` stands
   inside a statement expression, whatever its position there: it would
   return from inside the expression around it, where C does not say
   which of the other operands have been evaluated. None stands inside a
   block literal either: a block literal holds no Type-C text (13.3,
   P24), and `try` is a word in Type-C text alone (2.3). And none
   stands in a statement or declaration that has a pragma directly
   before it or before any of its labels, for the reason that 13.5
   gives with the rule.
4. `try` cannot appear in a deferred statement.

Rationale for the positions. C leaves the evaluation order of operands and
arguments unspecified and sequences `&&`, `||`, `?:` and `,`. Hoisting a
`try` out of an arbitrary expression must respect both, and C11 has no
expression that can hold statements. The three positions cover the common
case of one fallible call per statement and lower to straight-line C.
A `for` clause, a scrutinee and the operand of a test could be lowered
as well; they are left out to keep the positions few, and a declaration
before the statement holds the `try`. General placement is in section 12.

### 5.2 Results are not dropped

An expression of a `result` type whose value is discarded is an error: as
an expression statement, as the left operand of `,`, and as the first or
third clause of `for`. Handle the value with `try` or `match`, store it, or
discard it on purpose with a cast to `void`.

### 5.3 Other error conventions

An error of one type becomes an error of another through an ordinary
function and a `match`:

```c
match (open_file(path)) {
case Ok(opened):
    f = opened;
    break;
case Err(e):
    return Err(io_to_app_error(e));
}
```

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
   the error path of `try`. When several scopes are left together, their
   statements run in the reverse order of the `defer` statements. The
   body of a block literal is a function of its own (4.4): a `return` in
   it leaves no scope around the literal. No `defer` statement stands
   among the tokens that typing does not read (unread text, 13.5), in
   any text: the statement would reach the backend as written. One
   scan passes over every such token, whatever holds it: the body of a
   block literal, a function body that is passed through unread
   (13.3), an attribute argument, or anything else that typing passes
   over. It refuses `_Defer` in every such token, and the word `defer`
   in an attribute argument of Type-C text, where no declaration hides
   the word (2.3). The rule therefore names no kind of unread text and
   can miss none. The word begins a statement in Type-C text alone; of
   its unread tokens only an attribute argument can hold a statement,
   since a `#pragma` line holds none, and a block literal and a
   function body that is passed through unread hold no token of Type-C
   text (13.3).
   `S` is moved text, so it holds no block literal (13.5).
2. `S` runs at the exit and sees the values variables have then.
3. The operand of `return` is evaluated, and its value converted to the
   return type, before any deferred statement runs (13.5). The function
   returns the value that this conversion gave: a deferred statement
   that changes an object the operand read, or the rounding mode,
   changes nothing of it.
4. `S` cannot be left by `return`, `break` or `continue`, and `S`
   cannot contain `try`. A jump to a label (4.4), where the jump itself
   stands in `S`, has no target outside `S`. A loop inside `S` may use
   its own `break` and `continue`.
5. No jump to a label from outside `S` has a target in `S`, and none from
   outside the scope of a `defer` statement has a target in that scope.
   Section 4.4 says what is a jump to a label and what its targets are.
   The address of a label, `&&L`, is by 4.4 a jump to `L` from every
   point of the function. It is therefore refused, wherever it is
   written, when `L` is in the scope of a `defer` statement, and only
   then: a function that has a `defer` statement may take the address
   of a label that is in no such scope.
6. A loop body and a match arm are blocks: a `defer` in one runs at the end
   of each iteration or arm.
7. `longjmp`, `exit`, `abort` and other functions that do not return leave
   without running deferred statements.
8. *Provisional (P9).* `S` is moved text, and the resolution property of
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
   writes the copy (13.5). The error path of a `try` is an exit before
   the statement or declaration that holds the `try`, so that
   declaration is not in scope there:
   `{ defer use(x); { int x = try f(); } }` is allowed, since the copy
   stands before the declaration of the inner `x`. `S` is a block, as
   the substatement of an `if` is in C (C11 6.8.4p3), and each copy is
   written as one, `{ S }`: what `S` declares is in scope in `S` alone,
   at the `defer` statement as in each copy.
9. *Provisional (P9).* `S` contains no identifier label and no
   definition of an object with static or thread storage duration, and
   `S` declares no type. That leaves out a struct, union or enum
   specifier that has a body or declares its tag, and a Type-C type
   declaration, such as a variant that a block in `S` declares. `S` is
   copied to every exit (13.5): each copy would define the label again,
   would hold an object of its own, and would declare a type of its
   own, with the names it claims (10.1) and a layout set by the pragmas
   in force at its exit and not at the `defer` statement (13.5). A
   label declared with `__label__` is local to its copy and would not
   clash, and neither would an incomplete type; both are refused all
   the same, so that the rule has no exception. A declaration with
   `extern` defines no object and is allowed, as is a typedef whose
   specifier declares no type: the typedef itself names a type and
   declares none (C11 6.7.8p3).
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
    expression.
12. *Provisional (P9).* Lowering writes a `return` in the scope of a
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

Rules 1, 5 and 10 make the set of deferred statements that a jump leaves
a static fact, so `defer` needs no flags or run-time bookkeeping. Rules
8 and 12 are not in the TS. Rules 8 and 9 let the compiler repeat `S` at
each exit exactly as written, with every name bound as in the original
and no label, object or type defined twice, and rule 12 lets it write a
`return` as a block. `typec` lowers every `defer` statement itself
(13.5) and hands the backend none: a `defer` statement stands either
in text that typing reads, where it is lowered, or among the tokens
that typing does not read, where the scan of rule 1 refuses it under
both its spellings: `_Defer` in every such token, and `defer` in each
one that is Type-C text, the only text in which the word begins a
statement (2.3). It does not depend on the C compiler implementing
the TS.

Rationale for rule 11. C makes the substatement of a selection or
iteration statement a block of its own (C11 6.8.4p3, 6.8.5p5), so the
scope of a `defer` statement there would be empty and `S` would run at
once. A label is followed by a statement, which a declaration is not in
C11 or in the accepted dialect (2.4, 13.3), and a `defer` statement
stands where a declaration does. The last expression of a statement
expression is its value and leaves `S` no place after it.

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
   those of a generic type are (10.3).
2. Inside, `Ti` is an opaque value type (3.2).
3. The body is checked once, against the opaque types, when the definition
   is read. It may use a value of type `Ti` only in ways that are valid for
   every value type:

   - declare objects of the type, including with the initialiser `{0}` or `{}`;
   - initialise, assign, pass to a parameter of a prototype, and return;
   - apply unary `&`, `sizeof` and `_Alignof`;
   - do everything C allows with a `Ti *`: dereference, arithmetic,
     subscripting, comparison, casts to and from other object pointers;
   - use `Ti` as a type argument and in derived types.

   Arithmetic, comparison, conversion and casts of a `Ti` value, member
   access, calls, truth tests, and `_Generic` on a type that depends on
   `Ti` are errors. So is passing a `Ti` value through `...` or to a
   function without a prototype: the default argument promotions (C11
   6.5.2.2p6) would convert the values of some types and not of others.
4. An expression whose value depends on a type parameter, such as
   `sizeof(T)`, is not a constant expression. It cannot be an array bound, a
   `case` value or a static initialiser, and a type parameter cannot be the
   operand of `_Alignas`.
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

Because of rules 2 to 4, an instance of a checked generic function is
valid C for every value type. Instantiation fails only where a chain of
instances exceeds the nesting limit (3.5 rule 7), where a declaration
changes what the definition names (3.5 rule 8), where another
declaration takes a name that an instance claims (10.3), or where 10.3
or rule 2 of 7.3 refuses the instance's placement.

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
   address taken.
5. A type argument, deduced or explicit, is a value type that also meets
   rule 2 of 3.5.

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
   no code.
2. The definition of a generic function precedes the first use of each
   of its instances, since the instance is defined there (10.3): generic
   functions are defined in headers. A declaration that is not a
   definition lets generic functions call each other, provided both are
   defined before an instance of either is used. A generic function may
   be declared `static` or `inline` but not `extern`.
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
4. Consequences: the code of an instance is duplicated across translation
   units, the address of an instance differs between them, and a static
   object in a generic function exists once per instance per translation
   unit.
5. An ordinary function gives C code and other translation units a single
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

1. `s[i]`, for `s` of a slice type, is an lvalue of type `T` that designates
   `s.data[i]`. It traps unless `(size_t)i < s.len`; the test precedes any
   pointer arithmetic, and `s` is evaluated once. *Provisional (P14):* no
   option turns the check off. `s.data[i]` is the unchecked spelling and is
   visible in the source.
2. `slice_from_array(a)` takes an lvalue of array type `T[N]` and yields a
   `slice(T)` of length `N`. A pointer is not accepted.
3. `slice_sub(s, lo, hi)` yields the elements `[lo, hi)` of `s`. `lo` and
   `hi` are converted to `size_t`, and it traps unless `lo <= hi` and
   `hi <= s.len`.
4. `slice_unchecked(p, n)` makes a slice from a pointer and a count that the
   compiler cannot verify.
5. `slice(T)` converts implicitly to `slice(const T)`, as `T *` converts to
   `const T *`.
6. *Provisional (P13).* A string literal whose target type is `str` denotes
   a `str` over the characters of the literal. Its length excludes the
   terminating NUL, which is still present in storage.
7. A slice does not own its storage and says nothing about how long it
   lives. A slice of length 0 may have a null `data`. A `str` promises
   neither NUL termination nor an encoding.
8. `data` and `len` are ordinary members and can be read and, outside
   checked mode, written.

`slice` is a universe generic type with one piece of syntax, `[]`. The three
functions are universe names that the compiler implements; they need no
library. Bounds checks address reads and writes past the end of a live
buffer, and nothing else.

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
Type-C unit (2.3), and definitions of instances that lowering would
write again. Package 4.1 of the plan settles it, either by keeping the
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

*Provisional (P10).* An instance is named by its generic followed by `__`
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
argument holds no attribute for the expansion to lose (3.5 rule 2). An
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
either: they follow its last encoding with `_`.

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
   definition of its generic precedes (7.3 rule 2). The type instances
   that a definition needs complete are defined before it.

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
  after `typedef struct expr expr;` and before `enum expr_tag`.
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
packing around it stays as it was. No rule need say which of these texts
can hold a layout, since all are written through the one bracket. A
generic that is defined under `#pragma pack` is not packed by it; a
struct or union in a generic that is to be packed says so in the
definition, with `__attribute__((packed))`, which every instance then
carries. Under `-fpack-struct=n` the packing of the command line is
that option's, for an instance as for every other structure of the unit.
Other pragmas that change a layout are not kept from an instance (13.5).

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

What a definition names means in the instance what it means in the
generic (3.5 rule 8).

At the external declaration of its first use an instance claims, at file
scope, every name it declares there: a type instance its typedef name
and its tag and, where it is a variant, the enum tag and the enumerators
of 10.1; a function instance its name. All go through the one check
that claims a variant's names (10.1 rule 6): any other declaration of
one of them in the file scope or in a scope nested in it, in C text as
well, is an error, whichever comes first. A block that declares
`int max__i;` where `max__i` is claimed is refused. The claim begins at
that external declaration, in the lowered C: a block that ends before
it there holds no use of the instance and may have declared one of the
names. A block in the body of a generic function stands in the lowered
C where the instances of that function do, not where the generic is
defined, so it is refused when it declares a name that is claimed
before one of those instances.

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

### 10.5 Traps

A *trap* stops execution at the point of failure and never returns control
to the failing code. By default it is `__builtin_trap()` on GNU-compatible
compilers. `--trap-function=name` calls `_Noreturn void name(void)`, which
the program supplies, before the builtin; freestanding targets use this to
report the failure. Where the compiler has no such builtin, the call is
followed by an endless loop. The traps are: an invalid tag in `match`,
in a single-pattern test (4.5) or in `try` (5.1 rule 2), the end of a
match arm, a slice index or sub-slice out of range, and the checks of
checked mode.

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
   does not carry into an included file or out of one.
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

1. A dereference, `*p` or `p->m`, traps if the pointer is null. The check
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
| Nested and constant patterns | `case Add(Number(0), r):`. Needs matrix-based exhaustiveness and a rule that tells a binding from a constructor without fields. | Pilot code that routinely nests matches two deep. |
| `try` inside expressions | `f(try g(), h())`, with a defined order for the hoisted operands. | Many rewrites forced by 5.1(3) in pilot code (P8). |
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
  a makefile rule and works under make, ninja and cmake. Dependency files
  (`-MD`) come from the preprocessing step and name the real output.
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
- `--emit-c` stops after emission and writes the C. `--emit-c-header` is
  described in 9.3.
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
- Subprocesses are started with argument vectors, never through a shell.
  Intermediate files live in a private temporary directory.
- A backend step that fails ends `typec` with the backend's own status,
  or by the signal that ended it, as a direct compile would. `typec`'s
  own failures have statuses of their own, so that a build tool or a
  test runner tells them from the backend's without reading stderr: 80
  when `typec` refuses the program (a diagnostic about the source), 81
  for an error of its environment (the command line, a backend it cannot
  start or that gives no target model, a file it cannot read or write)
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
`__Float32x4_t` and `__Float64x2_t` with GCC and the SVE
`__SVFloat32_t`, `__SVFloat64_t` and `__SVBool_t` with both),
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
arguments; or unknown (P21), as for the vector builtins. An undeclared
identifier is an error unless the table has it for the backend, and one
that only the other compiler has, or that the backend has on other
architectures only, is an error saying so, so a builtin is never
guessed. *Provisional:* no macro says which Arm vector types a backend
declares, so the compiler and the architecture decide, as GCC 14 and
Clang 20 declare them on AArch64 whatever the target's features; a
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
finds such a token (section 6 rule 1). A body is therefore passed
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
`_Defer` (section 6 rule 1). A Type-C
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
the first release that types C as the front end does: Clang 19 gives an
enumerator that `int` holds the type `int` in an enumeration whose
values `int` does not all hold, where Clang 20 and GCC follow C23
6.7.2.2 (N3029) in every dialect and give every enumerator the
enumerated type. For GCC it is the oldest release that a test host
runs. *Provisional:* Apple numbers its Clang releases on its own and is
held to the same minimum, which only Apple Clang 21 confirms; an Apple
release at or above the minimum that types C as Clang 19 does would
settle it otherwise, and without one the minimum stays.

**No aggregate layout.** *Provisional (P16).* The size, alignment and
member offsets of struct, union and array types are opaque constants to
the front end. Expressions that use them are emitted as written and the
backend evaluates them; `_Static_assert` passes through. Packing pragmas,
bit-fields and layout attributes make this the part of C that is hardest
to duplicate, and a silent disagreement would be an ABI bug.

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
statement rests (13.5, P9), that the function's name names exactly one
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
  and P9 counts the refusals.
- Clang's `diagnose_if`, whatever its arguments. It reports a mention
  of the name where its condition holds, as an error or as a warning,
  whichever an argument says, and `typec` cannot tell which without
  reading the arguments, so every `diagnose_if` is marked. Apple Clang
  21 reports the `f` where the condition holds and reads no parameter.

`deprecated` has no mark: it reports a mention of the name as a
warning, and the table of diagnostics in 13.5 holds what the form adds
for it. Under `-Werror` the added warning breaks a build, which the P9
row of section 15 counts; a mark is for what reports an error by
itself. An attribute that is found to break the form joins the table
with a mark; 13.5 says what an attribute without one means there.

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
puts on an overload set are left to it. A use of the name resolves as
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
construct that it lowers. The marker after the text gives the place of
the external
declaration that follows. Every one of these markers takes the flags 3
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
| Constructor expression | A compound literal, `((struct expr){ .tag = expr_Add, .u.Add = { a, b } })`, which names the claimed struct tag and enumerator (10.1 rule 6) rather than the typedef name, which a block may hide. Inside an initialiser, the braced list alone, also for a constructor nested in another's arguments, so that static initialisers remain constant. |
| `match` | A block: a pointer to the scrutinee, or a copy when it is not an lvalue or is volatile, atomic or declared `register`; a `switch` on the tag with a `case` for every constructor; a block per arm that holds its block items as written and ends in a trap (10.5), `case X: { items trap }`; where the arm binds, that block declares the bindings first and holds the items in a block of their own, `case X: { bindings { items } trap }`; `break`, `continue` and `return` unchanged; `default:` holding the trap. |
| Single-pattern test, `if` | A block: the operand held as a `match` holds its scrutinee; the tag, read once into a local; an `if` on that local. The true branch is a block that opens at the `)` of the test, declares the bindings and then holds what follows that `)` as written, the controlled statement `S` with a pragma that stands before it: `{ bindings S }`, whether the test binds or not and whether `S` is a compound statement or not. The false branch traps when the local is no constructor's tag and then holds the `else` statement, if there is one. |
| Single-pattern test, `while` | The same block as the body of an endless loop, with a false branch that traps on an invalid tag and then ends in `break`. `break` and `continue` in the controlled statement stay unchanged, and the operand is evaluated in the body of that loop (4.4). |
| Distinct type | A typedef. Casts are kept. A construct that asks whether two types are compatible, `_Generic` and `__builtin_types_compatible_p`, is answered by the front end where Type-C text compares a distinct type: one of the types compared (the controlling type or an association's, either operand) is or contains one. The selection keeps its controlling expression and every association, so the backend sees the names they use and the tags they declare outside the association type names, and is steered to the front end's choice: the type name of the association at position `i` becomes `char (*)[i]`, and the controlling expression `e` becomes `((void)(e), (char (*)[k])0)`, where `k` is the position of the selected association. Arrays of different lengths make these types pairwise incompatible, and `default` stays, as its position is no type name's. The builtin becomes `1` or `0`. C text compares the representation (10.2), and the backend answers. |
| Type application | The name of its instance; the instance is declared and defined at file scope in the two steps of 10.3. |
| Generic function instance | A `static` function: the tokens of the definition, resolved as at the definition (3.5 rule 8), with each type parameter written as the typedef of its argument (10.3). Its prototype and its definition stand where 10.3 says. |
| `try` | A temporary of the result type, initialised with the operand; a test of whether its tag is `Ok`, the only test that success passes; where it is not, a trap unless the tag is `Err` (5.1 rule 2), then the active cleanups and a `return` of the `Err` built from the temporary; then the `Ok` field, read where the `try` stood. The temporary and the test stand directly before the statement or declaration that holds the `try` (5.1), as said below the table. Where `T` is `void`, `Ok` has no field (3.5 rule 6) and nothing is read after the test. |
| `defer` | *Provisional (P9).* The deferred statement `S` is repeated, as written and as a compound statement `{ S }`, at every exit from its scope, in reverse order. A `return e;` in the scope becomes a block, as said below the table. |
| Slice index, `slice_sub` | A call to an internal inline function that tests and then indexes, named as said below the table. |
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

**The statement that holds a `try`.** The temporary and the test of a
`try` stand directly before the statement or declaration that holds it,
in the same block, so the operand is moved text. The temporary is named
`__tc_t` and a number, which counts the `try` expressions of the
function from 0 in the order of the source: the temporaries of one block
share a scope, so each needs a name of its own. The labels of the
statement stay in place on a null statement, `L: ;`, and the temporary,
the test and the statement follow it. No block is then made around a
labelled statement, and a tag that the statement declares keeps the
scope it has in the source. Where the statement is not a block item once
its labels are set aside, it is the substatement of another statement,
which C makes a block of its own (C11 6.8.4p3, 6.8.5p5), and a block is
made around the null statement of the labels and the three, so the
labels stay inside the substatement: `if (c) L: x = try f();` becomes
`if (c) { L: ; /* temporary, test */ x = /* the Ok field */; }`, with
`L` under the `if`.

Nothing stands between the test and the statement, so a pragma before
the statement or before one of its labels would come to stand before
the temporary, or before the null statement of the labels. A `try` is
therefore an error where a pragma stands directly before the statement
or declaration that holds it, or directly before any of its labels: a
`#pragma` line, which is also how a `_Pragma` operator reaches `typec`.
`typec` sees the line as tokens and applies the rule without reading
them, whatever the pragma. A pragma there may govern the one statement
after it, as OpenMP's `critical` does. It would govern the declaration
of the temporary, which GCC 16 refuses under `-fopenmp` and the front
end of Apple Clang 21 under `-Xclang -fopenmp` (Apple's driver rejects
`-fopenmp` itself), and the error path of the `try` would leave the
governed statement.

The temporaries share the block of their statements, so a build that
asks for C90's order of declarations or for C++'s jump rule hears of
them: `-Wdeclaration-after-statement` reports a temporary that follows
a statement of its block, and `-Wjump-misses-init` a `goto` that
crosses one (Apple Clang 21, GCC 16). Neither is in `-Wall` or
`-Wextra`.

The error path returns the `Err` that is built from the temporary after
the cleanups (5.1 rule 2).

**`return` in the scope of a `defer` statement.** *Provisional (P9).*
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

A function with no such `return` is written as it stands.

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
  so an operand of unknown type is no error there.

In a function that returns `void` there is no value to hold and no
typedef. `return e;` with a void expression for `e`, as in
`return g();`, becomes `{ e; /* cleanups */ return; }`. The `return` of
the error path of a `try` needs no temporary either: the temporary of
the `try` holds its value, and no cleanup reads or changes that one,
since its name is reserved (2.3).

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
| `-Wmisleading-indentation` (in `-Wall`), both backends, `if (c) return x;` followed by a statement indented as if the `if` guarded it | Reported | Lost: the `return` stands in a block |
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
emitted header (9.3).

Pilot B judges the form against this list and the refusals above, with
the rest of P9; the P9 row of section 15 is the one list of what it
counts. Without a finding against it, the form stays.

Rules 8 and 9 of section 6 guarantee that each copy of a deferred
statement binds its names as the original does and defines no label,
object or type twice. Rule 12 guarantees that the block ends the scope
of no name that the operand declares, and that control leaves the
operand only as it ends or by leaving the function, so that the block
ends the life of no object that the source keeps.

**Moved text.** Lowering writes some source text at a place other than
its own: a deferred statement at each exit from its scope (section 6),
the definition of a generic in each instance (10.3) and the operand of
a `try` before the statement or declaration that holds it (5.1). One
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
  structure is completed between the text and the place of writing.
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
  parameter denotes (10.1, 10.3), or a name that it invents. Each is
  claimed (10.1, 10.3) or reserved (2.3), so no declaration hides one:
  not in a block, not in a copy of a deferred statement and not in an
  instance. A declaration that hides a universe name or a constructor
  from the source therefore changes no moved text.
- Moved text declares no name that is in scope after it. The text does
  not stay at its own place, so what follows it there would lose the
  declaration, and what follows a place of writing would gain it. A name
  whose scope ends inside the text, in a parameter list or in a block,
  is no such name. The kinds of moved text meet the clause each in its
  own way. A deferred statement is a block (section 6 rule 8), so the
  clause holds for it by construction. The operand of a `try` declares
  no tag and no enumeration constant in the scope around it (5.1 rule
  3). The definition of a generic declares its generic, and that of a
  generic variant its constructors, which lowering writes under the
  names of the instances (10.1, 10.3), and nothing else: it is not the
  first mention of a tag in file scope, and the head of a generic
  function declares no type at all (3.5 rule 8). The clause holds as
  well for the operand of a `return` that lowering writes as a block,
  though that text does not move (section 6 rule 12).

The property is stated here alone and checked in one place. Every move
goes through one check of the three clauses, and so does the block that
lowering makes around the operand of a `return` (above), where the
third clause applies. No kind of moved text has a check of the property
of its own: rules 8 and 12 of section 6, rule 8 of 3.5 and rule 3 of 5.1
cite the property and show it on examples, and what rule 3 of 5.1 and
rule 12 of section 6 say of a name that the operand declares is the
third clause on their text.

A place where the text is written is a place in the lowered C. The
copies of deferred statements for the error path of a `try` stand with
its test, before the statement or declaration that holds the `try`, so
a declaration that holds a `try` is not in scope at them (section 6
rule 8).

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
line among them. Three rules carry the property into unread text.

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
  though it would change nothing. The measurements of P9 and P23 count
  these refusals.
- For the second half, an identifier in an attribute argument or a
  `#pragma` line may denote, at its place, what lowering writes under a
  name of its own: a type parameter, a universe name, a constructor or
  a generic. Lowering leaves unread text as the source spells it,
  whether the text is moved or not, so the backend reads the spelling
  as the lowered C declares it there. Where the Type-C name hides a C
  entity of that spelling, the backend would read that entity, with no
  message, and the identifier is an error, in all Type-C text and in
  moved text that is C text: with `typedef char T;` at file scope,
  `__attribute__((aligned(sizeof(T))))` in a generic with a type
  parameter `T` would take the size of `char` in every instance. Where
  it hides none, the lowered C declares nothing under the spelling and
  the backend decides: it refuses a name that it cannot find, as the
  `option` of `__attribute__((aligned(_Alignof(option(int)))))`, and
  takes a word that is no name, as the `push` of `#pragma pack(push)`
  in the scope of a generic named `push`.
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
text is written, and it is outside the property. A deferred statement
declares no type for such state to lay out (section 6 rule 9). An
instance is kept from `#pragma pack` by the bracket of 10.3 and from no
other pragma that changes a layout, among them `#pragma ms_struct on`,
GCC's `#pragma scalar_storage_order` and a `#pragma clang attribute
push` that applies `packed`. An instance that is first used inside the
region of one of them in one translation unit, and outside it in
another, has one name and two layouts. A function instance is likewise
compiled under the pragmas in force where its first use puts its
definition: `#pragma GCC target`, `#pragma GCC optimize`, `#pragma clang
attribute push` and the pragmas that name a section apply to an instance
first used in their region. Code under such a pragma keeps the first use
of every instance outside its region.

The identifiers that the compiler invents begin with `__tc_`, which
keeps them from every name in the text (2.3). One that is declared at
file scope or defined as a macro, and is one of many of its kind,
continues with a word for its kind, then `__`, then what tells it from
the others of its kind:

- the internal function of a slice index or of a universe function:
  `slice_index` or the name of the universe function, then the argument
  encoding of the slice instance it serves (10.3), as in
  `__tc_slice_sub__h` for a `slice(unsigned char)`;
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
a header never meets the guard of an instance. The name of a universe
function is the kind word of its internal functions, and no universe
function has the word of another kind of this list as its name. Within
a kind, an encoding is one type, an instance name one instance (10.3),
and the written form of a module that last component alone, since
every `_` in it begins an escape. The written form holds no `__` and
does not end in `_` either, so in the guard of an instance the first
`__` after the kind word's ends the module, and the guard is one module
and one instance. A generic of the universe shares its guards with no
other: no generic of a file has a universe name (3.6), so none has its
instance names.

No other invented name holds a `__` after the prefix. `__tc_ret`, the
return type of a function, is declared once in the outermost block of
its function, and `__tc_r`, the temporary of a `return`, in a block of
its own; neither needs more than the prefix. `__tc_t0`, `__tc_t1` and
so on are the temporaries of the `try` expressions of a function, which
share its blocks and take the number that tells them apart. `__tc_bits`
and `__tc_enum_probe` are the probes of the assertions that end a unit
(13.4), and `__tc_pack_probe_1` and `__tc_pack_probe_2` the two
structures of the packing probe that ends one (10.3), one of each.

### 13.6 Diagnostics and debugging

- A diagnostic carries the file, the line, the source line and a stable
  code. Stable codes let tests and editors refer to a diagnostic without
  matching its text.
- A stable code is `TC` and four digits. It names a rule of this design
  that Type-C text breaks, a limit of the GNU profile (13.3) that C
  text or Type-C text meets, or a construct that a later work package
  implements, and ends the diagnostic in brackets after the clause that
  states the rule, as GCC and Clang end a warning with its option:
  `file:line: text (design 4.2 rule 1) [TC0018]`. Each rule's code is
  written beside it in the one table of rules, which generates the
  catalogue of diagnostics; a code is never renumbered or reused.
- A refusal of C text carries no code: it states no rule of this design,
  and C11, the GCC manual or the backend's own diagnostic names what is
  wrong. A translation limit of `typec` (C11 5.2.4.1), such as the
  parser's bound on the nesting of brackets, is such a refusal. The
  limit on nested instantiation is none: 3.5 rule 7 states it as a rule
  of Type-C, so it carries a code. A limit of the GNU profile, a
  construct
  outside the profile or one that needs what `typec` does not compute,
  is a refusal of the accepted dialect by this design rather than by C,
  so it carries a code. Every refusal of the front end is either coded
  or a refusal of C text, and only the function that appends a rule's
  code makes a coded one.
- Debuggers step through the original lines. Bindings are C locals under
  their source names. A variant value appears as its lowered struct, with
  the tag printed by name. Generic instances appear under their instance
  names.
- `--emit-c` shows what any construct became. Its output is the file
  that the compile step reads, preprocessed output with GNU line markers
  (13.4): compiling it by hand takes `-x cpp-output`, and under
  `-pedantic` on Clang also `-Wno-gnu-line-marker` (2.4).

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
| A `match` handles every constructor | Every `match` | Nothing; an invalid tag traps |
| Distinct types do not mix without a cast | Type-C code | C code sees the underlying type |
| Only the owner creates values of a private type, other than the zero value | Type-C code that does not write bytes behind the type | Not a security boundary (9.2) |
| A generic function is valid for every instance | Every instance that compiles: a chain past the nesting limit (3.5 rule 7), a declaration that changes what the definition names (3.5 rule 8), another declaration of a name that an instance claims (10.3) and a placement that 10.3 or 7.3 rule 2 refuses are compile errors | Nothing |
| Text that lowering moves means what it means at its own place, and the text around it what it means without the move | A deferred statement at each exit, a generic's definition in each instance and the operand of a `try` (13.5). Attribute arguments and `#pragma` lines are covered as far as 13.5 says: for the identifiers that denote something at the text's own place, and where a Type-C name hides a C entity | Pragma state is that of the place where the text is written. An instance is kept from `#pragma pack` alone: under another pragma that changes a layout (`#pragma ms_struct`, `#pragma scalar_storage_order`, `#pragma clang attribute`), an instance first used inside its region in one translation unit and outside it in another has one name and two layouts, and a function instance is compiled under the target, optimisation, attribute and section pragmas in force at its first use (13.5) |
| A C client and a Type-C unit see one layout of what an emitted header declares | Headers written by `--emit-c-header` (9.3) | The client compiles the header as C11 or later, for the target and with the layout options it was generated for, and includes it outside the region of every `#pragma pack` and of every other pragma that changes a layout. `typec` does not see a client's compile and cannot check this |
| A `result` is not discarded silently | Expression statements, left operands of `,`, clauses of `for` | Explicit casts to `void` |
| A slice access stays in bounds | `s[i]`, `slice_sub` | The slice describes live storage of its length |
| Tier 1 of checked mode (11.2) | Checked functions | Live pointers, correct trusted contracts and `unsafe` blocks |

Not guaranteed anywhere: object lifetimes, freedom from data races,
defined arithmetic, and anything about C code. Type-C does not replace a
memory-safe language, and none of the properties above holds against an
author who sets out to defeat it. The checked claims are backed by negative
tests, sanitizers and fuzzing, as the plan describes.

## 15. Provisional decisions

Each row is a choice that this document makes without evidence. The stage
numbers refer to the implementation plan.

| | Decision | Settled by | Default |
| --- | --- | --- | --- |
| P7 | A `void` type argument removes the field (3.5) | Stage 2 implementation and pilot | As specified |
| P8 | `try` is limited to three positions (5.1) | Stage 2 pilot: rewrites the limit forced | As specified |
| P9 | `defer` is lowered by repeating the cleanup at each exit, which needs rules 8, 9 and 12 of section 6, and a `return` in the scope of a `defer` statement holds its value in a temporary whose type `__typeof__` takes from a call of the function (13.5) | Stage 2, Pilot B, which counts what this row lists and nothing else for P9: code size against a hand-written `goto cleanup` version; how often each of rules 8, 9 and 12 of section 6 rejects code; among those of rule 8, the refusals that 13.5 makes for an identifier in an attribute argument or a `#pragma` line of a deferred statement; how often each refusal of the form (13.5) rejects a function or a `return`; the returns where the plain form reports a diagnostic of the list of 13.5 that the form loses; and the builds that a diagnostic the form adds breaks | Repetition, and the temporary as specified |
| P10 | The instance naming scheme (10.3) | Stage 2: injectivity tests; readability in a debugger | As specified |
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
| P21 | A type that the front end does not compute is unknown, an error only where it is needed (13.3) | Typing bodies (0.9b) and the corpus: points that need an unknown type's properties, the declarations that the resolution check of 13.5 refuses for one among them | Unknown types stay |
| P22 | `typec`'s own failures exit with 80, 81 and 82, which no backend uses (13.2) | Corpus runs with GCC and Clang: a backend failure that exits with one of them | As specified |
| P23 | A generic's definition is written as its tokens into each instance, which needs rule 8 of 3.5 (13.5) | Stage 2 pilot: how often rule 8 rejects a type definition, the refusals that 13.5 makes for an identifier in an attribute argument or a `#pragma` line of a definition among them. Stage 3: how often it rejects code in the container library (package 3.5) and in generic function bodies, where most of its cases arise | As specified |
| P24 | A block literal is C text only (13.3) | Stage 2, Pilot B: how often a block literal is refused. Type-C code on macOS: how often a block-taking API has no function-pointer form | C text only |

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

generic-function:      "generic" type-parameters function-definition
                     | "generic" type-parameters declaration

primary-expression:    ... | variant-type "." identifier
                           | generic-function-name type-arguments
variant-type:          typedef-name | generic-type-name type-arguments
assignment-expression: ... | "try" assignment-expression

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
sub-pattern:           identifier | "_"
defer-statement:       ("defer" | "_Defer") statement
unsafe-block:          "unsafe" compound-statement
```

A type declaration with type parameters is an external declaration only.
A `defer` statement is a block item and not a statement, so it is not the
substatement of another statement (section 6 rule 11). `try` is written
only in the positions of 5.1.
An unqualified constructor is an ordinary identifier or call in the
grammar; 3.3 decides its meaning. Slice indexing uses C's subscript
syntax.
