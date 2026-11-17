/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * sched: a round-robin job scheduler, simulated. It reads commands from
 * the standard input, one to a line:
 *
 *	add NAME WORK		queue a job of WORK units of work
 *	urgent NAME WORK	the same, at the head of the queue
 *	run QUANTUM		run each queued job for up to QUANTUM units
 *	kill NAME		take a queued job off the queue
 *	ps			list every job in the order added
 *
 * A bad command is reported and skipped, and makes the exit status 1.
 */

#include <err.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "queue.h"

#define	NAME_MAX_LEN	15	/* the longest name of a job */
#define	COUNT_MAX	1000000	/* the most units of work or of a quantum */
#define	MAX_WORDS	3	/* the most words of a command */

enum state { READY, DONE, KILLED };

static const char *const state_names[] = { "ready", "done", "killed" };

struct job {
	char		 name[NAME_MAX_LEN + 1];
	unsigned	 left;		/* the units of work still to run */
	enum state	 state;
	TAILQ_ENTRY(job) all_link;	/* on all, until the exit */
	TAILQ_ENTRY(job) ready_link;	/* on ready while READY */
};

TAILQ_HEAD(job_list, job);

struct scheduler {
	struct job_list	all;	/* every job, in the order added */
	struct job_list	ready;	/* the READY jobs, in the order they run */
};

/* Reads a count of 1 to COUNT_MAX, in decimal digits alone. */
static bool
parse_count(const char *word, unsigned *count)
{
	unsigned value = 0;

	if (*word == '\0')
		return (false);
	for (; *word != '\0'; word++) {
		if (*word < '0' || *word > '9')
			return (false);
		value = value * 10 + (unsigned)(*word - '0');
		if (value > COUNT_MAX)
			return (false);
	}
	if (value == 0)
		return (false);
	*count = value;
	return (true);
}

static struct job *
find_job(struct scheduler *s, const char *name)
{
	struct job *j;

	TAILQ_FOREACH(j, &s->all, all_link)
		if (strcmp(j->name, name) == 0)
			return (j);
	return (NULL);
}

/* add NAME WORK, or urgent NAME WORK when urgent is set. */
static bool
add_job(struct scheduler *s, char **words, int nwords, bool urgent)
{
	struct job *j;
	unsigned work;

	if (nwords != 3) {
		warnx("usage: %s NAME WORK", words[0]);
		return (false);
	}
	if (strlen(words[1]) > NAME_MAX_LEN) {
		warnx("%s: name too long: %s", words[0], words[1]);
		return (false);
	}
	if (find_job(s, words[1]) != NULL) {
		warnx("%s: job %s exists", words[0], words[1]);
		return (false);
	}
	if (!parse_count(words[2], &work)) {
		warnx("%s: bad work: %s", words[0], words[2]);
		return (false);
	}
	if ((j = malloc(sizeof(*j))) == NULL)
		err(1, "malloc");
	strcpy(j->name, words[1]);
	j->left = work;
	j->state = READY;
	TAILQ_INSERT_TAIL(&s->all, j, all_link);
	if (urgent)
		TAILQ_INSERT_HEAD(&s->ready, j, ready_link);
	else
		TAILQ_INSERT_TAIL(&s->ready, j, ready_link);
	return (true);
}

/* run QUANTUM: one round of the queue, in order. */
static bool
run_jobs(struct scheduler *s, char **words, int nwords)
{
	struct job *j, *next;
	unsigned quantum, ran;

	if (nwords != 2) {
		warnx("usage: run QUANTUM");
		return (false);
	}
	if (!parse_count(words[1], &quantum)) {
		warnx("run: bad quantum: %s", words[1]);
		return (false);
	}
	TAILQ_FOREACH_SAFE(j, &s->ready, ready_link, next) {
		ran = quantum;
		if (ran > j->left)
			ran = j->left;
		j->left -= ran;
		if (j->left > 0) {
			printf("%s: ran %u, %u left\n", j->name, ran, j->left);
			continue;
		}
		printf("%s: ran %u, done\n", j->name, ran);
		j->state = DONE;
		TAILQ_REMOVE(&s->ready, j, ready_link);
	}
	return (true);
}

/* kill NAME */
static bool
kill_job(struct scheduler *s, char **words, int nwords)
{
	struct job *j;

	if (nwords != 2) {
		warnx("usage: kill NAME");
		return (false);
	}
	if ((j = find_job(s, words[1])) == NULL) {
		warnx("kill: no job %s", words[1]);
		return (false);
	}
	if (j->state != READY) {
		warnx("kill: job %s is %s", j->name, state_names[j->state]);
		return (false);
	}
	j->state = KILLED;
	TAILQ_REMOVE(&s->ready, j, ready_link);
	return (true);
}

/* ps */
static bool
list_jobs(struct scheduler *s, char **words, int nwords)
{
	struct job *j;

	if (nwords != 1) {
		warnx("usage: %s", words[0]);
		return (false);
	}
	TAILQ_FOREACH(j, &s->all, all_link)
		printf("%s %u %s\n", j->name, j->left, state_names[j->state]);
	return (true);
}

static bool
run_command(struct scheduler *s, char **words, int nwords)
{
	if (strcmp(words[0], "add") == 0)
		return (add_job(s, words, nwords, false));
	if (strcmp(words[0], "urgent") == 0)
		return (add_job(s, words, nwords, true));
	if (strcmp(words[0], "run") == 0)
		return (run_jobs(s, words, nwords));
	if (strcmp(words[0], "kill") == 0)
		return (kill_job(s, words, nwords));
	if (strcmp(words[0], "ps") == 0)
		return (list_jobs(s, words, nwords));
	warnx("unknown command: %s", words[0]);
	return (false);
}

/*
 * Splits line into its words, at most MAX_WORDS + 1 of them so that a
 * command with too many words is seen, and returns their count.
 */
static int
split(char *line, char **words)
{
	int nwords = 0;
	char *word;

	for (word = strtok(line, " \t\n"); word != NULL;
	    word = strtok(NULL, " \t\n")) {
		words[nwords++] = word;
		if (nwords == MAX_WORDS + 1)
			break;
	}
	return (nwords);
}

static void
free_jobs(struct scheduler *s)
{
	struct job *j, *next;

	TAILQ_FOREACH_SAFE(j, &s->all, all_link, next)
		free(j);
}

int
main(void)
{
	struct scheduler s;
	char *words[MAX_WORDS + 1];
	char *line = NULL;
	size_t size = 0;
	int nwords, status = 0;

	TAILQ_INIT(&s.all);
	TAILQ_INIT(&s.ready);
	while (getline(&line, &size, stdin) >= 0) {
		nwords = split(line, words);
		if (nwords == 0)
			continue;
		if (!run_command(&s, words, nwords))
			status = 1;
	}
	if (ferror(stdin))
		err(1, "stdin");
	free(line);
	free_jobs(&s);
	return (status);
}
