#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# The measurements of package 3.12 on the cost of a try inside an
# expression (P33): builds programs in Type-C, with each try where its
# author put it (side prelude, the code that typec lowers to a prelude)
# and with each try in a declaration of its own (side decl), with each
# backend at -O0 and -O2, and writes to OUT one CSV row for each count.
# The programs are:
#
#   forms    nine functions of tools/measure/try_expr/forms.tc, each a
#            form of design 5.1 rule 3 (letters a to i), against the
#            same nine of forms_decl.tc
#   eval     the first example of the README, timed on a tree, against
#            the same with each try in a declaration of its own
#            (readme_decl.sed)
#   readme   the README's units copy.tc and pair.tc, as objects
#   toml     toml.tc of Pilot B against the same with each assignment
#            of a try in a declaration of its own (toml_decl.sed),
#            timed on the parser's bench of the pilot
#
# The metrics are:
#
#   text_bytes   the bytes of machine code of each object and program
#   run_ns       the nanoseconds of a program over its ROUNDS rounds,
#                best of RUNS, for each size of SIZES (forms and eval)
#                or its best round (toml, the pilot's bench: seconds
#                to the millisecond, so read at that grain)
#   try_holders ... try_multiple
#                what typec --stats reports of a Type-C unit
#
# Every run of two sides must print the same checksums (for toml, the
# same count of files that parse), or the script fails. A twin is
# checked to hold no try where a declaration or a statement of its own
# does not stand.
#
# Usage: tools/measure/try_expr.sh OUT [CC...]
#
# OUT is the CSV file, outside the repository because it is raw data;
# the objects go to the directory OUT.build, which the script makes and
# removes again only when it holds the script's mark. CC names the
# backends, by default the Clang and the GCC of test/run/backends.sh.
# PILOT names the tree of Pilot B (default /Volumes/Optaine/
# type-c-pilot-b), TYPEC the compiler (by default the one dune builds in
# this tree), RUNS the runs a best is taken of (default 5), SIZES the
# sizes of the forms, each N:ROUNDS (default "4096:5000"), EVAL_ROUNDS
# the rounds of eval (default 100000), and REVISION the revision of the
# tree (by default what tools/corpus/revision.sh prints for it). The path
# of the tree and PILOT hold no blank. Needs python3, sed -E and
# size(1), which the script runs with -m on macOS (Mach-O objects) and
# with -A elsewhere (ELF ones).

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
sources=$root/tools/measure/try_expr
pilot=${PILOT:-/Volumes/Optaine/type-c-pilot-b}
runs=${RUNS:-5}
sizes=${SIZES:-"4096:5000"}
eval_rounds=${EVAL_ROUNDS:-100000}
forms_flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror"
# The README's eval and the pilot compile with warnings that the
# backends give for them as they stand, so these are not errors.
unit_flags="-std=c11 -Wall -Wextra"
forms="a b c d e f g h i"
mark=.try-expr-measure

fail() {
  echo "try_expr.sh: $*" >&2
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
case $pilot in
*[[:space:]]*) fail "PILOT holds a blank: $pilot" ;;
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

# The fields are revision, host, cc, cc_version, opt, side, item,
# metric, value, n and rounds; a version holds no comma. A value that a
# command substitution computes in the arguments of row would not stop
# set -e where it fails, so row refuses an empty one.
row() {
  [ -n "$4" ] || fail "no value for $3 of $2"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" \
    "$cc" "$cc_version" "$opt" "$@" >> "$out"
}

# The row of the bytes of machine code in the object or program $3.
text_row() {
  bytes=$(code_bytes "$3")
  row "$1" "$2" text_bytes "$bytes" "" ""
}

# The rows of the counts of one unit, from the line of typec --stats.
stats_rows() {
  fields=$(sed -n 's/^typec: stats: .*: //p' "$2")
  [ -n "$fields" ] || fail "no counts for $1 in $2"
  for field in $fields; do
    case $field in
    try_*) row "$side" "$1" "${field%%=*}" "${field#*=}" "" "" ;;
    esac
  done
}

# Compiles the Type-C unit $2 with the flags $3 and the options $4 to
# the object $dir/SIDE-NAME.o for side $1 and item $5, counts its
# try holders and sizes it.
compile_unit() {
  side=$1
  object=$dir/$1-$5.o
  "$TYPEC" --cc="$cc" --stats $3 $opt $4 -c -o "$object" "$2" \
    2> "$dir/$1-$5.stats" ||
    fail "typec failed on $2: $(cat "$dir/$1-$5.stats")"
  stats_rows "$5" "$dir/$1-$5.stats"
  text_row "$1" "$5.o" "$object"
}

# The least of the numbers of the second field of the lines of $1,
# which hold "name nanoseconds checksum"; every line of a name must
# have the checksum of the first.
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

# Writes the rows of the phases of a program of side $1, from the file
# $2 of lines "name nanoseconds checksum", for the sizes $3 and $4, and
# checks the checksums against those of the other side where it is there.
record_phases() {
  while read -r name nanoseconds checksum; do
    row "$1" "$name" run_ns "$nanoseconds" "$3" "$4"
  done < "$2"
  awk '{ print $1, $3 }' "$2" > "$dir/$1.sums.$5"
  if [ -f "$dir/prelude.sums.$5" ] && [ -f "$dir/decl.sums.$5" ]; then
    cmp -s "$dir/prelude.sums.$5" "$dir/decl.sums.$5" ||
      fail "the checksums of the two sides differ: $cc $opt $5"
  fi
}

measure_forms() {
  for side in prelude decl; do
    case $side in
    prelude) unit=forms.tc ;;
    decl) unit=forms_decl.tc ;;
    esac
    for form in $forms; do
      compile_unit $side "$sources/$unit" "$forms_flags" \
        "-DFORM_$form -I $sources" "forms_$form"
    done
    compile_unit $side "$sources/$unit" "$forms_flags" \
      "-DFORM_ALL -I $sources" forms
    "$cc" $forms_flags $opt -I "$sources" -c -o "$dir/driver.o" \
      "$sources/driver.c"
    "$cc" -o "$dir/forms-$side" "$dir/driver.o" "$dir/$side-forms.o" \
      "$dir/ext.o"
    text_row $side forms "$dir/forms-$side"
  done
  for size in $sizes; do
    n=${size%%:*}
    rounds=${size#*:}
    for side in prelude decl; do
      best_phases "$dir/forms-$side" "$n" "$rounds" \
        > "$dir/forms-$side.$n.phases" ||
        fail "the $side forms disagree with themselves at $n"
      record_phases $side "$dir/forms-$side.$n.phases" "$n" "$rounds" "forms$n"
    done
  done
}

# The unit of the fallible functions of the forms, which both sides link.
build_forms_ext() {
  "$TYPEC" --cc="$cc" $forms_flags $opt -I "$sources" -c \
    -o "$dir/ext.o" "$sources/forms_ext.tc"
}

# Writes to $2 the README's unit $1 with each try in a declaration of
# its own, and fails where a try is left in another place: a try that
# a declaration or a statement of its own does not begin.
write_decl_unit() {
  sed -E -f "$sources/readme_decl.sed" "$build/readme/$1" > "$2"
  check_twin "$2"
}

# Fails where the file $1 holds a try that no declaration or statement
# of its own begins, by the shapes of source_shapes.awk.
check_twin() {
  awk -v names= -f "$sources/source_shapes.awk" "$1" > "$build/shapes" ||
    fail "source_shapes.awk failed on $1"
  awk '$1 == "D" && ($3 == "other" || $3 == "assignment")' \
    "$build/shapes" > "$build/not-decl"
  [ ! -s "$build/not-decl" ] ||
    fail "$1 holds a try that no declaration or statement of its own" \
      "begins: $(head -n 3 "$build/not-decl")"
}

measure_eval() {
  for side in prelude decl; do
    case $side in
    prelude) text=eval.tc ;;
    decl) text=eval_decl.tc ;;
    esac
    compile_unit $side "$sources/eval_bench.tc" "$unit_flags" \
      "-I $sources -I $build/readme -DEVAL=\"$text\"" eval_bench
    "$cc" $opt -o "$dir/eval-$side" "$sources/eval_driver.c" \
      "$dir/$side-eval_bench.o"
    text_row $side eval "$dir/eval-$side"
    best_phases "$dir/eval-$side" "$eval_rounds" \
      > "$dir/eval-$side.phases" ||
      fail "the $side eval disagrees with itself"
    record_phases $side "$dir/eval-$side.phases" "" "$eval_rounds" eval
  done
}

measure_readme_units() {
  for unit in copy pair; do
    compile_unit prelude "$build/readme/$unit.tc" "$unit_flags" \
      "-I $build/readme" "readme_$unit"
    compile_unit decl "$build/readme/${unit}_decl.tc" "$unit_flags" \
      "-I $build/readme" "readme_$unit"
  done
}

# The pilot's bench of the parser, as tools/bench/run.sh of the pilot
# runs it: REPS parses of each file in each of five rounds, the best
# round in seconds. The file list is "big" (one file, 20 reps) and
# "stdex" (the small files that parse, 300 reps).
measure_toml() {
  for side in prelude decl; do
    case $side in
    prelude) unit=$pilot/toml.tc ;;
    decl) unit=$build/toml_decl.tc ;;
    esac
    compile_unit $side "$unit" "$unit_flags" "-I $pilot" toml
    "$cc" $opt -I "$pilot" -o "$dir/bench-$side" \
      "$pilot/tools/bench/bench.c" "$dir/$side-toml.o"
    text_row $side bench "$dir/bench-$side"
    for set in "big 20" "stdex 300"; do
      name=${set% *}
      reps=${set#* }
      case $name in
      big) files=$build/big.toml ;;
      stdex) files=$stdex ;;
      esac
      : > "$dir/toml-$side-$name.times"
      i=0
      while [ "$i" -lt "$runs" ]; do
        "$dir/bench-$side" "$reps" $files \
          >> "$dir/toml-$side-$name.times" 2> "$dir/toml-$side-$name.ok" ||
          fail "the pilot's bench failed: $side $name"
        i=$((i + 1))
      done
      seconds=$(sort -n "$dir/toml-$side-$name.times" | head -n 1)
      nanoseconds=$(awk -v s="$seconds" 'BEGIN { printf "%.0f", s * 1e9 }')
      row $side "toml_$name" run_ns "$nanoseconds" "" "$reps"
      # The parses that succeed are the same for both sides.
      cp "$dir/toml-$side-$name.ok" "$dir/toml-$name.ok.$side"
    done
  done
  for name in big stdex; do
    cmp -s "$dir/toml-$name.ok.prelude" "$dir/toml-$name.ok.decl" ||
      fail "the sides parse a different number of files: $cc $opt $name"
  done
}

measure() {
  dir=$build/$backend-$(basename "$cc")$opt
  mkdir -p "$dir"
  build_forms_ext
  measure_forms
  measure_eval
  measure_readme_units
  measure_toml
}

if [ -e "$build" ]; then
  [ -f "$build/$mark" ] || fail "$build is not the script's; remove it"
  rm -rf "$build"
fi
mkdir -p "$build"
: > "$build/$mark"

# The twins and the inputs, once for all backends.
sh "$root/test/run/readme.sh" --files "$root/README.md" "$build/readme" ||
  fail "readme.sh wrote no files"
for unit in eval copy pair; do
  write_decl_unit "$unit.tc" "$build/readme/${unit}_decl.tc"
done
sed -E -f "$sources/toml_decl.sed" "$pilot/toml.tc" > "$build/toml_decl.tc"
check_twin "$build/toml_decl.tc"
check_twin "$sources/forms_decl.tc"
python3 -I "$pilot/tools/bench/gen_big.py" > "$build/big.toml"
stdex=
for file in "$pilot"/stdex/*.toml; do
  case $(basename "$file") in
  *bad* | *err*) ;;
  *) stdex="$stdex $file" ;;
  esac
done
[ -n "$stdex" ] || fail "no stdex file of the pilot parses: $pilot"

echo "revision,host,cc,cc_version,opt,side,item,metric,value,n,rounds" \
  > "$out"
backend=0
for cc in "$@"; do
  # Two backends of one name, as two clangs, get directories of their own.
  backend=$((backend + 1))
  version=$("$cc" --version)
  cc_version=$(printf '%s\n' "$version" | head -n 1 | tr ',' ';')
  for opt in -O0 -O2; do
    measure
  done
done
