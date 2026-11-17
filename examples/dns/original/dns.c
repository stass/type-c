/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * dns: prints a DNS response message read from a file: its header, its
 * questions and its answers, with the data of A, AAAA, CNAME and MX
 * records.  The message comes from the network, so every length and
 * offset in it is checked before it is used.
 *
 * Usage: dns file
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <assert.h>
#include <err.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define	MAX_MESSAGE	65535	/* the largest message, over TCP */
#define	MAX_NAME	255	/* in wire form, RFC 1035, 2.3.4 */

/*
 * A name of MAX_NAME bytes has at most 128 labels, the root included,
 * and needs at most one pointer before each.  A name that follows more
 * pointers runs in a loop, or chains pointers to pointers, which is
 * refused too.
 */
#define	MAX_POINTERS	(MAX_NAME / 2 + 1)

/* A name as text: a byte of a label prints as at most 4 characters. */
#define	NAME_TEXT_SIZE	(4 * MAX_NAME)

#define	LABEL_KIND	0xc0	/* the top bits of a label's first byte */
#define	LABEL_POINTER	0xc0	/* ... of a compression pointer */
#define	LABEL_PLAIN	0x00	/* ... of a label of up to 63 bytes */

#define	TYPE_A		1
#define	TYPE_CNAME	5
#define	TYPE_MX		15
#define	TYPE_AAAA	28
#define	CLASS_IN	1

/* Reads a message from its start to len, one field at a time. */
struct reader {
	const uint8_t	*data;
	size_t		len;
	size_t		off;		/* the next byte; never past len */
};

/* The first error in the message, which ends the reading. */
static struct {
	const char	*what;
	size_t		off;
} parse_error;

/* A name as text: its labels, each followed by a dot. */
struct name {
	char	text[NAME_TEXT_SIZE];
	size_t	len;
};

struct header {
	uint16_t	id;
	uint16_t	flags;
	uint16_t	qdcount;
	uint16_t	ancount;
	uint16_t	nscount;
	uint16_t	arcount;
};

struct question {
	struct name	name;
	uint16_t	type;
	uint16_t	class;
};

/* The data of a record; type says which member of u holds it. */
struct rdata {
	uint16_t	type;
	union {
		const uint8_t	*addr;		/* A: 4 bytes, AAAA: 16 */
		struct name	target;		/* CNAME */
		struct {
			uint16_t	preference;
			struct name	exchange;
		}		mx;
		struct {
			const uint8_t	*data;
			size_t		len;
		}		other;
	} u;
};

struct answer {
	struct name	owner;
	uint16_t	class;
	uint32_t	ttl;
	struct rdata	data;
};

static int
fail(size_t off, const char *what)
{
	parse_error.what = what;
	parse_error.off = off;
	return (-1);
}

static int
read_u8(struct reader *r, uint8_t *v)
{
	if (r->len - r->off < 1)
		return (fail(r->off, "truncated"));
	*v = r->data[r->off];
	r->off += 1;
	return (0);
}

static int
read_u16(struct reader *r, uint16_t *v)
{
	if (r->len - r->off < 2)
		return (fail(r->off, "truncated"));
	*v = (uint16_t)(r->data[r->off] << 8 | r->data[r->off + 1]);
	r->off += 2;
	return (0);
}

static int
read_u32(struct reader *r, uint32_t *v)
{
	uint16_t high, low;

	if (read_u16(r, &high) == -1)
		return (-1);
	if (read_u16(r, &low) == -1)
		return (-1);
	*v = (uint32_t)high << 16 | low;
	return (0);
}

static int
read_bytes(struct reader *r, size_t n, const uint8_t **p)
{
	if (r->len - r->off < n)
		return (fail(r->off, "truncated"));
	*p = r->data + r->off;
	r->off += n;
	return (0);
}

static void
name_put(struct name *n, char c)
{
	/* NAME_TEXT_SIZE holds the text of the longest name. */
	assert(n->len < sizeof(n->text));
	n->text[n->len++] = c;
}

/*
 * Appends a label and its dot.  A byte that a terminal could take for
 * something else, and a dot or backslash inside a label, print as \DDD.
 */
static void
name_append(struct name *n, const uint8_t *label, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		uint8_t c = label[i];

		if (c > ' ' && c < 0x7f && c != '.' && c != '\\') {
			name_put(n, (char)c);
			continue;
		}
		name_put(n, '\\');
		name_put(n, (char)('0' + c / 100));
		name_put(n, (char)('0' + c / 10 % 10));
		name_put(n, (char)('0' + c % 10));
	}
	name_put(n, '.');
}

/*
 * Reads the name at r into n and moves r past it: past its first
 * pointer, or past its last label.  The pointers lead anywhere before
 * the end of r, and are counted so that a loop of them ends.
 */
static int
read_name(struct reader *r, struct name *n)
{
	struct reader at = *r;		/* follows the pointers */
	size_t wire = 0;		/* the length in wire form */
	int pointers = 0;
	bool jumped = false;

	n->len = 0;
	for (;;) {
		size_t start = at.off;
		const uint8_t *label;
		uint8_t len, low;
		size_t target;

		if (read_u8(&at, &len) == -1)
			return (-1);
		if ((len & LABEL_KIND) == LABEL_POINTER) {
			if (read_u8(&at, &low) == -1)
				return (-1);
			if (++pointers > MAX_POINTERS)
				return (fail(start, "compression loop"));
			target = (size_t)(len & ~LABEL_KIND) << 8 | low;
			if (target >= at.len)
				return (fail(start, "pointer past the end"));
			if (!jumped)
				r->off = at.off;
			jumped = true;
			at.off = target;
			continue;
		}
		if ((len & LABEL_KIND) != LABEL_PLAIN)
			return (fail(start, "unknown label type"));
		wire += 1 + len;
		if (wire > MAX_NAME)
			return (fail(start, "name too long"));
		if (len == 0)
			break;
		if (read_bytes(&at, len, &label) == -1)
			return (-1);
		name_append(n, label, len);
	}
	if (!jumped)
		r->off = at.off;
	if (n->len == 0)
		name_put(n, '.');
	return (0);
}

static int
read_header(struct reader *r, struct header *h)
{
	if (read_u16(r, &h->id) == -1)
		return (-1);
	if (read_u16(r, &h->flags) == -1)
		return (-1);
	if (read_u16(r, &h->qdcount) == -1)
		return (-1);
	if (read_u16(r, &h->ancount) == -1)
		return (-1);
	if (read_u16(r, &h->nscount) == -1)
		return (-1);
	if (read_u16(r, &h->arcount) == -1)
		return (-1);
	return (0);
}

static int
read_question(struct reader *r, struct question *q)
{
	if (read_name(r, &q->name) == -1)
		return (-1);
	if (read_u16(r, &q->type) == -1)
		return (-1);
	if (read_u16(r, &q->class) == -1)
		return (-1);
	return (0);
}

/* Reads the data of a record of the given type, which ends where r does. */
static int
read_rdata(struct reader *r, uint16_t type, struct rdata *rd)
{
	rd->type = type;
	switch (type) {
	case TYPE_A:
		return (read_bytes(r, 4, &rd->u.addr));
	case TYPE_AAAA:
		return (read_bytes(r, 16, &rd->u.addr));
	case TYPE_CNAME:
		return (read_name(r, &rd->u.target));
	case TYPE_MX:
		if (read_u16(r, &rd->u.mx.preference) == -1)
			return (-1);
		return (read_name(r, &rd->u.mx.exchange));
	default:
		rd->u.other.len = r->len - r->off;
		return (read_bytes(r, rd->u.other.len, &rd->u.other.data));
	}
}

static int
read_answer(struct reader *r, struct answer *a)
{
	struct reader record;
	uint16_t type, rdlength;
	size_t start, end;

	if (read_name(r, &a->owner) == -1)
		return (-1);
	if (read_u16(r, &type) == -1)
		return (-1);
	if (read_u16(r, &a->class) == -1)
		return (-1);
	if (read_u32(r, &a->ttl) == -1)
		return (-1);
	if (read_u16(r, &rdlength) == -1)
		return (-1);
	start = r->off;
	if (rdlength > r->len - start)
		return (fail(start, "record data past the end"));
	end = start + rdlength;

	/* The data, with the message before it that its names point to. */
	record.data = r->data;
	record.len = end;
	record.off = start;
	if (read_rdata(&record, type, &a->data) == -1)
		return (-1);
	if (record.off != end)
		return (fail(record.off, "record data longer than its type"));
	r->off = end;
	return (0);
}

static void
print_type(uint16_t type)
{
	switch (type) {
	case TYPE_A:
		printf("A");
		break;
	case TYPE_CNAME:
		printf("CNAME");
		break;
	case TYPE_MX:
		printf("MX");
		break;
	case TYPE_AAAA:
		printf("AAAA");
		break;
	default:
		printf("TYPE%u", type);
		break;
	}
}

static void
print_class(uint16_t class)
{
	if (class == CLASS_IN)
		printf("IN");
	else
		printf("CLASS%u", class);
}

static void
print_name(const struct name *n)
{
	printf("%.*s", (int)n->len, n->text);
}

static void
print_address(int family, const uint8_t *addr)
{
	char text[INET6_ADDRSTRLEN];

	if (inet_ntop(family, addr, text, sizeof(text)) == NULL)
		err(1, "inet_ntop");
	printf("%s", text);
}

/* Prints the data of a record of a type it does not know, as RFC 3597. */
static void
print_unknown(const uint8_t *data, size_t len)
{
	size_t i;

	printf("\\# %zu", len);
	if (len > 0)
		printf(" ");
	for (i = 0; i < len; i++)
		printf("%02x", data[i]);
}

static void
print_rdata(const struct rdata *rd)
{
	switch (rd->type) {
	case TYPE_A:
		printf("A ");
		print_address(AF_INET, rd->u.addr);
		break;
	case TYPE_AAAA:
		printf("AAAA ");
		print_address(AF_INET6, rd->u.addr);
		break;
	case TYPE_CNAME:
		printf("CNAME ");
		print_name(&rd->u.target);
		break;
	case TYPE_MX:
		printf("MX %u ", rd->u.mx.preference);
		print_name(&rd->u.mx.exchange);
		break;
	default:
		print_type(rd->type);
		printf(" ");
		print_unknown(rd->u.other.data, rd->u.other.len);
		break;
	}
}

static void
print_header(const struct header *h)
{
	printf("header id %u flags 0x%04x", h->id, h->flags);
	printf(" questions %u answers %u", h->qdcount, h->ancount);
	printf(" authority %u additional %u\n", h->nscount, h->arcount);
}

static void
print_question(const struct question *q)
{
	printf("question ");
	print_name(&q->name);
	printf(" ");
	print_class(q->class);
	printf(" ");
	print_type(q->type);
	printf("\n");
}

static void
print_answer(const struct answer *a)
{
	printf("answer ");
	print_name(&a->owner);
	printf(" %lu ", (unsigned long)a->ttl);
	print_class(a->class);
	printf(" ");
	print_rdata(&a->data);
	printf("\n");
}

/* Prints the header, questions and answers, up to the first error. */
static int
print_message(struct reader *r)
{
	struct header h;
	struct question q;
	struct answer a;
	unsigned i;

	if (read_header(r, &h) == -1)
		return (-1);
	print_header(&h);
	for (i = 0; i < h.qdcount; i++) {
		if (read_question(r, &q) == -1)
			return (-1);
		print_question(&q);
	}
	for (i = 0; i < h.ancount; i++) {
		if (read_answer(r, &a) == -1)
			return (-1);
		print_answer(&a);
	}
	return (0);
}

/* Reads a file whole, into memory of exactly its size. */
static uint8_t *
read_file(const char *path, size_t *lenp)
{
	struct stat st;
	uint8_t *data;
	FILE *fp;
	size_t len;

	if ((fp = fopen(path, "rb")) == NULL)
		err(1, "%s", path);
	if (fstat(fileno(fp), &st) == -1)
		err(1, "%s", path);
	if (!S_ISREG(st.st_mode))
		errx(1, "%s: not a regular file", path);
	if (st.st_size > MAX_MESSAGE)
		errx(1, "%s: larger than a DNS message", path);
	len = (size_t)st.st_size;
	/* malloc(0) may return NULL, which is not a failure. */
	if ((data = malloc(len > 0 ? len : 1)) == NULL)
		err(1, "malloc");
	if (fread(data, 1, len, fp) != len)
		errx(1, "%s: short read", path);
	fclose(fp);
	*lenp = len;
	return (data);
}

int
main(int argc, char *argv[])
{
	struct reader r;
	uint8_t *data;
	size_t len;
	int status;

	if (argc != 2) {
		fprintf(stderr, "usage: dns file\n");
		return (2);
	}
	data = read_file(argv[1], &len);
	r.data = data;
	r.len = len;
	r.off = 0;
	status = print_message(&r);
	free(data);
	if (status == -1) {
		fflush(stdout);
		errx(1, "%s: %s at offset %zu", argv[1], parse_error.what,
		    parse_error.off);
	}
	return (0);
}
