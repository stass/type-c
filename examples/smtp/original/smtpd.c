/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * smtpd: the server side of a small subset of SMTP, RFC 5321.  Reads
 * what a client sends from standard input, a command or a line of
 * message text per line, writes the replies to standard output, and
 * appends each message it accepts to a mailbox file.  It knows HELO,
 * EHLO, MAIL, RCPT, DATA, RSET, NOOP and QUIT, and no extension.
 *
 * Usage: smtpd mailbox
 */

#include <err.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define	HOSTNAME	"smtpd.example"	/* the name the server gives */
#define	MAX_LINE	1000	/* a line, CRLF included, RFC 5321 4.5.3.1.6 */
#define	MAX_DOMAIN	255	/* RFC 5321 4.5.3.1.2 */
#define	MAX_ADDRESS	254	/* a path less its brackets, 4.5.3.1.3 */
#define	MAX_RCPT	100	/* the least a server must take, 4.5.3.1.8 */
#define	MAX_SPOOL	(1024 * 1024)	/* a message, envelope included */

/* Where the session is.  Each field of struct session names its states. */
enum state {
	STATE_INIT,		/* before HELO or EHLO */
	STATE_GREETED,		/* after HELO, between messages */
	STATE_MAIL,		/* after MAIL, taking RCPT */
	STATE_DATA		/* after DATA, reading the message text */
};

struct session {
	enum state	state;
	char		client[MAX_DOMAIN + 1];	/* all but INIT */
	char		from[MAX_ADDRESS + 1];	/* MAIL; "" for <> */
	char		rcpt[MAX_RCPT][MAX_ADDRESS + 1]; /* MAIL */
	size_t		nrcpt;			/* MAIL */
	FILE		*spool;			/* DATA */
	FILE		*mailbox;
	unsigned	queued;			/* messages accepted */
};

enum verb {
	VERB_HELO,
	VERB_EHLO,
	VERB_MAIL,
	VERB_RCPT,
	VERB_DATA,
	VERB_RSET,
	VERB_NOOP,
	VERB_QUIT
};

/* The commands, by the four letters that name them, in any case. */
static const struct {
	const char	*name;
	enum verb	verb;
} verbs[] = {
	{ "HELO", VERB_HELO },
	{ "EHLO", VERB_EHLO },
	{ "MAIL", VERB_MAIL },
	{ "RCPT", VERB_RCPT },
	{ "DATA", VERB_DATA },
	{ "RSET", VERB_RSET },
	{ "NOOP", VERB_NOOP },
	{ "QUIT", VERB_QUIT },
};

#define	NVERBS	(sizeof(verbs) / sizeof(verbs[0]))

struct command {
	enum verb	verb;
	char		domain[MAX_DOMAIN + 1];		/* HELO, EHLO */
	char		address[MAX_ADDRESS + 1];	/* MAIL, RCPT */
};

/* How read_line ended. */
enum line {
	LINE_OK,		/* a line, in buf without its CRLF */
	LINE_EOF,		/* the end of input */
	LINE_TOO_LONG,		/* MAX_LINE bytes without CRLF */
	LINE_BARE_LF		/* a LF without a CR before it */
};

/* Writes a reply and sends it before the next line is read. */
static void
reply(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\r\n");
	if (fflush(stdout) == EOF)
		err(1, "stdout");
}

/*
 * Reads a line that ends in CRLF from standard input into buf, without
 * the CRLF and with a NUL after it, and its length into *lenp.  A last
 * line without its LF is dropped, as a client that went away left it.
 */
static enum line
read_line(char *buf, size_t size, size_t *lenp)
{
	size_t len;
	int c;

	len = 0;
	while ((c = getchar()) != EOF) {
		if (c == '\n') {
			/* SMTP smuggling needs a bare LF to end a line. */
			if (len == 0 || buf[len - 1] != '\r')
				return (LINE_BARE_LF);
			buf[--len] = '\0';
			*lenp = len;
			return (LINE_OK);
		}
		/* The last byte of buf is kept for the NUL. */
		if (len == size - 1)
			return (LINE_TOO_LONG);
		buf[len++] = (char)c;
	}
	return (LINE_EOF);
}

/* Whether each byte is printable ASCII but space, '<' and '>'. */
static bool
printable(const char *s, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++)
		if (s[i] < '!' || s[i] > '~' || s[i] == '<' || s[i] == '>')
			return (false);
	return (true);
}

/* Reads " domain", the argument of HELO and EHLO, into domain. */
static const char *
parse_domain(const char *arg, char *domain)
{
	size_t len;

	if (arg[0] != ' ')
		return ("501 Syntax: HELO domain");
	arg++;
	len = strlen(arg);
	if (len == 0 || len > MAX_DOMAIN || !printable(arg, len))
		return ("501 Syntax: HELO domain");
	memcpy(domain, arg, len + 1);
	return (NULL);
}

/*
 * Reads keyword, " FROM:" or " TO:" in any case, then a path, <address>,
 * into address without the brackets.  Only MAIL takes the null path, <>.
 */
static const char *
parse_path(const char *arg, const char *keyword, bool null_ok,
    char *address)
{
	size_t len;

	len = strlen(keyword);
	if (strncasecmp(arg, keyword, len) != 0)
		return ("501 Syntax error in parameters");
	arg += len;
	len = strlen(arg);
	if (len < 2 || arg[0] != '<' || arg[len - 1] != '>')
		return ("501 Syntax error in parameters");
	arg++;
	len -= 2;
	if (len == 0 && !null_ok)
		return ("501 Syntax error in parameters");
	if (len > MAX_ADDRESS || !printable(arg, len))
		return ("501 Syntax error in parameters");
	memcpy(address, arg, len);
	address[len] = '\0';
	return (NULL);
}

/*
 * Parses a command line into cmd.  Returns NULL, or the reply to a line
 * that does not parse.
 */
static const char *
parse_command(const char *line, size_t len, struct command *cmd)
{
	const char *arg, *error;
	size_t i;

	/* A NUL would end the line early for the string functions. */
	if (memchr(line, '\0', len) != NULL)
		return ("500 Syntax error");
	for (i = 0; i < NVERBS; i++)
		if (strncasecmp(line, verbs[i].name, 4) == 0)
			break;
	if (i == NVERBS || (line[4] != '\0' && line[4] != ' '))
		return ("500 Command unrecognized");
	cmd->verb = verbs[i].verb;
	arg = line + 4;
	switch (cmd->verb) {
	case VERB_HELO:
	case VERB_EHLO:
		if ((error = parse_domain(arg, cmd->domain)) != NULL)
			return (error);
		break;
	case VERB_MAIL:
		if ((error = parse_path(arg, " FROM:", true,
		    cmd->address)) != NULL)
			return (error);
		break;
	case VERB_RCPT:
		if ((error = parse_path(arg, " TO:", false,
		    cmd->address)) != NULL)
			return (error);
		break;
	case VERB_NOOP:
		/* NOOP takes any argument, RFC 5321 4.1.1.9. */
		break;
	case VERB_DATA:
	case VERB_RSET:
	case VERB_QUIT:
		if (arg[0] != '\0')
			return ("501 Syntax error in parameters");
		break;
	}
	return (NULL);
}

/* HELO and EHLO start the session again, RFC 5321 4.1.4. */
static void
helo(struct session *s, const struct command *cmd)
{
	memcpy(s->client, cmd->domain, sizeof(s->client));
	s->state = STATE_GREETED;
	reply("250 %s", HOSTNAME);
}

static void
mail(struct session *s, const struct command *cmd)
{
	switch (s->state) {
	case STATE_INIT:
		reply("503 Send HELO first");
		break;
	case STATE_GREETED:
		memcpy(s->from, cmd->address, sizeof(s->from));
		s->nrcpt = 0;
		s->state = STATE_MAIL;
		reply("250 Ok");
		break;
	case STATE_MAIL:
	case STATE_DATA:
		reply("503 Nested MAIL command");
		break;
	}
}

static void
rcpt(struct session *s, const struct command *cmd)
{
	if (s->state != STATE_MAIL) {
		reply("503 Need MAIL first");
		return;
	}
	if (s->nrcpt == MAX_RCPT) {
		reply("452 Too many recipients");
		return;
	}
	memcpy(s->rcpt[s->nrcpt++], cmd->address, sizeof(s->rcpt[0]));
	reply("250 Ok");
}

/*
 * Starts the message: the envelope goes to a spool file, which the text
 * follows.
 */
static void
data(struct session *s)
{
	size_t i;

	if (s->state != STATE_MAIL) {
		reply("503 Need MAIL first");
		return;
	}
	if (s->nrcpt == 0) {
		reply("554 No valid recipients");
		return;
	}
	if ((s->spool = tmpfile()) == NULL)
		err(1, "tmpfile");
	fprintf(s->spool, "From <%s> via %s\n", s->from, s->client);
	for (i = 0; i < s->nrcpt; i++)
		fprintf(s->spool, "To <%s>\n", s->rcpt[i]);
	putc('\n', s->spool);
	s->state = STATE_DATA;
	reply("354 End data with <CR><LF>.<CR><LF>");
}

/* RSET ends the transaction; the HELO stays. */
static void
rset(struct session *s)
{
	if (s->state == STATE_MAIL)
		s->state = STATE_GREETED;
	reply("250 Ok");
}

/* Runs a command line.  Returns false after QUIT. */
static bool
command(struct session *s, const char *line, size_t len)
{
	struct command cmd;
	const char *error;

	if ((error = parse_command(line, len, &cmd)) != NULL) {
		reply("%s", error);
		return (true);
	}
	switch (cmd.verb) {
	case VERB_HELO:
	case VERB_EHLO:
		helo(s, &cmd);
		break;
	case VERB_MAIL:
		mail(s, &cmd);
		break;
	case VERB_RCPT:
		rcpt(s, &cmd);
		break;
	case VERB_DATA:
		data(s);
		break;
	case VERB_RSET:
		rset(s);
		break;
	case VERB_NOOP:
		reply("250 Ok");
		break;
	case VERB_QUIT:
		reply("221 Bye");
		return (false);
	}
	return (true);
}

/*
 * Appends the spool to the mailbox after a line that numbers the message
 * and gives the spool's size, which says where the next message starts.
 */
static void
deliver(struct session *s)
{
	char buf[BUFSIZ];
	long size, copied;
	size_t n;

	/* rewind would clear the error of a write to the spool. */
	if (fflush(s->spool) == EOF || ferror(s->spool))
		errx(1, "spool: write error");
	if ((size = ftell(s->spool)) == -1)
		err(1, "spool");
	rewind(s->spool);
	s->queued++;
	fprintf(s->mailbox, "Message %u, %ld bytes\n", s->queued, size);
	copied = 0;
	while ((n = fread(buf, 1, sizeof(buf), s->spool)) > 0) {
		fwrite(buf, 1, n, s->mailbox);
		copied += (long)n;
	}
	/* A record shorter than its size would frame the next one wrong. */
	if (copied != size)
		errx(1, "spool: short read");
	if (fflush(s->mailbox) == EOF || ferror(s->mailbox))
		errx(1, "mailbox: write error");
	reply("250 Ok: queued as %u", s->queued);
}

/* Takes a line of the message text, or the "." that ends it. */
static void
text(struct session *s, const char *line, size_t len)
{
	if (len == 1 && line[0] == '.') {
		if (ftell(s->spool) > MAX_SPOOL)
			reply("552 Message too big");
		else
			deliver(s);
		fclose(s->spool);
		s->state = STATE_GREETED;
		return;
	}
	/* The client doubled a dot that starts a line, RFC 5321 4.5.2. */
	if (line[0] == '.') {
		line++;
		len--;
	}
	/* Past MAX_SPOOL the text is read on to its end and dropped. */
	if (ftell(s->spool) <= MAX_SPOOL) {
		fwrite(line, 1, len, s->spool);
		putc('\n', s->spool);
	}
}

/* Runs the session to QUIT, the end of input or a line it cannot read. */
static void
serve(struct session *s)
{
	char line[MAX_LINE];
	size_t len;

	reply("220 %s ESMTP", HOSTNAME);
	for (;;) {
		switch (read_line(line, sizeof(line), &len)) {
		case LINE_OK:
			break;
		case LINE_EOF:
			return;
		case LINE_TOO_LONG:
			reply("421 Line too long");
			return;
		case LINE_BARE_LF:
			reply("421 Bare LF received");
			return;
		}
		if (s->state == STATE_DATA)
			text(s, line, len);
		else if (!command(s, line, len))
			return;
	}
}

int
main(int argc, char *argv[])
{
	struct session s;

	if (argc != 2) {
		fprintf(stderr, "usage: smtpd mailbox\n");
		return (2);
	}
	s.state = STATE_INIT;
	s.queued = 0;
	if ((s.mailbox = fopen(argv[1], "a")) == NULL)
		err(1, "%s", argv[1]);
	serve(&s);
	/* A session cut off in DATA leaves its spool open. */
	if (s.state == STATE_DATA)
		fclose(s.spool);
	if (fclose(s.mailbox) == EOF)
		err(1, "%s", argv[1]);
	return (0);
}
