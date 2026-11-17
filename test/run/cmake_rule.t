SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The CMakeLists.txt and typec.cmake of README.md ("In a build") build
the calc example with typec as the C compiler, on each backend, with
the Ninja generator. ninja reads the dependency file of each object,
rebuilds what a changed file reaches, and does nothing when no file
changed. calc.tc includes command.tci (calc_example.sh), whose Type-C
declaration fails a rule that compiles calc.tc as C, as the LANGUAGE
property would. ninja runs independent commands in any order, so they
are sorted, without the progress counts.

  $ . ./backends.sh
  $ . ./calc_example.sh
  $ cmake_directory() {
  >   calc_directory "$1" CMakeLists.txt typec.cmake && touch stamp &&
  >   cmake -G Ninja -DCMAKE_C_COMPILER=typec -B build > /dev/null
  > }
  $ build() {
  >   cmake --build build | sed 's/^\[[0-9]*\/[0-9]*\] //' | LC_ALL=C sort
  > }

The sources and the outputs of the build get the time of stamp, made
before CMake configures and builds, so that a file touched after the
build is newer than every output. An older
time would not do: CMake asks for the dependencies on system headers
too (-MD), which would then be newer than the outputs. The files of
CMake keep their times, as build.ninja is remade when it is older than
the modules of CMake.

  $ age() {
  >   touch -r stamp *.c *.h *.tc *.tci build/calc \
  >     build/CMakeFiles/calc.dir/*.o
  > }
  $ rebuilds() {
  >   build && build/calc && age && echo "nothing changed" && build &&
  >   for file in command.tci calc.h main.c; do
  >     echo "touched $file" && touch "$file" && build && age || return
  >   done
  > }

  $ cmake_directory clang && export TYPEC_CC=$clang
  $ rebuilds
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc
  unknown: mul 3
  -3
  nothing changed
  ninja: no work to do.
  touched command.tci
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Linking C executable calc
  touched calc.h
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc
  touched main.c
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc

  $ cd .. && cmake_directory gcc && export TYPEC_CC=$gcc
  $ rebuilds
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc
  unknown: mul 3
  -3
  nothing changed
  ninja: no work to do.
  touched command.tci
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Linking C executable calc
  touched calc.h
  Building C object CMakeFiles/calc.dir/calc.tc.o
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc
  touched main.c
  Building C object CMakeFiles/calc.dir/main.c.o
  Linking C executable calc
