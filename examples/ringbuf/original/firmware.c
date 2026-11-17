/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The command interpreter of a small device, as firmware has one on
 * its serial port. The UART interrupt queues each byte it receives in a
 * ring; the main loop takes them out, assembles lines and answers each
 * line with a reply, which it queues in a second ring for the UART to
 * send. It needs no C library: it is built with -ffreestanding.
 *
 *	set led 0|1	turns the LED off or on; replies "ok"
 *	get led		replies "led" and the LED's state
 *	get temp	replies "temp" and the board's temperature
 *	echo text	replies the text
 *	stats		replies the bytes dropped by each ring when full
 */

#include <stddef.h>

#include "../firmware.h"
#include "ring.h"

#define RX_SIZE		16	/* bytes received and not yet polled */
#define TX_SIZE		32	/* bytes of replies not yet sent */
#define LINE_SIZE	32	/* the longest command line */

/* The digits of the largest unsigned long, of 64 bits. */
#define DECIMAL_DIGITS	20

enum command_kind {
	CMD_EMPTY,			/* a blank line */
	CMD_SET_LED,
	CMD_GET_LED,
	CMD_GET_TEMP,
	CMD_ECHO,
	CMD_STATS,
};

struct command {
	enum command_kind kind;
	int		on;		/* CMD_SET_LED */
	const char	*text;		/* CMD_ECHO */
};

enum parse_error { PARSE_OK, PARSE_UNKNOWN, PARSE_ARGUMENT };

static unsigned char rx_buf[RX_SIZE];
static unsigned char tx_buf[TX_SIZE];
static struct ring rx, tx;
static char line[LINE_SIZE + 1];	/* and the NUL that parse needs */
static size_t line_len;
static int line_too_long;		/* bytes of this line were lost */
static int led;
static unsigned long rx_dropped, tx_dropped;

static void
put_char(char c)
{
	if (!ring_put(&tx, (unsigned char)c))
		tx_dropped++;
}

static void
put_string(const char *s)
{
	while (*s != '\0')
		put_char(*s++);
}

static void
put_decimal(unsigned long n)
{
	char digits[DECIMAL_DIGITS];
	size_t len = 0;

	do {
		digits[len++] = (char)('0' + n % 10);
		n /= 10;
	} while (n != 0);
	while (len > 0)
		put_char(digits[--len]);
}

static void
put_signed(long n)
{
	if (n < 0) {
		put_char('-');
		put_decimal(0UL - (unsigned long)n);
		return;
	}
	put_decimal((unsigned long)n);
}

static int
equal(const char *a, const char *b)
{
	while (*a != '\0' && *a == *b) {
		a++;
		b++;
	}
	return (*a == *b);
}

/*
 * Returns the word at *s, after any spaces, and moves *s past it and
 * the one space that ends it, which becomes the word's NUL.
 */
static char *
next_word(char **s)
{
	char *p = *s, *word;

	while (*p == ' ')
		p++;
	word = p;
	while (*p != '\0' && *p != ' ')
		p++;
	if (*p == ' ')
		*p++ = '\0';
	*s = p;
	return (word);
}

static enum parse_error
parse_get(char *s, struct command *cmd)
{
	char *object = next_word(&s);

	if (equal(object, "led"))
		cmd->kind = CMD_GET_LED;
	else if (equal(object, "temp"))
		cmd->kind = CMD_GET_TEMP;
	else
		return (PARSE_ARGUMENT);
	if (*next_word(&s) != '\0')
		return (PARSE_ARGUMENT);
	return (PARSE_OK);
}

static enum parse_error
parse_set(char *s, struct command *cmd)
{
	char *object = next_word(&s);
	char *value = next_word(&s);

	if (!equal(object, "led"))
		return (PARSE_ARGUMENT);
	if (equal(value, "0"))
		cmd->on = 0;
	else if (equal(value, "1"))
		cmd->on = 1;
	else
		return (PARSE_ARGUMENT);
	if (*next_word(&s) != '\0')
		return (PARSE_ARGUMENT);
	cmd->kind = CMD_SET_LED;
	return (PARSE_OK);
}

/* Reads the command of line s, which it cuts into words. */
static enum parse_error
parse(char *s, struct command *cmd)
{
	char *verb = next_word(&s);

	if (*verb == '\0') {
		cmd->kind = CMD_EMPTY;
		return (PARSE_OK);
	}
	if (equal(verb, "echo")) {
		cmd->kind = CMD_ECHO;
		cmd->text = s;
		return (PARSE_OK);
	}
	if (equal(verb, "stats")) {
		if (*next_word(&s) != '\0')
			return (PARSE_ARGUMENT);
		cmd->kind = CMD_STATS;
		return (PARSE_OK);
	}
	if (equal(verb, "get"))
		return (parse_get(s, cmd));
	if (equal(verb, "set"))
		return (parse_set(s, cmd));
	return (PARSE_UNKNOWN);
}

static void
execute(const struct command *cmd)
{
	switch (cmd->kind) {
	case CMD_EMPTY:
		break;
	case CMD_SET_LED:
		led = cmd->on;
		board_led(led);
		put_string("ok\n");
		break;
	case CMD_GET_LED:
		put_string("led ");
		put_decimal((unsigned long)led);
		put_char('\n');
		break;
	case CMD_GET_TEMP:
		put_string("temp ");
		put_signed(board_temp());
		put_char('\n');
		break;
	case CMD_ECHO:
		put_string(cmd->text);
		put_char('\n');
		break;
	case CMD_STATS:
		put_string("dropped rx ");
		put_decimal(rx_dropped);
		put_string(" tx ");
		put_decimal(tx_dropped);
		put_char('\n');
		break;
	}
}

/* Adds c to the line, or marks the line too long when it is full. */
static void
add_char(char c)
{
	if (line_len == LINE_SIZE) {
		line_too_long = 1;
		return;
	}
	line[line_len++] = c;
}

/* Answers the line just ended, and starts the next. */
static void
end_line(void)
{
	struct command cmd = { CMD_EMPTY, 0, NULL };

	if (line_too_long) {
		put_string("error: line too long\n");
	} else {
		line[line_len] = '\0';
		switch (parse(line, &cmd)) {
		case PARSE_OK:
			execute(&cmd);
			break;
		case PARSE_UNKNOWN:
			put_string("error: unknown command\n");
			break;
		case PARSE_ARGUMENT:
			put_string("error: bad argument\n");
			break;
		}
	}
	line_len = 0;
	line_too_long = 0;
}

void
fw_init(void)
{
	ring_init(&rx, rx_buf, sizeof(rx_buf));
	ring_init(&tx, tx_buf, sizeof(tx_buf));
}

/* Drops byte, and counts it, when the main loop has fallen behind. */
void
fw_rx(unsigned char byte)
{
	if (!ring_put(&rx, byte))
		rx_dropped++;
}

/* Answers each line that the UART has received; a CR is ignored. */
void
fw_poll(void)
{
	int c;

	while ((c = ring_get(&rx)) != -1) {
		if (c == '\n')
			end_line();
		else if (c != '\r')
			add_char((char)c);
	}
}

int
fw_tx(void)
{
	return (ring_get(&tx));
}
