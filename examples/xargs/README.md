<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The excerpts of original/xargs.c, original/strnsubst.c, xargs.tc and
strnsubst.tc below keep the licenses of those files.
-->

<!--
test/run/example_readmes.t checks the console blocks of this file on
Clang and GCC, but those marked untested: test/run/readme.sh says how
the blocks are marked.
-->

# xargs: a FreeBSD utility in Type-C

[`xargs.tc`](xargs.tc) and [`strnsubst.tc`](strnsubst.tc) are FreeBSD's
`xargs(1)` ported to Type-C, and [`original/`](original/) holds the C
they port, unchanged: `usr.bin/xargs/xargs.c`, `strnsubst.c` and
`pathnames.h` of [freebsd-src](https://github.com/freebsd/freebsd-src)
at commit `b26f93a4650339ceb319fe772faaca7389110113` ("xargs: Convert
tests to ATF", 2025-07-26), the last commit that changes
`usr.bin/xargs` on `main`. `xargs.c` last changed in `a7fa987abe1f`
("xargs: Limit -n to {ARG_MAX}", the same day), git blob
`2a7f026e5066ff5d56ee1d43469bbd02c2593d98`; `strnsubst.c` in
`1d386b48a555` (2023-08-16), blob
`1d4eaac777271d44e3c7627a03398d8df1272e39`; `pathnames.h` is blob
`b804276da175247691eb85ef6646aa8fe5b90f37`. `xargs.c` and its port carry
its BSD-3-Clause license, `strnsubst.c` and its port the notice of its
author.

`xargs` is a good test of a language for C programmers because it is
almost all error paths and resources: it splits its input with quotes and
backslashes into a fixed buffer, packs pointers into a fixed vector under
three limits (`-n`, `-s`, `-L`), substitutes into the utility's arguments
for `-I`, runs children in parallel for `-P`, and stops on a dozen
conditions, each with its own message and exit status.

The port keeps the original's functions, names, comments, control flow
and style(9) layout, and uses Type-C inside them: the modes become
variants that are matched where they are used, the errors of the input
and of running a command become a `result` that `try` hands up to `main`,
which prints upstream's messages, the buffers become slices, the cleanup a
`defer`, and the sentinels options. It takes the same options, prints the
same output and messages and exits with the same status, but for the
three upstream bugs it fixes, [below](#where-the-port-differs).
`make check` shows it: it runs both programs over 82 command lines,
error cases and limits among them, and compares what they print and how
they exit, and checks the port alone on 7 where the two differ.

```sh
make            # gmake on FreeBSD; builds xargs and original/xargs
make check
TYPEC_CC=gcc-14 make clean check
```

Five things stand between upstream's C and other systems, and the
[Makefile](Makefile) handles each outside the sources, so that
`original/` stays as upstream has it:

* glibc has no `strtonum(3)`: [`original/compat.h`](original/compat.h)
  defines it on Linux, with the BSD messages that `xargs` prints, and the
  Makefile puts it before each file with `-include`;
* glibc's `<unistd.h>` does not declare the `uintptr_t` that
  `strnsubst.c` uses: `compat.h` includes `<stdint.h>` on Linux;
* `xargs.c` includes FreeBSD's `<sys/limits.h>`:
  [`original/compat/sys/limits.h`](original/compat/sys/limits.h)
  includes `<limits.h>` instead where the system has none, as the
  Makefile searches `original/compat` with `-idirafter`, after the
  system's directories. The port includes `<limits.h>` itself;
* `strnsubst.c` includes `<sys/cdefs.h>`, which musl lacks:
  [`original/compat/sys/cdefs.h`](original/compat/sys/cdefs.h) is an
  empty one, found the same way;
* macOS declares `vfork` deprecated, and `xargs.c` compares an `int` with
  an `rlim_t`, so the Makefile turns those two warnings off where they
  apply.

## The diff, function by function

### The modes: `-I` and `-J` are a variant

The original keeps `-I` and `-J` in three variables, `Iflag`, `Jflag`
and `replstr`, that the option parser keeps in step: each of the two
options clears the other's flag and sets the string. The port makes
them one value, in which "a flag without its string" or "both flags"
cannot be written:

```diff
-static int cnt, Iflag, jfound, Lflag, Sflag, wasquoted, xflag;
+/* What -I and -J ask of the arguments read: the last of them wins. */
+type replace =
+    | NoReplace
+    | Insert(const char *replstr)	/* -I: into the utility's arguments */
+    | Join(const char *replstr);	/* -J: in place of one argument */
```

```diff
 		case 'I':
-			Jflag = 0;
-			Iflag = 1;
-			Lflag = 1;
-			replstr = optarg;
+			repl = Insert(optarg);
+			Lflag = Some(1);
 			break;
 		case 'J':
-			Iflag = 0;
-			Jflag = 1;
-			replstr = optarg;
+			repl = Join(optarg);
 			break;
```

After the options, `main` checks them in seven `if` statements over the
flags. The port checks `-I` and `-J` with one `match`, whose arms the
compiler holds to every mode. The order of the checks moves, but only
among calls of `usage()`, which print the same thing, so every command
line still meets the same message first:

```diff
-	if (!Iflag && Rflag)
-		usage();
-	if (!Iflag && Sflag)
-		usage();
-	if (Iflag && !Rflag)
-		Rflag = 5;
-	if (Iflag && !Sflag)
-		Sflag = 255;
 	if (xflag && !nflag)
 		usage();
-	if (Iflag || Lflag)
+	/* -I sets Lflag too. */
+	if (case Some = Lflag)
 		xflag = 1;
-	if (replstr != NULL && *replstr == '\0')
-		errx(1, "replstr may not be empty");
+	match (repl) {
+	case NoReplace:
+		if (Rflag || Sflag)
+			usage();
+		break;
+	case Insert(replstr):
+		if (!Rflag)
+			Rflag = 5;
+		if (!Sflag)
+			Sflag = 255;
+		if (*replstr == '\0')
+			errx(1, "replstr may not be empty");
+		break;
+	case Join(replstr):
+		if (Rflag || Sflag)
+			usage();
+		if (*replstr == '\0')
+			errx(1, "replstr may not be empty");
+		break;
+	}
```

The other uses test the one mode they need, and get its string from the
same test: `if (case Join(replstr) = repl)` where `main` looks for the
`-J` string among the utility's arguments, `if (case Insert = repl)`
where `parse_input` collects the line for `-I`, and
`if (case Insert(r) = repl)` in `prerun`.

### The line count of `-L` is an option

`Lflag` is 0 when neither `-L` nor `-I` was given, and the test that
ends a command after so many lines reads it as a number anyway:

```c
	if (xp == endxp || p > ebp || ch == EOF ||
	    (Lflag <= count && xflag) || foundeof) {
```

`&& xflag` is meant to stand for "-L was given", since `-L` sets
`xflag`, but `-x` sets it too. So `-n 3 -x` alone, which asks for three
arguments to a command and an error if they do not fit, makes `0 <=
count` true after every argument, and runs a command for each one, and
one with none for each empty line: the bug
[below](#what-the-port-found). The port makes "no count" a value of its
own, `option(int)`, which cannot be compared with `count` without asking
whether it is there:

```diff
-static int cnt, Iflag, jfound, Lflag, Sflag, wasquoted, xflag;
+static option(int) Lflag;	/* the lines of -L, or of -I */
```

```diff
-		    (Lflag <= count && xflag) || foundeof) {
+		    lines_read() || foundeof) {
```

`lines_read` is a function the port adds for a feature. A
single-pattern test is the whole condition of an `if` and cannot be
joined with `||`, so the test of `Lflag` moves into a function of its
own:

```c
static bool
lines_read(void)
{

	if (case Some(lines) = Lflag)
		return (lines <= count);
	return (false);
}
```

### The `-E` string is a `str`

`-E` keeps its string and its length in two variables, `eofstr` and
`eoflen`, set together. The port keeps one `str`, which carries its
length; `""`, the default, is the empty `str` that a `static` starts as,
so `main` no longer sets either:

```diff
-static const char *eofstr;
-static long eoflen;
+static str eofstr;
...
 		case 'E':
-			eofstr = optarg;
-			eoflen = strlen(eofstr);
+			eofstr = slice_unchecked(optarg, strlen(optarg));
 			break;
...
-		foundeof = eoflen != 0 && p - argp == eoflen &&
-		    strncmp(argp, eofstr, eoflen) == 0;
+		foundeof = eofstr.len != 0 && p - argp == eofstr.len &&
+		    strncmp(&bbp[argp], eofstr.data, eofstr.len) == 0;
```

### The argument vector and the text buffer are slices

The original reads the arguments into a buffer that five `char *`
pointers walk: `bbp` its start, `ebp` its last usable byte, `argp` the
argument being read, `p` the next byte, and they meet the end only in
comparisons such as `p < ebp`. It points at the arguments from a vector
that four `char **` walk: `av` its start, `bxp` the first argument read,
`xp` the next slot, `endxp` the `-n` limit. The port makes each buffer a
slice and each walking pointer an index of the same name, so every store
is checked against the length that `malloc` was asked for:

```diff
-static char **av, **bxp, **ep, **endxp, **xp;
-static char *argp, *bbp, *ebp, *inpline, *p, *replstr;
+static char **ep;
+/* The utility, its arguments, the arguments read and a NULL. */
+static slice(char *) av;
+static size_t bxp, endxp, xp;	/* the first read, the limit, the next */
+/* The text of the arguments read, each followed by a NUL. */
+static slice(char) bbp;
+static size_t argp, ebp, p;	/* this argument, the last byte, the next */
+static char *inpline;
```

```diff
-	if ((av = bxp = malloc(linelen * sizeof(char *))) == NULL)
+	if ((vec = malloc(linelen * sizeof(char *))) == NULL)
 		errx(1, "malloc failed");
+	av = slice_unchecked(vec, linelen);
+	bxp = 0;
...
-		cnt = strlen(*bxp++ = echo);
+		cnt = strlen(av[bxp++] = echo);
...
-	ebp = (argp = p = bbp) + nline - 1;
+	bbp = slice_unchecked(buf, (size_t)nline + 1);
+	argp = p = 0;
+	ebp = (size_t)nline - 1;
```

In `parse_input` every `*p++ = ch` becomes `bbp[p++] = ch`, and every
`*xp++ = ...` becomes `av[xp++] = ...`. Where `-J` appends the rest of
the utility's arguments after those read, the original's room for them
rests on an argument about `linelen` that a comment in `main` makes;
the port's `av[xp++]` checks it at each store.

When an argument does not fit at the end of the buffer, the original
runs a command with the arguments before it and moves the partial
argument to the start of the buffer with `memcpy`. The two ranges
overlap whenever the argument is longer than what came before it, and
`memcpy` of overlapping ranges is undefined: the third bug below. The
port copies with `memmove`, between two `slice_sub` whose bounds are
checked:

```diff
-		cnt = ebp - argp;
-		memcpy(bbp, argp, (size_t)cnt);
-		p = (argp = bbp) + cnt;
-		*p++ = ch;
+		/* The argument moves to the start, over itself if longer. */
+		cnt = ebp - argp;
+		memmove(slice_sub(bbp, 0, cnt).data,
+		    slice_sub(bbp, argp, ebp).data, (size_t)cnt);
+		argp = 0;
+		p = cnt;
+		bbp[p++] = ch;
```

A slice does not catch this one: the overlap is a contract of `memcpy`,
not a bound. Making the pointers indices is what makes the copy stand
out, since its two ends are visibly the same buffer.

### Errors: `parse_input`, `prerun` and `run` return a `result`

The original stops on eleven conditions inside `parse_input`, `prerun`
and `run`, each with the same two lines at the place it is found:

```c
		warnx("unterminated quote");
		xexit(*av, 1);
```

`xexit` waits for the running children and exits, so each of these
functions can end the program from any depth. The port names the
conditions in a variant, and each place returns one:

```c
/* The errors that stop xargs once its running children have exited. */
type xargs_error =
    | UnterminatedQuote
    | BackslashAtEOF
    | NoSpaceForArgument
    | NoSpaceForArguments
    | TooLong
    | NoMemory(const char *call)	/* the call that failed */
    | Vfork(int errnum);
```

```diff
 arg1:		if (insingle || indouble) {
-			warnx("unterminated quote");
-			xexit(*av, 1);
-		}
+arg1:		if (insingle || indouble)
+			return (Err(UnterminatedQuote));
...
-		prerun(argc, av);
+		try prerun(argc, av.data);
...
 	switch (pid = vfork()) {
 	case -1:
-		warn("vfork");
-		xexit(*argv, 1);
+		return (Err(Vfork(errno)));
```

`main` is the one place that prints them and stops, with upstream's
messages, which `report` holds in one `match`:

```diff
-	for (;;)
-		parse_input(argc, argv);
+	for (;;) {
+		if (case Err(xargs_error e) = parse_input(argc, argv)) {
+			report(e);
+			xexit(av[0], 1);
+		}
+	}
```

`report` is a function because `main` would otherwise hold a `match` of
seven arms in its loop; it adds nothing that the original did not print.
The messages of `main`'s own checks before any child runs, and those of
`waitchildren` and the child after `vfork`, stay `errx` and `err`, as in
the original: they are where the program already is at its top, or a
process of its own.

What the result buys is that the three functions say in their types
that they can fail, that a caller cannot drop the failure (a `result`
that is not used is an error), and that a function which allocates, as
`prerun` does below, can clean up with `defer` on its way out, where
`xexit` would leave from the middle.

### `prerun`: the `-I` list is freed by a `defer`

`prerun` builds a copy of the utility's arguments with the `-I` string
substituted, runs it and frees it. The original walks the list with two
pointers, `tmp2` at its start and `tmp` at the next slot, and frees it
from the tail:

```c
	for (; tmp2 != tmp; tmp--)
		free(*tmp);
	free(tmp2);
```

The loop stops when `tmp` reaches `tmp2`, so it never frees `tmp2[0]`,
the copy of the utility's name: one string leaks for every command that
`-I` runs. The port makes the list a slice that `calloc` zeroes, so that
it is terminated at every step, and a `defer` frees each string and the
list wherever the function leaves, on the error paths too:

```diff
-	tmp = malloc((argc + 1) * sizeof(char *));
-	if (tmp == NULL) {
-		warnx("malloc failed");
-		xexit(*argv, 1);
-	}
-	tmp2 = tmp;
+	list = calloc(argc + 1, sizeof(char *));
+	if (list == NULL)
+		return (Err(NoMemory("malloc")));
+	tmp2 = slice_unchecked(list, (size_t)argc + 1);
+	tmp = 0;
+	/*
+	 * Free each string, and then the list itself.
+	 */
+	defer {
+		for (tmp = 0; tmp2[tmp] != NULL; tmp++)
+			free(tmp2[tmp]);
+		free(tmp2.data);
+	}
```

`strnsubst` returns a `result` (below), and `prerun` matches it, since its
error is not `prerun`'s:

```diff
-			if (strnsubst(tmp++, replstr, inpline, (size_t)Sflag)) {
-				warnx("command line cannot be assembled, too long");
-				xexit(*argv, 1);
-			}
+			match (strnsubst(*avj++, replstr, inpline,
+			    (size_t)Sflag)) {
+			case Ok(s):
+				tmp2[tmp++] = s;
+				break;
+			case Err:
+				return (Err(TooLong));
+			}
```

`prerun` takes its `-I` string from `repl`, and runs the command
unchanged when there is none, which a nonzero `Rflag` already implies:
`main` refuses `-R` without `-I`.

### `run` and `prompt`: the answer is a variant

`prompt` returns 0, 1 or 2, which `run` reads in a `switch` whose
comment explains the numbers. The port returns a variant that says them:

```c
/* The user's answer to the prompt of -p. */
type answer =
    | No
    | Yes
    | NoTty;		/* the terminal did not open */
```

```diff
-			switch (prompt()) {
-			case 0:
-				return;
-			case 1:
+			match (prompt()) {
+			case No:
+				return (Ok);
+			case Yes:
 				goto exec;
-			case 2:
+			case NoTty:
 				break;
 			}
```

`prompt` closes the terminal and frees the response with `defer`, which
also frees the response where `getline` or `regcomp` fails, paths on
which the original leaks it. Its local `match` becomes `matched`, since `match` is
a word of Type-C.

### The child slots: a slice and an option

`childpids`, the `-P` table, becomes a `slice(pid_t)`, and `findslot`,
which returned a slot or -1, returns an `option(int)`. Its two callers
test it with `if (case Some(slot) = findslot(...))`, so neither can index
the table with -1:

```diff
-static int
+static option(int)
 findslot(pid_t pid)
 {
 	int slot;
 
 	for (slot = 0; slot < maxprocs; slot++)
 		if (childpids[slot] == pid)
-			return (slot);
-	return (-1);
+			return (Some(slot));
+	return (None);
 }
```

`xwait`, `xexit`, `waitchildren`, `pids_empty`, `pids_full`,
`pids_add`, `clearslot` and `usage` are unchanged but for `childpids`
being indexed through the slice.

### `strnsubst`: a result and a checked buffer

`strnsubst` builds the substituted argument with `strncat`, `strcat`,
`strlcpy` and `strlcat` into `maxsize` bytes, and returns `true` when it
had to truncate, with the truncated string in `*str` all the same. The
port returns `result(char *, void)`: the new string, or `Err` and no
string. It keeps the length of the string it builds instead of taking
`strlen(s2)` at each step, and copies each part with `memcpy` into a
`slice_sub` of the buffer. The buffer's slice leaves out its last byte,
so the check keeps room for the NUL, whatever the caller passes. The
two BSD calls go, so the port needs nothing of glibc that it lacks; the
original needs `strlcpy` and `strlcat`, which glibc has from 2.38. Upstream's
`#ifdef TEST` program at the end of the file, which nothing builds, is
not ported.

The original also takes a shortcut for an argument of exactly `maxsize`
bytes:

```c
	if (match == NULL || replstr == NULL || maxsize == strlen(s1)) {
		strlcpy(s2, s1, maxsize);
		goto done;
	}
```

`strlcpy` into `maxsize` bytes keeps `maxsize - 1` of them, so this path
returns the argument with its last byte cut off and no substitution
made, and reports no error: the second bug below. The port has no such
path.

## In numbers

| | original | port |
|---|---|---|
| lines of `xargs.c` / `xargs.tc` | 803 | 889 |
| lines of `strnsubst.c` / `strnsubst.tc` | 112 | 81 |
| functions | 18, and a test program | 20 |
| `warnx` or `warn` followed by `xexit` | 11 | 0 |
| `slice_unchecked` | | 6 |

`diff original/xargs.c xargs.tc` removes 175 lines and adds 261. The
port grows by the three variants and their comments, the `match` in
`main`, `report` and `lines_read`; `strnsubst` shrinks by its test
program. The six `slice_unchecked` are
where a pointer and a length come from C: the two `malloc` buffers of
`main`, the `-P` table, the `-I` list, the `-E` string and the buffer of
`strnsubst`. Each takes the length from the same expression as the
allocation beside it.

## Where the port differs

1. **`-x` with `-n` alone.** The port runs commands of `-n` arguments
   and stops with "insufficient space for arguments" where they do not
   fit, as xargs(1) describes. The original runs a command after each
   argument, and one with no arguments for each empty line.
2. **An `-I` argument of exactly `-S` bytes.** The port substitutes into
   it as into any other: it runs the result where it fits, and stops
   with "command line cannot be assembled, too long" and status 1 where
   it does not. The original cuts its last byte, leaves the replstr in
   it, runs it, and exits 0.
3. **The move of a partial argument** uses `memmove`. Both programs print
   the same where the C library's `memcpy` happens to copy forwards, as
   on macOS and glibc; the original is undefined there, and with musl's
   `memcpy` it loses the moved argument.

The port also frees the utility's name that `prerun` copies for each
command of `-I`, and the response of `-p` on its error paths, which
change nothing that the check sees. `check.sh` runs the port alone on
the command lines of 1, 2 and 3, against the output that xargs(1)
gives.

## What the port found

Three bugs of upstream's `xargs`: the port's types pointed at the first
two, and making the buffer's pointers indices at the third. The
transcripts are from macOS 26.6 on x86-64; its `/usr/bin/xargs`
is FreeBSD's, and has the first two as well.

**`-n` with `-x` gives each command one argument.** `Lflag`, an `int`
with 0 for "not given", is compared with the line count, and `xflag`,
which `-x` sets too, is the only guard:

<!-- untested: /usr/bin/xargs is the xargs of the host -->
```console
$ printf 'a b c d e\n' | original/xargs -n 3 -x echo
a
b
c
d
e
$ printf 'a b\n\nc\n' | original/xargs -n 2 -x echo
a
b

c
$ printf 'a b c d e\n' | /usr/bin/xargs -n 3 -x echo
a
b
c
d
e
$ printf 'a b c d e\n' | ./xargs -n 3 -x echo
a b c
d e
```

**An `-I` argument of exactly `-S` bytes is truncated.** `ab{}c` has 5
bytes; with `-S 5` the original prints it cut and unsubstituted, and
with `-S 6` it substitutes:

<!-- untested: /usr/bin/xargs is the xargs of the host -->
```console
$ echo x | original/xargs -I {} -S 5 echo ab{}c
ab{}
$ echo x | original/xargs -I {} -S 6 echo ab{}c
abxc
$ echo x | /usr/bin/xargs -I {} -S 5 echo ab{}c
ab{}
$ echo x | ./xargs -I {} -S 5 echo ab{}c
abxc
```

**`memcpy` of overlapping ranges.** With `-s 30`, `echo` leaves 25 bytes
for the arguments; the 22 bytes of the second argument do not fit after
the 3 of the first, and move to the start over themselves. The original
built with AddressSanitizer:

<!-- untested: the report of AddressSanitizer differs from run to run -->
```console
$ cc -g -fsanitize=address -Wno-deprecated-declarations \
    -idirafter original/compat -I original original/xargs.c \
    original/strnsubst.c \
    -o xargs-asan
$ printf 'aa bbbbbbbbbbbbbbbbbbbbbb c\n' | ./xargs-asan -s 30 echo
aa
=================================================================
==86114==ERROR: AddressSanitizer: memcpy-param-overlap: memory ranges [0x603000001b70,0x603000001b85) and [0x603000001b73, 0x603000001b88) overlap
    #0 0x00010579f58a in __asan_memcpy.cold.1+0x3a (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0x12658a)
    #1 0x00010571b4ea in __asan_memcpy+0x21a (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0xa24ea)
    #2 0x0001051ba611 in parse_input xargs.c:457
    #3 0x0001051b9a08 in main xargs.c:294
$ printf 'aa bbbbbbbbbbbbbbbbbbbbbb c\n' | ./xargs -s 30 echo
aa
bbbbbbbbbbbbbbbbbbbbbb c
```

## What Type-C does not change here

The port keeps C's strings where the C library takes them: the
utility's arguments are `char *` for `execvp`, the `-I` line `inpline`
is still grown with `realloc` and `strcat`, and `strstr` finds the
replstr. `&bbp[argp]` checks the start of an argument, not that a NUL
ends it; the NUL is there because `parse_input` writes one before it
stores the pointer. The child of `vfork` still shares the parent's
memory to report `errno` through `childerr`, and still calls `err`,
which runs the parent's `atexit` handlers, as upstream does.

`typec`'s output carries no comments, so GCC cannot see upstream's
`/* FALLTHROUGH */` in `parse_input`; the port writes
`__attribute__((__fallthrough__));` in its place.
