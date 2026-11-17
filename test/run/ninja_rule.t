SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The build.ninja of README.md ("In a build") builds the calc example with
typec, on each backend. ninja reads the dependency file of each object
(deps = gcc), rebuilds what a changed file reaches, and does nothing
when no file changed (calc_example.sh says how calc.tc includes
command.tci). ninja runs independent commands in any order, so they are
sorted, without the progress counts.

  $ . ./backends.sh
  $ . ./calc_example.sh
  $ build() { ninja | sed 's/^\[[0-9]*\/[0-9]*\] //' | LC_ALL=C sort; }

Each file that the build reads or writes gets one old time, so that a
file touched later is newer than every output however coarse the
clock of the file system.

  $ age() { touch -t 200001010000 *.c *.h *.tc *.tci *.o calc; }
  $ rebuilds() {
  >   build && ./calc && age && echo "nothing changed" && build &&
  >   for file in command.tci calc.h main.c; do
  >     echo "touched $file" && touch "$file" && build && age || return
  >   done
  > }

  $ calc_directory clang build.ninja && export TYPEC_CC=$clang
  $ rebuilds
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  unknown: mul 3
  -3
  nothing changed
  ninja: no work to do.
  touched command.tci
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec main.o calc.o -o calc
  touched calc.h
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  touched main.c
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  $ ninja -t deps calc.o | sed -n 's/^    //p'
  calc.tc
  calc.h
  command.tci

  $ cd .. && calc_directory gcc build.ninja && export TYPEC_CC=$gcc
  $ rebuilds
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  unknown: mul 3
  -3
  nothing changed
  ninja: no work to do.
  touched command.tci
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec main.o calc.o -o calc
  touched calc.h
  typec -Wall -Wextra -MMD -MF calc.o.d -c calc.tc -o calc.o
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  touched main.c
  typec -Wall -Wextra -MMD -MF main.o.d -c main.c -o main.o
  typec main.o calc.o -o calc
  $ ninja -t deps calc.o | sed -n 's/^    //p'
  calc.tc
  calc.h
  command.tci
