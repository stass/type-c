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

The port takes the same options, prints the same output and messages
and exits with the same status, but for the differences listed
[below](#where-the-port-differs). `make check` shows it: it runs both
programs over a hundred command lines and compares what they print and
how they exit, and checks the port alone where the two differ.

```sh
make            # gmake on FreeBSD; builds cut and original/cut
make check
TYPEC_CC=gcc-14 make clean check
```

`original/cut.c` needs two names of the BSD C library that glibc lacks,
`__unused` and `warnc`. [`original/compat.h`](original/compat.h)
defines them on Linux, and the [Makefile](Makefile) puts it before
`cut.c` with `-include`, so the file itself stays as upstream has it.

## The port, step by step

### Lists are slices, and their errors are values

`cut -f 2-4,7-` selects fields by a list. The original reads the list
with `strsep`, which writes NULs into the argument, and with `strtol`,
which moves a `char *` along it; an error ends the program from inside
the parser:

```c
	for (; (p = strsep(&list, ", \t")) != NULL;) {
		setautostart = start = stop = 0;
		if (*p == '-') {
			++p;
			setautostart = 1;
		}
		if (isdigit((unsigned char)*p)) {
			start = stop = strtol(p, &p, 10);
			if (setautostart && start > autostart)
				autostart = start;
		}
		...
		if (*p)
			errx(1, "[-bcf] list: illegal list value");
```

The port reads each item as a `str`, a pointer and a length that
`slice_sub` cuts and checks, and leaves the argument alone. An error is
an `Err` that `try` hands up, through `add_list` and `parse_command`, to
`main`, the one place that ends the program:

```c
static result(void, usage_error)
add_item(selection *s, str item)
{
	size_t start = 0, stop = 0;
	bool from_first = false;

	if (starts_with(item, '-')) {
		item = drop(item, 1);
		from_first = true;
	}
	if (starts_with_digit(item)) {
		start = stop = read_number(&item);
		if (from_first && start > s->open_to)
			s->open_to = start;
	}
	...
	if (item.len > 0)
		return (Err(IllegalList));
```

The columns that a list selects are a `slice(bool)` instead of a `char *`
and a separate `maxval`: `s->marked[column]` traps on a column past the
end where `positions[column]` would read past it.

### One cleanup, however a line ends

`f_cut` reads a line with `getline`, appends a newline when the last
line lacks one, and frees the buffer on each of its three exits:

```c
		if (lbuflen > 0 && *(lbuf + lbuflen - 1) != '\n') {
			/* Can't have > 1 line with no trailing newline. */
			if ((ssize_t)bufsize < (lbuflen + 1)) {
				bufsize = lbuflen + 1;
				lbuf = realloc(lbuf, bufsize);
			}
			if (lbuf == NULL)
				err(1, "realloc");
			lbuf[lbuflen] = '\n';
			reallen++;
		}
		...
			if (clen == (size_t)-1 || clen == (size_t)-2) {
				warnc(EILSEQ, "%s", fname);
				free(lbuf);
				return (1);
			}
```

In the port, one function reads the lines of every mode. A `defer` frees
the buffer at every exit, `try` leaves at the first invalid character,
and a line is a `str` and a flag that says whether it ended in a
newline, so nothing is appended:

```c
static result(void, input_error)
cut_file(FILE *fp, const command *c)
{
	char *buf = NULL;
	size_t size = 0;
	ssize_t n;

	defer free(buf);
	while ((n = getline(&buf, &size, fp)) >= 0)
		try cut_line(split_line(slice_unchecked(buf, (size_t)n)), c);
	if (ferror(fp))
		return (Err(ReadFailed(errno)));
	return (Ok);
}
```

### Seven flags become one variant

The original keeps an `int` for each option, `bflag` to `wflag`, checks
them against each other in `main`, and picks one of four functions
through a pointer:

```c
	if (fflag)
		fcn = f_cut;
	else if (cflag)
		fcn = MB_CUR_MAX > 1 ? c_cut : b_cut;
	else if (bflag)
		fcn = nflag && MB_CUR_MAX > 1 ? b_n_cut : b_cut;
```

`f_cut` then asks `wflag` again for each character. The port checks the
options once, in `choose_mode`, and keeps what they mean as a variant:
the delimiter and `-s` exist only in the case of `-f`, and `-w` is a
delimiter, not a flag beside one. A `match` sends each line to its
function and stops the build if a mode is added and not handled:

```c
type delimiter =
    | Char(wchar_t code, str text)
    | Blanks;					/* -w */

type mode =
    | Bytes					/* -b */
    | Chars					/* -c */
    | WholeChars				/* -b -n */
    | Fields(delimiter d, bool only_delimited);	/* -f, -s */
```

```c
	match (c->how) {
	case Bytes:
		cut_bytes(l, &c->what);
		return (Ok);
	case Chars:
		return (cut_chars(l, &c->what));
	case WholeChars:
		return (cut_whole_chars(l, &c->what));
	case Fields(delimiter d, only_delimited):
		return (cut_fields(l, &c->what, d, only_delimited));
	}
```

## What got longer

| | `original/cut.c` | `cut.tc` |
|---|---:|---:|
| lines | 481 | 701 |
| lines of code, without comments and blank lines | 390 | 535 |
| functions | 9 | 34 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
port is 37% longer in code. Almost all of it is function headers:
it splits the original's 9 functions into 34 that each do one thing,
and style(9) spends five or six lines on each, even on a one-line
helper such as `drop` or `starts_with`. The type declarations add about
40 lines that name what the original keeps in globals and flags. The
comments grew too, mostly where the port keeps an odd behaviour of the
original on purpose so that `make check` can compare the two.

Nothing got shorter in lines. What went away is the bookkeeping: the
global flags, the copies of `free(lbuf)` before each `return`, the
`char *` that `strtol` and `strsep` move, the buffer grown to append a
newline, and the function pointer.

## What the port found

`b_n_cut`, the function of `-b list -n` in a multibyte locale, moves
`lbuf` along the line as it reads it, and hands the moved pointer back
to `getline` for the next line and finally to `free`. `getline` then
believes it has the whole buffer from the moved pointer on: it writes
past the end when the next line is longer than what is left, or
reallocates a pointer that `malloc` never returned. And the final
`free` frees such a pointer whenever the loop moved it. Built with
AddressSanitizer:

```console
$ printf 'abcdefg\n0123456789\n' | LC_ALL=en_US.UTF-8 ./cut-asan -b 1-2 -n
==74765==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000100 ...
WRITE of size 11 at 0x602000000100 thread T0
    #0 0x000104359518 in memcpy+0x1058 (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0x126518)
    #1 0x7ff80a5d410b in sappend+0x116 (libsystem_c.dylib:x86_64+0x3010b)
    #2 0x7ff80a5d3fc4 in getdelim+0x17c (libsystem_c.dylib:x86_64+0x2ffc4)
    #3 0x000103d786af in b_n_cut cut.c:279
```

Type-C did not find it: it compiles the same pointer arithmetic. The
port does not have it because a line is a `str` that the loop shortens
with `drop`, a value of its own, while `buf` is touched only by
`getline` and `defer free(buf)`. Nothing in the language stops a
`buf += n`; the slice made it unnecessary to write one, and a
`slice_sub` past the end of the line traps instead of reading on.

## Where the port differs

- **`-n` in a multibyte locale.** The original overruns its buffer
  there, so the port follows `cut(1)` instead: a character is printed
  when one of its bytes is selected and, after a prefix of unselected
  bytes, the rest of its bytes are. An invalid byte sequence ends the
  input with an error, as with `-c` and `-f`, where the original warns
  and goes on; a NUL byte is a character, where the original ends the
  line at it. `make check` compares these cases with the output that
  `cut(1)` describes.
- **A character cut short by the end of the input**, with `-c` in a
  multibyte locale. The port reports it as an invalid byte sequence, as
  the original does with the C library of FreeBSD or macOS; with glibc,
  the original drops it without a word.
- **Read errors.** The port reports a read error, such as `EIO`, in
  every mode. The original reports one only with `-c` in a multibyte
  locale.
- **Memory.** The port reads a whole line at a time in every mode, so
  its memory grows with the longest line. The original's `-b` and `-c`
  read a character at a time, and cut a file with no newline, such as
  `/dev/zero`, in constant memory.
- **Lists past `INT_MAX`.** The original counts columns in an `int` with
  `-b`, `-c` and `-f`, which a list item past `INT_MAX` overflows; the
  port counts them in a `size_t`. Such a list takes gigabytes of marks
  in both.

Everything else is kept, the odd parts included, so that the outputs
can be compared:

- an error in a named file is reported but does not change the exit
  status; one in the standard input does;
- a reversed range, as `5-3`, selects nothing, and `5-3-` selects from
  column 4 on;
- with `-b` and `-c`, a last line without a newline gets one only when
  it reaches the last column of the list; with `-f`, a line without a
  delimiter is printed as it stands, with no newline added.
