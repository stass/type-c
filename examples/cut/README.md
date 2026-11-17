<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The excerpts of original/cut.c and cut.tc below keep the BSD-3-Clause
license of those files.
-->

# cut: a FreeBSD utility in Type-C

[`cut.tc`](cut.tc) is FreeBSD's `cut(1)` ported to Type-C, and
[`original/cut.c`](original/cut.c) is the C it ports, unchanged:
`usr.bin/cut/cut.c` of [freebsd-src](https://github.com/freebsd/freebsd-src)
at commit `35f375549c7f4d479ba1d9fcd0a368b0219c4ae6` ("cut: Avoid
undefined behavior.", 2025-10-23), the last commit that changes the file
on `main` (git blob `e4e322b4e5c99e4a5e91e3135df134ba9a685ffc`). Both
carry the BSD-3-Clause license of the original.

The port keeps the original's functions, names, comments, variables,
control flow and style(9) layout, and changes only what Type-C gives a
better way to write, so `diff original/cut.c cut.tc` is the whole story.
It takes the same options, prints the same output and messages and
exits with the same status, but for the differences listed
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

## The diff, step by step

### The positions are a slice

The original keeps the columns that the lists select in `positions`, a
`char *`, and its allocated size in a `static` of `needpos`. The port
makes it a `slice(char)`, which carries its length, so every
`positions[i]` is checked against it and traps past the end instead of
reading on. The length is `positions.len`, the one record of the size:

```diff
-static char *	positions;
+static slice(char) positions;
```

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
+		if ((newpos = realloc(positions.data, npos)) == NULL)
 			err(1, "realloc");
-		memset((char *)positions + oldnpos, 0, npos - oldnpos);
+		memset(newpos + oldnpos, 0, npos - oldnpos);
+		positions = slice_unchecked(newpos, npos);
 	}
```

`slice_unchecked` pairs a pointer with a length that the compiler takes
on trust. The port has three: here, the `npos` bytes that `realloc`
returned, and below, the length of a line that `getline` returned,
once as it stands and once with the newline that `f_cut` appends.

Where the original walks a `char *pos` along `positions`, the port
walks an index of the same name, in `get_list`, `b_cut`, `c_cut` and
`f_cut` alike:

```diff
-	char *pos;
+	size_t pos;
...
-		pos = positions + 1;
+		pos = 1;
...
-			if (*pos++)
+			if (positions[pos++])
```

`get_list` sets the columns of `-N` with `memset`, which takes a
pointer. The port hands it the pointer of a `slice_sub` of those
columns, so that the bound is checked there too:

```diff
-		memset(positions + 1, '1', autostart);
+		memset(slice_sub(positions, 1, autostart + 1).data, '1',
+		    autostart);
```

### A line is a `str`, not a moving buffer

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

`f_cut` still appends a newline to a last line that lacks one, as the
original does: its loops stop at that newline, and the port keeps them.
The `p[0]` that those loops read is checked against the line, where
`*p` would read past it if the newline were missing.

### `defer` frees the buffer at every exit

`f_cut` frees `lbuf` before each of its three `return`s. The port says
it once, after the declarations, and a `defer` frees the buffer at
whichever exit the function takes:

```diff
+	defer free(lbuf);
 	while ((lbuflen = getline(&lbuf, &bufsize, fp)) >= 0) {
...
 				warnc(EILSEQ, "%s", fname);
-				free(lbuf);
 				return (1);
```

`b_n_cut` has one exit, but gets the same `defer`, so that its buffer
is freed where it is declared, as in `f_cut`:

```diff
 	memset(&mbs, 0, sizeof(mbs));
 	warned = 0;
+	defer free(lbuf);
...
-	free(lbuf);
 	return (warned);
```

### What the port leaves alone

- **`main` is unchanged.** It closes each file right after the one call
  that reads it, so a `defer fclose(fp)` would only move the line. The
  option flags stay `int`s and the mode stays a function pointer: a
  variant of the modes would need a `match` at each of the three places
  that call `fcn`, or a new function to hold one, where the pointer
  dispatches as it is.
- **`get_list` keeps `errx`.** Every error of a list ends the program,
  and `get_list` is called from three cases of the `getopt` switch in
  `main`. As a `result`, it would need a `match` at each of the three,
  since `main` returns an `int` and has nowhere to hand an error up with
  `try`; `errx` in place says the same in one line.
- **`get_list` keeps `strsep` and `strtol`.** They walk a NUL-terminated
  argument, not a pointer with a length, so a `str` would only add a
  number reader of its own.

## The size

| | `original/cut.c` | `cut.tc` |
|---|---:|---:|
| lines | 481 | 488 |
| lines of code, without comments and blank lines | 390 | 396 |
| functions | 9 | 9 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
diff takes out 43 lines and puts in 50, one of them the copyright line
of the port, and adds no function.

## What the port found

`b_n_cut` moves `lbuf` along the line as it reads it, and hands the
moved pointer back to `getline` for the next line and finally to
`free`. `getline` then believes it has the whole buffer from the moved
pointer on: it writes past the end when the next line is longer than
what is left, or reallocates a pointer that `malloc` never returned. And
the final `free` frees such a pointer whenever the loop moved it. Built
with AddressSanitizer:

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
