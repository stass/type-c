# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the Type-C port, dns, and the C it ports, original/dns, with
# typec as the C compiler and the rule of README.md, "In a build", for
# the .tc file; typec hands original/dns.c to the C compiler untouched.
# "make check" runs both over the messages of tests/ and compares them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

all: dns original/dns

dns: dns.o
	$(LINK.o) $^ $(LDLIBS) -o $@

%.o: %.tc
	$(COMPILE.c) $(OUTPUT_OPTION) $<

original/dns: original/dns.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f dns dns.o dns.d original/dns original/dns.o original/dns.d

.PHONY: all check clean

-include dns.d original/dns.d
