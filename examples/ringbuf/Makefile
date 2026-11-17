# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Builds the firmware core twice, from firmware.tc and from
# original/firmware.c, as freestanding objects with typec as the C
# compiler, and links each with the hosted board of driver.c into
# driver and original/driver. stray shows a trap of the port calling
# panic. "make check" checks the objects' undefined symbols, then runs
# both drivers over the same inputs and compares them.

CC = typec
CFLAGS = -O2 -Wall -Wextra -Werror
CPPFLAGS = -MMD -MP

# The flags of an object that links with no C library. A host may turn
# on the stack protector by default, whose __stack_chk_fail a firmware
# would supply itself; this one goes without.
FREESTANDING = -ffreestanding -nostdlib -fno-builtin -fno-stack-protector

# A trap of the port calls panic, which the board supplies.
TRAP = --trap-function=panic

all: driver original/driver stray

# OBJFLAGS adds an object's own flags to CFLAGS, which a command line
# may override.
%.o: %.tc
	$(COMPILE.c) $(OBJFLAGS) $(OUTPUT_OPTION) $<

%.o: %.c
	$(COMPILE.c) $(OBJFLAGS) $(OUTPUT_OPTION) $<

firmware.o: OBJFLAGS = $(FREESTANDING) $(TRAP)
original/firmware.o: OBJFLAGS = $(FREESTANDING)
stray.o: OBJFLAGS = $(TRAP)

driver: driver.o firmware.o
	$(LINK.o) $^ $(LDLIBS) -o $@

original/driver: driver.o original/firmware.o
	$(LINK.o) $^ $(LDLIBS) -o $@

stray: stray.o
	$(LINK.o) $^ $(LDLIBS) -o $@

check: all
	sh ./check.sh

clean:
	rm -f driver driver.o driver.d firmware.o firmware.d stray stray.o \
	    stray.d original/driver original/firmware.o original/firmware.d

.PHONY: all check clean

-include driver.d firmware.d stray.d original/firmware.d
