<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/example_readmes.t checks the console blocks of this file on
Clang and GCC, but those marked untested: test/run/readme.sh says how
the blocks are marked.
-->

# wordfreq: a generic map against khash

`wordfreq` counts the words of its standard input and prints the most
frequent ones, ten unless `-n` gives another count:

```console
$ printf 'The cat and the Hat.\nthe end, THE END\n' | ./wordfreq -n 3
      4 the
      2 end
      1 and
```

A word is a run of ASCII letters, folded to lower case; a tie in count
is printed in the order of the words.

[`original/wordfreq.c`](original/wordfreq.c) is the program in C, on the
hash table that C programmers reach for, klib's
[`khash.h`](original/khash.h). [`wordfreq.tc`](wordfreq.tc) is the same
program in Type-C, on a generic `map(K, V)` that this example writes in
[`map.tci`](map.tci). `khash.h` is
[klib](https://github.com/attractivechaos/klib)'s file, unchanged and
under its MIT license, as it stands at commit
`97a0fcb790b43b9e5da8994f4671021fec036f19` (2025-12-22), the head of
`master`; the file last changed in commit
`5fc2090766753bdaa9e53e0cc0734b285a891c85` ("fixed a few typos in
khash.h; resolves #110", 2018-10-31), and its git blob is
`f75f3474c157dc07781c3d7f67e4be759ea74feb`.

```sh
make            # gmake on FreeBSD; builds wordfreq and original/wordfreq
make check      # runs both over the same texts and compares them
make bench      # times both on a generated text of 20 million words
TYPEC_CC=gcc-16 make clean check
```

`make check` runs both programs over an empty text, a short one, one
with tabs, carriage returns, NUL bytes, digits and non-ASCII letters,
200,000 words that [`corpus.awk`](corpus.awk) generates, and the sources
of the example, each with four counts, over words that are prefixes of
each other, and over the command lines that fail, a closed output
among them; it compares what they print and how they exit. The two
agree in every case.

## The program, side by side

`wordfreq.tc` has the functions of `wordfreq.c` in the same order, with
the same names, variables and control flow: `count_word`, `count_line`,
`count_file`, `compare_counts`, `print_top`, `free_words`, `main` and
`usage`. It adds two helpers, `str_dup` and `str_compare`, for the
`strdup` and `strcmp` that the C library has for C strings and lacks
for a `str`. A diff of the two files shows what Type-C changes, which
the sections below go through.

### The table is a type

`khash.h` is a macro that writes a table: `KHASH_MAP_INIT_STR(word,
int)` declares `khash_t(word)` and the functions `kh_get_word`,
`kh_put_word` and the rest, named for `word`, and the functions take a
`khint_t` iterator that `kh_val` and `kh_key` read the slot through. In
Type-C the table is the type `map(str, int)`, which every function names
as it would `int`, and a lookup is an `option` of a pointer to the
value:

```c
	k = kh_get(word, h, word);
	if (k != kh_end(h)) {
		kh_val(h, k)++;
		return;
	}
```

```c
	if (case Some(count) = map_get(h, word)) {
		(*count)++;
		return;
	}
```

`map_put` returns a `result`, which the call has to read, where
`kh_put` sets an `int` through a pointer that the call can forget to
test. `map_new` allocates nothing, so the `kh_init` that can fail in
`main` becomes a value.

### A word is a str

A key of `khash`'s string table is a C string, so `count_line` ends a
word in a NUL for the lookup, in the line buffer, and puts the character
back:

```c
		end = line[i];
		line[i] = '\0';
		count_word(h, line + start);
		line[i] = end;
```

It works because `getline` leaves a NUL after the line, which the reader
has to know. A key of `map(str, int)` is a `str`, a pointer and a
length, so the word is a slice of the line and nothing is written:

```c
		count_word(h, slice_sub(line, start, i));
```

The line is a `slice(char)` and the array that `print_top` sorts is a
`slice(struct count)`, so `line[i]` and `counts[n]` are checked against
their lengths.

A `str` has no NUL for `%s`, and `%.*s` takes the length as an `int`,
which a word of 2 GiB would overflow, so `print_top` prints the count
with `printf` and the word with `fwrite`:

```c
		printf("%7d %s\n", counts[i].count, counts[i].word);
```

```c
		printf("%7d ", counts[i].count);
		fwrite(counts[i].word.data, 1, counts[i].word.len, stdout);
		putchar('\n');
```

## The map

[`map.tci`](map.tci) is the table that `khash` is, as two generic types
and six generic functions in 150 lines, where `khash.h` has 627: open
addressing in a power of two slots, a probe in steps of 1, 2, 3 and on,
as `khash` probes, and a table that doubles when an entry would fill
more than three quarters of it, where `khash`'s doubles at 0.77. A slot
is a `map_slot(K, V)`, its key, its value and whether it is used, and
the table is one `slice` of them, so its keys and values cannot differ
in number; `khash` keeps three arrays, of keys, of values and of two
bits a slot. `map_put` of a key that the map has replaces its value, as
`kh_put` finds the key's slot. There is no deletion, which `wordfreq`
does not use; `khash`'s tombstones would add a third state to a slot
and a test to each probe.

The body of a generic function is checked once, for every `K`, so it
cannot hash or compare a `K` (the
[tutorial](../../docs/tutorial.md#5-generic-types-and-functions) shows
the error). A map holds the two functions that do, `uint32_t (*hash)(K)`
and `bool (*equal)(K, K)`, which `map_new` takes; `str_hash` is
`khash`'s X31 hash of a C string over a `str`, so that both programs
hash alike. Where `khash` pastes the hash and equality macros
into the code that it writes, `map.tci` calls through a pointer, which
is what the next section measures.

## Does generic code cost anything?

An instance of a generic is an ordinary C structure and ordinary C
functions, written for `map(str, int)` where `wordfreq.tc` uses it, as
`KHASH_MAP_INIT_STR` writes them for `word`, so neither has a run-time
type or a `void *`. What can cost is what the code does differently:
the hash and the equality that `map.tci` calls through pointers, and
the index checks of its slices.

`make bench` ([`bench.sh`](bench.sh)) prints the code of each object
file, the sections whose names begin with `.text`, and times both
programs with [hyperfine](https://github.com/sharkdp/hyperfine), two
warm-up runs and ten timed, on a text that `corpus.awk` generates: 20
million words, 94.6 MB, 500,000 distinct words. Both builds are `-O2`
through `typec`. The host is FreeBSD 16.0-CURRENT on an AMD Ryzen
Threadripper PRO 5995WX, idle; a macOS host shared with other work
moved the same runs by 30% from one try to the next, too much to read a
10% difference from.

| Compiler | Code, `map(str, int)` | Code, `khash` | Time, `map(str, int)` | Time, `khash` |
|---|---|---|---|---|
| Clang 21.1.8 | 2,518 bytes | 2,800 bytes | 1.083 s +/- 0.004 | 1.209 s +/- 0.008 |
| GCC 14.2.0 | 2,632 bytes | 3,252 bytes | 1.328 s +/- 0.006 | 1.121 s +/- 0.005 |

The generic table is the smaller code on both compilers. In time it is
10% faster on Clang and 18% slower on GCC:

* Clang inlines the hash and the equality: its assembly of
  `wordfreq.tc` has no indirect call, as the map is a local of `main`
  and the compiler sees which functions it holds. GCC keeps the
  pointers, and its assembly (GCC 16 on macOS) calls through them three
  times, in the probe of `map_get` and of `map_place`.
* The index checks cost nothing measurable on Clang and 5% on GCC: a
  build of `map.tci` that indexes its slots through `.data`, unchecked,
  runs in 1.093 s +/- 0.003 on Clang and 1.260 s +/- 0.012 on GCC.
* An earlier `map.tci` kept three slices, of keys, of values and of
  `bool`, as `khash` keeps three arrays; it ran in 1.062 s on Clang and
  1.234 s on GCC. The one slice of slots, which keeps the keys and
  values in step by construction, costs 2% on Clang and 8% on GCC. The
  likely cause, not measured, is that a probe tests `used` in slots of
  24 bytes, a `str`, an `int` and a `bool` with padding, where it
  tested a dense array of `bool`.

Where the rest of Clang's lead comes from is not measured. The likely
source is that a `str` carries its length, so the equality tests the
lengths before it calls `memcmp`, where `khash`'s calls `strcmp` on
every probe that meets a used slot.

So the answer is: the instances cost nothing in size, but a generic
function reaches the operations of its type, here the hash and the
equality, only through pointers, as its body cannot name them. That is
free where the C compiler propagates the constant pointers, as Clang
does, and costs about an eighth of the run time where it does not, as
GCC does. Whether Type-C should bind such operations when it makes an
instance is an open question of the design.

## What the type checker catches

`khash`'s functions are C functions of the key and value types, so the
C compiler stops a key passed as a value in a call. The hash and the
equality are not: `KHASH_INIT` pastes the two macros it is given into
the code that it writes, where a cast or an operator that takes any
operand hides a wrong key type. `khash.h` has a pair for integer keys,
`kh_int_hash_func` and `kh_int_hash_equal`, beside the pair for strings.
Give the string table the integer equality by a slip of the name. The
commands write the copies beside the originals, where `khash.h` and
`map.tci` are found:

<!-- stage: slips -->
<!-- run -->
```sh
sed 's/^KHASH_MAP_INIT_STR(word, int)/KHASH_INIT(word, kh_cstr_t, int, 1, kh_str_hash_func, kh_int_hash_equal)/' \
    original/wordfreq.c >original/eqmix.c
```

Both C compilers build it without a word under `-O2 -Wall -Wextra
-Werror`, Clang 21 and GCC 16 alike. `kh_int_hash_equal(a, b)` is
`((a) == (b))`, which compares two `const char *` as pointers, so no
word is ever found and each is counted anew:

```console
$ cc -O2 -Wall -Wextra -Werror -o eqmix original/eqmix.c
$ printf 'the cat the end the\n' | ./eqmix
      1 cat
      1 end
      1 the
      1 the
      1 the
```

`map.tci` has no functions for integer keys, as `wordfreq` needs none.
Add the pair that `khash.h` has, `int_hash` and `int_equal`, to the end
of `map.tci`:

<!-- stage: integer_keys -->
<!-- edit: map.tci -->
```c
static inline uint32_t
int_hash(int key)
{
	return ((uint32_t)key);
}

static inline bool
int_equal(int a, int b)
{
	return (a == b);
}
```

and make the same slip:

<!-- run -->
```sh
sed 's/map_new(str, int)(str_hash, str_equal)/map_new(str, int)(str_hash, int_equal)/' \
    wordfreq.tc >eqmix.tc
```

The equality is a function of the key type, and the type of the map
names the key type, so the slip stops the build at the line that makes
it:

```console
$ typec -O2 -Wall -Wextra -Werror -c eqmix.tc
eqmix.tc:192: error: a value of type '_Bool (*)(int, int)' does not convert to '_Bool (*)(slice(const char), slice(const char))' without a cast (C11 6.5.16.1p1)
  192 | 	h = map_new(str, int)(str_hash, int_equal);
[80]
```

A slip that both catch is reported in different places. Swap the key
and value types of the table:

<!-- stage: swapped_types -->
<!-- run -->
```sh
sed 's/^KHASH_MAP_INIT_STR(word, int)/KHASH_INIT(word, int, kh_cstr_t, 1, kh_str_hash_func, kh_str_hash_equal)/' \
    original/wordfreq.c >original/swap.c
sed 's/map_new(str, int)/map_new(int, str)/' wordfreq.tc >swap.tc
```

Clang reports 13 errors in 154 lines, each at the `KHASH_INIT` line and
traced through the macros of `khash.h`. GCC reports 13 in 200, at lines
of `khash.h`, none of them in `swap.c`:

<!-- untested: it shows two lines of the report of GCC 16 -->
```console
$ gcc-16 -O2 -Wall -Wextra -Werror -c original/swap.c
...
original/khash.h:235:41: error: passing argument 1 of '__ac_X31_hash_string' makes pointer from integer without a cast [-Wint-conversion]
original/khash.h:237:111: error: passing argument 1 of 'strcmp' makes pointer from integer without a cast [-Wint-conversion]
...
```

`typec` stops at its first error, as it always does, and that error is
at the line of the swap, in the types that the line names:

```console
$ typec -O2 -Wall -Wextra -Werror -c swap.tc
swap.tc:192: error: a value of type 'unsigned int (*)(slice(const char))' does not convert to 'unsigned int (*)(int)' without a cast (C11 6.5.16.1p1)
  192 | 	h = map_new(int, str)(str_hash, str_equal);
[80]
```

## Where the port differs

Nowhere in what it prints, its messages or its exit status, for any
input that `make check` runs. Two limits are shared: a count is an
`int`, as in the original, and a word seen more than `INT_MAX` times
overflows it in both. Inside, the Type-C table keeps a slot of 24 bytes,
with the `str` of 16, where `khash` keeps a pointer of 8, an `int` and
two bits in three arrays, and the table holds two function pointers.
