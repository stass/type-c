#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# What typec --stats reports for the Type-C units of the tests and of the
# README, as rows of the CSV that containers.sh writes (package 3.10,
# P32): the steps, the nodes and the depth of the selection tree of
# their matches and tests, with the other counts of --stats. A unit is
# every heredoc of a cram test that writes a file with the suffix .tc,
# compiled where the test stands, with the files that the test wrote
# before it; and every .tc file that test/run/readme.sh writes from the
# README. A unit that typec refuses has one row, refused, of value 1,
# since the tests hold the refusals; each unit that it builds has
# refused of value 0 and the fields of --stats; a refusal that names a
# translation limit of selection (design 4.7 rule 10) also has the row
# refused_selection of value 1. Units of other programs are counted by
# unit_stats.sh.
#
# Usage: tools/measure/selection_stats.sh OUT CC [TEST.t...]
#
# OUT is the CSV file, outside the repository because it is raw data;
# the script appends to it and writes its header where it is new. CC
# names the backend. The tests are by default those of test/run and
# test/golden. The side of a row is tests or readme, and the item names
# the test, the file and its place among that test's units. TYPEC names
# the compiler (by default the one dune builds in this tree), and
# REVISION the revision of the tree (by default what
# tools/corpus/revision.sh prints for it). Only the heredocs with a
# quoted delimiter that are plain "cat" commands are run, in a directory
# of the script's own, so that no other command of a test runs; the
# directories of the files they write are made, and a file that cat
# cannot read, as one that another command of the test makes, is left
# out.

set -eu

root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)

fail() {
  echo "selection_stats.sh: $*" >&2
  exit 1
}

[ $# -ge 2 ] || { echo "usage: $0 OUT CC [TEST.t...]" >&2; exit 2; }
out=$1
cc=$2
shift 2
if [ $# -eq 0 ]; then
  for test in "$root"/test/run/*.t "$root"/test/golden/*.t; do
    [ -f "$test" ] && set -- "$@" "$test"
  done
fi
case $cc in
*/*) cc=$(CDPATH='' cd "$(dirname "$cc")" && pwd -P)/$(basename "$cc") ;;
*) cc=$(command -v "$cc") || fail "no such backend: $cc" ;;
esac

out_dir=$(CDPATH='' cd "$(dirname "$out")" && pwd -P) ||
  fail "no directory for $out"
root_physical=$(CDPATH='' cd "$root" && pwd -P)
case $out_dir/ in
"$root_physical"/*)
  fail "$out is in the repository, and raw data stays out of it" ;;
esac
out=$out_dir/$(basename "$out")

if [ -n "${REVISION:-}" ]; then
  revision=$REVISION
else
  revision=$("$root/tools/corpus/revision.sh" "$root") ||
    fail "cannot tell the revision of $root; name it in REVISION"
fi
if [ -z "${TYPEC:-}" ]; then
  dune build --root "$root" ./bin/main.exe
  TYPEC=$root/_build/default/bin/main.exe
fi
# The units are built in other directories.
TYPEC=$(CDPATH='' cd "$(dirname "$TYPEC")" && pwd -P)/$(basename "$TYPEC")

host=$(uname -sm)
version=$("$cc" --version) || fail "$cc does not run"
cc_version=$(printf '%s\n' "$version" | head -n 1 | tr ',' ';')
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

[ -e "$out" ] ||
  echo "revision,host,cc,cc_version,opt,side,item,metric,value,n,rounds" \
    > "$out"

row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$revision" "$host" \
    "$cc" "$cc_version" -O2 "$side" "$@" >> "$out"
}

# The rows of the unit $1, a file in the directory where it stands:
# whether typec refuses it and its counts where it does not. The item
# is $group/$1, then a number for each unit of the group so far. The
# include path holds the directory of the unit and its include, which
# the README's units are built with.
units=0
measure_unit() {
  units=$((units + 1))
  item=$group/$1#$units
  if "$TYPEC" --cc="$cc" --stats -std=c11 -O2 -I . -I include --emit-c \
    -o "$scratch/unit.c" "$1" 2> "$scratch/stats"; then
    row "$item" refused 0 "" ""
    fields=$(sed -n 's/^typec: stats: .*: //p' "$scratch/stats")
    [ -n "$fields" ] || fail "no counts for $item"
    for field in $fields; do
      row "$item" "${field%%=*}" "${field#*=}" "" ""
    done
  else
    row "$item" refused 1 "" ""
    refusal=0
    if grep -q 'steps of selection\|^.*selection tree of .* is deeper' \
      "$scratch/stats"; then
      refusal=1
    fi
    row "$item" refused_selection "$refusal" "" ""
  fi
}

# An awk pattern for a command of a cram test that writes a file with
# cat from a heredoc whose delimiter is quoted (\047), so that its body
# is text.
name='[A-Za-z0-9_./-]+'
cat_heredoc="^  [$] cat( $name| -)* > $name <<\\047[A-Za-z_]+\\047\$"

# The shell script that writes the files of one cram test and measures
# each .tc file as it is written: the heredocs that are plain cat
# commands, copied as the test has them, and each followed by the call
# of measure_unit where the file is a unit.
test_script() {
  awk -v cat_heredoc="$cat_heredoc" '
    function delimiter(command) {
      sub(/.*<</, "", command)
      gsub(/\047/, "", command)
      return command
    }
    function target(command, words, count) {
      sub(/ *<<.*/, "", command)
      count = split(command, words, " ")
      return words[count]
    }
    !inside && $0 ~ cat_heredoc {
      command = $0
      sub(/^  \$ /, "", command)
      file = target(command)
      if (file ~ /(^|\/)\.\.(\/|$)/ || file ~ /^\//)
        next
      directory = file
      if (sub(/\/[^\/]*$/, "", directory))
        print "mkdir -p " directory
      print command " || :"
      end = delimiter(command)
      inside = 1
      next
    }
    inside {
      line = $0
      if (!sub(/^  > ?/, "", line)) { inside = 0; next }
      print line
      if (line == end) {
        inside = 0
        if (file ~ /\.tc$/)
          print "measure_unit " file
      }
    }' "$1"
}

side=tests
for test in "$@"; do
  [ -f "$test" ] || fail "no such test: $test"
  group=$(basename "$test" .t)
  units=0
  work=$scratch/work
  rm -rf "$work"
  mkdir "$work"
  test_script "$test" > "$scratch/test.sh"
  (cd "$work" && . "$scratch/test.sh")
done

# The README: the files that test/run/readme.sh writes, which needs
# typec on the path.
side=readme
group=README
units=0
mkdir "$scratch/bin"
ln -s "$TYPEC" "$scratch/bin/typec"
rm -rf "$scratch/work"
mkdir "$scratch/work"
(cd "$scratch/work" &&
  PATH=$scratch/bin:$PATH sh "$root/test/run/readme.sh" clang "$cc" \
    "$root/README.md" > "$scratch/readme.log" 2>&1)
[ -d "$scratch/work/work-clang" ] || fail "readme.sh wrote no files"
(cd "$scratch/work/work-clang" && find . -name '*.tc' | sort |
  while read -r unit; do
    measure_unit "${unit#./}"
  done)
