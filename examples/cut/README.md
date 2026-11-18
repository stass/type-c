<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The excerpts of original/cut.c and cut.tc below keep the BSD-3-Clause
license of those files.
-->

<!--
test/run/example_readmes.t checks the console blocks of this file on
Clang and GCC, but those marked untested: test/run/readme.sh says how
the blocks are marked.
-->

# cut: a FreeBSD utility in Type-C

[`cut.tc`](cut.tc) is FreeBSD's `cut(1)` ported to Type-C, and
[`original/cut.c`](original/cut.c) is the C it ports, unchanged:
`usr.bin/cut/cut.c` of [freebsd-src](https://github.com/freebsd/freebsd-src)
at commit `35f375549c7f4d479ba1d9fcd0a368b0219c4ae6` ("cut: Avoid
undefined behavior.", 2025-10-23), the last commit that changes the file
on `main` (git blob `e4e322b4e5c99e4a5e91e3135df134ba9a685ffc`). Both
carry the BSD-3-Clause license of the original.

The port keeps the original's functions, their names and order, its
comments, its control flow and its style(9) layout, and adds one
function. Inside the functions it writes in Type-C what Type-C has a
construct for: the options become variants that `match` takes apart,
the errors of a list a `result` that `try` hands up, a value that may
be missing an `option`, the column table and the lines slices, and the
frees `defer`. So `diff original/cut.c cut.tc` is the whole story, and
the walk [below](#the-diff-function-by-function) takes it function by
function. The port takes the same options, prints the same output and
messages and exits with the same status, but for the differences listed
[below](#where-the-port-differs). `make check` shows it: it runs both
programs over a hundred command lines and compares what they print and
how they exit, and checks the port alone where the two differ.

```sh
make            # gmake on FreeBSD; builds cut and original/cut
make check
TYPEC_CC=gcc-14 make clean check
```

Both files use two names of the BSD C library that glibc lacks,
`__unused` and `warnc`. [`original/compat.h`](original/compat.h)
defines them on Linux, and the [Makefile](Makefile) puts it before each
file with `-include`, so `cut.c` stays as upstream has it and the port
keeps upstream's calls.

## The diff, function by function

### The declarations: three variants and an `option`

The original keeps its options in nine `static` flags, read by `main`,
`is_delim` and `f_cut`. `dchar` and `dcharmb` hold the delimiter of
`-d` twice, as a wide character and as its bytes, and `wflag` says to
ignore both. The port gives what the cutters need a type each. A
`delimiter` is a character, with its bytes, or the blanks of `-w`, so
`dchar` exists only where `-w` is not given. A `cut_mode` is the
function that cuts, with the arguments of `f_cut`, which upstream
otherwise reads from the flags:

```diff
-static int	bflag;
-static int	cflag;
-static wchar_t	dchar;
-static char	dcharmb[MB_LEN_MAX + 1];
-static int	dflag;
-static int	fflag;
-static int	nflag;
-static int	sflag;
-static int	wflag;
-
-static size_t	autostart, autostop, maxval;
-static char *	positions;
+/* What separates the fields of -f. */
+type delimiter =
+    | Char(wchar_t dchar, str dcharmb)	/* -d, or the default tab */
+    | Blanks;				/* -w: spaces and tabs */
+
+/* How the input is cut, by the options and the locale. */
+type cut_mode =
+    | Bytes		/* -b, and -c or -n where a character is a byte */
+    | BytesNoSplit	/* -b -n where a character may be more */
+    | Chars		/* -c where a character may be more */
+    | Fields(delimiter delim, bool only_delimited);	/* -f [-s] */
+
+/* Why a list of -b, -c or -f is refused. */
+type list_error =
+    | IllegalValue
+    | ZeroValue
+    | NoMemory(int errnum);	/* the positions it selects do not fit */
+
+static size_t	autostart, maxval;
+static option(size_t) autostop = None;
+static slice(char) positions;
```

`list_error` names the three ways a list fails, which the original
reports where it finds them (see `get_list`).

`autostop` is the start of the open range, `N-`, that starts first: the
columns after it are all selected. The original stores 0 when the list
has no open range and tests for 0 before each use. As an
`option(size_t)` it is `None` then, and the column can be read only by a
test that it is there.

`positions`, the selected columns, becomes a `slice(char)`, which
carries its length, so every `positions[i]` is checked against it and
traps past the end instead of reading on.

### `main`: the options are matched into a mode

The flags become locals of `main`, the one function that reads them
now: they say which options were given, which is what the test of their
combinations, unchanged, needs. The delimiter's bytes become a `str`,
`"\t"` or the `-d` argument itself, in place of a copy in an array:

```diff
-	fcn = NULL;
+	bflag = cflag = dflag = fflag = nflag = sflag = wflag = 0;
 	dchar = '\t';			/* default delimiter is \t */
-	strcpy(dcharmb, "\t");
+	dcharmb = "\t";
...
-			strcpy(dcharmb, optarg);
+			dcharmb = slice_unchecked((const char *)optarg, n);
```

`slice_unchecked` pairs a pointer with a length that the compiler takes
on trust; here the length is the `n` bytes that `mbrtowc` read, which
the test just above has found to be all of `optarg`.

`get_list` returns a `result` now, and `main` matches it and prints
upstream's message for each error. The three options of a list share
the one `match`, so their cases become one, which moves `-f` up beside
`-b` and `-c`, and each sets its flag after it:

```diff
 		case 'b':
-			get_list(optarg);
-			bflag = 1;
-			break;
 		case 'c':
-			get_list(optarg);
-			cflag = 1;
+		case 'f':
+			match (get_list(optarg)) {
+			case Ok:
+				break;		/* leaves the match */
+			case Err(IllegalValue):
+				errx(1, "[-bcf] list: illegal list value");
+			case Err(ZeroValue):
+				errx(1, "[-bcf] list: values may not "
+				    "include zero");
+			case Err(NoMemory(errnum)):
+				errno = errnum;
+				err(1, "realloc");
+			}
+			if (ch == 'b')
+				bflag = 1;
+			else if (ch == 'c')
+				cflag = 1;
+			else
+				fflag = 1;
 			break;
```

In a `match`, as the comment says, `break` leaves the `match` and not
the `switch` around it, so the flags are set after an `Ok`. The `match`
must name every constructor of the `result` and of `list_error`: an
error added to `get_list` later is a compile error here until it has a
message. The other arms end the program, as `errx` and `err` do not
return; an arm cannot fall into the next (design 4.3).

Where the original picks the function that cuts, the port builds the
mode, with the delimiter that `-d` and `-w` gave:

```diff
-	if (fflag)
-		fcn = f_cut;
-	else if (cflag)
-		fcn = MB_CUR_MAX > 1 ? c_cut : b_cut;
-	else if (bflag)
-		fcn = nflag && MB_CUR_MAX > 1 ? b_n_cut : b_cut;
+	if (fflag && wflag)
+		mode = Fields(Blanks, sflag);
+	else if (fflag)
+		mode = Fields(Char(dchar, dcharmb), sflag);
+	else if (cflag && MB_CUR_MAX > 1)
+		mode = Chars;
+	else if (bflag && nflag && MB_CUR_MAX > 1)
+		mode = BytesNoSplit;
+	else
+		mode = Bytes;
```

and each `fcn(...)` becomes `cut(mode, ...)`. The original's `fcn` is
`NULL` until this point; a `cut_mode` has no value that cuts nothing.

`main` still closes each file right after the one call that reads it,
so a `defer fclose(fp)` would only move the line.

### `cut`: the one new function

A variant has no call operator: the function of a mode is chosen by a
`match`. `main` calls through `fcn` in three places, so the port puts
the `match` in a function of its own, `cut`, rather than write it
three times:

```c
/* Cuts fp with the function of the mode, which upstream holds in fcn. */
static int
cut(cut_mode mode, FILE *fp, const char *fname)
{
	match (mode) {
	case Bytes:
		return (b_cut(fp, fname));
	case BytesNoSplit:
		return (b_n_cut(fp, fname));
	case Chars:
		return (c_cut(fp, fname));
	case Fields(delimiter delim, sflag):
		return (f_cut(fp, fname, delim, sflag));
	}
}
```

Only `f_cut` takes the delimiter and `-s`, so only `Fields` carries
them. The `match` covers every mode, so `cut` needs no `return` after
it, and a mode added later does not compile until `cut` handles it.

### `get_list`: a `result`, with `try`

The original ends the program with `errx` at a bad list item, and
`needpos` with `err` when `realloc` fails. The port returns the error
instead, and `try` hands one from `needpos` up through `get_list` to
`main`. Every caller of `get_list` ends the program on an error, so
what this buys is not recovery but a split: `get_list` and `needpos`
say what went wrong, and `main` alone decides that it ends the program
and with which message:

```diff
-static void
+static result(void, list_error)
 get_list(char *list)
...
 		if (*p)
-			errx(1, "[-bcf] list: illegal list value");
+			return (Err(IllegalValue));
 		if (!stop || !start)
-			errx(1, "[-bcf] list: values may not include zero");
+			return (Err(ZeroValue));
 		if (maxval < stop) {
 			maxval = stop;
-			needpos(maxval + 1);
+			try needpos(maxval + 1);
 		}
...
+	return (Ok);
```

`autostop` is an `option`, so where the original keeps the smallest
start of an open range, with 0 for none, the port asks whether there is
one:

```diff
 			if (*p == '-') {
 				++p;
-				if (!autostop || autostop > stop)
-					autostop = stop;
+				if (case Some(from) = autostop) {
+					if (from > stop)
+						autostop = Some(stop);
+				} else
+					autostop = Some(stop);
 			}
...
 	/* overlapping ranges */
-	if (autostop && maxval > autostop) {
-		maxval = autostop;
-		needpos(maxval + 1);
+	if (case Some(from) = autostop) {
+		if (maxval > from) {
+			maxval = from;
+			try needpos(maxval + 1);
+		}
 	}
```

`if (case P = e)` is a test of one constructor: it succeeds when `e`
holds `P` and binds its field. The test is the whole condition and is
joined with nothing (design 4.6), so the original's `autostop &&` and
`!autostop ||` each become an `if` of their own.

Where the original walks a `char *pos` along `positions`, the port
walks an index of the same name, here and in `b_cut`, `c_cut` and
`f_cut` alike:

```diff
-		for (pos = positions + start; start++ <= stop; *pos++ = 1);
+		for (pos = start; start++ <= stop; positions[pos++] = 1);
```

It sets the columns of `-N` with `memset`, which takes a pointer, so
the port hands it the pointer of a `slice_sub` of those columns, and
the bound is checked there too:

```diff
-		memset(positions + 1, '1', autostart);
+		memset(slice_sub(positions, 1, autostart + 1).data, '1',
+		    autostart);
```

### `needpos`: the length is the slice's

The original keeps the allocated size of `positions` in a `static` of
`needpos`. The port reads it from the slice, `positions.len`, the one
record of the size, and returns the error of `realloc`, with its
`errno`, for `main` to report as the original does:

```diff
-	static size_t npos;
-	size_t oldnpos;
+	size_t npos, oldnpos;
+	char *newpos;
 
 	/* Grow the positions array to at least the specified size. */
-	if (n > npos) {
-		oldnpos = npos;
+	if (n > positions.len) {
+		oldnpos = npos = positions.len;
 		if (npos == 0)
 			npos = n;
 		while (n > npos)
 			npos *= 2;
-		if ((positions = realloc(positions, npos)) == NULL)
-			err(1, "realloc");
-		memset((char *)positions + oldnpos, 0, npos - oldnpos);
+		if ((newpos = realloc(positions.data, npos)) == NULL)
+			return (Err(NoMemory(errno)));
+		memset(newpos + oldnpos, 0, npos - oldnpos);
+		positions = slice_unchecked(newpos, npos);
 	}
+	return (Ok);
```

The `slice_unchecked` takes the `npos` bytes that `realloc` returned.

### `b_cut` and `c_cut`: an index, and a test of `autostop`

The two cut a column at a time and differ only in reading bytes or
wide characters. Each walks `positions` by index, as `get_list` does,
and asks `autostop` whether there is an open range, without binding
its column, which they do not need:

```diff
-	char *pos;
+	size_t pos;
...
-		pos = positions + 1;
+		pos = 1;
...
-			if (*pos++)
+			if (positions[pos++])
...
-			if (autostop)
+			if (case Some = autostop)
```

`c_cut` keeps its `goto out`: the code there reports a read error,
which is no cleanup that a `defer` would hold.

### `b_n_cut`: the line is a `str`, and `defer` frees the buffer

`b_n_cut`, the function of `-b list -n` in a multibyte locale, reads a
line with `getline` into `lbuf` and then walks the line by moving `lbuf`
itself, `lbuf += clen`. That pointer goes back to `getline` for the next
line and to `free` at the end: the bug [below](#what-the-port-found).
The port leaves `lbuf` to `getline` and walks a `str` over the line, a
pointer and a length that `slice_sub` shortens and checks:

```diff
-		for (col = 0; lbuflen > 0; col += clen) {
-			if ((clen = mbrlen(lbuf, lbuflen, &mbs)) < 0) {
+		line = slice_unchecked(lbuf, lbuflen);
+		for (col = 0; line.len > 0; col += clen) {
+			if ((clen = mbrlen(line.data, line.len, &mbs)) < 0) {
...
-			if (clen == 0 || *lbuf == '\n')
+			if (clen == 0 || line[0] == '\n')
...
-					fwrite(lbuf, 1, clen, stdout);
+					fwrite(line.data, 1, clen, stdout);
...
-			lbuf += clen;
-			lbuflen -= clen;
+			line = slice_sub(line, clen, line.len);
 		}
-		if (lbuflen > 0)
+		if (line.len > 0)
 			putchar('\n');
```

The `slice_unchecked` takes the `lbuflen` bytes that `getline` read.
`lbuf` is freed by a `defer` where it is declared, in place of the
`free` before the one `return`, as in `f_cut`, which has three:

```diff
 	memset(&mbs, 0, sizeof(mbs));
 	warned = 0;
+	/* Whether the list selects every byte past maxval, as "N-" does. */
+	tail = false;
+	if (case Some = autostop)
+		tail = true;
+	defer free(lbuf);
...
-	free(lbuf);
 	return (warned);
```

The test of `autostop` is the one that does not fit a test of one
constructor. The original joins it with `&&` inside a loop condition:

```diff
-					if ((i >= maxval && !autostop) ||
+					if ((i >= maxval && !tail) ||
 					    (i < maxval && !positions[1 + i])) {
```

so the port asks the `option` once, before the lines, into the flag
`tail`.

### `is_delim`: a `match` on the delimiter

The original tests `wflag` and otherwise compares with `dchar`. The
port takes the delimiter and matches it, so `dchar` is read only where
there is one:

```diff
 static int
-is_delim(wchar_t ch)
+is_delim(delimiter delim, wchar_t ch)
 {
-	if (wflag) {
+	match (delim) {
+	case Blanks:
 		if (ch == ' ' || ch == '\t')
 			return 1;
-	} else {
+		break;
+	case Char(dchar, _):
 		if (ch == dchar)
 			return 1;
+		break;
 	}
 	return 0;
 }
```

A match arm must end in a `break`, `return` or the like (design 4.3);
it does not fall through as a `switch` case does.

### `f_cut`: the delimiter as an argument, the line as a `str`

`f_cut` takes the delimiter and `-s` from its mode, through `cut`, in
place of `wflag`, `dchar`, `dcharmb` and `sflag`. The bytes it writes
between fields are those of the `-d` character, or the tab that the
original leaves in `dcharmb` when `-w` is given:

```diff
 static int
-f_cut(FILE *fp, const char *fname)
+f_cut(FILE *fp, const char *fname, delimiter delim, bool sflag)
...
+	/* -w joins the fields with a tab, the default delimiter. */
+	dcharmb = "\t";
+	if (case Char(_, mb) = delim)
+		dcharmb = mb;
```

As a `str`, `dcharmb` is written with one `fwrite` of its length, where
the original loops to its NUL:

```diff
-				for (i = 0; dcharmb[i] != '\0'; i++)
-					putchar(dcharmb[i]);
+				(void)fwrite(dcharmb.data, 1, dcharmb.len,
+				    stdout);
```

`-w` takes a run of blanks for one delimiter. The original tests
`wflag`; the port tests the delimiter, and moves the test of the
newline into the loop, where it guards the `p[0]` that would read past
the line:

```diff
 					/* compress whitespace */
-					if (wflag && ch != '\n')
-						while (is_delim(*p))
-							p++;
+					if (case Blanks = delim)
+						while (ch != '\n' &&
+						    is_delim(delim, p[0]))
+							p = slice_sub(p, 1,
+							    p.len);
```

`f_cut` does not move `lbuf`, but walks the line with a second pointer
`p` and works out what is left of the line as `lbuf + reallen - p`. In
the port `p` is a `str`, the rest of the line, so what is left is
`p.len`, and stepping past a character is a `slice_sub`:

```diff
-		for (isdelim = 0, p = lbuf;; p += clen) {
-			clen = mbrtowc(&ch, p, lbuf + reallen - p, NULL);
+		line = slice_unchecked(lbuf, reallen);
+		for (isdelim = 0, p = line;; p = slice_sub(p, clen, p.len)) {
+			clen = mbrtowc(&ch, p.data, p.len, NULL);
```

The `slice_unchecked` takes the `reallen` bytes of the line, its
newline included, that `f_cut` appends when the last line lacks one.
The original prints a character of a field after it has stepped past
it, as `p - clen`. A slice cannot reach back before its start, so the
port keeps the character's bytes, `chmb`, before it steps:

```diff
-				p += clen;
+				chmb = slice_sub(p, 0, clen);
+				p = slice_sub(p, clen, p.len);
...
-				if (*pos)
-					(void)fwrite(p - clen, 1, clen,
+				if (positions[pos])
+					(void)fwrite(chmb.data, 1, chmb.len,
 					    stdout);
```

The loops that stop at that newline stay; the `p[0]` that they read is
checked against the line, where `*p` would read past it if the newline
were missing.

`f_cut` frees `lbuf` before each of its three `return`s. The port says
it once, after the declarations, and the `defer` frees the buffer at
whichever exit the function takes:

```diff
+	defer free(lbuf);
 	while ((lbuflen = getline(&lbuf, &bufsize, fp)) >= 0) {
...
 				warnc(EILSEQ, "%s", fname);
-				free(lbuf);
 				return (1);
```

### What the port leaves alone

- **`usage` is unchanged.**
- **The flags stay `int`s in `main`.** The test of which options go
  together is about which were given, and the flags say just that; the
  mode is built once the test has passed.
- **`get_list` keeps `strsep` and `strtol`.** They walk a NUL-terminated
  argument, not a pointer with a length, so a `str` would only add a
  number reader of its own.
- **The return of a cutter stays an `int`.** It is the exit status of
  `main`, set by `warn`ings already printed, not an error for the
  caller to handle.

## The size

| | `original/cut.c` | `cut.tc` |
|---|---:|---:|
| lines | 481 | 552 |
| lines of code, without comments and blank lines | 390 | 451 |
| functions | 9 | 10 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
diff takes out 108 lines and puts in 179, one of them the copyright
line of the port, and adds one function, `cut`.

## What the port found

`b_n_cut` moves `lbuf` along the line as it reads it, and hands the
moved pointer back to `getline` for the next line and finally to
`free`. `getline` then believes it has the whole buffer from the moved
pointer on: it writes past the end when the next line is longer than
what is left, or reallocates a pointer that `malloc` never returned. And
the final `free` frees such a pointer whenever the loop moved it. Built
with AddressSanitizer:

<!-- untested: the report of AddressSanitizer differs from run to run -->
```console
$ printf 'abcdefg\n0123456789\n' | LC_ALL=en_US.UTF-8 ./cut-asan -b 1-2 -n
==74765==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000100 ...
WRITE of size 11 at 0x602000000100 thread T0
    #0 0x000104359518 in memcpy+0x1058 (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0x126518)
    #1 0x7ff80a5d410b in sappend+0x116 (libsystem_c.dylib:x86_64+0x3010b)
    #2 0x7ff80a5d3fc4 in getdelim+0x17c (libsystem_c.dylib:x86_64+0x2ffc4)
    #3 0x000103d786af in b_n_cut cut.c:279
```

Type-C did not find it: it compiles the same pointer arithmetic, and
nothing in the language stops an `lbuf += clen`. The port does not have
it because the `str` made it unnecessary to write one: `line` is a value
of its own that the loop shortens, `lbuf` is touched only by `getline`
and `defer free(lbuf)`, and a `slice_sub` past the end of the line traps
instead of reading on.

## Where the port differs

- **`-n` in a multibyte locale.** The original overruns its buffer
  there, as [above](#what-the-port-found); the port does not. The
  original's behaviour is undefined there, so `make check` compares
  these cases with the output that `cut(1)` describes.

Everything else is kept, the odd parts included, so that the outputs
can be compared:

- an error in a named file is reported but does not change the exit
  status; one in the standard input does;
- a reversed range, as `5-3`, selects nothing, and `5-3-` selects from
  column 4 on;
- with `-b` and `-c`, a last line without a newline gets one only when
  it reaches the last column of the list; with `-f`, a line without a
  delimiter is printed as it stands, with no newline added;
- with `-n`, an invalid byte sequence is warned of once and each of
  its bytes taken for a character of one byte, a NUL byte ends the
  line, and a character that reaches past the last column of the list
  is printed when its bytes up to that column are, though `cut(1)` asks
  for all of them: `cut -n -b 2` prints a whole three-byte euro sign;
- `-b` and `-c` read a character at a time, so they cut a file with no
  newline, such as `/dev/zero`, in constant memory, and only `-c` in a
  multibyte locale reports a read error such as `EIO`;
- with `-c`, a character cut short by the end of the input is reported
  as an invalid byte sequence or dropped without a word, as the C
  library's `getwc` has it: FreeBSD's and macOS's report it, glibc's
  drops it;
- `-b`, `-c` and `-f` count columns in an `int`, which a list item past
  `INT_MAX` overflows; such a list takes gigabytes of positions first.
