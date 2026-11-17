/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/* The shared part of the benchmarks: see bench_common.h. */

/* clock_gettime is POSIX, which -std=c11 hides on some hosts. */
#define	_POSIX_C_SOURCE	200809L

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "bench_common.h"

static const char *const phase_names[PHASE_COUNT] = {
	[PHASE_VECTOR_PUSH] = "vector_push",
	[PHASE_VECTOR_GET] = "vector_get",
	[PHASE_SUM_CHECKED] = "sum_checked",
	[PHASE_SUM_UNCHECKED] = "sum_unchecked",
	[PHASE_VECTOR_APPEND] = "vector_append",
	[PHASE_VECTOR_POP] = "vector_pop",
	[PHASE_REGION_NEW] = "region_new",
	[PHASE_MAP_PUT] = "map_put",
	[PHASE_MAP_GET] = "map_get",
	[PHASE_MAP_EACH] = "map_each"
};

/* The nanoseconds and the checksums of each phase over all rounds. */
static long long phase_ns[PHASE_COUNT];
static unsigned long long phase_checksum[PHASE_COUNT];

/* xorshift32: a state that is not 0 never becomes 0. */
uint32_t
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
long long
now_ns(void)
{
	struct timespec t;

	if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) {
		perror("bench: clock_gettime");
		exit(1);
	}
	return ((long long)t.tv_sec * 1000000000 + t.tv_nsec);
}

void
phase_done(enum phase phase, long long start, unsigned long long checksum)
{

	phase_ns[phase] += now_ns() - start;
	phase_checksum[phase] += checksum;
}

void
print_phases(void)
{
	int phase;

	for (phase = 0; phase < PHASE_COUNT; phase++)
		printf("%s %lld %llu\n", phase_names[phase], phase_ns[phase],
		    phase_checksum[phase]);
}

/* Reads N and ROUNDS, or says what they must be and returns 0. */
int
bench_arguments(int argc, char **argv, size_t *n, size_t *rounds)
{
	unsigned long count, repeat;

	if (argc != 3) {
		fprintf(stderr, "usage: bench N ROUNDS\n");
		return (0);
	}
	count = strtoul(argv[1], NULL, 10);
	repeat = strtoul(argv[2], NULL, 10);
	if (count == 0 || count > BENCH_MAX_N || repeat == 0) {
		fprintf(stderr, "bench: N must be in 1..%d, ROUNDS above 0\n",
		    BENCH_MAX_N);
		return (0);
	}
	*n = count;
	*rounds = repeat;
	return (1);
}
