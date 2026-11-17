# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C program, wordfreq, and the C original,
# original/wordfreq, with typec as the C compiler and the rule of
# README.md, "In a build", for the .tc file; typec hands
# original/wordfreq.c to the C compiler untouched.  "make check" runs
# both over the same texts and compares them; "make bench" times them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

all: wordfreq original/wordfreq

wordfreq: wordfreq.o
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

original/wordfreq: original/wordfreq.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

bench: all
	sh ./bench.sh

clean:
	rm -f wordfreq wordfreq.o wordfreq.d
	rm -f original/wordfreq original/wordfreq.o original/wordfreq.d

.PHONY: all bench check clean

-include wordfreq.d original/wordfreq.d
