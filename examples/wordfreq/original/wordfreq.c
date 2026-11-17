/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 *
 * wordfreq: count the words of the standard input and print the most
 * frequent ones, with klib's khash.h as the table.  A word is a run of
 * ASCII letters, folded to lower case.
 */

#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "khash.h"

/* The table of words to counts, with khash's hash for C strings. */
KHASH_MAP_INIT_STR(word, int)

/* A word and its count, as print_top sorts them. */
struct count {
	const char *word;
	int count;
};

static void usage(void);

static void
count_word(khash_t(word) *h, const char *word)
{
	khint_t k;
	char *key;
	int ret;

	k = kh_get(word, h, word);
	if (k != kh_end(h)) {
		kh_val(h, k)++;
		return;
	}
	if ((key = strdup(word)) == NULL)
		err(1, "strdup");
	k = kh_put(word, h, key, &ret);
	if (ret < 0)
		errx(1, "out of memory");
	kh_val(h, k) = 1;
}

static void
count_line(khash_t(word) *h, char *line, size_t len)
{
	size_t i, start;
	char end;

	i = 0;
	while (i < len) {
		if (!isalpha((unsigned char)line[i])) {
			i++;
			continue;
		}
		start = i;
		while (i < len && isalpha((unsigned char)line[i])) {
			line[i] = (char)tolower((unsigned char)line[i]);
			i++;
		}
		/*
		 * A key of the table is a C string, so the word ends in a
		 * NUL for the lookup; getline leaves one after the line.
		 */
		end = line[i];
		line[i] = '\0';
		count_word(h, line + start);
		line[i] = end;
	}
}

static void
count_file(khash_t(word) *h, FILE *fp)
{
	char *line = NULL;
	size_t size = 0;
	ssize_t len;

	while ((len = getline(&line, &size, fp)) >= 0)
		count_line(h, line, (size_t)len);
	if (ferror(fp))
		err(1, "stdin");
	free(line);
}

/* The most frequent word first, and words of one count in order. */
static int
compare_counts(const void *a, const void *b)
{
	const struct count *x = a, *y = b;

	if (x->count != y->count)
		return (x->count > y->count ? -1 : 1);
	return (strcmp(x->word, y->word));
}

static void
print_top(khash_t(word) *h, size_t top)
{
	struct count *counts;
	size_t i, n;
	khint_t k;

	if (kh_size(h) == 0)
		return;
	if ((counts = calloc(kh_size(h), sizeof(*counts))) == NULL)
		err(1, "calloc");
	n = 0;
	for (k = kh_begin(h); k != kh_end(h); k++) {
		if (!kh_exist(h, k))
			continue;
		counts[n].word = kh_key(h, k);
		counts[n].count = kh_val(h, k);
		n++;
	}
	qsort(counts, n, sizeof(*counts), compare_counts);
	if (top > n)
		top = n;
	for (i = 0; i < top; i++)
		printf("%7d %s\n", counts[i].count, counts[i].word);
	free(counts);
}

static void
free_words(khash_t(word) *h)
{
	khint_t k;

	for (k = kh_begin(h); k != kh_end(h); k++)
		if (kh_exist(h, k))
			free((char *)kh_key(h, k));
	kh_destroy(word, h);
}

int
main(int argc, char *argv[])
{
	khash_t(word) *h;
	char *end;
	long top;
	int ch;

	top = 10;
	while ((ch = getopt(argc, argv, "n:")) != -1)
		switch (ch) {
		case 'n':
			errno = 0;
			top = strtol(optarg, &end, 10);
			if (*optarg == '\0' || *end != '\0' || top < 0 ||
			    errno != 0)
				errx(1, "%s: invalid count", optarg);
			break;
		default:
			usage();
		}
	if (argc != optind)
		usage();

	if ((h = kh_init(word)) == NULL)
		errx(1, "out of memory");
	count_file(h, stdin);
	print_top(h, (size_t)top);
	free_words(h);
	if (fflush(stdout) != 0)
		err(1, "stdout");
	return (0);
}

static void
usage(void)
{
	(void)fprintf(stderr, "usage: wordfreq [-n count]\n");
	exit(1);
}
