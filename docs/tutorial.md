<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/tutorial.t checks the examples of this file on Clang and GCC:
test/run/readme.sh says how the blocks are marked. A stage marker
starts a directory that holds the files of the stage before, so that
each stage of the program is built as it is shown.
-->

# A tutorial for C programmers

This tutorial grows one C program into Type-C, a chapter for each thing
that Type-C adds: the C problem, the Type-C that solves it, the C that
`typec` writes, and a pitfall. It assumes that you write C and doubt
that a new language helps. The [README](../README.md) describes each
feature and this page does not repeat it. The tests of
[`test/run/tutorial.t`](../test/run/tutorial.t) build and run every
example here on GCC and Clang, so each one uses only what `typec` builds.

The program reads a file of `key = value` lines into a structure. Each
chapter shows the files it changes, whole, and the others stay as the
chapter before left them: replace a file with its new text and run the
commands from one directory. You need `typec` on your `PATH`
([Try it](../README.md#try-it)).

## 1. Adopting one file

Three C files, as you have written them. `main.c` loads a file,
`load.c` reads it a line at a time, and `conf.c` applies a line to a
`struct conf`.

<!-- stage: c1_c -->
<!-- file: units.h -->
```c
#include <stdint.h>

typedef uint16_t port;
typedef unsigned seconds;
```

<!-- file: conf.h -->
```c
#include "units.h"

struct conf {
	port		bind_port;
	seconds		timeout;
	int		debug;
};

/* Applies a line such as "port = 8080" to *c: 0 when it is fine, else -1. */
int conf_apply(const char *line, struct conf *c);

/* Applies each line of a file and reports those it cannot: 0 or -1. */
int conf_load(const char *path, struct conf *c);
```

<!-- file: main.c -->
```c
#include <stdio.h>
#include "conf.h"

int
main(int argc, char **argv)
{
	struct conf c = {0};

	if (argc != 2 || conf_load(argv[1], &c) != 0)
		return (1);
	printf("port %u, timeout %u s, debug %d\n",
	    (unsigned)c.bind_port, (unsigned)c.timeout, c.debug);
	return (0);
}
```

<!-- file: load.c -->
```c
#include <stdio.h>
#include <string.h>
#include "conf.h"

int
conf_load(const char *path, struct conf *c)
{
	char line[128];
	int status = -1, n = 0;
	FILE *f;

	f = fopen(path, "r");
	if (f == NULL)
		goto done;
	status = 0;
	while (fgets(line, sizeof(line), f) != NULL) {
		n++;
		line[strcspn(line, "\n")] = '\0';
		if (conf_apply(line, c) != 0) {
			fprintf(stderr, "%s:%d: cannot apply '%s'\n",
			    path, n, line);
			status = -1;
		}
	}
	fclose(f);
done:
	return (status);
}
```

<!-- file: conf.c -->
```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "conf.h"

int
conf_apply(const char *line, struct conf *c)
{
	char key[32], value[32];
	unsigned long n;

	if (line[0] == '\0' || line[0] == '#')
		return (0);
	if (sscanf(line, " %31[a-z_] = %31s", key, value) != 2)
		return (-1);
	n = strtoul(value, NULL, 10);
	if (strcmp(key, "port") == 0) {
		if (n < 1 || n > 65535)
			return (-1);
		c->bind_port = (port)n;
		return (0);
	}
	if (strcmp(key, "timeout") == 0) {
		c->timeout = (seconds)n;
		return (0);
	}
	if (strcmp(key, "debug") == 0) {
		c->debug = strcmp(value, "yes") == 0;
		return (0);
	}
	return (-1);
}
```

<!-- file: demo.conf -->
```text
# demo
port = 8080
timeout = 30
debug = yes
```

```console
$ cc -Wall -Wextra -o conf main.c conf.c load.c
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

It has the faults of such C. `port` and `seconds` are names of an
integer, so `c->bind_port = c->timeout` compiles. An unknown key and a
bad line are the same `-1`, and `debug = maybe` is `no`. The chapters
that follow remove them.

`typec` takes the command line of `cc`, and a C11 file is a Type-C file
with the same meaning, so renaming `conf.c` and building with `typec`
where `cc` stood is the first step:

<!-- stage: c1_tc -->
```console
$ mv conf.c conf.tc
$ typec -Wall -Wextra -o conf main.c conf.tc load.c
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

`main.c` and `load.c` went to the C compiler untouched. `conf.tc` went
through `typec`, which found no Type-C in it and handed the C compiler
its preprocessed text as read: no runtime, nothing added to the link
([the few rules of a `.tc` file](../README.md#adopting-one-file)).

Now use something new. The chain of `strcmp` classifies a name: it is
one of three keys, or none. That is a variant, a type that is exactly
one of its cases. It goes in an interface file, a `.tci`, which is a
header for Type-C files: `key.tci` declares it, `key.tc` makes it, and
`conf.tc` includes the interface and takes the variant apart with
`match`.

<!-- stage: c1_key -->
<!-- file: key.tci -->
```c
type key = | Port | Timeout | Debug | Unknown;

key key_of(const char *name);
```

<!-- file: key.tc -->
```c
#include <string.h>
#include "key.tci"

key
key_of(const char *name)
{
	if (strcmp(name, "port") == 0)
		return (Port);
	if (strcmp(name, "timeout") == 0)
		return (Timeout);
	if (strcmp(name, "debug") == 0)
		return (Debug);
	return (Unknown);
}
```

<!-- file: conf.tc -->
```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "conf.h"
#include "key.tci"

int
conf_apply(const char *line, struct conf *c)
{
	char name[32], value[32];
	unsigned long n;

	if (line[0] == '\0' || line[0] == '#')
		return (0);
	if (sscanf(line, " %31[a-z_] = %31s", name, value) != 2)
		return (-1);
	n = strtoul(value, NULL, 10);
	match (key_of(name)) {
	case Port:
		if (n < 1 || n > 65535)
			return (-1);
		c->bind_port = (port)n;
		return (0);
	case Timeout:
		c->timeout = (seconds)n;
		return (0);
	case Debug:
		c->debug = strcmp(value, "yes") == 0;
		return (0);
	case Unknown:
		return (-1);
	}
}
```

```console
$ typec -Wall -Wextra -o conf main.c conf.tc key.tc load.c
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

Both directions of the boundary are plain C. `conf.tc` calls `sscanf`
and `strtoul` with no binding, and `load.c` calls `conf_apply`, which is
Type-C now, as any C function: no mangling, no glue. C sees a variant as
the structure of a tag and a union
([Using Type-C types from C](../README.md#using-type-c-types-from-c)),
and `typec --emit-c-header key.tci` writes `key.h`, the header that a C
file includes to read one. The functions that C calls keep C types, as
`conf_apply` does.

A pitfall: `typec` takes C11 and C17 only, so a build that gives its C
files `-std=c99` leaves the option out for a `.tc` file, and `typec`
says so rather than compile another language:

```console
$ typec -std=c99 -c key.tc
typec: -std=c99 cannot be used with a .tc input: Type-C accepts C11 and C17, in ISO or GNU form
[81]
```

And a `type` is for `.tc` files alone, so a header that C files
include too, as `conf.h` does, must show them plain C. Chapter 2 does
that with `__TYPEC__`.

## 2. Distinct types

`typedef uint16_t port;` is a comment: `c->bind_port = c->timeout`
compiles. A distinct type has the representation of another and
converts to nothing, and from nothing, without a cast. `conf.tc` already
casts where an integer becomes a `port`, so only `units.h` changes. Type-C
files see the distinct types, and `typec` defines `__TYPEC__` while it
preprocesses them, so C files still see the `typedef`.

<!-- stage: c2 -->
<!-- file: units.h -->
```c
#include <stdint.h>

#ifdef __TYPEC__
type port = distinct uint16_t;
type seconds = distinct unsigned;
#else
typedef uint16_t port;
typedef unsigned seconds;
#endif
```

```console
$ typec -Wall -Wextra -o conf main.c conf.tc key.tc load.c
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

`main.c` and `load.c` compile as C and the program is the same, but the
mix that compiled before is an error in Type-C:

<!-- file: mixed.tc -->
```c
#include "conf.h"

void
reset(struct conf *c)
{
	c->bind_port = c->timeout;
}
```

```console
$ typec -c mixed.tc
mixed.tc:6: error: a value of type 'seconds' does not convert to 'port' without a cast [distinct-conversion]
    6 | 	c->bind_port = c->timeout;
[80]
```

The check costs nothing at run time. The type is a name, and `typec`
writes the `typedef` that you would have:

<!-- file: minutes.tc -->
```c
type seconds = distinct unsigned;

seconds
minutes(unsigned m)
{
	return ((seconds)(m * 60));
}
```

<!-- emit-c: minutes.tc -->
```c
typedef unsigned seconds;

seconds
minutes(unsigned m)
{
  return ((seconds)(m * 60));
}
```

The pitfall is the price of the check. Arithmetic, `<` and the other
relations on a distinct type are errors too, so a function that adds two
`seconds` casts out to `unsigned` and back, once, where it can say what
the sum means ([design 3.4](../type-c-language-design.md#34-distinct-types)
has the table). A cast also skips every check, so `(port)n` is as good as
the test before it. A `private` distinct type, declared in a `.tci`, can
be made only by that interface and the source file of the same name
([Private types and interfaces](../README.md#private-types-and-interfaces)).

## 3. Variants and `match`

`conf_apply` takes a line apart and acts on it in one pass. A line is
nothing, a setting of a key to a value, or garbage, and a value is a
number or a word. In C that is a tag, a union and a `switch`, with the
faults that the README shows: a field read under the wrong tag, and a
case that a `switch` lets slip. In Type-C the fields belong to their
cases.

<!-- stage: c3 -->
<!-- file: line.tci -->
```c
#include "key.tci"

type value = | Number(unsigned long n) | Word(const char *text);

type line = | Blank | Setting(key name, value v) | Garbage;

line parse_line(const char *text);
```

<!-- file: line.tc -->
```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "line.tci"

/* The Word points into text, so it is good as long as text is. */
line
parse_line(const char *text)
{
	char name[32], *end;
	const char *rest;
	int len = -1;
	unsigned long n;

	if (text[0] == '\0' || text[0] == '#')
		return (Blank);
	sscanf(text, " %31[a-z_] =%n", name, &len);
	if (len < 0)
		return (Garbage);
	rest = text + len + strspn(text + len, " ");
	n = strtoul(rest, &end, 10);
	if (end != rest && *end == '\0')
		return (Setting(key_of(name), Number(n)));
	return (Setting(key_of(name), Word(rest)));
}
```

A case is made by its name, as `Number(n)` is, and read by a `match` or
an `if (case ...)`. Patterns nest, so one `match` tells a numeric port
from a word, and `typec` checks that the arms cover every value.
`if (case ...)` asks one question and binds its names where the answer
is yes:

<!-- file: conf.tc -->
```c
#include <stdio.h>
#include <string.h>
#include "conf.h"
#include "line.tci"

static int
privileged(line l)
{
	if (case Setting(Port, Number(n)) = l)
		return (n < 1024);
	return (0);
}

int
conf_apply(const char *text, struct conf *c)
{
	line l = parse_line(text);

	if (privileged(l))
		fprintf(stderr, "note: ports below 1024 need privileges\n");
	match (l) {
	case Blank:
		return (0);
	case Setting(Port, Number(n)):
		if (n < 1 || n > 65535)
			return (-1);
		c->bind_port = (port)n;
		return (0);
	case Setting(Timeout, Number(n)):
		c->timeout = (seconds)n;
		return (0);
	case Setting(Debug, Word(word)):
		c->debug = strcmp(word, "yes") == 0;
		return (0);
	case Setting(_, _):
	case Garbage:
		return (-1);
	}
}
```

<!-- file: bad.conf -->
```text
debug = maybe
timeout = soon
port = 70000
```

```console
$ typec -Wall -Wextra -o conf main.c conf.tc line.tc key.tc load.c
$ ./conf bad.conf
bad.conf:2: cannot apply 'timeout = soon'
bad.conf:3: cannot apply 'port = 70000'
[1]
$ printf 'port = 80\n' > low.conf
$ ./conf low.conf
note: ports below 1024 need privileges
port 80, timeout 0 s, debug 0
```

The names that a pattern binds are `const` copies of the fields, so an
arm cannot change the variant it reads. In C the variant is a tag and
a union, and a constructor is a compound literal; `typec --emit-c`
prints them ([What the C looks
like](../README.md#what-the-c-looks-like)).

The pitfall is in that run: `debug = maybe` was applied, as the arm for
`Word` takes any word. The last arm, `Setting(_, _)`, is the same
mistake. It covers every key and value that no arm above it names,
including a key added later, so the check that would stop the build at the
new key cannot. Write a wildcard where the cases are really one case, not
to stop thinking about the rest. The next chapter lists them.

## 4. `result`, `option`, `try` and `defer`

`conf_apply` returns `-1` for every fault, and `load.c` can say only
that a line is bad. A fallible C function returns a code and puts the
detail in `errno`, a global or a message printed on the spot. A Type-C
function returns a `result(T, E)`: `Ok` with a value, or `Err` with an
error that can be a variant with fields of its own. A call that drops a
`result` is an error. `option(T)` is `None` or `Some` of a value, for
the `NULL` or `-1` that means "no such thing".

`try` takes the value of an `Ok`, or returns the `Err` from the function
at once, and it stands inside an expression. `defer` runs a statement at
every exit of its scope, a `try` included.

The errors become a type that `conf.tc` and `load.tc` share. The `match`
of `conf_set` names every key, so a new key stops the build there;
`conf_load` ends in `Err(_)`, which is right where every other fault is
reported alike.

<!-- stage: c4 -->
<!-- file: conf.tci -->
```c
#include "conf.h"
#include "line.tci"

type conf_error =
    | CannotOpen
    | NotASetting
    | UnknownKey
    | OutOfRange(unsigned long n)
    | BadValue;

result(void, conf_error) conf_set(const char *text, struct conf *c);
```

<!-- file: conf.tc -->
```c
#include <string.h>
#include "conf.tci"

static option(int)
switch_of(const char *word)
{
	if (strcmp(word, "yes") == 0)
		return (Some(1));
	if (strcmp(word, "no") == 0)
		return (Some(0));
	return (None);
}

static result(unsigned long, conf_error)
to_number(value v)
{
	if (case Number(n) = v)
		return (Ok(n));
	return (Err(BadValue));
}

static result(port, conf_error)
to_port(value v)
{
	unsigned long n = try to_number(v);

	if (n < 1 || n > 65535)
		return (Err(OutOfRange(n)));
	return (Ok((port)n));
}

static result(int, conf_error)
to_switch(value v)
{
	if (case Word(word) = v)
		if (case Some(on) = switch_of(word))
			return (Ok(on));
	return (Err(BadValue));
}

result(void, conf_error)
conf_set(const char *text, struct conf *c)
{
	match (parse_line(text)) {
	case Blank:
		return (Ok);
	case Setting(Port, value v):
		c->bind_port = try to_port(v);
		return (Ok);
	case Setting(Timeout, value v):
		c->timeout = (seconds)try to_number(v);
		return (Ok);
	case Setting(Debug, value v):
		c->debug = try to_switch(v);
		return (Ok);
	case Setting(Unknown, _):
		return (Err(UnknownKey));
	case Garbage:
		return (Err(NotASetting));
	}
}

int
conf_apply(const char *text, struct conf *c)
{
	if (case Ok = conf_set(text, c))
		return (0);
	return (-1);
}
```

A pattern binds a field of a variant type with its type, as `value v`
does, so that a name cannot be taken for a constructor. `try` stands
in a declaration (`to_port`) and in a cast (`(seconds)try to_number(v)`).
`conf_apply` stays for C callers: it turns the `result` into the `0` or
`-1` that C reads with no declaration of its own.

`load.c` becomes `load.tc`. The `goto done` becomes a `defer` on the line
after the `try` that opens the file, and the `try` below it and each
`return` close the file:

<!-- file: load.tc -->
```c
#include <stdio.h>
#include <string.h>
#include "conf.tci"

static result(FILE *, conf_error)
open_file(const char *path)
{
	FILE *f;

	f = fopen(path, "r");
	if (f == NULL)
		return (Err(CannotOpen));
	return (Ok(f));
}

static result(void, conf_error)
load(const char *path, struct conf *c, int *number)
{
	char text[128];
	FILE *f;

	f = try open_file(path);
	defer fclose(f);
	while (fgets(text, sizeof(text), f) != NULL) {
		(*number)++;
		text[strcspn(text, "\n")] = '\0';
		try conf_set(text, c);
	}
	return (Ok);
}

int
conf_load(const char *path, struct conf *c)
{
	int number = 0;

	match (load(path, c, &number)) {
	case Ok:
		return (0);
	case Err(CannotOpen):
		fprintf(stderr, "%s: cannot open\n", path);
		return (-1);
	case Err(OutOfRange(n)):
		fprintf(stderr, "%s:%d: %lu is out of range\n",
		    path, number, n);
		return (-1);
	case Err(_):
		fprintf(stderr, "%s:%d: cannot apply the line\n",
		    path, number);
		return (-1);
	}
}
```

The run now stops at the first fault and reports it. `Err(OutOfRange(n))`
is a nested pattern, so the one `match` tells the faults apart:

```console
$ typec -Wall -Wextra -o conf main.c conf.tc line.tc key.tc load.tc
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
$ ./conf bad.conf
bad.conf:1: cannot apply the line
[1]
$ printf 'port = 70000\n' > big.conf
$ ./conf big.conf
big.conf:1: 70000 is out of range
[1]
$ ./conf missing.conf
missing.conf: cannot open
[1]
```

A `try` is an early `return` that runs the deferred statements in force,
and `defer` is no destructor bound to a value: its statement is written
at each exit and reads what its variables hold there. So a variable that
a `defer` names must not be reused for another resource, as `handle`
shows here:

<!-- file: late.tc -->
```c
int printf(const char *format, ...);

int
main(void)
{
	int handle = 1;

	defer printf("release %d\n", handle);
	handle = 2;
	return (0);
}
```

```console
$ typec -o late late.tc
$ ./late
release 2
```

The C that `typec` writes holds the value of the `return` first, then
the statement, then the `return`, with no table or unwinding:

<!-- emit-c: late.tc -->
```c
int printf(const char *format, ...);

int
main(void)
{
  typedef __typeof__(((__typeof__(main) *)0)()) __tc_ret;
  {
    int handle = 1;
    handle = 2;
    {
      __tc_ret __tc_r0 = ((0));
      { printf("release %d\n", handle); }
      return __tc_r0;
    }
    __builtin_trap();
  }
}
```

The second pitfall is the error type. `try` returns the error as it found
it, so the function that holds it returns a `result` with the identical
error type ([`try-error-type`](../type-c-language-design.md#51-try)),
and there is no conversion between two. To add context, as a line number,
a function matches on the result and builds an error of its own type.

## 5. Generic types and functions

C has two ways to write a container once: a `void *` that gives up the
type, or a macro that writes a new structure at each use, so that two
spellings of one type do not match. This program has the case: `key_of`
is a chain of `strcmp`, and a table of names to values is the same code
for any value. A generic type takes type parameters, and `entry(int)` is
one type wherever it is written. A generic function is checked once,
where it is written, and its instances are made where it is called.

`table.tci` holds both, so that every file can use them, and `key.tc`
shrinks to a table:

<!-- stage: c5 -->
<!-- file: table.tci -->
```c
#include <string.h>

type entry(T) = struct { const char *name; T value; };

/* The value of the entry called name, if the table has one. */
generic(T) option(T)
lookup(const entry(T) *table, size_t n, const char *name)
{
	for (size_t i = 0; i < n; i++)
		if (strcmp(table[i].name, name) == 0)
			return (Some(table[i].value));
	return (None);
}
```

<!-- file: key.tc -->
```c
#include "table.tci"
#include "key.tci"

static const entry(key) keys[] = {
	{"port", Port}, {"timeout", Timeout}, {"debug", Debug},
};

key
key_of(const char *name)
{
	size_t n = sizeof(keys) / sizeof(keys[0]);

	if (case Some(key k) = lookup(keys, n, name))
		return (k);
	return (Unknown);
}
```

```console
$ typec -Wall -Wextra -o conf main.c conf.tc line.tc key.tc load.tc
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

The call `lookup(keys, n, name)` deduces `T` as `key` from the table.
Each instance of a generic type is a structure of C named after its
arguments, as chapter 7 shows, and C converts no structure to another,
so a table of `int` does not pass where a table of `key` is wanted, as a
`void *` table would.

The pitfall is what a type parameter allows. In `lookup`, `T` is opaque:
the body is checked once, for every `T`, so it can copy a `T`, store it
and take its address and size, but not compare, add or call it. A
container that needs those takes them as function pointers.

<!-- file: same.tc -->
```c
generic(T) int
same(T a, T b)
{
	return (a == b);
}
```

```console
$ typec -c same.tc
same.tc:4: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
    4 | 	return (a == b);
[80]
```

A macro version compiles for `int` and fails for a structure only where
someone uses it.

## 6. Slices and `str`

A C function that takes a table or a text takes a pointer and a count,
`lookup(keys, n, name)`, and trusts both. A slice is the pair as a
type, `slice(T)`, and `str` is `slice(const char)`: a pointer and a
length, with no NUL. Every `s[i]` of a slice checks the index, and
`slice_from_array(a)` makes the slice of an array, so no count is spelled.
The table of chapter 5 takes slices:

<!-- stage: c6 -->
<!-- file: table.tci -->
```c
#include <string.h>

type entry(T) = struct { str name; T value; };

static inline int
str_equal(str a, str b)
{
	return (a.len == b.len && memcmp(a.data, b.data, a.len) == 0);
}

/* The value of the entry called name, if the table has one. */
generic(T) option(T)
lookup(slice(const entry(T)) table, str name)
{
	for (size_t i = 0; i < table.len; i++)
		if (str_equal(table[i].name, name))
			return (Some(table[i].value));
	return (None);
}
```

<!-- file: key.tc -->
```c
#include "table.tci"
#include "key.tci"

static const entry(key) keys[] = {
	{"port", Port}, {"timeout", Timeout}, {"debug", Debug},
};

key
key_of(const char *name)
{
	str s = slice_unchecked(name, strlen(name));

	if (case Some(key k) = lookup(slice_from_array(keys), s))
		return (k);
	return (Unknown);
}
```

```console
$ typec -Wall -Wextra -o conf main.c conf.tc line.tc key.tc load.tc
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

A string literal where a `str` is wanted is a `str` of its characters,
as the names of the table are. `slice_unchecked(p, n)` takes a pointer
and a count on trust, here where a C string comes in; every index after
it is checked, and `slice_sub(s, lo, hi)` checks a range the same way.
The check is code in the function that indexes, with the trap that ends
every `match`:

<!-- file: at.tc -->
```c
char
at(str s, unsigned long i)
{
	return (s[i]);
}
```

<!-- emit-c: at.tc -->
```c
typedef const char __tc_arg__Kc;
struct slice__Kc; typedef struct slice__Kc slice__Kc;
struct slice__Kc { __tc_arg__Kc *data; __typeof__(sizeof 0) len; };

char
at(slice__Kc s, unsigned long i)
{
  struct slice__Kc __tc_s0;
  __typeof__(__tc_s0.len) __tc_i0;
  {
    return ((*((void)(__tc_s0 = (s)),
               (void)(__tc_i0 = (__typeof__(__tc_i0))(i)),
               (void)(__tc_i0 < __tc_s0.len ? (void)0 : __builtin_trap()),
               &__tc_s0.data[__tc_i0])));
  }
}
```

A check that fails stops the program at the trap: the system kills it
with a signal, SIGILL on x86-64, and the shell reports an illegal
instruction, not the line. A debugger names the line. Built with `-g`,
the program stops in the debugger at the check that failed, and since
the C that typec emits keeps the lines of the `.tc` files, the location
is one of theirs: the line of the `.tc` file, with a column of the
emitted C. `peek.tc` reads one character past the end of `"port"`:

<!-- file: peek.tc -->
```c
#include <stdio.h>

char at(str s, unsigned long i);

int
main(void)
{
	printf("%c\n", at("port", 4));
	return (0);
}
```

```console
$ typec -g -o peek peek.tc at.tc
```

<!-- console: lldb -->
```console
$ lldb --batch -o run ./peek | grep -o 'at\.tc:[0-9]*'
at.tc:4
```

`lldb ./peek` and then `run` shows the same stop with the source around
it; the `grep` keeps only the location from lldb's report.

Outside a debugger, the program can at least say why it stopped.
`--trap-function=on_trap` makes every trap call `on_trap`, which the
program supplies, before `__builtin_trap()`. It takes no arguments, so
it cannot know the line; it says that a check failed, and ends in
`abort()`, whose stack a debugger still shows:

<!-- file: on_trap.c -->
```c
#include <stdio.h>
#include <stdlib.h>

/* Every trap of the .tc files calls this: a check failed. */
_Noreturn void
on_trap(void)
{
	fputs("peek: a checked index or tag failed\n", stderr);
	abort();
}
```

```console
$ typec -g --trap-function=on_trap -o peek peek.tc at.tc on_trap.c
```

<!-- console: lldb -->
```console
$ lldb --batch -o run -k bt ./peek | grep -o -e 'peek: [a-z ]*' -e 'at\.tc:[0-9]*'
peek: a checked index or tag failed
at.tc:4
```

Run alone, the program prints the message and aborts. Under lldb,
`-k bt` prints the backtrace once the abort stops the program: below
`abort` it holds `on_trap`, then `__tc_trap`, the function at `<typec>`
through which typec calls it, then `at` at `at.tc:4` and `main`; the
`grep` keeps the message and the line of `at`. On macOS, `on_trap` can
also print the stack itself with `backtrace()` and
`backtrace_symbols_fd()` of `<execinfo.h>`, which name the functions
but not the lines.

The pitfalls follow from what a slice is: a pointer and a count, and
no more. It owns nothing and keeps nothing alive, so the slice of a local
array that a function returns dangles as the pointer would. A `str` is
not a C string: it promises no NUL, so `printf("%s", s.data)` can read
past the end. `printf("%.*s", (int)s.len, s.data)` is no better for a `str`
of 2 GiB or more: the `int` cast wraps negative, and a negative precision
means none. The spelling is `fwrite(s.data, 1, s.len, stdout)`, which takes
a `size_t` length and needs no NUL.
And `s.data[i]` is the unchecked index, visible where it is written.

## 7. Reading the errors and the C

`typec` stops at the first error and prints it as GCC and Clang print
theirs, `file:line: error: message` with the line of the source under
it, and exits with 80. There is a line and no column, so no caret. An
error under a rule of Type-C ends with the rule's name
in brackets, the thing to search for: `dune build docs/diagnostics.md`
writes the catalog of names ([What typec
reports](../README.md#what-typec-reports)).

What stops a build is what you want to stop it. Add a key to the variant,
and the `match` of `conf_set` names the value that it no longer covers, as
the `Setting(_, _)` of chapter 3 would have hidden. The commands edit
copies and put the files back:

<!-- stage: c7 -->
```console
$ cp key.tci key.tci.orig
$ sed -i.bak 's/| Debug/| Debug | Name/' key.tci
$ typec -c conf.tc
conf.tc:44: error: the match does not cover the value 'Setting(Name, _)' [match-coverage]
   44 | 	match (parse_line(text)) {
[80]
$ mv key.tci.orig key.tci
```

Drop the `try` in front of `conf_set` in `load.tc`, and the result that
nothing reads is the error, not a warning to find in a log:

```console
$ cp load.tc load.tc.orig
$ sed -i.bak 's/try conf_set(text, c);/conf_set(text, c);/' load.tc
$ typec -c load.tc
load.tc:27: error: a value of a result type is discarded; handle it with try or match, store it, or cast it to void [discarded-result]
   27 | 		conf_set(text, c);
[80]
$ mv load.tc.orig load.tc
```

The C compiler reads what `typec` writes, with line markers that point
into your `.tc` file, so its warnings name your file and line, and
`-Wall -Wextra` warns of the C that you wrote. An error of the C compiler in
the C that `typec` wrote comes with that compiler's message and status,
not 80, and it is a bug of `typec` to report: the lowered C is not for you
to patch.

`typec --emit-c` prints the C, to read when you wonder what a construct
became. Your names are kept: `key_Port` is the `Port` of `key`. An
instance of a generic is named after its arguments, each a code (`i` for
`int`, `v` for `void`) or a length and a name, so these are the
`result` instances that `conf.tc` makes. The temporaries begin with `__tc_`, a
prefix that a `.tc` file may not use.

```console
$ typec --emit-c conf.tc | grep -o 'struct result__[A-Za-z0-9_]* {' | sort -u
struct result__4port10conf_error {
struct result__i10conf_error {
struct result__m10conf_error {
struct result__v10conf_error {
```

## 8. In a build, and freestanding

To a build, `typec` is a C compiler, so a build changes in two places:
the rule for a `.tc` file, which is the rule for a `.c` file, and the
compiler's name, `CC=typec`. The dependency options work as for C, and
the file lists each `.tci` that a source reads, so that make and ninja
rebuild what a change reaches. The README gives the rules for [make,
ninja and CMake](../README.md#in-a-build), which its tests build with.
Here the program is built as objects:

<!-- stage: c8 -->
```console
$ typec -Wall -Wextra -MMD -c conf.tc
$ cat conf.d
conf.o: conf.tc conf.tci conf.h units.h line.tci key.tci
$ typec -Wall -Wextra -c main.c line.tc key.tc load.tc
$ typec main.o conf.o line.o key.o load.o -o conf
$ ./conf demo.conf
port 8080, timeout 30 s, debug 1
```

`TYPEC_CC` or `--cc=` names the C compiler that `typec` hands the C to
([Choosing the backend](../README.md#choosing-the-backend)).

A freestanding program has no library to report a trap, and no
debugger may be at hand. The `--trap-function` of chapter 6 is its
report: each trap of the emitted C, a bad index or a corrupt tag, calls
the `_Noreturn void NAME(void)` that the program supplies instead of
executing the trap instruction alone:

<!-- file: ring.tc -->
```c
#include <stddef.h>

_Noreturn void fail(void);

unsigned char
get(slice(unsigned char) buf, size_t i)
{
	return (buf[i]);
}
```

```console
$ typec -ffreestanding --trap-function=fail -c ring.tc
$ nm -u ring.o | grep -cE '(^| )_?fail$'
1
```

Such an object needs from its environment what the same C needs, and
nothing that the program did not write
([Compiling a `.tc` input](../README.md#compiling-a-tc-input);
`test/run/freestanding.t` links with `-nostdlib`).

Next: the README says what each feature rules out, and what is not
built yet is in its [Status](../README.md#status). The
[design](../type-c-language-design.md) states every rule.
