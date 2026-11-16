#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Stage 1 exit gate 4, size and speed: builds each Type-C program in
# tools/measure/gate4 and its hand-written C twin at -O2 with each
# backend, checks that the two print the same, and writes the code size
# of both and the instructions and cycles each run takes to
# OUT/results.md.
#
# Usage: tools/measure/gate4.sh OUT
#
# OUT holds the objects, the lowered C and the counts beside the
# results; it is outside the repository because they are raw data.
# TYPEC names the compiler (by default the one dune builds in this
# tree), TYPEC_TEST_CLANG and TYPEC_TEST_GCC the backends as for the
# tests, RUNS the counted runs of each program (default 5, at least 3),
# REVISION the revision of the tree (by default what
# tools/corpus/revision.sh prints for it; a copy of the tree without its
# git directory names it, as that script prints it where the copy was
# made). The script runs on FreeBSD, whose hwpmc counts the instructions
# and cycles of one process (pmcstat), with a libpmc that honors the usr
# qualifier of a pmu event, and needs size; the code size is the bytes
# of the .text* sections of each ELF object.

set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/gate4
[ $# -eq 1 ] || { echo "usage: $0 OUT" >&2; exit 2; }
out=$1
runs=${RUNS:-5}
# Both sides of a pair are built as C11, the dialect typec gives a .tc
# input, rather than in each backend's own default.
flags="-std=gnu11 -O2 -Wall -Wextra -Werror"
# Above this share of the count of the C twin the spread of the
# instruction counts is too large for a verdict: the counter is seeing
# more than the program.
inconclusive_percent=1

fail() {
  echo "gate4.sh: $*" >&2
  exit 1
}

# A spread needs a few runs to estimate the noise from.
case $runs in
'' | *[!0-9]*) fail "RUNS is not a number: $runs" ;;
esac
[ "$runs" -ge 3 ] || fail "RUNS is $runs, and a spread needs at least 3"

command -v pmcstat > /dev/null || fail "needs pmcstat (FreeBSD hwpmc)"
command -v size > /dev/null || fail "needs size"

if [ -n "${REVISION:-}" ]; then
  revision=$REVISION
else
  revision=$("$root/tools/corpus/revision.sh" "$root") ||
    fail "cannot tell the revision of $root; name it in REVISION"
fi

. "$root/test/run/backends.sh"

if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi

# The command-line arguments of each program, sized for a run of a few
# tenths of a second, and the last one a seed.
arguments_of() {
  case $1 in
  tree) echo "65536 400 1" ;;
  shapes) echo "10000 10000 1" ;;
  ids) echo "1048576 8000000 1" ;;
  nodes) echo "100000 100 1" ;;
  *) fail "no arguments for $1" ;;
  esac
}

# The bytes of machine code in an object: the sum of its code sections,
# which GCC splits into several (.text, .text.startup, .text.unlikely),
# from the table of sections that size -A prints (elftoolchain, GNU and
# LLVM size print the same). Strings and unwind tables are left out;
# the padding that aligns each function is counted.
code_bytes() {
  sections=$(size -A "$1") || fail "cannot size $1"
  printf '%s\n' "$sections" |
    awk '$1 ~ /^\.text(\..*)?$/ { sum += $2; found = 1 }
      END { if (!found) exit 1; print sum }' ||
    fail "no code section in $1"
}

# Compiles one program of the pair to an object, sizes it and links it;
# for a .tc source it also keeps the lowered C beside the object.
# $1 is the backend, $2 the source, $3 the name of the result.
build() {
  case $2 in
  *.tc)
    "$TYPEC" --cc="$1" --emit-c -o "$3.lowered.c" "$2"
    "$TYPEC" --cc="$1" $flags -c -o "$3.o" "$2"
    ;;
  *) "$1" $flags -c -o "$3.o" "$2" ;;
  esac
  "$1" -o "$3" "$3.o"
  code_bytes "$3.o" > "$3.size"
}

# Runs a program once under pmcstat in process mode and appends the
# instructions it retired and the core cycles it took in user mode, in
# that order, to a file of counts. The two events are the hwpmc aliases
# of the CPU's own, and pmcstat prints their counts in the order they
# are given, under a line that names them. $1 is the program, $2 the
# file of counts, the rest the arguments of the program. Every program
# runs from one path, a copy of it: the length of the path a program is
# run by moves the instructions its startup retires by tens, which
# would set apart twins of the same code.
count() {
  counted=$1 counts=$2
  shift 2
  cp -f "$counted" "$out/work/counted"
  # Without this, a pmcstat that wrote nothing would leave the counts of
  # the run before for awk to read.
  rm -f "$counts.run"
  pmcstat -o "$counts.run" -p instructions,usr -p unhalted-cycles,usr \
    "$out/work/counted" "$@" > /dev/null
  awk 'NR == 1 && !/p\/instructions +p\/unhalted-cycles/ { exit 1 }
    NR == 2 && NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      print $1, $2; found = 1
    }
    END { if (!found) exit 1 }' "$counts.run" >> "$counts" ||
    fail "pmcstat printed no counts for $counted in $counts.run"
}

# Fails unless pmcstat counts user mode alone under the usr qualifier.
# A libpmc without pmu_parse_qualifiers ignores it silently and counts
# kernel mode too, whose interrupts and page faults move a count by more
# than the differences the gate looks for. The check counts a dd that
# retires most of its instructions in the kernel (four in five on Zen
# 3), so under the qualifier it must retire less than half as many.
# Checking one event is enough: libpmc reads the qualifiers of every
# pmu event in one place.
check_user_mode() {
  probe=$out/work/user-mode.run
  rm -f "$probe"
  pmcstat -o "$probe" -p instructions,usr -p instructions \
    dd if=/dev/zero of=/dev/null bs=1 count=10000 status=none
  awk 'NR == 1 && !/p\/instructions +p\/instructions/ { exit 1 }
    NR == 2 && NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
      $1 > 0 && 2 * $1 < $2 { found = 1 }
    END { if (!found) exit 1 }' "$probe" ||
    fail "pmcstat counts kernel mode under the usr qualifier, or" \
      "printed no counts in $probe; docs/development.md, \"Measuring against" \
      "hand-written C\", says how to get a libpmc that honors it"
}

# Checks that the twins print the same, then counts RUNS runs of each,
# alternating the twins so that a change of load during the batch moves
# the cycles of both alike.
measure() {
  arguments=$(arguments_of "$2")
  "$1-tc" $arguments > "$1-tc.out"
  "$1-c" $arguments > "$1-c.out"
  cmp -s "$1-tc.out" "$1-c.out" || fail "$1: the twins differ in output"
  rm -f "$1-c.counts" "$1-tc.counts"
  run=0
  while [ "$run" -lt "$runs" ]; do
    count "$1-c" "$1-c.counts" $arguments
    count "$1-tc" "$1-tc.counts" $arguments
    run=$((run + 1))
  done
}

# The median of one column of a file of counts and its spread, the
# largest count less the smallest. The median of an even number of runs
# is the upper middle one. $1 is the file, $2 the column.
statistics() {
  awk -v column="$2" '{ print $column }' "$1" | sort -n |
    awk '{ value[NR] = $1 }
      END { if (NR > 0) print value[int(NR / 2) + 1], value[NR] - value[1] }'
}

# One row of the table: sizes, counts and both verdicts, drawn as the
# header of results.md defines them.
row() {
  size_tc=$(cat "$1-tc.size")
  size_c=$(cat "$1-c.size")
  instructions_tc=$(statistics "$1-tc.counts" 1)
  instructions_c=$(statistics "$1-c.counts" 1)
  cycles_tc=$(statistics "$1-tc.counts" 2)
  cycles_c=$(statistics "$1-c.counts" 2)
  [ -n "$instructions_tc" ] && [ -n "$instructions_c" ] ||
    fail "$1 has no counts"
  awk -v program="$2" -v backend="$3" -v size_tc="$size_tc" \
    -v size_c="$size_c" -v instructions_tc="$instructions_tc" \
    -v instructions_c="$instructions_c" -v cycles_tc="$cycles_tc" \
    -v cycles_c="$cycles_c" -v inconclusive_percent="$inconclusive_percent" '
    function abs(x) { return x < 0 ? -x : x }
    function max(a, b) { return a > b ? a : b }
    function judge_speed() {
      if (100 * noise > inconclusive_percent * reference)
        return "inconclusive"
      if (abs(delta) <= noise)
        return "within"
      return "outside"
    }
    BEGIN {
      split(instructions_tc, typec); split(instructions_c, twin)
      split(cycles_tc, typec_cycles); split(cycles_c, twin_cycles)
      reference = twin[1]
      noise = max(typec[2], twin[2])
      delta = typec[1] - reference
      cycles_delta = typec_cycles[1] - twin_cycles[1]
      size_verdict = size_tc == size_c ? "equal" : "differs"
      speed_verdict = judge_speed()
      printf "| %s | %s | %d | %d | %+d | %s |", \
        program, backend, size_tc, size_c, size_tc - size_c, size_verdict
      printf " %.0f (%.0f) | %.0f (%.0f) | %+.0f (%+.3f%%) | %.0f | %s |", \
        typec[1], typec[2], twin[1], twin[2], \
        delta, 100 * delta / reference, noise, speed_verdict
      printf " %.0f (%.0f) | %.0f (%.0f) | %+.1f%% |\n", \
        typec_cycles[1], typec_cycles[2], twin_cycles[1], twin_cycles[2], \
        100 * cycles_delta / twin_cycles[1]
    }'
}

header() {
  cat <<EOF
# Stage 1 exit gate 4: size and speed against hand-written C

Written by tools/measure/gate4.sh at
$revision on $(date -u +%Y-%m-%dT%H:%MZ),
$(uname -m),
$(sysctl -n hw.model | sed "s/ *$//").

* clang: $("$clang" --version | head -n 1)
* gcc: $("$gcc" --version | head -n 1)
* flags: $flags
* counting: pmcstat in process mode, the hwpmc events instructions and
  unhalted-cycles in user mode, $runs runs of each program, alternating
  the C twin and the Type-C program
* code: bytes of the .text* sections of the object (size -A)

Code size has no noise, so it is within noise only when equal. Speed
is judged on the instructions a program retires, which the load of the
host hardly moves. Each count is the median of its runs, with the
spread, the largest count less the smallest, in parentheses. The
counters count in user mode alone, leaving out the page faults, system
calls and interrupts the kernel serves while the program runs, and
every program runs from one path, since the length of that path moves
the count of its startup. The noise is the larger spread of the two
twins. The instruction count is within
noise when it differs from that of the C twin by at most the noise,
and the verdict is inconclusive when the noise exceeds
$inconclusive_percent% of the count of the C twin.

The unhalted core cycles stand beside the instructions and judge
nothing: they move with the load of the host, which shares caches and
memory with the program. They show what the instruction count cannot,
the stalls on memory, which bound the walk of ids.

$(uptime | sed "s/.*load/Load/") when the run began.

EOF
  printf '| %s ' program backend 'code tc' 'code c' diff size \
    'instr tc' 'instr c' 'diff' 'noise' speed \
    'cycles tc' 'cycles c' 'cycles diff'
  echo '|'
  printf '| %s ' --- --- --- --- --- --- --- --- --- --- --- --- --- ---
  echo '|'
}

# The results go to a temporary file first, so that a run that stops
# part-way leaves no table that reads as complete.
mkdir -p "$out/work"
check_user_mode
header > "$out/results.md.tmp"
for source in "$sources"/*.tc; do
  program=$(basename "$source" .tc)
  for backend in "$clang" "$gcc"; do
    name=$(basename "$backend")
    base=$out/work/$program-$name
    build "$backend" "$sources/$program.tc" "$base-tc"
    build "$backend" "$sources/$program.c" "$base-c"
    measure "$base" "$program"
    row "$base" "$program" "$name" >> "$out/results.md.tmp"
  done
done
mv "$out/results.md.tmp" "$out/results.md"
cat "$out/results.md"
