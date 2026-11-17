<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/readme.t checks the examples of this file on Clang and GCC,
but those marked untested: test/run/readme.sh says how the blocks are
marked.
-->

# Type-C

Type-C is C11 with the types C is missing: variants that `match` checks,
distinct types for ids and units, generic types, and errors as values
with `try` and `defer`. Its compiler, `typec`, takes the command line of
`cc`, turns Type-C into C that you can read, and hands that C to your C
compiler. A C11 file is already a Type-C file, so a program adopts it
one file at a time.

Type-C is early: every example on this page works today, and the rest
of the language is designed but not built yet ([Status](#status)).

## A first look

An evaluator of arithmetic expression trees, which reports a division
by zero or an overflow as a value instead of crashing. Like every C
and Type-C example in this README, it is checked by the tests.

<!-- file: eval.tc -->
```c
#include <limits.h>
#include <stdio.h>

type expr =
    | Num(int value)
    | Add(const expr *l, const expr *r)
    | Mul(const expr *l, const expr *r)
    | Div(const expr *l, const expr *r);

type eval_error = | DivByZero | Overflow;

/* With a 32-bit int, long long holds every sum, product and quotient. */
static result(int, eval_error)
fit(long long n)
{
	if (n < INT_MIN || n > INT_MAX)
		return (Err(Overflow));
	return (Ok((int)n));
}

static result(int, eval_error)
eval(const expr *e)
{
	int d;

	match (*e) {
	case Num(value):
		return (Ok(value));
	case Add(l, r):
		return (fit((long long)try eval(l) + try eval(r)));
	case Mul(l, r):
		return (fit((long long)try eval(l) * try eval(r)));
	case Div(l, r):
		d = try eval(r);
		if (d == 0)
			return (Err(DivByZero));
		return (fit((long long)try eval(l) / d));
	}
}

static void
show(const expr *e)
{
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
}

int
main(void)
{
	expr two = Num(2), three = Num(3), four = Num(4), zero = Num(0);
	expr sum = Add(&three, &four), ratio = Div(&sum, &zero);
	expr good = Mul(&two, &sum), bad = Mul(&two, &ratio);

	show(&good);	/* 2 * (3 + 4) */
	show(&bad);	/* 2 * ((3 + 4) / 0) */
}
```

It builds with the options of `cc` and prints:

```console
$ typec -std=c11 -Wall -Wextra -o eval eval.tc
$ ./eval
14
division by zero
```

What it shows:

- **Variants.** `expr` and `eval_error` are closed sums: a value is
  exactly one of the cases, and holds the fields of that case only.
  Code reaches the fields by naming them in a `case`, so Type-C code
  cannot read an `Add` as a `Num`.
- **An exhaustive `match`.** Each `match` here covers every case, with
  no `default`. Add a `Sub` case to `expr`, and the build stops at the
  `match` in `eval` until it handles `Sub`
  ([Variants and `match`](#variants-and-match)). In `show`,
  `Err(DivByZero)` nests one pattern in another, so one `match` tells
  the errors apart.
- **`result` and `try`.** `result(int, eval_error)` is a variant that
  every Type-C file has: `Ok` of an `int`, or `Err` of an `eval_error`.
  `try eval(l)` gives the value of an `Ok`, or returns that `Err` from
  the function at once: the division by zero inside `bad` comes up
  through the `Mul` above it to `show`
  ([`result` and `try`](#result-and-try)). `try` stands inside an
  expression, as in `try eval(l) + try eval(r)`: the operands of the
  tries run first, left to right, and the first error returns.
- **No runtime.** `typec` writes C: a variant becomes a structure of a
  tag and a union of the fields of its cases, a `match` a `switch` on
  the tag, and `try` an early return
  ([What the C looks like](#what-the-c-looks-like)). The rest is C: the
  headers, the pointers, `printf`, the arithmetic in `long long`, and
  the C compiler that builds it.

[What Type-C adds to C](#what-type-c-adds-to-c) explains each new piece,
and shows the mistakes each one rules out. The
[tutorial](docs/tutorial.md) grows a C program into Type-C one feature
at a time.

## Why Type-C

- **It stays C.** A C11 file keeps its meaning
  ([principle 2](#principles)). Type-C keeps C's declarations,
  statements, pointers, preprocessor and headers, and adds only what C
  has no way to say: closed sums, distinct types, type parameters,
  errors as values and cleanups.
- **It does not redo what C already does.** No module system, build
  tool or package manager of its own: a program stays translation
  units, headers and the build it has, and Type-C interfaces are
  headers that `#include` reads.
- **No runtime.** No hidden allocation, garbage collector, exceptions
  or runtime library, and nothing added to the link;
  [principle 4](#principles) lists the few places where `typec` adds
  code that the source does not spell out.
- **One toolchain.** `typec` writes C and hands it to your GCC or Clang:
  the same headers, the same compiler, the same options but
  [a few](#adopting-one-file), the same ABI, and the same debugger,
  which steps through the lines of the `.tc` file (with
  [gaps](#adopting-one-file) in the debug information still).
- **Adopt it one file at a time.** Rename one `.c` file to `.tc`, build
  with `CC=typec` and a build rule for `.tc` files, and use the new
  types where they help. The other files do not change
  ([Adopting one file](#adopting-one-file)).
- **Not another language at the boundary.** Rust, Zig and OCaml call
  C through bindings or stubs, and C code gains their checks only when
  it is rewritten in them; C++ compiles only some C. Type-C's checks
  start in the one file that you rename. Safe Rust and OCaml are memory
  safe, and Type-C is not ([Why not just...](#why-not-just)).
- **Costs measured against hand-written C.** On a real library, the
  Type-C rewrite parses as fast as a hand-written C twin, within the
  noise of the measurement, and its object code is 2.8% (Clang) to
  11.9% (GCC) larger
  ([Measured on a real library](#measured-on-a-real-library)).
- **Claims only what is checked.** Each guarantee says what it depends
  on ([principle 5](#principles)), and the tests check each C and Type-C
  example on this page but the first, on GCC and Clang.

## What Type-C adds to C

Each feature below rules out a kind of mistake that C compiles without
a word: as an error that the section shows, or by making the mistake
impossible to write. Where a C warning catches a form of it, the
section says which. The messages are those that `typec` prints, with
its exit
status in brackets ([What typec reports](#what-typec-reports)). The
cases of a variant are its *constructors*, as the messages call them.

### Variants and `match`

A tagged union in C, with two bugs:

<!-- file: shape.c -->
```c
enum shape_kind { CIRCLE, RECT, TRIANGLE };

struct shape {
	enum shape_kind	kind;
	union {
		struct { double r; } circle;
		struct { double w, h; } rect;
		struct { double b, h; } triangle;
	} u;
};

double
area(struct shape s)
{
	switch (s.kind) {
	case CIRCLE:
		return (3.14159 * s.u.circle.r * s.u.circle.r);
	case RECT:
		return (s.u.rect.w * s.u.circle.r);	/* wrong member */
	default:					/* TRIANGLE forgotten */
		return (0);
	}
}
```

```console
$ cc -std=c11 -Wall -Wextra -c shape.c
```

The same in Type-C. Each field belongs to its case, so the wrong-member
read cannot be written, and the forgotten case stops the build:

<!-- file: area.tc -->
```c
type shape =
    | Circle(double r)
    | Rect(double w, double h)
    | Triangle(double b, double h);

double
area(shape s)
{
	match (s) {
	case Circle(r):
		return (3.14159 * r * r);
	case Rect(w, h):
		return (w * h);
	}
}
```

```console
$ typec -std=c11 -Wall -Wextra -c area.tc
area.tc:9: error: the match does not cover the constructor 'Triangle' of the variant 'shape' [match-coverage]
[80]
```

C's `-Wall` warns of a forgotten enumerator only in a `switch` with no
`default`, and only when the kind has an enumeration type; a `default`
written for a kind that is none of the three, or an `int` kind, hides
it (`-Wswitch-enum` warns with the `default` too). No flag that
[`test/run/comparison.t`](test/run/comparison.t) tries warns of the
wrong-member read. A `match` needs no `default`: it stops the program
on a value whose tag is none of the cases, and a case added later is an
error at every `match` that misses it.

### Asking about one case: `if (case ...)`

`if (case ...)` tests for one case and binds its fields, and
`while (case ...)` loops while it holds. Outside them and `match`,
Type-C code cannot name a field at all:

<!-- file: token.tc -->
```c
type token = | Number(long value) | Name(const char *text);

long
number_value(token t)
{
	if (case Number(value) = t)
		return (value);
	return (0);
}
```

A field read as C reads a member of the union:

<!-- file: peek.tc -->
```c
type token = | Number(long value) | Name(const char *text);

long
number_value(token t)
{
	return (t.u.Number.value);
}
```

```console
$ typec -c token.tc
$ typec -c peek.tc
peek.tc:6: error: the variant 'token' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
[80]
```

### No fall-through

An arm of a `match` that can run into the next one is an error: it ends
in `break`, `return`, `continue`, `goto` or a call that does not
return.

<!-- file: cost.tc -->
```c
type op = | Load(int address) | Add(int operands);

int
cost(op o)
{
	int c = 0;

	match (o) {
	case Load(_):
		c = 2;
	case Add(n):
		c += n;
		break;
	}
	return (c);
}
```

```console
$ typec -c cost.tc
cost.tc:9: error: the end of the match arm can be reached [match-arm-end]
[80]
```

In C, GCC's `-Wextra` warns of a missing `break`, and Clang does with
`-Wimplicit-fallthrough`.

### Distinct types

A distinct type has the representation of another type but does not
convert to it, or from it, without a cast. Ids and units that C would
mix become an error:

<!-- file: ids.tc -->
```c
type user_id = distinct unsigned;
type group_id = distinct unsigned;

int is_member(user_id u, group_id g);

int
may_read(user_id u, group_id g)
{
	return (is_member(g, u));	/* swapped */
}
```

```console
$ typec -c ids.tc
ids.tc:9: error: a value of type 'group_id' does not convert to 'user_id' without a cast [distinct-conversion]
[80]
```

With C's `typedef`, the swap compiles, and no warning flag that
`comparison.t` tries catches it:

<!-- file: ids.c -->
```c
typedef unsigned user_id;
typedef unsigned group_id;

int is_member(user_id u, group_id g);

int
may_read(user_id u, group_id g)
{
	return (is_member(g, u));	/* swapped */
}
```

```console
$ cc -std=c11 -Wall -Wextra -c ids.c
```

### Private types and interfaces

An interface file, `.tci`, is a header for Type-C: other files include
it with `#include`. A `private` type in it can be made only in the
interface and in the source file of the same name, here `port.tc`;
other files use ports and read their value. So, short of C code or
reinterpreted storage ([limits](#limits-of-the-checks)), every port but
the zero value, `{0}`, comes from `port_parse`.

<!-- file: include/port.tci -->
```c
#include <stdint.h>

type port = private distinct uint16_t;

port port_parse(const char *text);	/* {0} when text is no port */
```

<!-- file: port.tc -->
```c
#include <stdlib.h>
#include "port.tci"

port
port_parse(const char *text)
{
	char *end;
	long n = strtol(text, &end, 10);

	if (end == text || *end != '\0' || n < 1 || n > 65535)
		return ((port){0});
	return ((port)n);
}
```

<!-- file: server.tc -->
```c
#include <stdlib.h>
#include "port.tci"

port
port_from_argument(const char *argument)
{
	return ((port)atoi(argument));	/* skips the check */
}
```

```console
$ typec -Iinclude -c port.tc
$ typec -Iinclude -c server.tc
server.tc:7: error: the distinct type 'port' is private to 'include/port.tci', so only the text of its owner creates its values [private-creation]
[80]
```

In C, the rule is a comment:

<!-- file: port.h -->
```c
#include <stdint.h>

typedef uint16_t port;	/* make one with port_parse only */

port port_parse(const char *text);
```

<!-- file: server.c -->
```c
#include <stdlib.h>
#include "port.h"

port
port_from_argument(const char *argument)
{
	return (atoi(argument));	/* skips the check */
}
```

```console
$ cc -std=c11 -Wall -Wextra -c server.c
```

### Generic types

A type can take type parameters, instead of holding a `void *`.
`list(int)` and `list(double)` are different types, so a list of prices
cannot reach a function that sums integers. Each `list(int)` names the
same type, wherever it is written.

<!-- file: list.tc -->
```c
type list(T) = | Nil | Cons(T head, list(T) *tail);

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

int
sum_prices(list(double) prices)
{
	return (sum(prices));
}
```

Each instance of a generic type is a C structure of its own, and a
structure converts to no other type, so `typec` refuses `list(double)`
where `list(int)` is wanted:

```console
$ typec -c list.tc
list.tc:18: error: a value of type 'list(double)' does not convert to 'list(int)' (C11 6.5.16.1p1)
[80]
```

The C list of `void *` takes any element:

<!-- file: list.c -->
```c
#include <stddef.h>

struct list {
	void		*head;
	struct list	*tail;
};

int
sum(struct list l)
{
	int total = 0;

	for (struct list *p = &l; p != NULL; p = p->tail)
		total += *(int *)p->head;
	return (total);
}

int
sum_prices(struct list prices)
{
	return (sum(prices));	/* a list of doubles */
}
```

```console
$ cc -std=c11 -Wall -Wextra -c list.c
```

### `option`

`option(T)` is a generic variant that every Type-C file has: `None`, or
`Some` of a value. It replaces the `-1` or `NULL` that means "not
found", which a caller can forget to test:

<!-- file: find.tc -->
```c
#include <stddef.h>

option(size_t)
find(const int *items, size_t n, int wanted)
{
	for (size_t i = 0; i < n; i++)
		if (items[i] == wanted)
			return (Some(i));
	return (None);
}

size_t
index_or_end(const int *items, size_t n, int wanted)
{
	if (case Some(i) = find(items, n, wanted))
		return (i);
	return (n);
}
```

```console
$ typec -std=c11 -Wall -Wextra -c find.tc
```

### `result` and `try`

`result(T, E)` is another generic variant that every Type-C file has:
`Ok` of a value, or `Err` of an error, which can be a variant with
fields of its own. `try` gives the value of a `result`, or returns its
error from the function at once:

<!-- file: size.tc -->
```c
#include <stdio.h>
#include <stdlib.h>

type setting_error =
    | Missing(const char *name)
    | NotANumber(const char *name);

static result(long, setting_error)
setting(const char *name)
{
	const char *text = getenv(name);
	char *end;
	long n;

	if (text == NULL)
		return (Err(Missing(name)));
	n = strtol(text, &end, 10);
	if (end == text || *end != '\0')
		return (Err(NotANumber(name)));
	return (Ok(n));
}

static result(long, setting_error)
area(void)
{
	long width = try setting("WIDTH");
	long height = try setting("HEIGHT");

	return (Ok(width * height));
}

int
main(void)
{
	match (area()) {
	case Ok(n):
		printf("%ld\n", n);
		return (0);
	case Err(Missing(name)):
		fprintf(stderr, "%s is not set\n", name);
		return (1);
	case Err(NotANumber(name)):
		fprintf(stderr, "%s is not a number\n", name);
		return (1);
	}
}
```

```console
$ typec -std=c11 -Wall -Wextra size.tc -o size
$ WIDTH=3 HEIGHT=4 ./size
12
$ WIDTH=3 ./size
HEIGHT is not set
[1]
$ WIDTH=3 HEIGHT=four ./size
HEIGHT is not a number
[1]
```

### A dropped result is an error

A call that drops a `result`, as a statement of its own, is an error:

<!-- file: backup.tc -->
```c
type copy_error = | CannotOpen | CannotRead | CannotWrite;

result(void, copy_error) copy_file(const char *from, const char *to);

void
backup(void)
{
	copy_file("notes.txt", "notes.bak");
}
```

```console
$ typec -c backup.tc
backup.tc:8: error: a value of a result type is discarded; handle it with try or match, store it, or cast it to void [discarded-result]
[80]
```

C drops a return code without a word unless its function is declared
`[[nodiscard]]` (C23) or `warn_unused_result`, and then it warns.

### `defer`

C releases resources at one label that each error path must jump to;
here an error path written later returns past it:

<!-- file: copy.c -->
```c
#include <stdio.h>

int
copy_file(const char *from, const char *to)
{
	int status = -1;
	FILE *out = NULL;
	FILE *in = fopen(from, "rb");
	char buffer[4096];
	size_t n;

	if (in == NULL)
		goto done;
	out = fopen(to, "wb");
	if (out == NULL)
		goto done;
	while ((n = fread(buffer, 1, sizeof(buffer), in)) > 0)
		if (fwrite(buffer, 1, n, out) != n)
			return (-1);	/* leaks in and out */
	if (ferror(in) || fflush(out) != 0)
		goto done;
	status = 0;
done:
	if (out != NULL)
		fclose(out);
	if (in != NULL)
		fclose(in);
	return (status);
}
```

```console
$ cc -std=c11 -Wall -Wextra -c copy.c
```

A `defer`, written on the line after an acquisition, releases the
resource at every exit after it: each exit runs the deferred statements
in force there, in reverse order, so the `return` in the loop closes
both files. A deferred statement cannot report an error, so the
function flushes `out` itself before its last exit:

<!-- file: copy.tc -->
```c
#include <stdio.h>

type copy_error = | CannotOpen | CannotRead | CannotWrite;

static result(FILE *, copy_error)
open_file(const char *path, const char *mode)
{
	FILE *f = fopen(path, mode);

	if (f == NULL)
		return (Err(CannotOpen));
	return (Ok(f));
}

result(void, copy_error)
copy_file(const char *from, const char *to)
{
	FILE *in, *out;
	char buffer[4096];
	size_t n;

	in = try open_file(from, "rb");
	defer fclose(in);
	out = try open_file(to, "wb");
	defer fclose(out);
	while ((n = fread(buffer, 1, sizeof(buffer), in)) > 0)
		if (fwrite(buffer, 1, n, out) != n)
			return (Err(CannotWrite));
	if (ferror(in))
		return (Err(CannotRead));
	if (fflush(out) != 0)
		return (Err(CannotWrite));
	return (Ok);
}
```

```console
$ typec -std=c11 -Wall -Wextra -c copy.tc
```

`typec` writes a copy of each deferred statement at each exit
([What the C looks like](#what-the-c-looks-like)). An analyzer finds
some leaks of C by following paths: GCC's `-fanalyzer` reports both of
`copy.c`, in either order.

<!-- console: gcc -->
```console
$ cc -std=c11 -fanalyzer -c copy.c 2>&1 | grep -o "leak of FILE '[a-z]*'" | sort
leak of FILE 'in'
leak of FILE 'out'
```

### Limits of the checks

A `match` with a `default` covers a new case as C's `default` does; but
a `default` that covers no case is refused, so one cannot be written
"just in case" before the case exists. A value whose tag is none of its
cases, which C code, casts and unions can make, stops the program when
it is matched, at run time. `private` binds Type-C files only: C code
reads and writes the layout as C does, the zero value is open to every
file, and Type-C code that reinterprets storage, as `*(port *)p` does,
is not refused. The guarantees and what each depends on are in [design
14](type-c-language-design.md#14-guarantees).

## Adopting one file

Type-C enters a program one file at a time. Take a small C program:
`main.c` calls `calc.c` through `calc.h`.

<!-- file: calc.h -->
```c
/*
 * Applies a line such as "add 5" or "neg" to *total: 0 when it knows
 * the line, else -1.
 */
int calc_apply(const char *line, long *total);
```

<!-- file: main.c -->
```c
#include <stdio.h>
#include "calc.h"

int
main(void)
{
	const char *lines[] = {"add 5", "neg", "add 2", "mul 3"};
	long total = 0;

	for (int i = 0; i < 4; i++)
		if (calc_apply(lines[i], &total) != 0)
			printf("unknown: %s\n", lines[i]);
	printf("%ld\n", total);
	return (0);
}
```

<!-- file: calc.c -->
```c
#include <stdlib.h>
#include <string.h>
#include "calc.h"

int
calc_apply(const char *line, long *total)
{
	if (strncmp(line, "add ", 4) == 0) {
		*total += strtol(line + 4, NULL, 10);
		return (0);
	}
	if (strcmp(line, "neg") == 0) {
		*total = -*total;
		return (0);
	}
	return (-1);
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

static command
parse(const char *line)
{
	if (strncmp(line, "add ", 4) == 0)
		return (Add(strtol(line + 4, NULL, 10)));
	if (strcmp(line, "neg") == 0)
		return (Neg);
	return (Unknown);
}

int
calc_apply(const char *line, long *total)
{
	match (parse(line)) {
	case Add(n):
		*total += n;
		return (0);
	case Neg:
		*total = -*total;
		return (0);
	case Unknown:
		return (-1);
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

A build compiles `calc.tc` with `typec`, and its other files as before
([In a build](#in-a-build)).

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
- A universe name (`option` or `result`) as
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
compiler adds without the source spelling it out, the traps of
matching, the cleanups of `defer` and slice bounds checks are built;
checked mode will add the rest ([principle 4](#principles)). The rest
of a program links as before: Type-C functions are C functions under
their own names, with no mangling, and `typec` adds no library to the link
([design 10.4](type-c-language-design.md#104-functions-and-objects)).
Debuggers step through the lines of the `.tc` file
([design 13.6](type-c-language-design.md#136-diagnostics-and-debugging)),
but the debug information is not yet that of a direct compile: with
Clang it names a temporary file as the compilation unit, and on macOS a
command that links a `.tc` input with other inputs loses the `.dSYM` of
`-g` ([TODO.md](TODO.md#driver)).

### In a build

In a build, `typec` is the C compiler, with the backend that `TYPEC_CC`
names ([Choosing the backend](#choosing-the-backend)). It hands
`main.c` and every other C file to the backend untouched, so a build
tool needs to learn only that a `.tc` file is compiled as a `.c` file
is. The dependency options (`-M`, `-MM`, `-MD`, `-MMD`, `-MF`, `-MT`,
`-MQ`, `-MP`) work as for a `.c` file: the rule of `calc.o` names
`calc.tc` and every header and `.tci` interface that it includes, so
make or ninja rebuilds `calc.o` when one of them changes, and nothing
when none does.

In a GNU Makefile, the rule for a `.tc` file is make's built-in rule
for a `.c` file:

<!-- file: Makefile -->
```
CC = typec
CFLAGS = -Wall -Wextra
CPPFLAGS = -MMD -MP
objects = main.o calc.o

calc: $(objects)
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

-include $(objects:.o=.d)
```

With ninja, whose `deps = gcc` reads the same dependency files:

<!-- file: build.ninja -->
```
cflags = -Wall -Wextra

rule cc
  command = typec $cflags -MMD -MF $out.d -c $in -o $out
  depfile = $out.d
  deps = gcc

rule link
  command = typec $in -o $out

build main.o: cc main.c
build calc.o: cc calc.tc
build calc: link main.o calc.o
```

In CMake, a file of rules that CMake reads when it enables C makes
`.tc` a suffix of C sources:

<!-- file: typec.cmake -->
```
list(APPEND CMAKE_C_SOURCE_FILE_EXTENSIONS tc)
```

<!-- file: CMakeLists.txt -->
```
cmake_minimum_required(VERSION 3.20)
set(CMAKE_USER_MAKE_RULES_OVERRIDE_C
    ${CMAKE_CURRENT_SOURCE_DIR}/typec.cmake)
project(calc C)
add_executable(calc main.c calc.tc)
```

```sh
cmake -G Ninja -DCMAKE_C_COMPILER=typec -B build
cmake --build build
```

The `LANGUAGE C` property on `calc.tc` would not do: with it, CMake
puts `-x c` before the file, and `typec` then hands it to the backend
as C, as the C compiler would take it. The tests
[`make_rule.t`](test/run/make_rule.t),
[`ninja_rule.t`](test/run/ninja_rule.t) and
[`cmake_rule.t`](test/run/cmake_rule.t) build with these rules on both
backends, where the host has the tool.

## What typec reports

`typec` stops at the first error it finds, prints it as GCC and Clang
print theirs, `file:line: error: message`, and exits with status 80. An
error under a rule of Type-C ends with the rule's name in brackets, as
`[match-arm-end]`, the way GCC ends a warning with its option; the
catalogue of diagnostics (`dune build docs/diagnostics.md` writes it to
`_build/default/docs/diagnostics.md`) gives each name's rule and the
section of the [design](type-c-language-design.md) that states it. A
message about no place in the source, as one about the command line,
begins with `typec:` instead. An error
that the C compiler finds in the C that `typec` writes, as with the
generic types above, comes with the C compiler's message and status.
[`test/run/readme.t`](test/run/readme.t) checks the files and the output
of every C and Type-C example on this page but the first, on GCC and
Clang.

## What the C looks like

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

double
area(shape s)
{
	match (s) {
	case Circle(r):
		return (3.14159 * r * r);
	case Rect(w, h):
		return (w * h);
	case Triangle(b, h):
		return (b * h / 2);
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

double
area(shape s)
{
  {
    const struct shape *const __tc_match0 = &(s);
    switch (__tc_match0->tag) {
    case shape_Circle: {
      const __typeof__(__tc_match0->u.Circle.r) r = __tc_match0->u.Circle.r;
      {
        return (3.14159 * r * r);
      }
      __builtin_trap();
    }
    case shape_Rect: {
      const __typeof__(__tc_match0->u.Rect.w) w = __tc_match0->u.Rect.w;
      const __typeof__(__tc_match0->u.Rect.h) h = __tc_match0->u.Rect.h;
      {
        return (w * h);
      }
      __builtin_trap();
    }
    case shape_Triangle: {
      const __typeof__(__tc_match0->u.Triangle.b) b =
          __tc_match0->u.Triangle.b;
      const __typeof__(__tc_match0->u.Triangle.h) h =
          __tc_match0->u.Triangle.h;
      {
        return (b * h / 2);
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

A `result` is a variant like any other, an instance named after its
arguments, as `result__i5error` is `result(int, error)`. A `try` tests
the tag and returns the error at once, and a `defer` writes its
statement at each exit of its scope, in reverse order, after the value
of a `return` is computed: the C of early returns that each release
what is held, with no table, unwinding or allocation.

<details>
<summary>The C of <code>try</code> and <code>defer</code></summary>

<!-- file: pair.tc -->
```c
type error = | Busy;

result(int, error) acquire(int id);
void release(int handle);
result(void, error) join(int a, int b);

result(void, error)
pair(void)
{
	int a, b;

	a = try acquire(1);
	defer release(a);
	b = try acquire(2);
	defer release(b);
	return (join(a, b));
}
```

`typec --emit-c pair.tc` writes this, here without its line markers and
laid out for reading:

<!-- emit-c: pair.tc -->
```c
struct error; typedef struct error error;
enum error_tag { error_Busy };
struct error { enum error_tag tag; };

typedef int __tc_arg__i;
struct error; typedef struct error __tc_arg__5error;
struct result__i5error; typedef struct result__i5error result__i5error;

result__i5error acquire(int id);
void release(int handle);

typedef void __tc_arg__v;
struct result__v5error; typedef struct result__v5error result__v5error;

result__v5error join(int a, int b);

enum result__v5error_tag { result__v5error_Err, result__v5error_Ok };
struct result__v5error {
  enum result__v5error_tag tag;
  union {
    struct { __tc_arg__5error error; } Err;
  } u;
};
enum result__i5error_tag { result__i5error_Err, result__i5error_Ok };
struct result__i5error {
  enum result__i5error_tag tag;
  union {
    struct { __tc_arg__5error error; } Err;
    struct { __tc_arg__i value; } Ok;
  } u;
};

result__v5error
pair(void)
{
  typedef __typeof__(((__typeof__(pair) *)0)()) __tc_ret;
  {
    int a, b;

    struct result__i5error __tc_t0 = (acquire(1));
    if (__tc_t0.tag != result__i5error_Ok) {
      if (__tc_t0.tag != result__i5error_Err)
        __builtin_trap();
      return ((struct result__v5error){
          .tag = result__v5error_Err, .u.Err = { __tc_t0.u.Err.error } });
    }
    a = __tc_t0.u.Ok.value;

    struct result__i5error __tc_t1 = (acquire(2));
    if (__tc_t1.tag != result__i5error_Ok) {
      if (__tc_t1.tag != result__i5error_Err)
        __builtin_trap();
      { release(a); }
      return ((struct result__v5error){
          .tag = result__v5error_Err, .u.Err = { __tc_t1.u.Err.error } });
    }
    b = __tc_t1.u.Ok.value;

    {
      __tc_ret __tc_r0 = ((join(a, b)));
      { release(b); }
      { release(a); }
      return __tc_r0;
    }
    __builtin_trap();
  }
}
```

A tag that is neither `Ok` nor `Err` traps, as in every `match`, and so
does the end of the function, which no path reaches.

</details>

The lowering is measured against hand-written C: Type-C programs and C
twins of them, which carry the same checks (the trap of a `match` on a
bad tag, the copies of the bound fields), are built at `-O2` with both
compilers and compared in code size and in the instructions they retire
([Measuring against hand-written C](docs/development.md#measuring-against-hand-written-c)).
The cost of the checks themselves, and what is not measured yet, are
open in [TODO.md](TODO.md).

## Using Type-C types from C

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
type user_id = distinct unsigned;	/* in .tc files */
#else
typedef unsigned user_id;		/* in .c files */
#endif

int user_is_root(user_id u);
```

<!-- file: user.tc -->
```c
#include "user.h"

int
user_is_root(user_id u)
{
	return (u == (user_id)0);
}
```

<!-- file: admin.c -->
```c
#include <stdio.h>
#include "user.h"

int
main(void)
{
	printf("%d\n", user_is_root(0));
	return (0);
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

## Measured on a real library

Pilot B, the plan's test of Stage 2 on real code
([plan, Stage 2](type-c-implementation-plan.md#stage-2-generic-types-result-try-and-defer)),
rewrote the parser of tomlc99, a TOML library in C (`toml.c`, 2392
lines), with `result`, `try` and `defer`. Its header `toml.h`, its C
programs and its tests did not change and link against the Type-C
object. The pilot's repository is not published; the numbers here are
from its record.

Fault injection fails each allocation of a parse in turn, one run for
each. Over the library's 62 example files, 1416 runs, the original
went wrong in 34: 25 leaks and 9 uses after free, from two defects in
the code that grows an array or a table. The rewrite went wrong in
none, built by Clang or GCC, and the address, undefined behavior and
leak sanitizers reported nothing. Over the 146 files of
toml-spec-tests, 18847 runs, the original leaked in 1022, 1000 of them
in one deeply nested file, and crashed in 9; the rewrite did neither.

`try` and `defer` did not remove the defects by themselves. A variant
of the rewrite whose three faulty functions only put a `try` in place
of each `if (!x) return` kept all 34 bad runs. Adding a `defer` that
frees each new object until it is linked into the tree removed the 25
leaks but not the 9 uses after free, which came from the order of the
steps: the old buffer of an array was freed before its new element
existed. Reordering the steps, so that each grown buffer is stored and
counted before the next allocation, removed them. The language puts
the question "who owns this object if this step fails?" at every
`try`; the rewrite had to answer it.

What it costs, at `-O2 -g`, against a hand-written C version of the
same rewrite with a `goto cleanup` where Type-C has a `defer`:

| | Apple Clang 21 | GCC 16 |
| --- | --- | --- |
| text of `toml.o`, over the `goto` version | +528 bytes, +2.8% | +2192 bytes, +11.9% |
| of which cleanups repeated at each exit | 208 bytes, 1.1% of text | 368 bytes, 2.0% of text |
| text of `toml.o`, over the original `toml.c` | +480 bytes, +2.6% | +656 bytes, +3.3% |
| 20 parses of a 1.3 MB document, `goto` version | 0.868 s | 0.962 s |
| the same, Type-C | 0.870 s | 0.960 s |

The record does not split the rest of the growth further and puts most
of it down to the representation of `result`, a structure of a tag and
a union returned by value where the C returns an `int` or a pointer;
returning a result whose error has no fields as the bare value is open
in [TODO.md](TODO.md). Parse times are the best
of five rounds, and repeated runs move each by 2 to 3 percent, more
than any gap between the versions. Error paths were not timed.

## Principles

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

## Why not just...

**...turn on more warnings, or run an analyzer?** Use them: Type-C code
still gets the warnings of the C compiler. Warnings see only the forms
they were written for, and no flag that `comparison.t` tries catches a
read of the wrong member, swapped ids or a value made outside its
module. An analyzer finds what the paths it explores reach. In Type-C
these mistakes are type errors that every build checks, with no extra
tool.

**...use Rust, Zig or OCaml?** All three have tagged unions whose
matches are checked for missing cases, and generic types, and safe Rust
and OCaml are memory safe, which Type-C is not ([design
14](type-c-language-design.md#14-guarantees)). All three call C, but C
code gains their checks only when it is rewritten in their language, and
the build gains their toolchain and a boundary between the languages:
Rust reads C's declarations through `extern "C"` blocks, written by hand
or generated by bindgen, Zig translates C headers into Zig, and OCaml
calls C through stubs written against its runtime, which brings a
garbage collector. `typec` is a tool to add too, but in Type-C the
checks start in the one file you rename. It includes the same headers as
they are, is compiled by the same C compiler, and gives an object with
the C ABI, which links with the rest as before ([Adopting one
file](#adopting-one-file)).

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

## Status

Type-C is in development: the [design](type-c-language-design.md)
specifies the whole language, and the
[plan](type-c-implementation-plan.md) builds it in stages, each ending
in a measured gate. Stages 1 and 2 are built and have met their gates:
variants, `match` and `if (case ...)`, distinct types, `private` and
interface files (`.tci`), generic types, `option` and `result`, `try`
and `defer`. Stage 2's gate rests on
[Pilot B](#measured-on-a-real-library).

Stage 3 is in progress, and **not ready to use** yet. Slices with
checked indexing and `str` are built,
`slice(uint8_t) bytes = slice_from_array(buffer);`, and so are generic
functions, `generic(T) T *vector_last(vector(T) *v);`, and `try` inside
an expression, `return fit(try eval(l) + try eval(r));`, which
[design 5.1](type-c-language-design.md#51-try) specifies.

Nested patterns, which
[design 4.7](type-c-language-design.md#47-nested-patterns) specifies,
are built in `match`, such as `case Err(DivByZero):`, and in the
single-pattern test, such as `while (case At(*Cons(h, t)) = c)`.

Designed and **not yet implemented**: a checked mode, whose rules are
provisional, that rules out specific classes of memory errors in the
functions it covers.

## Try it

You need OCaml, dune and a GCC or Clang, of the releases that
[Building and testing](#building-and-testing) names. From a checkout,
with the examples above saved under their names:

```sh
dune build --root .
export PATH="$PWD/_build/install/default/bin:$PATH"
typec -c area.tc         # a match that misses a case
typec -c shape.c         # a C file compiles as with cc
typec --emit-c token.tc  # print the C that typec hands to cc
```

`typec` takes the command line of `cc` and hands an input that is not a
`.tc` file to the C compiler untouched, so an existing build runs with
`CC=typec` and its C files compile as before. With a `.tc` input it
refuses the few options that it cannot follow, such as `-E`, which
stops before the C it writes, or `-fshort-enums`, which changes C's
types, and the long options, spelled with `--`, that it does not
know. The C compiler is `cc` unless `--cc=PATH` or
`TYPEC_CC` names another ([choosing it](#choosing-the-backend)).

[`examples/`](examples/) holds larger programs, each beside the C that
it ports, such as FreeBSD's `cut(1)`.

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
through the stages after the parser on a stack limited to 256K words of
amd64 frames (more where a frame is larger).
`test/golden` holds cram tests that show the C or the diagnostic
that the front end gives for a source, with no backend
(`test/golden/golden.ml`); `dune test test/golden` runs them and
`dune promote` takes a changed output. Every rule that typec enforces has
a stable name in the one table `src/syntax/rule_table/rule_table.ml`,
which generates the module `Rule` and the catalogue
`_build/default/docs/diagnostics.md` (`dune build docs/diagnostics.md`);
`test/golden/coverage.ml` fails while some rule's name appears in no
golden output, so a new rule needs a golden case, and
`test/golden/citations.ml` fails while an expected output of a golden
or run test says the word "design": a diagnostic says what is wrong in
the terms of the user's text, and its rule name is the reference.
`test/run` holds cram tests that run `typec` and the backends;
`types.t` and `declarations.t` compile static assertions of what typec
computes, so a backend that disagrees fails to compile them.
`test/misuse` holds OCaml that an interface must refuse; each file names
its library and the expected error text in a `(* misuse: LIBRARY TEXT *)`
line, and passes only when `ocamlc` rejects it with that text.

## Choosing the backend

The backend is the program named by the last `--cc=PATH` option, else by
the `TYPEC_CC` environment variable when it is set and not empty, else
`cc`. A name without a slash is looked up in `PATH`. `typec` consumes
`--cc=`, `--print-target`, `--emit-c`, `--stats` and `--trap-function=`
where an option can stand (the value of `-o` is never one) and forwards
every other argument, `--cc` without `=` included, in its original
order. The backend is run with an
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
with the same signal. `typec` exits with 81 when `--cc=` has no path,
`--trap-function=` names no C identifier, the backend cannot be started
or the backend runs `typec` again, after one
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

1. `BACKEND -E -D__TYPEC__=1 -std=gnu17 OPTIONS -dD -x c FILE.tc`,
   with its stdout in a private temporary directory; `-dD` keeps each
   `#define` and `#undef` in the text, so that `typec` knows which names
   are macros where;
2. `typec` reads the preprocessed text, parses it and reads its
   declarations at file scope, then emits it. The declarations are read
   for the target model that the backend gives with the options of step
   3 (see "Printing the target model"). A text that the front end
   refuses stops `typec` with one message, `FILE:LINE: MESSAGE`. With no
   Type-C construct the emitted text is the preprocessed text, byte for
   byte, but that each `#define` and `#undef` line is left empty;
3. `BACKEND -std=gnu17 OPTIONS -c -o OUTPUT -x cpp-output EMITTED`,
   with `-S` in place of `-c`, or `-fsyntax-only` in place of `-c -o
   OUTPUT`, as the command line asks, and with `-fno-trigraphs` last on
   Clang, which makes Clang read EMITTED without trigraphs, as `typec`
   read it (design 13.2).

On Clang, steps 1 and 3 also get `-Wno-unused-command-line-argument`
before OPTIONS, so that Clang does not warn about an option of the
command line that the step does not use. GCC does not know the option,
so its steps go without it. The query for the target model runs before
the backend is known and gets it on both.

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
With `-M` or `-MM` the command line compiles nothing: step 1 of each
`.tc` input prints its rule in place of the preprocessed text, to the
`-o` file or stdout, and one more backend command gets the command line
without the `.tc` inputs, when other inputs remain, to print theirs.

`--emit-c` stops after step 2 and writes the C to the `-o` file, or to
stdout; the command line then has exactly one input, a `.tc` file.

`--trap-function=NAME` makes every trap of the emitted C (a corrupted
tag, a slice index out of range) call `_Noreturn void NAME(void)`, which
the program supplies, instead of executing `__builtin_trap()` alone; a
freestanding program uses it to report the failure (design 10.5). NAME
is a C identifier of ASCII letters, digits and underscores, and the last
`--trap-function=` wins. NAME is the name the program defines, not a
macro: the emitted C is already preprocessed, so `-DNAME=...` does not
change it. A `.tc` unit that holds a Type-C construct declares NAME
after its own text, so a declaration of NAME in the program with
another type is a backend error reported at typec's text (`<typec>`).

`--stats` prints on stderr, for each `.tc` input, one line
`typec: stats: FILE: ` and the fields `unit_bytes` (the preprocessed
unit), `instance_bytes` (charged to the instance budget),
`copy_bytes` (the front end's charge to the output limit for the
copies of deferred statements, which `output_bytes` counts again),
`output_bytes` (charged to the output limit by lowering, the unit's own
text included), `output_limit`, `longest_instance_code` (the most bytes
of the code of one instance, its generic's name and the encodings of its
arguments, that the bound on encodings holds) and `longest_name` (of a
type declaration or a generic function, the universe text included),
each as `name=value`: the counts of design 3.5 rule 7 that the
measurements of P30 read. Then come the slice tests of the unit and of
each instance that it uses, which the measurements of P28 read:
`slice_indexes`, `slice_subs` and `slice_conversions` (those that C
evaluates, which lowering writes with a test), `slice_untested` (those
that C does not evaluate) and `slice_late_calls` (the tested indexes and
`slice_sub`s with a call or a statement expression in an operand after
the first). Last come the most steps (`selection_steps`), nodes
(`selection_nodes`) and nodes on one path (`selection_depth`) that
building the selection tree of one match or test of the unit or of an
instance took, which the measurements of P32 read, each the most over
all of them. The holders of a `try` of the unit and of each instance come
last, which the measurements of P33 to P35 read: `try_holders` (the
holders), `try_tries` (their `try` expressions), `try_first_operands`
(the hoisted operands that are the first operand of `&&`, `||` or a
conditional operator or the left operand of a comma), `try_conditioned`
(the hoisted operands under a condition) and `try_multiple` (the holders
with more than one hoisted operand). A unit that typec refuses reports
none.

A `.tc` input refuses the option that stops the backend at
preprocessing (`-E`), the options that change the preprocessed text
(`-P`, `-C`, `-CC`, `-fuse-line-directives`, `-traditional-cpp`,
`-fdirectives-only`), every `-d` option of dumps (`-dD`, `-dM`, `-dI`
and the like), alone or passed on by `-Wp,`, `-Xpreprocessor` or
`-Xclang` (which so refuses Clang's `-Xclang -disable-O0-optnone` too),
`-save-temps`, `-###`, `-ansi`, `--`, the options that
name a file of further options (response files, `@FILE`, `-specs=` and
`--config=`) and the queries that print a fact of the backend
(`-print-file-name=` and every other `-print-` option, `-dumpmachine`),
with a usage error naming the option.
It refuses a long option, spelled with `--`, that it does not know, as
GCC reads `--NAME` as `-fNAME` and accepts abbreviations, so that
`--preprocess`, `--write-user-dep` or `--short-enums` cannot reach the
backend unseen; an option that also has a form with one `-` passes
in that form.
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

A freestanding build passes `-ffreestanding -nostdlib` as for C. The
objects need from the environment what the same C needs, such as
`memset`, and nothing more: a trap is `__builtin_trap()`, an
instruction on x86-64 and AArch64
([design 10.4](type-c-language-design.md#104-functions-and-objects)).

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
