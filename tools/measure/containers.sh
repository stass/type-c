#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The measurements of package 3.6 on the container library: builds the
# benchmark of tools/measure/containers in Type-C, with the library of
# test/run/containers.t, and its two hand-written C twins, with each
# backend at -O0 and -O2, and writes to OUT one CSV row for each count.
# The sides are typec; c, whose instances are external functions defined
# once in containers.o; c_inline, whose instances are static inline
# functions defined in each unit, as Type-C's are; and common, the plain
# C of bench_common.c that all three programs link. The metrics are:
#
#   text_bytes   the bytes of machine code of each object and program
#   compile_s    the seconds that typec, or the backend for C, takes to
#                compile each unit to an object, best of RUNS
#   emit_s       the seconds that typec --emit-c takes, best of RUNS
#   run_ns       the nanoseconds of each phase of the benchmark over
#                its ROUNDS rounds, best of RUNS, for each size of SIZES
#   unit_bytes ... longest_name
#                what typec --stats reports for each Type-C unit
#
# The units of the library's test (words.tc, points.tc, main.tc) are
# compiled and counted too, though they have no twin. region.o carries
# the str functions of the library, which the C twins leave out. Every
# run of the three programs must print the same checksums, or the
# script fails.
#
# Usage: tools/measure/containers.sh OUT [CC...]
#
# OUT is the CSV file, outside the repository because it is raw data;
# the objects go to the directory OUT.build, which the script makes and
# removes again only when it holds the script's mark. CC names the
# backends, by default the Clang and the GCC of test/run/backends.sh.
# TYPEC names the compiler (by default the one dune builds in this
# tree), RUNS the runs a best is taken of (default 5), SIZES the sizes
# of the benchmark, each N:ROUNDS (default "10000:1000 1000000:10"),
# and REVISION the revision of the tree (by default what
# tools/corpus/revision.sh prints for it). The path of the tree holds
# no blank. Needs size(1), which -m reads Mach-O objects with on macOS
# and -A ELF ones elsewhere, and a time(1) with -p, whose resolution of
# 10 ms bounds that of the compile times.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/containers
library=$root/test/run/containers.t
runs=${RUNS:-5}
sizes=${SIZES:-"10000:1000 1000000:10"}
flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror"
typec_units="$sources/bench.tc $sources/bench_map.tc $library/region.tc
  $library/words.tc $library/points.tc $library/main.tc"
c_units="$sources/containers.c $sources/bench.c $sources/bench_map.c"
mark=.containers-measure

fail() {
  echo "containers.sh: $*" >&2
  exit 1
}

[ $# -ge 1 ] || { echo "usage: $0 OUT [CC...]" >&2; exit 2; }
out=$1
shift
[ -n "$out" ] || fail "OUT is empty"
[ ! -d "$out" ] || fail "OUT is a directory: $out"
case $root in
*[[:space:]]*) fail "the path of the tree holds a blank: $root" ;;
esac
case $runs in
'' | *[!0-9]* | 0) fail "RUNS is not a positive number: $runs" ;;
esac

out_dir=$(CDPATH='' cd "$(dirname "$out")" && pwd -P) ||
  fail "no directory for $out"
root_physical=$(CDPATH='' cd "$root" && pwd -P)
case $out_dir/ in
"$root_physical"/*)
  fail "$out is in the repository, and raw data stays out of it" ;;
esac
out=$out_dir/$(basename "$out")
build=$out.build

if [ -n "${REVISION:-}" ]; then
  revision=$REVISION
else
  revision=$("$root/tools/corpus/revision.sh" "$root") ||
    fail "cannot tell the revision of $root; name it in REVISION"
fi

if [ $# -eq 0 ]; then
  . "$root/test/run/backends.sh"
  set -- "$clang" "$gcc"
fi

if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi

host=$(uname -sm)

# The bytes of machine code in an object or a program: the sum of its
# code sections, which GCC splits into several (.text.startup and the
# like on ELF, __text_startup on Mach-O).
code_bytes() {
  case $(uname -s) in
  Darwin)
    size -m "$1" |
      awk '/Section (\(__TEXT, )?__text/ { sum += $NF; found = 1 }
        END { if (!found) exit 1; print sum }' ;;
  *)
    size -A "$1" |
      awk '$1 ~ /^\.text(\..*)?$/ { sum += $2; found = 1 }
        END { if (!found) exit 1; print sum }' ;;
  esac || fail "no code section in $1"
}

# The least real time, in seconds, of RUNS runs of a command whose
# output is dropped.
best_seconds() {
  : > "$build/times"
  i=0
  while [ "$i" -lt "$runs" ]; do
    /usr/bin/time -p sh -c '"$@" > /dev/null 2>&1' sh "$@" \
      2> "$build/time" || fail "failed: $*"
    awk '$1 == "real" { print $2 }' "$build/time" >> "$build/times"
    i=$((i + 1))
  done
  sort -n "$build/times" | head -n 1
}

# The fields are revision, host, cc, cc_version, opt, side, item,
# metric, value, n and rounds; a version holds no comma. Each value is
# assigned before it is written, so that set -e stops at a failed one.
row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" \
    "$cc" "$cc_version" "$opt" "$@" >> "$out"
}

# The rows of the counts of one unit, from the line of typec --stats.
stats_rows() {
  fields=$(sed -n 's/^typec: stats: .*: //p' "$2")
  [ -n "$fields" ] || fail "no counts for $1 in $2"
  for field in $fields; do
    row typec "$1" "${field%%=*}" "${field#*=}" "" ""
  done
}

# Compiles each Type-C unit with --stats, then times the compile and
# --emit-c, and sizes the object.
measure_typec_units() {
  for unit in $typec_units; do
    name=$(basename "$unit" .tc)
    object=$dir/$name.o
    "$TYPEC" --cc="$cc" --stats $flags $opt -I "$library" -c \
      -o "$object" "$unit" 2> "$dir/$name.stats" ||
      fail "typec failed on $unit: $(cat "$dir/$name.stats")"
    stats_rows "$name.tc" "$dir/$name.stats"
    bytes=$(code_bytes "$object")
    row typec "$name.o" text_bytes "$bytes" "" ""
    seconds=$(best_seconds "$TYPEC" --cc="$cc" $flags $opt -I "$library" \
      -c -o "$object" "$unit")
    row typec "$name.tc" compile_s "$seconds" "" ""
    seconds=$(best_seconds "$TYPEC" --cc="$cc" $flags $opt -I "$library" \
      --emit-c -o "$dir/$name.c" "$unit")
    row typec "$name.tc" emit_s "$seconds" "" ""
  done
}

# Compiles a C unit of side $1 with the options after it, and sizes
# and times it; the object is $dir/$1.NAME.o.
measure_c_unit() {
  side=$1
  unit=$2
  shift 2
  name=$(basename "$unit" .c)
  object=$dir/$side.$name.o
  "$cc" $flags $opt "$@" -c -o "$object" "$unit"
  bytes=$(code_bytes "$object")
  row "$side" "$name.o" text_bytes "$bytes" "" ""
  seconds=$(best_seconds "$cc" $flags $opt "$@" -c -o "$object" "$unit")
  row "$side" "$name.c" compile_s "$seconds" "" ""
}

measure_c_units() {
  measure_c_unit common "$sources/bench_common.c"
  for unit in $c_units; do
    measure_c_unit c "$unit"
    measure_c_unit c_inline "$unit" -DCONTAINERS_INLINE
  done
}

link_programs() {
  "$cc" -o "$dir/bench_typec" "$dir/bench.o" "$dir/bench_map.o" \
    "$dir/region.o" "$dir/common.bench_common.o"
  for side in c c_inline; do
    "$cc" -o "$dir/bench_$side" "$dir/$side.containers.o" \
      "$dir/$side.bench.o" "$dir/$side.bench_map.o" \
      "$dir/common.bench_common.o"
  done
  for side in typec c c_inline; do
    bytes=$(code_bytes "$dir/bench_$side")
    row "$side" bench text_bytes "$bytes" "" ""
  done
}

# The best time of each phase over RUNS runs of a program, as lines
# "phase nanoseconds checksum"; every run must print the same checksums.
best_phases() {
  : > "$build/phases"
  i=0
  while [ "$i" -lt "$runs" ]; do
    "$@" >> "$build/phases" || fail "failed: $*"
    i=$((i + 1))
  done
  awk '
    !($1 in best) { order[++count] = $1; best[$1] = $2; sum[$1] = $3 }
    $2 < best[$1] { best[$1] = $2 }
    $3 != sum[$1] { differs = 1 }
    END {
      if (differs) exit 1
      for (i = 1; i <= count; i++) print order[i], best[order[i]], sum[order[i]]
    }' "$build/phases"
}

measure_runs() {
  for size in $sizes; do
    n=${size%%:*}
    rounds=${size#*:}
    for side in typec c c_inline; do
      best_phases "$dir/bench_$side" "$n" "$rounds" \
        > "$dir/$side.$n.phases" ||
        fail "the $side benchmark disagrees with itself at $n"
      awk '{ print $1, $3 }' "$dir/$side.$n.phases" > "$dir/$side.sums"
      cmp -s "$dir/typec.sums" "$dir/$side.sums" ||
        fail "the checksums of $side differ from typec's: $cc $opt $n"
      while read -r phase nanoseconds checksum; do
        row "$side" "$phase" run_ns "$nanoseconds" "$n" "$rounds"
      done < "$dir/$side.$n.phases"
    done
  done
}

measure() {
  dir=$build/$(basename "$cc")$opt
  mkdir -p "$dir"
  measure_typec_units
  measure_c_units
  link_programs
  measure_runs
}

if [ -e "$build" ]; then
  [ -f "$build/$mark" ] || fail "$build is not the script's; remove it"
  rm -rf "$build"
fi
mkdir -p "$build"
: > "$build/$mark"
echo "revision,host,cc,cc_version,opt,side,item,metric,value,n,rounds" \
  > "$out"
for cc in "$@"; do
  version=$("$cc" --version)
  cc_version=$(printf '%s\n' "$version" | head -n 1 | tr ',' ';')
  for opt in -O0 -O2; do
    measure
  done
done
