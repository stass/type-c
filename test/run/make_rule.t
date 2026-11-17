SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The Makefile of README.md ("In a build") builds the calc example with
typec as the C compiler, on each backend. The dependency files that it
asks for make make rebuild what a changed file reaches, and nothing
when no file changed (calc_example.sh says how calc.tc includes
command.tci). GNU make is gmake where make is another, as on FreeBSD.

  $ . ./backends.sh
  $ . ./calc_example.sh
  $ make=$(command -v gmake || command -v make)

Each file that the build reads or writes gets one old time, so that a
file touched later is newer than every output however coarse the
clock of the file system.

  $ age() { touch -t 200001010000 *.c *.h *.tc *.tci *.o calc; }
  $ rebuilds() {
  >   "$make" && ./calc && age &&
  >   "$make" -q && echo "nothing changed: up to date" &&
  >   for file in command.tci calc.h main.c; do
  >     echo "touched $file" && touch "$file" && "$make" && age || return
  >   done
  > }

  $ calc_directory clang Makefile && export TYPEC_CC=$clang
  $ rebuilds
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  unknown: mul 3
  -3
  nothing changed: up to date
  touched command.tci
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  touched calc.h
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  touched main.c
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec   main.o calc.o  -o calc
  $ cat calc.d
  calc.o: calc.tc calc.h command.tci
  calc.h:
  command.tci:

  $ cd .. && calc_directory gcc Makefile && export TYPEC_CC=$gcc
  $ rebuilds
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  unknown: mul 3
  -3
  nothing changed: up to date
  touched command.tci
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  touched calc.h
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec -Wall -Wextra -MMD -MP  -c -o calc.o calc.tc
  typec   main.o calc.o  -o calc
  touched main.c
  typec -Wall -Wextra -MMD -MP  -c -o main.o main.c
  typec   main.o calc.o  -o calc
  $ cat calc.d
  calc.o: calc.tc calc.h command.tci
  calc.h:
  command.tci:
