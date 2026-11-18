# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C port, xargs, and FreeBSD's original, original/xargs,
# with typec as the C compiler and the rule of README.md, "In a build",
# for the .tc files; typec hands the .c files to the C compiler untouched.
# "make check" runs both over the same inputs and compares them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

PORT_OBJS = xargs.o strnsubst.o
ORIGINAL_OBJS = original/xargs.o original/strnsubst.o

all: xargs original/xargs

xargs: $(PORT_OBJS)
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

# compat.h supplies what glibc lacks: strtonum(3), and the uintptr_t
# that strnsubst.c expects from <unistd.h>; pathnames.h is upstream's,
# beside xargs.c.
$(PORT_OBJS) $(ORIGINAL_OBJS): CPPFLAGS += -include original/compat.h \
    -I original

# xargs.c includes FreeBSD's <sys/limits.h>, which compat/ stands in for
# elsewhere.  macOS declares vfork(2) deprecated.  The original compares
# an int with an rlim_t, and GCC takes its "case -1" of vfork, which ends
# in xexit, a function not declared to return never, to fall through.
# The flags are added with override, so that a CFLAGS on the command
# line keeps them.
ifneq ($(shell uname -s),FreeBSD)
$(ORIGINAL_OBJS): CPPFLAGS += -I original/compat
endif
$(PORT_OBJS) $(ORIGINAL_OBJS): \
    override CFLAGS += -Wno-deprecated-declarations
$(ORIGINAL_OBJS): \
    override CFLAGS += -Wno-sign-compare -Wno-implicit-fallthrough

original/xargs: $(ORIGINAL_OBJS)
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f xargs $(PORT_OBJS) $(PORT_OBJS:.o=.d) original/xargs \
	    $(ORIGINAL_OBJS) $(ORIGINAL_OBJS:.o=.d)

.PHONY: all check clean

-include $(PORT_OBJS:.o=.d) $(ORIGINAL_OBJS:.o=.d)
