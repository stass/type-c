# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C version, sched, and the C original, original/sched,
# with typec as the C compiler and the rule of README.md, "In a build",
# for the .tc file; typec hands original/sched.c to the C compiler
# untouched. "make check" runs both over the same inputs and compares
# them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

all: sched original/sched

sched: sched.o
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

# compat/sys/cdefs.h stands in for the header that musl lacks.
original/sched.o: CPPFLAGS += -idirafter original/compat

original/sched: original/sched.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f sched sched.o sched.d original/sched original/sched.o \
	    original/sched.d

.PHONY: all check clean

-include sched.d original/sched.d
