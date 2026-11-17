/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The driver of eval_bench.tc: eval_driver ROUNDS prints a line
 * "eval nanoseconds checksum" for ROUNDS evaluations of the tree.
 */

/* clock_gettime is POSIX, which -std=c11 hides on some hosts. */
#define	_POSIX_C_SOURCE	200809L

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

long	run_eval(long rounds);

/* A monotonic clock, as a wall clock that steps would spoil a minimum. */
static long long
now_ns(void)
{
	struct timespec t;

	if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) {
		perror("eval_driver: clock_gettime");
		exit(1);
	}
	return ((long long)t.tv_sec * 1000000000 + t.tv_nsec);
}

int
main(int argc, char **argv)
{
	long long start;
	long rounds, checksum;

	if (argc != 2 || (rounds = atol(argv[1])) < 1) {
		fprintf(stderr, "usage: eval_driver ROUNDS\n");
		return (2);
	}
	start = now_ns();
	checksum = run_eval(rounds);
	printf("eval %lld %ld\n", now_ns() - start, checksum);
	return (0);
}
