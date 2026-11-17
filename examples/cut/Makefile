# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C port, cut, and FreeBSD's original, original/cut, with
# typec as the C compiler and the rule of README.md, "In a build", for
# the .tc file; typec hands original/cut.c to the C compiler untouched.
# "make check" runs both over the same inputs and compares them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

all: cut original/cut

cut: cut.o
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

# compat.h supplies the names of the BSD C library that glibc lacks and
# that both files use.
cut.o original/cut.o: CPPFLAGS += -include original/compat.h

original/cut: original/cut.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f cut cut.o cut.d original/cut original/cut.o original/cut.d

.PHONY: all check clean

-include cut.d original/cut.d
