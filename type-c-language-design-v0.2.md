# Type-C: C with ML-style types and opt-in checking

**Design proposal v0.2 — 13 November 2026**  
**Status:** proposed semantics and implementation plan, not implemented  
**Language name:** Type-C. The compiler command and source suffixes proposed below are provisional.

## 0. Executive design decision

Type-C is a conservative extension of C11 that retains C's operational model and adds the particularly useful abstractions of ML: algebraic datatypes, exhaustive pattern matching, distinct types, checked polymorphism, private constructors, result propagation, and later lexical regions and closures. Its first compiler is standalone and translates Type-C into ordinary C11. Plain C remains plain C, with unchanged ABI and semantics. A separately enabled checked subset can rule out specific classes of pointer and lifetime errors; it cannot make arbitrary foreign C memory-safe.

### 0.1 Guiding principles (normative for design reviews)

1. **Preserve C whenever C already expresses the operation clearly. Introduce new syntax only where existing C cannot express the feature elegantly.** This is the primary rule for Type-C. In particular, retain normal C declaration syntax, `if`, `for`, `while`, `switch`, `case`, `default`, `break`, `continue`, `return`, `goto` (subject to safe scope transitions), casts, pointer operators, struct/union syntax, and C function calls. Do not replace these with an ML/Rust/C++ spelling just for stylistic consistency.
2. **Extend rather than redefine.** Existing ordinary C11 constructs, including their control flow and expression evaluation rules, retain their meaning; Type-C extensions must explicitly document any new sequencing they introduce. When Type-C needs stricter semantics (e.g. no fallthrough between destructuring match arms), the departure must be narrow, documented, diagnosed, and justified by a concrete type-safety or correctness requirement. Standard `switch` is never changed.
3. **Use ML syntax selectively where C lacks an equivalent.** Closed sum types and destructuring patterns justify `type ... = | ...` and `match`. Nominal generic type arguments, checked error propagation, and explicit closures may justify their own syntax. Do not adopt ML's `let` expressions, curried function application, pervasive inference, or expression-oriented control flow by default.
4. **Keep operational costs visible.** No implicit heap allocation, required GC, hidden libc, exceptions, implicit runtime registry, or required linking library for basic features. Allocation and lifetime ownership remain explicit. Generated C is an inspectable compilation artifact.
5. **Add stronger guarantees without pretending arbitrary C is safe.** Variant construction, exhaustiveness, nominal typing, generic contracts, and module privacy are checked in Type-C. Pointer bounds/lifetime checking is opt-in and requires trusted boundaries; generated C and unchecked clients are not magically protected.
6. **Minimal new vocabulary and no machinery for its own sake.** Avoid classes, inheritance, C++-style templates, pervasive Rust-style borrow syntax, operator overloading, and gratuitous new operators. Prefer C scopes and statements over novel expression forms where they suffice.
7. **Design language semantics independently of compiler machinery.** The initial implementation may use a Clang semantic probe, but the language must not be shaped by limitations of a temporary rewriting strategy.

**Syntax-preservation test:** before accepting any feature, write the clearest ordinary C spelling for it. If that spelling already has the desired behavior and reasonable readability, Type-C should keep it. If the feature cannot be expressed safely or concisely in C, use the smallest extension that does the job. The `match` statement deliberately retains `case`, `default`, `break`, `return`, and `continue`; it adds patterns and exhaustiveness, not an entirely new control-flow vocabulary.

**Concrete syntax review (v0.2):**

| Need | Keep ordinary C | Add only what C lacks |
| --- | --- | --- |
| Multiway dispatch | `case`, `default`, `break`, `return`, `continue` | `match` for typed destructuring and exhaustiveness |
| Multiple labels, one body | Stacked `case` labels | Pattern compatibility checks for grouping |
| A value from a multiway branch | Declare/assign a local | Expression `match` deferred until a real need is demonstrated |
| Local allocation lifetime | `{ ... }` block, variable declaration | `region` capability, checked lifetime contracts |
| Modules | `#include`, C headers, ordinary function declarations | Optional checked `.tci` interface metadata |
| Generic type arguments | Familiar declarator forms and parentheses | `generic(T)` / `vector(T)` for type-safe parametrization |
| Error handling | `return`, normal C control flow | `result` and `try` for repetitive propagation |

**First useful release:** distinct types + closed variants + exhaustive statement-level `match` with C-style explicit termination, compiling an actual compiler IR module into C11. Do *not* start with a general ownership checker.

## 1. Surface language

### 1.1 Compatibility boundary

- `.c` and `.h`: interpreted as ordinary C by Type-C, normally passed through. ISO C11 is the normative baseline, with explicit GNU/Clang compatibility extensions as separately tested profiles. No existing C identifier becomes illegal in these files.
- `.tc`: extended C. New words such as `type`, `match`, `generic`, `try`, and `defer` have contextual or reserved meaning here, depending on the grammar. Tooling warns on collisions with existing macros; compatibility is not promised for source that already uses the same spellings.
- `.tci`: optional module interface. This is not a C header and is consumed by Type-C. An ordinary generated `.h` is the interoperability boundary for other C compilers.
- Existing `#include`, `#if`, `#define`, target compiler options, inline assembly, and linkage are not redefined; extended constructs may be restricted inside macro expansions in early releases.

The compiler command `typec` and suffixes `.tc`/`.tci` are provisional; the language name Type-C is not. Importing a `.tci` is initially done through `#include "ir.tci"` in Type-C source, and the driver substitutes metadata/generated declarations as appropriate. The module is selected by build metadata (or a source/interface pair); there is no new mandatory module/package syntax. A normal `.h` stays a normal C header. Do not add a parallel `import` keyword unless a demonstrated shortcoming of `#include`/interface metadata makes it necessary.

### 1.2 Algebraic datatypes

```c
type expr =
    | Number(long value)
    | Variable(str name)
    | Add(expr *left, expr *right)
    | Multiply(expr *left, expr *right);

expr x = expr.Number(42);
expr y = expr.Add(&x, &x);
```

`type E = | ...` declares one **closed, nominal, by-value datatype**. The compiler generates a tag and union representation. Constructor calls construct a value; they do **not** allocate storage. Recursive occurrences must be indirect (`expr *` or another finite representation). The compiler rejects infinitely sized types. Variant tags, storage, and constructor identities cannot be directly written in checked Type-C; pattern matching and well-defined constructors preserve the tag/payload invariant. This does not protect against unchecked C writes to the same object.

Rules:

1. Constructor names are resolved via expected result type or explicit `expr.Number(...)` qualification. No public global `Number` symbol is emitted. Type-qualified syntax is recognized only when the prefix denotes a type, not an ordinary object.
2. Every datatype value must be initialized by a valid constructor before it is read. Checked Type-C rejects reading uninitialized variants and rejects relying on arbitrary zero initialization unless the language explicitly defines a default variant.
3. `expr a = b` copies the representation as a C value. This does not deep-copy pointed-to objects. Mutable payload ownership follows the checked lifetime rules, when enabled.
4. `expr` has a complete target-dependent C layout. This representation is stable only relative to a documented Type-C ABI/version and target triple; it is not a serialized format.
5. Explicit tag values and a wire-format representation, if ever added, must be opt-in. Do not conflate ordinary variants with portable on-disk encoding.
6. In non-checked code, invalid tags constructed via legacy C must never be read by accessing an uninitialized union member. The generated match fallback calls a user-supplied trap hook or uses a target-specific trap; it does not invoke libc.

### 1.3 Exhaustive matching: a checked C-style `switch`

The statement form keeps C's `case`, `default`, and explicit `break`. Each reachable arm must leave the arm explicitly—by `break`, `return`, `continue` targeting an enclosing loop, or a permitted `goto` out of the `match`—rather than falling into the next arm. A case ending in `return` does not need `break`. Omitting the required transfer is a **compile-time error**, not an implicit break. Ordinary C `switch` semantics, including fallthrough, are unchanged.

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

For cases performing statements without returning, write `break` exactly as in C:

```c
void emit(const instruction *i)
{
    match (*i) {
    case Move(dst, src):
        emit_move(dst, src);
        break;

    case Load(dst, address):
        emit_load(dst, address);
        break;

    case Jump(target):
        emit_jump(target);
        break;
    }
}
```

**Control-flow rules:**

1. An unqualified `break` exits the nearest enclosing `match`, `switch`, or loop, exactly as in C. A `break` inside a nested `switch`/loop does **not** satisfy the outer match arm's termination requirement.
2. `continue` continues the nearest enclosing loop, as in C; `match` itself is not a loop. `return` exits the function. A permitted `goto` to a label outside the match exits the arm and performs any applicable `defer` cleanups. A `goto` may not enter another arm, jump into a pattern-binding scope, or bypass initialization/cleanup invariants.
3. Termination is a **control-flow graph property**, not a textual requirement that the last token be `break`. For instance `if (p) return a; else break;` satisfies it. Every reachable path must terminate the arm before a later arm's body.
4. Empty, stacked C-style case labels may share a body **when they introduce no bindings**. For example, `case None: case Empty: handle_empty(); break;` is legal. This is grouped dispatch, not execution fallthrough. Grouping arms with incompatible bindings is rejected; general OR-patterns can be designed separately if needed.
5. `default:` is the spelling for the catch-all arm, reusing C syntax. It is optional. On a closed datatype an explicit `default:` satisfies exhaustiveness but should produce a configurable warning because adding a constructor will no longer reveal affected matches. `_` remains a wildcard **inside** a constructor pattern, as in `case Number(_):`.
6. Each arm has its own lexical binding scope for destructured fields; no binding is visible in another arm or after the match. This small difference from C's label scoping is necessary to prevent crossing destructured payloads.
7. `case` labels are checked for overlap and reachability. `match` evaluates its scrutinee **exactly once**. If it is an lvalue, generated code may inspect it by pointer to avoid copying a large variant; otherwise, it materializes a temporary. Bindings copy selected payload fields unless an explicitly checked borrowed binding is supported later.

The compiler must prove all constructor alternatives are covered and diagnose missing or unreachable patterns. Ordinary C enums are not closed variants merely because their enumerators are listed: their underlying representation may contain other values. Initially, `match` accepts Type-C closed variants only. Pattern capabilities are staged: top-level constructor patterns and `_` first; then nested patterns, constants, and named fields such as `Add(.left = l, .right = r)`. Pointer patterns must check null before dereferencing. Guards, if ever supported, do not establish exhaustiveness unless another unguarded arm covers the same values.

**Example of grouped cases and explicit exit:**

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

Do **not** introduce an expression-valued `match` merely for ML-style aesthetics: a C local variable plus a statement-level `match` is usually clear and sufficient. An expression form remains a future experiment only if real examples show substantial value that cannot be expressed cleanly by ordinary C statements. This follows the primary guiding principle.

### 1.4 Distinct types

```c
type reg_id   = distinct uint32_t;
type block_id = distinct uint32_t;

reg_id r = (reg_id)3;
block_id b = (block_id)3;
r = b; /* error */
```

Plain `typedef` remains an alias. A `distinct` declaration makes a nominal identity, keyed by defining module and declaration. There are no implicit conversions to/from the underlying C type or another distinct type; explicit C-style casts mark crossings. Equality is defined for values of the same distinct type. Other arithmetic is not automatically granted: initial design requires explicit conversion or a declared derived operation, so distinct IDs do not accidentally behave like offsets. The dialect may erase the distinction to its scalar ABI, but plain C callers then lose the static check. A separate wrapper API can provide nominal-looking types to C at the cost of potentially different calling conventions.

### 1.5 Generics and constraints

```c
type vector(T) = struct {
    T *data;
    size_t len;
    size_t capacity;
};

generic(T)
T *vector_last(vector(T) *v)
{
    return v->len ? &v->data[v->len - 1] : NULL;
}

vector(int) numbers;
vector(expr *) nodes;
```

Generic bodies must be checked **once under abstract type variables**, not merely copied and compiled after substitution like C++ templates. For the initial model, an unconstrained `T` ranges over complete, sized, ordinarily copyable C object types; this permits assignment, taking addresses, and pointer arithmetic with a known element size. Arithmetic on values of `T`, hashing, ordering, and other non-universal operations require explicit constraints. Future affine/noncopyable types are excluded unless a generic is explicitly designed for them; copying such a `T` must require `copy(T)` or be forbidden. Constraints are declared explicitly for operations that are not available to arbitrary `T`:

```c
generic(K, V) requires(hash(K), equal(K))
result(void, map_error) map_put(map(K, V) *m, K key, V value);
```

`requires(...)` describes compile-time operation contracts, resolved statically. It does not imply trait objects, vtables, implicit runtime dictionaries, operator overloads, or hidden allocations. Avoid unconstrained template specialization tricks. There is one canonical compiled concrete specialization for each identity `(definition, type arguments, target, ABI version, compile-time options)`. Generics are not available to ordinary C callers until the project explicitly exports concrete specializations.

**Implementation warning:** pure monomorphization does not solve semantic checking. Building a typed intermediate representation and constraint solver is the principal engineering cost of this feature. The earliest generic implementation may deliberately support only type-safe generic containers and functions using a narrow, predeclared operation set.

### 1.6 Option, Result, `try`

```c
type option(T) = | None | Some(T value);
type result(T, E) = | Ok(T value) | Err(E error);

type parse_error = | EndOfInput | BadToken | OutOfMemory;

result(uint32_t, parse_error) read_number(reader *r)
{
    uint8_t tag = try read_byte(r);
    uint32_t n = try read_u32(r);
    if (tag != EXPECTED) return err(BadToken);
    return ok(n);
}
```

`option` and `result` are ordinary, compiler-recognized library ADTs, with concrete layouts. `ok`, `err`, `Some`, and `None` use expected-type resolution; users may qualify constructors explicitly. `try e` is an expression allowed only in a function returning `result(U,E)`. It evaluates `e` exactly once. On `Ok(v)` it evaluates to `v`; on `Err(e)` it returns `Err(e)` from the enclosing function after running applicable defers. The error type must match **exactly**; there is no implicit `From` mechanism or exception. Conversions are explicit:

```c
expr *node = try map_error(region_new(r, expr.Number(7)),
                           alloc_to_parse_error);
```

Initial `try` placement: a whole initializer, a whole assignment RHS, or a whole return expression. Nested `try` inside arbitrary call arguments, comma expressions, `&&`, `||`, and conditionals waits until typed control-flow lowering preserves evaluation order and short-circuiting. The language must choose and document the evaluation order of extended expressions rather than silently changing existing C expression behavior. A `result(void,E)` specialization supports success without a value.

No hidden error allocation or unwinding. C libraries that return integer error codes are adapted through ordinary wrappers.

### 1.7 `defer`

```c
FILE *f = fopen(path, "rb");
if (!f) return err(IoError);
defer fclose(f);

/* Transfer function is specified to consume ownership without closing here. */
take_ownership(f);
f = NULL;
```

A deferred statement runs when its enclosing lexical scope is exited normally, in reverse registration order, and refers to the **current variables at exit**, not copies captured when registered. This follows the direction of WG14's evolving Defer Technical Specification 25755. The return expression is evaluated before cleanup; defers cannot `return`, `break`, `continue`, or `goto` outside their own body. `return`, `break`, `continue`, and permitted `goto` through enclosing scopes execute active defers. `longjmp`, process termination, and asynchronous interruptions do not unwind deferred C statements. Checked code rejects unsafe nonlocal-jump paths across active cleanup scopes.

Early compiler restrictions: require `defer` inside a compound block and reject gotos that enter a defer's lifetime or re-enter a registration site without leaving the scope. This avoids an implicit dynamic cleanup stack. Later harmonize these constraints with the final TS. Loop-body scopes register defers separately on each iteration. Lower with deterministic flags and cleanup blocks; no hidden heap or libc.

### 1.8 Slices and strings

```c
slice(uint8_t) bytes = slice_from_array(buffer);
uint8_t first = bytes[0];
str text = str_from_literal("hello");
```

`slice(T)` is conceptually `(T *data, size_t len)`. It is bounds-checked in checked mode. `str` is an immutable byte slice and does **not** promise NUL termination or valid UTF-8; validation is a separate explicit operation. A zero-length slice may have a null data pointer. Bounds checking must occur before pointer arithmetic and must use overflow-safe arithmetic. Read-only `.len` access is possible, but checked code cannot forge an inconsistent slice by writing the raw fields independently.

Safe constructors from fixed arrays, checked slices, and trusted span-bearing APIs preserve bounds. Constructing from arbitrary `T *` and a count is an unsafe boundary: the compiler cannot infer allocation extent or lifetime from those two expressions. Slice bounds protect against spatial overrun, not use-after-free, data races, or concurrent mutation of backing storage. Checked slices carry a logical provenance/lifetime in type metadata; the C representation alone does not enforce it. Cross-ABI representation and ownership are documented, not guessed.

### 1.9 Derivation

Proposed standalone declaration:

```c
derive(eq, hash) token;
```

Only generate operations with well-defined fieldwise semantics. Never implement generic struct equality as `memcmp` because of padding and floating-point representation. Pointer fields use identity comparison by default only when explicitly permitted; recursive deep equality and hashing need a user-defined policy for cycles and recursion depth. `show`/printing is omitted from the freestanding core unless the caller supplies an output sink. Derived functions are deterministic, visible in generated C, and do not allocate silently.

### 1.10 Closures (later)

```c
int factor = 3;
func(int, int) scale = fun(int x) {
    return x * factor;
};
```

The intended C ABI is a code pointer plus an environment pointer. Non-escaping closures may use a stack environment. Escaping closures require caller-provided storage or a region, and the compiler must verify that captured values outlive that storage. A closure that captures a raw pointer is not made safe simply by copying the pointer. Ordinary C function pointers are supported for non-capturing functions; capturing closures do not implicitly convert to `qsort`-style callbacks without an explicit context adapter. No executable stack trampolines, hidden globals, reference counting, or heap allocation. By-value and by-reference capture rules and syntax remain open pending a lifetime-system prototype.

## 2. Privacy and modules

A `.tci` interface can declare:

```c
type instruction = private
    | Move(reg dst, reg src)
    | Load(reg dst, address src)
    | Store(address dst, reg src);

instruction make_move(reg dst, reg src);
```

Within the defining implementation, constructors are permitted. Outside, matching and reading matched fields are permitted, but constructing arbitrary values is forbidden in checked Type-C. The type and field layout can be visible, so a C-generated header can provide by-value interoperability. **The privacy guarantee applies to checked Type-C clients**; plain C clients can forge any representation exposed by a header. Exports can choose opaque pointer handles for stronger C-level encapsulation.

An `abstract` type declaration exposes only a name and opaque pointers to C. A hypothetical *opaque-by-value* type is not part of the initial portable C ABI: size and alignment alone are insufficient for all platform aggregate calling conventions. Later, source-level checked opacity might work when the private representation is still emitted to C translation units, with the limitations made explicit.

Interfaces contain type IDs, constructor sets, field types, privacy, generic constraints and definitions, region/effect summaries, and a version hash. They are checked against the implementation. `.tci` files are not raw textual C headers. Generated ordinary C headers are separately produced and can explicitly export concrete generic instantiations. Module boundaries do not introduce a new runtime or dynamic module loader.

## 3. Runtime representation and C ABI

1. Variants: a fixed-width (`uint32_t`) discriminant followed by a C union of payload structs, aligned naturally by the target C compiler. The exact tag mapping and layout are emitted in a generated header; `sizeof`, `_Alignof`, and offsets are verified in ABI tests. The implementation is free to optimize entirely private, non-ABI-visible variants in a future ABI version, not silently within v1.
2. Constructors: static inline functions for monomorphic cases, or concrete out-of-line functions where addressability/ABI needs require. They initialize both discriminant and active payload. No heap allocation.
3. Match: switch on the discriminator, with a compiler-emitted invalid-tag trap for corrupted values. Pattern bindings reference or copy the active payload safely after tag discrimination. Source-level `break` keeps C semantics and becomes a transfer to the end of the match; the translator must not silently supply missing `break` statements. Source `default:` is optional; the trap is an implementation fallback, not proof of exhaustiveness.
4. Distinct types: same scalar underlying ABI in Type-C-generated C where declared as ABI-erased; nominal checking exists only in Type-C. Public generated C headers document that erasure. Wrapper APIs are separate.
5. Generic types/functions: specialized C names are deterministic and collision-resistant; public generic entities do not have a magic universal C ABI. Compile the specialization in the defining module context, with dependency-aware caching.
6. `option`, `result`, `slice`: C value structs with documented target-specific calling conventions and layouts. C calling code compiles against the generated header for the same target and ABI version.
7. Functions: non-generic exported functions retain conventional C function names where possible. Explicit C-linkage export declarations avoid mangling surprises. Version changes to exported C layouts are ABI-breaking and must be reported.
8. Generated symbols: use a strictly reserved compiler-generated prefix and a canonical signature hash. Source code may not define conflicting generated names. Metadata carries source symbols, not just opaque hashes.
9. No object format serialization guarantees are implied by in-memory C struct compatibility; explicit serializing APIs are necessary.

ABI compliance is tested on macOS/AArch64, Linux/x86-64, Linux/AArch64, and eventually freestanding ARM. C11 `_Static_assert` verifies generated layout assumptions; C test callers and Type-C code call each other in both directions.

## 4. Opt-in checking and the memory model

### 4.1 Two modes, not two execution languages

Default Type-C: new ADTs, private constructors, distinct types, and generics are always type-checked, but legacy C memory operations remain available. Strong lifetime guarantees are **not** claimed. Checked Type-C (e.g. `#pragma typec checked` in a module) rejects operations that violate tracked nullability, slice validity, and region lifetime rules. `unsafe { ... }` may be used for carefully delimited foreign operations; its results are not automatically certified as checked values.

A checked module's guarantees are conditional on the correctness of trusted FFI contracts and the absence of unchecked aliases that mutate its protected objects. `unsafe` functions must establish postconditions before returning checked values. No thread/data-race freedom is promised. Signed overflow, arbitrary type punning, and unrelated C undefined behavior remain distinct concerns to be diagnosed separately or handled by sanitizers.

### 4.2 Initial region model: lexical, explicitly backed

Prefer an **ordinary C block and variable declaration** to a new `region r(...) { ... }` statement. The region handle is a compiler-recognized, non-copyable capability in checked code; the built-in constructor safely derives bounds and lifetime from a real local array:

```c
result(void, alloc_error) use_scratch(void)
{
    {
        unsigned char workspace[16384];
        region scratch = region_from_array(workspace);
        expr *e = try region_new(&scratch, expr.Number(42));
        consume(e);
    }
    return ok();
}
```

This is a lexical bump allocator over explicitly provided storage, using only C's familiar declaration/block syntax. `region_from_array` is a **Type-C compiler-checked operation**, not an unrestricted `(ptr, len)` convenience function: it accepts an actual array or an already trusted exclusive buffer, records the storage's extent/lifetime, and rejects a forged pointer in checked mode. `region_new` is fallible and returns `result(T *, alloc_error)`; an enclosing function with another error type must explicitly map the error. Each region variable acquires a compiler-tracked lifetime tied to its lexical scope, bounded by the lifetime of its backing storage. References cannot escape beyond that scope. The region checks alignment and capacity, and does not invoke `malloc`. Leaving the region scope invalidates pointers even though no destructor call is necessary for a caller-owned bump buffer; whether bytes are poisoned is a debug-mode choice. An explicit reset/release operation is forbidden while tracked references might exist.

**Important:** making this sound requires exclusive access to the storage backing the region for its active duration or a trusted contract. An arbitrary `char *` supplied by foreign code does not establish that exclusive access. Start with locally declared fixed arrays and controlled region-owned buffers. General-purpose resettable shared arenas are a *later* extension, not part of the initial claim.

### 4.3 Outlives and inference

Internally, a tracked pointer has a region identifier and nullability/bounds facts; these qualifiers can be erased in ordinary C code generation. The checker solves a conservative partial order `outlives(A,B)`. A pointer into `A` may be stored in an object living in `B` only if `A` outlives `B`. This rule is transitive through ADT payloads, structs, arrays, slices, and closure environments. A pointer returned from a region-allocating function requires a summary relating the return to a parameter, e.g.:

```c
expr *parse(region *output, str input) returns(output);
```

`returns(output)` is proposed C-like interface syntax, erased by code generation. It specifies a lifetime bound, not a heap allocation. Here `output` designates the region capability pointed to by the argument, not a copied region handle. The checker also verifies that any pointers embedded in the returned object do not refer to regions that expire sooner. A parser cannot store a borrowed input substring in a long-lived AST unless it can prove the input outlives the AST or explicitly copies the text into the AST's region.

Within function bodies, infer local relationships. At module boundaries, require exported lifetime/effect summaries, potentially inferred and then written back into interfaces. Explicit summaries are necessary for separately compiled foreign functions. Do not promise complete interprocedural lifetime inference from arbitrary C.

### 4.4 Why regions do not imply full ownership safety

Lexical region checking prevents many dangling-region errors, but not individual invalid frees, arena resets, external `realloc`, forging pointer extents, mutating shared tag/payload storage, mutable alias conflicts, or thread races. A checked region deliberately forbids resetting/destroying while references exist. Arbitrary `free` and raw pointer arithmetic on tracked region pointers are rejected. Checked copying of values whose ownership is affine is restricted. Controlled legacy interfaces are marked unsafe or wrapped by certified APIs.

Future unique ownership can build on limited affine types and move semantics, but a full Rust-style borrow checker is explicitly outside the initial project. For graph-heavy compiler IR, region allocation and immutable references should be the default pattern.

## 5. Compiler architecture

### 5.1 Dependency and pipeline

```text
.tc + .tci + C headers + build flags
      |
      v
C preprocessor with source/macro locations (target-aware)
      |
      v
Extension island parser + C semantic probe (prototype)
      |
      v
Typed Type-C IR + public-type metadata (mature compiler)
      |
      +--> nominal checks, pattern exhaustiveness, constraints,
      |     privacy, dataflow, lifetime/effects
      v
Control-flow lowering and generic specialization
      |
      v
C11 emitter + generated .h + .tcmeta + source map
      |
      v
GCC/Clang/compatible C compiler --> ordinary objects
```

The initial prototype parses new constructs after preprocessing and emits a temporary valid-C **probe** translation unit: extended datatype declarations are lowered into skeleton C structs, and `match` scrutinees are exposed to Clang as typed expressions. Clang's parsed AST supplies the C type information. A second pass then emits the final C. This is a *prototype technique* and not the architecture on which to base all future features. Complex generics and `try` embedded in arbitrary expressions need a genuine typed Type-C expression/statement IR. Set a deliberate transition gate rather than growing an increasingly fragile token-rewriter indefinitely.

A Clang fork is **not** required initially. Clang's stable `libclang` C interface provides convenient inspection but not a general new-syntax parser. `LibTooling` is powerful but C++-based and version-sensitive. A standalone front end written in C17 can call a target Clang subprocess for preprocessing/probe semantics and emit C11; a small optional C++ libTooling helper is feasible but not a requirement. Supporting a GCC final backend does not remove this Clang dependency in the prototype. Where the selected preprocessor and semantic-probe compiler differ, target built-ins, macros, and GNU extensions may not mean the same thing. Start with a Clang/Clang profile, then explicitly qualify and test a Clang-probe/GCC-final profile. A full independent C parser is not a sensible MVP commitment.

### 5.2 Preprocessing, headers, and macro hygiene

The extension compiler sees target-specific preprocessed tokens with provenance (`spelling`, `expansion`, and `include` locations). It must honor conditional compilation and macro expansion *once*, not independently preprocess the generated source under a changed macro environment. Generated C can be emitted in a fully expanded form for semantic faithfulness; `--emit-c=compact` is a later source-preserving mode that preserves original includes when mechanically safe.

In early releases, reject extended constructs split across independent macro expansions if they cannot be given unambiguous source spans. Macros may expand to expressions and normal C declarations used *within* extended constructs. Advanced diagnostics must show both a macro expansion site and its defining location. Preprocessor dependencies are recorded for incremental builds.

Plain system headers are handled by the selected C toolchain; standard library declarations are not reimplemented. GCC/Clang extensions are captured in explicit tested compatibility profiles. Different target triples, include paths, macros, and C ABI flags produce different cached semantic artifacts. `volatile` is not a synchronization primitive: matching a concurrently mutated tagged value is not proven safe. Snapshotting an atomic value or externally synchronizing is a separate concern.

### 5.3 Typed IR and checker

The mature internal representation needs only the semantic C-like layer relevant to extensions, not a machine-independent optimizer:

```text
Type = CPrimitive | CPointer | CArray | CRecord | CUnion | CEnum
     | Distinct(id,repr) | Variant(id,args) | GenericParam(id,requirements)
     | Slice(T,lifetime) | Function(signature,effects)

Expr = CExpr | Constructor | Try | GenericCall | Closure | MatchExpr (experimental only)
Stmt = CStmt | MatchStmt | Defer | UnsafeScope  (region tracking attaches to C declarations/scopes)

Metadata = module identity, source spans, ABI version, private/public,
           generic signatures/bodies, effect/lifetime summaries
```

The checker must preserve C integer promotions, qualifiers, address spaces, `volatile`, `_Atomic`, `restrict`, `_Generic`, ABI-affecting attributes, and target-dependent layout when extended expressions interact with ordinary C. Initially delegate these to Clang; do not create subtly divergent rules for C constructs. Generic abstract operations and lifetime rules are checked by Type-C.

### 5.4 Lowering semantics

- **Constructors:** ordinary initialized structs, with active payload initialized and tag set. A constructor must not evaluate an argument twice.
- **Match:** evaluate the scrutinee once. Use a switch or decision tree for nested patterns. Preserve each explicit C `break`, `return`, `continue`, and permitted `goto` and lower their targets correctly; do not insert an implicit arm-ending break. Missing explicit exits are type/control-flow errors. Stacked binding-free labels may share one body. No source `default` is necessary for closed-variant exhaustiveness; an invalid-tag trap protects the unchecked boundary.
- **Try:** extract success into a temporary; on error, materialize the error return, then transfer through active cleanup scopes. Exact error types, no implicit conversion.
- **Defer:** generate per-scope cleanup labels/flags; evaluate the return value before cleanup; reverse registration order. Forbid control-flow edges that invalidate the static cleanup representation.
- **Generic:** type-check a generic under abstract type parameters; then specialize its typed IR and lower to ordinary C. Deterministic names; owner-module compilation and per-target cache.
- **Slice:** lower a checked subscript to a bounds test and a pointer operation, never pointer arithmetic before validating the index. Permit optimizer elimination only with sound proofs. Provide a no-libc failure hook, preferably a target trap.
- **Region:** lower to explicit allocator state and caller-provided storage; no implicit malloc. Build-time or optional runtime debug checks for region invalidation and capacity.
- **Closure:** lower to `(code pointer, environment pointer)` with a typed, verified capture environment; require caller storage when escaping.

### 5.5 Separate compilation and generic specialization

The compiler driver builds an interface dependency graph. Each module produces `.tcmeta` containing a canonical serialized type graph, exported contracts, generic typed IR or reproducible specialization recipe, source hashes, and ABI options. A consumer requesting `vector(expr *)` records an instantiation request. A specialization unit is generated *in the defining module's context*, allowing private implementation access without exposing it to the consumer. The driver deduplicates requests globally and compiles each concrete specialization once. Avoid weak symbols, arbitrary link-order dependence, and post-link code generation.

Library-only use and ordinary non-Type-C builds need an explicit export list of concrete specializations. Generated `.h` declares precisely those concrete types/functions. The build interface may later support Ninja/CMake, but an initial `typec` driver should be able to compile a small multi-file project unaided.

### 5.6 Debugging and diagnostics

Source locations are first-class IR fields. Emit `#line` for source lines and a sidecar source map for columns, generated temporaries, macro expansions, and variant-field bindings. Clang/GCC errors in generated code must be rewritten to user-source spans where possible; internal compiler errors never masquerade as a user C error. `typec --emit-c` and `typec --explain-lowering=<span>` are essential. Full source-variable-aware DWARF for every lowering is not promised by `#line` alone; first target correct line stepping and inspectable temporaries.

Warnings: non-exhaustive and unreachable matches and missing explicit arm termination (errors), default-masks-future-variants, unchecked slice creation, unsafe boundary crossing, accidental distinct-type conversion, escaping region pointer, unverified FFI summary, and overly-large generic specializations. Stable error codes enable tests and editor integration.

## 6. Problems that cannot be hand-waved

**C ABI versus opacity.** A representation-visible C struct can always be forged by plain C. An incomplete type provides stronger encapsulation but not portable by-value use. Pointer-to-storage adapters can preserve allocation control but change calling conventions. Type-C guarantees privacy only in checked Type-C clients.

**Region-backed buffers.** A `region` initialized from arbitrary `char *` cannot prove ownership of the backing buffer. Start with local arrays or trusted exclusive capabilities. General shared arenas need an affine capability or explicit unsafe contract.

**Arbitrary legacy calls.** A legacy function may free, save, modify, or longjmp through pointers. Without trusted summaries, checked Type-C must reject or treat calls as unsafe, not pretend that it has proved anything.

**C evaluation order.** Rewriting `f(try g(), h())` may introduce sequencing not specified by C, or accidentally evaluate things twice. Restrict the grammar first; later define a typed normalization with precisely specified behavior.

**Generic type checking.** Specializing C text after the fact is not sufficient. Operations on unconstrained type variables must be illegal; constrained generic bodies must be checked before callers instantiate them.

**Memory representation.** C bitfields, `_Atomic`, packed structs, flexible array members, unaligned members, volatile MMIO, and target-specific calling conventions cannot be reconstructed from `sizeof` alone. Delegate plain C layout to the target compiler, and avoid new guarantees around unsupported extensions.

**Pointer provenance.** A two-word slice does not prove that an arbitrary pointer refers to an allocation of a given extent. Address arithmetic can be out-of-bounds even before dereferencing. The checked subset must conserve provenance facts or mark their reconstruction unsafe.

**Security claim.** This is not a replacement for Rust safety, nor a proof against arbitrary C undefined behavior. Restrict claims to features and code areas actually checked, and validate assumptions with sanitizer/fuzzer testing.

## 7. Staged engineering plan and acceptance gates

The milestones are ordered to get an actual tool and real compiler IR code running quickly. Estimates are intentionally omitted: each gate should be measured empirically against implementation effort and user benefit.

### M0 — Toolchain vertical slice

**Build:** `typec` driver; `.tc` recognized; C11 pass-through; target-specific preprocessing; source locations; `--emit-c`; generated C compiled by both Clang and GCC; basic dependency files; one freestanding `-nostdlib` test. Start with a standalone C17 implementation and external Clang for C semantics.

**Exit:** a substantial ordinary C11 test corpus compiles with identical runtime behavior and ABI when passed through Type-C; macro paths and compiler diagnostics map correctly. No hidden runtime library. This gate measures whether the toolchain premise works.

### M1 — Nominal types and ADT constructors

**Build:** `type X = distinct T;`, `type X = | ...`, recursive pointers, constructor resolution, initialization checks, generated C tagged structs, public C header for a single module; C representation tests.

**Exit:** an actual instruction/node representation from a compiler can replace a handwritten tag/union without unsafe casts; invalid constructors and accidental distinct-type mixing fail compilation; optimized generated code matches straightforward C.

### M2 — Statement `match` and private variants

**Build:** C-style `match` with `case`, `default:`, mandatory explicit `break` or another terminating control transfer, exhaustive checking, wildcard and binding patterns, stacked binding-free labels, no implicit fallthrough, source spans, match lowering to switch, basic private constructor restrictions, `.tci` interface check; nested patterns only if prototype scope permits.

**Exit:** change a test IR by adding a variant and verify all affected matches fail with precise diagnostics. Deliberately omit `break` after an arm with a reachable end and verify an error. Verify `return` and `continue` are valid exits, an inner loop `break` does not exit the `match`, `default:` hides future variants with a warning, and stacked binding-free labels share a body. Exercise public-private construction from two modules and a plain C caller. This is the **first useful public release**.

### M3 — Structured error control and typed lowering

**Build:** standard `option`/`result` types, initial `try` restrictions, `defer` aligned with the Defer TS as far as feasible, typed control-flow IR, cleanup labels and flags, exact error propagation, nested branch/loop tests; no general generics yet except built-in fixed shapes required for result/option.

**Exit:** a parser or binary reader written in Type-C has one error path, no leaked resources on normal exits, no hidden allocations, and generated control flow passes sanitizer and fault-injection tests. Tests cover `return`, `break`, `continue`, conditionally executed defer, and rejected gotos.

### M4 — Parametric generics and multi-file builds

**Build:** `generic(T)` and type application `vector(T)`; constrained type checking; monomorphization; cross-module metadata; owner-context specialization; deduplication; deterministic names; explicit export list for plain C.

**Exit:** a real generic vector/map-like library compiles in separate modules and runs with multiple element types; all generic bodies are checked once; invalid operations on unconstrained types are rejected at definition time; clean and incremental rebuilds produce identical code and no duplicate linker symbols.

### M5 — Slices, safety mode, and lexical regions

**Build:** `slice(T)`, `str`, safe array-to-slice conversions, dynamic bounds checks, checked-mode pragma, unsafe boundaries, basic nullability, lexical regions over explicit storage, fallible typed allocation, local outlives analysis, public `returns(region)` summaries, trusted C API contracts.

**Exit:** negative tests are rejected for slice forging, use-after-region-scope, storing short-lived pointers in long-lived objects, and unsafe external calls. Known-safe parser cases compile without unexpected heap allocation. ASan/UBSan tests verify dynamic guards; freestanding tests verify no libc dependency.

### M6 — Advanced compiler ergonomics

**Build:** nested pointer patterns, named fields, derived equality/hash (with explicit policies), better generic constraints, source-aware editor support, optimized bounds checks, improved module abstraction. Consider expression-valued `match` only if a C-statement-based pilot demonstrates a real ergonomic deficit.

**Exit:** sustained use on a compiler's IR/AST modules materially reduces handwritten casting, switch boilerplate, error handling, and special-purpose container macros while preserving comparable performance.

### M7 — Closures and advanced memory checking (conditional)

**Build:** non-escaping `fun` closures, precise capture semantics, explicit environment storage for escaping closures, bounded affine ownership/region capabilities if warranted; consider dynamic regions only after a correctness and ergonomic review.

**Exit:** visitor/fold callbacks work without hidden allocation and cannot escape with dangling captures. No requirement to add a full borrow checker or GC if the measured benefit is weak.

## 8. Quality and test strategy

- Golden positive/negative compilation tests, including source-location snapshots and type-error codes.
- Differential execution tests comparing generated code against handwritten C reference implementations for variants, `match` (including explicit `break`/`continue` and nested `switch`/loops), `try`, and `defer`.
- Property tests for constructors and nested matching, exhaustiveness algorithm invariants, generic specialization identity, and slice subrange arithmetic.
- Parser fuzzing (including malformed/hostile macro expansions, deeply nested types, and macro provenance); generated C compiled with `-Wall -Wextra -Wpedantic` where applicable.
- ASan/UBSan and target-specific fuzzing of generated code. Freestanding link checks inspect undefined symbols to prove no hidden malloc/libc.
- ABI conformance tests with C callers, different translation units, compiler optimization levels, and target triples.
- Microbenchmarks: switch dispatch, constructor cost, generic vector operations, `try` fast/error paths, bounds check overhead, compilation time and code size. No universal "zero-cost" claim; checked slices and checked dynamic operations have costs.
- Real pilot: one compiler IR module first, then a parser/reader, and finally a freestanding/embedded component. Record code size, runtime, binary size, error count, and diagnostics friction relative to C.

## 9. Explicit non-goals, and decisions reserved for experiments

Not in the initial language: GC, exceptions, classes, inheritance, implicit conversion machinery, overloaded user operators, C++ templates, Rust traits/impl, async runtimes, mutable-borrow inference across arbitrary legacy code, a package manager, a new machine-code backend, and magical ABI-free opaque values.

Experiments still needed: (1) exact naming/grammar for type-qualified constructors and pointer patterns; (2) whether expression-valued `match` justifies *any* new syntax after statement-level `match` is exercised on real code (it is **not** in the core plan); (3) whether to expose `returns(region)` in source or only in `.tci` metadata; (4) how much generic type checking can use Clang as a probe before a typed frontend becomes necessary; (5) whether optional `unsafe` syntax is preferable to an explicit trusted API boundary; (6) capture semantics and closure value representation; (7) how to preserve source-level debugging across large generated C files.

## 10. Revision notes for v0.2

- Adopted the **Type-C** name. Proposed tool name is `typec`, source/interface extensions are `.tc` and `.tci`, and generated semantic metadata uses `.tcmeta` (all provisional except the language name).
- Made **preserve familiar C syntax** the foremost design principle, including a concrete acceptance test for future syntax proposals.
- Made statement-level `match` C-shaped: explicit `break` or another exiting transfer is required, `default:` replaces a novel catch-all arm spelling, and binding-free `case` labels can be stacked. Ordinary `switch` continues to permit fallthrough.
- Removed expression-valued `match` from the planned core and made it a later evidence-driven experiment.
- Replaced the proposed region-specific block with ordinary C scopes and a region declaration over explicit storage; region capabilities still need special typing rules.
- Updated compiler lowering, milestone gates, and negative tests to enforce these decisions.

## 11. Primary research references

1. [Cyclone manual, including datatypes, matching, regions, polymorphism and C interop](https://www.cs.cornell.edu/Projects/cyclone/online-manual/) — most directly comparable historical language design.
2. [C∀ source and compiler driver](https://github.com/cforall/cforall) and [research papers](https://cforall.uwaterloo.ca/papers) — checked polymorphism, constraints, and C translation.
3. [Cake manual](https://cakecc.org/manual.html) — source-to-source C frontend, ownership annotations, `_Defer`, and target-specific C output; review licensing before code reuse.
4. [Clang tooling interface selection](https://clang.llvm.org/docs/Tooling.html) — practical tradeoffs among libclang, plugins, and LibTooling.
5. [Clang bounds-safety model and status](https://clang.llvm.org/docs/BoundsSafety/index.html) — pointer extents and C ABI-compatible annotations; upstream rollout still incomplete as of 2026.
6. [Checked C project](https://www.checkedc.org/) — incremental bounds checking and C interoperability.
7. [WG14 project listing: TS 25755](https://open-std.org/jtc1/sc22/wg14/www/projects.html) and [historical N3927 defer paper](https://www.open-std.org/jtc1/sc22/WG14/www/docs/n3927.htm) — defer is now on a dedicated TS track and the TS supersedes that paper.
8. [OCaml interfaces](https://ocaml.org/docs/modules) and [private variants](https://ocaml.org/manual/4.05/extn.html) — the abstraction model.
9. [C3 specification](https://c3-lang.org/implementation-details/specification/) — contemporary systems-language comparison for generics and defer.
10. [LLVM source-level debugging](https://llvm.org/docs/SourceLevelDebugging.html) — source-location and debugger design considerations.
11. [Clang lifetime safety analysis](https://clang.llvm.org/docs/LifetimeSafety.html) — useful examples of lifetime contracts and what purely local inference cannot establish.

**Recommendation:** implement M0-M2 as one sharply defined project, release it, and evaluate the syntax on real compiler code before broadening the language. Design the metadata and IR for later checking, but do not prematurely implement the full memory model. This project succeeds if it makes ordinary C compiler code substantially clearer while keeping every operational cost obvious.
