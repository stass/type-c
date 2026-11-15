#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Stage 1 exit gate 4, size and speed: builds each Type-C program in
# tools/measure/gate4 and its hand-written C twin at -O2 with each
# backend, checks that the two print the same, and writes the code size
# and the run time of both to OUT/results.md.
#
# Usage: tools/measure/gate4.sh [OUT]
#
# OUT defaults to /Volumes/Optaine/typec-gate4 and holds the objects,
# the lowered C and the timings beside the results; it is outside the
# repository because they are raw data. TYPEC names the compiler (by
# default the one dune builds in this tree), TYPEC_TEST_CLANG and
# TYPEC_TEST_GCC the backends as for the tests, RUNS the timed runs of
# each batch (default 30). The code size is read from Mach-O sections,
# so the script runs on macOS only, and it needs hyperfine and jq.

set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/gate4
out=${1:-/Volumes/Optaine/typec-gate4}
runs=${RUNS:-30}
# Both sides of a pair are built as C11, the dialect typec gives a .tc
# input, rather than in each backend's own default.
flags="-std=gnu11 -O2 -Wall -Wextra -Werror"
# Above this share of the reference time the noise is too large for a
# verdict: the host is too busy to tell a difference of that size.
inconclusive_percent=5

fail() {
  echo "gate4.sh: $*" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "reads Mach-O sections; run on macOS"
command -v hyperfine > /dev/null || fail "needs hyperfine"
command -v jq > /dev/null || fail "needs jq"

. "$root/test/run/backends.sh"

if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi

# The command-line arguments of each program, sized for a run of a few
# tenths of a second on the development host, and the last one a seed.
arguments_of() {
  case $1 in
  tree) echo "65536 400 1" ;;
  shapes) echo "10000 10000 1" ;;
  ids) echo "1048576 8000000 1" ;;
  *) fail "no arguments for $1" ;;
  esac
}

# The bytes of machine code in an object: the sum of its __TEXT sections
# named __text*, which GCC splits into __text, __text_startup and
# __text_cold. Strings and unwind tables are left out; the padding that
# aligns each function is counted.
code_bytes() {
  sections=$(size -m "$1") || fail "size -m failed on $1"
  echo "$sections" | awk '
    /Section \(__TEXT, __text/ { sum += $NF; found = 1 }
    END { if (!found) exit 1; print sum }' ||
    fail "no __text section in $1"
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

# The median and the interquartile range of one batch of a hyperfine
# export, in milliseconds. The median and the quartiles, unlike the mean
# and the standard deviation, are not dragged by the few runs that other
# load on the host slows. A quantile is the sorted run at its rank,
# rounded down, so the median of an even count is the upper middle run.
timing() {
  jq -r --arg batch "$2" '
    def at(q): .[length * q | floor];
    .results[] | select(.command == $batch) | .times | sort |
    [at(0.5), at(0.75) - at(0.25)] | map(. * 1000) | join(" ")' "$1"
}

# Checks that the twins print the same, then times the C twin, the
# Type-C program and the C twin again; the second batch of the C twin
# measures the drift between batches.
measure() {
  arguments=$(arguments_of "$2")
  "$1-tc" $arguments > "$1-tc.out"
  "$1-c" $arguments > "$1-c.out"
  cmp -s "$1-tc.out" "$1-c.out" || fail "$1: the twins differ in output"
  hyperfine -N --style none --warmup 3 --runs "$runs" \
    --export-json "$1.json" \
    -n c "$1-c $arguments" -n tc "$1-tc $arguments" \
    -n c-again "$1-c $arguments" > /dev/null
}

# One row of the table: sizes, times and both verdicts, drawn as the
# header of results.md defines them.
row() {
  size_tc=$(cat "$1-tc.size")
  size_c=$(cat "$1-c.size")
  c1=$(timing "$1.json" c)
  c2=$(timing "$1.json" c-again)
  tc=$(timing "$1.json" tc)
  [ -n "$c1" ] && [ -n "$c2" ] && [ -n "$tc" ] ||
    fail "$1.json lacks a batch"
  awk -v program="$2" -v backend="$3" -v size_tc="$size_tc" \
    -v size_c="$size_c" -v c1="$c1" -v c2="$c2" -v tc="$tc" \
    -v inconclusive_percent="$inconclusive_percent" '
    function abs(x) { return x < 0 ? -x : x }
    function max(a, b) { return a > b ? a : b }
    function judge_time() {
      if (100 * noise > inconclusive_percent * reference)
        return "inconclusive"
      if (abs(delta) <= noise)
        return "within"
      return "outside"
    }
    BEGIN {
      split(c1, first); split(c2, again); split(tc, typec)
      reference = (first[1] + again[1]) / 2
      noise = max(max(first[2], again[2]), abs(first[1] - again[1]))
      delta = typec[1] - reference
      size_verdict = size_tc == size_c ? "equal" : "differs"
      time_verdict = judge_time()
      printf "| %s | %s | %d | %d | %+d | %s | %.1f (%.1f) |" \
        " %.1f (%.1f) | %+.1f (%+.1f%%) | %.1f | %s |\n", \
        program, backend, size_tc, size_c, size_tc - size_c, size_verdict, \
        typec[1], typec[2], reference, max(first[2], again[2]), \
        delta, 100 * delta / reference, noise, time_verdict
    }'
}

header() {
  cat <<EOF
# Stage 1 exit gate 4: size and speed against hand-written C

Written by tools/measure/gate4.sh at
$(git -C "$root" describe --always --dirty) on $(date -u +%Y-%m-%dT%H:%MZ),
$(uname -m),
$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown CPU").

* clang: $("$clang" --version | head -n 1)
* gcc: $("$gcc" --version | head -n 1)
* flags: $flags
* timing: hyperfine, 3 warm-up runs and $runs timed runs per batch, in
  the order C twin, Type-C, C twin again
* code: bytes of the __text* sections of the object (size -m)

Code size has no noise, so it is within noise only when equal. The
Type-C time is its median with its interquartile range in parentheses;
the C time is the reference, the mean of the medians of its two
batches, with the larger interquartile range of the two. The noise is
the larger of that range and the drift between the two C medians. A
time is within noise when it differs from the reference by at most the
noise, and the verdict is inconclusive when the noise exceeds
$inconclusive_percent% of the reference.
$(uptime | sed "s/.*load/Load/") when the run began.

EOF
  printf '| %s ' program backend 'code tc' 'code c' diff size \
    'time tc ms' 'time c ms' 'diff ms' 'noise ms' time
  echo '|'
  printf '| %s ' --- --- --- --- --- --- --- --- --- --- ---
  echo '|'
}

# The results go to a temporary file first, so that a run that stops
# part-way leaves no table that reads as complete.
mkdir -p "$out/work"
header > "$out/results.md.tmp"
for program in tree shapes ids; do
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
