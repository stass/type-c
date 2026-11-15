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
| Generic function | `generic (` ... `)`, starting a file-scope declaration | C11 has no implicit `int`, so this starts a C declaration only when `generic` names a type; 2.3 excludes that case. |
| `unsafe` block | `unsafe {`, starting a statement | An identifier cannot be followed by `{`. |
| Type application, explicit instance | *G* `(` *types* `)`, where *G* names a generic | Only Type-C declares such a *G*. |
| Qualified constructor | *type-name* `.` | A type name cannot begin a postfix expression. |
| Unqualified constructor, `str` literal | Selected by a target type that is a Type-C type (3.3) | No C expression has such a target type. |

The consequence for adoption: a C file can be renamed to `.tc` and compiled
before any Type-C construct is used in it.

### 2.3 Words

*Provisional (P1).*

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
encloses file scope. Any declaration of the same identifier shadows the
universe name from that point, under C's ordinary scope rules, so
`int result = f();` remains valid C; inside that scope `result(T, E)` is
simply unavailable. Where C11 6.7.6.3p11 would read an identifier in a
parameter declaration either as a typedef name or as the parameter it
declares, a universe name is the parameter: `int f(int (str));` declares an
`int` parameter named `str`, as in C, so a header shared with C means the
same in both. A parameter whose type is a universe type and that has no
name is written without parentheses, `size_t len(str);`, where no other
reading exists.

**Generated names.** Identifiers that begin with `__tc_` are reserved for the
compiler in a Type-C translation unit; one in its text, C text included, is
an error, so that no declaration and no use can meet a name that lowering
generates. The names that a type declaration derives for C (section 10)
are reserved in the scope of that declaration.

Rationale. The words Type-C wants (`type`, `match`, `result`, `str`,
`option`) are among the most common identifiers in C. Reserving them would
break struct fields named `type`, parser functions named `match`, and every
`int result`, including uses that reach Type-C text through macros defined
in C headers. Recognition by position costs nothing where the construct is
invalid C anyway; Rust's contextual `union` and Go's universe block are the
precedents.

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
`-pedantic-errors`. Two are used: `__typeof__`, which C23 standardises as
`typeof` and which gives a match binding the type of its field where no
name for that type is sure to be visible, and `__builtin_trap` (10.5).
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
   in the same scope, by a variant definition with the same parameters. For
   an incomplete struct, C's `struct N;` remains the spelling.
5. A name has one definition in a scope. Unlike `typedef`, a type
   declaration is not repeated; headers use include guards.

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
   may have such a name, as a member may.
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
6. **A variant is opened only by `match`.** Type-C text cannot open a
   variant, that is, reach its tag or payload, as a value or by name:
   constructors make them and `match` reads them, and no other operation
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
  with a constructor `C`. *Provisional (P2):* there, `C` denotes the
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
Swift implicit member expressions work the same way.

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
   alone is not a type; a *type application* `G(A1, ..., An)` is. The name
   does not contain two consecutive underscores (10.3).
2. A type argument is an object type, complete or not, that is neither an
   array nor variably modified. It is declared at file scope, and a struct,
   union or enum argument has a tag or a typedef name declared with it, so
   that every argument has a name (10.3).
3. Two applications denote the same type exactly when they apply the same
   generic to pairwise identical arguments. Typedef names are transparent,
   qualifiers are significant, and a distinct type is identical only to
   itself.
4. A generic definition uses a type parameter only as a type: of a member,
   a field, a pointed-to object, an element, a parameter or a result, or as
   a type argument. It does not use one directly after `distinct`, in a
   bit-field or in `_Alignas`; no constant expression in it depends on one;
   and a struct, union or enum specifier in it has no tag. The definition
   is checked once under these rules, so an application to value types
   (3.2) cannot fail.
5. An application with an argument that is not a value type, such as an
   incomplete or qualified type, is checked when a complete type is first
   needed: the arguments are substituted and the result must be a valid
   definition. An error is reported at the application and cites the
   definition.
6. *Provisional (P7).* `void` may be an argument. A variant field whose type
   becomes `void` does not exist: its constructor takes no argument for it
   and a pattern has no sub-pattern for it. This makes `result(void, E)` the
   type of a fallible function that produces no value.
7. A generic may refer to itself through a pointer (`list(T) *tail`).
   Instantiation that nests deeper than an implementation limit of at least
   64 levels is an error.

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
only construct that knows `result` by name.

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
   one sub-pattern per field. A sub-pattern is an identifier, which is a
   *binding*, or `_`, which matches without binding.
4. *Provisional (P5).* A binding declares a non-modifiable object of the
   field's type in the scope of its arm, initialised with a copy of the
   field.
5. Each arm is a block of its own. Its bindings and declarations are
   invisible to other arms and after the match, and a declaration may follow
   a label directly.
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

### 4.2 Exhaustiveness

1. Every constructor is covered exactly once: by one `case` label, or by
   `default`. A missing constructor is an error that names it; so is a
   constructor named twice.
2. There is at most one `default`, and it must cover at least one
   constructor.
3. A `default` hides constructors added later. *Provisional (P4):* a warning
   for `default` on a variant exists and is off by default.
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
3. A label inside an arm may be the target only of a `goto` in the same arm.
   Each label of a GNU `asm goto` is the target of a `goto` in this sense.
   The GNU address of a label inside an arm, `&&L`, is refused anywhere,
   also in the label's own arm, since a computed `goto *e` from outside the
   arm could jump to it. A `case` or `default` label of an enclosing
   `switch` cannot appear inside a `match`.
4. `switch` is unchanged.

The lowered code also ends every arm in a trap (13.5). If the analysis of
4.4 and the generated code ever disagreed, execution would stop there and
could not enter another arm's bindings.

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
inside a match arm within the item, which by 4.3(3) only a `goto` in that
arm reaches, a label in the body of a block literal, which is a function
of its own, and a `case` or `default` label of a `switch` within the
item. Such a label belongs to the innermost `switch` around it (C11
6.8.4.2p4) and is reached only through that `switch`'s controlling
expression, so it counts for the items between it and the `switch` body
and for none that contains the `switch`. In `switch (n) { default: return
1; { case 2: ; } }` the block after the `return` is reachable and the
`switch` can complete.

A constant here is an integer constant expression that the front end can
evaluate (13.3). A statement expression of the GNU profile is treated as
the block it contains: a `break`, `continue`, `goto` or label inside it
counts for the statements around it. A `break` leaves the innermost
loop, `switch` or `match` around it and a `continue` the innermost loop;
the parser records which, so that the analysis reads one answer. One in
a statement expression in the condition of a `while` or `do`, or in the
condition or step of a `for`, that leaves no loop, `switch` or `match`
within the expression is refused: Clang takes it to leave that loop, GCC
the statement around the loop, and GCC refuses it where there is none
(GCC 16, Apple Clang 21). In the first clause of a `for` and the
controlling expression of a `switch` both take it to leave the statement
around that one, and so does typec there and in the scrutinee of a
`match`, which lowers to a declaration before its `switch` (13.5). An
arm that the rules reject but that cannot in fact fall through is fixed
by adding the `break` the rules ask for.

### 4.5 Invalid tags

Matching a value whose tag is none of its constructors *traps* (10.5). Such
a value comes only from code that writes the bytes of the object behind its
type (C code, or Type-C code that uses casts, unions or `memcpy`) or from
an uninitialised object. The check is present in every match, including
one with `default`: a `default` arm receives real constructors only.

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
   returns `result(U, E)` with the identical `E`. Anything else is an error;
   there is no implicit conversion between error types.
2. `try` evaluates its operand once. If the value is `Err(x)`, the function
   returns `Err(x)` exactly as a `return` statement would, running the
   deferred statements that are active (section 6). If it is `Ok(v)`, the
   `try` expression has the value `v` and the type `T`; when `T` is `void`
   it is a void expression.
3. *Provisional (P8).* A `try` expression is the whole initialiser of an
   automatic object, the whole right operand of `=` in an expression
   statement, or a whole expression statement. In the assignment form the
   operand of `try` is evaluated before the left operand.
4. `try` cannot appear in a deferred statement.

Rationale for the positions. C leaves the evaluation order of operands and
arguments unspecified and sequences `&&`, `||`, `?:` and `,`. Hoisting a
`try` out of an arbitrary expression must respect both, and C11 has no
expression that can hold statements. The three positions cover the common
case of one fallible call per statement and lower to straight-line C.
General placement is in section 12.

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

1. The *scope* of a `defer` statement runs from its end to the end of the
   enclosing block. `defer S` schedules the statement `S` to run when
   control leaves that scope: by reaching the end of the block; by
   `return`, `break`, `continue` or `goto` to a point outside the scope,
   which includes a `goto` back to before the `defer` statement; or by the
   error path of `try`. When several scopes are left together, their
   statements run in the reverse order of the `defer` statements.
2. `S` runs at the exit and sees the values variables have then.
3. The operand of `return` is evaluated, and converted to the return type,
   before any deferred statement runs.
4. `S` cannot be left by `return`, `break`, `continue` or `goto` and cannot
   contain `try`. A loop inside `S` may use its own `break` and `continue`.
5. `goto` and `switch` cannot jump into `S`, nor from outside the scope of
   a `defer` statement into it.
6. A loop body and a match arm are blocks: a `defer` in one runs at the end
   of each iteration or arm.
7. `longjmp`, `exit`, `abort` and other functions that do not return leave
   without running deferred statements.
8. *Provisional (P9).* Within the scope of a `defer` statement, a
   declaration in a nested block cannot reuse a name that `S` uses.

Rules 1 and 5 make the set of deferred statements that a jump leaves a
static fact, so `defer` needs no flags or run-time bookkeeping. Rule 8 is
not in the TS; it lets the compiler repeat `S` at each exit exactly as
written, with every name bound as in the original. `typec` always lowers
`defer` itself (13.5); it does not depend on the C compiler implementing
the TS.

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
2. Inside, `Ti` is an opaque value type (3.2).
3. The body is checked once, against the opaque types, when the definition
   is read. It may use a value of type `Ti` only in ways that are valid for
   every value type:

   - declare objects of the type, including with the initialiser `{0}` or `{}`;
   - initialise, assign, pass and return;
   - apply unary `&`, `sizeof` and `_Alignof`;
   - do everything C allows with a `Ti *`: dereference, arithmetic,
     subscripting, comparison, casts to and from other object pointers;
   - use `Ti` as a type argument and in derived types.

   Arithmetic, comparison, conversion and casts of a `Ti` value, member
   access, calls, truth tests, passing through `...`, and `_Generic` on a
   type that depends on `Ti` are errors.
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
valid C for every value type. Instantiation fails only by exceeding the
nesting limit of 3.5.

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
   in that translation unit as a function with internal linkage. A generic
   function that is not used produces no code.
2. The definition must therefore be visible wherever an instance is used:
   generic functions are defined in headers. A generic function may be
   declared `static` or `inline` but not `extern`.
3. Consequences: the code of an instance is duplicated across translation
   units, the address of an instance differs between them, and a static
   object in a generic function exists once per instance per translation
   unit.
4. An ordinary function gives C code and other translation units a single
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
2. *Provisional (P6).* The owner is the text of the file that contains the
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
   to every client, C code or unchecked Type-C can write any bytes, and a
   line marker in the source can name the owner's file and so claim its
   rights. Type-C text also makes a private value without a cast or a
   constructor through any operation that reinterprets storage, such as a
   pointer conversion (`*(symbol *)p`), a union member, `va_arg` or
   copying bytes; these stay outside the rule, because refusing pointer
   conversions would break `malloc` code. Bounding them belongs to checked
   mode (section 11).

### 9.3 C clients

`typec --emit-c-header M.tci` writes `M.h`, the lowered form (section 10) of
the declarations in `M.tci`, for C compilers: variants as tagged structs,
distinct types as typedefs, and function prototypes. An `#include` of
another `.tci` becomes an `#include` of its `.h`. Generic declarations are
omitted; a type application that `M.tci` names through a typedef is emitted
as a concrete struct. The header is specific to the target and
configuration it was generated for. C clients can read and write everything
it exposes, and no Type-C rule binds them.

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
2. *Provisional (P3).* The tag has the generated enumeration type, with the
   size and alignment the target's C ABI gives that enumeration. Debuggers
   then print constructors by name, and layout has one authority.
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
| Pointer to *T* | `P` *T* |
| `const`, `volatile`, `restrict` qualified *T* | `K` *T*, `V` *T*, `r` *T*; several are written in the order `r`, `V`, `K` |
| `_Atomic` *T* | `A` *T* |
| Struct, union or enum with tag *name* | `T` *length* *name* |
| Variant, distinct type, or untagged type named by its typedef | *length* *name* |
| Application `G(args)` | `I` *length* `G` *args* `E` |
| Function type, under a pointer | `F` *return* *parameters* `E`. The parameters are `v` for an empty prototype and `N` for no prototype; `z` marks a trailing ellipsis; top-level qualifiers of parameters are dropped, as in C's type compatibility. |

`vector(int)` is `vector__i`, `vector(expr *)` is `vector__P4expr`, and
`result(uint32_t, parse_error)` is `result__j11parse_error` where
`uint32_t` is `unsigned int`. A generic's name has no `__` (3.5), so the
first `__` of an instance name always separates the generic from its
arguments, and every encoding is self-delimiting. Arguments are encoded
after typedef expansion, so names depend on the target, like every other
ABI fact. The remaining types of the GNU profile are encoded in the same
manner.

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
followed by an endless loop. The traps are: an invalid tag in `match`, the
end of a match arm, a slice index or sub-slice out of range, and the checks
of checked mode.

### 10.6 What C code sees

| Type-C | C |
| --- | --- |
| Variant | Tagged struct (10.1), by value |
| Distinct type | Its underlying type |
| Type application | Struct or typedef under the instance name |
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
| Single-pattern test | `if (case Add(l, r) = *e) { ... }` and the same in `while`; bindings scoped to the controlled statement. `case` cannot begin a C condition. | A large share of pilot matches have one `case` and a `default` (P4). |
| Binding by reference | `case Block(&stmts):` binds a pointer to the field, for in-place update of a payload. | Pilot code that rebuilds values only to change one field (P5). |
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
| Compact layouts | Smaller tags; `option(T *)` as a nullable pointer. An ABI change, so opt-in. | Measured size of pilot data against hand-written C (P3). |
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
- *Provisional (P15).* The backend preprocesses: `typec` runs it with
  `-E -x c` and the user's options, parses the result, and compiles its own
  output with `-x cpp-output`. Macros are expanded once, by the compiler that
  compiles the result, so the two cannot disagree. The cost is that
  locations are a file and a line: columns and macro backtraces are not
  available, and backend warnings that depend on macro provenance or on
  comments can differ from a direct compile.
- `--emit-c` stops after emission and writes the C. `--emit-c-header` is
  described in 9.3.
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
  (P22).* The values assume that no backend exits with them: GCC and
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
the function's body is read.

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
cannot use, as Apple clang reserves `__float128` and GCC `_Float128x`;
typec reads such a spelling as an identifier, which only a program that
declares a reserved identifier (C11 7.1.3) can tell; GCC's `__float128`
is a builtin typedef name, which such a program can tell as well. Both
GCC and Clang reserve `__int128` on targets without the type, i386
among them, where typec reads it as an identifier in the same way. Only
x86-64 backends confirm the rule; a backend of another architecture
whose macros disagree with its keywords would settle it otherwise, and
without one the rule stays. A construct outside the profile is an error
that names it; the front end does not guess. GCC's nested functions are
outside the profile, as Clang has none. Bodies of functions defined
in system headers are not parsed: they are brace-matched and passed
through.

**Typing.** The front end types every expression by C's rules: promotions,
usual arithmetic conversions, lvalues, qualifiers, composite types and
`_Generic`. Type-C rules need the type of any expression that can hold a
Type-C value, and that is any expression.

**Target model.** Sizes of scalar types, the signedness of `char` and the
types behind `size_t`, `ptrdiff_t` and `wchar_t` are read from the
backend's predefined macros, obtained from the same compiler with the
options of the step that compiles the output. Preprocessing options such
as `-D` and `-undef` are left out: they cannot change the ABI of that
step, and `-D__SIZEOF_LONG__=4` would make the model lie. `typec` has no
target table of its own. The model also names the backend, Clang when
`__clang__` is defined and GCC otherwise, with its major version
(`__clang_major__` or `__GNUC__`). The compiler decides the constructs
whose types are unknown (below), and `typec` refuses a release older
than `Target.minimum_major_version`, the one statement of the oldest
supported releases. For Clang that is the first release that types C as
the front end does: Clang 19 gives an enumerator that `int` holds the
type `int` in an enumeration whose values `int` does not all hold, where
Clang 20 and GCC follow C23 6.7.2.2 (N3029) in every dialect and give
every enumerator the enumerated type. For GCC it is the oldest release
that a test host runs. *Provisional:* Apple numbers its Clang releases
on its own and is held to the same minimum, which only Apple clang 21
confirms; an Apple release at or above the minimum that types C as
Clang 19 does would settle it otherwise, and without one the minimum
stays.

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
prototype of its own and keeps one before it; and the composite of an
enumerated type and its compatible integer type, which is the enumerated
type in GCC and the integer type in Clang. With GCC as
the backend each of these has an unknown type (P21) wherever GCC's type
differs from Clang's, and the real part of a bit-field, which differs in
being an lvalue, has one too: the front end neither guesses GCC's type nor
refuses what GCC accepts, and the error at a point that needs the type
names the construct and says that GCC types it otherwise. One table,
`Backend_difference`, holds the constructs, what GCC does and a probe of
each, and decides for every place that types one. GCC 14 to 16 and
Clang 20 to 22 confirm every entry but the old-style definition and the
composite, which GCC 16 and Clang 21 to 23 confirm. One rule for the class replaces a policy
per construct: the front end models one compiler's typing, and the other
costs an unknown type where it differs, not a second model.
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
not the platform's headers. A marker that `typec` writes inside a file
that a marker with flag 3 opened carries flag 3 and no enter or return
flag, which keeps the exemption; without it the exemption would end until
the backend's next marker with flag 3. A header that only
`#pragma GCC system_header` makes a system header, and a region that GCC
marks as the expansion of a system macro, is not seen as one (2.4 owner
rule), so an edit there ends the exemption until the next such marker.

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
| `match` | A block: a pointer to the scrutinee, or a copy when it is not an lvalue or is volatile, atomic or declared `register`; a `switch` on the tag with a `case` for every constructor; a block per arm that declares the bindings and ends in a trap; `break`, `continue` and `return` unchanged; `default:` holding the trap. |
| Distinct type | A typedef. Casts are kept. A construct that asks whether two types are compatible, `_Generic` and `__builtin_types_compatible_p`, is answered by the front end where Type-C text compares a distinct type: one of the types compared (the controlling type or an association's, either operand) is or contains one. The selection keeps its controlling expression and every association, so the backend sees the names they use and the tags they declare outside the association type names, and is steered to the front end's choice: the type name of the association at position `i` becomes `char (*)[i]`, and the controlling expression `e` becomes `((void)(e), (char (*)[k])0)`, where `k` is the position of the selected association. Arrays of different lengths make these types pairwise incompatible, and `default` stays, as its position is no type name's. The builtin becomes `1` or `0`. C text compares the representation (10.2), and the backend answers. |
| Type application | The instance definition, once, at file scope before first use. |
| Generic function instance | A `static` function: the body's tokens, with each type parameter replaced by a typedef of its argument. |
| `try` | A temporary of the result type; a test of its tag; on `Err`, the active cleanups and a `return`; then the `Ok` field. |
| `defer` | *Provisional (P9).* The deferred statement is repeated, as written, at every exit from its scope, in reverse order; `return e;` becomes a temporary, the cleanups, and `return` of the temporary. Rule 8 of section 6 guarantees that each copy binds its names as the original does. |
| Slice index, `slice_sub` | A call to an internal inline function that tests and then indexes. |
| Checked-mode checks | Inline tests that trap. |

Identifiers the compiler invents begin with `__tc_`.

### 13.6 Diagnostics and debugging

- A diagnostic carries the file, the line, the source line and a stable
  code. Stable codes let tests and editors refer to a diagnostic without
  matching its text.
- A stable code is `TC` and four digits. It names a rule of this design
  that Type-C text breaks, or a construct that a later work package
  implements, and ends the diagnostic in brackets after the clause that
  states the rule, as GCC and Clang end a warning with its option:
  `file:line: text (design 4.2 rule 1) [TC0018]`. Each rule's code is
  written beside it in the one table of rules, which generates the
  catalogue of diagnostics; a code is never renumbered or reused.
- A refusal of C text carries no code: it states no rule of Type-C, and
  the C standard or the backend's own diagnostic names what is wrong.
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
| A generic function is valid for every instance | Every generic function, within the nesting limit of 3.5 | Nothing |
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
| P1 | `type`, `match` and the other new words are positional; `try` and `defer` are hidden by a declaration (2.3) | Stage 1 pilot: identifiers renamed and header macros broken by the port | As specified |
| P2 | An unqualified constructor wins over an ordinary identifier under a variant target type, and a typedef name keeps C's type-name readings (3.3) | Stage 1 pilot: any resolution that surprised its author | As specified |
| P3 | The tag is a C enumeration (10.1) | Stage 1: size of pilot data against hand-written C; debugger use | Enumeration |
| P4 | The `default` warning is off; there is no single-pattern test (4.2, 12) | Stage 1 pilot: share of matches with one `case` and a `default` | No new syntax; warning stays off |
| P5 | Bindings are non-modifiable copies; none by reference (4.1, 12) | Stage 1 pilot: sites that need in-place update | As specified |
| P6 | The owner of a private type is found by file name (9.2) | Stage 1 pilot with a module of several files | As specified |
| P7 | A `void` type argument removes the field (3.5) | Stage 2 implementation and pilot | As specified |
| P8 | `try` is limited to three positions (5.1) | Stage 2 pilot: rewrites the limit forced | As specified |
| P9 | `defer` is lowered by repeating the cleanup at each exit, which needs rule 8 of section 6 (13.5) | Stage 2: code size on the pilot; how often rule 8 rejects code | Repetition |
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
| P21 | A type that the front end does not compute is unknown, an error only where it is needed (13.3) | Typing bodies (0.9b) and the corpus: points that need an unknown type's properties | Unknown types stay |
| P22 | `typec`'s own failures exit with 80, 81 and 82, which no backend uses (13.2) | Corpus runs with GCC and Clang: a backend failure that exits with one of them | As specified |

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
block-item:            ... | type-declaration

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

statement:             ... | match-statement | defer-statement
                           | unsafe-block
match-statement:       "match" "(" expression ")" "{" arm+ "}"
arm:                   arm-label+ block-item+
arm-label:             "case" pattern ":" | "default" ":"
pattern:               identifier ("(" sub-pattern ("," sub-pattern)* ")")?
sub-pattern:           identifier | "_"
defer-statement:       ("defer" | "_Defer") statement
unsafe-block:          "unsafe" compound-statement
```

A type declaration with type parameters is an external declaration only.
An unqualified constructor is an ordinary identifier or call in the
grammar; 3.3 decides its meaning. Slice indexing uses C's subscript
syntax.
