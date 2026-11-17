/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The driver of the measurements of nested patterns: driver N ROUNDS
 * builds N values of each type from fixed random numbers, runs each
 * matcher of nested.h over all of them ROUNDS times, and prints the
 * nanoseconds and the checksum of each over all rounds, as lines
 * "name nanoseconds checksum".  The matchers are linked from the objects
 * of the Type-C units or of the C twins; the values are the same.
 */

/* clock_gettime is POSIX, which -std=c11 hides on some hosts. */
#define	_POSIX_C_SOURCE	200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "nested.h"

/* The state of the random numbers; it is never 0. */
#define	SEED		2463534242u

/* The most elements, so that the arrays fit in memory. */
#define	MAX_N		(1 << 24)

/* A child is one of this many values before its parent. */
#define	WINDOW		32

/* The nanoseconds and the checksum of a phase over all rounds. */
struct phase {
	const char	*name;
	long long	ns;
	unsigned long long checksum;
};

/* xorshift32: a state that is not 0 never becomes 0. */
static uint32_t
next_random(uint32_t *state)
{
	uint32_t x;

	x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return (x);
}

/* A monotonic clock, as a wall clock that steps would spoil a minimum. */
static long long
now_ns(void)
{
	struct timespec t;

	if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) {
		perror("driver: clock_gettime");
		exit(1);
	}
	return ((long long)t.tv_sec * 1000000000 + t.tv_nsec);
}

/* The arm of a matcher: a function that no backend can inline. */
long
arm(int id, long a, long b)
{

	return ((a * 31 + b) ^ id);
}

/* The index of a child of the value of index i, below i. */
static size_t
child(uint32_t *state, size_t i)
{
	size_t span;

	span = i < WINDOW ? i : WINDOW;
	return (i - 1 - next_random(state) % span);
}

static expr *
make_exprs(size_t n)
{
	uint32_t state;
	expr *e;
	size_t i;
	uint32_t kind;

	state = SEED;
	if ((e = calloc(n, sizeof(*e))) == NULL)
		exit(1);
	for (i = 0; i < n; i++) {
		kind = i == 0 ? 0 : next_random(&state) % 10;
		if (kind < 3) {
			e[i].tag = expr_Num;
			e[i].u.Num.value = next_random(&state) % 1000;
		} else if (kind < 6) {
			e[i].tag = expr_Add;
			e[i].u.Add.l = &e[child(&state, i)];
			e[i].u.Add.r = &e[child(&state, i)];
		} else if (kind < 8) {
			e[i].tag = expr_Mul;
			e[i].u.Mul.l = &e[child(&state, i)];
			e[i].u.Mul.r = &e[child(&state, i)];
		} else {
			e[i].tag = expr_Neg;
			e[i].u.Neg.e = &e[child(&state, i)];
		}
	}
	return (e);
}

static list *
make_lists(size_t n)
{
	uint32_t state;
	list *l;
	size_t i;

	state = SEED;
	if ((l = calloc(n, sizeof(*l))) == NULL)
		exit(1);
	for (i = 0; i < n; i++) {
		if (i == 0 || next_random(&state) % 8 == 0) {
			l[i].tag = list_Nil;
		} else {
			l[i].tag = list_Cons;
			l[i].u.Cons.head = next_random(&state) % 1000;
			l[i].u.Cons.tail = &l[child(&state, i)];
		}
	}
	return (l);
}

static result *
make_results(size_t n)
{
	uint32_t state;
	result *r;
	size_t i;
	uint32_t kind;

	state = SEED;
	if ((r = calloc(n, sizeof(*r))) == NULL)
		exit(1);
	for (i = 0; i < n; i++) {
		kind = next_random(&state) % 4;
		if (kind == 0) {
			r[i].tag = result_Ok;
			r[i].u.Ok.value = next_random(&state) % 1000;
			continue;
		}
		r[i].tag = result_Err;
		r[i].u.Err.fault.tag = kind - 1;
		if (r[i].u.Err.fault.tag == fault_Io)
			r[i].u.Err.fault.u.Io.error =
			    next_random(&state) % 1000;
	}
	return (r);
}

static struct node *
make_nodes(size_t n)
{
	uint32_t state;
	struct node *node;
	size_t i;

	state = SEED;
	if ((node = calloc(n, sizeof(*node))) == NULL)
		exit(1);
	for (i = 0; i < n; i++) {
		node[i].id = i;
		node[i].small.tag = next_random(&state) % 3;
		node[i].small.u.Busy.load = next_random(&state) % 1000;
		node[i].large.tag = next_random(&state) % 2;
		node[i].large.u.Wide.a = next_random(&state) % 1000;
		node[i].large.u.Wide.b = next_random(&state) % 1000;
		node[i].large.u.Wide.c = next_random(&state) % 1000;
		node[i].large.u.Wide.d = next_random(&state) % 1000;
		node[i].large.u.Wide.e = next_random(&state) % 1000;
		node[i].large.u.Wide.f = next_random(&state) % 1000;
	}
	return (node);
}

static void
run_exprs(struct phase *phase, long (*matcher)(const expr *), const expr *e,
    size_t n, size_t rounds)
{
	unsigned long long sum;
	long long start;
	size_t i, round;

	sum = 0;
	start = now_ns();
	for (round = 0; round < rounds; round++)
		for (i = 0; i < n; i++)
			sum += matcher(&e[i]);
	phase->ns = now_ns() - start;
	phase->checksum = sum;
}

static void
run_lists(struct phase *phase, long (*matcher)(const list *), const list *l,
    size_t n, size_t rounds)
{
	unsigned long long sum;
	long long start;
	size_t i, round;

	sum = 0;
	start = now_ns();
	for (round = 0; round < rounds; round++)
		for (i = 0; i < n; i++)
			sum += matcher(&l[i]);
	phase->ns = now_ns() - start;
	phase->checksum = sum;
}

static void
run_results(struct phase *phase, long (*matcher)(const result *),
    const result *r, size_t n, size_t rounds)
{
	unsigned long long sum;
	long long start;
	size_t i, round;

	sum = 0;
	start = now_ns();
	for (round = 0; round < rounds; round++)
		for (i = 0; i < n; i++)
			sum += matcher(&r[i]);
	phase->ns = now_ns() - start;
	phase->checksum = sum;
}

static void
run_nodes(struct phase *phase, long (*matcher)(const struct node *),
    const struct node *node, size_t n, size_t rounds)
{
	unsigned long long sum;
	long long start;
	size_t i, round;

	sum = 0;
	start = now_ns();
	for (round = 0; round < rounds; round++)
		for (i = 0; i < n; i++)
			sum += matcher(&node[i]);
	phase->ns = now_ns() - start;
	phase->checksum = sum;
}

int
main(int argc, char **argv)
{
	struct phase phases[6] = {
		{ "fold", 0, 0 }, { "fold_test", 0, 0 },
		{ "sum_list", 0, 0 }, { "outcome", 0, 0 },
		{ "member_small", 0, 0 }, { "member_large", 0, 0 }
	};
	unsigned long n, rounds;
	expr *e;
	list *l;
	result *r;
	struct node *node;
	size_t i;

	if (argc != 3) {
		fprintf(stderr, "usage: driver N ROUNDS\n");
		return (1);
	}
	n = strtoul(argv[1], NULL, 10);
	rounds = strtoul(argv[2], NULL, 10);
	if (n == 0 || n > MAX_N || rounds == 0) {
		fprintf(stderr, "driver: N must be in 1..%d, ROUNDS above 0\n",
		    MAX_N);
		return (1);
	}
	e = make_exprs(n);
	l = make_lists(n);
	r = make_results(n);
	node = make_nodes(n);
	run_exprs(&phases[0], fold, e, n, rounds);
	run_exprs(&phases[1], fold_test, e, n, rounds);
	run_lists(&phases[2], sum_list, l, n, rounds);
	run_results(&phases[3], outcome, r, n, rounds);
	run_nodes(&phases[4], member_small, node, n, rounds);
	run_nodes(&phases[5], member_large, node, n, rounds);
	for (i = 0; i < sizeof(phases) / sizeof(phases[0]); i++)
		printf("%s %lld %llu\n", phases[i].name, phases[i].ns,
		    phases[i].checksum);
	free(e);
	free(l);
	free(r);
	free(node);
	return (0);
}
