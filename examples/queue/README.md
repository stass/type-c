<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# queue: `sys/queue.h` against a typed list

[`original/sched.c`](original/sched.c) is a small round-robin job
scheduler written the way BSD C keeps lists: each job is a structure
with a `TAILQ_ENTRY` for every list it can be on, and the macros of
`<sys/queue.h>` link it in place. [`sched.tc`](sched.tc) is the same
program in Type-C, on `list(T)`, a typed list that
[`list.tci`](list.tci) writes once as two generic types and four
generic functions. The two have the same functions in the same order,
with the same names, comments and control flow, so that `diff
original/sched.c sched.tc` shows only what Type-C changes: the list,
and the `option`, slice and `defer` described below.

The scheduler reads commands from the standard input:

```
add NAME WORK		queue a job of WORK units of work
urgent NAME WORK	the same, at the head of the queue
run QUANTUM		run each queued job for up to QUANTUM units
kill NAME		take a queued job off the queue
ps			list every job in the order added
```

```console
$ printf 'add a 5\nadd b 3\nurgent c 4\nrun 2\nkill b\nrun 3\nps\n' | ./sched
c: ran 2, 2 left
a: ran 2, 3 left
b: ran 2, 1 left
c: ran 2, done
a: ran 3, done
a 0 done
b 1 killed
c 0 done
```

A job is on two lists at once: `all`, every job in the order added, which
`ps` and the lookup by name walk, and `ready`, the jobs that still have
work, in the order they run, where `urgent` puts a job first. `make
check` runs both programs over the same inputs, from the errors of each
command to two thousand jobs, and compares their output, messages and
exit status.

```sh
make            # gmake on FreeBSD; builds sched and original/sched
make check
TYPEC_CC=gcc-14 make clean check
```

[`original/queue.h`](original/queue.h) is FreeBSD's `sys/sys/queue.h`,
unchanged, from [freebsd-src](https://github.com/freebsd/freebsd-src) at
commit `aa15df4597053c0e95a15b2a7036296999cd562a` ("queue.h: Reorder
STAILQ_INSERT_TAIL", 2026-03-16), the last commit that changes the file
on `main` (git blob `e2603bc664c344f3cad4aefbe9a7c5b735c511e0`), under
its BSD-3-Clause license. The program includes it instead of the
system's `<sys/queue.h>` because glibc's has no `TAILQ_FOREACH_SAFE`
and musl has none. `queue.h` includes `<sys/cdefs.h>`, which musl also
lacks; [`original/compat/sys/cdefs.h`](original/compat/sys/cdefs.h) is
an empty one that the [Makefile](Makefile) puts after the system
directories, so it is read only where the C library has none.

## What the port changes

### The list owns its nodes

A `TAILQ` is intrusive: the links are members of the element, and the
macros reach them by the name of the member. `list(T)` is not: the list
allocates a node that holds a copy of the value and the links, so
`struct job` loses its two `TAILQ_ENTRY` members, and the scheduler
names its lists by what they hold:

```c
struct scheduler {
	list(struct job)	all;	/* every job, in the order added */
	list(struct job *)	ready;	/* the READY jobs of all, in run order */
};
```

`all` owns the jobs; `ready` holds pointers into the nodes of `all`,
where a job stays put until the exit. `list(struct job)` and
`list(struct job *)` are two types, and so are their nodes,
`list_node(struct job)` and `list_node(struct job *)`: the mistakes
below come down to that.

The loops are plain `for` loops over the nodes, in place of the macros.
`TAILQ_FOREACH_SAFE` becomes the loop that it expands to, with the next
node read before the body can free this one:

```c
	TAILQ_FOREACH_SAFE(j, &s->ready, ready_link, next) {
		...
		TAILQ_REMOVE(&s->ready, j, ready_link);
	}
```

```c
	for (n = s->ready.first; n != NULL; n = next) {
		next = n->next;
		j = n->value;
		...
		list_remove(&s->ready, n);
	}
```

### Lookups return `option`, and the words are a slice

`find_job` returns `option(struct job *)`, `None` where the original
returns `NULL`. `add_job` asks only whether there is one, with a test
that binds nothing:

```c
	if (case Some = find_job(s, words[1])) {
```

`kill_job` binds the job, and that changes its shape: a binding lives
only in the statement that the test controls, so the work on the job
moves inside the `if` and the message of a missing job follows it,
where the original reports the missing job first and goes on.

The words of a command were a `char **words` and an `int nwords`
passed side by side through every handler; they are one
`slice(char *)`, whose `words[i]` is checked against `words.len`.
`split` fills the array of `main` through a slice of it and returns the
part it filled, so the bound `MAX_WORDS + 1` is written once, in the
size of the array.

### `defer` frees beside the allocation

`main` says `defer free(line)` and `defer free_jobs(&s)` once, at the
top, where the original frees both at the bottom. `main` has one
`return`, so this buys little here beyond keeping the cleanup next to
what it cleans; `err(1, "stdin")` exits without running either, as in
the original. `free_jobs` clears the two lists.

## Three classic mistakes

`sys/queue.h` takes the name of the member to link through, and it
types nothing else: a member of the right shape, `TAILQ_ENTRY(job)`, is
all a macro needs. Each mistake below compiles in the original without a
word under `cc -Wall -Wextra -Werror`.

### The right list, the wrong link

`kill_job` unlinks the job through `all_link` instead of `ready_link`:

```c
	TAILQ_REMOVE(&s->ready, j, all_link);
```

The macro unlinks the job from `all` and leaves it on `ready`: the
killed job vanishes from `ps`, keeps running, and is never freed, since
`free_jobs` walks `all`. Were the job last on `all`, the macro would also
point the tail of `ready` into `all`.

```console
$ printf 'add a 3\nadd b 3\nadd c 3\nkill b\nrun 1\nps\n' | ./sched
a: ran 1, 2 left
b: ran 1, 2 left
c: ran 1, 2 left
a 2 ready
c 2 ready
```

The port has no link to name. The nearest mistake is to hand a node of
`ready` to the other list, and `typec` refuses it:

```c
		list_remove(&s->all, n);
```

```console
$ typec -O2 -Wall -Wextra -Werror -c sched.tc
sched.tc:171: error: a value of type 'list_node(struct job *) *' does not convert to 'list_node(struct job) *' without a cast (C11 6.5.16.1p1)
[80]
```

That holds because the two lists hold different types. Had the port
kept both as `list(struct job *)`, with the jobs allocated apart, the
call would compile, and `list_remove` would unlink a node of one list
from the head of the other.

### The wrong list

`add_job` queues the job on `all` again instead of on `ready`:

```c
		TAILQ_INSERT_TAIL(&s->all, j, ready_link);
```

The job now links to itself through `all_link`, and the next walk of
`all` never ends:

```console
$ printf 'add a 2\nps\n' | ./sched | head -3
a 2 ready
a 2 ready
a 2 ready
```

In the port the same slip passes a `struct job *` where a
`list(struct job)` takes a `struct job`, and `typec` refuses the
argument itself, as C refuses the same assignment:

```c
		queued = list_insert_tail(&s->all, j);
```

```console
$ typec -O2 -Wall -Wextra -Werror -c sched.tc
sched.tc:111: error: a value of type 'struct job *' does not convert to 'struct job' (C11 6.5.16.1p1)
[80]
```

### Removing during a walk

`run_jobs` walks `ready` with `TAILQ_FOREACH` instead of
`TAILQ_FOREACH_SAFE`, its `next` variable dropped with it, and the loop
reads the next job from the one it
just removed. With FreeBSD's `queue.h` that works by accident:
`TAILQ_REMOVE` leaves the removed job's links as they were, so the
output is right. Built with `-DQUEUE_MACRO_DEBUG_TRASH`, which
overwrites them, the same program dies of a segmentation fault:

```console
$ cc -Wall -Wextra -Werror -DQUEUE_MACRO_DEBUG_TRASH -o sched-trash sched.c
$ printf 'add a 1\nadd b 2\nadd c 3\nrun 1\n' | ./sched-trash; echo $?
139
```

Type-C does not catch this one. The port's loop with `n = n->next` in
place of `next`, and `next` dropped, compiles without a word, and is
worse than the
original's, since `list_remove` frees the node that the loop then reads.
AddressSanitizer finds it:

```console
$ typec -g -Wall -Wextra -Werror -fsanitize=address -o sched-asan sched.tc
$ printf 'add a 1\nadd b 2\nrun 1\n' | ./sched-asan
==71433==ERROR: AddressSanitizer: heap-use-after-free on address 0x603000001b48 ...
READ of size 8 at 0x603000001b48 thread T0
    #0 0x0001092fb217 in run_jobs sched.tc:133
    #1 0x0001092f9f4e in run_command sched.tc:203
    #2 0x0001092f9a79 in main sched.tc:255
```

A list that took the loop's body as a function could make this mistake
impossible to write, but it would turn every loop of the program into a
callback, and the port keeps the original's loops.

## What the typed list cannot do, and what it costs

Type-C's generics cannot express the intrusive list. A generic function
sees its type parameter as an opaque value: it can copy a `T` and take
its address, but not name a member of it, so there is no `list(T, field)`
that links an element through a member it has. What follows from that:

- **An allocation per node.** The original allocates one block per job
  and links it in place; the port allocates a node on `all` and another
  on `ready`, and can fail on either. Sizes on x86-64 macOS, with the
  block that `malloc_good_size` rounds each to:

  | | bytes | block |
  |---|---:|---:|
  | `struct job` with two `TAILQ_ENTRY`, the original | 56 | 64 |
  | `list_node(struct job)`, on `all` | 40 | 48 |
  | `list_node(struct job *)`, on `ready` | 24 | 32 |

  A queued job takes 64 bytes in the original and 80 in the port, two
  allocations where there was one. Forty thousand jobs added and run
  peak at 3.21 MB in the original and 3.88 MB in the port (`/usr/bin/time
  -l`, peak memory footprint): 16 bytes more a job, as the table says.
- **An element on several lists is a pointer on all but one.** The
  original's job is on `all` and `ready` through two members. The port's
  is a value on `all` and a pointer on `ready`, and the pointer is good
  only while the node on `all` lives.
- **A value does not know its node.** `TAILQ_REMOVE` unlinks a job in
  constant time, because the job holds its links. The port's `kill_job`
  has the job and must walk `ready` to find the node that points to it,
  the one loop the port adds. The walk is no worse than the lookup by
  name before it, which both programs make, but a scheduler that removed
  by pointer often would feel it.
- **Code.** `list.tci` makes one instance of each function for each
  type it is used with, where the macros expand in place. The object
  files hold 2468 bytes of text for `sched.tc` and 2188 for `sched.c`,
  at `-O2` with Apple Clang.

What the port gets for it is in the mistakes above: the list's type says
what it holds, and a node of one kind does not pass where another is
wanted.

## What got longer

| | `original/sched.c` | `sched.tc` | `list.tci` |
|---|---:|---:|---:|
| lines | 256 | 262 | 92 |
| lines of code, without comments and blank lines | 202 | 208 | 66 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
program is about the same length: the loops written out where the original
had a macro, the second `malloc` check and the search in `kill_job`
cost about as much as the two `TAILQ_ENTRY` members, the `TAILQ_HEAD`
and the `nwords` arguments save. The list itself is 66 lines that the
original gets from the 1097 of `queue.h`, which also hold three other
kinds of list.
