# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C port, smtpd, and the C it ports, original/smtpd, with
# typec as the C compiler and the rule of README.md, "In a build", for
# the .tc file; typec hands original/smtpd.c to the C compiler untouched.
# "make check" runs both over the sessions of check.sh and compares them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

all: smtpd original/smtpd

smtpd: smtpd.o
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

original/smtpd: original/smtpd.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f smtpd smtpd.o smtpd.d \
	    original/smtpd original/smtpd.o original/smtpd.d

.PHONY: all check clean

-include smtpd.d original/smtpd.d
