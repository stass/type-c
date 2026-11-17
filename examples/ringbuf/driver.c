/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * A hosted board for the firmware core: it feeds the standard input to
 * fw_rx, as the UART interrupt would, calls fw_poll after every N bytes
 * and once at the end of the input, and writes what fw_tx gives to the
 * standard output. A large N lets bytes arrive faster than the main
 * loop takes them, so that the receive ring fills.
 */

#include <stdio.h>
#include <stdlib.h>

#include "firmware.h"

/* The temperatures that board_temp reports, in turn. */
static const int temps[] = { 21, 0, -40, 125 };
static size_t next_temp;

void
board_led(int on)
{
	printf("[led %d]\n", on);
}

int
board_temp(void)
{
	int t = temps[next_temp];

	next_temp = (next_temp + 1) % (sizeof(temps) / sizeof(temps[0]));
	return (t);
}

_Noreturn void
panic(void)
{
	fflush(stdout);
	fputs("driver: panic\n", stderr);
	exit(3);
}

/* Runs the main loop once and sends the replies it queued. */
static void
service(void)
{
	int c;

	fw_poll();
	while ((c = fw_tx()) != -1)
		putchar(c);
}

int
main(int argc, char **argv)
{
	unsigned long every, fed = 0;
	int c;

	if (argc != 2 || (every = strtoul(argv[1], NULL, 10)) == 0) {
		fputs("usage: driver bytes-per-poll\n", stderr);
		return (2);
	}
	fw_init();
	while ((c = getchar()) != EOF) {
		fw_rx((unsigned char)c);
		if (++fed % every == 0)
			service();
	}
	service();
	return (0);
}
