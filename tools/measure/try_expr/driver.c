/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The driver of the forms: driver N ROUNDS builds N values from a fixed
 * seed, runs each form of forms.h over all of them ROUNDS times, and
 * prints a line "name nanoseconds checksum" for each, the checksum over
 * all rounds.  The forms are linked from the objects of forms.tc or of
 * forms_decl.tc; the values are the same.
 */

/* clock_gettime is POSIX, which -std=c11 hides on some hosts. */
#define	_POSIX_C_SOURCE	200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "forms.h"

/* The state of the random numbers; it is never 0. */
#define	SEED		2463534242u

/* The most values, so that the array fits in memory. */
#define	MAX_N		(1 << 24)

/* The values are below this, so that get() of them stays in an int. */
#define	VALUE_LIMIT	100000

struct form {
	const char	*name;
	long		(*run)(const int *, long);
};

static const struct form forms[] = {
	{ "a", run_a }, { "b", run_b }, { "c", run_c },
	{ "d", run_d }, { "e", run_e }, { "f", run_f },
	{ "g", run_g }, { "h", run_h }, { "i", run_i },
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

int
main(int argc, char **argv)
{
	uint32_t state;
	long n, rounds, i, round;
	int *v;
	size_t f;
	long long start;
	long checksum;

	if (argc != 3) {
		fprintf(stderr, "usage: driver N ROUNDS\n");
		return (2);
	}
	n = atol(argv[1]);
	rounds = atol(argv[2]);
	if (n < 1 || n > MAX_N || rounds < 1) {
		fprintf(stderr, "driver: N or ROUNDS out of range\n");
		return (2);
	}
	if ((v = calloc(n, sizeof(*v))) == NULL)
		return (1);
	state = SEED;
	for (i = 0; i < n; i++)
		v[i] = next_random(&state) % VALUE_LIMIT;
	for (f = 0; f < sizeof(forms) / sizeof(forms[0]); f++) {
		checksum = 0;
		start = now_ns();
		for (round = 0; round < rounds; round++)
			checksum += forms[f].run(v, n);
		printf("%s %lld %ld\n", forms[f].name, now_ns() - start,
		    checksum);
	}
	free(v);
	return (0);
}
