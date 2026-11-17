#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The measurements of package 3.10 on nested patterns: builds the matchers
# of tools/measure/nested in Type-C and their hand-written C twins, which
# are nested switch statements of the same decisions, with each backend at
# -O0 and -O2, and writes to OUT one CSV row for each count. The sides
# are typec; c, the twins; and c_aligned, which differs from c in the two
# matchers of a member, where it reads the member through a pointer to a
# typedef declared aligned(1) instead of a copy typec makes (design 13.5).
# The metrics are:
#
#   text_bytes   the bytes of machine code of each object and program
#   run_ns       the nanoseconds of each matcher over its ROUNDS rounds,
#                best of RUNS, for each size of SIZES
#   strict_insns the instructions of each matcher of a member that clang
#                writes for a target that has no unaligned loads
#                (ARMv5), counted in its assembly, where clang is the
#                backend
#   compile_ok   1 where the unit of a tree of the greatest depth that
#                design 4.7 rule 10 allows compiles, else 0
#   compile_s    the seconds that it takes, best of RUNS
#   unit_bytes ... selection_depth
#                what typec --stats reports for each Type-C unit
#
# The matchers are the units of tools/measure/nested: fold (a match with
# eight arms, three nodes deep through pointers), fold_test (three tests),
# sum_list (five nodes deep), outcome (two nodes, no pointer), and
# member_small and member_large (a scrutinee that is a member). Every run
# of the programs must print the same checksums, or the script fails.
#
# Usage: tools/measure/nested.sh OUT [CC...]
#
# OUT is the CSV file, outside the repository because it is raw data;
# the objects go to the directory OUT.build, which the script makes and
# removes again only when it holds the script's mark. CC names the
# backends, by default the Clang and the GCC of test/run/backends.sh.
# TYPEC names the compiler (by default the one dune builds in this
# tree), RUNS the runs a best is taken of (default 5), SIZES the sizes
# of the benchmark, each N:ROUNDS (default "10000:2000 1000000:20"),
# and REVISION the revision of the tree (by default what
# tools/corpus/revision.sh prints for it). The path of the tree holds
# no blank. Needs size(1), which -m reads Mach-O objects with on macOS
# and -A ELF ones elsewhere, and a time(1) with -p.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/nested
runs=${RUNS:-5}
sizes=${SIZES:-"10000:2000 1000000:20"}
flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror"
matchers="fold fold_test sum_list outcome member_small member_large"
aligned_matchers="member_small member_large"
# The constructors of a list that one pattern reads through pointers to
# make a tree of the most nodes on a path that rule 10 allows
# (Selection.max_depth, 127): one tag for each constructor and one for the
# Nil at its end. measure_limit checks that this is the greatest.
limit_levels=126
# A target whose loads must be aligned, so that a pointer to a typedef
# declared aligned(1) costs what it says.
strict_target=armv5-unknown-linux-gnueabi
mark=.nested-measure

fail() {
  echo "nested.sh: $*" >&2
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
case $out in
*[[:space:]]*) fail "OUT holds a blank: $out" ;;
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

# Compiles the Type-C unit $1 to $dir/typec-NAME.o with --stats, and
# sizes it.
measure_typec_unit() {
  name=$1
  object=$dir/typec-$name.o
  "$TYPEC" --cc="$cc" --stats $flags $opt -I "$sources" -c \
    -o "$object" "$sources/$name.tc" 2> "$dir/$name.stats" ||
    fail "typec failed on $name.tc: $(cat "$dir/$name.stats")"
  stats_rows "$name.tc" "$dir/$name.stats"
  bytes=$(code_bytes "$object")
  row typec "$name.o" text_bytes "$bytes" "" ""
}

# Compiles the file $2 of the C twins, which defines the matcher $3, to
# $dir/SIDE-MATCHER.o and sizes it, for side $1.
measure_c_unit() {
  side=$1
  object=$dir/$side-$3.o
  "$cc" $flags $opt -I "$sources" -c -o "$object" "$sources/$2.c"
  bytes=$(code_bytes "$object")
  row "$side" "$3.o" text_bytes "$bytes" "" ""
}

# The instructions of the assembly file $1: its lines that begin with
# white space and a letter, which are no directives.
count_instructions() {
  awk '/^[ \t]+[a-z]/ { count++ } END { print count + 0 }' "$1"
}

# The instructions of each matcher of a member on the strict target, by
# side, from the assembly that clang writes for its C: typec's, as
# lowered, and each twin's. The warnings are off, since the lowered C
# holds the line markers that -pedantic-errors refuses.
measure_strict_target() {
  case $version in
  *clang*) ;;
  *) return 0 ;;
  esac
  for matcher in $aligned_matchers; do
    "$TYPEC" --cc="$cc" $flags $opt -I "$sources" --emit-c \
      -o "$dir/$matcher.emitted.c" "$sources/$matcher.tc"
    for side in typec c c_aligned; do
      case $side in
      typec) source=$dir/$matcher.emitted.c ;;
      c) source=$sources/$matcher.c ;;
      c_aligned) source=$sources/${matcher}_aligned.c ;;
      esac
      "$cc" --target="$strict_target" -std=c11 $opt -I "$sources" -S \
        -o "$dir/$side-$matcher.s" "$source"
      insns=$(count_instructions "$dir/$side-$matcher.s")
      row "$side" "$matcher.s" strict_insns "$insns" "" ""
    done
  done
}

measure_units() {
  "$cc" $flags $opt -I "$sources" -c -o "$dir/driver.o" "$sources/driver.c"
  for matcher in $matchers; do
    measure_typec_unit "$matcher"
    measure_c_unit c "$matcher" "$matcher"
  done
  for matcher in $aligned_matchers; do
    measure_c_unit c_aligned "${matcher}_aligned" "$matcher"
  done
}

# The three programs: the c_aligned one takes the matchers of a member
# from its own objects and the others from the twins'.
link_programs() {
  "$cc" -o "$dir/nested_typec" "$dir/driver.o" "$dir"/typec-*.o
  "$cc" -o "$dir/nested_c" "$dir/driver.o" "$dir"/c-*.o
  objects=
  for matcher in $matchers; do
    if [ -f "$dir/c_aligned-$matcher.o" ]; then
      objects="$objects $dir/c_aligned-$matcher.o"
    else
      objects="$objects $dir/c-$matcher.o"
    fi
  done
  "$cc" -o "$dir/nested_c_aligned" "$dir/driver.o" $objects
  for side in typec c c_aligned; do
    bytes=$(code_bytes "$dir/nested_$side")
    row "$side" nested text_bytes "$bytes" "" ""
  done
}

# The best time of each matcher over RUNS runs of a program, as lines
# "matcher nanoseconds checksum"; every run must print the same checksums.
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
    for side in typec c c_aligned; do
      best_phases "$dir/nested_$side" "$n" "$rounds" \
        > "$dir/$side.$n.phases" ||
        fail "the $side program disagrees with itself at $n"
      awk '{ print $1, $3 }' "$dir/$side.$n.phases" > "$dir/$side.sums"
      cmp -s "$dir/typec.sums" "$dir/$side.sums" ||
        fail "the checksums of $side differ from typec's: $cc $opt $n"
      while read -r matcher nanoseconds checksum; do
        row "$side" "$matcher" run_ns "$nanoseconds" "$n" "$rounds"
      done < "$dir/$side.$n.phases"
    done
  done
}

# Writes to $1 a match whose one label reads $2 constructors of a list
# through pointers.
write_limit_unit() {
  awk -v levels="$2" '
    BEGIN {
      print "type list = | Nil | Cons(int head, const list *tail);"
      print "int"
      print "limit(const list *l)"
      print "{"
      print "\tmatch (*l) {"
      pattern = "Nil"
      for (i = 0; i < levels; i++)
        pattern = "Cons(_, *" pattern ")"
      print "\tcase " pattern ":"
      print "\t\treturn 1;"
      print "\tdefault:"
      print "\t\treturn 0;"
      print "\t}"
      print "}"
    }' > "$1"
}

# The tree of the greatest depth: typec must build it, and refuse one
# level more for its depth; then whether the backend compiles what typec
# lowers for it, how long that takes, and the counts of the unit.
measure_limit() {
  write_limit_unit "$dir/limit.tc" "$limit_levels"
  write_limit_unit "$dir/over.tc" $((limit_levels + 1))
  "$TYPEC" --cc="$cc" --emit-c -o "$dir/limit.c" "$dir/limit.tc" ||
    fail "typec refuses the tree of $limit_levels levels"
  if "$TYPEC" --cc="$cc" --emit-c -o "$dir/over.c" "$dir/over.tc" \
    2> "$dir/over.stats"; then
    fail "typec builds the tree of $((limit_levels + 1)) levels"
  fi
  grep -q 'is deeper than' "$dir/over.stats" ||
    fail "typec refuses one level more, but not for the depth:" \
      "$(cat "$dir/over.stats")"
  if "$TYPEC" --cc="$cc" --stats $flags $opt -c -o "$dir/limit.o" \
    "$dir/limit.tc" 2> "$dir/limit.stats"; then
    row typec limit.tc compile_ok 1 "" ""
    stats_rows limit.tc "$dir/limit.stats"
    bytes=$(code_bytes "$dir/limit.o")
    row typec limit.o text_bytes "$bytes" "" ""
    seconds=$(best_seconds "$TYPEC" --cc="$cc" $flags $opt -c \
      -o "$dir/limit.o" "$dir/limit.tc")
    row typec limit.tc compile_s "$seconds" "" ""
  else
    row typec limit.tc compile_ok 0 "" ""
  fi
}

measure() {
  dir=$build/$(basename "$cc")$opt
  mkdir -p "$dir"
  measure_units
  measure_strict_target
  link_programs
  measure_runs
  measure_limit
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
