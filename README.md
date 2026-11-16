<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/readme.t checks the examples of this file on Clang and GCC:
test/run/readme.sh says how the blocks are marked.
-->

# Type-C

Type-C is C11 with the types C is missing: variants checked by `match`,
distinct types for ids and units, and generic types. Its compiler,
`typec`, takes the command line of `cc`, turns Type-C into C that you
can read, and hands that to your C compiler.

You adopt it one file at a time, with no rewrite: rename one `.c` file
of your program to `.tc`, build with `CC=typec`, and use the new types
in that file where they help. The file keeps its meaning
([the fine print](#adopting-one-file)), and everything else stays as it
is: your headers, your other C files, your libraries, your debugger and
your ABI. Your build system needs a rule that compiles a `.tc` file,
and the fine print lists the few options that such a file refuses.
There is no runtime, no library to link and no hidden allocation;
nothing is added at run time but the checks of the Type-C that you
write.

Type-C is early: the examples below work today, and the rest of the
language is designed but not built yet ([Status](#status)).

A tagged union in C, with two bugs:

<!-- file: shape.c -->
```c
enum shape_kind { CIRCLE, RECT, TRIANGLE };

struct shape {
  enum shape_kind kind;
  union {
    struct { double r; } circle;
    struct { double w, h; } rect;
    struct { double b, h; } triangle;
  } u;
};

double area(struct shape s) {
  switch (s.kind) {
  case CIRCLE:
    return 3.14159 * s.u.circle.r * s.u.circle.r;
  case RECT:
    return s.u.rect.w * s.u.circle.r;  /* wrong member */
  default:                              /* TRIANGLE forgotten */
    return 0;
  }
}
```

```console
$ cc -std=c11 -Wall -Wextra -c shape.c
```

The same in Type-C. Each field belongs to its case, so the wrong-member
read cannot be written, and the forgotten case stops the build (with
exit status 80, shown in brackets):

<!-- file: area.tc -->
```c
type shape =
  | Circle(double r)
  | Rect(double w, double h)
  | Triangle(double b, double h);

double area(shape s) {
  match (s) {
  case Circle(r):
    return 3.14159 * r * r;
  case Rect(w, h):
    return w * h;
  }
}
```

```console
$ typec -std=c11 -Wall -Wextra -c area.tc
typec: area.tc:7: the match does not cover the constructor 'Triangle' of the variant 'shape' (design 4.2 rule 1) [TC0018]
[80]
```

C's `-Wall` warns of a forgotten enumerator only in a `switch` with no
`default`, and only when the kind has an enumeration type; a `default`
written for a kind that is none of the three, or an `int` kind, hides
it. Nothing in C catches the wrong-member read. A `match` needs no
`default`: it stops the program on such a value, and a case added
later is an error at every `match` that misses it.

## One file of an existing program

A small C program: `main.c` calls `calc.c` through `calc.h`.

<!-- file: calc.h -->
```c
/* Applies a line such as "add 5" or "neg" to *total: 0 when it
   knows the line, else -1. */
int calc_apply(const char *line, long *total);
```

<!-- file: main.c -->
```c
#include <stdio.h>
#include "calc.h"

int main(void) {
  const char *lines[] = {"add 5", "neg", "add 2", "mul 3"};
  long total = 0;
  for (int i = 0; i < 4; i++)
    if (calc_apply(lines[i], &total) != 0)
      printf("unknown: %s\n", lines[i]);
  printf("%ld\n", total);
  return 0;
}
```

<!-- file: calc.c -->
```c
#include <stdlib.h>
#include <string.h>
#include "calc.h"

int calc_apply(const char *line, long *total) {
  if (strncmp(line, "add ", 4) == 0) {
    *total += strtol(line + 4, NULL, 10);
    return 0;
  }
  if (strcmp(line, "neg") == 0) {
    *total = -*total;
    return 0;
  }
  return -1;
}
```

```console
$ cc -Wall -Wextra -c main.c calc.c
$ cc main.o calc.o -o calc
$ ./calc
unknown: mul 3
-3
```

`calc.c` becomes `calc.tc`, which parses a line into a variant and
matches on it. It still includes `calc.h`, and `calc_apply` keeps its C
type, so `main.c` and `calc.h` do not change:

<!-- file: calc.tc -->
```c
#include <stdlib.h>
#include <string.h>
#include "calc.h"

type command = | Add(long n) | Neg | Unknown;

static command parse(const char *line) {
  if (strncmp(line, "add ", 4) == 0)
    return Add(strtol(line + 4, NULL, 10));
  if (strcmp(line, "neg") == 0)
    return Neg;
  return Unknown;
}

int calc_apply(const char *line, long *total) {
  match (parse(line)) {
  case Add(n):
    *total += n;
    return 0;
  case Neg:
    *total = -*total;
    return 0;
  case Unknown:
    return -1;
  }
}
```

`typec` compiles `calc.tc` to an ordinary object. The C compiler links
it with the `main.o` of the C build, which is not even recompiled:

```console
$ typec -Wall -Wextra -c calc.tc
$ cc main.o calc.o -o calc
$ ./calc
unknown: mul 3
-3
```

A command added to `command` later, such as `Mul(long n)`, stops the
build at every `match` that does not handle it.

In a build, `CC=typec` compiles `main.c` and every other C file as the
C compiler does, since `typec` hands them to it untouched. The build
also needs a rule for the `.tc` file, as make has none built in: in a
GNU Makefile, `%.o: %.tc` with the command
`$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<`, and in other build systems
their own form of it. Documented rules for make,
ninja and CMake are plan package 4.3, not done yet.

## A short tour

The cases of a variant are its *constructors*, as the messages of
`typec` call them.

**Ask about one case.** `if (case ...)` tests for one case and binds its
fields. Outside it and `match`, Type-C code cannot name a field at all.

<!-- file: token.tc -->
```c
type token = | Number(long value) | Name(const char *text);

long number_value(token t) {
  if (case Number(value) = t)
    return value;
  return 0;
}
```

**No fall-through.** An arm of a `match` that can run into the next one
is an error: it ends in `break`, `return`, `continue`, `goto` or a call
that does not return.

<!-- file: cost.tc -->
```c
type op = | Load(int address) | Add(int operands);

int cost(op o) {
  int c = 0;
  match (o) {
  case Load(_):
    c = 2;
  case Add(n):
    c += n;
    break;
  }
  return c;
}
```

**Ids that do not mix.** A distinct type has the representation of
another type but does not convert to it, or from it, without a cast.
Swapped arguments become an error:

<!-- file: ids.tc -->
```c
type user_id = distinct unsigned;
type group_id = distinct unsigned;

int is_member(user_id u, group_id g);

int may_read(user_id u, group_id g) {
  return is_member(g, u);  /* swapped */
}
```

**Generic types instead of `void *`.** `list(int)` and `list(double)`
are different types, so a list of prices cannot reach a function that
sums integers. Each `list(int)` names the same type, wherever it is
written.

<!-- file: list.tc -->
```c
type list(T) = | Nil | Cons(T head, list(T) *tail);

int sum(list(int) l) {
  int total = 0;
  while (case Cons(head, tail) = l) {
    total += head;
    l = *tail;
  }
  return total;
}

int sum_prices(list(double) prices) {
  return sum(prices);
}
```

**A value that may be missing.** `option(T)` is a generic variant that
every Type-C file has: `None`, or `Some` of a value.

<!-- file: find.tc -->
```c
#include <stddef.h>

option(size_t) find(const int *items, size_t n, int wanted) {
  for (size_t i = 0; i < n; i++)
    if (items[i] == wanted)
      return Some(i);
  return None;
}
```

**Types that only their owner can make.** A `private` type can be made
only in its interface and in the source file of the same name, here
`port.tc`; other files use ports and read their value. So, short of C
code or reinterpreted storage ([limits](#what-typec-reports)), every
port but the zero value, `{0}`, comes from `port_parse`.

<!-- file: include/port.tci -->
```c
#include <stdint.h>

type port = private distinct uint16_t;

port port_parse(const char *text);  /* {0} when text is no port */
```

<!-- file: server.tc -->
```c
#include <stdlib.h>
#include "port.tci"

port port_from_argument(const char *argument) {
  return (port)atoi(argument);  /* skips the check */
}
```

## Try it

You need OCaml, dune and a GCC or Clang, of the releases that
[Building and testing](#building-and-testing) names. From a checkout,
with the examples above saved under their names:

```sh
dune build --root .
export PATH="$PWD/_build/install/default/bin:$PATH"
typec -c area.tc         # the error above
typec -c shape.c         # a C file compiles as with cc
typec --emit-c token.tc  # print the C that typec hands to cc
```

`typec` takes the command line of `cc` and hands an input that is not a
`.tc` file to the C compiler untouched, so an existing build runs with
`CC=typec` and its C files compile as before. With a `.tc` input it
refuses the few options that it cannot follow, such as `-E`, which
stops before the C it writes, or `-fshort-enums`, which changes C's
types. The C compiler is `cc` unless `--cc=PATH` or
`TYPEC_CC` names another ([choosing it](#choosing-the-backend)).

## In detail

### Adopting one file

A C11 translation unit is a Type-C unit with the same meaning
([design 2.2](type-c-language-design.md#22-type-c-is-a-superset-of-c11)):
each Type-C construct begins with tokens that C refuses, and the words
Type-C adds, such as `type`, `match` and `result`, stay free for C's
identifiers
([design 2.3](type-c-language-design.md#23-words)). So a file renamed
to `.tc` compiles before any Type-C is written in it, and while it uses
no Type-C construct, `typec` hands the C compiler its preprocessed text
byte for byte: the object equals the one that the C compiler builds from
that same preprocessed text with the same options
([`test/run/pipeline.t`](test/run/pipeline.t)). The corpus runner
checks the same on every file of real programs, among them zlib, Lua,
SQLite and QBE, each renamed to `.tc`
([Running the corpus](docs/development.md#running-the-corpus));
recording a run of the whole corpus at one revision on every host is
open in [TODO.md](TODO.md#corpus).

The fine print, for a `.tc` file:

- The dialect is C11 or C17, in the ISO or the GNU form, with the GNU
  and Clang extensions that system headers and common code use
  ([design 13.3](type-c-language-design.md#133-front-end)). Any other
  `-std=` is refused, so a build that selects C99 or C23 changes its
  option for the file. Without a `-std=`, `typec` selects `-std=gnu17`,
  the default of Clang 11 and later, so `__STDC_VERSION__` is `201710L`.
  GCC 15 and later default to `gnu23`, which cannot be kept: a build
  with such a GCC passes `-std=gnu17` (or `-std=gnu11`) so that its
  `.c` and `.tc` files share one dialect.
- An extension outside that set, such as a GNU nested function, is
  refused with a message, and so is a call of a builtin function that
  the table of `typec` lacks, such as `__builtin_cpu_supports`
  ([TODO.md](TODO.md) tracks the table).
- A source character that is not valid UTF-8, such as a Latin-1 byte in
  a string literal, is refused.
- A universe name (`option`, `result`, `slice`, `str` and the like) as
  a parameter of an old-style definition is an error: the name is a
  typedef name in a `.tc` file, and C11 6.9.1p6 forbids one there
  (design 2.2).
- Identifiers that begin with `__tc_` are reserved to `typec`, and one
  in the unit is an error (design 2.3).
- `typec` defines `__TYPEC__` as `1` while it preprocesses the unit
  (design 2.1).
- `__FILE__` names the `.tc` file, as it names any renamed file.
- A few options are refused, among them `-E`, `-save-temps`,
  `-fshort-enums` and more than one `-arch`
  ([Compiling a `.tc` input](#compiling-a-tc-input) lists them).
- The C compiler reads preprocessed text, so its warnings that depend on
  where a macro came from or on comments can differ from a direct
  compile
  ([design 13.2](type-c-language-design.md#132-driver-and-preprocessing)).

The code that you write in Type-C compiles to plain C
([What the C looks like](#what-the-c-looks-like)). Of the code that the
compiler adds without the source spelling it out, the traps of matching
are all that is built; `defer`, slice bounds checks and checked mode
will add the rest ([principle 4](#principles)). The rest of a program
links as before: Type-C functions are C functions under their own
names, with no mangling, and `typec` adds no library to the link
([design 10.4](type-c-language-design.md#104-functions-and-objects)).
Debuggers step through the lines of the `.tc` file
([design 13.6](type-c-language-design.md#136-diagnostics-and-debugging)),
but the debug information is not yet that of a direct compile: with
Clang it names a temporary file as the compilation unit, and on macOS a
command that links a `.tc` input with other inputs loses the `.dSYM` of
`-g` ([TODO.md](TODO.md#driver)).

### What typec reports

`typec` stops at the first error it finds, with the file and line, a
message, the section of the [design](type-c-language-design.md) that
states the rule, and the rule's code. These are the errors of the tour.
[`test/run/readme.t`](test/run/readme.t) checks the files and the
output shown on this page on GCC and Clang.

<details>
<summary>The error of each example of the tour</summary>

A `match` that misses a case, as above:

```console
$ typec -c area.tc
typec: area.tc:7: the match does not cover the constructor 'Triangle' of the variant 'shape' (design 4.2 rule 1) [TC0018]
[80]
```

A field read outside `match` and `if (case ...)`, as C reads a member
of the union:

<!-- file: peek.tc -->
```c
type token = | Number(long value) | Name(const char *text);

long number_value(token t) {
  return t.u.Number.value;
}
```

```console
$ typec -c token.tc
$ typec -c peek.tc
typec: peek.tc:4: the variant 'token' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching (design 3.2 rule 6) [TC0007]
[80]
```

An arm that falls into the next:

```console
$ typec -c cost.tc
typec: cost.tc:6: the end of the match arm can be reached (design 4.3 rule 1) [TC0021]
[80]
```

Swapped ids:

```console
$ typec -c ids.tc
typec: ids.tc:7: a value of type 'group_id' does not convert to 'user_id' without a cast (design 3.4) [TC0012]
[80]
```

A value made outside its owner:

<!-- file: port.tc -->
```c
#include <stdlib.h>
#include "port.tci"

port port_parse(const char *text) {
  long n = strtol(text, NULL, 10);
  if (n < 1 || n > 65535)
    return (port){0};
  return (port)n;
}
```

```console
$ typec -Iinclude -c port.tc
$ typec -Iinclude -c server.tc
typec: server.tc:5: the distinct type 'port' is private to 'include/port.tci', so only the text of its owner creates its values (design 9.2 rule 1) [TC0013]
[80]
```

`option` compiles as any other variant:

```console
$ typec -std=c11 -Wall -Wextra -c find.tc
```

Each instance of a generic type is a C structure of its own, so it is
the C compiler that refuses `list(double)` where `list(int)` is wanted.
Clang says (it quotes a fragment of the line, which
[TODO.md](TODO.md) tracks):

<!-- console: clang -->
```console
$ typec -c list.tc
list.tc:13:14: error: passing 'list__d' (aka 'struct list__d') to parameter of incompatible type 'list__i' (aka 'struct list__i')
   13 |   return sum(prices);
      |              ^~~~~~
list.tc:3:2: note: passing argument to parameter 'l' here
    3 |  l) {
      |  ^
1 error generated.
[1]
```

</details>

The C versions of these mistakes compile with `-Wall -Wextra`, on both
compilers, without a word:

<details>
<summary>The C of each mistake</summary>

<!-- file: token.c -->
```c
enum token_kind { TOKEN_NUMBER, TOKEN_NAME };

struct token {
  enum token_kind kind;
  union {
    struct { long value; } number;
    struct { const char *text; } name;
  } u;
};

long number_value(struct token t) {
  return t.u.number.value;
}
```

<!-- file: ids.c -->
```c
typedef unsigned user_id;
typedef unsigned group_id;

int is_member(user_id u, group_id g);

int may_read(user_id u, group_id g) {
  return is_member(g, u);  /* swapped */
}
```

<!-- file: list.c -->
```c
struct list {
  void *head;
  struct list *tail;
};

int sum(struct list l) {
  int total = 0;
  for (struct list *p = &l; p; p = p->tail)
    total += *(int *)p->head;
  return total;
}

int sum_prices(struct list prices) {
  return sum(prices);  /* a list of doubles */
}
```

<!-- file: port.h -->
```c
#include <stdint.h>

typedef uint16_t port;  /* make one with port_parse only */

port port_parse(const char *text);
```

<!-- file: server.c -->
```c
#include <stdlib.h>
#include "port.h"

port port_from_argument(const char *argument) {
  return atoi(argument);  /* skips the check */
}
```

```console
$ cc -std=c11 -Wall -Wextra -c token.c
$ cc -std=c11 -Wall -Wextra -c ids.c
$ cc -std=c11 -Wall -Wextra -c list.c
$ cc -std=c11 -Wall -Wextra -c server.c
```

</details>

C's warnings catch some forms of these mistakes, and
[`test/run/comparison.t`](test/run/comparison.t) records which, on both
compilers: `-Wall` warns of a `switch` on an enumeration that misses an
enumerator, unless it has a `default`; `-Wswitch-enum` warns with the
`default` too; GCC's `-Wextra` warns of a missing `break`, and Clang
does with `-Wimplicit-fallthrough`. No flag tried warns of a member
read under the wrong tag, of swapped ids or of a value made outside its
module.

Type-C has limits here too. A `match` with a `default` covers a new
case as C's `default` does; but a `default` that covers no case is
refused, so one cannot be written "just in case" before the case
exists. A value whose tag is none of its cases, which C code, casts and
unions can make, stops the program when it is matched, at run time.
`private` binds Type-C files only: C code reads and writes the layout
as C does, the zero value is open to every file, and Type-C code that
reinterprets storage, as `*(port *)p` does, is not refused. The
guarantees and what each depends on are in
[design 14](type-c-language-design.md#14-guarantees).

### What the C looks like

`typec` writes plain C11 with the GNU extensions that GCC and Clang
share, and `--emit-c` prints it. A variant is a structure of an
enumeration, its tag, and a union of one structure for each case that
has fields. A `match` is a `switch` on the tag that copies the fields
an arm binds into `const` locals, and traps after each arm and in the
`default` that it adds for a tag that is none of the cases. A distinct
type is a `typedef` of the type it is made from, and an instance of a
generic type is a structure named after its arguments, as `list__i` is
`list(int)`. C code and Type-C code call each other with no glue. C
text that uses no Type-C construct is written out as it was read.

<details>
<summary>The C of <code>area</code> with its third case</summary>

<!-- file: shape.tc -->
```c
type shape =
  | Circle(double r)
  | Rect(double w, double h)
  | Triangle(double b, double h);

double area(shape s) {
  match (s) {
  case Circle(r):
    return 3.14159 * r * r;
  case Rect(w, h):
    return w * h;
  case Triangle(b, h):
    return b * h / 2;
  }
}
```

`typec --emit-c shape.tc` writes this, here without its line markers
and laid out for reading:

<!-- emit-c: shape.tc -->
```c
struct shape; typedef struct shape shape;
enum shape_tag { shape_Circle, shape_Rect, shape_Triangle };
struct shape {
  enum shape_tag tag;
  union {
    struct { double r; } Circle;
    struct { double w; double h; } Rect;
    struct { double b; double h; } Triangle;
  } u;
};

double area(shape s) {
  {
    const struct shape *const __tc_match = &(s);
    switch (__tc_match->tag) {
    case shape_Circle: {
      const __typeof__(__tc_match->u.Circle.r) r = __tc_match->u.Circle.r;
      {
        return 3.14159 * r * r;
      }
      __builtin_trap();
    }
    case shape_Rect: {
      const __typeof__(__tc_match->u.Rect.w) w = __tc_match->u.Rect.w;
      const __typeof__(__tc_match->u.Rect.h) h = __tc_match->u.Rect.h;
      {
        return w * h;
      }
      __builtin_trap();
    }
    case shape_Triangle: {
      const __typeof__(__tc_match->u.Triangle.b) b =
          __tc_match->u.Triangle.b;
      const __typeof__(__tc_match->u.Triangle.h) h =
          __tc_match->u.Triangle.h;
      {
        return b * h / 2;
      }
      __builtin_trap();
    }
    default:
      __builtin_trap();
    }
  }
}
```

The unit ends with a few static assertions of what `typec` assumes of
the target, which fail to compile where the C compiler's types differ
from those `typec` read, as under `-Xclang -fshort-enums`.

</details>

The lowering is measured against hand-written C: Type-C programs and C
twins of them, which carry the same checks (the trap of a `match` on a
bad tag, the copies of the bound fields), are built at `-O2` with both
compilers and compared in code size and in the instructions they retire
([Measuring against hand-written C](docs/development.md#measuring-against-hand-written-c)).
The cost of the checks themselves, and what is not measured yet, are
open in [TODO.md](TODO.md).

### Using Type-C types from C

C code sees what
[design 10.6](type-c-language-design.md#106-what-c-code-sees) lists: a
variant is the structure shown above, a distinct type is the type it is
made from, and a function is the same C function. The C compiler lays
out both sides, so they agree:
[`test/run/abi.t`](test/run/abi.t) links objects that `typec` builds
with objects of the C compiler alone, in every pairing of GCC and
Clang, and passes variants with fields of each class of C object type
both ways, the C side reading them through a structure written by hand
as [design 10.1](type-c-language-design.md#101-variants) gives it.

One header can serve both kinds of file. `typec` defines `__TYPEC__`
while it preprocesses a Type-C unit, so the header can give Type-C
files a distinct type where C files see a plain `typedef`
([design 2.1](type-c-language-design.md#21-files)). Both have the same
representation, so both call the same function, and only the Type-C
side gets the check:

<!-- file: user.h -->
```c
#ifdef __TYPEC__
type user_id = distinct unsigned;  /* in .tc files */
#else
typedef unsigned user_id;          /* in .c files */
#endif

int user_is_root(user_id u);
```

<!-- file: user.tc -->
```c
#include "user.h"

int user_is_root(user_id u) {
  return u == (user_id)0;
}
```

<!-- file: admin.c -->
```c
#include <stdio.h>
#include "user.h"

int main(void) {
  printf("%d\n", user_is_root(0));
  return 0;
}
```

```console
$ typec -Wall -Wextra user.tc admin.c -o admin
$ ./admin
1
```

Not built yet: `typec --emit-c-header`, which writes the C header of a
`.tci` interface, so that C code gets its variants without a structure
written by hand
([design 9.3](type-c-language-design.md#93-c-clients), plan package
4.1).

### Principles

One line each on the principles of
[design section 1](type-c-language-design.md#1-principles), which states
them in full:

1. **Preserve C.** Where C already says it clearly, Type-C keeps C's
   spelling and meaning: declarations, `if`, `for`, `switch`, pointers,
   casts, the preprocessor and headers.
2. **Extend, never redefine.** A valid C11 file means the same in
   Type-C, but for one narrow exception
   ([design 2.2](type-c-language-design.md#22-type-c-is-a-superset-of-c11)).
3. **ML where C has nothing.** Closed sums, destructuring, nominal
   scalars and type parameters; no `let`, currying or pervasive
   inference.
4. **Costs stay visible.** No heap allocation, garbage collection,
   exceptions, runtime library or link dependency; the compiler adds
   code the source does not spell out in four places only: the traps of
   `match`, slice bounds checks, `defer` cleanups and checked mode.
5. **Claim only what is checked.** Each guarantee names the code it
   covers and what it depends on
   ([design 14](type-c-language-design.md#14-guarantees)).
6. **Small vocabulary.** Every concept names the problem it solves: no
   classes, inheritance, overloading, traits, templates or implicit
   conversion machinery.
7. **C's compilation model.** Translation units, headers and any build
   system; one unit at a time.
8. **By construction over by rule.** Prefer a design in which the wrong
   thing cannot be written over one that relies on a check being
   remembered.
9. **Language before machinery.** The design defines the meaning, not
   what an implementation makes easy.

### Why not just...

**...turn on more warnings, or run an analyzer?** Use them: Type-C code
still gets the warnings of the C compiler. Warnings see only the forms
they were written for, and no flag that `comparison.t` tries catches a
read of the wrong member, swapped ids or a value made outside its
module. An analyzer finds what the paths it explores reach. In Type-C
these mistakes are type errors that every build checks, with no extra
tool.

**...use Rust or Zig?** Both have exhaustive tagged unions and generic
types, and Rust's safe code is memory safe, which Type-C is not
([design 14](type-c-language-design.md#14-guarantees)). Both call C, but
C code gains their checks only when it is rewritten in their language,
and the build gains their toolchain and a boundary between the
languages: Rust reads C's declarations through `extern "C"`
blocks, written by hand or generated by bindgen, and Zig translates C
headers into Zig. `typec` is a tool to add too, but in Type-C the checks
start in the one file you rename. It includes the same headers as they
are, is compiled by the same C compiler, and gives an object with the C
ABI, which links with the rest as before
([One file of an existing program](#one-file-of-an-existing-program)).

**...use C++?** `std::variant`, `enum class` and templates do much of
this, in another language. A C file is not always a C++ file
(`int *p = malloc(n);` is an error in C++), C++ reaches C functions
through `extern "C"` declarations, and C++ brings exceptions and a
runtime library to link. A C file stays valid Type-C, and `typec`
writes C.

**...write macros?** A macro that writes `struct { T *data; ... }`
makes a new type at each use, so the `VECTOR(int)` of one declaration
does not pass where another `VECTOR(int)` is wanted, and C refuses the
call. The usual fix declares each instance once by name, by hand. A
generic type such as `vector(int)` is one type wherever it is written. A
macro cannot check a `switch` either.

### Status

Type-C is in development: the [design](type-c-language-design.md)
specifies the whole language, and the
[plan](type-c-implementation-plan.md) builds it in stages, each ending
in a measured gate. What is built is the language of Stage 1 of the
plan and the first packages of Stage 2: variants, `match` and `if (case ...)`, distinct
types, `private` and interface files (`.tci`), generic types, and
`option` and `result`.

Coming next, designed and **not yet implemented**:

- `try`, which returns the error of a `result` or gives its value:
  `uint32_t n = try read_u32(r);`
- `defer`, which runs a statement when its block is left:
  `defer fclose(f);`
- generic functions: `generic(T) T *vector_last(vector(T) *v);`
- slices with checked indexing:
  `slice(uint8_t) bytes = slice_from_array(buffer);`
- a checked mode, whose rules are provisional, that rules out specific
  classes of memory errors in the functions it covers.

## Building and testing

Requirements: OCaml 5.4 and dune 3; the tests also need a C compiler as
`cc`, a Clang and a GCC of releases that `typec` supports (see
[Choosing the backend](#choosing-the-backend)), and `tools/corpus/runner.t` runs
`/usr/bin/clang`. The cram tests in `test/run` run the Clang that
`TYPEC_TEST_CLANG` names and the GCC that `TYPEC_TEST_GCC` names; unset,
they are `/usr/bin/clang` and `/usr/local/bin/gcc-16`, those of the
macOS development host (`test/run/backends.sh`). `headers.t` parses
and reads the declarations of every C11 and POSIX header that each
backend's system headers hold.
`target.t` expects the model of x86-64 or of arm64, both Linux, and
`types.t`, `declarations.t` and `expressions.t` compile for the host's target and
for a second one, `-m32` on x86-64 and the other signedness of plain
char elsewhere (`second_target` in `test/run/backends.sh`). A host
without the C headers of i386 runs the tests that include the C headers
(`abi.t`) with the other signedness of plain char instead of `-m32`, and
`dune test` prints a line saying so. A host that has them sets
`TYPEC_TEST_REQUIRE_M32` to a non-empty value, and `dune test` then
fails when the backends do not both compile `<limits.h>` with `-m32`;
the check is a rule of `test/run/dune`, so a run of one test alone
(`dune test test/run/abi.t`) skips it. There are no other dependencies.

```sh
dune build    # builds typec as _build/install/default/bin/typec
dune test     # unit tests and end-to-end cram tests
TYPEC_TEST_GCC=/usr/bin/gcc dune test   # with another GCC
```

`dune exec typec -- ARGS` runs the compiler from the build tree.

`tools/gate.sh` is the command to run before a commit: it runs `dune build`
and `dune test`, then builds the typing oracle and runs its tests, which
`dune test` skips (see
[Typing oracle](docs/development.md#typing-oracle)). It needs the opam
switch `tools` and fails, saying where to find how to create it, when the
switch is missing. It prints the end of the log when a step fails; the
variables in the header of the script set the opam root, the oracle's build
directory and the log.

Library tests are in `test/unit`; the parser's are tables of C text and
the structural dump of its tree (`test/support/tree_dump.ml`) or its
error. `test_deep_trees` runs every chain that the parser reads in a
loop (`test/support/chains.ml`), as deep as `Parser.max_depth` lets it,
through the stages after the parser on a stack limited to 256K words.
`test/golden` holds cram tests that show the C or the diagnostic
that the front end gives for a source, with no backend
(`test/golden/golden.ml`); `dune test test/golden` runs them and
`dune promote` takes a changed output. Every rule that typec enforces has
a stable code in the one table `src/syntax/rule_table/rule_table.ml`,
which generates the module `Rule` and the catalogue
`_build/default/docs/diagnostics.md` (`dune build docs/diagnostics.md`);
`test/golden/coverage.ml` fails while some rule's code appears in no
golden output, so a new rule needs a golden case. `test/run` holds cram
tests that run `typec` and the backends;
`types.t` and `declarations.t` compile static assertions of what typec
computes, so a backend that disagrees fails to compile them.
`test/misuse` holds OCaml that an interface must refuse; each file names
its library and the expected error text in a `(* misuse: LIBRARY TEXT *)`
line, and passes only when `ocamlc` rejects it with that text.

## Choosing the backend

The backend is the program named by the last `--cc=PATH` option, else by
the `TYPEC_CC` environment variable when it is set and not empty, else
`cc`. A name without a slash is looked up in `PATH`. `typec` consumes
`--cc=`, `--print-target` and `--emit-c` where an option can stand (the
value of `-o` is never one) and forwards every other argument, `--cc`
without `=` included, in its original order. The backend is run with an
argument vector, never through a shell, so `TYPEC_CC` names one program:
it cannot carry extra arguments such as `ccache gcc`.

A backend that runs `typec` again, such as a `cc` first on `PATH` that
is `typec` itself, is refused: `typec` sets `TYPEC_OUTER_CC` to the
backend's name in the environment of every backend it runs, and a
`typec` that starts with it set exits with 81 after one message naming
that backend. The whole process tree of the backend inherits the mark,
so a `typec` that a wrapper backend runs on purpose is refused too. To
install `typec` as `cc`, set `TYPEC_CC` to the path of the real C
compiler.

The backend is GCC or Clang, Apple's included, no older than the
releases that `minimum_major_version` in
[src/sema/target.ml](src/sema/target.ml) names. `typec` refuses an
older one with a message naming the oldest supported releases.

Without a `.tc` input `typec` replaces itself with the backend. Exit
status: the backend's own; a backend ended by a signal ends `typec`
with the same signal. `typec` exits with 81 when `--cc=` has no path, the
backend cannot be started or the backend runs `typec` again, after one
message on stderr (with `--print-target`, a second says that the backend
gave no target model).

`typec`'s own failures have statuses of their own, which
[src/driver/exit_status.ml](src/driver/exit_status.ml) defines and
design 13.2 explains: 80 when it refuses the program (a diagnostic about
the source), 81 for an error of its environment (the command line, the
backend, a file it cannot read or write) and 82 for an internal error, a
bug in `typec`. Every other status is the backend's.

## Compiling a `.tc` input

An input whose name ends in `.tc`, with no `-x` other than `-x none`
before it, goes through three steps:

1. `BACKEND -E -D__TYPEC__=1 -std=gnu17 OPTIONS -x c FILE.tc`, with its
   stdout in a private temporary directory;
2. `typec` reads the preprocessed text, parses it and reads its
   declarations at file scope, then emits it. The declarations are read
   for the target model that the backend gives with the options of step
   3 (see "Printing the target model"). A text that the front end
   refuses stops `typec` with one message, `FILE:LINE: MESSAGE`. With no
   Type-C construct the emitted text is the preprocessed text, byte for
   byte;
3. `BACKEND -std=gnu17 OPTIONS -c -o OUTPUT -x cpp-output EMITTED`,
   with `-S` in place of `-c`, or `-fsyntax-only` in place of `-c -o
   OUTPUT`, as the command line asks, and with `-fno-trigraphs` last on
   Clang, which makes Clang read EMITTED without trigraphs, as `typec`
   read it (design 13.2).

Steps 1 and 3 also get `-Wno-unused-command-line-argument` before
OPTIONS, so that Clang does not warn about an option of the command
line that the step does not use.

`-std=gnu17` is left out when the command line gives `-std=` for C11 or
C17 (`c11`, `c17`, `c18`, `gnu11`, `gnu17`, `gnu18`, `c1x`, `gnu1x`,
`iso9899:2011`, `iso9899:2017`, `iso9899:2018`); any other `-std=` is a
usage error. Step 2 reads `asm` and `typeof` as keywords in the GNU forms
and as identifiers in the ISO forms, as GCC and Clang do; `-fasm` and
`-fno-asm` select the GNU and the ISO keywords whatever `-std=` says.
The options of step 1 are those that matter to
preprocessing and to code generation, those of step 3 the latter only;
`src/driver/cc_option.ml` is the one table that tells them apart and
says which options take a separate value. The output is named as cc
names it: after `-o`, else after the input in the current directory.
When the command line links and has no input but `.tc` ones, step 3
is the final command: the backend compiles and links the command line
with each `.tc` input replaced by `-x cpp-output EMITTED`, where EMITTED
is named as the input with the suffix `.c`, in a directory of its own.
The backend thus leaves what it leaves for a one-step build of C
sources, named as there: on macOS the `.dSYM` bundle of `-g`, and the
files of `-gsplit-dwarf`, `-fstack-usage` and `-fcallgraph-info`. When
the command line links with other inputs, each `.tc` input becomes an
object in the temporary directory and the backend links the command line
with those objects in place of the `.tc` inputs, and the side outputs of
step 3 are lost with the objects; without linking, the other inputs are
compiled by one more backend command without the `.tc` inputs. A `.c`
input is thus compiled exactly as without `typec`.

With `-MD` or `-MMD` the dependency file comes from step 1, named as cc
names it: after `-MF`, else after `-o` with the suffix `.d`, else after
the input; its target is the `-MT` or `-MQ` value, else the real output.

`--emit-c` stops after step 2 and writes the C to the `-o` file, or to
stdout; the command line then has exactly one input, a `.tc` file.

A `.tc` input refuses the options that stop the backend at
preprocessing (`-E`, `-M`, `-MM`), that change the preprocessed text
(`-P`, `-C`, `-CC`, `-fuse-line-directives`, `-dD`, `-dM` and the like,
`-traditional-cpp`, `-fdirectives-only`), `-save-temps`, `-###`, `-ansi`,
`--` and response files (`@FILE`), with a usage error naming the option.
It refuses the options known to change a type of C without changing a
macro that the target model reads, which the model therefore cannot
see: `-fshort-enums`, `-funsigned-bitfields` or `-fno-signed-bitfields`,
and `-fsingle-precision-constant`, even when a later option undoes
them. Other routes to these types, such as `-Xclang -fshort-enums`, a
config file, a wrapper or a target whose default differs, fail in step
3: the C of a unit with a Type-C construct ends, after a line marker
for `<typec>` with flag 3, with a static assertion of each such type
that `typec` assumes, whose message names the option that would break
it. Flag 3 keeps the user's warning options off typec's own text. An option
that changes a macro the model reads, such as
`-funsigned-char` or `-fshort-wchar`, reaches the target model.
It refuses `-fpack-struct` without a value, under which GCC
ignores the `#pragma pack` lines that `typec` writes around an instance
of a generic and warns of each; `-fpack-struct=n` passes. A unit that
holds such lines also ends with a probe that fails where the backend
reads `#pragma pack()` as a pop, as Clang does under
`-fapple-pragma-pack`.
It also refuses `-arch` options that name more than one architecture: cc
builds a universal binary from them, but step 1 preprocesses for one
architecture only. Build each architecture with its own `-arch` and join
the results with `lipo -create`.

The temporary directory is made with mode 0700 in `TMPDIR`, or `/tmp`,
and removed on every way out. SIGHUP, SIGINT, SIGPIPE, SIGQUIT and
SIGTERM are passed on to the running backend; `typec` then removes the
directory and ends by the same signal.

Exit status: 0 when every step succeeds; else the status of the first
backend step that fails, or the signal that ended it; 80 when the reader
or the front end refuses the preprocessed text; 81 for a usage error,
when the backend cannot be started or gives no target model, or when a
file cannot be read or written; 82 for an internal error.

## Printing the target model

`typec --print-target [OPTIONS]` runs the backend as
`BACKEND OPTIONS -dM -E -x c /dev/null` and prints the target model that
its predefined macros give: the backend and its major version, the
sizes of the scalar types, the
signedness of `char`, the types behind `size_t` and the other standard
typedefs, the byte order and `__STDC_VERSION__`, one `field: value` per
line. The other arguments are the backend options that select the
target or the dialect, such as `-m32`, `-funsigned-char` or `-std=gnu17`;
inputs, `-o` and dependency options do not belong there.

Exit status: 0 with the model on stdout; 81 when the backend fails,
cannot be started, is not supported or prints macros the model cannot
be read from, or for a usage error; 82 for an internal error.

## Developing typec

The test hosts, fuzzing, the corpus runner, the typing oracle and the
measurements against hand-written C are described in
[docs/development.md](docs/development.md). The order of work is the
[implementation plan](type-c-implementation-plan.md), and open work is
in [TODO.md](TODO.md).
